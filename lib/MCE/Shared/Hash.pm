###############################################################################
## ----------------------------------------------------------------------------
## Hash helper class.
##
###############################################################################

package MCE::Shared::Hash;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized numeric );

our $VERSION = '1.699_009';

## no critic (TestingAndDebugging::ProhibitNoStrict)

use MCE::Shared::Base;
use bytes;

use overload (
   q("")    => \&MCE::Shared::Base::_stringify,
   q(0+)    => \&MCE::Shared::Base::_numify,
   fallback => 1
);

sub TIEHASH {
   my $self = bless {}, shift;
   $self->mset(@_) if @_;
   $self;
}

# Based on Tie::StdHash from Tie::Hash.

sub STORE    { $_[0]->{$_[1]} = $_[2] }
sub FETCH    { $_[0]->{$_[1]} }
sub DELETE   { delete $_[0]->{$_[1]} }
sub FIRSTKEY { my $a = keys %{$_[0]}; each %{$_[0]} }
sub NEXTKEY  { each %{$_[0]} }
sub EXISTS   { exists $_[0]->{$_[1]} }
sub CLEAR    { %{$_[0]} = () }
sub SCALAR   { scalar keys %{$_[0]} }

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

   MCE::Shared::Base::_find_hash(
      $self, $params, $query, CORE::keys %{ $self }
   );
}

# clone ( key [, key, ... ] )
# clone ( )

sub clone {
   my $self = shift;
   my $params = ref($_[0]) eq 'HASH' ? shift : {};
   my ( %data, $key );

   if ( @_ ) {
      while ( @_ ) {
         $key = shift;
         $data{ $key } = $self->{ $key };
      }
   }
   else {
      %data = %{ $self };
   }

   $self->clear() if $params->{'flush'};

   bless \%data, ref $self;
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

   if ( !scalar @keys ) {
      @keys = CORE::keys %{ $self };
   }
   elsif ( @keys == 1 && $keys[0] =~ /^(?:key|val)[ ]+\S\S?[ ]+\S/ ) {
      @keys = $self->keys($keys[0]);
   }

   return sub {
      return unless @keys;
      my $key = shift(@keys);
      return ( $key => $self->{ $key } );
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
         @_ ? map { exists $self->{ $_ } ? $_ : undef } @_
            : CORE::keys %{ $self };
      }
      else {
         scalar CORE::keys %{ $self };
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
         @_ ? map { $_ => $self->{ $_ } } @_
            : %{ $self };
      }
      else {
         ( scalar CORE::keys %{ $self } ) << 1;
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
         @_ ? @{ $self }{ @_ }
            : CORE::values %{ $self };
      }
      else {
         scalar CORE::keys %{ $self };
      }
   }
}

###############################################################################
## ----------------------------------------------------------------------------
## mdel, mexists, mget, mset
##
###############################################################################

# mdel ( key [, key, ... ] )

sub mdel {
   my $self = shift;
   my ( $cnt, $key ) = ( 0 );

   while ( @_ ) {
      $key = shift;
      $cnt++, delete($self->{ $key }) if exists($self->{ $key });
   }

   $cnt;
}

# mexists ( key [, key, ... ] )

sub mexists {
   my $self = shift;
   my $key;

   while ( @_ ) {
      $key = shift;
      return '' if ( !exists $self->{ $key } );
   }

   1;
}

# mget ( key [, key, ... ] )

sub mget {
   my $self = shift;

   @_ ? @{ $self }{ @_ } : ();
}

# mset ( key, value [, key, value, ... ] )

sub mset {
   my ( $self, $key ) = ( shift );

   while ( @_ ) {
      $key = shift, $self->{ $key } = shift;
   }

   defined wantarray ? scalar CORE::keys %{ $self } : ();
}

###############################################################################
## ----------------------------------------------------------------------------
## Sugar API, mostly resembles http://redis.io/commands#string primitives.
##
###############################################################################

# append ( key, string )

sub append {
   $_[0]->{ $_[1] } .= $_[2] || '';
   length $_[0]->{ $_[1] };
}

# decr    ( key )
# decrby  ( key, number )
# incr    ( key )
# incrby  ( key, number )
# getdecr ( key )
# getincr ( key )

sub decr    { --$_[0]->{ $_[1] }               }
sub decrby  {   $_[0]->{ $_[1] } -= $_[2] || 0 }
sub incr    { ++$_[0]->{ $_[1] }               }
sub incrby  {   $_[0]->{ $_[1] } += $_[2] || 0 }
sub getdecr {   $_[0]->{ $_[1] }--        || 0 }
sub getincr {   $_[0]->{ $_[1] }++        || 0 }

# getset ( key, value )

sub getset { my $old = $_[0]->{ $_[1] }; $_[0]->{ $_[1] } = $_[2]; $old }

# len ( key )
# len ( )

sub len {
   ( defined $_[1] )
      ? length $_[0]->{ $_[1] } || 0
      : scalar CORE::keys %{ $_[0] };
}

{
   no strict 'refs';

   *{ __PACKAGE__.'::new'    } = \&TIEHASH;
   *{ __PACKAGE__.'::set'    } = \&STORE;
   *{ __PACKAGE__.'::get'    } = \&FETCH;
   *{ __PACKAGE__.'::delete' } = \&DELETE;
   *{ __PACKAGE__.'::exists' } = \&EXISTS;
   *{ __PACKAGE__.'::clear'  } = \&CLEAR;

   *{ __PACKAGE__.'::del'    } = \&delete;
   *{ __PACKAGE__.'::merge'  } = \&mset;
   *{ __PACKAGE__.'::vals'   } = \&values;
}

1;

__END__

###############################################################################
## ----------------------------------------------------------------------------
## Module usage.
##
###############################################################################

=head1 NAME

MCE::Shared::Hash - Hash helper class

=head1 VERSION

This document describes MCE::Shared::Hash version 1.699_009

=head1 SYNOPSIS

   # non-shared
   use MCE::Shared::Hash;

   my $ha = MCE::Shared::Hash->new( @pairs );

   # shared
   use MCE::Shared;

   my $ha = MCE::Shared->hash( @pairs );

   # oo interface
   $val   = $ha->set( $key, $val );
   $val   = $ha->get( $key );
   $val   = $ha->delete( $key );              # del is an alias for delete
   $bool  = $ha->exists( $key );
   void   = $ha->clear();
   $len   = $ha->len();                       # scalar keys %{ $ha }
   $len   = $ha->len( $key );                 # length $ha->{ $key }

   $ha2   = $ha->clone( @keys );              # @keys is optional
   $ha3   = $ha->flush( @keys );
   $iter  = $ha->iterator( @keys );           # ($key, $val) = $iter->()
   @keys  = $ha->keys( @keys );
   %pairs = $ha->pairs( @keys );
   @vals  = $ha->values( @keys );             # vals is an alias for values

   $cnt   = $ha->mdel( @keys );
   @vals  = $ha->mget( @keys );
   $bool  = $ha->mexists( @keys );            # true if all keys exists
   $len   = $ha->mset( $key/$val pairs );     # merge is an alias for mset

   # search capability key/val { =~ !~ eq ne lt le gt ge == != < <= > >= }
   # query string is quoteless, otherwise quote(s) are treated literally
   # key/val means to match against actual key/val respectively
   # do not mix :AND(s) and :OR(s) together

   @keys  = $ha->keys( "key =~ /$pattern/i" );
   @keys  = $ha->keys( "key !~ /$pattern/i" );
   @keys  = $ha->keys( "val =~ /$pattern/i" );
   @keys  = $ha->keys( "val !~ /$pattern/i" );

   %pairs = $ha->pairs( "key == $number" );
   %pairs = $ha->pairs( "key != $number :AND val > 100" );
   %pairs = $ha->pairs( "key <  $number :OR key > $number" );
   %pairs = $ha->pairs( "val <= $number" );
   %pairs = $ha->pairs( "val >  $number" );
   %pairs = $ha->pairs( "val >= $number" );

   @vals  = $ha->values( "key eq $string" );
   @vals  = $ha->values( "key ne $string with space" );
   @vals  = $ha->values( "key lt $string :OR val =~ /$pat1|$pat2/" );
   @vals  = $ha->values( "val le $string :AND val eq foo bar" );
   @vals  = $ha->values( "val gt $string" );
   @vals  = $ha->values( "val ge $string" );

   # sugar methods without having to call set/get explicitly

   $len   = $ha->append( $key, $string );     #   $val .= $string
   $val   = $ha->decr( $key );                # --$val
   $val   = $ha->decrby( $key, $number );     #   $val -= $number
   $val   = $ha->getdecr( $key );             #   $val--
   $val   = $ha->getincr( $key );             #   $val++
   $val   = $ha->incr( $key );                # ++$val
   $val   = $ha->incrby( $key, $number );     #   $val += $number
   $old   = $ha->getset( $key, $new );        #   $o = $v, $v = $n, $o

=head1 DESCRIPTION

A hash helper class for use with L<MCE::Shared|MCE::Shared>.

=head1 QUERY STRING

Several methods in C<MCE::Shared::Hash> receive a query string argument.
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

=item new

=item clear

=item clone ( key [, key, ... ] )

=item clone

=item delete ( key )

=item del

C<del> is an alias for C<delete>.

=item exists ( key )

=item flush ( key [, key, ... ] )

=item flush

Same as C<clone>. Clears all existing items before returning.

=item get ( key )

=item iterator ( key [, key, ... ] )

=item iterator ( "query string" )

=item iterator

=item keys ( key [, key, ... ] )

=item keys ( "query string" )

=item keys

=item len ( key )

=item len

=item mdel ( key [, key, ... ] )

=item mexists ( key [, key, ... ] )

=item mget ( key [, key, ... ] )

=item mset ( key, value [, key, value, ... ] )

=item merge

C<merge> is an alias for C<mset>.

=item pairs ( key [, key, ... ] )

=item pairs ( "query string" )

=item pairs

=item set ( key, value )

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

The implementation is inspired by L<Tie::StdHash|Tie::StdHash>.

=head1 INDEX

L<MCE|MCE>, L<MCE::Core|MCE::Core>, L<MCE::Shared|MCE::Shared>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

