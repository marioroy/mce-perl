###############################################################################
## ----------------------------------------------------------------------------
## Hash class for use with MCE::Shared.
##
###############################################################################

package MCE::Shared::Hash;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized );

our $VERSION = '1.699_003';

## no critic (BuiltinFunctions::ProhibitStringyEval)
## no critic (TestingAndDebugging::ProhibitNoStrict)

use MCE::Shared::Base;
use base 'MCE::Shared::Base';
use bytes;

use overload (
   q("")    => \&MCE::Shared::Base::_stringify_h,
   q(0+)    => \&MCE::Shared::Base::_numify,
   fallback => 1
);

sub _croak {
   goto &MCE::Shared::Base::_croak;
}

sub TIEHASH {
   my $self = bless {}, shift;
   $self->mset(@_) if @_;
   $self;
}

## Based on Tie::StdHash from Tie::Hash.

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
## clone, flush, iterator, mget, mset, keys, values, pairs
##
###############################################################################

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

sub flush {
   shift()->clone( { flush => 1 }, @_ );
}

sub iterator {
   my ( $self, @keys ) = @_;
   @keys = CORE::keys %{ $self } unless @keys;

   return sub {
      return unless @keys;
      my $key = shift(@keys);
      return ( $key => $self->{ $key } );
   };
}

sub mget {
   my $self = shift;

   @_ ? @{ $self }{ @_ }
      : ();
}

sub mset {
   my ( $self, $key ) = ( shift );

   while ( @_ ) {
      $key = shift, $self->{ $key } = shift;
   }

   scalar CORE::keys %{ $self };
}

sub keys {
   my $self = shift;

   if ( wantarray ) {
      @_ ? map { exists $self->{ $_ } ? $_ : undef } @_
         : CORE::keys %{ $self };
   }
   else {
      scalar CORE::keys %{ $self };
   }
}

sub values {
   my $self = shift;

   if ( wantarray ) {
      @_ ? @{ $self }{ @_ }
         : CORE::values %{ $self };
   }
   else {
      scalar CORE::keys %{ $self };
   }
}

sub pairs {
   my $self = shift;

   if ( wantarray ) {
      @_ ? map { $_ => $self->{ $_ } } @_
         : %{ $self };
   }
   else {
      ( scalar CORE::keys %{ $self } ) << 1;
   }
}

###############################################################################
## ----------------------------------------------------------------------------
## find
##
###############################################################################

sub find {
   my ( $self, $search ) = @_;
   my ( $attr, $op, $expr ) = split( /\s+/, $search, 3 );

   ## Returns ( KEY, VALUE ) pairs where KEY matches expression.

   if ( $attr eq 'key' ) {
      my $_find = $self->_find_keys_hash();

      _croak('Find error: invalid OPCODE') unless length $op;
      _croak('Find error: invalid OPCODE') unless exists $_find->{ $op };
      _croak('Find error: invalid EXPR'  ) unless length $expr;

      $expr = undef if $expr eq 'undef';

      $_find->{ $op }->( $self, $expr, CORE::keys %{ $self } );
   }

   ## Returns ( KEY, VALUE ) pairs where VALUE matches expression.

   elsif ( $attr eq 'val' || $attr eq 'value' ) {
      my $_find = $self->_find_vals_hash();

      _croak('Find error: invalid OPCODE') unless length $op;
      _croak('Find error: invalid OPCODE') unless exists $_find->{ $op };
      _croak('Find error: invalid EXPR'  ) unless length $expr;

      $expr = undef if $expr eq 'undef';

      $_find->{ $op }->( $self, $expr, CORE::keys %{ $self } );
   }

   ## Error.

   else {
      _croak('Find error: invalid ATTR');
   }
}

###############################################################################
## ----------------------------------------------------------------------------
## append, decr, decrby, incr, incrby, pdecr, pincr
##
###############################################################################

sub append {   $_[0]->{ $_[1] } .= $_[2] || '' ; length $_[0]->{ $_[1] } }
sub decr   { --$_[0]->{ $_[1] }                }
sub decrby {   $_[0]->{ $_[1] } -= $_[2] || 0  }
sub incr   { ++$_[0]->{ $_[1] }                }
sub incrby {   $_[0]->{ $_[1] } += $_[2] || 0  }
sub pdecr  {   $_[0]->{ $_[1] }--              }
sub pincr  {   $_[0]->{ $_[1] }++              }

sub length {
   ( defined $_[1] )
      ? CORE::length( $_[0]->{ $_[1] } )
      : scalar CORE::keys %{ $_[0] };
}

## Aliases.

{
   no strict 'refs';
   *{ __PACKAGE__.'::new'    } = \&TIEHASH;
   *{ __PACKAGE__.'::set'    } = \&STORE;
   *{ __PACKAGE__.'::get'    } = \&FETCH;
   *{ __PACKAGE__.'::delete' } = \&DELETE;
   *{ __PACKAGE__.'::exists' } = \&EXISTS;
   *{ __PACKAGE__.'::clear'  } = \&CLEAR;
}

1;

__END__

###############################################################################
## ----------------------------------------------------------------------------
## Module usage.
##
###############################################################################

=head1 NAME

MCE::Shared::Hash - Class for sharing hashes via MCE::Shared

=head1 VERSION

This document describes MCE::Shared::Hash version 1.699_003

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
   $val   = $ha->delete( $key );
   $bool  = $ha->exists( $key );
   void   = $ha->clear();
   $len   = $ha->length();                    # scalar keys %{ $ha }
   $len   = $ha->length( $key );              # length $ha->{ $key }

   $ha2   = $ha->clone( @keys );              # @keys is optional
   $ha3   = $ha->flush( @keys );
   $iter  = $ha->iterator( @keys );           # ($key, $val) = $iter->()
   $len   = $ha->mset( $key/$val pairs );
   @vals  = $ha->mget( @keys );
   @keys  = $ha->keys( @keys );
   @vals  = $ha->values( @keys );
   %pairs = $ha->pairs( @keys );

   %pairs = $ha->find( "val =~ /$pattern/i" );
   %pairs = $ha->find( "val !~ /$pattern/i" );
   %pairs = $ha->find( "key =~ /$pattern/i" );
   %pairs = $ha->find( "key !~ /$pattern/i" );

   %pairs = $ha->find( "val eq $string" );    # also, search key
   %pairs = $ha->find( "val ne $string" );
   %pairs = $ha->find( "val lt $string" );
   %pairs = $ha->find( "val le $string" );
   %pairs = $ha->find( "val gt $string" );
   %pairs = $ha->find( "val ge $string" );

   %pairs = $ha->find( "val == $number" );    # ditto, find( "key ..." )
   %pairs = $ha->find( "val != $number" );
   %pairs = $ha->find( "val <  $number" );
   %pairs = $ha->find( "val <= $number" );
   %pairs = $ha->find( "val >  $number" );
   %pairs = $ha->find( "val >= $number" );

   # sugar methods without having to call set/get explicitly
   $len   = $ha->append( $key, $string );     #   $val .= $string
   $val   = $ha->decr( $key );                # --$val
   $val   = $ha->decrby( $key, $number );     #   $val -= $number
   $val   = $ha->incr( $key );                # ++$val
   $val   = $ha->incrby( $key, $number );     #   $val += $number
   $val   = $ha->pdecr( $key );               #   $val--
   $val   = $ha->pincr( $key );               #   $val++

=head1 DESCRIPTION

Helper class for L<MCE::Shared|MCE::Shared>.

=head1 API DOCUMENTATION

To be completed before the final 1.700 release.

=over 3

=item new

=item set

=item get

=item delete

=item exists

=item clear

=item length

=item clone

=item flush

=item iterator

=item mget

=item mset

=item keys

=item values

=item pairs

=item find

=item append

=item decr

=item decrby

=item incr

=item incrby

=item pdecr

=item pincr

=back

=head1 CREDITS

Implementation inspired by L<Tie::StdHash|Tie::StdHash>.

=head1 INDEX

L<MCE|MCE>, L<MCE::Core|MCE::Core>, L<MCE::Shared|MCE::Shared>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

