###############################################################################
## ----------------------------------------------------------------------------
## Array helper class.
##
###############################################################################

package MCE::Shared::Array;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized numeric );

our $VERSION = '1.699_010';

## no critic (TestingAndDebugging::ProhibitNoStrict)

use MCE::Shared::Base;
use bytes;

use overload (
   q("")    => \&MCE::Shared::Base::_stringify,
   q(0+)    => \&MCE::Shared::Base::_numify,
   fallback => 1
);

no overloading;

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
sub POP       { pop(@{ $_[0] }) }
sub PUSH      { my $o = shift; push(@$o, @_) }
sub SHIFT     { shift(@{ $_[0] }) }
sub UNSHIFT   { my $o = shift; unshift(@$o, @_) }

# SPLICE ( offset, length [, list ] )

sub SPLICE {
   my $ob  = shift;
   my $sz  = $ob->FETCHSIZE;
   my $off = @_ ? shift : 0;
   $off   += $sz if $off < 0;
   my $len = @_ ? shift : $sz-$off;
   return splice(@$ob, $off, $len, @_);
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
#     key means to match against indices in the array
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

   MCE::Shared::Base::_find_array(
      $self, $params, $query, 0 .. $#{ $self }
   );
}

# clone ( key [, key, ... ] )
# clone ( )

sub clone {
   my $self = shift;
   my $params = ref($_[0]) eq 'HASH' ? shift : {};
   my ( @data, $key );

   if ( @_ ) {
      while ( @_ ) {
         $key = shift;
         push @data, $self->[ $key ];
      }
   }
   else {
      @data = @{ $self };
   }

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

   if ( !scalar @keys ) {
      @keys = ( 0 .. $#{ $self } );
   }
   elsif ( @keys == 1 && $keys[0] =~ /^(?:key|val)[ ]+\S\S?[ ]+\S/ ) {
      @keys = $self->keys($keys[0]);
   }

   return sub {
      return unless @keys;
      my $key = shift(@keys);
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
         ( scalar @{ $self } ) << 1;
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
      $cnt++, delete($self->[ $key ]) if exists($self->[ $key ]);
   }

   $cnt;
}

# mexists ( index [, index, ... ] )

sub mexists {
   my $self = shift;
   my $key;

   while ( @_ ) {
      $key = shift;
      return '' if ( !exists $self->[ $key ] );
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
      $alpha = 1 if $request =~ /\balpha\b/i;
      $desc  = 1 if $request =~ /\bdesc\b/i;
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
   $_[0]->[ $_[1] ] .= $_[2] || '';
   length $_[0]->[ $_[1] ];
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
sub getdecr {   $_[0]->[ $_[1] ]--        || 0 }
sub getincr {   $_[0]->[ $_[1] ]++        || 0 }

# getset ( index, value )

sub getset { my $old = $_[0]->[ $_[1] ]; $_[0]->[ $_[1] ] = $_[2]; $old }

# len ( index )
# len ( )

sub len {
   ( defined $_[1] )
      ? length $_[0]->[ $_[1] ] || 0
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

This document describes MCE::Shared::Array version 1.699_010

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
   # query string is quoteless, otherwise quote(s) are treated literally
   # key/val means to match against actual key/val respectively
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

An array helper class for use with L<MCE::Shared|MCE::Shared>.

=head1 QUERY STRING

Several methods in C<MCE::Shared::Array> receive a query string argument.
The string is quoteless. Basically, any quotes inside the string will be
treated literally.

   Search capability { =~ !~ eq ne lt le gt ge == != < <= > >= }

   "key =~ /pattern/i :AND val =~ /pattern/i"
   "key =~ /pattern/i :AND val eq foo bar"     # val eq foo bar
   "val eq foo baz :OR key !~ /pattern/i"

      key means to match against indices in the array
      likewise, val means to match against values

   :AND(s) and :OR(s) mixed together is not supported

=head1 API DOCUMENTATION

To be completed before the final 1.700 release.

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

=item clone ( index [, index, ... ] )

=item clone

=item delete ( index )

=item del

C<del> is an alias for C<delete>.

=item exists ( index )

=item flush ( index [, index, ... ] )

=item flush

Same as C<clone>. Though, clears all existing items before returning.

=item get ( index )

=item iterator ( index [, index, ... ] )

=item iterator ( "query string" )

=item iterator

=item keys ( index [, index, ... ] )

=item keys ( "query string" )

=item keys

=item len ( index )

Returns the length of the value stored at index.

   $len = $ar->len( 0 );

=item len

Returns the length of the list.

   $len = $ar->len;

=item mdel ( index [, index, ... ] )

=item mexists ( index [, index, ... ] )

=item mget ( index [, index, ... ] )

=item mset ( index, value [, index, value, ... ] )

=item merge

C<merge> is an alias for C<mset>.

=item pairs ( index [, index, ... ] )

=item pairs ( "query string" )

=item pairs

=item pop

=item push ( list )

=item set ( index, value )

=item shift

=item range ( start, stop )

=item sort ( "BY val [ ASC | DESC ] [ ALPHA ]" )

=item sort ( "[ ASC | DESC ] [ ALPHA ]" )

=item splice ( offset, length, list )

=item unshift ( list )

=item values ( index [, index, ... ] )

=item values ( "query string" )

=item values

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

   $len = $ar->append( 0, 'foo' );

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

   $old = $ar->getset( 0, 'baz' );

=item incr ( key )

Increments the value of a key by one and returns its new value.

   $num = $ar->incr( 0 );

=item incrby ( key, number )

Increments the value of a key by the given number and returns its new value.

   $num = $ar->incrby( 0, 2 );

=back

=head1 CREDITS

The implementation is inspired by L<Tie::StdArray|Tie::StdArray>.

=head1 INDEX

L<MCE|MCE>, L<MCE::Core|MCE::Core>, L<MCE::Shared|MCE::Shared>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

