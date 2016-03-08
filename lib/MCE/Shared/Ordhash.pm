###############################################################################
## ----------------------------------------------------------------------------
## Ordered-hash helper class.
##
## An optimized, pure-Perl ordered hash implementation featuring tombstone
## deletion, inspired by Hash::Ordered v0.009.
##
## 1. Added splice, sorting, plus extra capabilities for use with MCE::Shared.
##
## 2. Revised tombstone deletion to not impact store, push, unshift, and merge.
##    Tombstones are purged in-place for overall lesser memory consumption.
##    Also, minimized overhead in pop and shift when an index is present.
##    Ditto for forward and reverse deletes.
##
## 3. Provides support for hash-like dereferencing.
##
###############################################################################

package MCE::Shared::Ordhash;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized numeric );

our $VERSION = '1.700';

## no critic (Subroutines::ProhibitExplicitReturnUndef)
## no critic (TestingAndDebugging::ProhibitNoStrict)

use MCE::Shared::Base;
use bytes;

# for marking a key to be garbage collected later
use constant { _TOMBSTONE => undef };

use constant {
   _DATA => 0,  # unordered data
   _KEYS => 1,  # ordered ids with keys
   _INDX => 2,  # index into _KEYS (on demand, no impact to STORE)
   _BEGI => 3,  # begin ordered id for optimized shift/unshift
   _GCNT => 4,  # garbage count
   _HREF => 5,  # for hash-like dereferencing
   _ITER => 6,  # for tied hash support
};

use overload (
   q("")    => \&MCE::Shared::Base::_stringify,
   q(0+)    => \&MCE::Shared::Base::_numify,
   q(%{})   => sub {
      $_[0]->[_HREF] //= do {
         tie my %h, __PACKAGE__.'::_href', bless([ @{ $_[0] } ], __PACKAGE__);
         \%h;
      };
   },
   fallback => 1
);

###############################################################################
## ----------------------------------------------------------------------------
## TIEHASH, STORE, FETCH, DELETE, FIRSTKEY, NEXTKEY, EXISTS, CLEAR, SCALAR
##
###############################################################################

# TIEHASH ( key, value [, key, value, ... ] )
# TIEHASH ( )

sub TIEHASH {
   my ( $class ) = ( shift );
   my ( $begi, $gcnt ) = ( 0, 0 );
   my ( $key, %data, @keys );

   while ( @_ ) {
      push @keys, "$key" unless ( exists $data{ $key = shift } );
      $data{ $key } = shift;
   }

   bless [ \%data, \@keys, {}, \$begi, \$gcnt ], $class;
}

# STORE ( key, value )

sub STORE {
   my ( $key, $data, $keys ) = ( $_[1], @{ $_[0] } );
   push @{ $keys }, "$key" unless ( exists $data->{ $key } );

   $data->{ $key } = $_[2];
}

# FETCH ( key )

sub FETCH {
   $_[0]->[_DATA]{ $_[1] };
}

# DELETE ( key )

sub DELETE {
   my ( $key, $data, $keys, $indx, $begi, $gcnt ) = ( $_[1], @{ $_[0] } );

   # check the first key
   if ( $key eq $keys->[0] ) {
      shift @{ $keys };
      ${ $begi }++, delete $indx->{ $key } if %{ $indx };

      # GC start of list
      if ( ${ $gcnt } && !defined $keys->[0] ) {
         my $i = 1;
         $i++ until ( defined $keys->[$i] );
         ${ $begi } += $i, ${ $gcnt } -= $i;
         splice @{ $keys }, 0, $i;
      }
      elsif ( ! @{ $keys } ) {
         ${ $begi } = 0;
      }

      return delete $data->{ $key };
   }

   # check the last key
   if ( $key eq $keys->[-1] ) {
      pop @{ $keys };
      delete $indx->{ $key } if %{ $indx };

      # GC end of list
      if ( ${ $gcnt } && !defined $keys->[-1] ) {
         my $i = $#{ $keys } - 1;
         $i-- until ( defined $keys->[$i] );
         ${ $gcnt } -= $#{ $keys } - $i;
         splice @{ $keys }, $i + 1;
      }
      elsif ( ! @{ $keys } ) {
         ${ $begi } = 0;
      }

      return delete $data->{ $key };
   }

   # fill index, on-demand
   my $off = delete $indx->{ $key } // do {
      return undef unless ( exists $data->{ $key } );

      # with entire list
      ( %{ $indx } ) ? undef : do {
         $_[0]->purge() if ${ $gcnt };
         my $i; $i = ${ $begi } = 0;
         $indx->{ $_ } = $i++ for @{ $keys };
         delete $indx->{ $key };
      };

   } // do {
      # or from end of list
      ( exists $indx->{ $keys->[-1] } ) ? undef : do {
         my $i = ${ $begi } + $#{ $keys };
         for my $k ( reverse @{ $keys } ) {
            $i--, next unless ( defined $k );
            last if ( exists $indx->{ $k } );
            $indx->{ $k } = $i--;
         }
         delete $indx->{ $key };
      };

   } // do {
      # or from start of list
      my $i = ${ $begi };
      for my $k ( @{ $keys } ) {
         $i++, next unless ( defined $k );
         last if ( exists $indx->{ $k } );
         $indx->{ $k } = $i++;
      }
      delete $indx->{ $key };
   };

   # set tombstone
   $keys->[ $off - ${ $begi } ] = _TOMBSTONE;

   # GC keys if 75% or more are tombstone
   if ( ++${ $gcnt } >= ( @{ $keys } >> 2 ) * 3 ) {
      my $i; $i = ${ $begi } = ${ $gcnt } = 0;
      for my $k ( @{ $keys } ) {
         $keys->[ $i ] = $k, $indx->{ $k } = $i++ if ( defined $k );
      }
      splice @{ $keys }, $i;
   }

   delete $data->{ $key };
}

# FIRSTKEY ( )

sub FIRSTKEY {
   my ( $self ) = @_;
   my @keys = ( ${ $self->[_GCNT] } )
      ? grep defined($_), @{ $self->[_KEYS] }
      : @{ $self->[_KEYS] };

   $self->[_ITER] = sub {
      return unless @keys;
      return shift  @keys;
   };

   $self->[_ITER]->();
}

# NEXTKEY ( )

sub NEXTKEY {
   $_[0]->[_ITER]->();
}

# EXISTS ( key )

sub EXISTS {
   exists $_[0]->[_DATA]{ $_[1] };
}

# CLEAR ( )

sub CLEAR {
   my ( $data, $keys, $indx, $begi, $gcnt ) = @{ $_[0] };

   %{ $data } = @{ $keys } = %{ $indx } = ();
   ${ $begi } = ${ $gcnt } = 0;

   delete $_[0]->[_ITER];

   return;
}

# SCALAR ( )

sub SCALAR {
   @{ $_[0]->[_KEYS] } - ${ $_[0]->[_GCNT] };
}

###############################################################################
## ----------------------------------------------------------------------------
## POP, PUSH, SHIFT, UNSHIFT, SPLICE
##
###############################################################################

# POP ( )

sub POP {
   my ( $data, $keys, $indx ) = @{ $_[0] };
   my $key = pop @{ $keys };

   delete $indx->{ $key } if %{ $indx };

   # GC end of list
   if ( ! @{ $keys } ) {
      ${ $_[0]->[_BEGI] } = 0;
   }
   elsif ( !defined $keys->[-1] ) {
      my $i = $#{ $keys } - 1;
      $i-- until ( defined $keys->[$i] );
      ${ $_[0]->[_GCNT] } -= $#{ $keys } - $i;
      splice @{ $keys }, $i + 1;
   }

   defined $key ? ( $key, delete $data->{ $key } ) : ();
}

# PUSH ( key, value [, key, value, ... ] )

sub PUSH {
   my $self = shift;
   my ( $data, $keys ) = @{ $self };
   my $key;

   while ( @_ ) {
      $self->delete( $key ) if ( exists $data->{ $key = shift } );
      push @{ $keys }, "$key";
      $data->{ $key } = shift;
   }

   defined wantarray ? @{ $keys } - ${ $self->[_GCNT] } : ();
}

# SHIFT ( )

sub SHIFT {
   my ( $data, $keys, $indx ) = @{ $_[0] };
   my $key = shift @{ $keys };

   ${ $_[0]->[_BEGI] }++, delete $indx->{ $key } if %{ $indx };

   # GC start of list
   if ( ! @{ $keys } ) {
      ${ $_[0]->[_BEGI] } = 0;
   }
   elsif ( !defined $keys->[0] ) {
      my $i = 1;
      $i++ until ( defined $keys->[$i] );
      ${ $_[0]->[_BEGI] } += $i, ${ $_[0]->[_GCNT] } -= $i;
      splice @{ $keys }, 0, $i;
   }

   defined $key ? ( $key, delete $data->{ $key } ) : ();
}

# UNSHIFT ( key, value [, key, value, ... ] )

sub UNSHIFT {
   my $self = shift;
   my ( $data, $keys ) = @{ $self };
   my $key;

   if ( @_ == 2 ) {
      $self->delete( $key ) if ( exists $data->{ $key = $_[0] } );
      ${ $self->[_BEGI] }-- if %{ $self->[_INDX] };
      unshift @{ $keys }, "$key";
      $data->{ $key } = $_[1];
   }
   else {
      my ( $indx, $begi ) = @{ $self }[ _INDX, _BEGI ];
      while ( @_ ) {
         $self->delete( $key ) if ( exists $data->{ $key = $_[-2] } );
         ${ $begi }-- if %{ $indx };
         unshift @{ $keys }, "$key";
         $data->{ $key } = pop;
         pop;
      }
   }

   defined wantarray ? @{ $keys } - ${ $self->[_GCNT] } : ();
}

# SPLICE ( offset [, length [, key, value, ... ] ] )

sub SPLICE {
   my ( $self, $off  ) = ( shift, shift );
   my ( $data, $keys ) = @{ $self };
   return () unless ( defined $off );

   $self->purge() if %{ $self->[_INDX] };

   my ( $key, @ret );
   my $size = scalar @{ $keys };
   my $len  = @_ ? shift : $size - $off;

   if ( $off >= $size ) {
      $self->push( @_ ) if @_;
   }
   elsif ( abs($off) <= $size ) {
      if ( $len > 0 ) {
         $off = $off + @{ $keys } if ( $off < 0 );
         my @k = splice @{ $keys }, $off, $len;
         push(@ret, $_, delete $data->{ $_ }) for @k;
      }
      if ( @_ ) {
         my @k = splice @{ $keys }, $off;
         $self->push( @_ );
         push(@{ $keys }, "$_") for @k;
      }
   }

   return @ret;
}

###############################################################################
## ----------------------------------------------------------------------------
## _find, clone, flush, iterator, keys, pairs, values
##
###############################################################################

# _find ( { getkeys => 1 }, "query string" )
# _find ( { getvals => 1 }, "query string" )
# _find ( "query string" ) # pairs

sub _find {
   my $self   = shift;
   my $params = ref($_[0]) eq 'HASH' ? shift : {};
   my $query  = shift;

   MCE::Shared::Base::_find_hash( $self->[_DATA], $params, $query, $self );
}

# clone ( key [, key, ... ] )
# clone ( )

sub clone {
   my $self = shift;
   my $params = ref($_[0]) eq 'HASH' ? shift : {};
   my ( $begi, $gcnt ) = ( 0, 0 );
   my ( %data, @keys );

   if ( @_ ) {
      @data{ @_ } = @{ $self->[_DATA] }{ @_ };
      if ( scalar( keys %data ) == scalar( @_ ) ) {
         # @_ has zero duplicates, finish up
         @keys = map "$_", @_;
      }
      else {
         # @_ has duplicate keys, try again the long way
         my ( $DATA, $key ) = ( $self->[_DATA] );
         %data = ();
         while ( @_ ) {
            $key = shift;
            next if ( exists $data{ $key } );
            push @keys, "$key";
            $data{ $key } = $DATA->{ $key };
         }
      }
   }
   else {
      @keys = ( ${ $self->[_GCNT] } )
         ? grep defined($_), @{ $self->[_KEYS] }
         : @{ $self->[_KEYS] };

      @data{ @keys } = @{ $self->[_DATA] }{ @keys };
   }

   $self->clear() if $params->{'flush'};

   bless [ \%data, \@keys, {}, \$begi, \$gcnt ], ref $self;
}

# flush ( key [, key, ... ] )
# flush ( )

sub flush {
   shift()->clone( { flush => 1 }, @_ );
}

# iterator ( key [, key, ... ] )
# iterator ( "query string" )
# iterator ( )

sub iterator {
   my ( $self, @keys ) = @_;
   my $data = $self->[_DATA];

   if ( ! @keys ) {
      @keys = ( ${ $self->[_GCNT] } )
         ? grep defined($_), @{ $self->[_KEYS] }
         : @{ $self->[_KEYS] };
   }
   elsif ( @keys == 1 && $keys[0] =~ /^(?:key|val)[ ]+\S\S?[ ]+\S/ ) {
      @keys = $self->keys($keys[0]);
   }

   return sub {
      return unless @keys;
      my $key = shift @keys;
      return ( $key => $data->{ $key } );
   };
}

# keys ( key [, key, ... ] )
# keys ( "query string" )
# keys ( )

sub keys {
   my $self = shift;

   if ( @_ == 1 && $_[0] =~ /^(?:key|val)[ ]+\S\S?[ ]+\S/ ) {
      $self->_find({ getkeys => 1 }, @_);
   }
   else {
      if ( wantarray ) {
         my $data = $self->[_DATA];
         @_ ? map { exists $data->{ $_ } ? $_ : undef } @_
            : ( ${ $self->[_GCNT] } )
                  ? grep defined($_), @{ $self->[_KEYS] }
                  : @{ $self->[_KEYS] };
      }
      else {
         @{ $self->[_KEYS] } - ${ $self->[_GCNT] };
      }
   }
}

# pairs ( key [, key, ... ] )
# pairs ( "query string" )
# pairs ( )

sub pairs {
   my $self = shift;

   if ( @_ == 1 && $_[0] =~ /^(?:key|val)[ ]+\S\S?[ ]+\S/ ) {
      $self->_find(@_);
   }
   else {
      if ( wantarray ) {
         my $data = $self->[_DATA];
         @_ ? map { $_ => $data->{ $_ } } @_
            : map { $_ => $data->{ $_ } } ( ${ $self->[_GCNT] } )
                  ? grep defined($_), @{ $self->[_KEYS] }
                  : @{ $self->[_KEYS] };
      }
      else {
         @{ $self->[_KEYS] } - ${ $self->[_GCNT] };
      }
   }
}

# values ( key [, key, ... ] )
# values ( "query string" )
# values ( )

sub values {
   my $self = shift;

   if ( @_ == 1 && $_[0] =~ /^(?:key|val)[ ]+\S\S?[ ]+\S/ ) {
      $self->_find({ getvals => 1 }, @_);
   }
   else {
      if ( wantarray ) {
         @_ ? @{ $self->[_DATA] }{ @_ }
            : @{ $self->[_DATA] }{ ( ${ $self->[_GCNT] } )
                  ? grep defined($_), @{ $self->[_KEYS] }
                  : @{ $self->[_KEYS] }
              };
      }
      else {
         @{ $self->[_KEYS] } - ${ $self->[_GCNT] };
      }
   }
}

###############################################################################
## ----------------------------------------------------------------------------
## mdel, mexists, mget, mset, purge, sort
##
###############################################################################

# mdel ( key [, key, ... ] )

sub mdel {
   my $self = shift;
   my ( $data, $cnt, $key ) = ( $self->[_DATA], 0 );

   while ( @_ ) {
      $key = shift;
      $cnt++, $self->delete( $key ) if ( exists $data->{ $key } );
   }

   $cnt;
}

# mexists ( key [, key, ... ] )

sub mexists {
   my $self = shift;
   my $data = $self->[_DATA];
   my $key;

   while ( @_ ) {
      $key = shift;
      return '' unless ( exists $data->{ $key } );
   }

   1;
}

# mget ( key [, key, ... ] )

sub mget {
   my $self = shift;

   @_ ? @{ $self->[_DATA] }{ @_ } : ();
}

# mset ( key, value [, key, value, ... ] )

sub mset {
   my $self = shift;
   my ( $data, $keys ) = @{ $self };
   my $key;

   while ( @_ ) {
      push @{ $keys }, "$key" unless ( exists $data->{ $key = shift } );
      $data->{ $key } = shift;
   }

   defined wantarray ? @{ $keys } - ${ $self->[_GCNT] } : ();
}

# purge ( )

sub purge {
   my ( $data, $keys, $indx, $begi, $gcnt ) = @{ $_[0] };

   # TOMBSTONES, in-place purging for minimum memory consumption.

   if ( ${ $gcnt } ) {
      my $i = 0;
      for my $key ( @{ $keys } ) {
         $keys->[ $i++ ] = $key if ( defined $key );
      }
      splice @{ $keys }, $i;
   }

   ${ $begi } = ${ $gcnt } = 0;
   %{ $indx } = ();

   return;
}

# sort ( "BY key [ ASC | DESC ] [ ALPHA ]" )
# sort ( "BY val [ ASC | DESC ] [ ALPHA ]" )
# sort ( "[ ASC | DESC ] [ ALPHA ]" ) # same as "BY val ..."

sub sort {
   my ( $self, $request ) = @_;
   my ( $by_key, $alpha, $desc ) = ( 0, 0, 0 );

   if ( length $request ) {
      $by_key = 1 if ( $request =~ /\bkey\b/i );
      $alpha  = 1 if ( $request =~ /\balpha\b/i );
      $desc   = 1 if ( $request =~ /\bdesc\b/i );
   }

   # Return sorted keys, leaving the data intact.

   if ( defined wantarray ) {
      if ( $by_key ) {                                # by key
         if ( $alpha ) { ( $desc )
          ? CORE::sort { $b cmp $a } $self->keys
          : CORE::sort { $a cmp $b } $self->keys;
         }
         else { ( $desc )
          ? CORE::sort { $b <=> $a } $self->keys
          : CORE::sort { $a <=> $b } $self->keys;
         }
      }
      else {                                          # by value
         my $d = $self->[_DATA];
         if ( $alpha ) { ( $desc )
          ? CORE::sort { $d->{$b} cmp $d->{$a} } $self->keys
          : CORE::sort { $d->{$a} cmp $d->{$b} } $self->keys;
         }
         else { ( $desc )
          ? CORE::sort { $d->{$b} <=> $d->{$a} } $self->keys
          : CORE::sort { $d->{$a} <=> $d->{$b} } $self->keys;
         }
      }
   }

   # Sort keys in-place otherwise, in void context.

   elsif ( $by_key ) {                                # by key
      if ( $alpha ) { ( $desc )
       ? $self->_reorder( CORE::sort { $b cmp $a } $self->keys )
       : $self->_reorder( CORE::sort { $a cmp $b } $self->keys );
      }
      else { ( $desc )
       ? $self->_reorder( CORE::sort { $b <=> $a } $self->keys )
       : $self->_reorder( CORE::sort { $a <=> $b } $self->keys );
      }
   }
   else {                                             # by value
      my $d = $self->[_DATA];
      if ( $alpha ) { ( $desc )
       ? $self->_reorder( CORE::sort { $d->{$b} cmp $d->{$a} } $self->keys )
       : $self->_reorder( CORE::sort { $d->{$a} cmp $d->{$b} } $self->keys );
      }
      else { ( $desc )
       ? $self->_reorder( CORE::sort { $d->{$b} <=> $d->{$a} } $self->keys )
       : $self->_reorder( CORE::sort { $d->{$a} <=> $d->{$b} } $self->keys );
      }
   }
}

sub _reorder {
   my $self = shift;
   @{ $self->[_KEYS] } = @_;

   ${ $self->[_BEGI] } = ${ $self->[_GCNT] } = 0;
   %{ $self->[_INDX] } = ();

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Sugar API, mostly resembles http://redis.io/commands#string primitives.
##
###############################################################################

# append ( key, string )

sub append {
   my ( $key, $data ) = ( $_[1], @{ $_[0] } );
   push @{ $_[0]->[_KEYS] }, "$key" unless ( exists $data->{ $key } );

   length( $data->{ $key } .= $_[2] // '' );
}

# decr ( key )

sub decr {
   my ( $key, $data ) = ( $_[1], @{ $_[0] } );
   push @{ $_[0]->[_KEYS] }, "$key" unless ( exists $data->{ $key } );

   --$data->{ $key };
}

# decrby ( key, number )

sub decrby {
   my ( $key, $data ) = ( $_[1], @{ $_[0] } );
   push @{ $_[0]->[_KEYS] }, "$key" unless ( exists $data->{ $key } );

   $data->{ $key } -= $_[2] || 0;
}

# incr ( key )

sub incr {
   my ( $key, $data ) = ( $_[1], @{ $_[0] } );
   push @{ $_[0]->[_KEYS] }, "$key" unless ( exists $data->{ $key } );

   ++$data->{ $key };
}

# incrby ( key, number )

sub incrby {
   my ( $key, $data ) = ( $_[1], @{ $_[0] } );
   push @{ $_[0]->[_KEYS] }, "$key" unless ( exists $data->{ $key } );

   $data->{ $key } += $_[2] || 0;
}

# getdecr ( key )

sub getdecr {
   my ( $key, $data ) = ( $_[1], @{ $_[0] } );
   push @{ $_[0]->[_KEYS] }, "$key" unless ( exists $data->{ $key } );

   $data->{ $key }-- // 0;
}

# getincr ( key )

sub getincr {
   my ( $key, $data ) = ( $_[1], @{ $_[0] } );
   push @{ $_[0]->[_KEYS] }, "$key" unless ( exists $data->{ $key } );

   $data->{ $key }++ // 0;
}

# getset ( key, value )

sub getset {
   my ( $key, $data ) = ( $_[1], @{ $_[0] } );
   push @{ $_[0]->[_KEYS] }, "$key" unless ( exists $data->{ $key } );

   my $old = $data->{ $key };
   $data->{ $key } = $_[2];

   $old;
}

# len ( key )
# len ( )

sub len {
   ( defined $_[1] )
      ? length $_[0]->[_DATA]{ $_[1] }
      : @{ $_[0]->[_KEYS] } - ${ $_[0]->[_GCNT] };
}

{
   no strict 'refs';

   *{ __PACKAGE__.'::new'     } = \&TIEHASH;
   *{ __PACKAGE__.'::set'     } = \&STORE;
   *{ __PACKAGE__.'::get'     } = \&FETCH;
   *{ __PACKAGE__.'::delete'  } = \&DELETE;
   *{ __PACKAGE__.'::exists'  } = \&EXISTS;
   *{ __PACKAGE__.'::clear'   } = \&CLEAR;
   *{ __PACKAGE__.'::pop'     } = \&POP;
   *{ __PACKAGE__.'::push'    } = \&PUSH;
   *{ __PACKAGE__.'::shift'   } = \&SHIFT;
   *{ __PACKAGE__.'::unshift' } = \&UNSHIFT;
   *{ __PACKAGE__.'::splice'  } = \&SPLICE;

   *{ __PACKAGE__.'::del'     } = \&delete;
   *{ __PACKAGE__.'::merge'   } = \&mset;
   *{ __PACKAGE__.'::vals'    } = \&values;
}

# For on-demand hash-like dereferencing.

package MCE::Shared::Ordhash::_href;

sub TIEHASH { $_[1] }

1;

__END__

###############################################################################
## ----------------------------------------------------------------------------
## Module usage.
##
###############################################################################

=head1 NAME

MCE::Shared::Ordhash - An ordered hash class featuring tombstone deletion

=head1 VERSION

This document describes MCE::Shared::Ordhash version 1.700

=head1 SYNOPSIS

   # non-shared
   use MCE::Shared::Ordhash;

   my $oh = MCE::Shared::Ordhash->new( @pairs );

   # shared
   use MCE::Shared;

   my $oh = MCE::Shared->ordhash( @pairs );

   # oo interface
   $val   = $oh->set( $key, $val );
   $val   = $oh->get( $key );
   $val   = $oh->delete( $key );              # del is an alias for delete
   $bool  = $oh->exists( $key );
   void   = $oh->clear();
   $len   = $oh->len();                       # scalar keys %{ $oh }
   $len   = $oh->len( $key );                 # length $oh->{ $key }
   @pair  = $oh->pop();
   $len   = $oh->push( @pairs );
   @pair  = $oh->shift();
   $len   = $oh->unshift( @pairs );
   %pairs = $oh->splice( $offset, $length, @pairs );

   $oh2   = $oh->clone( @keys );              # @keys is optional
   $oh3   = $oh->flush( @keys );
   $iter  = $oh->iterator( @keys );           # ($key, $val) = $iter->()
   @keys  = $oh->keys( @keys );
   %pairs = $oh->pairs( @keys );
   @vals  = $oh->values( @keys );             # vals is an alias for values

   $cnt   = $oh->mdel( @keys );
   @vals  = $oh->mget( @keys );
   $bool  = $oh->mexists( @keys );            # true if all keys exists
   $len   = $oh->mset( $key/$val pairs );     # merge is an alias for mset

   @vals  = $oh->sort();                      # by val $a <=> $b default
   @vals  = $oh->sort( "desc" );              # by val $b <=> $a
   @vals  = $oh->sort( "alpha" );             # by val $a cmp $b
   @vals  = $oh->sort( "alpha desc" );        # by val $b cmp $a

   @vals  = $oh->sort( "key" );               # by key $a <=> $b
   @vals  = $oh->sort( "key desc" );          # by key $b <=> $a
   @vals  = $oh->sort( "key alpha" );         # by key $a cmp $b
   @vals  = $oh->sort( "key alpha desc" );    # by key $b cmp $a

   # search capability key/val { =~ !~ eq ne lt le gt ge == != < <= > >= }
   # key/val means to match against actual key/val respectively
   # do not add quotes inside the string unless intended literally
   # do not mix :AND(s) and :OR(s) together

   @keys  = $oh->keys( "key =~ /$pattern/i" );
   @keys  = $oh->keys( "key !~ /$pattern/i" );
   @keys  = $oh->keys( "val =~ /$pattern/i" );
   @keys  = $oh->keys( "val !~ /$pattern/i" );

   %pairs = $oh->pairs( "key == $number" );
   %pairs = $oh->pairs( "key != $number :AND val > 100" );
   %pairs = $oh->pairs( "key <  $number :OR key > $number" );
   %pairs = $oh->pairs( "val <= $number" );
   %pairs = $oh->pairs( "val >  $number" );
   %pairs = $oh->pairs( "val >= $number" );

   @vals  = $oh->values( "key eq $string" );
   @vals  = $oh->values( "key ne $string with space" );
   @vals  = $oh->values( "key lt $string :OR val =~ /$pat1|$pat2/" );
   @vals  = $oh->values( "val le $string :AND val eq foo bar" );
   @vals  = $oh->values( "val gt $string" );
   @vals  = $oh->values( "val ge $string" );

   # sugar methods without having to call set/get explicitly

   $len   = $oh->append( $key, $string );     #   $val .= $string
   $val   = $oh->decr( $key );                # --$val
   $val   = $oh->decrby( $key, $number );     #   $val -= $number
   $val   = $oh->getdecr( $key );             #   $val--
   $val   = $oh->getincr( $key );             #   $val++
   $val   = $oh->incr( $key );                # ++$val
   $val   = $oh->incrby( $key, $number );     #   $val += $number
   $old   = $oh->getset( $key, $new );        #   $o = $v, $v = $n, $o

=head1 DESCRIPTION

This module implements an ordered hash featuring tombstone deletion,
inspired by the L<Hash::Ordered> module. An ordered hash means the key
insertion order is preserved.

It provides C<splice>, sorting, plus extra capabilities for use with
L<MCE::Shared::Minidb>. Tombstone deletion is further optimized to not
impact C<store>, C<push>, C<unshift>, and C<merge>. Tombstones are
purged in-place for lesser memory consumption. In addition, C<pop> and
C<shift> run optimally when an index is present. The optimization also
applies to forward and reverse deletes.

The end result is achieving a new level of performance, for a pure-Perl
ordered hash implementation.

=head1 SYNTAX for QUERY STRING

Several methods in C<MCE::Shared::Ordhash> take a query string for an argument.
The format of the string is quoteless. Therefore, any quotes inside the string
is treated literally.

   o Basic demonstration: @keys = $oh->keys( "val =~ /pattern/" );
   o Supported operators: =~ !~ eq ne lt le gt ge == != < <= > >=
   o Multiple expressions are delimited by :AND or :OR.

     "key =~ /pattern/i :AND val =~ /pattern/i"
     "key =~ /pattern/i :AND val eq foo bar"     # val eq "foo bar"
     "val eq foo baz :OR key !~ /pattern/i"

     * key matches on keys in the hash
     * val matches on values

=over 3

=item * The modifiers C<:AND> and C<:OR> may be mixed case. e.g. C<:And>

=item * Mixing C<:AND> and C<:OR> in the query is not supported.

=back

=head1 API DOCUMENTATION

This module involves TIE when accessing the object via hash-like behavior.
Both non-shared and shared instances are impacted if doing so. Although likely
fast enough for many use cases, use the OO interface if better performance is
desired.

=over 3

=item new ( key, value [, key, value, ... ] )

Constructs a new object, with an optional list of key-value pairs.

   # non-shared
   use MCE::Shared::Ordhash;

   $oh = MCE::Shared::Ordhash->new( @pairs );
   $oh = MCE::Shared::Ordhash->new( );

   # shared
   use MCE::Shared;

   $oh = MCE::Shared->ordhash( @pairs );
   $oh = MCE::Shared->ordhash( );

=item clear

Removes all key-value pairs from the hash.

   $oh->clear;
   %{$oh} = ();

=item clone ( key [, key, ... ] )

Creates a shallow copy, a C<MCE::Shared::Ordhash> object. It returns an exact
copy if no arguments are given. Otherwise, the object includes only the given
keys in the same order. Keys that do not exist in the hash will have the
C<undef> value.

   $oh2 = $oh->clone( "key1", "key2" );
   $oh2 = $oh->clone;

=item delete ( key )

Deletes and returns the value by given key or C<undef> if the key does not
exists in the hash.

   $val = $oh->delete( "some_key" );
   $val = delete $oh->{ "some_key" };

=item del

C<del> is an alias for C<delete>.

=item exists ( key )

Determines if a key exists in the hash.

   if ( $oh->exists( "some_key" ) ) { ... }
   if ( exists $oh->{ "some_key" } ) { ... }

=item flush ( key [, key, ... ] )

Same as C<clone>. Though, clears all existing items before returning.

=item get ( key )

Gets the value of a hash key or C<undef> if the key does not exists.

   $val = $oh->get( "some_key" );
   $val = $oh->{ "some_key" };

=item iterator ( key [, key, ... ] )

Returns a code reference for iterating a list of key-value pairs stored in
the hash when no arguments are given. Otherwise, returns a code reference for
iterating the given keys in the same order. Keys that do not exist will have
the C<undef> value.

The list of keys to return is set when the closure is constructed. Later keys
added to the hash are not included. Subsequently, the C<undef> value is
returned for deleted keys.

   $iter = $oh->iterator;
   $iter = $oh->iterator( "key1", "key2" );

   while ( my ( $key, $val ) = $iter->() ) {
      ...
   }

=item iterator ( "query string" )

Returns a code reference for iterating a list of key-value pairs that match
the given criteria. It returns an empty list if the search found nothing.
The syntax for the C<query string> is described above.

   $iter = $oh->iterator( "val eq some_value" );
   $iter = $oh->iterator( "key eq some_key :AND val =~ /sun|moon|air|wind/" );
   $iter = $oh->iterator( "val eq sun :OR val eq moon :OR val eq foo" );
   $iter = $oh->iterator( "key =~ /$pattern/" );

   while ( my ( $key, $val ) = $iter->() ) {
      ...
   }

=item keys ( key [, key, ...] )

Returns hash keys in the same insertion order when no arguments are given.
Otherwise, returns the given keys in the same order. Keys that do not exist
will have the C<undef> value. In scalar context, returns the size of the hash.

   @keys = $oh->keys;
   @keys = $oh->keys( "key1", "key2" );
   $len  = $oh->keys;

=item keys ( "query string" )

Returns only keys that match the given criteria. It returns an empty list
if the search found nothing. The syntax for the C<query string> is described
above. In scalar context, returns the size of the resulting list.

   @keys = $oh->keys( "val eq some_value" );
   @keys = $oh->keys( "key eq some_key :AND val =~ /sun|moon|air|wind/" );
   @keys = $oh->keys( "val eq sun :OR val eq moon :OR val eq foo" );
   $len  = $oh->keys( "key =~ /$pattern/" );

=item len ( key )

Returns the size of the hash when no arguments are given. For the given key,
returns the length of the value stored at key or the C<undef> value if the
key does not exists.

   $size = $oh->len;
   $len  = $oh->len( "key1" );
   $len  = length $oh->{ "key1" };

=item mdel ( key [, key, ... ] )

Deletes one or more keys in the hash and returns the number of keys deleted.
A given key which does not exist in the hash is not counted.

   $cnt = $oh->mdel( "key1", "key2" );

=item mexists ( key [, key, ... ] )

Returns a true value if all given keys exists in the hash. A false value is
returned otherwise.

   if ( $oh->mexists( "key1", "key2" ) ) { ... }

=item mget ( key [, key, ... ] )

Gets the values of all given keys. It returns C<undef> for keys which do not
exists in the hash.

   ( $val1, $val2 ) = $oh->mget( "key1", "key2" );

=item mset ( key, value [, key, value, ... ] )

Sets multiple key-value pairs in a hash and returns the number of keys stored
in the hash.

   $len = $oh->mset( "key1" => "val1", "key2" => "val2" );

=item merge

C<merge> is an alias for C<mset>.

=item pairs ( key [, key, ... ] )

Returns key-value pairs in the same insertion order when no arguments are given.
Otherwise, returns key-value pairs for the given keys in the same order. Keys
that do not exist will have the C<undef> value. In scalar context, returns the
size of the hash.

   @pairs = $oh->pairs;
   @pairs = $oh->pairs( "key1", "key2" );
   $len   = $oh->pairs;

=item pairs ( "query string" )

Returns only key-value pairs that match the given criteria. It returns an
empty list if the search found nothing. The syntax for the C<query string> is
described above. In scalar context, returns the size of the resulting list.

   @pairs = $oh->pairs( "val eq some_value" );
   @pairs = $oh->pairs( "key eq some_key :AND val =~ /sun|moon|air|wind/" );
   @pairs = $oh->pairs( "val eq sun :OR val eq moon :OR val eq foo" );
   $len   = $oh->pairs( "key =~ /$pattern/" );

=item pop

Removes and returns the last key-value pair or value in scalar context of the
ordered hash. If there are no keys in the hash, returns the undefined value.

   ( $key, $val ) = $oh->pop;

   $val = $oh->shift;

=item purge

A utility method for purging any *tombstones* in the keys array. It also
resets a couple counters internally. Call this method before serializing
to a file, which is the case in C<MCE::Shared::Minidb>.

   $oh->purge;

=item push ( key, value [, key, value, ... ] )

Appends one or multiple key-value pairs to the tail of the ordered hash and
returns the new length. Any keys already existing in the hash are re-inserted
with the new values.

   $len = $oh->push( "key1", "val1", "key2", "val2" );

=item set ( key, value )

Sets the value of the given hash key and returns its new value.

   $val = $oh->set( "key", "value" );
   $val = $oh->{ "key" } = "value";

=item shift

Removes and returns the first key-value pair or value in scalar context of the
ordered hash. If there are no keys in the hash, returns the undefined value.

   ( $key, $val ) = $oh->shift;

   $val = $oh->shift;

=item sort ( "BY key [ ASC | DESC ] [ ALPHA ]" )

=item sort ( "BY val [ ASC | DESC ] [ ALPHA ]" )

Returns sorted keys in list context, leaving the elements intact. In void
context, sorts the hash in-place. By default, sorting is numeric and applied
to values when no arguments are given.

   @keys = $oh->sort( "BY val" );

   $oh->sort();

If the keys or values contain string values and you want to sort them
lexicographically, specify the C<ALPHA> modifier.

   @keys = $oh->sort( "BY key ALPHA" );

   $oh->sort( "BY val ALPHA" );

The default is C<ASC> for sorting the hash from small to large. In order to
sort the hash from large to small, specify the C<DESC> modifier.

   @keys = $oh->sort( "BY val DESC ALPHA" );

   $oh->sort( "BY key DESC ALPHA" );

=item splice ( offset [, length [, key, value, ... ] ] )

Removes the key-value pairs designated by C<offset> and C<length> from the
ordered hash, and replaces them with C<key-value pairs>, if any. The behavior
is similar to the Perl C<splice> function.

   @pairs = $oh->splice( 20, 2, @pairs );
   @pairs = $oh->splice( 20, 2 );
   @pairs = $oh->splice( 20 );

=item unshift ( key, value [, key, value, ... ] )

Prepends one or multiple key-value pairs to the head of the ordered hash and
returns the new length. Any keys already existing in the hash are re-inserted
with the new values.

   $len = $oh->unshift( "key1", "val1", "key2", "val2" );

=item values ( key [, key, ... ] )

Returns hash values in the same insertion order when no arguments are given.
Otherwise, returns values for the given keys in the same order. Keys that do
not exist will have the C<undef> value. In scalar context, returns the size
of the hash.

   @vals = $oh->values;
   @vals = $oh->values( "key1", "key2" );
   $len  = $oh->values;

=item values ( "query string" )

Returns only values that match the given criteria. It returns an empty list
if the search found nothing. The syntax for the C<query string> is described
above. In scalar context, returns the size of the resulting list.

   @vals = $oh->values( "val eq some_value" );
   @vals = $oh->values( "key eq some_key :AND val =~ /sun|moon|air|wind/" );
   @vals = $oh->values( "val eq sun :OR val eq moon :OR val eq foo" );
   $len  = $oh->values( "key =~ /$pattern/" );

=item vals

C<vals> is an alias for C<values>.

=back

=head1 SUGAR METHODS

This module is equipped with sugar methods to not have to call C<set>
and C<get> explicitly. The API resembles a subset of the Redis primitives
L<http://redis.io/commands#strings> with key representing the hash key.

=over 3

=item append ( key, string )

Appends a value to a key and returns its new length.

   $len = $oh->append( $key, "foo" );

=item decr ( key )

Decrements the value of a key by one and returns its new value.

   $num = $oh->decr( $key );

=item decrby ( key, number )

Decrements the value of a key by the given number and returns its new value.

   $num = $oh->decrby( $key, 2 );

=item getdecr ( key )

Decrements the value of a key by one and returns its old value.

   $old = $oh->getdecr( $key );

=item getincr ( key )

Increments the value of a key by one and returns its old value.

   $old = $oh->getincr( $key );

=item getset ( key, value )

Sets the value of a key and returns its old value.

   $old = $oh->getset( $key, "baz" );

=item incr ( key )

Increments the value of a key by one and returns its new value.

   $num = $oh->incr( $key );

=item incrby ( key, number )

Increments the value of a key by the given number and returns its new value.

   $num = $oh->incrby( $key, 2 );

=back

=head1 CREDITS

Many thanks to David Golden for Hash::Ordered. This implementation is inspired
by L<Hash::Ordered> v0.009.

=head1 MOTIVATION

I wanted an ordered hash implementation for use with MCE::Shared without any
side effects. For example, linear scans, slow deletes, or excessive memory
consumption. The closest module on CPAN to pass in this regard is
L<Hash::Ordered> by David Golden.

MCE::Shared has only one shared-manager process which is by design. Therefore,
refactored tombstone deletion with extras for lesser impact to the rest of the
library. This module differs in personality from Hash::Ordered mainly for
compatibility with the various classes included with MCE::Shared.

The following simulates a usage pattern inside L<MCE::Hobo> involving random
key deletion. For example, an application joining a list of Hobos provided by
C<MCE::Hobo->list_joinable>.

   use MCE::Shared::Ordhash;
   use List::Util 'shuffle';
   use Time::HiRes 'time';

   srand 1618;

   my $oh = MCE::Shared::Ordhash->new();
   my $num_keys = 200000;
   my $start = time();

   $oh->set($_,$_) for 1 .. $num_keys;

   for ( shuffle $oh->keys ) {
      $oh->delete($_);
   }

   printf "duration: %7.03f secs\n", time() - $start;

Both the runtime and memory consumption are captured for the demonstration.
Result for MCE::Shared::Hash is included for seeing how much longer a given
ordered hash implementation takes in comparison.

   for ( shuffle $oh->keys ) { $oh->delete($_) }

   0.362 secs.  55 MB  MCE::Shared::Hash; unordered hash
   0.626 secs. 126 MB  Tie::Hash::Indexed; (XS) ordered hash
   0.720 secs.  74 MB  MCE::Shared::Ordhash; ordered hash **
   1.032 secs.  74 MB  Hash::Ordered; ordered hash
   1.756 secs. 161 MB  Tie::LLHash; ordered hash
    > 42 mins.  79 MB  Tie::IxHash; ordered hash (stopped)

Using the same demonstration above, another usage pattern inside L<MCE::Hobo>
involves orderly hash-key deletion. For example, waiting for and joining all
Hobos provided by C<MCE::Hobo->list>.

   for ( $oh->keys ) { $oh->delete($_) }

   0.332 secs.  55 MB  MCE::Shared::Hash; unordered hash
   0.447 secs.  67 MB  MCE::Shared::Ordhash; ordered hash **
   0.503 secs. 126 MB  Tie::Hash::Indexed; (XS) ordered hash
   0.802 secs.  74 MB  Hash::Ordered; ordered hash
   1.337 secs. 161 MB  Tie::LLHash; ordered hash
    > 42 mins.  79 MB  Tie::IxHash; ordered hash (stopped)

No matter if orderly or randomly, even backwards, hash-key deletion in
C<MCE::Shared::Ordhash> performs reasonably well.

The following provides the construction used for the modules mentioned.
Basically, key setting and deletion is through the OO interface for fair
comparison.

   my $oh = Hash::Ordered->new();
      $oh->set($_,$_);   $oh->keys;  $oh->delete($_);

   my $oh = tie my %hash, 'Tie::Hash::Indexed';
      $oh->STORE($_,$_); keys %hash; $oh->DELETE($_);

   my $oh = Tie::IxHash->new();
      $oh->STORE($_,$_); $oh->Keys;  $oh->DELETE($_);

   my $oh = tie my %hash, 'Tie::LLHash';
      $oh->last($_,$_);  keys %hash; $oh->DELETE($_);

=head1 SEE ALSO

=over 3

=item * L<Hash::Ordered>

=item * L<Tie::Hash::Indexed>

=item * L<Tie::IxHash>

=item * L<Tie::LLHash>

=back

=head1 INDEX

L<MCE|MCE>, L<MCE::Core>, L<MCE::Shared>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

