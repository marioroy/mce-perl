###############################################################################
## ----------------------------------------------------------------------------
## Ordered-hash helper class.
##
## An optimized ordered-hash implementation inspired by Hash::Ordered v0.009.
##
## -- Added SPLICE, sorting, plus extra capabilities for use with MCE::Hobo.
## -- Keys garbage collection is done in-place for minimum memory consumption.
## -- Revised tombstone deletion to ensure safety with varied usage patterns.
## -- The indexed hash is filled on-demand to not impact subsequent stores.
## -- Provides support for hash-like dereferencing, also on-demand.
##
###############################################################################

package MCE::Shared::Ordhash;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized );

our $VERSION = '1.699_008';

# no critic (TestingAndDebugging::ProhibitNoStrict)

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
   _HREF => 6,  # for hash-like dereferencing
};

use overload (
   q("")    => \&MCE::Shared::Base::_stringify_a,
   q(0+)    => \&MCE::Shared::Base::_numify,
   q(%{})   => sub {
      $_[0]->[_HREF] || do {
         tie my %h, 'MCE::Shared::Ordhash::_href', $_[0];
         $_[0]->[_HREF] = \%h;
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
# TIEHASH

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

   if ( exists $self->[_DATA]{ $key } ) {
      my $keys = $self->[_KEYS];

      # check first key
      if ( $key eq $keys->[0] ) {
         $self->[_BEGI]++, delete $self->[_INDX]{ $key } if $self->[_INDX];
         shift @{ $keys };
         if ( ref $keys->[0] ) {
            my $i = 0; # GC start of list
            $i++, shift @{ $keys } while ref( $keys->[0] );
            $self->[_BEGI] += $i, $self->[_GCNT] -= $i;
         }
      }

      # check last key
      elsif ( $key eq $keys->[-1] ) {
         delete $self->[_INDX]{ $key } if $self->[_INDX];
         pop @{ $keys };
         if ( ref $keys->[-1] ) {
            my $i = 0; # GC end of list
            $i++, pop @{ $keys } while ref( $keys->[-1] );
            $self->[_GCNT] -= $i;
         }
      }

      # otherwise, key is in the middle
      else {
         my $indx = $self->[_INDX] || $self->_make_indx();
         my $id   = delete $indx->{ $key };

         # fill index on-demand; tombstone
         $self->_fill_indx(), $id = delete $indx->{ $key } if !defined $id;
         $keys->[ $id - $self->[_BEGI] ] = _TOMBSTONE;

         # GC keys if more than half are tombstone
         $self->purge() if ++$self->[_GCNT] > ( @{ $keys } >> 1 );
      }

      $self->[_BEGI] = 0, $self->[_INDX] = undef unless scalar @{ $keys };

      delete $self->[_DATA]{ $key };
   }
   else {
      undef;
   }
}

# FIRSTKEY

sub FIRSTKEY {
   my ( $self ) = @_;
   my @keys = grep !ref($_), @{ $self->[_KEYS] };

   $self->[_ITER] = sub {
      return unless @keys;
      return shift(@keys);
   };

   $self->[_ITER]->();
}

# NEXTKEY

sub NEXTKEY {
   exists $_[0]->[_ITER] ? $_[0]->[_ITER]->() : ();
}

# EXISTS ( key )

sub EXISTS {
   exists $_[0]->[_DATA]{ $_[1] };
}

# CLEAR

sub CLEAR {
   my ( $self ) = @_;

   %{ $self->[_DATA] } = @{ $self->[_KEYS] } = (   ),
      $self->[_BEGI]   =    $self->[_GCNT]   =   0  ,
      $self->[_INDX]   = undef;

   delete $self->[_HREF] if exists $self->[_HREF];
   delete $self->[_ITER] if exists $self->[_ITER];

   ();
}

# SCALAR

sub SCALAR {
   @{ $_[0]->[_KEYS] } - $_[0]->[_GCNT];
}

###############################################################################
## ----------------------------------------------------------------------------
## POP, PUSH, SHIFT, UNSHIFT, SPLICE
##
###############################################################################

# POP

sub POP {
   my ( $self ) = @_;

   if ( $self->[_INDX] ) {
      my $key = $self->[_KEYS][-1];
      return unless defined $key;
      return $key, $self->DELETE($key);
   }
   else {
      my $key = pop @{ $self->[_KEYS] };
      return unless defined $key;
      return $key, delete $self->[_DATA]{$key};
   }
}

# PUSH ( key, value [, key, value, ... ] )

sub PUSH {
   my $self = shift;
   my ( $data, $keys ) = @$self;

   while ( @_ ) {
      my ( $key, $val ) = splice( @_, 0, 2 );
      $self->DELETE($key) if exists $data->{ $key };
      push @{ $keys }, "$key";
      $data->{ $key } = $val;
   }

   @{ $keys } - $self->[_GCNT];
}

# SHIFT

sub SHIFT {
   my ( $self ) = @_;

   if ( $self->[_INDX] ) {
      my $key = $self->[_KEYS][0];
      return unless defined $key;
      return $key, $self->DELETE($key);
   }
   else {
      my $key = shift @{ $self->[_KEYS] };
      return unless defined $key;
      return $key, delete $self->[_DATA]{$key};
   }
}

# UNSHIFT ( key, value [, key, value, ... ] )

sub UNSHIFT {
   my $self = shift;
   my ( $data, $keys ) = @$self;

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
   my ( $data, $keys, $indx ) = @$self;
   my ( $key, @ret );

   return @ret unless defined $off;

   $self->purge() if $indx;

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
## Private methods.
##
###############################################################################

# Create / fill index with ( key => id ) pairs.

sub _make_indx {
   my ( $self, $i, %indx ) = ( shift, 0 );

   $indx{ $_ } = $i++ for @{ $self->[_KEYS] };

   $self->[_BEGI] = 0;
   $self->[_INDX] = \%indx;
}

sub _fill_indx {
   my ( $self ) = @_;
   my ( $keys, $indx ) = ( $self->[_KEYS], $self->[_INDX] );
   return $self->_make_indx() unless defined $indx;

   my ( $left, $right ) = @{ $indx }{ @{ $keys }[ 0, -1 ] };

   if ( !defined $left ) {
      my ( $pos, $id, $key ) = ( 0, $self->[_BEGI] );
      for ( 1 .. @{ $keys } ) {
         $key = $keys->[ $pos ];
         if ( !ref $key ) {
            last if exists $indx->{ $key };
            $indx->{ $key } = $id;
         }
         $pos++, $id++;
      }
   }

   if ( !defined $right ) {
      my ( $pos, $id, $key ) = ( -1, $self->[_BEGI] + $#{ $keys } );
      for ( 1 .. @{ $keys } ) {
         $key = $keys->[ $pos ];
         if ( !ref $key ) {
            last if exists $indx->{ $key };
            $indx->{ $key } = $id;
         }
         $pos--, $id--;
      }
   }

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## _find, clone, flush, iterator, keys, pairs, values
##
###############################################################################

#  Query string:
#
#  Several methods receive query string as an argument. The string is
#  quoteless. Any quotes inside the string will be treated literally.
#
#  Search capability { =~ !~ eq ne lt le gt ge == != < <= > >= }
#
#  "key =~ /pattern/i :AND val =~ /pattern/i"
#  "key =~ /pattern/i :AND val eq foo bar"     # val eq foo bar
#  "val eq foo baz :OR key !~ /pattern/i"
#
#     key means to match against keys in the hash
#     val means to match against values in the hash
#
#  Do not mix :AND(s) and :OR(s) together.

# _find ( { getkeys => 1 }, "query string" )
# _find ( { getvals => 1 }, "query string" )
#
# _find ( "query string" ) # pairs

sub _find {
   my $self   = shift;
   my $params = ref($_[0]) eq 'HASH' ? shift : {};
   my $query  = shift;

   MCE::Shared::Base::_find_hash(
      $self->[_DATA], $params, $query, grep(!ref($_), @{ $self->[_KEYS] })
   );
}

# clone ( key [, key, ... ] )
# clone

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
         next if ref $key;
         push @keys, "$key" unless exists $data{ $key };
         $data{ $key } = $DATA->{ $key };
      }
   }

   $self->clear() if $params->{'flush'};

   bless [ \%data, \@keys, undef, 0, 0 ], ref $self;
}

# flush ( key [, key, ... ] )
# flush

sub flush {
   shift()->clone( { flush => 1 }, @_ );
}

# iterator ( key [, key, ... ] )
# iterator ( "query string" )
# iterator

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
# keys

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
# pairs

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
# values

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

# purge

sub purge {
   my ( $self ) = @_;

   # @{ $self->[_KEYS] } = grep !ref($_), @{ $self->[_KEYS] };
   # Purging is done in-place for lesser memory consumption.

   if ( $self->[_GCNT] ) {
      my ( $i, $keys ) = ( 0, $self->[_KEYS] );

      if ( @{ $keys } ) {
         for ( 0 .. @{ $keys } - 1 ) {
            next if ref( $keys->[$_] );
            $keys->[ $i++ ] = $keys->[$_];
         }
         splice @{ $keys }, $i;
      }
   }

   $self->[_INDX] = undef, $self->[_BEGI] = $self->[_GCNT] = 0;

   return;
}

# sort ( "BY key [ ASC | DESC ] [ ALPHA ]" )
# sort ( "BY val [ ASC | DESC ] [ ALPHA ]" )
#
# sort ( "[ ASC | DESC ] [ ALPHA ]" ) # same as "BY val ..."

sub sort {
   my ( $self, $request ) = @_;
   my ( $by_key, $alpha, $desc ) = ( 0, 0, 0 );

   if ( length $request ) {
      $by_key = 1 if $request =~ /\bkey\b/i;
      $alpha  = 1 if $request =~ /\balpha\b/i;
      $desc   = 1 if $request =~ /\bdesc\b/i;
   }

   # Return sorted keys
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

   # Sort keys in-place
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
   my $self = shift; @{ $self->[_KEYS] } = @_;
   $self->[_INDX] = undef, $self->[_BEGI] = $self->[_GCNT] = 0;

   delete $self->[_HREF] if exists $self->[_HREF];
   delete $self->[_ITER] if exists $self->[_ITER];

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Sugar API, mostly resembles http://redis.io/commands#string primitives.
##
###############################################################################

# append ( key, string )

sub append {
   $_[0]->[_DATA]{ $_[1] } .= $_[2] || '';
   length $_[0]->[_DATA]{ $_[1] };
}

# decr    ( key )
# decrby  ( key, number )
# incr    ( key )
# incrby  ( key, number )
# getdecr ( key )
# getincr ( key )

sub decr    { --$_[0]->[_DATA]{ $_[1] }               }
sub decrby  {   $_[0]->[_DATA]{ $_[1] } -= $_[2] || 0 }
sub incr    { ++$_[0]->[_DATA]{ $_[1] }               }
sub incrby  {   $_[0]->[_DATA]{ $_[1] } += $_[2] || 0 }
sub getdecr {   $_[0]->[_DATA]{ $_[1] }--        || 0 }
sub getincr {   $_[0]->[_DATA]{ $_[1] }++        || 0 }

# getset ( key, value )

sub getset {
   my ( $self, $key ) = @_;  # $_[2] is not copied in case it's large
   push @{ $self->[_KEYS] }, "$key" unless exists $self->[_DATA]{ $key };

   my $old = $self->[_DATA]{ $key };
   $self->[_DATA]{ $key } = $_[2];

   $old;
}

# len ( key )
# len

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

MCE::Shared::Ordhash - Ordered-hash helper class

=head1 VERSION

This document describes MCE::Shared::Ordhash version 1.699_008

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

Helper class for L<MCE::Shared|MCE::Shared>.

=head1 API DOCUMENTATION

To be completed before the final 1.700 release.

=over 3

=item new ( key, value [, key, value, ... ] )

=item new

=item clear

=item clone ( key [, key, ... ] )

=item clone

=item delete ( key )

=item exists ( key )

=item flush ( key [, key, ... ] )

=item flush

Same as C<clone>. Clears all existing items before returning.

=item get ( key )

=item iterator ( key [, key, ... ] )

=item iterator ( "query string" )

=item iterator

=item keys ( key [, key, ...] )

=item keys ( "query string" )

=item keys

=item len ( [ key ] )

=item mdel ( keys )

=item mexists ( keys )

=item mget ( keys )

=item mset ( key/value pairs )

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

=back

=head1 SUGAR METHODS

This module is equipped with sugar methods to not have to call C<set>
and C<get> explicitly. The API resembles a subset of the Redis primitives
L<http://redis.io/commands#strings> with key representing the hash key.

=over 3

=item append ( key, string )

Append a value to a key.

=item decr ( key )

Decrement the value of a key by one and return its new value.

=item decrby ( key, number )

Decrement the value of a key by the given number and return its new value.

=item getdecr ( key )

Decrement the value of a key by one and return its old value.

=item getincr ( key )

Increment the value of a key by one and return its old value.

=item getset ( key, value )

Set the value of a key and return its old value.

=item incr ( key )

Increment the value of a key by one and return its new value.

=item incrby ( key, number )

Increment the value of a key by the given number and return its new value.

=back

=head1 CREDITS

The implementation is inspired by L<Hash::Ordered|Hash::Ordered>.

=head1 INDEX

L<MCE|MCE>, L<MCE::Core|MCE::Core>, L<MCE::Shared|MCE::Shared>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

