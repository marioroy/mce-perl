###############################################################################
## ----------------------------------------------------------------------------
## Scalar helper class.
##
###############################################################################

package MCE::Shared::Scalar;

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

sub TIESCALAR {
   my $class = shift;
   bless \do{ my $o = defined $_[0] ? shift : undef }, $class;
}

# Based on Tie::StdScalar from Tie::Scalar.

sub STORE { ${ $_[0] } = $_[1] }
sub FETCH { ${ $_[0] } }

###############################################################################
## ----------------------------------------------------------------------------
## Sugar API, mostly resembles http://redis.io/commands#string primitives.
##
###############################################################################

# append ( string )

sub append {
   ${ $_[0] } .= $_[1] || '';
   length ${ $_[0] };
}

# decr
# decrby ( number )
# incr
# incrby ( number )
# getdecr
# getincr

sub decr    { --${ $_[0] }               }
sub decrby  {   ${ $_[0] } -= $_[1] || 0 }
sub incr    { ++${ $_[0] }               }
sub incrby  {   ${ $_[0] } += $_[1] || 0 }
sub getdecr {   ${ $_[0] }--        || 0 }
sub getincr {   ${ $_[0] }++        || 0 }

# getset ( value )

sub getset { my $old = ${ $_[0] }; ${ $_[0] } = $_[1]; $old }

# len ( )

sub len { length ${ $_[0] } || 0 }

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

This document describes MCE::Shared::Scalar version 1.699_009

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
   $len = $var->len();

   # sugar methods without having to call set/get explicitly
   $val = $var->append( $string );            #   $val .= $string
   $val = $var->decr();                       # --$val
   $val = $var->decrby( $number );            #   $val -= $number
   $val = $var->getdecr();                    #   $val--
   $val = $var->getincr();                    #   $val++
   $val = $var->incr();                       # ++$val
   $val = $var->incrby( $number );            #   $val += $number
   $old = $var->getset( $new );               #   $o = $v, $v = $n, $o

=head1 DESCRIPTION

Helper class for L<MCE::Shared|MCE::Shared>.

=head1 API DOCUMENTATION

=over 3

=item new ( value )

=item new

Construct a new scalar object. The value defaults to C<undef> unless value is
specified.

=item set ( value )

Set scalar to value.

=item get

Get the scalar value.

=item len

Get the length of the scalar value.

=back

=head1 SUGAR METHODS

This module is equipped with sugar methods to not have to call C<set>
and C<get> explicitly. The API resembles a subset of the Redis primitives
L<http://redis.io/commands#strings> without the key argument.

=over 3

=item append ( value )

Append the value at the end of the scalar value.

=item decr

Decrement the value by one and return its new value.

=item decrby ( number )

Decrement the value by the given number and return its new value.

=item getdecr

Decrement the value by one and return its old value.

=item getincr

Increment the value by one and return its old value.

=item getset ( value )

Set to value and return its old value.

=item incr

Increment the value by one and return its new value.

=item incrby ( number )

Increment the value by the given number and return its new value.

=back

=head1 CREDITS

The implementation is inspired by L<Tie::StdScalar|Tie::StdScalar>.

=head1 INDEX

L<MCE|MCE>, L<MCE::Core|MCE::Core>, L<MCE::Shared|MCE::Shared>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

