###############################################################################
## ----------------------------------------------------------------------------
## MCE::Number -- An auto-shareable pure-Perl number class.
##
###############################################################################

package MCE::Number;

use strict;
use warnings;

our $VERSION = '1.699_001';

sub new {
    my ($class, $self) = (shift, shift || 0);

    $INC{'MCE/Shared.pm'}
        ? MCE::Shared::share( bless \$self, $class )
        : bless \$self, $class;
}

sub Set  {   ${ $_[0] }    = $_[1] }
sub Val  {   ${ $_[0] }            }
sub Decr { --${ $_[0] }            }
sub Incr { ++${ $_[0] }            }
sub Next {   ${ $_[0] }++          }
sub Prev {   ${ $_[0] }--          }
sub Add  {   ${ $_[0] }   += $_[1] }
sub Sub  {   ${ $_[0] }   -= $_[1] }
sub Mul  {   ${ $_[0] }   *= $_[1] }
sub Div  {   ${ $_[0] }   /= $_[1] }

1;

__END__

###############################################################################
## ----------------------------------------------------------------------------
## Module usage.
##
###############################################################################

=head1 NAME

MCE::Number - An auto-shareable pure-Perl number class

=head1 VERSION

This document describes MCE::Number version 1.699_001

=head1 SYNOPSIS

   use MCE::Shared;
   use MCE::Number;   # auto-shares when MCE::Shared is present
   use MCE::Flow;

   my $n = MCE::Number->new(100);   # default 0

   mce_flow { max_workers => 8 }, sub {
      $n->Incr;
   };

   print $n->Val, "\n";

   -- Output

   108

=head1 DESCRIPTION

This module provides an auto-shareable number class supporting threads and
processes. The object is shared when MCE::Shared is present.

=head1 API DOCUMENTATION

=over 3

=item new ( number )

The number argument is optional and defaults to zero when omitted.

=item Set ( number )

=item Val

Setter and getter for the class. They return the new and current value
respectively.

   $n->Set( 100 );
   $n->Val;

=item Decr

=item Incr

=item Next

=item Prev

These methods are sugar for decrementing and incrementing.

   $n->Decr;     # like --$n     returns new value
   $n->Incr;     # like ++$n     returns new value
   $n->Next;     # like   $n++   returns old value
   $n->Prev;     # like   $n--   returns old value

=item Add ( number )

=item Div ( number )

=item Mul ( number )

=item Sub ( number )

These methods are sugar for adding, dividing, multiplying, or subtracting
a number. They return the new value.

   $n->Add( $number );     # like $n += $number
   $n->Div( $number );     # like $n /= $number
   $n->Mul( $number );     # like $n *= $number
   $n->Sub( $number );     # like $n -= $number

=back

=head1 INDEX

L<MCE|MCE>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

