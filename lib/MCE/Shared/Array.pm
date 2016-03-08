###############################################################################
## ----------------------------------------------------------------------------
## Array helper class.
##
###############################################################################

package MCE::Shared::Array;

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
## Based on Tie::StdArray from Tie::Array.
##
###############################################################################

sub TIEARRAY {
   my $self = bless [], shift;
   @{ $self } = @_ if @_;

   $self;
}

sub EXTEND { }

sub FETCHSIZE { scalar @{ $_[0] } }
sub STORESIZE { $#{ $_[0] } = $_[1] - 1 }

sub STORE     { $_[0]->[ $_[1] ] = $_[2] }
sub FETCH     { $_[0]->[ $_[1] ] }
sub DELETE    { delete $_[0]->[ $_[1] ] }
sub EXISTS    { exists $_[0]->[ $_[1] ] }
sub CLEAR     { @{ $_[0] } = () }
sub POP       { pop @{ $_[0] } }
sub PUSH      { my $ob = shift; push @{ $ob }, @_ }
sub SHIFT     { shift @{ $_[0] } }
sub UNSHIFT   { my $ob = shift; unshift @{ $ob }, @_ }

# SPLICE ( offset [, length [, list ] ] )

sub SPLICE {
   my $ob  = shift;
   my $sz  = $ob->FETCHSIZE;
   my $off = @_ ? shift : 0;
   $off   += $sz if $off < 0;
   my $len = @_ ? shift : $sz-$off;

   splice @{ $ob }, $off, $len, @_;
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

   MCE::Shared::Base::_find_array( $self, $params, $query );
}

# clone ( key [, key, ... ] )
# clone ( )

sub clone {
   my $self = shift;
   my $params = ref($_[0]) eq 'HASH' ? shift : {};
   my @data = ( @_ ) ? @{ $self }[ @_ ] : @{ $self };

   $self->clear() if $params->{'flush'};

   bless \@data, ref $self;
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
      @keys = ( 0 .. $#{ $self } );
   }
   elsif ( @keys == 1 && $keys[0] =~ /^(?:key|val)[ ]+\S\S?[ ]+\S/ ) {
      @keys = $self->keys($keys[0]);
   }

   return sub {
      return unless @keys;
      my $key = shift @keys;
      return ( $key => $self->[ $key ] );
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
         @_ ? map { exists $self->[ $_ ] ? $_ : undef } @_
            : ( 0 .. $#{ $self } );
      }
      else {
         scalar @{ $self };
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
         @_ ? map { $_ => $self->[ $_ ] } @_
            : map { $_ => $self->[ $_ ] } 0 .. $#{ $self };
      }
      else {
         scalar @{ $self };
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
         @_ ? @{ $self }[ @_ ]
            : @{ $self }
      }
      else {
         scalar @{ $self };
      }
   }
}

###############################################################################
## ----------------------------------------------------------------------------
## mdel, mexists, mget, mset, range, sort
##
###############################################################################

# mdel ( index [, index, ... ] )

sub mdel {
   my $self = shift;
   my ( $cnt, $key ) = ( 0 );

   while ( @_ ) {
      $key = shift;
      $cnt++, delete($self->[ $key ]) if ( exists $self->[ $key ] );
   }

   $cnt;
}

# mexists ( index [, index, ... ] )

sub mexists {
   my $self = shift;
   my $key;

   while ( @_ ) {
      $key = shift;
      return '' unless ( exists $self->[ $key ] );
   }

   1;
}

# mget ( index [, index, ... ] )

sub mget {
   my $self = shift;

   @_ ? @{ $self }[ @_ ] : ();
}

# mset ( index, value [, index, value, ... ] )

sub mset {
   my ( $self, $key ) = ( shift );

   while ( @_ ) {
      $key = shift, $self->[ $key ] = shift;
   }

   defined wantarray ? scalar @{ $self } : ();
}

# range ( start, stop )

sub range {
   my ( $self, $start, $stop ) = @_;

   if ( $start !~ /^\-?\d+$/ || $stop !~ /^\-?\d+$/ || $start > $#{ $self } ) {
      return ();
   }

   if ( $start < 0 ) {
      $start = @{ $self } + $start;
      $start = 0 if $start < 0;
   }

   if ( $stop < 0 ) {
      $stop = @{ $self } + $stop;
      $stop = 0 if $stop < 0;
   }
   else {
      $stop = $#{ $self } if $stop > $#{ $self };
   }

   @{ $self }[ $start .. $stop ];
}

# sort ( "BY val [ ASC | DESC ] [ ALPHA ]" )
# sort ( "[ ASC | DESC ] [ ALPHA ]" ) # same as "BY val ..."

sub sort {
   my ( $self, $request ) = @_;
   my ( $alpha, $desc ) = ( 0, 0 );

   if ( length $request ) {
      $alpha = 1 if ( $request =~ /\balpha\b/i );
      $desc  = 1 if ( $request =~ /\bdesc\b/i );
   }

   # Return sorted values, leaving the data intact.

   if ( defined wantarray ) {
      if ( $alpha ) { ( $desc )
       ? CORE::sort { $b cmp $a } @{ $self }
       : CORE::sort { $a cmp $b } @{ $self };
      }
      else { ( $desc )
       ? CORE::sort { $b <=> $a } @{ $self }
       : CORE::sort { $a <=> $b } @{ $self };
      }
   }

   # Sort values in-place otherwise, in void context.

   elsif ( $alpha ) { ( $desc )
    ? $self->_reorder( CORE::sort { $b cmp $a } @{ $self } )
    : $self->_reorder( CORE::sort { $a cmp $b } @{ $self } );
   }
   else { ( $desc )
    ? $self->_reorder( CORE::sort { $b <=> $a } @{ $self } )
    : $self->_reorder( CORE::sort { $a <=> $b } @{ $self } );
   }
}

sub _reorder {
   my $self = shift; @{ $self } = @_; 

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Sugar API, mostly resembles http://redis.io/commands#string primitives.
##
###############################################################################

# append ( index, string )

sub append {
   length( $_[0]->[ $_[1] ] .= $_[2] // '' );
}

# decr    ( index )
# decrby  ( index, number )
# incr    ( index )
# incrby  ( index, number )
# getdecr ( index )
# getincr ( index )

sub decr    { --$_[0]->[ $_[1] ]               }
sub decrby  {   $_[0]->[ $_[1] ] -= $_[2] || 0 }
sub incr    { ++$_[0]->[ $_[1] ]               }
sub incrby  {   $_[0]->[ $_[1] ] += $_[2] || 0 }
sub getdecr {   $_[0]->[ $_[1] ]--        // 0 }
sub getincr {   $_[0]->[ $_[1] ]++        // 0 }

# getset ( index, value )

sub getset {
   my $old = $_[0]->[ $_[1] ];
   $_[0]->[ $_[1] ] = $_[2];

   $old;
}

# len ( index )
# len ( )

sub len {
   ( defined $_[1] )
      ? length $_[0]->[ $_[1] ]
      : scalar @{ $_[0] };
}

{
   no strict 'refs';

   *{ __PACKAGE__.'::new'     } = \&TIEARRAY;
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

1;

__END__

###############################################################################
## ----------------------------------------------------------------------------
## Module usage.
##
###############################################################################

=head1 NAME

MCE::Shared::Array - Array helper class

=head1 VERSION

This document describes MCE::Shared::Array version 1.700

=head1 SYNOPSIS

   # non-shared
   use MCE::Shared::Array;

   my $ar = MCE::Shared::Array->new( @list );

   # shared
   use MCE::Shared;

   my $ar = MCE::Shared->array( @list );

   # oo interface
   $val   = $ar->set( $index, $val );
   $val   = $ar->get( $index);
   $val   = $ar->delete( $index );            # del is an alias for delete
   $bool  = $ar->exists( $index );
   void   = $ar->clear();
   $len   = $ar->len();                       # scalar @{ $ar }
   $len   = $ar->len( $index );               # length $ar->[ $index ]
   $val   = $ar->pop();
   $len   = $ar->push( @list );
   $val   = $ar->shift();
   $len   = $ar->unshift( @list );
   @list  = $ar->splice( $offset, $length, @list );

   $ar2   = $ar->clone( @indices );           # @indices is optional
   $ar3   = $ar->flush( @indices );
   $iter  = $ar->iterator( @indices );        # ($idx, $val) = $iter->()
   @keys  = $ar->keys( @indices );
   %pairs = $ar->pairs( @indices );
   @vals  = $ar->values( @indices );          # vals is an alias for values

   $cnt   = $ar->mdel( @indices );
   @vals  = $ar->mget( @indices );
   $bool  = $ar->mexists( @indices );         # true if all indices exists
   $len   = $ar->mset( $idx/$val pairs );     # merge is an alias for mset

   @vals  = $ar->range( $start, $stop );

   @vals  = $ar->sort();                      # $a <=> $b default
   @vals  = $ar->sort( "desc" );              # $b <=> $a
   @vals  = $ar->sort( "alpha" );             # $a cmp $b
   @vals  = $ar->sort( "alpha desc" );        # $b cmp $a

   # search capability key/val { =~ !~ eq ne lt le gt ge == != < <= > >= }
   # key/val means to match against actual key/val respectively
   # do not add quotes inside the string unless intended literally
   # do not mix :AND(s) and :OR(s) together

   @keys  = $ar->keys( "key =~ /$pattern/i" );
   @keys  = $ar->keys( "key !~ /$pattern/i" );
   @keys  = $ar->keys( "val =~ /$pattern/i" );
   @keys  = $ar->keys( "val !~ /$pattern/i" );

   %pairs = $ar->pairs( "key == $number" );
   %pairs = $ar->pairs( "key != $number :AND val > 100" );
   %pairs = $ar->pairs( "key <  $number :OR key > $number" );
   %pairs = $ar->pairs( "val <= $number" );
   %pairs = $ar->pairs( "val >  $number" );
   %pairs = $ar->pairs( "val >= $number" );

   @vals  = $ar->values( "key eq $string" );
   @vals  = $ar->values( "key ne $string with space" );
   @vals  = $ar->values( "key lt $string :OR val =~ /$pat1|$pat2/" );
   @vals  = $ar->values( "val le $string :AND val eq foo bar" );
   @vals  = $ar->values( "val gt $string" );
   @vals  = $ar->values( "val ge $string" );

   # sugar methods without having to call set/get explicitly

   $len   = $ar->append( $index, $string );   #   $val .= $string
   $val   = $ar->decr( $index );              # --$val
   $val   = $ar->decrby( $index, $number );   #   $val -= $number
   $val   = $ar->getdecr( $index );           #   $val--
   $val   = $ar->getincr( $index );           #   $val++
   $val   = $ar->incr( $index );              # ++$val
   $val   = $ar->incrby( $index, $number );   #   $val += $number
   $old   = $ar->getset( $index, $new );      #   $o = $v, $v = $n, $o

=head1 DESCRIPTION

An array helper class for use with L<MCE::Shared>.

=head1 SYNTAX for QUERY STRING

Several methods in C<MCE::Shared::Array> take a query string for an argument.
The format of the string is quoteless. Therefore, any quotes inside the string
is treated literally.

   o Basic demonstration: @keys = $ar->keys( "val =~ /pattern/" );
   o Supported operators: =~ !~ eq ne lt le gt ge == != < <= > >=
   o Multiple expressions are delimited by :AND or :OR.

     "key =~ /pattern/i :AND val =~ /pattern/i"
     "key =~ /pattern/i :AND val eq foo bar"     # val eq "foo bar"
     "val eq foo baz :OR key !~ /pattern/i"

     * key matches on indices in the array
     * val matches on values

=over 3

=item * The modifiers C<:AND> and C<:OR> may be mixed case. e.g. C<:And>

=item * Mixing C<:AND> and C<:OR> in the query is not supported.

=back

=head1 API DOCUMENTATION

This module may involve TIE when accessing the object via array-like behavior.
Only shared instances are impacted if doing so. Although likely fast enough for
many use cases, use the OO interface if better performance is desired.

=over 3

=item new ( val [, val, ... ] )

Constructs a new object, with an optional list of values.

   # non-shared
   use MCE::Shared::Array;

   $ar = MCE::Shared::Array->new( @list );
   $ar = MCE::Shared::Array->new( );

   # shared
   use MCE::Shared;

   $ar = MCE::Shared->array( @list );
   $ar = MCE::Shared->array( );

=item clear

Removes all elements from the array.

   $ar->clear;
   @{$ar} = ();

=item clone ( index [, index, ... ] )

Creates a shallow copy, a C<MCE::Shared::Array> object. It returns an exact
copy if no arguments are given. Otherwise, the object includes only the given
indices in the same order. Indices that do not exist in the array will have
the C<undef> value.

   $ar2 = $ar->clone( 0, 1 );
   $ar2 = $ar->clone;

=item delete ( index )

Deletes and returns the value associated by index or C<undef> if index exceeds
the size of the list.

   $val = $ar->delete( 20 );
   $val = delete $ar->[ 20 ];

=item del

C<del> is an alias for C<delete>.

=item exists ( index )

Determines if an element by its index exists in the array. The behavior is
strongly tied to the use of delete on lists.

   $ar->push(qw/ value0 value1 value2 value3 /);

   $ar->exists( 2 );     # True
   $ar->exists( 2, 3 );  # True
   $ar->delete( 2 );     # value2

   $ar->exists( 2 );     # False
   $ar->exists( 2, 3 );  # False
   $ar->exists( 3 );     # True

   exists $ar->[ 3 ];

=item flush ( index [, index, ... ] )

Same as C<clone>. Though, clears all existing items before returning.

=item get ( index )

Gets the value of an element by its index or C<undef> if the index does not
exists.

   $val = $ar->get( 2 );
   $val = $ar->[ 2 ];

=item iterator ( index [, index, ... ] )

Returns a code reference for iterating a list of index-value pairs stored in
the array when no arguments are given. Otherwise, returns a code reference for
iterating the given indices in the same order. Indices that do not exist will
have the C<undef> value.

The list of indices to return is set when the closure is constructed. New
indices added later are not included. Subsequently, the C<undef> value is
returned for deleted indices.

   $iter = $ar->iterator;
   $iter = $ar->iterator( 0, 1 );

   while ( my ( $index, $val ) = $iter->() ) {
      ...
   }

=item iterator ( "query string" )

Returns a code reference for iterating a list of index-value pairs that match
the given criteria. It returns an empty list if the search found nothing.
The syntax for the C<query string> is described above.

   $iter = $ar->iterator( "val eq some_value" );
   $iter = $ar->iterator( "key >= 50 :AND val =~ /sun|moon|air|wind/" );
   $iter = $ar->iterator( "val eq sun :OR val eq moon :OR val eq foo" );
   $iter = $ar->iterator( "key =~ /$pattern/" );

   while ( my ( $index, $val ) = $iter->() ) {
      ...
   }

=item keys ( index [, index, ... ] )

Returns all indices in the array when no arguments are given. Otherwise,
returns the given indices in the same order. Indices that do not exist will
have the C<undef> value. In scalar context, returns the size of the array.

   @keys = $ar->keys;
   @keys = $ar->keys( 0, 1 );
   $len  = $ar->keys;

=item keys ( "query string" )

Returns only indices that match the given criteria. It returns an empty list
if the search found nothing. The syntax for the C<query string> is described
above. In scalar context, returns the size of the resulting list.

   @keys = $ar->keys( "val eq some_value" );
   @keys = $ar->keys( "key >= 50 :AND val =~ /sun|moon|air|wind/" );
   @keys = $ar->keys( "val eq sun :OR val eq moon :OR val eq foo" );
   $len  = $ar->keys( "key =~ /$pattern/" );

=item len ( index )

Returns the size of the array when no arguments are given. For the given
index, returns the length of the value stored at index or the C<undef> value
if the index does not exists.

   $len = $ar->len;
   $len = $ar->len( 0 );
   $len = length $ar->[ 0 ];

=item mdel ( index [, index, ... ] )

Deletes one or more elements by its index and returns the number of indices
deleted. A given index which does not exist in the list is not counted.

   $cnt = $ar->mdel( 0, 1 );

=item mexists ( index [, index, ... ] )

Returns a true value if all given indices exists in the list. A false value is
returned otherwise.

   if ( $ar->mexists( 0, 1 ) ) { ... }

=item mget ( index [, index, ... ] )

Gets multiple values from the list by its index. It returns C<undef> for indices
which do not exists in the list.

   ( $val1, $val2 ) = $ar->mget( 0, 1 );

=item mset ( index, value [, index, value, ... ] )

Sets multiple index-value pairs in the list and returns the length of the list.

   $len = $ar->mset( 0 => "val1", 1 => "val2" );

=item merge

C<merge> is an alias for C<mset>.

=item pairs ( "query string" )

Returns index-value pairs in the array when no arguments are given. Otherwise,
returns index-value pairs for the given indices in the same order. Indices that
do not exist will have the C<undef> value. In scalar context, returns the size
of the array.

   @pairs = $ar->pairs;
   @pairs = $ar->pairs( 0, 1 );
   $len   = $ar->pairs;

=item pairs ( index [, index, ... ] )

Returns only index-value pairs that match the given criteria. It returns an
empty list if the search found nothing. The syntax for the C<query string> is
described above. In scalar context, returns the size of the resulting list.

   @pairs = $ar->pairs( "val eq some_value" );
   @pairs = $ar->pairs( "key >= 50 :AND val =~ /sun|moon|air|wind/" );
   @pairs = $ar->pairs( "val eq sun :OR val eq moon :OR val eq foo" );
   $len   = $ar->pairs( "key =~ /$pattern/" );

=item pop

Removes and returns the last value of the list. If there are no elements in the
list, returns the undefined value.

   $val = $ar->pop;

=item push ( value [, value, ... ] )

Appends one or multiple values to the tail of the list and returns the new
length.

   $len = $ar->push( "val1", "val2" );

=item set ( index, value )

Sets the value of the given array index and returns its new value.

   $val = $ar->set( 2, "value" );
   $val = $ar->[ 2 ] = "value";

=item shift

Removes and returns the first value of the list. If there are no elements in the
list, returns the undefined value.

   $val = $ar->shift;

=item range ( start, stop )

Returns the specified elements of the list. The offsets C<start> and C<stop>
can also be negative numbers indicating offsets starting at the end of the
list.

An empty list is returned if C<start> is larger than the end of the list.
C<stop> is set to the last index of the list if larger than the actual end
of the list.

   @list = $ar->range( 20, 29 );
   @list = $ar->range( -4, -1 );

=item sort ( "BY val [ ASC | DESC ] [ ALPHA ]" )

Returns sorted values in list context, leaving the elements intact. In void
context, sorts the list in-place. By default, sorting is numeric when no
arguments are given. The C<BY val> modifier is optional and may be omitted.

   @vals = $ar->sort( "BY val" );

   $ar->sort();

If the list contains string values and you want to sort them lexicographically,
specify the C<ALPHA> modifier.

   @vals = $ar->sort( "BY val ALPHA" );

   $ar->sort( "ALPHA" );

The default is C<ASC> for sorting the list from small to large. In order to
sort the list from large to small, specify the C<DESC> modifier.

   @vals = $ar->sort( "DESC ALPHA" );

   $ar->sort( "DESC ALPHA" );

=item splice ( offset [, length [, list ] ] )

Removes the elements designated by C<offset> and C<length> from the array, and
replaces them with the elements of C<list>, if any. The behavior is similar to
the Perl C<splice> function.

   @items = $ar->splice( 20, 2, @list );
   @items = $ar->splice( 20, 2 );
   @items = $ar->splice( 20 );

=item unshift ( value [, value, ... ] )

Prepends one or multiple values to the head of the list and returns the new
length.

   $len = $ar->unshift( "val1", "val2" );

=item values ( index [, index, ... ] )

Returns all values in the array when no arguments are given. Otherwise, returns
values for the given indices in the same order. Indices that do not exist will
have the C<undef> value. In scalar context, returns the size of the array.

   @vals = $ar->values;
   @vals = $ar->values( 0, 1 );
   $len  = $ar->values;

=item values ( "query string" )

Returns only values that match the given criteria. It returns an empty list
if the search found nothing. The syntax for the C<query string> is described
above. In scalar context, returns the size of the resulting list.

   @keys = $ar->values( "val eq some_value" );
   @keys = $ar->values( "key >= 50 :AND val =~ /sun|moon|air|wind/" );
   @keys = $ar->values( "val eq sun :OR val eq moon :OR val eq foo" );
   $len  = $ar->values( "key =~ /$pattern/" );

=item vals

C<vals> is an alias for C<values>.

=back

=head1 SUGAR METHODS

This module is equipped with sugar methods to not have to call C<set>
and C<get> explicitly. The API resembles a subset of the Redis primitives
L<http://redis.io/commands#strings> with key representing the array index.

=over 3

=item append ( key, string )

Appends a value to a key and returns its new length.

   $len = $ar->append( 0, "foo" );

=item decr ( key )

Decrements the value of a key by one and returns its new value.

   $num = $ar->decr( 0 );

=item decrby ( key, number )

Decrements the value of a key by the given number and returns its new value.

   $num = $ar->decrby( 0, 2 );

=item getdecr ( key )

Decrements the value of a key by one and returns its old value.

   $old = $ar->getdecr( 0 );

=item getincr ( key )

Increments the value of a key by one and returns its old value.

   $old = $ar->getincr( 0 );

=item getset ( key, value )

Sets the value of a key and returns its old value.

   $old = $ar->getset( 0, "baz" );

=item incr ( key )

Increments the value of a key by one and returns its new value.

   $num = $ar->incr( 0 );

=item incrby ( key, number )

Increments the value of a key by the given number and returns its new value.

   $num = $ar->incrby( 0, 2 );

=back

=head1 CREDITS

The implementation is inspired by L<Tie::StdArray>.

=head1 INDEX

L<MCE|MCE>, L<MCE::Core>, L<MCE::Shared>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

