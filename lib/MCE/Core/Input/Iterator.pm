###############################################################################
## ----------------------------------------------------------------------------
## Iterator reader.
##
## This package, used interally by the worker process, provides support for
## user specified iterators assigned to input_data.
##
## There is no public API.
##
###############################################################################

package MCE::Core::Input::Iterator;

use strict;
use warnings;

our $VERSION = '1.821';

## Items below are folded into MCE.

package # hide from rpm
   MCE;

no warnings qw( threads recursion uninitialized );

use bytes;

###############################################################################
## ----------------------------------------------------------------------------
## Worker process -- User Iterator.
##
###############################################################################

sub _worker_user_iterator {

   my ($self) = @_;

   @_ = ();

   _croak('MCE::_worker_user_iterator: (user_func) is not specified')
      unless (defined $self->{user_func});

   my $_chn         = $self->{_chn};
   my $_DAT_LOCK    = $self->{_dat_lock};
   my $_DAT_W_SOCK  = $self->{_dat_w_sock}->[0];
   my $_DAU_W_SOCK  = $self->{_dat_w_sock}->[$_chn];
   my $_lock_chn    = $self->{_lock_chn};
   my $_chunk_size  = $self->{chunk_size};
   my $_I_FLG       = (!$/ || $/ ne $LF);
   my $_wuf         = $self->{_wuf};

   my ($_dat_ex, $_dat_un);

   if ($_lock_chn) {
      $_dat_ex = sub {  sysread ( $_DAT_LOCK->{_r_sock}, my $_b, 1 ) };
      $_dat_un = sub { syswrite ( $_DAT_LOCK->{_w_sock}, '0' ) };
   }

   my ($_chunk_id, $_len, $_is_ref);

   ## -------------------------------------------------------------------------

   $self->{_next_jmp} = sub { goto _WORKER_USER_ITERATOR__NEXT; };
   $self->{_last_jmp} = sub { goto _WORKER_USER_ITERATOR__LAST; };

   local $_;

   _WORKER_USER_ITERATOR__NEXT:

   while (1) {
      undef $_ if (length > MAX_CHUNK_SIZE);

      $_ = '';

      ## Obtain the next chunk of data.
      {
         local $\ = undef if (defined $\); local $/ = $LF if ($_I_FLG);

         $_dat_ex->() if $_lock_chn;
         print {$_DAT_W_SOCK} OUTPUT_U_ITR . $LF . $_chn . $LF;
         chomp($_len = <$_DAU_W_SOCK>);

         if ($_len < 0) {
            $_dat_un->() if $_lock_chn;
            return;
         }

         $_is_ref = chop $_len;

         chomp($_chunk_id = <$_DAU_W_SOCK>);
         read $_DAU_W_SOCK, $_, $_len;

         $_dat_un->() if $_lock_chn;
      }

      ## Call user function.
      if ($_is_ref) {
         my $_chunk_ref = $self->{thaw}($_); undef $_;
         $_ = ($_chunk_size == 1) ? $_chunk_ref->[0] : $_chunk_ref;
         $_wuf->($self, $_chunk_ref, $_chunk_id);
      }
      else {
         $_wuf->($self, [ $_ ], $_chunk_id);
      }
   }

   _WORKER_USER_ITERATOR__LAST:

   return;
}

1;

