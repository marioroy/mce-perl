###############################################################################
## ----------------------------------------------------------------------------
## MCE::Mutex::Channel - Locking via Pipe/Socket.
##
###############################################################################

package MCE::Mutex::Channel;

use strict;
use warnings;

no warnings 'threads';
no warnings 'recursion';
no warnings 'uninitialized';

our $VERSION = '1.699';

use base 'MCE::Mutex';
use MCE::Util qw( $LF );
use bytes;

our @CARP_NOT = qw( MCE::Shared MCE::Mutex MCE );

my $_tid = $INC{'threads.pm'} ? threads->tid() : 0;

sub CLONE {
   $_tid = threads->tid();
   return;
}

sub DESTROY {
   my ($_obj, $_arg) = @_;
   my $_pid = $INC{'threads.pm'} ? $$ .'.'. $_tid : $$;

   $_obj->unlock() if ($_obj->{ $_pid });

   if ($_arg eq 'shutdown' || $_obj->{'init_pid'} eq $_pid) {
      ($_obj->{'pipe'} || $^O eq 'MSWin32')
         ? MCE::Util::_destroy_pipes($_obj, qw(_w_sock _r_sock))
         : MCE::Util::_destroy_sockets($_obj, qw(_w_sock _r_sock));
   }

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

   ($_obj->{'pipe'} || $^O eq 'MSWin32')
      ? MCE::Util::_pipe_pair($_obj, qw(_r_sock _w_sock))
      : MCE::Util::_socket_pair($_obj, qw(_r_sock _w_sock));

   syswrite($_obj->{_w_sock}, '0');

   return bless($_obj, $_class);
}

sub lock {
   my $_obj = shift;
   my $_pid = $INC{'threads.pm'} ? $$ .'.'. $_tid : $$;

   unless ($_obj->{ $_pid }) {
      sysread($_obj->{_r_sock}, my $_b, 1);
      $_obj->{ $_pid } = 1;
   }

   return;
}

sub unlock {
   my $_obj = shift;
   my $_pid = $INC{'threads.pm'} ? $$ .'.'. $_tid : $$;

   if ($_obj->{ $_pid }) {
      syswrite($_obj->{_w_sock}, '0');
      $_obj->{ $_pid } = 0;
   }

   return;
}

1;

