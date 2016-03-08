###############################################################################
## ----------------------------------------------------------------------------
## Condvar helper class.
##
###############################################################################

package MCE::Shared::Condvar;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized numeric );

our $VERSION = '1.700';

use MCE::Shared::Base;
use MCE::Util ();
use MCE::Mutex;
use bytes;

use overload (
   q("")    => \&MCE::Shared::Base::_stringify,
   q(0+)    => \&MCE::Shared::Base::_numify,
   fallback => 1
);

my $_has_threads = $INC{'threads.pm'} ? 1 : 0;
my $_tid = $_has_threads ? threads->tid() : 0;

sub new {
   my ($_class, $_cv) = (shift, {});

   $_cv->{_init_pid} = $_has_threads ? $$ .'.'. $_tid : $$;
   $_cv->{_mutex}    = MCE::Mutex->new;
   $_cv->{_value}    = shift || 0;
   $_cv->{_count}    = 0;

   MCE::Util::_sock_pair($_cv, qw(_cr_sock _cw_sock));

   bless $_cv, $_class;
}

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

###############################################################################
## ----------------------------------------------------------------------------
## Public methods.
##
###############################################################################

sub get { $_[0]->{_value} }
sub set { $_[0]->{_value} = $_[1] }

# The following methods applies to sharing only and are handled by
# MCE::Shared::Object.

sub lock      { }
sub unlock    { }

sub broadcast { }
sub signal    { }
sub timedwait { }
sub wait      { }

###############################################################################
## ----------------------------------------------------------------------------
## Sugar API, mostly resembles http://redis.io/commands#string primitives.
##
###############################################################################

# append ( string )

sub append {
   length( $_[0]->{_value} .= $_[1] // '' );
}

# decr
# decrby ( number )
# incr
# incrby ( number )
# getdecr
# getincr

sub decr    { --$_[0]->{_value}               }
sub decrby  {   $_[0]->{_value} -= $_[1] || 0 }
sub incr    { ++$_[0]->{_value}               }
sub incrby  {   $_[0]->{_value} += $_[1] || 0 }
sub getdecr {   $_[0]->{_value}--        // 0 }
sub getincr {   $_[0]->{_value}++        // 0 }

# getset ( value )

sub getset {
   my $old = $_[0]->{_value};
   $_[0]->{_value} = $_[1];

   $old;
}

# len ( )

sub len {
   length $_[0]->{_value};
}

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

This document describes MCE::Shared::Condvar version 1.700

=head1 SYNOPSIS

   use MCE::Shared;

   my $cv = MCE::Shared->condvar( 0 );

   # oo interface
   $val = $cv->set( $val );
   $val = $cv->get();
   $len = $cv->len();

   # conditional locking primitives
   $cv->lock();
   $cv->unlock();

   $cv->broadcast();
   $cv->broadcast(0.05);     # delay before broadcasting

   $cv->signal();
   $cv->signal(0.05);        # delay before signaling

   $cv->timedwait(2.5);
   $cv->wait();

   # sugar methods without having to call set/get explicitly
   $val = $cv->append( $string );     #   $val .= $string
   $val = $cv->decr();                # --$val
   $val = $cv->decrby( $number );     #   $val -= $number
   $val = $cv->getdecr();             #   $val--
   $val = $cv->getincr();             #   $val++
   $val = $cv->incr();                # ++$val
   $val = $cv->incrby( $number );     #   $val += $number
   $old = $cv->getset( $new );        #   $o = $v, $v = $n, $o

=head1 DESCRIPTION

This helper class for L<MCE::Shared> provides a C<Scalar>, C<Mutex>, and
primitives for conditional locking.

The following demonstrates barrier synchronization.

   use MCE;
   use MCE::Shared;
   use Time::HiRes qw(usleep);

   my $num_workers = 8;
   my $count = MCE::Shared->condvar(0);
   my $state = MCE::Shared->scalar("ready");

   my $microsecs = ($^O eq "cygwin") ? 0 : 200;

   # The lock is released upon entering ->broadcast, ->signal, ->timedwait,
   # and ->wait. For performance reasons, the condition variable is *not*
   # re-locked prior to exiting the call. Therefore, obtain the lock when
   # synchronization is desired subsequently.

   sub barrier_sync {
      usleep($microsecs) until $state->get eq "ready" or $state->get eq "up";

      $count->lock;
      $state->set("up"), $count->incr;

      if ($count->get == $num_workers) {
         $count->decr, $state->set("down");
         $count->broadcast;
      }
      else {
         $count->wait while $state->get eq "up";
         $count->lock;
         $count->decr;
         $state->set("ready") if $count->get == 0;
         $count->unlock;
      }
   }

   # Time taken from a 2.6 GHz machine running Mac OS X.
   #
   # threads::shared:   0.238s  threads
   #   forks::shared:  36.426s  child processes
   #     MCE::Shared:   0.397s  child processes
   #        MCE Sync:   0.062s  child processes

   sub user_func {
      my $id = MCE->wid;
      for (1 .. 400) {
         MCE->print("$_: $id\n");
         # MCE->sync();   # via MCE Core API
         barrier_sync();  # via MCE::Shared::Condvar
      }
   }

   my $mce = MCE->new(
      max_workers => $num_workers,
      user_func   => \&user_func
   )->run;

=head1 API DOCUMENTATION

=over 3

=item new ( [ value ] )

Constructs a new condition variable. Its value defaults to C<0> when C<value>
is not specified.

   # shared
   use MCE::Shared;

   $cv = MCE::Shared->condvar( 100 );
   $cv = MCE::Shared->condvar;

=item set ( value )

Sets the value associated with the C<cv> object. The new value is returned
in scalar context.

   $val = $cv->set( 10 );
   $cv->set( 10 );

=item get

Returns the value associated with the C<cv> object.

   $val = $cv->get;

=item len

Returns the length of the value. It returns the C<undef> value if the value
is not defined.

   $len = $var->len;

=item lock

Attempts to grab the lock and waits if not available. Multiple calls to
C<$cv->lock> by the same process or thread is safe. The mutex will remain
locked until C<$cv->unlock> is called.

   $cv->lock;

=item unlock

Releases the lock. A held lock by an exiting process or thread is released
automatically.

   $cv->unlock;

=item signal ( [ floating_seconds ] )

Releases a held lock on the variable. Then, unblocks one process or thread
that's C<wait>ing on that variable. The variable is *not* locked upon return.

Optionally, delay C<floating_seconds> before signaling.

   $count->signal;
   $count->signal( 0.5 );

=item broadcast ( [ floating_seconds ] )

The C<broadcast> method works similarly to C<signal>. It releases a held lock
on the variable. Then, unblocks all the processes or threads that are blocked
in a condition C<wait> on the variable, rather than only one. The variable is
*not* locked upon return.

Optionally, delay C<floating_seconds> before broadcasting.

   $count->broadcast;
   $count->broadcast( 0.5 );

=item wait

Releases a held lock on the variable. Then, waits until another thread does a
C<signal> or C<broadcast> for the same variable. The variable is *not* locked
upon return.

   $count->wait() while $state->get() eq "bar";

=item timedwait ( floating_seconds )

Releases a held lock on the variable. Then, waits until another thread does a
C<signal> or C<broadcast> for the same variable or if the timeout exceeds
C<floating_seconds>.

A false value is returned if the timeout is reached, and a true value otherwise.
In either case, the variable is *not* locked upon return.

   $count->timedwait( 10 ) while $state->get() eq "foo";

=back

=head1 SUGAR METHODS

This module is equipped with sugar methods to not have to call C<set>
and C<get> explicitly. The API resembles a subset of the Redis primitives
L<http://redis.io/commands#strings> without the key argument.

=over 3

=item append ( value )

Appends a value at the end of the current value and returns its new length.

   $len = $cv->append( "foo" );

=item decr

Decrements the value by one and returns its new value.

   $num = $cv->decr;

=item decrby ( number )

Decrements the value by the given number and returns its new value.

   $num = $cv->decrby( 2 );

=item getdecr

Decrements the value by one and returns its old value.

   $old = $cv->getdecr;

=item getincr

Increments the value by one and returns its old value.

   $old = $cv->getincr;

=item getset ( value )

Sets the value and returns its old value.

   $old = $cv->getset( "baz" );

=item incr

Increments the value by one and returns its new value.

   $num = $cv->incr;

=item incrby ( number )

Increments the value by the given number and returns its new value.

   $num = $cv->incrby( 2 );

=back

=head1 CREDITS

The conditional locking aspect is inspired by L<threads::shared>.

=head1 LIMITATION

Perl must have the L<IO::FDPass> module installed for constructing a shared
C<queue> or C<condvar> while the shared-manager process is running.

For platforms where C<IO::FDPass> is not feasible, construct C<queues> or
C<condvars> first before other classes. The shared-manager process is delayed
until sharing other classes or explicitly starting the process.

   use MCE::Shared;

   my $q1 = MCE::Shared->queue();
   my $cv = MCE::Shared->condvar();

   MCE::Shared->start();

=head1 INDEX

L<MCE|MCE>, L<MCE::Core>, L<MCE::Shared>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

