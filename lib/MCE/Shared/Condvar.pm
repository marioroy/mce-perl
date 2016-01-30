###############################################################################
## ----------------------------------------------------------------------------
## Condvar helper class.
##
###############################################################################

package MCE::Shared::Condvar;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized );

our $VERSION = '1.699_008';

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
   $_[0]->{_value} .= $_[1] || '';
   length $_[0]->{_value};
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
sub getdecr {   $_[0]->{_value}--        || 0 }
sub getincr {   $_[0]->{_value}++        || 0 }

# getset ( value )

sub getset { my $old = $_[0]->{_value}; $_[0]->{_value} = $_[1]; $old }

# len

sub len { length($_[0]->{_value}) || 0 }

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

This document describes MCE::Shared::Condvar version 1.699_008

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
   $len = $cv->len();

   # sugar methods without having to call set/get explicitly
   $val = $cv->append( $string );             #   $val .= $string
   $val = $cv->decr();                        # --$val
   $val = $cv->decrby( $number );             #   $val -= $number
   $val = $cv->getdecr();                     #   $val--
   $val = $cv->getincr();                     #   $val++
   $val = $cv->incr();                        # ++$val
   $val = $cv->incrby( $number );             #   $val += $number
   $old = $cv->getset( $new );                #   $o = $v, $v = $n, $o

=head1 DESCRIPTION

Helper class for L<MCE::Shared|MCE::Shared>.

The following demonstrates barrier synchronization.

   use MCE;
   use MCE::Shared;
   use Time::HiRes qw(usleep);

   my $num_workers = 8;
   my $count = MCE::Shared->condvar(0);
   my $state = MCE::Shared->scalar('ready');

   # Sleeping with a small value is expensive on Cygwin (imo).
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
         # MCE->sync();   # via MCE Core API
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

=item new ( value )

=item new

=item lock

=item unlock

=item broadcast

=item signal

=item timedwait ( floating_seconds )

=item wait

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

The implementation is inspired by L<threads|threads>.

=head1 INDEX

L<MCE|MCE>, L<MCE::Core|MCE::Core>, L<MCE::Shared|MCE::Shared>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

