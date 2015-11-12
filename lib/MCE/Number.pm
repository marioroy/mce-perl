###############################################################################
## ----------------------------------------------------------------------------
## MCE::Number -- An auto-shareable number class.
##
###############################################################################

package MCE::Number;

use strict;
use warnings;

our $VERSION = '1.699_001';

my $use_thrs;

BEGIN {
   $use_thrs = (
      $INC{'threads/shared.pm'}
         && threads::shared->can('shared_clone')
         && !$INC{'MCE/Shared.pm'}
         && !$INC{'forks.pm'}
   ) ? 1 : 0;
}

sub new {
   my ($class, $self) = (shift, shift || 0);

   if ($use_thrs) {
      threads::shared::shared_clone( bless \$self, $class );
   }
   else {
      require MCE::Shared unless $INC{'MCE/Shared.pm'};
      MCE::Shared::share( bless \$self, $class );
   }
}

sub Set  { lock $_[0] if $use_thrs;    ${ $_[0] }    = $_[1] }
sub Val  { lock $_[0] if $use_thrs;    ${ $_[0] }            }
sub Decr { lock $_[0] if $use_thrs;  --${ $_[0] }            }
sub Incr { lock $_[0] if $use_thrs;  ++${ $_[0] }            }
sub Next { lock $_[0] if $use_thrs;    ${ $_[0] }++          }
sub Prev { lock $_[0] if $use_thrs;    ${ $_[0] }--          }
sub Add  { lock $_[0] if $use_thrs;    ${ $_[0] }   += $_[1] }
sub Sub  { lock $_[0] if $use_thrs;    ${ $_[0] }   -= $_[1] }
sub Mul  { lock $_[0] if $use_thrs;    ${ $_[0] }   *= $_[1] }
sub Div  { lock $_[0] if $use_thrs;    ${ $_[0] }   /= $_[1] }

1;

__END__

###############################################################################
## ----------------------------------------------------------------------------
## Module usage.
##
###############################################################################

=head1 NAME

MCE::Number - An auto-shareable number class

=head1 VERSION

This document describes MCE::Number version 1.699_001

=head1 SYNOPSIS

   # including threads is optional

   use threads;
   use threads::shared;

   use MCE::Flow;
   use MCE::Number;

   my $n = MCE::Number->new(100);   # default 0

   mce_flow { max_workers => 8 }, sub {
      $n->Incr;
   };

   print $n->Val, "\n";

   -- Output

   108

=head1 DESCRIPTION

This module provides an auto-shareable number class supporting threads
and processes. MCE::Shared is included automatically in the absence of
threads::shared or missing shared_clone function. Sharing is via
MCE::Shared when both modules are present.

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

