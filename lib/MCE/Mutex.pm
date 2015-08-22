###############################################################################
## ----------------------------------------------------------------------------
## MCE::Mutex - Locking for Many-Core Engine.
##
###############################################################################

package MCE::Mutex;

use strict;
use warnings;

no warnings 'threads';
no warnings 'recursion';
no warnings 'uninitialized';

our $VERSION = '1.699';

our @CARP_NOT = qw( MCE::Shared MCE );

my ($_default, $_loaded) = ('channel', 0);

sub import {
   my $_class = shift; return if ($_loaded++);

   while (my $_argument = shift) {
      my $_arg = lc $_argument;

      if ( $_arg eq 'type' ) {
         $_default = shift || 'channel';
         if ($_default !~ /^(?:flock|channel|pipe|socket)$/) {
            _croak("Error: (type => '$_default') is not valid");
         }
         next;
      }

      _croak("Error: ($_argument) invalid module option");
   }

   return;
}

sub _croak {
   unless (defined $MCE::VERSION) {
      $\ = undef; require Carp; goto &Carp::croak;
   } else {
      goto &MCE::_croak;
   }
}

###############################################################################
## ----------------------------------------------------------------------------
## Public methods.
##
###############################################################################

sub new {
   my ($_class, %_argv) = @_; my $_obj;
   my $_type = $_argv{'type'} || $ENV{'PERL_MCE_MUTEX_TYPE'} || $_default;

   ## adjust accordingly

   if ($_type eq 'flock') {
      $_type = 'channel' if ($^O eq 'cygwin');
   }
   elsif ($_type eq 'pipe') {
      $_type = 'channel'; $_argv{'pipe'} = 1;
   }
   elsif ($_type eq 'socket') {
      $_type = 'channel'; $_argv{'pipe'} = 0;
   }

   $_argv{'pipe'} = 1 if ($_type eq 'channel' && not exists $_argv{'pipe'});
   $_argv{'pipe'} = 0 if ($_argv{'pipe'} && $^O =~ /^(?:cygwin|solaris)$/);

   ## return lock object

   if ($_type eq 'channel') {
      delete $_argv{'type'};
      require MCE::Mutex::Channel unless $INC{'MCE/Mutex/Channel.pm'};
      $_obj = MCE::Mutex::Channel->new(%_argv);
   }
   elsif ($_type eq 'flock') {
      require MCE::Mutex::Flock unless $INC{'MCE/Mutex/Flock.pm'};
      $_obj = MCE::Mutex::Flock->new(%_argv);
   }
   else {
      _croak("MCE::Mutex: type ($_type) is not valid");
   }

   return $_obj;
}

sub synchronize {
   my ($_obj, $_code) = (shift, shift);

   if (ref $_code eq 'CODE') {
      if (defined wantarray) {
         $_obj->lock();   my @_a = $_code->(@_);
         $_obj->unlock();

         return wantarray ? @_a : $_a[0];
      }
      else {
         $_obj->lock();   $_code->(@_);
         $_obj->unlock();
      }
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

This document describes MCE::Mutex version 1.699

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

=head2 $m->lock ( void )

Attempts to grab the lock and waits if not available. Multiple calls to
mutex->lock by the same process or thread is safe. The mutex will remain
locked until mutex->unlock is called.

=head2 $m->unlock ( void )

Releases the lock. A held lock by an exiting process or thread is released
automatically.

=head2 $m->synchronize ( sub { ... }, @_ )

Obtains a lock, runs the code block, and releases the lock after the block
completes. Optionally, the method is wantarray aware.

   my $value = $m->synchronize( sub {

      ## access shared resource

      'value';
   });

=head1 INDEX

L<MCE|MCE>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

