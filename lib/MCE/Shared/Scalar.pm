###############################################################################
## ----------------------------------------------------------------------------
## Scalar helper class.
##
###############################################################################

package MCE::Shared::Scalar;

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

# Based on Tie::StdScalar from Tie::Scalar.

sub TIESCALAR {
   my $class = shift;
   bless \do{ my $o = defined $_[0] ? shift : undef }, $class;
}

sub STORE { ${ $_[0] } = $_[1] }
sub FETCH { ${ $_[0] } }

###############################################################################
## ----------------------------------------------------------------------------
## Sugar API, mostly resembles http://redis.io/commands#string primitives.
##
###############################################################################

# append ( string )

sub append {
   length( ${ $_[0] } .= $_[1] // '' );
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
sub getdecr {   ${ $_[0] }--        // 0 }
sub getincr {   ${ $_[0] }++        // 0 }

# getset ( value )

sub getset {
   my $old = ${ $_[0] };
   ${ $_[0] } = $_[1];

   $old;
}

# len ( )

sub len {
   length ${ $_[0] };
}

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

This document describes MCE::Shared::Scalar version 1.700

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
   $val = $var->append( $string );     #   $val .= $string
   $val = $var->decr();                # --$val
   $val = $var->decrby( $number );     #   $val -= $number
   $val = $var->getdecr();             #   $val--
   $val = $var->getincr();             #   $val++
   $val = $var->incr();                # ++$val
   $val = $var->incrby( $number );     #   $val += $number
   $old = $var->getset( $new );        #   $o = $v, $v = $n, $o

=head1 DESCRIPTION

Helper class for L<MCE::Shared>.

=head1 API DOCUMENTATION

This module may involve TIE when accessing the object via scalar dereferencing.
Only shared instances are impacted if doing so. Although likely fast enough for
many use cases, use the OO interface if better performance is desired.

=over 3

=item new ( [ value ] )

Constructs a new object. Its value is undefined when C<value> is not specified.

   # non-shared
   use MCE::Shared::Scalar;

   $var = MCE::Shared::Scalar->new( "foo" );
   $var = MCE::Shared::Scalar->new;

   # shared
   use MCE::Shared;

   $var = MCE::Shared->scalar( "bar" );
   $var = MCE::Shared->scalar;

=item set ( value )

Preferably, set the value via the OO interface. Otherwise, C<TIE> is activated
on-demand for setting the value. The new value is returned in scalar context.

   $val = $var->set( "baz" );
   $var->set( "baz" );
   ${$var} = "baz";

=item get

Likewise, obtain the value via the OO interface. C<TIE> is utilized for
retrieving the value otherwise.

   $val = $var->get;
   $val = ${$var};

=item len

Returns the length of the value. It returns the C<undef> value if the value
is not defined.

   $len = $var->len;
   length ${$var};

=back

=head1 SUGAR METHODS

This module is equipped with sugar methods to not have to call C<set>
and C<get> explicitly. The API resembles a subset of the Redis primitives
L<http://redis.io/commands#strings> without the key argument.

=over 3

=item append ( value )

Appends a value at the end of the current value and returns its new length.

   $len = $var->append( "foo" );

=item decr

Decrements the value by one and returns its new value.

   $num = $var->decr;

=item decrby ( number )

Decrements the value by the given number and returns its new value.

   $num = $var->decrby( 2 );

=item getdecr

Decrements the value by one and returns its old value.

   $old = $var->getdecr;

=item getincr

Increments the value by one and returns its old value.

   $old = $var->getincr;

=item getset ( value )

Sets the value and returns its old value.

   $old = $var->getset( "baz" );

=item incr

Increments the value by one and returns its new value.

   $num = $var->incr;

=item incrby ( number )

Increments the value by the given number and returns its new value.

   $num = $var->incrby( 2 );

=back

=head1 CREDITS

The implementation is inspired by L<Tie::StdScalar>.

=head1 INDEX

L<MCE|MCE>, L<MCE::Core>, L<MCE::Shared>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

