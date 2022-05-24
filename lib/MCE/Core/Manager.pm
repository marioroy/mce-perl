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

our $VERSION = '1.879';

## no critic (BuiltinFunctions::ProhibitStringyEval)
## no critic (TestingAndDebugging::ProhibitNoStrict)

## Items below are folded into MCE.

package # hide from rpm
   MCE;

no warnings qw( threads recursion uninitialized );

## The POSIX module has many symbols. Try not loading it simply
## to have WNOHANG. The following covers most platforms.

use constant {
   _WNOHANG => ( $INC{'POSIX.pm'} )
      ? &POSIX::WNOHANG : ( $^O eq 'solaris' ) ? 64 : 1
};

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
   elsif (defined $self->{task_end}) {
      $self->{task_end}->($self, 0, $self->{task_name});
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

my %_sendto_fhs;

sub _sendto_fhs_close {
   for my $_p (keys %_sendto_fhs) {
      close  $_sendto_fhs{$_p};
      delete $_sendto_fhs{$_p};
   }
}

sub _sendto_fhs_get {
   my ($self, $_fd) = @_;

   $_sendto_fhs{$_fd} || do {

      $_sendto_fhs{$_fd} = IO::Handle->new();
      $_sendto_fhs{$_fd}->fdopen($_fd, 'w')
         or _croak "Cannot open file descriptor ($_fd): $!";

      binmode $_sendto_fhs{$_fd};

      if (!exists $self->{flush_file} || $self->{flush_file}) {
         local $!;
         $_sendto_fhs{$_fd}->autoflush(1)
      }

      $_sendto_fhs{$_fd};
   };
}

sub _output_loop {

   my ( $self, $_input_data, $_input_glob, $_plugin_function,
        $_plugin_loop_begin, $_plugin_loop_end ) = @_;

   @_ = ();

   my (
      $_aborted, $_eof_flag, $_max_retries, $_syn_flag, $_win32_ipc,
      $_cb, $_chunk_id, $_chunk_size, $_file, $_size_completed, $_wa,
      @_is_c_ref, @_is_h_ref, @_is_q_ref, $_on_post_exit, $_on_post_run,
      $_has_user_tasks, $_sess_dir, $_task_id, $_user_error, $_user_output,
      $_input_size, $_offset_pos, $_single_dim, @_gather, $_cs_one_flag,
      $_exit_id, $_exit_pid, $_exit_status, $_exit_wid, $_len, $_sync_cnt,
      $_BSB_W_SOCK, $_BSB_R_SOCK, $_DAT_R_SOCK, $_DAU_R_SOCK, $_MCE_STDERR,
      $_I_FLG, $_O_FLG, $_I_SEP, $_O_SEP, $_RS, $_RS_FLG, $_MCE_STDOUT,
      @_delay_wid
   );

   ## -------------------------------------------------------------------------
   ## Callback return.

   my $_cb_reply = sub {
      local $\ = $_O_SEP if ($_O_FLG);
      local $/ = $_I_SEP if ($_I_FLG);

      no strict 'refs';

      if ( $_wa == WANTS_UNDEF ) {
         $_cb->(@_);
         return;
      }
      elsif ( $_wa == WANTS_ARRAY ) {
         my @_ret = $_cb->(@_);
         my $_buf = $self->{freeze}(\@_ret);

         return print {$_DAU_R_SOCK} length($_buf).$LF, $_buf;
      }

      my $_ret = $_cb->(@_);
      my $_buf = $self->{freeze}([ $_ret ]);

      return print {$_DAU_R_SOCK} length($_buf).$LF, $_buf;
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
               for my $_i (1 .. $_total_running) {
                  syswrite($_BSB_W_SOCK, $LF);
               }
               undef $_syn_flag;
            }
         }

         _task_end($self, $_task_id) unless $_total_running;

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
               for my $_i (1 .. $_total_running) {
                  syswrite($_BSB_W_SOCK, $LF);
               }
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

         local ($!, $?);

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
                  eval { $self->{_thrs}->[$i]->join() };
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
               $self->{_retry}     = $self->{thaw}($_retry_buf);
               $self->{_retry_cnt} = $_max_retries - $self->{_retry}[2] - 1;

               $_on_post_exit->($self, {
                  wid => $_exit_wid, pid => $_exit_pid, status => $_exit_status,
                  msg => $_exit_msg, id  => $_exit_id
               }, $self->{_retry_cnt});

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

         _task_end($self, $_task_id) unless $_total_running;

         return;
      },

      ## ----------------------------------------------------------------------

      OUTPUT_A_REF.$LF => sub {                   # Input << Array ref
         my $_buf;

         if ($_offset_pos >= $_input_size || $_aborted) {
            local $\ = undef if (defined $\);
            print {$_DAU_R_SOCK} '0'.$LF;

            return;
         }

         if ($_single_dim && $_cs_one_flag) {
            $_buf = $self->{freeze}( [ $_input_data->[$_offset_pos] ] );
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

      OUTPUT_G_REF.$LF => sub {                   # Input << Glob ref
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
                  $_buf .= $_input_glob->can('getline')
                     ? $_input_glob->getline : <$_input_glob>;
                  $_eof_flag = 1 unless (length $_buf);
               }
               else {
                  my $_last_len = 0;
                  for (1 .. $_chunk_size) {
                     $_buf .= $_input_glob->can('getline')
                        ? $_input_glob->getline : <$_input_glob>;
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
               if ($_input_glob->can('getline') && $_input_glob->can('read')) {
                  if ($_input_glob->read($_buf, $_chunk_size) == $_chunk_size) {
                     $_buf .= $_input_glob->getline;
                     $_eof_flag = 1 if (length $_buf == $_chunk_size);
                  } else {
                     $_eof_flag = 1;
                  }
               }
               else {
                  if (read($_input_glob, $_buf, $_chunk_size) == $_chunk_size) {
                     $_buf .= <$_input_glob>;
                     $_eof_flag = 1 if (length $_buf == $_chunk_size);
                  } else {
                     $_eof_flag = 1;
                  }
               }
            }
         }

         $_len = length $_buf; local $\ = undef if (defined $\);

         if ($_len) {
            my $_tmp = $self->{freeze}(\$_buf);
            print {$_DAU_R_SOCK} length($_tmp).$LF . (++$_chunk_id).$LF, $_tmp;
         }
         else {
            print {$_DAU_R_SOCK} '0'.$LF;
         }

         return;
      },

      OUTPUT_H_REF.$LF => sub {                   # Input << Hash ref
         my @_pairs;

         if ($_offset_pos >= $_input_size || $_aborted) {
            local $\ = undef if (defined $\);
            print {$_DAU_R_SOCK} '0'.$LF;

            return;
         }

         if ($_offset_pos + $_chunk_size - 1 < $_input_size) {
            for my $_i ($_offset_pos .. $_offset_pos + $_chunk_size - 1) {
               push @_pairs, each %{ $_input_data };
            }
         }
         else {
            for my $_i ($_offset_pos .. $_input_size - 1) {
               push @_pairs, each %{ $_input_data };
            }
         }

         my $_buf = $self->{freeze}(\@_pairs);

         $_len = length $_buf; local $\ = undef if (defined $\);
         print {$_DAU_R_SOCK} $_len.$LF . (++$_chunk_id).$LF, $_buf;
         $_offset_pos += $_chunk_size;

         return;
      },

      OUTPUT_I_REF.$LF => sub {                   # Input << Iter ref
         my $_buf;

         if ($_aborted) {
            local $\ = undef if (defined $\);
            print {$_DAU_R_SOCK} '-1'.$LF;

            return;
         }

         my @_ret_a = $_input_data->($_chunk_size);

         if (@_ret_a > 1 || defined $_ret_a[0]) {
            $_buf = $self->{freeze}([ @_ret_a ]);
            $_len = length $_buf; local $\ = undef if (defined $\);
            print {$_DAU_R_SOCK} $_len.$LF . (++$_chunk_id).$LF, $_buf;

            return;
         }

         local $\ = undef if (defined $\);
         print {$_DAU_R_SOCK} '-1'.$LF;
         $_aborted = 1;

         return;
      },

      ## ----------------------------------------------------------------------

      OUTPUT_A_CBK.$LF => sub {                   # Callback w/ args
         chomp($_wa  = <$_DAU_R_SOCK>),
         chomp($_cb  = <$_DAU_R_SOCK>),
         chomp($_len = <$_DAU_R_SOCK>);

         read $_DAU_R_SOCK, my($_buf), $_len;

         my $_aref = $self->{thaw}($_buf);
         undef $_buf;

         return $_cb_reply->(@{ $_aref });
      },

      OUTPUT_N_CBK.$LF => sub {                   # Callback w/ no args
         chomp($_wa = <$_DAU_R_SOCK>),
         chomp($_cb = <$_DAU_R_SOCK>);

         return $_cb_reply->();
      },

      OUTPUT_A_GTR.$LF => sub {                   # Gather data
         chomp($_task_id = <$_DAU_R_SOCK>),
         chomp($_len     = <$_DAU_R_SOCK>);

         read $_DAU_R_SOCK, my($_buf), $_len;

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

      ## ----------------------------------------------------------------------

      OUTPUT_O_SND.$LF => sub {                   # Send >> STDOUT
         chomp($_len = <$_DAU_R_SOCK>);

         read $_DAU_R_SOCK, my($_buf), $_len;
         $_buf = ${ $self->{thaw}($_buf) };

         if (defined $_user_output) {
            $_user_output->($_buf);
         }
         else {
            use bytes;
            print {$_MCE_STDOUT} $_buf;
         }

         return;
      },

      OUTPUT_E_SND.$LF => sub {                   # Send >> STDERR
         chomp($_len = <$_DAU_R_SOCK>);

         read $_DAU_R_SOCK, my($_buf), $_len;
         $_buf = ${ $self->{thaw}($_buf) };

         if (defined $_user_error) {
            $_user_error->($_buf);
         }
         else {
            use bytes;
            print {$_MCE_STDERR} $_buf;
         }

         return;
      },

      OUTPUT_F_SND.$LF => sub {                   # Send >> File
         my ($_buf, $_OUT_FILE);

         chomp($_len = <$_DAU_R_SOCK>);
         read $_DAU_R_SOCK, $_buf, $_len;

         $_buf  = $self->{thaw}($_buf);
         $_file = $_buf->[0];

         unless (exists $_sendto_fhs{$_file}) {
            open $_sendto_fhs{$_file}, ">>", "$_file"
               or _croak "Cannot open file for writing ($_file): $!";

            binmode $_sendto_fhs{$_file};

            if (!exists $self->{flush_file} || $self->{flush_file}) {
               local $!;
               $_sendto_fhs{$_file}->autoflush(1);
            }
         }

         {
            use bytes;
            $_OUT_FILE = $_sendto_fhs{$_file};
            print {$_OUT_FILE} $_buf->[1];
         }

         return;
      },

      OUTPUT_D_SND.$LF => sub {                   # Send >> File descriptor
         my ($_buf, $_OUT_FILE);

         chomp($_len = <$_DAU_R_SOCK>);
         read $_DAU_R_SOCK, $_buf, $_len;

         $_buf = $self->{thaw}($_buf);

         {
            use bytes;
            $_OUT_FILE = _sendto_fhs_get($self, $_buf->[0]);
            print {$_OUT_FILE} $_buf->[1];
         }

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
            for my $_i (1 .. $_total_running) {
               syswrite($_BSB_W_SOCK, $LF);
            }
            undef $_syn_flag;
         }

         return;
      },

      OUTPUT_E_SYN.$LF => sub {                   # Barrier sync - end
         if (--$_sync_cnt == 0) {
            my $_total_running = ($_has_user_tasks)
               ? $self->{_task}->[0]->{_total_running}
               : $self->{_total_running};

            for my $_i (1 .. $_total_running) {
               syswrite($_BSB_R_SOCK, $LF);
            }
         }

         return;
      },

      OUTPUT_S_IPC.$LF => sub {                   # Change to win32 IPC
         syswrite($_DAT_R_SOCK, $LF);

         $_win32_ipc = 1, goto _LOOP unless $_win32_ipc;

         return;
      },

      OUTPUT_C_NFY.$LF => sub {                   # Chunk ID notification
         chomp($_len = <$_DAU_R_SOCK>);

         my ($_pid, $_chunk_id) = split /:/, $_len;
         $self->{_pids_c}{$_pid} = $_chunk_id;

         return;
      },

      OUTPUT_P_NFY.$LF => sub {                   # Progress notification
         chomp($_len = <$_DAU_R_SOCK>);

         $self->{progress}->( $_size_completed += $_len );

         return;
      },

      OUTPUT_S_DIR.$LF => sub {                   # Make/get sess_dir
         print {$_DAU_R_SOCK} $self->sess_dir().$LF;

         return;
      },

      OUTPUT_T_DIR.$LF => sub {                   # Make/get tmp_dir
         print {$_DAU_R_SOCK} $self->tmp_dir().$LF;

         return;
      },

      OUTPUT_I_DLY.$LF => sub {                   # Interval delay
         my $_tasks = $_has_user_tasks ? $self->{user_tasks} : undef;

         chomp($_task_id = <$_DAU_R_SOCK>);

         my $_interval = ($_tasks && exists $_tasks->[$_task_id]{interval})
            ? $_tasks->[$_task_id]{interval}
            : $self->{interval};

         if (!$_interval) {
            print {$_DAU_R_SOCK} '0'.$LF;
         }
         elsif ($_interval->{max_nodes} == 1) {
            my $_delay = $_interval->{delay};
            my $_lapse = $_interval->{_lapse};
            my $_time  = MCE::Util::_time();

            if (!$_delay || !defined $_lapse) {
               $_lapse = $_time;
            }
            elsif ($_lapse + $_delay - $_time < 0) {
               $_lapse += int( abs($_time - $_lapse) / $_delay + 0.5 ) * $_delay;
            }

            $_interval->{_lapse} = ($_lapse += $_delay);
            print {$_DAU_R_SOCK} ($_lapse - $_time).$LF
         }
         else {
            my $_max_workers = ($_tasks)
               ? $_tasks->[$_task_id]{max_workers}
               : $self->{max_workers};

            if (++$_delay_wid[$_task_id] > $_max_workers) {
               $_delay_wid[$_task_id] = 1;
            }

            my $_nodes  = $_interval->{max_nodes};
            my $_id     = $_interval->{node_id};
            my $_delay  = $_interval->{delay} * $_nodes;

            my $_app_tb = $_delay * $_max_workers;
            my $_app_st = $_interval->{_time} + ($_delay / $_nodes * $_id);
            my $_wrk_st = ($_delay_wid[$_task_id] - 1) * $_delay + $_app_st;

            $_delay = $_wrk_st - MCE::Util::_time();

            if ($_delay < 0.0 && $_app_tb) {
               my $_count = int($_delay * -1 / $_app_tb + 0.5) + 1;
               $_delay += $_app_tb * $_count;
               $_interval->{_time} = MCE::Util::_time() if ($_count > 2e9);
            }

            ($_delay > 0.0)
               ? print {$_DAU_R_SOCK} $_delay.$LF
               : print {$_DAU_R_SOCK} '0'.$LF;
         }

         return;
      },

   );

   ## -------------------------------------------------------------------------

   local ($!, $?, $_);

   $_aborted = $_chunk_id = $_eof_flag = $_size_completed = 0;
   $_has_user_tasks = (defined $self->{user_tasks}) ? 1 : 0;
   $_cs_one_flag = ($self->{chunk_size} == 1) ? 1 : 0;

   $_max_retries  = $self->{max_retries};
   $_on_post_exit = $self->{on_post_exit};
   $_on_post_run  = $self->{on_post_run};
   $_chunk_size   = $self->{chunk_size};
   $_user_output  = $self->{user_output};
   $_user_error   = $self->{user_error};
   $_single_dim   = $self->{_single_dim};
   $_sess_dir     = $self->{_sess_dir};

   if (defined $_max_retries && !$_on_post_exit) {
      $_on_post_exit = sub {
         my ($self, $_e, $_retry_cnt) = @_;

         if ($_e->{id}) {
            my $_cnt = $_retry_cnt + 1;
            my $_msg = "Error: chunk $_e->{id} failed";

            if (defined $self->{init_relay}) {
               print {*STDERR} "$_msg, retrying chunk attempt # $_cnt\n"
                  if ($_retry_cnt < $_max_retries);
            }
            else {
               ($_retry_cnt < $_max_retries)
                  ? print {*STDERR} "$_msg, retrying chunk attempt # $_cnt\n"
                  : print {*STDERR} "$_msg\n";
            }

            $self->restart_worker;
         }
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
   }
   elsif (defined $_input_data && ref $_input_data eq 'HASH') {
      $_input_size = scalar( keys %{ $_input_data } );
      $_offset_pos = 0;
   }
   else {
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
   }

   if (defined $self->{stderr_file}) {
      open $_MCE_STDERR, '>>', $self->{stderr_file}
         or die $self->{stderr_file} . ": $!\n";
      binmode $_MCE_STDERR;
   }
   else {
      $_MCE_STDERR = \*STDERR;
   }

   ## Autoflush STDERR-STDOUT handles if not specified or requested.

   {
      local $!;

      $_MCE_STDERR->autoflush(1)
         if ( !exists $self->{flush_stderr} || $self->{flush_stderr} );

      $_MCE_STDOUT->autoflush(1)
         if ( !exists $self->{flush_stdout} || $self->{flush_stdout} );
   }

   ## -------------------------------------------------------------------------

   ## Output event loop.

   my $_channels = $self->{_dat_r_sock};
   my $_func;

   $_win32_ipc = (
      $ENV{'PERL_MCE_IPC'} eq 'win32' ||
      defined($self->{max_retries}) ||
      $INC{'MCE/Child.pm'} ||
      $INC{'MCE/Hobo.pm'}
   );

   $_BSB_W_SOCK = $self->{_bsb_w_sock};
   $_BSB_R_SOCK = $self->{_bsb_r_sock};
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

      $self->{_pids_c} = {};  # Chunk ID notification

      $_timeout = 5 if $_timeout < 5;

      local $SIG{ALRM} = sub {
         alarm 0; local ($!, $?);

         for my $i (0 .. @{ $_list }) {
            if ($_pid = $_list->[$i]) {
               if (waitpid($_pid, _WNOHANG)) {

                  $_list->[$i] = undef;

                  if ($? > abs($self->{_wrk_status})) {
                     $self->{_wrk_status} = $?;
                  }

                  my $_task_id = $self->{_pids_t}{$_pid};
                  my $_wid     = $self->{_pids_w}{$_pid};

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
                        for my $_i (1 .. $_total_running) {
                           syswrite($_BSB_W_SOCK, $LF);
                        }
                        undef $_syn_flag;
                     }
                  }

                  _task_end($self, $_task_id) unless $_total_running;

                  if (my $_cid = $self->{_pids_c}{$_pid}) {
                     warn "Error: process $_pid has ended prematurely\n",
                          "Error: chunk $_cid failed\n";

                     if ($_cid > $self->{_relayed}) {
                        local $SIG{CHLD} = 'IGNORE';
                        my $_pid = fork;

                        if (defined $_pid && $_pid == 0) {
                           delete $self->{max_retries};

                           $self->{_chunk_id} = $_cid;
                           $self->{_task_id}  = $_task_id;
                           $self->{_wid}      = $_wid;

                           eval 'MCE::relay';

                           CORE::kill('KILL', $$);
                           CORE::exit(0);
                        }
                     }
                  }

                  delete $self->{_pids_c}{$_pid};
                  delete $self->{_pids_t}{$_pid};
                  delete $self->{_pids_w}{$_pid};
               }
            }
         }

         print {$_DAT_W_SOCK} 'NOOP'.$LF . '0'.$LF;
      };

      while ( $self->{_total_running} ) {
         alarm $_timeout; $_func = <$_DAT_R_SOCK>; alarm 0;
         $_DAU_R_SOCK = $_channels->[ <$_DAT_R_SOCK> ];

         if (exists $_core_output_function{$_func}) {
            $_core_output_function{$_func}();
         } elsif (exists $_plugin_function->{$_func}) {
            $_plugin_function->{$_func}();
         }
      }

      delete $self->{_pids_c};
   }

   ## Wait on requests *without* timeout capability.

   elsif ($^O eq 'MSWin32') {
      MCE::Util::_nonblocking($_DAT_R_SOCK, 1) if $_win32_ipc;

      while ($self->{_total_running}) {
         MCE::Util::_sysread2($_DAT_R_SOCK, $_func, 8);
         last() unless length($_func) == 8;
         $_DAU_R_SOCK = $_channels->[ substr($_func, -2, 2, '') ];

         if (exists $_core_output_function{$_func}) {
            $_core_output_function{$_func}();
         } elsif (exists $_plugin_function->{$_func}) {
            $_plugin_function->{$_func}();
         }
      }

      MCE::Util::_nonblocking($_DAT_R_SOCK, 0) if $_win32_ipc;
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

   _sendto_fhs_close();

   ## Close MCE STDOUT/STDERR handles.

   eval q{
      close $_MCE_STDOUT if (fileno $_MCE_STDOUT > 2);
      close $_MCE_STDERR if (fileno $_MCE_STDERR > 2);
   };

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

MCE::Core::Manager - Core methods for the manager process

=head1 VERSION

This document describes MCE::Core::Manager version 1.879

=head1 DESCRIPTION

This package provides the loop and relevant methods used internally by the
manager process.

There is no public API.

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

