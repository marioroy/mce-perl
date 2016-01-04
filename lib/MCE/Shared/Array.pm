###############################################################################
## ----------------------------------------------------------------------------
## Array helper class.
##
###############################################################################

package MCE::Shared::Array;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized numeric );

our $VERSION = '1.699_004';

## no critic (BuiltinFunctions::ProhibitStringyEval)
## no critic (TestingAndDebugging::ProhibitNoStrict)

use MCE::Shared::Base;
use base 'MCE::Shared::Base';
use bytes;

use overload (
   q("")    => \&MCE::Shared::Base::_stringify_a,
   q(0+)    => \&MCE::Shared::Base::_numify,
   fallback => 1
);

sub _croak {
   goto &MCE::Shared::Base::_croak;
}

sub TIEARRAY {
   my $self = bless [], shift;
   $self->PUSH(@_) if @_;
   $self;
}

sub EXTEND { }

## Based on Tie::StdArray from Tie::Array.

sub FETCHSIZE { scalar @{$_[0]} }
sub STORESIZE { $#{$_[0]} = $_[1] - 1 }
sub STORE     { $_[0]->[$_[1]] = $_[2] }
sub FETCH     { $_[0]->[$_[1]] }
sub DELETE    { delete $_[0]->[$_[1]] }
sub EXISTS    { exists $_[0]->[$_[1]] }
sub CLEAR     { @{$_[0]} = () }
sub POP       { pop(@{$_[0]}) }
sub PUSH      { my $o = shift; push(@$o, @_) }
sub SHIFT     { shift(@{$_[0]}) }
sub UNSHIFT   { my $o = shift; unshift(@$o, @_) }

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
## clone, flush, iterator, mget, mset, keys, values, pairs
##
###############################################################################

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

sub flush  {
   shift()->clone( { flush => 1 }, @_ );
}

sub iterator {
   my ( $self, @keys ) = @_;
   @keys = ( 0 .. $#{ $self } ) unless @keys;

   return sub {
      return unless @keys;
      my $key = shift(@keys);
      return ( $key => $self->[ $key ] );
   };
}

sub mget {
   my $self = shift;

   @_ ? @{ $self }[ @_ ]
      : ();
}

sub mset {
   my ( $self, $key ) = ( shift );

   while ( @_ ) {
      $key = shift, $self->[ $key ] = shift;
   }

   scalar @{ $self };
}

sub keys {
   my $self = shift;

   if ( wantarray ) {
      @_ ? map { exists $self->[ $_ ] ? $_ : undef } @_
         : ( 0 .. $#{ $self } );
   }
   else {
      scalar @{ $self };
   }
}

sub values {
   my $self = shift;

   if ( wantarray ) {
      @_ ? @{ $self }[ @_ ]
         : @{ $self }
   }
   else {
      scalar @{ $self };
   }
}

sub pairs {
   my $self = shift;

   if ( wantarray ) {
      @_ ? map { $_ => $self->[ $_ ] } @_
         : map { $_ => $self->[ $_ ] } 0 .. $#{ $self };
   }
   else {
      ( scalar @{ $self } ) << 1;
   }
}

###############################################################################
## ----------------------------------------------------------------------------
## find, sort
##
###############################################################################

sub find {
   my ( $self, $search ) = @_;
   my ( $attr, $op, $expr ) = split( /\s+/, $search, 3 );

   ## Returns ( IDX, VALUE ) pairs where VALUE matches expression.

   if ( $attr eq 'val' || $attr eq 'value' ) {
      my $_find = $self->_find_vals_array();

      _croak('Find error: invalid OPCODE') unless length $op;
      _croak('Find error: invalid OPCODE') unless exists $_find->{ $op };
      _croak('Find error: invalid EXPR'  ) unless length $expr;

      $expr = undef if $expr eq 'undef';

      $_find->{ $op }->( $self, $expr, 0 .. $#{ $self } );
   }

   ## Error.

   else {
      _croak('Find error: invalid ATTR');
   }
}

sub sort {
   my ( $self, $request ) = @_;
   my ( $alpha, $desc ) = ( 0, 0 );

   if ( length $request ) {
      $alpha = 1 if $request =~ /alpha/i;
      $desc  = 1 if $request =~ /desc/i;
   }

   if ( $alpha ) { ( $desc )
      ? CORE::sort { $b cmp $a } @{ $self }
      : CORE::sort { $a cmp $b } @{ $self };
   }
   else { ( $desc )
      ? CORE::sort { $b <=> $a } @{ $self }
      : CORE::sort { $a <=> $b } @{ $self };
   }
}

###############################################################################
## ----------------------------------------------------------------------------
## append, decr, decrby, incr, incrby, pdecr, pincr
##
###############################################################################

sub append {   $_[0]->[ $_[1] ] .= $_[2] || '' ; length $_[0]->[ $_[1] ] }
sub decr   { --$_[0]->[ $_[1] ]                }
sub decrby {   $_[0]->[ $_[1] ] -= $_[2] || 0  }
sub incr   { ++$_[0]->[ $_[1] ]                }
sub incrby {   $_[0]->[ $_[1] ] += $_[2] || 0  }
sub pdecr  {   $_[0]->[ $_[1] ]--              }
sub pincr  {   $_[0]->[ $_[1] ]++              }

sub length {
   ( defined $_[1] )
      ? CORE::length( $_[0]->[ $_[1] ] )
      : scalar @{ $_[0] };
}

## Aliases.

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

This document describes MCE::Shared::Array version 1.699_004

=head1 SYNOPSIS

   # non-shared
   use MCE::Shared::Array;

   my $ar = MCE::Shared::Array->new( @list );

   # shared
   use MCE::Shared;

   my $ar = MCE::Shared->array( @list );

   # oo interface
   $val   = $ar->set( $idx, $val );
   $val   = $ar->get( $idx);
   $val   = $ar->delete( $idx );
   $bool  = $ar->exists( $idx );
   void   = $ar->clear();
   $len   = $ar->length();                    # scalar @{ $ar }
   $len   = $ar->length( $idx );              # length $ar->[ $idx ]
   $val   = $ar->pop();
   $len   = $ar->push( @list );
   $val   = $ar->shift();
   $len   = $ar->unshift( @list );
   @list  = $ar->splice( $offset, $length, @list );

   $ar2   = $ar->clone( @indices );           # @indices is optional
   $ar3   = $ar->flush( @indices );
   $iter  = $ar->iterator( @indices );        # ($idx, $val) = $iter->()
   $len   = $ar->mset( $idx/$val pairs );
   @vals  = $ar->mget( @indices );
   @keys  = $ar->keys( @indices );
   @vals  = $ar->values( @indices );
   %pairs = $ar->pairs( @indices );

   @vals  = $ar->sort();                      # $a <=> $b default
   @vals  = $ar->sort( "desc" );              # $b <=> $a
   @vals  = $ar->sort( "alpha" );             # $a cmp $b
   @vals  = $ar->sort( "alpha desc" );        # $b cmp $a

   %pairs = $ar->find( "val =~ /$pattern/i" );
   %pairs = $ar->find( "val !~ /$pattern/i" );

   %pairs = $ar->find( "val eq $string" );
   %pairs = $ar->find( "val ne $string" );
   %pairs = $ar->find( "val lt $string" );
   %pairs = $ar->find( "val le $string" );
   %pairs = $ar->find( "val gt $string" );
   %pairs = $ar->find( "val ge $string" );

   %pairs = $ar->find( "val == $number" );
   %pairs = $ar->find( "val != $number" );
   %pairs = $ar->find( "val <  $number" );
   %pairs = $ar->find( "val <= $number" );
   %pairs = $ar->find( "val >  $number" );
   %pairs = $ar->find( "val >= $number" );

   # sugar methods without having to call set/get explicitly
   $len   = $ar->append( $idx, $string );     #   $val .= $string
   $val   = $ar->decr( $idx );                # --$val
   $val   = $ar->decrby( $idx, $number );     #   $val -= $number
   $val   = $ar->incr( $idx );                # ++$val
   $val   = $ar->incrby( $idx, $number );     #   $val += $number
   $val   = $ar->pdecr( $idx );               #   $val--
   $val   = $ar->pincr( $idx );               #   $val++

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

=item pop

=item push

=item shift

=item unshift

=item splice

=item clone

=item flush

=item iterator

=item mget

=item mset

=item keys

=item values

=item pairs

=item find

=item sort

=item append

=item decr

=item decrby

=item incr

=item incrby

=item pdecr

=item pincr

=back

=head1 CREDITS

Implementation inspired by L<Tie::StdArray|Tie::StdArray>.

=head1 INDEX

L<MCE|MCE>, L<MCE::Core|MCE::Core>, L<MCE::Shared|MCE::Shared>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

