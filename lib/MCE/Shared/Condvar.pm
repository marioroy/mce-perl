###############################################################################
## ----------------------------------------------------------------------------
## Condvar helper class.
##
###############################################################################

package MCE::Shared::Condvar;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized );

our $VERSION = '1.699_007';

use MCE::Shared::Base;
use MCE::Util ();
use MCE::Mutex;
use bytes;

use overload (
   q("")    => \&MCE::Shared::Base::_stringify_h,
   q(0+)    => \&MCE::Shared::Base::_numify,
   fallback => 1
);

my $_has_threads = $INC{'threads.pm'} ? 1 : 0;
my $_tid = $_has_threads ? threads->tid() : 0;

sub CLONE {
   $_tid = threads->tid();
}

sub DESTROY {
   my ($_cv) = @_;
   my $_pid  = $_has_threads ? $$ .'.'. $_tid : $$;

   MCE::Util::_destroy_socks($_cv, qw(_cw_sock _cr_sock))
      if $_cv->{_init_pid} eq $_pid;

   return;
}

sub new {
   my ($_class, $_cv) = (shift, {});

   $_cv->{_init_pid} = $_has_threads ? $$ .'.'. $_tid : $$;
   $_cv->{_mutex}    = MCE::Mutex->new;
   $_cv->{_value}    = shift || 0;
   $_cv->{_count}    = 0;

   MCE::Util::_sock_pair($_cv, qw(_cr_sock _cw_sock));

   bless $_cv, $_class;
}

###############################################################################
## ----------------------------------------------------------------------------
## Public methods.
##
###############################################################################

sub set    {   $_[0]->{_value}  = $_[1]       }
sub get    {   $_[0]->{_value}                }

sub append {   $_[0]->{_value} .= $_[1] || '' ;
        length $_[0]->{_value}
}
sub decr   { --$_[0]->{_value}                }
sub decrby {   $_[0]->{_value} -= $_[1] || 0  }
sub incr   { ++$_[0]->{_value}                }
sub incrby {   $_[0]->{_value} += $_[1] || 0  }
sub pdecr  {   $_[0]->{_value}--              }
sub pincr  {   $_[0]->{_value}++              }

sub length {
   CORE::length($_[0]->{_value}) || 0;
}

## Handled by MCE::Shared::Object.

sub lock      { }
sub unlock    { }

sub broadcast { }
sub signal    { }
sub timedwait { }
sub wait      { }

1;

__END__

###############################################################################
## ----------------------------------------------------------------------------
## Module usage.
##
###############################################################################

=head1 NAME

MCE::Shared::Condvar - Condvar helper class

=head1 VERSION

This document describes MCE::Shared::Condvar version 1.699_007

=head1 SYNOPSIS

   use MCE::Shared;

   my $cv = MCE::Shared->condvar( 0 );

   # oo interface
   $cv->lock();
   $cv->unlock();
   $cv->broadcast();
   $cv->broadcast(0.05);        # yield some time before broadcast
   $cv->signal();
   $cv->signal(0.05);           # yield some time before signal
   $cv->timedwait(2.5);
   $cv->wait();

   $val = $cv->set( $val );
   $val = $cv->get();
   $len = $cv->length();

   # sugar methods without having to call set/get explicitly
   $val = $cv->append( $string );             #   $val .= $string
   $val = $cv->decr();                        # --$val
   $val = $cv->decrby( $number );             #   $val -= $number
   $val = $cv->incr();                        # ++$val
   $val = $cv->incrby( $number );             #   $val += $number
   $val = $cv->pdecr();                       #   $val--
   $val = $cv->pincr();                       #   $val++

=head1 DESCRIPTION

Helper class for L<MCE::Shared|MCE::Shared>.

The following demonstrates barrier synchronization.

   use MCE;
   use MCE::Shared;
   use Time::HiRes qw(usleep);

   my $num_workers = 8;
   my $count = MCE::Shared->condvar(0);
   my $state = MCE::Shared->scalar('ready');

   # Sleeping with small values is expensive on Cygwin (imo).
   my $microsecs = ($^O eq 'cygwin') ? 0 : 200;

   # Lock is released when calling ->broadcast, ->signal, ->timedwait,
   # or ->wait. Thus, re-obtain the lock for synchronization afterwards
   # if desired.

   sub barrier_sync {
      usleep($microsecs) until $state->get eq 'ready' or $state->get eq 'up';

      $count->lock;
      $state->set('up'), $count->incr;

      if ($count->get == $num_workers) {
         $count->decr, $state->set('down');
         $count->broadcast;
      }
      else {
         $count->wait while $state->get eq 'up';
         $count->lock;
         $count->decr;
         $state->set('ready') if $count->get == 0;
         $count->unlock;
      }
   }

   # Time taken from a 2.6 GHz machine running Mac OS X.
   # If you want a fast barrier synchronization, let me know.
   # I can add MCE::Shared::Barrier to behave like MCE Sync.
   #
   #    threads::shared:   0.238s  threads
   #      forks::shared:  36.426s  child processes
   #        MCE::Shared:   0.397s  child processes
   #           MCE Sync:   0.062s  child processes

   sub user_func {
      my $id = MCE->wid;
      for (1 .. 400) {
         MCE->print("$_: $id\n");
         ## MCE->sync();  # via MCE Core API
         barrier_sync();  # via MCE::Shared::Condvar
      }
   }

   my $mce = MCE->new(
      max_workers => $num_workers,
      user_func   => \&user_func
   )->run;

=head1 API DOCUMENTATION

To be completed before the final 1.700 release.

=over 3

=item new

=item lock

=item unlock

=item broadcast

=item signal

=item timedwait

=item wait

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

=head1 INDEX

L<MCE|MCE>, L<MCE::Core|MCE::Core>, L<MCE::Shared|MCE::Shared>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

