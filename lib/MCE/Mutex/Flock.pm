###############################################################################
## ----------------------------------------------------------------------------
## MCE::Mutex::Flock - Locking via Fcntl.
##
###############################################################################

package MCE::Mutex::Flock;

use strict;
use warnings;

no warnings 'threads';
no warnings 'recursion';
no warnings 'uninitialized';

our $VERSION = '1.699_001';

use base 'MCE::Mutex';
use Fcntl qw( :flock );
use MCE::Signal;

our @CARP_NOT = qw( MCE::Shared MCE::Mutex MCE );

my $_tid = $INC{'threads.pm'} ? threads->tid() : 0;
my $_flock_id = 0;

sub CLONE {
   $_tid = threads->tid();
   return;
}

sub DESTROY {
   my ($_obj, $_arg) = @_;
   my $_pid = $INC{'threads.pm'} ? $$ .'.'. $_tid : $$;

   if (exists $_obj->{ $_pid }) {
      $_obj->unlock() if ($_obj->{ $_pid });
      close (delete $_obj->{'hndl'}) if (exists $_obj->{'hndl'});
   }

   if ($_arg eq 'shutdown' || $_obj->{'init_pid'} eq $_pid) {
      unlink (delete $_obj->{'path'}) if (exists $_obj->{'path'});
   }

   return;
}

sub _croak { goto &MCE::Mutex::_croak; }

sub _open_hndl {
   my $_obj = shift;

   open $_obj->{'hndl'}, '+>>:raw::stdio', $_obj->{'path'}
      or _croak( "MCE::Mutex::Flock: open error $_obj->{'path'}: $!" );

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Public methods.
##
###############################################################################

sub new {
   my ($_class, %_argv) = @_; my $_obj = { %_argv };

   $_obj->{'init_pid'} = $INC{'threads.pm'} ? $$ .'.'. $_tid : $$;

   unless ($_obj->{'path'}) {
      $_flock_id++;
      $_obj->{'path'} = $MCE::Signal::tmp_dir . "/_mutex_${_flock_id}.lock";
   }

   return bless($_obj, $_class);
}

sub lock {
   my $_obj = shift;
   my $_pid = $INC{'threads.pm'} ? $$ .'.'. $_tid : $$;

   $_obj->_open_hndl unless exists $_obj->{ $_pid };

   unless ($_obj->{ $_pid }) {
      flock $_obj->{'hndl'}, LOCK_EX;
      $_obj->{ $_pid } = 1;
   }

   return;
}

sub unlock {
   my $_obj = shift;
   my $_pid = $INC{'threads.pm'} ? $$ .'.'. $_tid : $$;

   if ($_obj->{ $_pid }) {
      flock $_obj->{'hndl'}, LOCK_UN;
      $_obj->{ $_pid } = 0;
   }

   return;
}

1;

