###############################################################################
## ----------------------------------------------------------------------------
## Scalar helper class.
##
###############################################################################

package MCE::Shared::Scalar;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized );

our $VERSION = '1.699_004';

## no critic (TestingAndDebugging::ProhibitNoStrict)

use MCE::Shared::Base;
use bytes;

use overload (
   q("")    => \&MCE::Shared::Base::_stringify_s,
   q(0+)    => \&MCE::Shared::Base::_numify,
   fallback => 1
);

sub _croak {
   goto &MCE::Shared::Base::_croak;
}

sub TIESCALAR {
   my $class = shift;
   _croak("storing a reference for SCALAR is not supported") if ref $_[0];
   bless \do{ my $o = defined $_[0] ? shift : undef }, $class;
}

## Based on Tie::StdScalar from Tie::Scalar.

sub STORE { ${ $_[0] } = $_[1] }
sub FETCH { ${ $_[0] } }

###############################################################################
## ----------------------------------------------------------------------------
## Public methods.
##
###############################################################################

sub append {   ${ $_[0] } .= $_[1] || '' ; length ${ $_[0] } }
sub decr   { --${ $_[0] }                }
sub decrby {   ${ $_[0] } -= $_[1] || 0  }
sub incr   { ++${ $_[0] }                }
sub incrby {   ${ $_[0] } += $_[1] || 0  }
sub pdecr  {   ${ $_[0] }--              }
sub pincr  {   ${ $_[0] }++              }

sub length {
   CORE::length(${ $_[0] }) || 0;
}

## Aliases.

{
   no strict 'refs';
   *{ __PACKAGE__.'::new' } = \&TIESCALAR;
   *{ __PACKAGE__.'::set' } = \&STORE;
   *{ __PACKAGE__.'::get' } = \&FETCH;
}

1;

__END__

###############################################################################
## ----------------------------------------------------------------------------
## Module usage.
##
###############################################################################

=head1 NAME

MCE::Shared::Scalar - Scalar helper class

=head1 VERSION

This document describes MCE::Shared::Scalar version 1.699_004

=head1 SYNOPSIS

   # non-shared
   use MCE::Shared::Scalar;

   my $var = MCE::Shared::Scalar->new( $val );

   # shared
   use MCE::Shared;

   my $var = MCE::Shared->scalar( $val );

   # oo interface
   $val = $var->set( $val );
   $val = $var->get();
   $len = $var->length();

   # sugar methods without having to call set/get explicitly
   $val = $var->append( $string );            #   $val .= $string
   $val = $var->decr();                       # --$val
   $val = $var->decrby( $number );            #   $val -= $number
   $val = $var->incr();                       # ++$val
   $val = $var->incrby( $number );            #   $val += $number
   $val = $var->pdecr();                      #   $val--
   $val = $var->pincr();                      #   $val++

=head1 DESCRIPTION

Helper class for L<MCE::Shared|MCE::Shared>.

=head1 API DOCUMENTATION

To be completed before the final 1.700 release.

=over 3

=item new

=item set

=item get

=item length

=item append

=item decr

=item decrby

=item incr

=item incrby

=item pdecr

=item pincr

=back

=head1 CREDITS

Implementation inspired by L<Tie::StdScalar|Tie::StdScalar>.

=head1 INDEX

L<MCE|MCE>, L<MCE::Core|MCE::Core>, L<MCE::Shared|MCE::Shared>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

