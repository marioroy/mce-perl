###############################################################################
## ----------------------------------------------------------------------------
## Hash helper class.
##
###############################################################################

package MCE::Shared::Hash;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized numeric );

our $VERSION = '1.700';

## no critic (TestingAndDebugging::ProhibitNoStrict)

use MCE::Shared::Base;
use bytes;

use overload (
   q("")    => \&MCE::Shared::Base::_stringify,
   q(0+)    => \&MCE::Shared::Base::_numify,
   fallback => 1
);

###############################################################################
## ----------------------------------------------------------------------------
## Based on Tie::StdHash from Tie::Hash.
##
###############################################################################

sub TIEHASH {
   my $self = bless {}, shift;
   %{ $self } = @_ if @_;

   $self;
}

sub STORE    { $_[0]->{ $_[1] } = $_[2] }
sub FETCH    { $_[0]->{ $_[1] } }
sub DELETE   { delete $_[0]->{ $_[1] } }
sub FIRSTKEY { my $a = keys %{ $_[0] }; each %{ $_[0] } }
sub NEXTKEY  { each %{ $_[0] } }
sub EXISTS   { exists $_[0]->{ $_[1] } }
sub CLEAR    { %{ $_[0] } = () }
sub SCALAR   { scalar keys %{ $_[0] } }

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

   MCE::Shared::Base::_find_hash( $self, $params, $query, $self );
}

# clone ( key [, key, ... ] )
# clone ( )

sub clone {
   my $self = shift;
   my $params = ref($_[0]) eq 'HASH' ? shift : {};
   my %data;

   if ( @_ ) {
      @data{ @_ } = @{ $self }{ @_ };
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

   if ( ! @keys ) {
      @keys = CORE::keys %{ $self };
   }
   elsif ( @keys == 1 && $keys[0] =~ /^(?:key|val)[ ]+\S\S?[ ]+\S/ ) {
      @keys = $self->keys($keys[0]);
   }

   return sub {
      return unless @keys;
      my $key = shift @keys;
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
         scalar CORE::keys %{ $self };
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
      $cnt++, delete($self->{ $key }) if ( exists $self->{ $key } );
   }

   $cnt;
}

# mexists ( key [, key, ... ] )

sub mexists {
   my $self = shift;
   my $key;

   while ( @_ ) {
      $key = shift;
      return '' unless ( exists $self->{ $key } );
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
   length( $_[0]->{ $_[1] } .= $_[2] // '' );
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
sub getdecr {   $_[0]->{ $_[1] }--        // 0 }
sub getincr {   $_[0]->{ $_[1] }++        // 0 }

# getset ( key, value )

sub getset {
   my $old = $_[0]->{ $_[1] };
   $_[0]->{ $_[1] } = $_[2];

   $old;
}

# len ( key )
# len ( )

sub len {
   ( defined $_[1] )
      ? length $_[0]->{ $_[1] }
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

This document describes MCE::Shared::Hash version 1.700

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
   # key/val means to match against actual key/val respectively
   # do not add quotes inside the string unless intended literally
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

A hash helper class for use with L<MCE::Shared>.

=head1 SYNTAX for QUERY STRING

Several methods in C<MCE::Shared::Hash> take a query string for an argument.
The format of the string is quoteless. Therefore, any quotes inside the string
is treated literally.

   o Basic demonstration: @keys = $ha->keys( "val =~ /pattern/" );
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

This module may involve TIE when accessing the object via hash-like behavior.
Only shared instances are impacted if doing so. Although likely fast enough for
many use cases, use the OO interface if better performance is desired.

=over 3

=item new ( key, value [, key, value, ... ] )

Constructs a new object, with an optional list of key-value pairs.

   # non-shared
   use MCE::Shared::Hash;

   $ha = MCE::Shared::Hash->new( @pairs );
   $ha = MCE::Shared::Hash->new( );

   # shared
   use MCE::Shared;

   $ha = MCE::Shared->hash( @pairs );
   $ha = MCE::Shared->hash( );

=item clear

Removes all key-value pairs from the hash.

   $ha->clear;
   %{$ha} = ();

=item clone ( key [, key, ... ] )

Creates a shallow copy, a C<MCE::Shared::Hash> object. It returns an exact
copy if no arguments are given. Otherwise, the object includes only the given
keys. Keys that do not exist in the hash will have the C<undef> value.

   $ha2 = $ha->clone( "key1", "key2" );
   $ha2 = $ha->clone;

=item delete ( key )

Deletes and returns the value by given key or C<undef> if the key does not
exists in the hash.

   $val = $ha->delete( "some_key" );
   $val = delete $ha->{ "some_key" };

=item del

C<del> is an alias for C<delete>.

=item exists ( key )

Determines if a key exists in the hash.

   if ( $ha->exists( "some_key" ) ) { ... }
   if ( exists $ha->{ "some_key" } ) { ... }

=item flush ( key [, key, ... ] )

Same as C<clone>. Though, clears all existing items before returning.

=item get ( key )

Gets the value of a hash key or C<undef> if the key does not exists.

   $val = $ha->get( "some_key" );
   $val = $ha->{ "some_key" };

=item iterator ( key [, key, ... ] )

Returns a code reference for iterating a list of key-value pairs stored in
the hash when no arguments are given. Otherwise, returns a code reference for
iterating the given keys in the same order. Keys that do not exist will have
the C<undef> value.

The list of keys to return is set when the closure is constructed. Later keys
added to the hash are not included. Subsequently, the C<undef> value is
returned for deleted keys.

   $iter = $ha->iterator;
   $iter = $ha->iterator( "key1", "key2" );

   while ( my ( $key, $val ) = $iter->() ) {
      ...
   }

=item iterator ( "query string" )

Returns a code reference for iterating a list of key-value pairs that match
the given criteria. It returns an empty list if the search found nothing.
The syntax for the C<query string> is described above.

   $iter = $ha->iterator( "val eq some_value" );
   $iter = $ha->iterator( "key eq some_key :AND val =~ /sun|moon|air|wind/" );
   $iter = $ha->iterator( "val eq sun :OR val eq moon :OR val eq foo" );
   $iter = $ha->iterator( "key =~ /$pattern/" );

   while ( my ( $key, $val ) = $iter->() ) {
      ...
   }

=item keys ( key [, key, ... ] )

Returns all keys in the hash when no arguments are given. Otherwise, returns
the given keys in the same order. Keys that do not exist will have the C<undef>
value. In scalar context, returns the size of the hash.

   @keys = $ha->keys;
   @keys = $ha->keys( "key1", "key2" );
   $len  = $ha->keys;

=item keys ( "query string" )

Returns only keys that match the given criteria. It returns an empty list
if the search found nothing. The syntax for the C<query string> is described
above. In scalar context, returns the size of the resulting list.

   @keys = $ha->keys( "val eq some_value" );
   @keys = $ha->keys( "key eq some_key :AND val =~ /sun|moon|air|wind/" );
   @keys = $ha->keys( "val eq sun :OR val eq moon :OR val eq foo" );
   $len  = $ha->keys( "key =~ /$pattern/" );

=item len ( key )

Returns the size of the hash when no arguments are given. For the given key,
returns the length of the value stored at key or the C<undef> value if the
key does not exists.

   $size = $ha->len;
   $len  = $ha->len( "key1" );
   $len  = length $ha->{ "key1" };

=item mdel ( key [, key, ... ] )

Deletes one or more keys in the hash and returns the number of keys deleted.
A given key which does not exist in the hash is not counted.

   $cnt = $ha->mdel( "key1", "key2" );

=item mexists ( key [, key, ... ] )

Returns a true value if all given keys exists in the hash. A false value is
returned otherwise.

   if ( $ha->mexists( "key1", "key2" ) ) { ... }

=item mget ( key [, key, ... ] )

Gets the values of all given keys. It returns C<undef> for keys which do not
exists in the hash.

   ( $val1, $val2 ) = $ha->mget( "key1", "key2" );

=item mset ( key, value [, key, value, ... ] )

Sets multiple key-value pairs in a hash and returns the number of keys stored
in the hash.

   $len = $ha->mset( "key1" => "val1", "key2" => "val2" );

=item merge

C<merge> is an alias for C<mset>.

=item pairs ( "query string" )

Returns key-value pairs in the hash when no arguments are given. Otherwise,
returns key-value pairs for the given keys in the same order. Keys that do not
exist will have the C<undef> value. In scalar context, returns the size of the
hash.

   @pairs = $ha->pairs;
   @pairs = $ha->pairs( "key1", "key2" );
   $len   = $ha->pairs;

=item pairs ( key [, key, ... ] )

Returns only key-value pairs that match the given criteria. It returns an
empty list if the search found nothing. The syntax for the C<query string> is
described above. In scalar context, returns the size of the resulting list.

   @pairs = $ha->pairs( "val eq some_value" );
   @pairs = $ha->pairs( "key eq some_key :AND val =~ /sun|moon|air|wind/" );
   @pairs = $ha->pairs( "val eq sun :OR val eq moon :OR val eq foo" );
   $len   = $ha->pairs( "key =~ /$pattern/" );

=item set ( key, value )

Sets the value of the given hash key and returns its new value.

   $val = $ha->set( "key", "value" );
   $val = $ha->{ "key" } = "value";

=item values ( key [, key, ... ] )

Returns all values in the hash when no arguments are given. Otherwise, returns
values for the given keys in the same order. Keys that do not exist will have
the C<undef> value. In scalar context, returns the size of the hash.

   @vals = $ha->values;
   @vals = $ha->values( "key1", "key2" );
   $len  = $ha->values;

=item values ( "query string" )

Returns only values that match the given criteria. It returns an empty list
if the search found nothing. The syntax for the C<query string> is described
above. In scalar context, returns the size of the resulting list.

   @vals = $ha->values( "val eq some_value" );
   @vals = $ha->values( "key eq some_key :AND val =~ /sun|moon|air|wind/" );
   @vals = $ha->values( "val eq sun :OR val eq moon :OR val eq foo" );
   $len  = $ha->values( "key =~ /$pattern/" );

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

   $len = $ha->append( $key, "foo" );

=item decr ( key )

Decrements the value of a key by one and returns its new value.

   $num = $ha->decr( $key );

=item decrby ( key, number )

Decrements the value of a key by the given number and returns its new value.

   $num = $ha->decrby( $key, 2 );

=item getdecr ( key )

Decrements the value of a key by one and returns its old value.

   $old = $ha->getdecr( $key );

=item getincr ( key )

Increments the value of a key by one and returns its old value.

   $old = $ha->getincr( $key );

=item getset ( key, value )

Sets the value of a key and returns its old value.

   $old = $ha->getset( $key, "baz" );

=item incr ( key )

Increments the value of a key by one and returns its new value.

   $num = $ha->incr( $key );

=item incrby ( key, number )

Increments the value of a key by the given number and returns its new value.

   $num = $ha->incrby( $key, 2 );

=back

=head1 CREDITS

The implementation is inspired by L<Tie::StdHash>.

=head1 INDEX

L<MCE|MCE>, L<MCE::Core>, L<MCE::Shared>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

