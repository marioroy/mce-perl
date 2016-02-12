###############################################################################
## ----------------------------------------------------------------------------
## Ordered-hash helper class.
##
## An optimized ordered hash implementation inspired by Hash::Ordered v0.009.
##
## 1. Added splice, sorting, plus extra capabilities for use with MCE::Hobo
##    and MCE::Shared::Minidb.
##
## 2. Revised tombstone deletion to not impact store, push, unshift, and merge.
##    Tombstones are purged in-place for overall lesser memory consumption.
##    Also, minimized overhead in pop and shift when an index is present.
##    Ditto for forward and reverse deletes.
##
## 3. Provides support for hash-like dereferencing, for Perlish behavior.
##
###############################################################################

package MCE::Shared::Ordhash;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized numeric );

our $VERSION = '1.699_011';

## no critic (Subroutines::ProhibitExplicitReturnUndef)
## no critic (TestingAndDebugging::ProhibitNoStrict)

use MCE::Shared::Base;
use bytes;

use constant { _TOMBSTONE => \1 };  # ref to arbitrary scalar

use constant {
   _DATA => 0,  # unordered data
   _KEYS => 1,  # ordered ids with keys
   _INDX => 2,  # index into _KEYS (on demand, no impact to STORE)
   _BEGI => 3,  # begin ordered id for optimized shift/unshift
   _GCNT => 4,  # garbage count
   _ITER => 5,  # for tied hash support
};

use overload (
   q("")    => \&MCE::Shared::Base::_stringify,
   q(0+)    => \&MCE::Shared::Base::_numify,
   q(%{})   => sub {
      tie my %h, 'MCE::Shared::Ordhash::_href', $_[0];
      \%h;
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
   my ( $key, %data, @keys );

   while ( @_ ) {
      $key = shift;
      push @keys, "$key" unless exists $data{ $key };
      $data{ $key } = shift;
   }

   bless [ \%data, \@keys, undef, 0, 0 ], $class;
}

# STORE ( key, value )

sub STORE {
   my ( $self, $key ) = @_;  # $_[2] is not copied in case it's large
   push @{ $self->[_KEYS] }, "$key" unless exists $self->[_DATA]{ $key };

   $self->[_DATA]{ $key } = $_[2];
}

# FETCH ( key )

sub FETCH {
   $_[0]->[_DATA]{ $_[1] };
}

# DELETE ( key )

sub DELETE {
   my ( $self, $key ) = @_;

   return undef if ( !exists $self->[_DATA]{ $key } );

   my $keys = $self->[_KEYS];

   # check the first key
   if ( $key eq $keys->[0] ) {
      shift @{ $keys };
      $self->[_BEGI]++, delete $self->[_INDX]{ $key } if $self->[_INDX];

      # GC start of list
      if ( ref $keys->[0] ) {
         my $i = 1;
         $i++ while ( ref $keys->[$i] );
         $self->[_BEGI] += $i, $self->[_GCNT] -= $i;
         splice @{ $keys }, 0, $i;
      }

      $self->[_BEGI] = 0, $self->[_INDX] = undef unless @{ $keys };

      return delete $self->[_DATA]{ $key };
   }

   # perhaps the last key
   elsif ( $key eq $keys->[-1] ) {
      pop @{ $keys };
      delete $self->[_INDX]{ $key } if $self->[_INDX];

      # GC end of list
      if ( ref $keys->[-1] ) {
         my $i = $#{ $keys } - 1;
         $i-- while ( ref $keys->[$i] );
         $self->[_GCNT] -= $#{ $keys } - $i;
         splice @{ $keys }, $i + 1;
      }

      $self->[_BEGI] = 0, $self->[_INDX] = undef unless @{ $keys };

      return delete $self->[_DATA]{ $key };
   }

   # make index, on-demand
   my $indx = $self->[_INDX] ||
   do {
      my ( $i, %indx ) = ( 0 );
      $indx{ $_ } = $i++ for @{ $self->[_KEYS] };
      $self->[_INDX] = \%indx;
   };

   # fill index, on-demand
   my $id = delete $indx->{ $key } //
   do {
      ( exists $indx->{ $keys->[-1] } ) ? undef : do {
         # from end of list
         my $i = $self->[_BEGI] + $#{ $keys };
         for my $k ( reverse @{ $keys } ) {
            $i--, next if ref( $k );
            last if exists $indx->{ $k };
            $indx->{ $k } = $i--;
         }
         delete $indx->{ $key };
      };
   } //
   do {
      # from start of list
      my $i = $self->[_BEGI];
      for my $k ( @{ $keys } ) {
         $i++, next if ref( $k );
         last if exists $indx->{ $k };
         $indx->{ $k } = $i++;
      }
      delete $indx->{ $key };
   };

   # place tombstone
   $keys->[ $id - $self->[_BEGI] ] = _TOMBSTONE;

   # GC keys/indx if more than half are tombstone
   if ( ++$self->[_GCNT] > ( @{ $keys } >> 1 ) ) {
      my $i = 0;
      for my $k ( @{ $keys } ) {
         $keys->[ $i ] = $k, $indx->{ $k } = $i++ unless ref( $k );
      }
      $self->[_BEGI] = $self->[_GCNT] = 0;
      splice @{ $keys }, $i;
   }

   delete $self->[_DATA]{ $key };
}

# FIRSTKEY ( )

sub FIRSTKEY {
   my ( $self ) = @_;
   my @keys = grep !ref($_), @{ $self->[_KEYS] };

   $self->[_ITER] = sub {
      return unless @keys;
      return shift(@keys);
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
   my ( $self ) = @_;

   %{ $self->[_DATA] } = @{ $self->[_KEYS] } = ( );
      $self->[_BEGI]   =    $self->[_GCNT]   =  0 ;
      $self->[_INDX]   = undef;

   delete $self->[_ITER] if defined $self->[_ITER];

   return;
}

# SCALAR ( )

sub SCALAR {
   @{ $_[0]->[_KEYS] } - $_[0]->[_GCNT];
}

###############################################################################
## ----------------------------------------------------------------------------
## POP, PUSH, SHIFT, UNSHIFT, SPLICE
##
###############################################################################

# POP ( )

sub POP {
   my $self = shift;
   my $keys = $self->[_KEYS];
   my $key  = pop @{ $keys };

   return unless defined $key;

   if ( $self->[_INDX] ) {
      delete $self->[_INDX]{ $key };

      # GC end of list
      if ( ref $keys->[-1] ) {
         my $i = $#{ $keys } - 1;
         $i-- while ( ref $keys->[$i] );
         $self->[_GCNT] -= $#{ $keys } - $i;
         splice @{ $keys }, $i + 1;
      }

      $self->[_BEGI] = 0, $self->[_INDX] = undef unless @{ $keys };
   }

   return $key, delete $self->[_DATA]{ $key };
}

# PUSH ( key, value [, key, value, ... ] )

sub PUSH {
   my $self = shift;
   my ( $data, $keys ) = @{ $self };

   while ( @_ ) {
      my ( $key, $val ) = splice( @_, 0, 2 );
      $self->DELETE($key) if exists $data->{ $key };
      push @{ $keys }, "$key";
      $data->{ $key } = $val;
   }

   @{ $keys } - $self->[_GCNT];
}

# SHIFT ( )

sub SHIFT {
   my $self = shift;
   my $keys = $self->[_KEYS];
   my $key  = shift @{ $keys };

   return unless defined $key;

   if ( $self->[_INDX] ) {
      $self->[_BEGI]++, delete $self->[_INDX]{ $key };

      # GC start of list
      if ( ref $keys->[0] ) {
         my $i = 1;
         $i++ while ( ref $keys->[$i] );
         $self->[_BEGI] += $i, $self->[_GCNT] -= $i;
         splice @{ $keys }, 0, $i;
      }

      $self->[_BEGI] = 0, $self->[_INDX] = undef unless @{ $keys };
   }

   return $key, delete $self->[_DATA]{ $key };
}

# UNSHIFT ( key, value [, key, value, ... ] )

sub UNSHIFT {
   my $self = shift;
   my ( $data, $keys ) = @{ $self };

   while ( @_ ) {
      my ( $key, $val ) = splice( @_, -2, 2 );
      $self->DELETE($key) if exists $data->{ $key };
      $data->{ $key } = $val, unshift @{ $keys }, "$key";
      $self->[_BEGI]-- if $self->[_INDX];
   }

   @{ $keys } - $self->[_GCNT];
}

# SPLICE ( offset, length [, key, value, ... ] )

sub SPLICE {
   my ( $self, $off ) = ( shift, shift );
   my ( $data, $keys, $indx ) = @{ $self };
   return () unless defined $off;

   $self->purge() if $indx;

   my ( $key, @ret );
   my $size = scalar @{ $keys };
   my $len  = @_ ? shift : $size - $off;

   if ( $off >= $size ) {
      $self->PUSH(@_) if @_;
   }
   elsif ( abs($off) <= $size ) {
      if ( $len > 0 ) {
         $off = $off + @{ $keys } if $off < 0;
         my @k = splice @{ $keys }, $off, $len;
         push(@ret, $_, delete $data->{ $_ }) for @k;
      }
      if ( @_ ) {
         my @k = splice @{ $keys }, $off;
         $self->PUSH(@_);
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

#  Query string:
#
#  Several methods receive a query string argument. The string is quoteless.
#  Basically, any quotes inside the string will be treated literally.
#
#  Search capability { =~ !~ eq ne lt le gt ge == != < <= > >= }
#
#  "key =~ /pattern/i :AND val =~ /pattern/i"
#  "key =~ /pattern/i :AND val eq foo bar"     # val eq foo bar
#  "val eq foo baz :OR key !~ /pattern/i"
#
#     key means to match against keys in the hash
#     likewise, val means to match against values
#
#  :AND(s) and :OR(s) mixed together is not supported

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
   my $DATA = $self->[_DATA];
   my ( $key, %data, @keys );

   if ( @_ ) {
      while ( @_ ) {
         $key = shift;
         push @keys, "$key" unless exists $data{ $key };
         $data{ $key } = $DATA->{ $key };
      }
   }
   else {
      for my $key ( @{ $self->[_KEYS] } ) {
         next if ( ref $key );
         push @keys, "$key" unless exists $data{ $key };
         $data{ $key } = $DATA->{ $key };
      }
   }

   $self->clear() if $params->{'flush'};

   bless [ \%data, \@keys, undef, 0, 0 ], ref $self;
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

   if ( !scalar @keys ) {
      @keys = grep !ref($_), @{ $self->[_KEYS] };
   }
   elsif ( @keys == 1 && $keys[0] =~ /^(?:key|val)[ ]+\S\S?[ ]+\S/ ) {
      @keys = $self->keys($keys[0]);
   }

   return sub {
      return unless @keys;
      my $key = shift(@keys);
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
            : grep !ref($_), @{ $self->[_KEYS] };
      }
      else {
         @{ $self->[_KEYS] } - $self->[_GCNT];
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
            : map { $_ => $data->{ $_ } }
                 grep !ref($_), @{ $self->[_KEYS] };
      }
      else {
         ( @{ $self->[_KEYS] } - $self->[_GCNT] ) << 1;
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
            : @{ $self->[_DATA] }{ grep !ref($_), @{ $self->[_KEYS] } };
      }
      else {
         @{ $self->[_KEYS] } - $self->[_GCNT];
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
      $cnt++, $self->DELETE($key) if exists($data->{ $key });
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
      return '' if ( !exists $data->{ $key } );
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
   my ( $data, $keys, $key ) = ( $self->[_DATA], $self->[_KEYS] );

   while ( @_ ) {
      $key = shift;
      push @{ $keys }, "$key" unless exists $data->{ $key };
      $data->{ $key } = shift;
   }

   defined wantarray ? @{ $keys } - $self->[_GCNT] : ();
}

# purge ( )

sub purge {
   my ( $self ) = @_;
   my ( $i, $keys ) = ( 0, $self->[_KEYS] );

   # TOMBSTONES, purge in-place to minimize memory consumption.

   if ( $self->[_GCNT] ) {
      for my $key ( @{ $keys } ) {
         $keys->[ $i++ ] = $key unless ref( $key );
      }
      splice @{ $keys }, $i;
   }

   $self->[_BEGI] = $self->[_GCNT] = 0;
   $self->[_INDX] = undef;

   return;
}

# sort ( "BY key [ ASC | DESC ] [ ALPHA ]" )
# sort ( "BY val [ ASC | DESC ] [ ALPHA ]" )
# sort ( "[ ASC | DESC ] [ ALPHA ]" ) # same as "BY val ..."

sub sort {
   my ( $self, $request ) = @_;
   my ( $by_key, $alpha, $desc ) = ( 0, 0, 0 );

   if ( length $request ) {
      $by_key = 1 if $request =~ /\bkey\b/i;
      $alpha  = 1 if $request =~ /\balpha\b/i;
      $desc   = 1 if $request =~ /\bdesc\b/i;
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

   $self->[_BEGI] = $self->[_GCNT] = 0;
   $self->[_INDX] = undef;

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Sugar API, mostly resembles http://redis.io/commands#string primitives.
##
###############################################################################

# append ( key, string )

sub append {
   my ( $self, $key ) = @_;
   push @{ $self->[_KEYS] }, "$key" unless exists $self->[_DATA]{ $key };

   $self->[_DATA]{ $key } .= $_[2] || '';

   length $self->[_DATA]{ $key };
}

# decr ( key )

sub decr {
   my ( $self, $key ) = @_;
   push @{ $self->[_KEYS] }, "$key" unless exists $self->[_DATA]{ $key };

   --$self->[_DATA]{ $key };
}

# decrby ( key, number )

sub decrby {
   my ( $self, $key ) = @_;
   push @{ $self->[_KEYS] }, "$key" unless exists $self->[_DATA]{ $key };

   $self->[_DATA]{ $key } -= $_[2] || 0;
}

# incr ( key )

sub incr {
   my ( $self, $key ) = @_;
   push @{ $self->[_KEYS] }, "$key" unless exists $self->[_DATA]{ $key };

   ++$self->[_DATA]{ $key };
}

# incrby ( key, number )

sub incrby {
   my ( $self, $key ) = @_;
   push @{ $self->[_KEYS] }, "$key" unless exists $self->[_DATA]{ $key };

   $self->[_DATA]{ $key } += $_[2] || 0;
}

# getdecr ( key )

sub getdecr {
   my ( $self, $key ) = @_;
   push @{ $self->[_KEYS] }, "$key" unless exists $self->[_DATA]{ $key };

   $self->[_DATA]{ $key }-- || 0;
}

# getincr ( key )

sub getincr {
   my ( $self, $key ) = @_;
   push @{ $self->[_KEYS] }, "$key" unless exists $self->[_DATA]{ $key };

   $self->[_DATA]{ $key }++ || 0;
}

# getset ( key, value )

sub getset {
   my ( $self, $key ) = @_;
   push @{ $self->[_KEYS] }, "$key" unless exists $self->[_DATA]{ $key };

   my $old = $self->[_DATA]{ $key };
   $self->[_DATA]{ $key } = $_[2];

   $old;
}

# len ( key )
# len ( )

sub len {
   ( defined $_[1] )
      ? length $_[0]->[_DATA]{ $_[1] } || 0
      : @{ $_[0]->[_KEYS] } - $_[0]->[_GCNT];
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

This document describes MCE::Shared::Ordhash version 1.699_011

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
   # query string is quoteless, otherwise quote(s) are treated literally
   # key/val means to match against actual key/val respectively
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

MCE::Shared provides two ordered hash implementations.

This module implements an ordered hash featuring tombstone deletion,
inspired by the L<Hash::Ordered> module. An ordered hash means that
the key insertion order is preserved.

It provides C<splice>, sorting, plus extra capabilities for use with
L<MCE::Shared::Minidb>. Tombstone deletion is further optimized to not
impact C<store>, C<push>, C<unshift>, and C<merge>. Tombstones are
purged in-place for lesser memory consumption.

In addition, C<pop> and C<shift> run optimally when an index is present.
The optimization also applies to forward and reverse deletes.

Applications sensitive to hash deletion may prefer L<MCE::Shared::Indhash>,
a doubly-linked list implementation.

Both this module and C<MCE::Shared::Indhash> may be used interchangeably.
Only the underlying implementation differs between the two.

=head1 QUERY STRING

Several methods in C<MCE::Shared::Ordhash> receive a query string argument.
The string is quoteless. Basically, any quotes inside the string will be
treated literally.

   Search capability: =~ !~ eq ne lt le gt ge == != < <= > >=

   "key =~ /pattern/i :AND val =~ /pattern/i"
   "key =~ /pattern/i :AND val eq foo bar"     # val eq foo bar
   "val eq foo baz :OR key !~ /pattern/i"

      key means to match against keys in the hash
      likewise, val means to match against values

   :AND(s) and :OR(s) mixed together is not supported

=head1 API DOCUMENTATION

To be completed before the final 1.700 release.

=over 3

=item new ( key, value [, key, value, ... ] )

Constructs a new object, with an optional list of key-value pairs.

   # non-shared
   use MCE::Shared::Ordhash;

   $ha = MCE::Shared::Ordhash->new( @pairs );
   $ha = MCE::Shared::Ordhash->new( );

   # shared
   use MCE::Shared;

   $ha = MCE::Shared->ordhash( @pairs );
   $ha = MCE::Shared->ordhash( );

=item clear

=item clone ( key [, key, ... ] )

=item clone

=item delete ( key )

=item del

C<del> is an alias for C<delete>.

=item exists ( key )

=item flush ( key [, key, ... ] )

=item flush

Same as C<clone>. Though, clears all existing items before returning.

=item get ( key )

=item iterator ( key [, key, ... ] )

=item iterator ( "query string" )

=item iterator

=item keys ( key [, key, ...] )

=item keys ( "query string" )

=item keys

=item len ( key )

Returns the length of the value stored at key.

   $len = $oh->len( $key );

=item len

Returns the number of keys stored in the hash.

   $len = $oh->len;

=item mdel ( key [, key, ... ] )

=item mexists ( key [, key, ... ] )

=item mget ( key [, key, ... ] )

=item mset ( key, value [, key, value, ... ] )

=item merge

C<merge> is an alias for C<mset>.

=item pairs ( key [, key, ... ] )

=item pairs ( "query string" )

=item pairs

=item pop

=item purge

=item push ( key/value pairs )

=item set ( key, value )

=item shift

=item sort ( "BY key [ ASC | DESC ] [ ALPHA ]" )

=item sort ( "BY val [ ASC | DESC ] [ ALPHA ]" )

=item sort ( "[ ASC | DESC ] [ ALPHA ]" )

=item splice ( offset, length, key/value pairs )

=item unshift ( key/value pairs )

=item values ( key [, key, ... ] )

=item values ( "query string" )

=item values

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

   $len = $oh->append( $key, 'foo' );

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

   $old = $oh->getset( $key, 'baz' );

=item incr ( key )

Increments the value of a key by one and returns its new value.

   $num = $oh->incr( $key );

=item incrby ( key, number )

Increments the value of a key by the given number and returns its new value.

   $num = $oh->incrby( $key, 2 );

=back

=head1 CREDITS

The implementation is inspired by L<Hash::Ordered> v0.009.

=head1 MOTIVATION

I wanted an ordered hash implementation for use with MCE::Shared without
any side effects such as linear scans, slow deletes, or excessive memory
consumption. A module on CPAN to pass in this regard is L<Hash::Ordered>
by David Golden.

MCE::Shared has one shared-manager process which is by design. Therefore,
extra measures were taken to further reduce any remaining side effects.
I forwarded all findings along the way to David.

This module differs in personality mainly for compatibilty with other
C<hash> classes included with MCE::Shared.

=head1 INDEX

L<MCE|MCE>, L<MCE::Core>, L<MCE::Shared>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

