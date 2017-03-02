###############################################################################
## ----------------------------------------------------------------------------
## Array_ref and Glob_ref input reader.
##
## This package provides the request chunk method used internally by the worker
## process. Distribution follows a bank-queuing model.
##
## There is no public API.
##
###############################################################################

package MCE::Core::Input::Request;

use strict;
use warnings;

our $VERSION = '1.818';

## Items below are folded into MCE.

package # hide from rpm
   MCE;

no warnings qw( threads recursion uninitialized );

use bytes;

###############################################################################
## ----------------------------------------------------------------------------
## Worker process -- Request chunk.
##
###############################################################################

sub _worker_request_chunk {

   my ($self, $_proc_type) = @_;

   @_ = ();

   _croak('MCE::_worker_request_chunk: (user_func) is not specified')
      unless (defined $self->{user_func});

   my $_chn         = $self->{_chn};
   my $_DAT_LOCK    = $self->{_dat_lock};
   my $_DAT_W_SOCK  = $self->{_dat_w_sock}->[0];
   my $_DAU_W_SOCK  = $self->{_dat_w_sock}->[$_chn];
   my $_lock_chn    = $self->{_lock_chn};
   my $_single_dim  = $self->{_single_dim};
   my $_chunk_size  = $self->{chunk_size};
   my $_use_slurpio = $self->{use_slurpio};
   my $_RS          = $self->{RS} || $/;
   my $_RS_FLG      = (!$_RS || $_RS ne $LF);
   my $_I_FLG       = (!$/ || $/ ne $LF);
   my $_wuf         = $self->{_wuf};

   my ($_dat_ex, $_dat_un);

   if ($_lock_chn) {
      $_dat_ex = sub {  sysread ( $_DAT_LOCK->{_r_sock}, my $_b, 1 ) };
      $_dat_un = sub { syswrite ( $_DAT_LOCK->{_w_sock}, '0' ) };
   }

   my ($_chunk_id, $_len, $_output_tag);
   my ($_chop_len, $_chop_str, $_p);

   if ($_proc_type == REQUEST_ARRAY) {
      $_output_tag = OUTPUT_A_ARY;
      $_chop_len   = 0;
   }
   else {
      $_output_tag = OUTPUT_S_GLB;
      if (length $_RS > 1 && substr($_RS, 0, 1) eq "\n") {
         $_chop_str = substr($_RS, 1);
         $_chop_len = length $_chop_str;
      } else {
         $_chop_str = '';
         $_chop_len = 0;
      }
   }

   ## -------------------------------------------------------------------------

   $self->{_next_jmp} = sub { goto _WORKER_REQUEST_CHUNK__NEXT; };
   $self->{_last_jmp} = sub { goto _WORKER_REQUEST_CHUNK__LAST; };

   local $_;

   _WORKER_REQUEST_CHUNK__NEXT:

   while (1) {
      undef $_ if (length > MAX_CHUNK_SIZE);

      $_ = '';

      ## Obtain the next chunk of data.
      {
         local $\ = undef if (defined $\); local $/ = $LF if ($_I_FLG);

         $_dat_ex->() if $_lock_chn;
         print {$_DAT_W_SOCK} $_output_tag . $LF . $_chn . $LF;
         chomp($_len = <$_DAU_W_SOCK>);

         unless ($_len) {
            $_dat_un->() if $_lock_chn;
            return;
         }

         chomp($_chunk_id = <$_DAU_W_SOCK>);

         if ($_chunk_id > 1 && $_chop_len) {
            $_p = $_chop_len; $_ = $_chop_str;
         } else {
            $_p = 0;
         }

         read $_DAU_W_SOCK, $_, $_len, $_p;

         $_dat_un->() if $_lock_chn;
      }

      ## Call user function.
      if ($_proc_type == REQUEST_ARRAY) {
         if ($_single_dim && $_chunk_size == 1) {
            $_wuf->($self, [ $_ ], $_chunk_id);
         }
         else {
            my $_chunk_ref = $self->{thaw}($_); undef $_;
            $_ = ($_chunk_size == 1) ? $_chunk_ref->[0] : $_chunk_ref;
            $_wuf->($self, $_chunk_ref, $_chunk_id);
         }
      }
      else {
         if ($_use_slurpio) {
            if ($_chop_len && substr($_, -$_chop_len) eq $_chop_str) {
               substr($_, -$_chop_len, $_chop_len, '');
            }
            local $_ = \$_;
            $_wuf->($self, $_, $_chunk_id);
         }
         else {
            if ($_chunk_size == 1) {
               if ($_chop_len && substr($_, -$_chop_len) eq $_chop_str) {
                  substr($_, -$_chop_len, $_chop_len, '');
               }
               $_wuf->($self, [ $_ ], $_chunk_id);
            }
            else {
               my @_recs;
               {
                  local $/ = $_RS if ($_RS_FLG);
                  _sync_buffer_to_array(\$_, \@_recs, $_chop_str);
                  undef $_;
               }
               if ($_chop_len) {
                  for my $i (0 .. @_recs - 1) {
                     if (substr($_recs[$i], -$_chop_len) eq $_chop_str) {
                        substr($_recs[$i], -$_chop_len, $_chop_len, '');
                     }
                  }
               }
               local $_ = \@_recs;
               $_wuf->($self, \@_recs, $_chunk_id);
            }
         }
      }
   }

   _WORKER_REQUEST_CHUNK__LAST:

   return;
}

1;

