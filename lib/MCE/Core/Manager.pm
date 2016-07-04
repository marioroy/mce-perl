###############################################################################
## ----------------------------------------------------------------------------
## Core methods for the manager process.
##
## This package provides the loop and relevant methods used internally by the
## manager process.
##
## There is no public API.
##
###############################################################################

package MCE::Core::Manager;

use strict;
use warnings;

our $VERSION = '1.802';

## no critic (BuiltinFunctions::ProhibitStringyEval)
## no critic (TestingAndDebugging::ProhibitNoStrict)

## Items below are folded into MCE.

package # hide from rpm
   MCE;

no warnings qw( threads recursion uninitialized );

## POSIX is large. This will cover most platforms.
use constant { _WNOHANG => $^O eq 'solaris' ? 64 : 1 };

use bytes;

###############################################################################
## ----------------------------------------------------------------------------
## Call on task_end after task completion.
##
###############################################################################

sub _task_end {

   my ($self, $_task_id) = @_;

   @_ = ();

   if (defined $self->{user_tasks}) {
      my $_task_end = (exists $self->{user_tasks}->[$_task_id]->{task_end})
         ? $self->{user_tasks}->[$_task_id]->{task_end}
         : $self->{task_end};

      if (defined $_task_end) {
         my $_task_name = (exists $self->{user_tasks}->[$_task_id]->{task_name})
            ? $self->{user_tasks}->[$_task_id]->{task_name}
            : $self->{task_name};

         $_task_end->($self, $_task_id, $_task_name);
      }
   }

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Process output.
##
## Awaits and processes events from workers. The sendto/do methods tag the
## output accordingly. The hash structure below is key-driven.
##
###############################################################################

sub _output_loop {

   my ( $self, $_input_data, $_input_glob, $_plugin_function,
        $_plugin_loop_begin, $_plugin_loop_end ) = @_;

   @_ = ();

   my (
      $_aborted, $_eof_flag, $_max_retries, $_syn_flag, %_sendto_fhs,
      $_cb, $_chunk_id, $_chunk_size, $_fd, $_file, $_flush_file, $_wa,
      @_is_c_ref, @_is_h_ref, @_is_q_ref, $_on_post_exit, $_on_post_run,
      $_has_user_tasks, $_sess_dir, $_task_id, $_user_error, $_user_output,
      $_input_size, $_offset_pos, $_single_dim, @_gather, $_cs_one_flag,
      $_exit_id, $_exit_pid, $_exit_status, $_exit_wid, $_len, $_sync_cnt,
      $_BSB_W_SOCK, $_BSE_W_SOCK, $_DAT_R_SOCK, $_DAU_R_SOCK, $_MCE_STDERR,
      $_I_FLG, $_O_FLG, $_I_SEP, $_O_SEP, $_RS, $_RS_FLG, $_MCE_STDOUT,
      $_win32_ipc
   );

   ## -------------------------------------------------------------------------
   ## Callback return.

   my $_cb_ret_a = sub {                          # CBK return array

      my $_buf = $self->{freeze}($_[0]);
         $_len = length $_buf; local $\ = undef if (defined $\);

      print {$_DAU_R_SOCK} $_len.$LF, $_buf;

      return;
   };

   my $_cb_ret_r = sub {                          # CBK return reference

      my $_buf = $self->{freeze}($_[0]);
         $_len = length $_buf; local $\ = undef if (defined $\);

      print {$_DAU_R_SOCK} WANTS_REF.$LF . $_len.$LF, $_buf;

      return;
   };

   my $_cb_ret_s = sub {                          # CBK return scalar

      $_len = (defined $_[0]) ? length $_[0] : -1;
      local $\ = undef if (defined $\);

      print {$_DAU_R_SOCK} WANTS_SCALAR.$LF . $_len.$LF, $_[0];

      return;
   };

   ## -------------------------------------------------------------------------
   ## Create hash structure containing various output functions.

   my %_core_output_function = (

      OUTPUT_W_ABT.$LF => sub {                   # Worker has aborted
         $_aborted = 1;
         return;
      },

      OUTPUT_W_DNE.$LF => sub {                   # Worker has completed
         chomp($_task_id = <$_DAU_R_SOCK>);
         $self->{_total_running} -= 1;

         if ($_has_user_tasks && $_task_id >= 0) {
            $self->{_task}->[$_task_id]->{_total_running} -= 1;
         }

         my $_total_running = ($_has_user_tasks)
            ? $self->{_task}->[$_task_id]->{_total_running}
            : $self->{_total_running};

         if ($_task_id == 0 && defined $_syn_flag && $_sync_cnt) {
            if ($_sync_cnt == $_total_running) {
               for (1 .. $_total_running) { syswrite $_BSB_W_SOCK, $LF }
               undef $_syn_flag;
            }
         }

         _task_end($self, $_task_id) unless ($_total_running);

         return;
      },

      ## ----------------------------------------------------------------------

      OUTPUT_W_EXT.$LF => sub {                   # Worker has exited
         chomp($_task_id = <$_DAU_R_SOCK>);

         $self->{_total_exited}  += 1;
         $self->{_total_running} -= 1;
         $self->{_total_workers} -= 1;

         if ($_has_user_tasks && $_task_id >= 0) {
            $self->{_task}->[$_task_id]->{_total_running} -= 1;
            $self->{_task}->[$_task_id]->{_total_workers} -= 1;
         }

         my $_total_running = ($_has_user_tasks)
            ? $self->{_task}->[$_task_id]->{_total_running}
            : $self->{_total_running};

         if ($_task_id == 0 && defined $_syn_flag && $_sync_cnt) {
            if ($_sync_cnt == $_total_running) {
               for (1 .. $_total_running) { syswrite $_BSB_W_SOCK, $LF }
               undef $_syn_flag;
            }
         }

         my ($_exit_msg, $_retry_buf) = ('', '');

         chomp($_exit_wid    = <$_DAU_R_SOCK>),
         chomp($_exit_pid    = <$_DAU_R_SOCK>),
         chomp($_exit_status = <$_DAU_R_SOCK>),
         chomp($_exit_id     = <$_DAU_R_SOCK>),
         chomp($_len         = <$_DAU_R_SOCK>);

         read($_DAU_R_SOCK, $_exit_msg, $_len) if ($_len);

         chomp($_len = <$_DAU_R_SOCK>);

         read($_DAU_R_SOCK, $_retry_buf, $_len) if ($_len);

         if (abs($_exit_status) > abs($self->{_wrk_status})) {
            $self->{_wrk_status} = $_exit_status;
         }

         ## Reap child/thread. Note: Win32 uses negative PIDs.

         if ($_exit_pid =~ /^PID_(-?\d+)/) {
            my $_pid = $1; my $_list = $self->{_pids};
            for my $i (0 .. @{ $_list }) {
               if ($_list->[$i] && $_list->[$i] == $_pid) {
                  waitpid $_pid, 0;
                  $self->{_pids}->[$i] = undef;
                  last;
               }
            }
         }
         elsif ($_exit_pid =~ /^TID_(\d+)/) {
            my $_tid = $1; my $_list = $self->{_tids};
            for my $i (0 .. @{ $_list }) {
               if ($_list->[$i] && $_list->[$i] == $_tid) {
                  ${ $self->{_thrs}->[$i] }->join();
                  $self->{_thrs}->[$i] = undef;
                  $self->{_tids}->[$i] = undef;
                  last;
               }
            }
         }

         ## Call on_post_exit callback if defined. Otherwise, append status
         ## information if on_post_run is defined for later retrieval.

         if (defined $_on_post_exit) {
            $self->{_exited_wid} = $_exit_wid;

            if (length($_retry_buf)) {
               $self->{_retry} = $self->{thaw}($_retry_buf);
               my $_retry_cnt  = $_max_retries - $self->{_retry}[2] - 1;

               $_on_post_exit->($self, {
                  wid => $_exit_wid, pid => $_exit_pid, status => $_exit_status,
                  msg => $_exit_msg, id  => $_exit_id
               }, $_retry_cnt);

               delete $self->{_retry};
            }
            else {
               $_on_post_exit->($self, {
                  wid => $_exit_wid, pid => $_exit_pid, status => $_exit_status,
                  msg => $_exit_msg, id  => $_exit_id
               }, $_max_retries || 0 );
            }

            delete $self->{_exited_wid};
         }
         elsif (defined $_on_post_run) {
            push @{ $self->{_status} }, {
               wid => $_exit_wid, pid => $_exit_pid, status => $_exit_status,
               msg => $_exit_msg, id  => $_exit_id
            };
         }

         _task_end($self, $_task_id) unless ($_total_running);

         return;
      },

      ## ----------------------------------------------------------------------

      OUTPUT_A_ARY.$LF => sub {                   # Array << Array
         my $_buf;

         if ($_offset_pos >= $_input_size || $_aborted) {
            local $\ = undef if (defined $\);
            print {$_DAU_R_SOCK} '0'.$LF;

            return;
         }

         if ($_single_dim && $_cs_one_flag) {
            $_buf = $_input_data->[$_offset_pos];
         }
         else {
            if ($_offset_pos + $_chunk_size - 1 < $_input_size) {
               $_buf = $self->{freeze}( [ @{ $_input_data }[
                  $_offset_pos .. $_offset_pos + $_chunk_size - 1
               ] ] );
            }
            else {
               $_buf = $self->{freeze}( [ @{ $_input_data }[
                  $_offset_pos .. $_input_size - 1
               ] ] );
            }
         }

         $_len = length $_buf; local $\ = undef if (defined $\);
         print {$_DAU_R_SOCK} $_len.$LF . (++$_chunk_id).$LF, $_buf;
         $_offset_pos += $_chunk_size;

         return;
      },

      OUTPUT_S_GLB.$LF => sub {                   # Scalar << Glob FH
         my $_buf = '';

         ## The logic below honors ('Ctrl/Z' in Windows, 'Ctrl/D' in Unix)
         ## when reading from standard input. No output will be lost as
         ## far as what was previously read into the buffer.

         if ($_eof_flag || $_aborted) {
            local $\ = undef if (defined $\);
            print {$_DAU_R_SOCK} '0'.$LF;

            return;
         }

         {
            local $/ = $_RS if ($_RS_FLG);

            if ($_chunk_size <= MAX_RECS_SIZE) {
               if ($_chunk_size == 1) {
                  $_buf = <$_input_glob>;
                  $_eof_flag = 1 unless (length $_buf);
               }
               else {
                  my $_last_len = 0;
                  for (1 .. $_chunk_size) {
                     $_buf .= <$_input_glob>;
                     $_len  = length $_buf;
                     if ($_len == $_last_len) {
                        $_eof_flag = 1;
                        last;
                     }
                     $_last_len = $_len;
                  }
               }
            }
            else {
               if (read($_input_glob, $_buf, $_chunk_size) == $_chunk_size) {
                  $_buf .= <$_input_glob>;
                  $_eof_flag = 1 if (length $_buf == $_chunk_size);
               }
               else {
                  $_eof_flag = 1;
               }
            }
         }

         $_len = length $_buf; local $\ = undef if (defined $\);

         if ($_len) {
            print {$_DAU_R_SOCK} $_len.$LF . (++$_chunk_id).$LF, $_buf;
         } else {
            print {$_DAU_R_SOCK} '0'.$LF;
         }

         return;
      },

      OUTPUT_U_ITR.$LF => sub {                   # User << Iterator
         my $_buf;

         if ($_aborted) {
            local $\ = undef if (defined $\);
            print {$_DAU_R_SOCK} '-1'.$LF;

            return;
         }

         my @_ret_a = $_input_data->($_chunk_size);

         if (scalar @_ret_a > 1 || ref $_ret_a[0]) {
            $_buf = $self->{freeze}( [ @_ret_a ] );
            $_len = length $_buf; local $\ = undef if (defined $\);
            print {$_DAU_R_SOCK} $_len.'1'.$LF . (++$_chunk_id).$LF, $_buf;

            return;
         }
         elsif (defined $_ret_a[0]) {
            $_len = length $_ret_a[0]; local $\ = undef if (defined $\);
            print {$_DAU_R_SOCK} $_len.'0'.$LF . (++$_chunk_id).$LF, $_ret_a[0];

            return;
         }

         local $\ = undef if (defined $\);
         print {$_DAU_R_SOCK} '-1'.$LF;
         $_aborted = 1;

         return;
      },

      ## ----------------------------------------------------------------------

      OUTPUT_A_CBK.$LF => sub {                   # Callback w/ multiple args
         my ($_buf, $_data_ref);

         chomp($_wa  = <$_DAU_R_SOCK>),
         chomp($_cb  = <$_DAU_R_SOCK>),
         chomp($_len = <$_DAU_R_SOCK>);

         read $_DAU_R_SOCK, $_buf, $_len;
         $_data_ref = $self->{thaw}($_buf); undef $_buf;

         local $\ = $_O_SEP if ($_O_FLG); local $/ = $_I_SEP if ($_I_FLG);
         no strict 'refs';

         if ($_wa == WANTS_UNDEF) {
            $_cb->(@{ $_data_ref });
         }
         elsif ($_wa == WANTS_ARRAY) {
            my @_ret_a = $_cb->(@{ $_data_ref });
            $_cb_ret_a->(\@_ret_a);
         }
         else {
            my  $_ret_s = $_cb->(@{ $_data_ref });
            ref $_ret_s ? $_cb_ret_r->($_ret_s) : $_cb_ret_s->($_ret_s);
         }

         return;
      },

      OUTPUT_S_CBK.$LF => sub {                   # Callback w/ 1 scalar arg
         my $_buf;

         chomp($_wa  = <$_DAU_R_SOCK>),
         chomp($_cb  = <$_DAU_R_SOCK>),
         chomp($_len = <$_DAU_R_SOCK>);

         read $_DAU_R_SOCK, $_buf, $_len;

         local $\ = $_O_SEP if ($_O_FLG); local $/ = $_I_SEP if ($_I_FLG);
         no strict 'refs';

         if ($_wa == WANTS_UNDEF) {
            $_cb->($_buf);
         }
         elsif ($_wa == WANTS_ARRAY) {
            my @_ret_a = $_cb->($_buf);
            $_cb_ret_a->(\@_ret_a);
         }
         else {
            my  $_ret_s = $_cb->($_buf);
            ref $_ret_s ? $_cb_ret_r->($_ret_s) : $_cb_ret_s->($_ret_s);
         }

         return;
      },

      OUTPUT_N_CBK.$LF => sub {                   # Callback w/ no args

         chomp($_wa = <$_DAU_R_SOCK>),
         chomp($_cb = <$_DAU_R_SOCK>);

         local $\ = $_O_SEP if ($_O_FLG); local $/ = $_I_SEP if ($_I_FLG);
         no strict 'refs';

         if ($_wa == WANTS_UNDEF) {
            $_cb->();
         }
         elsif ($_wa == WANTS_ARRAY) {
            my @_ret_a = $_cb->();
            $_cb_ret_a->(\@_ret_a);
         }
         else {
            my  $_ret_s = $_cb->();
            ref $_ret_s ? $_cb_ret_r->($_ret_s) : $_cb_ret_s->($_ret_s);
         }

         return;
      },

      ## ----------------------------------------------------------------------

      OUTPUT_A_GTR.$LF => sub {                   # Gather array/ref
         my $_buf;

         chomp($_task_id = <$_DAU_R_SOCK>),
         chomp($_len     = <$_DAU_R_SOCK>);

         read $_DAU_R_SOCK, $_buf, $_len;

         if ($_is_c_ref[$_task_id]) {
            local $_ = $self->{thaw}($_buf);
            $_gather[$_task_id]->(@{ $_ });
         }
         elsif ($_is_h_ref[$_task_id]) {
            local $_ = $self->{thaw}($_buf);
            while (1) {
               my $_key = shift @{ $_ }; my $_val = shift @{ $_ };
               $_gather[$_task_id]->{$_key} = $_val;
               last unless (@{ $_ });
            }
         }
         elsif ($_is_q_ref[$_task_id]) {
            $_gather[$_task_id]->enqueue(@{ $self->{thaw}($_buf) });
         }
         else {
            push @{ $_gather[$_task_id] }, @{ $self->{thaw}($_buf) };
         }

         return;
      },

      OUTPUT_S_GTR.$LF => sub {                   # Gather scalar
         local $_;

         chomp($_task_id = <$_DAU_R_SOCK>),
         chomp($_len     = <$_DAU_R_SOCK>);

         read $_DAU_R_SOCK, $_, $_len if ($_len >= 0);

         if ($_is_c_ref[$_task_id]) {
            $_gather[$_task_id]->($_);
         }
         elsif ($_is_h_ref[$_task_id]) {
            $_gather[$_task_id]->{$_} = undef;
         }
         elsif ($_is_q_ref[$_task_id]) {
            $_gather[$_task_id]->enqueue($_);
         }
         else {
            push @{ $_gather[$_task_id] }, $_;
         }

         return;
      },

      ## ----------------------------------------------------------------------

      OUTPUT_O_SND.$LF => sub {                   # Send >> STDOUT
         my $_buf;

         chomp($_len = <$_DAU_R_SOCK>);
         read $_DAU_R_SOCK, $_buf, $_len;

         if (defined $_user_output) {
            $_user_output->($_buf);
         } else {
            print {$_MCE_STDOUT} $_buf;
         }

         return;
      },

      OUTPUT_E_SND.$LF => sub {                   # Send >> STDERR
         my $_buf;

         chomp($_len = <$_DAU_R_SOCK>);
         read $_DAU_R_SOCK, $_buf, $_len;

         if (defined $_user_error) {
            $_user_error->($_buf);
         } else {
            print {$_MCE_STDERR} $_buf;
         }

         return;
      },

      OUTPUT_F_SND.$LF => sub {                   # Send >> File
         my ($_buf, $_OUT_FILE);

         chomp($_file = <$_DAU_R_SOCK>),
         chomp($_len  = <$_DAU_R_SOCK>);

         read $_DAU_R_SOCK, $_buf, $_len;

         unless (exists $_sendto_fhs{$_file}) {
            open $_sendto_fhs{$_file}, '>>', $_file
               or _croak "Cannot open file for writing ($_file): $!";

            binmode $_sendto_fhs{$_file};

            ## Select new FH, turn on autoflush, restore the old FH.
            if ($_flush_file) {
               local $|; select((select($_sendto_fhs{$_file}), $| = 1)[0]);
            }
         }

         $_OUT_FILE = $_sendto_fhs{$_file};
         print {$_OUT_FILE} $_buf;

         return;
      },

      OUTPUT_D_SND.$LF => sub {                   # Send >> File descriptor
         my ($_buf, $_OUT_FILE);

         chomp($_fd  = <$_DAU_R_SOCK>),
         chomp($_len = <$_DAU_R_SOCK>);

         read $_DAU_R_SOCK, $_buf, $_len;

         unless (exists $_sendto_fhs{$_fd}) {
            require IO::Handle unless (defined $IO::Handle::VERSION);

            $_sendto_fhs{$_fd} = IO::Handle->new();
            $_sendto_fhs{$_fd}->fdopen($_fd, 'w')
               or _croak "Cannot open file descriptor ($_fd): $!";

            binmode $_sendto_fhs{$_fd};

            ## Select new FH, turn on autoflush, restore the old FH.
            if ($_flush_file) {
               local $|; select((select($_sendto_fhs{$_fd}), $| = 1)[0]);
            }
         }

         $_OUT_FILE = $_sendto_fhs{$_fd};
         print {$_OUT_FILE} $_buf;

         return;
      },

      ## ----------------------------------------------------------------------

      OUTPUT_B_SYN.$LF => sub {                   # Barrier sync - begin

         if (!defined $_sync_cnt || $_sync_cnt == 0) {
            $_syn_flag = 1, $_sync_cnt = 0;
         }

         my $_total_running = ($_has_user_tasks)
            ? $self->{_task}->[0]->{_total_running}
            : $self->{_total_running};

         if (++$_sync_cnt == $_total_running) {
            for (1 .. $_total_running) { syswrite $_BSB_W_SOCK, $LF }
            undef $_syn_flag;
         }

         return;
      },

      OUTPUT_E_SYN.$LF => sub {                   # Barrier sync - end

         if (--$_sync_cnt == 0) {
            my $_total_running = ($_has_user_tasks)
               ? $self->{_task}->[0]->{_total_running}
               : $self->{_total_running};

            for (1 .. $_total_running) { syswrite $_BSE_W_SOCK, $LF }
         }

         return;
      },

      OUTPUT_S_IPC.$LF => sub {                   # Change to win32 IPC

         syswrite $_DAT_R_SOCK, $LF;

         $_win32_ipc = 1, goto _LOOP unless $_win32_ipc;

         return;
      },

   );

   ## -------------------------------------------------------------------------

   local ($!, $?, $_);

   $_has_user_tasks = (defined $self->{user_tasks}) ? 1 : 0;
   $_cs_one_flag = ($self->{chunk_size} == 1) ? 1 : 0;
   $_aborted = $_chunk_id = $_eof_flag = 0;

   $_max_retries  = $self->{max_retries};
   $_on_post_exit = $self->{on_post_exit};
   $_on_post_run  = $self->{on_post_run};
   $_chunk_size   = $self->{chunk_size};
   $_flush_file   = $self->{flush_file};
   $_user_output  = $self->{user_output};
   $_user_error   = $self->{user_error};
   $_single_dim   = $self->{_single_dim};
   $_sess_dir     = $self->{_sess_dir};

   if ($_max_retries && !$_on_post_exit) {
      $_on_post_exit = sub {
         my ($self, $_e, $_retry_cnt) = @_;
         my ($_cnt, $_msg) = ($_retry_cnt + 1, "Error: Chunk $_e->{id} failed");

         ($_retry_cnt < $_max_retries)
            ? print {*STDERR} "$_msg, retrying chunk attempt #${_cnt}\n"
            : print {*STDERR} "$_msg\n";

         $self->restart_worker;
      };
   }

   if ($_has_user_tasks && $self->{user_tasks}->[0]->{chunk_size}) {
      $_chunk_size = $self->{user_tasks}->[0]->{chunk_size};
   }

   if ($_has_user_tasks) {
      for my $_i (0 .. @{ $self->{user_tasks} } - 1) {
         $_gather[$_i] = (defined $self->{user_tasks}->[$_i]->{gather})
            ? $self->{user_tasks}->[$_i]->{gather} : $self->{gather};

         $_is_c_ref[$_i] = ( ref $_gather[$_i] eq 'CODE' ) ? 1 : 0;
         $_is_h_ref[$_i] = ( ref $_gather[$_i] eq 'HASH' ) ? 1 : 0;

         $_is_q_ref[$_i] = (
            ref $_gather[$_i] eq 'MCE::Queue' ||
            ref $_gather[$_i] eq 'Thread::Queue' ) ? 1 : 0;
      }
   }

   if (defined $self->{gather}) {
      $_gather[0] = $self->{gather};

      $_is_c_ref[0] = ( ref $_gather[0] eq 'CODE' ) ? 1 : 0;
      $_is_h_ref[0] = ( ref $_gather[0] eq 'HASH' ) ? 1 : 0;

      $_is_q_ref[0] = (
         ref $_gather[0] eq 'MCE::Queue' ||
         ref $_gather[0] eq 'Thread::Queue' ) ? 1 : 0;
   }

   if (defined $_input_data && ref $_input_data eq 'ARRAY') {
      $_input_size = @{ $_input_data };
      $_offset_pos = 0;
   } else {
      $_input_size = $_offset_pos = 0;
   }

   ## Set STDOUT/STDERR to user parameters.

   if (defined $self->{stdout_file}) {
      open $_MCE_STDOUT, '>>', $self->{stdout_file}
         or die $self->{stdout_file} . ": $!\n";
      binmode $_MCE_STDOUT;
   }
   else {
      $_MCE_STDOUT = \*STDOUT;
      binmode $_MCE_STDOUT;
   }

   if (defined $self->{stderr_file}) {
      open $_MCE_STDERR, '>>', $self->{stderr_file}
         or die $self->{stderr_file} . ": $!\n";
      binmode $_MCE_STDERR;
   }
   else {
      $_MCE_STDERR = \*STDERR;
      binmode $_MCE_STDERR;
   }

   ## Make MCE_STDOUT the default handle.
   ## Flush STDERR/STDOUT handles if requested.

   my $_old_hndl = select $_MCE_STDOUT;

   if ($self->{flush_stdout}) {
      local $|; select((select($_MCE_STDOUT), $| = 1)[0]);
   }
   if ($self->{flush_stderr}) {
      local $|; select((select($_MCE_STDERR), $| = 1)[0]);
   }

   ## -------------------------------------------------------------------------

   ## Output event loop.

   my $_func; my $_channels = $self->{_dat_r_sock};

   $_win32_ipc  = ( $ENV{'PERL_MCE_IPC'} eq 'win32' || $INC{'MCE/Hobo.pm'} );

   $_BSB_W_SOCK = $self->{_bsb_w_sock};
   $_BSE_W_SOCK = $self->{_bse_w_sock};
   $_DAT_R_SOCK = $self->{_dat_r_sock}->[0];

   $_RS     = $self->{RS} || $/;
   $_O_SEP  = $\; local $\ = undef;
   $_I_SEP  = $/; local $/ = $LF;

   $_RS_FLG = (!$_RS || $_RS ne $LF) ? 1 : 0;
   $_O_FLG  = (defined $_O_SEP) ? 1 : 0;
   $_I_FLG  = (!$_I_SEP || $_I_SEP ne $LF) ? 1 : 0;

   ## Call module's loop_begin routine for modules plugged into MCE.

   for my $_p (@{ $_plugin_loop_begin }) {
      $_p->($self, \$_DAU_R_SOCK);
   }

   ## Wait on requests *with* timeout capability. Exit loop when all workers
   ## have completed processing or exited prematurely.

   _LOOP:

   if ($self->{loop_timeout} && @{ $self->{_tids} } == 0 && $^O ne 'MSWin32') {
      my ($_list, $_timeout) = ($self->{_pids}, $self->{loop_timeout});
      my ($_DAT_W_SOCK, $_pid) = ($self->{_dat_w_sock}->[0]);

      $_timeout = 5 if $_timeout < 5;

      local $SIG{ALRM} = sub {
         alarm 0;
         for my $i (0 .. @{ $_list }) {
            if ($_pid = $_list->[$i]) {
               if (waitpid($_pid, _WNOHANG)) {
                  $self->{_total_exited}  += 1;
                  $self->{_total_running} -= 1;
                  $self->{_total_workers} -= 1;
                  $_list->[$i] = undef;
               }
            }
         }
         print {$_DAT_W_SOCK} 'NOOP'.$LF . '0'.$LF;
      };

      while ( $self->{_total_running} ) {
         alarm $_timeout;
         $_func = <$_DAT_R_SOCK>;
         $_DAU_R_SOCK = $_channels->[ <$_DAT_R_SOCK> ];

         alarm 0;
         if (exists $_core_output_function{$_func}) {
            $_core_output_function{$_func}();
         } elsif (exists $_plugin_function->{$_func}) {
            $_plugin_function->{$_func}();
         }
      }
   }

   ## Wait on requests *without* timeout capability.

   elsif ($^O eq 'MSWin32' && $_win32_ipc) {
      # The normal loop hangs on Windows when processes/threads start/exit.
      # Using ioctl() properly, http://www.perlmonks.org/?node_id=780083

      my $_val_bytes = "\x00\x00\x00\x00";
      my $_ptr_bytes = unpack( 'I', pack('P', $_val_bytes) );
      my ($_count, $_done, $_nbytes, $_start) = (1, 0);

      while (!$_done) {
         $_start = time;

         # MSWin32 FIONREAD
         IOCTL: ioctl($_DAT_R_SOCK, 0x4004667f, $_ptr_bytes);

         unless ($_nbytes = unpack('I', $_val_bytes)) {
            if ($_count) {
                # delay after a while to not consume a CPU core
                $_count = 0 if ++$_count % 50 == 0 && time - $_start > 0.005;
            } else {
                sleep 0.030;
            }
            goto IOCTL;
         }

         $_count = 1;

         do {
            sysread($_DAT_R_SOCK, $_func, 8);
            $_done = 1, last() unless length($_func) == 8;
            $_DAU_R_SOCK = $_channels->[ substr($_func, -2, 2, '') ];

            if (exists $_core_output_function{$_func}) {
               $_core_output_function{$_func}();
            } elsif (exists $_plugin_function->{$_func}) {
               $_plugin_function->{$_func}();
            }

         } while (($_nbytes -= 8) >= 8);

         last unless $self->{_total_running};
      }
   }

   elsif ($^O eq 'MSWin32') {
      while ($self->{_total_running}) {
         sysread($_DAT_R_SOCK, $_func, 8);
         last() unless length($_func) == 8;
         $_DAU_R_SOCK = $_channels->[ substr($_func, -2, 2, '') ];

         if (exists $_core_output_function{$_func}) {
            $_core_output_function{$_func}();
         } elsif (exists $_plugin_function->{$_func}) {
            $_plugin_function->{$_func}();
         }
      }
   }

   else {
      while ($self->{_total_running}) {
         $_func = <$_DAT_R_SOCK>;
         last() unless length($_func) == 6;
         $_DAU_R_SOCK = $_channels->[ <$_DAT_R_SOCK> ];

         if (exists $_core_output_function{$_func}) {
            $_core_output_function{$_func}();
         } elsif (exists $_plugin_function->{$_func}) {
            $_plugin_function->{$_func}();
         }
      }
   }

   ## Call module's loop_end routine for modules plugged into MCE.

   for my $_p (@{ $_plugin_loop_end }) {
      $_p->($self);
   }

   ## Call on_post_run callback.

   $_on_post_run->($self, $self->{_status}) if (defined $_on_post_run);

   ## Close opened sendto file handles.

   for my $_p (keys %_sendto_fhs) {
      close  $_sendto_fhs{$_p};
      undef  $_sendto_fhs{$_p};
      delete $_sendto_fhs{$_p};
   }

   ## Restore the default handle. Close MCE STDOUT/STDERR handles.

   select $_old_hndl;

   eval q{
      close $_MCE_STDOUT if (fileno $_MCE_STDOUT > 2);
      close $_MCE_STDERR if (fileno $_MCE_STDERR > 2);
   };

   return;
}

1;

