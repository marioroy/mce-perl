###############################################################################
## ----------------------------------------------------------------------------
## Locking for Many-Core Engine.
##
###############################################################################

package MCE::Mutex;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized );

our $VERSION = '1.800';

use MCE::Util qw( $LF );

my $_has_threads = $INC{'threads.pm'} ? 1 : 0;
my $_tid = $_has_threads ? threads->tid() : 0;

sub CLONE {
   $_tid = threads->tid() if $_has_threads;
}

sub DESTROY {
   my ($_obj, $_arg) = @_;
   my $_pid = $_has_threads ? $$ .'.'. $_tid : $$;

   $_obj->unlock() if ($_obj->{ $_pid });

   if ($_obj->{'init_pid'} eq $_pid || $_arg eq 'shutdown') {
      MCE::Util::_destroy_socks($_obj, qw(_w_sock _r_sock));
   }

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Public methods.
##
###############################################################################

sub new {
   my ($_class, %_obj) = @_;
   $_obj{'init_pid'} = $_has_threads ? $$ .'.'. $_tid : $$;

   MCE::Util::_sock_pair(\%_obj, qw(_r_sock _w_sock));
   1 until syswrite($_obj{_w_sock}, '0');

   return bless(\%_obj, $_class);
}

sub lock {
   my ($_obj) = @_;
   my $_pid = $_has_threads ? $$ .'.'. $_tid : $$;

   unless ($_obj->{ $_pid }) {
      1 until sysread($_obj->{_r_sock}, my $_b, 1);
      $_obj->{ $_pid } = 1;
   }

   return;
}

sub unlock {
   my ($_obj) = @_;
   my $_pid = $_has_threads ? $$ .'.'. $_tid : $$;

   if ($_obj->{ $_pid }) {
      1 until syswrite($_obj->{_w_sock}, '0');
      $_obj->{ $_pid } = 0;
   }

   return;
}

sub synchronize {
   my ($_obj, $_code) = (shift, shift);

   return if (ref $_code ne 'CODE');

   if (defined wantarray) {
      $_obj->lock();
      my @_a = $_code->(@_);
      $_obj->unlock();

      return wantarray ? @_a : $_a[0];
   }
   else {
      $_obj->lock();
      $_code->(@_);
      $_obj->unlock();
   }

   return;
}

1;

__END__

###############################################################################
## ----------------------------------------------------------------------------
## Module usage.
##
###############################################################################

=head1 NAME

MCE::Mutex - Locking for Many-Core Engine

=head1 VERSION

This document describes MCE::Mutex version 1.800

=head1 SYNOPSIS

   use MCE::Flow max_workers => 4;
   use MCE::Mutex;

   print "## running a\n";
   my $a = MCE::Mutex->new;

   mce_flow sub {
      $a->lock;

      ## access shared resource
      my $wid = MCE->wid; MCE->say($wid); sleep 1;

      $a->unlock;
   };

   print "## running b\n";
   my $b = MCE::Mutex->new;

   mce_flow sub {
      $b->synchronize( sub {

         ## access shared resource
         my ($wid) = @_; MCE->say($wid); sleep 1;

      }, MCE->wid );
   };

=head1 DESCRIPTION

This module implements locking methods that can be used to coordinate access
to shared data from multiple workers spawned as processes or threads.

The inspiration for this module came from reading Mutex for Ruby.

=head1 API DOCUMENTATION

=head2 MCE::Mutex->new ( void )

Creates a new mutex.

Channel locking is through a pipe or socket depending on platform.
The advantage of channel locking is not having to re-establish handles
inside new processes or threads.

=head2 $m->lock ( void )

Attempts to grab the lock and waits if not available. Multiple calls to
mutex->lock by the same process or thread is safe. The mutex will remain
locked until mutex->unlock is called.

=head2 $m->unlock ( void )

Releases the lock. A held lock by an exiting process or thread is released
automatically.

=head2 $m->synchronize ( sub { ... }, @_ )

Obtains a lock, runs the code block, and releases the lock after the block
completes. Optionally, the method is C<wantarray> aware.

   my $value = $m->synchronize( sub {

      ## access shared resource

      'value';
   });

=head1 INDEX

L<MCE|MCE>, L<MCE::Core>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

