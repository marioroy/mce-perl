###############################################################################
## ----------------------------------------------------------------------------
## Core methods for the worker process.
##
## This package provides main, loop, and relevant methods used internally by
## the worker process.
##
## There is no public API.
##
###############################################################################

package MCE::Core::Worker;

use strict;
use warnings;

our $VERSION = '1.879';

my $_tid = $INC{'threads.pm'} ? threads->tid() : 0;

sub CLONE {
   $_tid = threads->tid() if $INC{'threads.pm'};
}

## Items below are folded into MCE.

package # hide from rpm
   MCE;

no warnings qw( threads recursion uninitialized );

###############################################################################
## ----------------------------------------------------------------------------
## Internal do, gather and send related functions for serializing data to
## destination. User functions for handling gather, queue or void.
##
###############################################################################

{
   my (
      $_dest, $_len, $_tag, $_task_id, $_user_func, $_val, $_wa,
      $_DAT_LOCK, $_DAT_W_SOCK, $_DAU_W_SOCK, $_chn, $_lock_chn,
      $_dat_ex, $_dat_un
   );

   ## Create array structure containing various send functions.
   my @_dest_function = ();

   $_dest_function[SENDTO_FILEV2] = sub {         ## Content >> File

      return unless (defined $_val);
      local $\ = undef if (defined $\);

      if (length ${ $_[1] }) {
         my $_buf = $_[0]->{freeze}([ $_val, ${ $_[1] } ]);
         $_dat_ex->() if $_lock_chn;
         print({$_DAT_W_SOCK} OUTPUT_F_SND.$LF . $_chn.$LF),
         print({$_DAU_W_SOCK} length($_buf).$LF, $_buf);
         $_dat_un->() if $_lock_chn;
      }

      return;
   };

   $_dest_function[SENDTO_FD] = sub {             ## Content >> File descriptor

      return unless (defined $_val);
      local $\ = undef if (defined $\);

      if (length ${ $_[1] }) {
         my $_buf = $_[0]->{freeze}([ $_val, ${ $_[1] } ]);
         $_dat_ex->() if $_lock_chn;
         print({$_DAT_W_SOCK} OUTPUT_D_SND.$LF . $_chn.$LF),
         print({$_DAU_W_SOCK} length($_buf).$LF, $_buf);
         $_dat_un->() if $_lock_chn;
      }

      return;
   };

   $_dest_function[SENDTO_STDOUT] = sub {         ## Content >> STDOUT

      local $\ = undef if (defined $\);

      if (length ${ $_[1] }) {
         my $_buf = $_[0]->{freeze}($_[1]);
         $_dat_ex->() if $_lock_chn;
         print({$_DAT_W_SOCK} OUTPUT_O_SND.$LF . $_chn.$LF),
         print({$_DAU_W_SOCK} length($_buf).$LF, $_buf);
         $_dat_un->() if $_lock_chn;
      }

      return;
   };

   $_dest_function[SENDTO_STDERR] = sub {         ## Content >> STDERR

      local $\ = undef if (defined $\);

      if (length ${ $_[1] }) {
         my $_buf = $_[0]->{freeze}($_[1]);
         $_dat_ex->() if $_lock_chn;
         print({$_DAT_W_SOCK} OUTPUT_E_SND.$LF . $_chn.$LF),
         print({$_DAU_W_SOCK} length($_buf).$LF, $_buf);
         $_dat_un->() if $_lock_chn;
      }

      return;
   };

   ## -------------------------------------------------------------------------

   sub _do_callback {

      my ($self, $_buf, $_aref);

      ($self, $_val, $_aref) = @_;

      unless (defined wantarray) {
         $_wa = WANTS_UNDEF;
      } elsif (wantarray) {
         $_wa = WANTS_ARRAY;
      } else {
         $_wa = WANTS_SCALAR;
      }

      local $\ = undef if (defined $\);

      ## Crossover: Send arguments

      if ( ! @{ $_aref } ) {
         $_dat_ex->() if $_lock_chn;
         print({$_DAT_W_SOCK} OUTPUT_N_CBK.$LF . $_chn.$LF),
         print({$_DAU_W_SOCK} $_wa.$LF . $_val.$LF);
      }
      else {
         $_buf = $self->{freeze}($_aref);
         $_len = length $_buf;

         $_dat_ex->() if $_lock_chn;
         print({$_DAT_W_SOCK} OUTPUT_A_CBK.$LF . $_chn.$LF),
         print({$_DAU_W_SOCK} $_wa.$LF . $_val.$LF . $_len.$LF, $_buf);
      }

      ## Crossover: Receive value

      if ( $_wa ) {
         local $/ = $LF if ($/ ne $LF);
         chomp(my $_len = <$_DAU_W_SOCK>);

         read $_DAU_W_SOCK, my($_buf), $_len;
         $_dat_un->() if $_lock_chn;

         return ( $_wa != WANTS_ARRAY )
            ? ($self->{thaw}($_buf))->[0]
            : @{ $self->{thaw}($_buf) };
      }

      $_dat_un->() if $_lock_chn;
   }

   ## -------------------------------------------------------------------------

   sub _do_gather {

      my $_buf; my ($self, $_aref) = @_;

      return unless (scalar @{ $_aref });

      $_tag = OUTPUT_A_GTR;
      $_buf = $self->{freeze}($_aref);
      $_len = length $_buf;

      local $\ = undef if (defined $\);

      $_dat_ex->() if $_lock_chn;
      print({$_DAT_W_SOCK} $_tag.$LF . $_chn.$LF),
      print({$_DAU_W_SOCK} $_task_id.$LF . $_len.$LF, $_buf);
      $_dat_un->() if $_lock_chn;

      return;
   }

   ## -------------------------------------------------------------------------

   sub _do_send {

      my $_data_ref; my $self = shift;

      $_dest = shift; $_val = shift;

      if (scalar @_ > 1) {
         $_data_ref = \join('', @_);
      }
      elsif (my $_ref = ref $_[0]) {
         if ($_ref eq 'SCALAR') {
            $_data_ref = $_[0];
         }
         elsif ($_ref eq 'ARRAY') {
            $_data_ref = \join('', @{ $_[0] });
         }
         elsif ($_ref eq 'HASH') {
            $_data_ref = \join('', %{ $_[0] });
         }
         else {
            $_data_ref = \join('', @_);
         }
      }
      else {
         $_data_ref = \(''.$_[0]);
      }

      $_dest_function[$_dest]($self, $_data_ref);

      return 1;
   }

   sub _do_send_glob {

      my ($self, $_glob, $_fd, $_data_ref) = @_;

      if ($self->{_wid} > 0) {
         if ($_fd == 1) {
            _do_send($self, SENDTO_STDOUT, undef, $_data_ref);
         }
         elsif ($_fd == 2) {
            _do_send($self, SENDTO_STDERR, undef, $_data_ref);
         }
         else {
            _do_send($self, SENDTO_FD, $_fd, $_data_ref);
         }
      }
      else {
         use bytes;
         my $_fh = _sendto_fhs_get($self, $_fd);
         local $\ = undef if (defined $\);

         print {$_fh} ${ $_data_ref };
      }

      return 1;
   }

   ## -------------------------------------------------------------------------

   sub _do_send_init {

      my ($self) = @_;

      $_chn        = $self->{_chn};
      $_DAT_LOCK   = $self->{_dat_lock};
      $_DAT_W_SOCK = $self->{_dat_w_sock}->[0];
      $_DAU_W_SOCK = $self->{_dat_w_sock}->[$_chn];
      $_lock_chn   = $self->{_lock_chn};
      $_task_id    = $self->{_task_id};

      if ($_lock_chn) {
         # inlined for performance
         $_dat_ex = sub {
            my $_pid = $_tid ? $$ .'.'. $_tid : $$;
            MCE::Util::_sysread($_DAT_LOCK->{_r_sock}, my($b), 1), $_DAT_LOCK->{ $_pid } = 1
               unless $_DAT_LOCK->{ $_pid };
         };
         $_dat_un = sub {
            my $_pid = $_tid ? $$ .'.'. $_tid : $$;
            syswrite($_DAT_LOCK->{_w_sock}, '0'), $_DAT_LOCK->{ $_pid } = 0
               if $_DAT_LOCK->{ $_pid };
         };
      }

      {
         local $!;
         (*STDERR)->autoflush(1) if defined( fileno *STDERR );
         (*STDOUT)->autoflush(1) if defined( fileno *STDOUT );
      }

      return;
   }

   sub _do_send_clear {

      my ($self) = @_;

      $_dest = $_len = $_task_id = $_user_func = $_val = $_wa = undef;
      $_DAT_LOCK = $_DAT_W_SOCK = $_DAU_W_SOCK = $_chn = $_lock_chn = undef;
      $_dat_ex = $_dat_un = $_tag = undef;

      return;
   }

   ## -------------------------------------------------------------------------

   sub _do_user_func {

      my ($self, $_chunk, $_chunk_id) = @_;
      my $_size = 0;

      delete $self->{_relayed};
      $self->{_chunk_id} = $_chunk_id;

      if ($self->{progress} && $self->{_task_id} == 0) {
         # use_slurpio
         if (ref $_chunk eq 'SCALAR') {
            $_size += length ${ $_chunk };
         }
         # sequence and bounds_only
         elsif ($self->{sequence} && $self->{bounds_only}) {
            my $_seq = $self->{sequence};
            my $_step = (ref $_seq eq 'ARRAY') ? $_seq->[2] : $_seq->{step};
            $_size += int(abs($_chunk->[0] - $_chunk->[1]) / abs($_step)) + 1;
         }
         # workers clear {input_data} to conserve memory when array ref
         # otherwise, /path/to/infile or scalar reference
         elsif ($self->{input_data}) {
            map { $_size += length } @{ $_chunk };
         }
         # array or sequence
         else {
            $_size += (ref $_chunk eq 'ARRAY') ? @{ $_chunk } : 1;
         }
      }

      if ($self->{max_retries}) {
         $self->{_retry} = [ $_chunk, $_chunk_id, $self->{max_retries} ];
      }

      if ($self->{loop_timeout} && $self->{_task_id} == 0 &&
          defined $self->{init_relay} && !$self->{_is_thread} &&
          $^O ne 'MSWin32') {

         local $\ = undef if (defined $\);

         $_dat_ex->() if $_lock_chn;
         print({$_DAT_W_SOCK} OUTPUT_C_NFY.$LF . $_chn.$LF),
         print({$_DAU_W_SOCK} "$$:$_chunk_id".$LF);
         $_dat_un->() if $_lock_chn;
      }

      $_user_func->($self, $_chunk, $_chunk_id);

      if ($self->{progress} && $self->{_task_id} == 0) {
         local $\ = undef if (defined $\);

         $_dat_ex->() if $_lock_chn;
         print({$_DAT_W_SOCK} OUTPUT_P_NFY.$LF . $_chn.$LF),
         print({$_DAU_W_SOCK} $_size.$LF);
         $_dat_un->() if $_lock_chn;
      }

      return;
   }

   sub _do_user_func_init {

      my ($self) = @_;

      $_user_func = $self->{user_func};

      return;
   }
}

###############################################################################
## ----------------------------------------------------------------------------
## Worker process -- Do.
##
###############################################################################

sub _worker_do {

   my ($self, $_params_ref) = @_;

   @_ = ();

   ## Set options.
   $self->{_abort_msg}  = $_params_ref->{_abort_msg};
   $self->{_run_mode}   = $_params_ref->{_run_mode};
   $self->{use_slurpio} = $_params_ref->{_use_slurpio};
   $self->{parallel_io} = $_params_ref->{_parallel_io};
   $self->{progress}    = $_params_ref->{_progress};
   $self->{max_retries} = $_params_ref->{_max_retries};
   $self->{RS}          = $_params_ref->{_RS};

   _do_user_func_init($self);

   ## Init local vars.
   my $_chn        = $self->{_chn};
   my $_DAT_LOCK   = $self->{_dat_lock};
   my $_DAT_W_SOCK = $self->{_dat_w_sock}->[0];
   my $_DAU_W_SOCK = $self->{_dat_w_sock}->[$_chn];
   my $_lock_chn   = $self->{_lock_chn};
   my $_run_mode   = $self->{_run_mode};
   my $_task_id    = $self->{_task_id};
   my $_task_name  = $self->{task_name};

   ## Do not override params if defined in user_tasks during instantiation.
   for my $_p (qw(bounds_only chunk_size sequence user_args)) {
      if (defined $_params_ref->{"_${_p}"}) {
         $self->{$_p} = $_params_ref->{"_${_p}"}
            unless (defined $self->{_task}->{$_p});
      }
   }

   ## Assign user function.
   $self->{_wuf} = \&_do_user_func;

   ## Call user_begin if defined.
   if (defined $self->{user_begin}) {
      $self->{_chunk_id} = 0;
      $self->{user_begin}($self, $_task_id, $_task_name);
      if ($_task_id == 0 && defined $self->{init_relay} && !$self->{_retry}) {
         $self->sync();
      }
   }

   ## Retry chunk if previous attempt died.
   if ($self->{_retry}) {
      $self->{_chunk_id} = $self->{_retry}->[1];
      $self->{user_func}->($self, $self->{_retry}->[0], $self->{_retry}->[1]);
      delete $self->{_retry};
   }

   ## Call worker function.
   if ($_run_mode eq 'sequence') {
      require MCE::Core::Input::Sequence
         unless $INC{'MCE/Core/Input/Sequence.pm'};
      _worker_sequence_queue($self);
   }
   elsif (defined $self->{_task}->{sequence}) {
      require MCE::Core::Input::Generator
         unless $INC{'MCE/Core/Input/Generator.pm'};
      _worker_sequence_generator($self);
   }
   elsif ($_run_mode eq 'array') {
      require MCE::Core::Input::Request
         unless $INC{'MCE/Core/Input/Request.pm'};
      _worker_request_chunk($self, REQUEST_ARRAY);
   }
   elsif ($_run_mode eq 'glob') {
      require MCE::Core::Input::Request
         unless $INC{'MCE/Core/Input/Request.pm'};
      _worker_request_chunk($self, REQUEST_GLOB);
   }
   elsif ($_run_mode eq 'hash') {
      require MCE::Core::Input::Request
         unless $INC{'MCE/Core/Input/Request.pm'};
      _worker_request_chunk($self, REQUEST_HASH);
   }
   elsif ($_run_mode eq 'iterator') {
      require MCE::Core::Input::Iterator
         unless $INC{'MCE/Core/Input/Iterator.pm'};
      _worker_user_iterator($self);
   }
   elsif ($_run_mode eq 'file') {
      require MCE::Core::Input::Handle
         unless $INC{'MCE/Core/Input/Handle.pm'};
      _worker_read_handle($self, READ_FILE, $_params_ref->{_input_file});
   }
   elsif ($_run_mode eq 'memory') {
      require MCE::Core::Input::Handle
         unless $INC{'MCE/Core/Input/Handle.pm'};
      _worker_read_handle($self, READ_MEMORY, $self->{input_data});
   }
   elsif (defined $self->{user_func}) {
      if ($self->{max_retries}) {
         $self->{_retry} = [ undef, 0, $self->{max_retries} ];
      }
      $self->{_chunk_id} = 0;
      $self->{user_func}->($self);
   }

   undef $self->{_next_jmp} if (defined $self->{_next_jmp});
   undef $self->{_last_jmp} if (defined $self->{_last_jmp});
   undef $self->{user_data} if (defined $self->{user_data});

   ## Call user_end if defined.
   if (defined $self->{user_end}) {
      $self->{_chunk_id} = 0;
      $self->sync() if ($_task_id == 0 && defined $self->{init_relay});
      $self->{user_end}($self, $_task_id, $_task_name);
   }

   delete $self->{_wuf};

   ## Check for nested workers not yet joined.
   MCE::Child->finish('MCE') if $INC{'MCE/Child.pm'};
   MCE::Hobo->finish('MCE')  if $INC{'MCE/Hobo.pm'};

   ## Notify the main process a worker has completed.
   local $\ = undef if (defined $\);

   $_DAT_LOCK->lock() if $_lock_chn;

   print({$_DAT_W_SOCK} OUTPUT_W_DNE.$LF . $_chn.$LF),
   print({$_DAU_W_SOCK} $_task_id.$LF);

   $_DAT_LOCK->unlock() if $_lock_chn;

   if ($^O eq 'MSWin32') {
      lock $self->{_run_lock};
   }

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Worker process -- Loop.
##
###############################################################################

sub _worker_loop {

   my ($self) = @_;

   @_ = ();

   my ($_response, $_len, $_buf, $_params_ref);

   my $_COM_LOCK   = $self->{_com_lock};
   my $_COM_W_SOCK = $self->{_com_w_sock};
   my $_job_delay  = $self->{job_delay};

   if ($^O eq 'MSWin32') { lock $MCE::_WIN_LOCK; }

   while (1) {
      {
         local $\ = undef; local $/ = $LF;
         $_COM_LOCK->lock();

         ## Wait for the next job request.
         $_response = <$_COM_W_SOCK>, print {$_COM_W_SOCK} $self->{_wid}.$LF;

         ## Return if instructed to exit.
         $_COM_LOCK->unlock(), return if ($_response eq "_exit\n");

         ## Process send request.
         if ($_response eq "_data\n") {
            chomp($_len = <$_COM_W_SOCK>), read($_COM_W_SOCK, $_buf, $_len);
            print({$_COM_W_SOCK} $LF), $_COM_LOCK->unlock();
            $self->{user_data} = $self->{thaw}($_buf), undef $_buf;

            sleep $_job_delay * $self->{_wid}
               if defined($_job_delay) && $_job_delay > 0.0;
         }

         ## Process normal request.
         elsif ($_response =~ /\d+/) {
            chomp($_len = <$_COM_W_SOCK>), read($_COM_W_SOCK, $_buf, $_len);
            print({$_COM_W_SOCK} $LF), $_COM_LOCK->unlock();
            $_params_ref = $self->{thaw}($_buf), undef $_buf;
         }

         ## Leave loop if invalid response.
         else {
            last;
         }
      }

      ## Send request.
      _worker_do($self, {}), next if ($_response eq "_data\n");

      ## Wait here until MCE completes job submission to all workers.
      MCE::Util::_sysread($self->{_bsb_w_sock}, my($_b), 1);

      ## Normal request.
      sleep $_job_delay * $self->{_wid}
         if defined($_job_delay) && $_job_delay > 0.0;

      _worker_do($self, $_params_ref); undef $_params_ref;
   }

   ## Notify the main process a worker has ended. The following is executed
   ## when an invalid reply was received above (not likely to occur).

   $_COM_LOCK->unlock();

   die "Error: worker $self->{_wid} has ended prematurely";
}

###############################################################################
## ----------------------------------------------------------------------------
## Worker process -- Main.
##
###############################################################################

sub _worker_main {

   my ( $self, $_wid, $_task, $_task_id, $_task_wid, $_params,
        $_plugin_worker_init ) = @_;

   @_ = ();

   if (exists $self->{input_data}) {
      my $_ref = ref $self->{input_data};
      delete $self->{input_data} if ($_ref && $_ref ne 'SCALAR');
   }

   $self->{_task_id}  = (defined $_task_id ) ? $_task_id  : 0;
   $self->{_task_wid} = (defined $_task_wid) ? $_task_wid : $_wid;
   $self->{_task}     = $_task;
   $self->{_wid}      = $_wid;

   ## Define exit pid and DIE handler.
   my $_use_threads = (defined $_task->{use_threads})
      ? $_task->{use_threads} : $self->{use_threads};

   if ($INC{'threads.pm'} && $_use_threads) {
      $self->{_exit_pid} = 'TID_' . $_tid;
   } else {
      $self->{_exit_pid} = 'PID_' . $$;
   }

   my $_running_inside_eval = $^S;

   local $SIG{SEGV} = sub { $self->exit(11) };

   local $SIG{__DIE__} = sub {
      if (!defined $^S || $^S) {
         if ( ($INC{'threads.pm'} && $_tid != 0) ||
               $ENV{'PERL_IPERL_RUNNING'} ||
               $_running_inside_eval
         ) {
            # thread env or running inside IPerl, check stack trace
            my $_t = Carp::longmess(); $_t =~ s/\teval [^\n]+\n$//;
            if ( $_t =~ /^(?:[^\n]+\n){1,7}\teval / ||
                 $_t =~ /\n\teval [^\n]+\n\t(?:eval|Try)/ )
            {
               CORE::die(@_);
            }
         }
         else {
            # normal env, trust $^S
            CORE::die(@_);
         }
      }

      $SIG{__DIE__} = $SIG{__WARN__} = sub {};
      my $_die_msg = (defined $_[0]) ? $_[0] : '';
      local $\ = undef; print {*STDERR} $_die_msg;

      $self->exit(255, $_die_msg, $self->{_chunk_id});
   };

   ## Use options from user_tasks if defined.
   $self->{max_workers} = $_task->{max_workers} if ($_task->{max_workers});
   $self->{chunk_size}  = $_task->{chunk_size}  if ($_task->{chunk_size});
   $self->{gather}      = $_task->{gather}      if ($_task->{gather});
   $self->{sequence}    = $_task->{sequence}    if ($_task->{sequence});
   $self->{bounds_only} = $_task->{bounds_only} if ($_task->{bounds_only});
   $self->{task_name}   = $_task->{task_name}   if ($_task->{task_name});
   $self->{user_args}   = $_task->{user_args}   if ($_task->{user_args});
   $self->{user_begin}  = $_task->{user_begin}  if ($_task->{user_begin});
   $self->{user_func}   = $_task->{user_func}   if ($_task->{user_func});
   $self->{user_end}    = $_task->{user_end}    if ($_task->{user_end});

   ## Init runtime vars. Obtain handle to lock files.
   my $_chn;

   if (defined $_params && exists $_params->{_chn}) {
      $_chn = $self->{_chn} = delete $_params->{_chn};
   } else {
      $_chn = $self->{_chn} = $_wid % $self->{_data_channels} + 1;
   }

   ## Choose locks for DATA channels.
   $self->{_com_lock} = $self->{'_mutex_0'};
   $self->{_dat_lock} = $self->{'_mutex_'.$_chn} if ($self->{_lock_chn});

   ## Delete attributes no longer required after being spawned.
   delete @{ $self }{ qw(
      flush_file flush_stderr flush_stdout stderr_file stdout_file
      on_post_exit on_post_run user_data user_error user_output
      _pids _state _status _thrs _tids
   ) };

   ## Call MCE::Shared's init routine if present; enables parallel IPC.
   ## For threads, init is called automatically via the CLONE feature.
   MCE::Shared::init() if (!$_use_threads && $INC{'MCE/Shared.pm'});

   _do_send_init($self);

   ## Call module's worker_init routine for modules plugged into MCE.
   for my $_p (@{ $_plugin_worker_init }) { $_p->($self); }

   ## Begin processing if worker was added during processing.
   _worker_do($self, $_params), undef $_params if defined($_params);

   ## Enter worker loop.
   _worker_loop($self);

   ## Clear worker session.
   _do_send_clear($self);

   $self->{_com_lock} = undef;
   $self->{_dat_lock} = undef;

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

MCE::Core::Worker - Core methods for the worker process

=head1 VERSION

This document describes MCE::Core::Worker version 1.879

=head1 DESCRIPTION

This package provides main, loop, and relevant methods used internally by
the worker process.

There is no public API.

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

