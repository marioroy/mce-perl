###############################################################################
## ----------------------------------------------------------------------------
## MCE - Many-Core Engine for Perl providing parallel processing capabilities.
##
###############################################################################

package MCE;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized );

our $VERSION = '1.879';

## no critic (BuiltinFunctions::ProhibitStringyEval)
## no critic (Subroutines::ProhibitSubroutinePrototypes)
## no critic (TestingAndDebugging::ProhibitNoStrict)

use Carp ();

my ($_has_threads, $_freeze, $_thaw, $_tid, $_oid);

BEGIN {
   local $@;

   if ( $^O eq 'MSWin32' && ! $INC{'threads.pm'} ) {
      eval 'use threads; use threads::shared;';
   }
   elsif ( $INC{'threads.pm'} && ! $INC{'threads/shared.pm'} ) {
      eval 'use threads::shared;';
   }

   $_has_threads = $INC{'threads.pm'} ? 1 : 0;
   $_tid = $_has_threads ? threads->tid() : 0;
   $_oid = "$$.$_tid";

   if ( $] ge '5.008008' && ! $INC{'PDL.pm'} ) {
      eval 'use Sereal::Encoder 3.015; use Sereal::Decoder 3.015;';
      if ( ! $@ ) {
         my $_encoder_ver = int( Sereal::Encoder->VERSION() );
         my $_decoder_ver = int( Sereal::Decoder->VERSION() );
         if ( $_encoder_ver - $_decoder_ver == 0 ) {
            $_freeze = \&Sereal::Encoder::encode_sereal;
            $_thaw   = \&Sereal::Decoder::decode_sereal;
         }
      }
   }

   if ( ! defined $_freeze ) {
      require Storable;
      $_freeze = \&Storable::freeze;
      $_thaw   = \&Storable::thaw;
   }
}

use IO::Handle ();
use Scalar::Util qw( looks_like_number refaddr reftype weaken );
use Socket qw( SOL_SOCKET SO_RCVBUF );
use Time::HiRes qw( sleep time );

use MCE::Util qw( $LF );
use MCE::Signal ();
use MCE::Mutex ();

our ($MCE, $RLA, $_que_template, $_que_read_size);
our (%_valid_fields_new);

my  ($TOP_HDLR, $_is_MSWin32, $_is_winenv, $_prev_mce);
my  (%_valid_fields_task, %_params_allowed_args);

BEGIN {
   ## Configure pack/unpack template for writing to and from the queue.
   ## Each entry contains 2 positive numbers: chunk_id & msg_id.
   ## Check for >= 64-bit, otherwize fall back to machine's word length.

   $_que_template  = ( ( log(~0+1) / log(2) ) >= 64 ) ? 'Q2' : 'I2';
   $_que_read_size = length pack($_que_template, 0, 0);

   ## Attributes used internally.
   ## _abort_msg _caller _chn _com_lock _dat_lock _mgr_live _rla_data _seed
   ## _chunk_id _pids _run_mode _single_dim _thrs _tids _task_wid _wid _wuf
   ## _exiting _exit_pid _last_sref _total_exited _total_running _total_workers
   ## _send_cnt _sess_dir _spawned _state _status _task _task_id _wrk_status
   ## _init_pid _init_total_workers _pids_t _pids_w _pids_c _relayed
   ##
   ## _bsb_r_sock _bsb_w_sock _com_r_sock _com_w_sock _dat_r_sock _dat_w_sock
   ## _que_r_sock _que_w_sock _rla_r_sock _rla_w_sock _data_channels
   ## _lock_chn   _mutex_n

   %_valid_fields_new = map { $_ => 1 } qw(
      max_workers tmp_dir use_threads user_tasks task_end task_name freeze thaw
      chunk_size input_data sequence job_delay spawn_delay submit_delay RS
      flush_file flush_stderr flush_stdout stderr_file stdout_file use_slurpio
      interval user_args user_begin user_end user_func user_error user_output
      bounds_only gather init_relay on_post_exit on_post_run parallel_io
      loop_timeout max_retries progress posix_exit
   );
   %_params_allowed_args = map { $_ => 1 } qw(
      chunk_size input_data sequence job_delay spawn_delay submit_delay RS
      flush_file flush_stderr flush_stdout stderr_file stdout_file use_slurpio
      interval user_args user_begin user_end user_func user_error user_output
      bounds_only gather init_relay on_post_exit on_post_run parallel_io
      loop_timeout max_retries progress
   );
   %_valid_fields_task = map { $_ => 1 } qw(
      max_workers chunk_size input_data interval sequence task_end task_name
      bounds_only gather init_relay user_args user_begin user_end user_func
      RS parallel_io use_slurpio use_threads
   );

   $_is_MSWin32 = ( $^O eq 'MSWin32' ) ? 1 : 0;
   $_is_winenv  = ( $^O =~ /mswin|mingw|msys|cygwin/i ) ? 1 : 0;

   ## Create accessor functions.
   no strict 'refs'; no warnings 'redefine';

   for my $_p (qw( chunk_size max_retries max_workers task_name user_args )) {
      *{ $_p } = sub () {
         my $self = shift; $self = $MCE unless ref($self);
         return $self->{$_p};
      };
   }
   for my $_p (qw( chunk_id task_id task_wid wid )) {
      *{ $_p } = sub () {
         my $self = shift; $self = $MCE unless ref($self);
         return $self->{"_${_p}"};
      };
   }
   for my $_p (qw( freeze thaw )) {
      *{ $_p } = sub () {
         my $self = shift; $self = $MCE unless ref($self);
         return $self->{$_p}(@_);
      };
   }

   $RLA = {};

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Import routine.
##
###############################################################################

use constant { SELF => 0, CHUNK => 1, CID => 2 };

our $_MCE_LOCK : shared = 1;
our $_WIN_LOCK : shared = 1;

my ($_def, $_imported) = ({});

sub import {
   my ($_class, $_pkg) = (shift, caller);
   my $_p = $_def->{$_pkg} = {};

   ## Process module arguments.
   while ( my $_argument = shift ) {
      my $_arg = lc $_argument;

      $_p->{MAX_WORKERS} = shift, next if ( $_arg eq 'max_workers' );
      $_p->{CHUNK_SIZE}  = shift, next if ( $_arg eq 'chunk_size' );
      $_p->{TMP_DIR}     = shift, next if ( $_arg eq 'tmp_dir' );
      $_p->{FREEZE}      = shift, next if ( $_arg eq 'freeze' );
      $_p->{THAW}        = shift, next if ( $_arg eq 'thaw' );

      if ( $_arg eq 'export_const' || $_arg eq 'const' ) {
         if ( shift eq '1' ) {
            no strict 'refs'; no warnings 'redefine';
            *{ $_pkg.'::SELF'  } = \&SELF;
            *{ $_pkg.'::CHUNK' } = \&CHUNK;
            *{ $_pkg.'::CID'   } = \&CID;
         }
         next;
      }

      ## Sereal, if available, is used automatically by MCE 1.800 onwards.
      if ( $_arg eq 'sereal' ) {
         if ( shift eq '0' ) {
            require Storable;
            $_p->{FREEZE} = \&Storable::freeze;
            $_p->{THAW}   = \&Storable::thaw;
         }
         next;
      }

      _croak("Error: ($_argument) invalid module option");
   }

   return if $_imported++;

   ## Instantiate a module-level instance.
   $MCE = MCE->new( _module_instance => 1, max_workers => 0 );

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Define constants & variables.
##
###############################################################################

use constant {

   # Max data channels. This cannot be greater than 8 on MSWin32.
   DATA_CHANNELS  => ($^O eq 'MSWin32') ? 8 : 10,

   # Max GC size. Undef variable when exceeding size.
   MAX_GC_SIZE    => 1024 * 1024 * 64,

   MAX_RECS_SIZE  => 8192,     # Reads number of records if N <= value
                               # Reads number of bytes if N > value

   OUTPUT_W_ABT   => 'W~ABT',  # Worker has aborted
   OUTPUT_W_DNE   => 'W~DNE',  # Worker has completed
   OUTPUT_W_RLA   => 'W~RLA',  # Worker has relayed
   OUTPUT_W_EXT   => 'W~EXT',  # Worker has exited
   OUTPUT_A_REF   => 'A~REF',  # Input << Array ref
   OUTPUT_G_REF   => 'G~REF',  # Input << Glob ref
   OUTPUT_H_REF   => 'H~REF',  # Input << Hash ref
   OUTPUT_I_REF   => 'I~REF',  # Input << Iter ref
   OUTPUT_A_CBK   => 'A~CBK',  # Callback w/ multiple args
   OUTPUT_N_CBK   => 'N~CBK',  # Callback w/ no args
   OUTPUT_A_GTR   => 'A~GTR',  # Gather data
   OUTPUT_O_SND   => 'O~SND',  # Send >> STDOUT
   OUTPUT_E_SND   => 'E~SND',  # Send >> STDERR
   OUTPUT_F_SND   => 'F~SND',  # Send >> File
   OUTPUT_D_SND   => 'D~SND',  # Send >> File descriptor
   OUTPUT_B_SYN   => 'B~SYN',  # Barrier sync - begin
   OUTPUT_E_SYN   => 'E~SYN',  # Barrier sync - end
   OUTPUT_S_IPC   => 'S~IPC',  # Change to win32 IPC
   OUTPUT_C_NFY   => 'C~NFY',  # Chunk ID notification
   OUTPUT_P_NFY   => 'P~NFY',  # Progress notification
   OUTPUT_R_NFY   => 'R~NFY',  # Relay notification
   OUTPUT_S_DIR   => 'S~DIR',  # Make/get sess_dir
   OUTPUT_T_DIR   => 'T~DIR',  # Make/get tmp_dir
   OUTPUT_I_DLY   => 'I~DLY',  # Interval delay

   READ_FILE      => 0,        # Worker reads file handle
   READ_MEMORY    => 1,        # Worker reads memory handle

   REQUEST_ARRAY  => 0,        # Worker requests next array chunk
   REQUEST_GLOB   => 1,        # Worker requests next glob chunk
   REQUEST_HASH   => 2,        # Worker requests next hash chunk

   SENDTO_FILEV1  => 0,        # Worker sends to 'file', $a, '/path'
   SENDTO_FILEV2  => 1,        # Worker sends to 'file:/path', $a
   SENDTO_STDOUT  => 2,        # Worker sends to STDOUT
   SENDTO_STDERR  => 3,        # Worker sends to STDERR
   SENDTO_FD      => 4,        # Worker sends to file descriptor

   WANTS_UNDEF    => 0,        # Callee wants nothing
   WANTS_ARRAY    => 1,        # Callee wants list
   WANTS_SCALAR   => 2,        # Callee wants scalar
};

my $_mce_count = 0;

sub CLONE {
   $_tid = threads->tid() if $INC{'threads.pm'};
}

sub DESTROY {
   CORE::kill('KILL', $$)
      if ( $_is_MSWin32 && $MCE::Signal::KILLED );

   $_[0]->shutdown(1)
      if ( $_[0] && $_[0]->{_spawned} && $_[0]->{_init_pid} eq "$$.$_tid" &&
           !$MCE::Signal::KILLED );

   return;
}

END {
   return unless ( defined $MCE );

   my $_pid = $MCE->{_is_thread} ? $$ .'.'. threads->tid() : $$;
   $MCE->exit if ( exists $MCE->{_wuf} && $MCE->{_pid} eq $_pid );

   _end();
}

sub _end {
   MCE::Flow->finish   ( 'MCE' ) if $INC{'MCE/Flow.pm'};
   MCE::Grep->finish   ( 'MCE' ) if $INC{'MCE/Grep.pm'};
   MCE::Loop->finish   ( 'MCE' ) if $INC{'MCE/Loop.pm'};
   MCE::Map->finish    ( 'MCE' ) if $INC{'MCE/Map.pm'};
   MCE::Step->finish   ( 'MCE' ) if $INC{'MCE/Step.pm'};
   MCE::Stream->finish ( 'MCE' ) if $INC{'MCE/Stream.pm'};

   $MCE = $TOP_HDLR = undef;
}

###############################################################################
## ----------------------------------------------------------------------------
## Plugin interface for external modules plugging into MCE, e.g. MCE::Queue.
##
###############################################################################

my (%_plugin_function, @_plugin_loop_begin, @_plugin_loop_end);
my (%_plugin_list, @_plugin_worker_init);

sub _attach_plugin {
   my $_ext_module = caller;

   unless (exists $_plugin_list{$_ext_module}) {
      $_plugin_list{$_ext_module} = undef;

      my $_ext_output_function    = $_[0];
      my $_ext_output_loop_begin  = $_[1];
      my $_ext_output_loop_end    = $_[2];
      my $_ext_worker_init        = $_[3];

      if (ref $_ext_output_function eq 'HASH') {
         for my $_p (keys %{ $_ext_output_function }) {
            $_plugin_function{$_p} = $_ext_output_function->{$_p}
               unless (exists $_plugin_function{$_p});
         }
      }

      push @_plugin_loop_begin, $_ext_output_loop_begin
         if (ref $_ext_output_loop_begin eq 'CODE');
      push @_plugin_loop_end, $_ext_output_loop_end
         if (ref $_ext_output_loop_end eq 'CODE');
      push @_plugin_worker_init, $_ext_worker_init
         if (ref $_ext_worker_init eq 'CODE');
   }

   @_ = ();

   return;
}

## Functions for saving and restoring $MCE.
## Called by MCE::{ Flow, Grep, Loop, Map, Step, and Stream }.

sub _save_state {
   $_prev_mce = $MCE; $MCE = $_[0];
   return;
}
sub _restore_state {
   $_prev_mce->{_wrk_status} = $MCE->{_wrk_status};
   $MCE = $_prev_mce; $_prev_mce = undef;
   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## New instance instantiation.
##
###############################################################################

sub _croak {
   if (MCE->wid == 0 || ! $^S) {
      $SIG{__DIE__}  = \&MCE::Signal::_die_handler;
      $SIG{__WARN__} = \&MCE::Signal::_warn_handler;
   }
   $\ = undef; goto &Carp::croak;
}

use MCE::Core::Validation ();
use MCE::Core::Manager ();
use MCE::Core::Worker ();

sub new {
   my ($class, %self) = @_;
   my $_pkg = exists $self{pkg} ? delete $self{pkg} : caller;

   @_ = ();

   bless(\%self, ref($class) || $class);

   $self{task_name}   ||= 'MCE';
   $self{max_workers} ||= $_def->{$_pkg}{MAX_WORKERS} || 1;
   $self{chunk_size}  ||= $_def->{$_pkg}{CHUNK_SIZE}  || 1;
   $self{tmp_dir}     ||= $_def->{$_pkg}{TMP_DIR}     || $MCE::Signal::tmp_dir;
   $self{freeze}      ||= $_def->{$_pkg}{FREEZE}      || $_freeze;
   $self{thaw}        ||= $_def->{$_pkg}{THAW}        || $_thaw;

   if (exists $self{_module_instance}) {
      $self{_init_total_workers} = $self{max_workers};
      $self{_chunk_id} = $self{_task_wid} = $self{_wrk_status} = 0;
      $self{_spawned}  = $self{_task_id}  = $self{_wid} = 0;
      $self{_init_pid} = "$$.$_tid";

      return \%self;
   }

   _sendto_fhs_close();

   for my $_p (keys %self) {
      _croak("MCE::new: ($_p) is not a valid constructor argument")
         unless (exists $_valid_fields_new{$_p});
   }

   $self{_caller} = $_pkg, $self{_init_pid} = "$$.$_tid";

   if (defined $self{use_threads}) {
      if (!$_has_threads && $self{use_threads}) {
         my $_msg  = "\n";
            $_msg .= "## Please include threads support prior to loading MCE\n";
            $_msg .= "## when specifying use_threads => $self{use_threads}\n";
            $_msg .= "\n";

         _croak($_msg);
      }
   }
   else {
      $self{use_threads} = ($_has_threads) ? 1 : 0;
   }

   if (!exists $self{posix_exit}) {
      $self{posix_exit} = 1 if (
         $^S || $_tid || $INC{'Mojo/IOLoop.pm'} ||
         $INC{'Coro.pm'} || $INC{'LWP/UserAgent.pm'} || $INC{'stfl.pm'} ||
         $INC{'Curses.pm'} || $INC{'CGI.pm'} || $INC{'FCGI.pm'} ||
         $INC{'Tk.pm'} || $INC{'Wx.pm'} || $INC{'Win32/GUI.pm'} ||
         $INC{'Gearman/Util.pm'} || $INC{'Gearman/XS.pm'}
      );
   }

   ## -------------------------------------------------------------------------
   ## Validation.

   if (defined $self{tmp_dir}) {
      _croak("MCE::new: ($self{tmp_dir}) is not a directory or does not exist")
         unless (-d $self{tmp_dir});
      _croak("MCE::new: ($self{tmp_dir}) is not writeable")
         unless (-w $self{tmp_dir});
   }

   if (defined $self{user_tasks}) {
      _croak('MCE::new: (user_tasks) is not an ARRAY reference')
         unless (ref $self{user_tasks} eq 'ARRAY');

      $self{max_workers} = _parse_max_workers($self{max_workers});
      $self{init_relay}  = $self{user_tasks}->[0]->{init_relay}
         if ($self{user_tasks}->[0]->{init_relay});

      for my $_task (@{ $self{user_tasks} }) {
         for my $_p (keys %{ $_task }) {
            _croak("MCE::new: ($_p) is not a valid task constructor argument")
               unless (exists $_valid_fields_task{$_p});
         }
         $_task->{max_workers} = 0 unless scalar(keys %{ $_task });

         $_task->{max_workers} = $self{max_workers}
            unless (defined $_task->{max_workers});
         $_task->{use_threads} = $self{use_threads}
            unless (defined $_task->{use_threads});

         bless($_task, ref(\%self) || \%self);
      }
   }

   _validate_args(\%self);

   ## -------------------------------------------------------------------------
   ## Private options. Limit chunk_size.

   my $_run_lock;

   $self{_chunk_id}   = 0;  # Chunk ID
   $self{_send_cnt}   = 0;  # Number of times data was sent via send
   $self{_spawned}    = 0;  # Have workers been spawned
   $self{_task_id}    = 0;  # Task ID, starts at 0 (array index)
   $self{_task_wid}   = 0;  # Task Worker ID, starts at 1 per task
   $self{_wid}        = 0;  # Worker ID, starts at 1 per MCE instance
   $self{_wrk_status} = 0;  # For saving exit status when worker exits

   $self{_run_lock}   = threads::shared::share($_run_lock) if $_is_MSWin32;

   $self{_last_sref}  = (ref $self{input_data} eq 'SCALAR')
      ? refaddr($self{input_data}) : 0;

   my $_data_channels = ("$$.$_tid" eq $_oid)
      ? ( $INC{'MCE/Channel.pm'} ? 6 : DATA_CHANNELS )
      : 2;

   my $_total_workers = 0;

   if (defined $self{user_tasks}) {
      $_total_workers += $_->{max_workers} for @{ $self{user_tasks} };
   } else {
      $_total_workers = $self{max_workers};
   }

   $self{_init_total_workers} = $_total_workers;

   $self{_data_channels} = ($_total_workers < $_data_channels)
      ? $_total_workers : $_data_channels;

   $self{_lock_chn} = ($_total_workers > $_data_channels) ? 1 : 0;
   $self{_lock_chn} = 1 if $INC{'MCE/Child.pm'} || $INC{'MCE/Hobo.pm'};

   $MCE = \%self if ($MCE->{_wid} == 0);

   return \%self;
}

###############################################################################
## ----------------------------------------------------------------------------
## Spawn method.
##
###############################################################################

sub spawn {
   my $self = shift; $self = $MCE unless ref($self);

   local $_; @_ = ();

   _croak('MCE::spawn: method is not allowed by the worker process')
      if ($self->{_wid});

   ## Return if workers have already been spawned or if module instance.
   return $self if ($self->{_spawned} || exists $self->{_module_instance});

   lock $_WIN_LOCK if $_is_MSWin32;    # Obtain locks
   lock $_MCE_LOCK if $_has_threads && $_is_winenv;

   $MCE::_GMUTEX->lock() if ($_tid && $MCE::_GMUTEX);
   sleep 0.015 if $_tid;

   _sendto_fhs_close();

   if ($INC{'PDL.pm'}) { local $@;
      # PDL::IO::Storable is required for serializing piddles.
      eval 'use PDL::IO::Storable' unless $INC{'PDL/IO/Storable.pm'};
      # PDL data should not be naively copied in new threads.
      eval 'no warnings; sub PDL::CLONE_SKIP { 1 }';
      # Disable PDL auto-threading.
      eval q{ PDL::set_autopthread_targ(1) };
   }
   if ( $INC{'LWP/UserAgent.pm'} && !$INC{'Net/HTTP.pm'} ) {
      local $@; eval 'require Net::HTTP; require Net::HTTPS';
   }

   ## Start the shared-manager process if not running.
   MCE::Shared->start() if $INC{'MCE/Shared.pm'};

   ## Load input module.
   if (defined $self->{sequence}) {
      require MCE::Core::Input::Sequence
         unless $INC{'MCE/Core/Input/Sequence.pm'};
   }
   elsif (defined $self->{input_data}) {
      my $_ref = ref $self->{input_data};
      if ($_ref =~ /^(?:ARRAY|HASH|GLOB|FileHandle|IO::)/) {
         require MCE::Core::Input::Request
            unless $INC{'MCE/Core/Input/Request.pm'};
      }
      elsif ($_ref eq 'CODE') {
         require MCE::Core::Input::Iterator
            unless $INC{'MCE/Core/Input/Iterator.pm'};
      }
      else {
         require MCE::Core::Input::Handle
            unless $INC{'MCE/Core/Input/Handle.pm'};
      }
   }

   my $_die_handler  = $SIG{__DIE__};
   my $_warn_handler = $SIG{__WARN__};

   $SIG{__DIE__}  = \&MCE::Signal::_die_handler;
   $SIG{__WARN__} = \&MCE::Signal::_warn_handler;

   if (!defined $TOP_HDLR || (!$TOP_HDLR->{_mgr_live} && !$TOP_HDLR->{_wid})) {
      ## On Windows, must shutdown the last idle MCE session.
      if ($_is_MSWin32 && defined $TOP_HDLR && $TOP_HDLR->{_spawned}) {
         $TOP_HDLR->shutdown(1);
      }
      $TOP_HDLR = $self;
   }
   elsif (refaddr($self) != refaddr($TOP_HDLR)) {
      ## Reduce the maximum number of channels for nested sessions.
      $self->{_data_channels} = 4 if ($self->{_data_channels} > 4);
      $self->{_lock_chn} = 1 if ($self->{_init_total_workers} > 4);

      ## On Windows, instruct the manager process to enable win32 IPC.
      if ($_is_MSWin32 && $ENV{'PERL_MCE_IPC'} ne 'win32') {
         $ENV{'PERL_MCE_IPC'} = 'win32'; local $\ = undef;
         my $_DAT_W_SOCK = $TOP_HDLR->{_dat_w_sock}->[0];
         print {$_DAT_W_SOCK} OUTPUT_S_IPC.$LF . '0'.$LF;

         MCE::Util::_sock_ready($_DAT_W_SOCK, -1);
         MCE::Util::_sysread($_DAT_W_SOCK, my($_buf), 1);
      }
   }

   ## -------------------------------------------------------------------------

   my $_data_channels = $self->{_data_channels};
   my $_max_workers   = _get_max_workers($self);
   my $_use_threads   = $self->{use_threads};

   ## Create locks for data channels.
   $self->{'_mutex_0'} = MCE::Mutex->new( impl => 'Channel' );

   if ($self->{_lock_chn}) {
      $self->{'_mutex_'.$_} = MCE::Mutex->new( impl => 'Channel' )
         for (1 .. $_data_channels);
   }

   ## Create sockets for IPC.                             sync, comm, data
   MCE::Util::_sock_pair($self, qw(_bsb_r_sock _bsb_w_sock), undef, 1);
   MCE::Util::_sock_pair($self, qw(_com_r_sock _com_w_sock), undef, 1);

   MCE::Util::_sock_pair($self, qw(_dat_r_sock _dat_w_sock), 0);
   MCE::Util::_sock_pair($self, qw(_dat_r_sock _dat_w_sock), $_, 1)
      for (1 .. $_data_channels);

   setsockopt($self->{_dat_r_sock}->[0], SOL_SOCKET, SO_RCVBUF, pack('i', 4096))
      if ($^O ne 'aix' && $^O ne 'linux');

   ($_is_MSWin32)                                                   # input
      ? MCE::Util::_pipe_pair($self, qw(_que_r_sock _que_w_sock))
      : MCE::Util::_sock_pair($self, qw(_que_r_sock _que_w_sock), undef, 1);

   if (defined $self->{init_relay}) {                               # relay
      unless ($INC{'MCE/Relay.pm'}) {
         require MCE::Relay; MCE::Relay->import();
      }
      MCE::Util::_sock_pair($self, qw(_rla_r_sock _rla_w_sock), $_, 1)
         for (0 .. $_max_workers - 1);
   }

   $self->{_seed} = int(rand() * 1e9);

   ## -------------------------------------------------------------------------

   ## Spawn workers.
   $self->{_pids}   = [], $self->{_thrs}  = [], $self->{_tids} = [];
   $self->{_status} = [], $self->{_state} = [], $self->{_task} = [];

   if ($self->{loop_timeout} && !$_is_MSWin32) {
      $self->{_pids_t} = {}, $self->{_pids_w} = {};
   }

   local $SIG{TTIN}, local $SIG{TTOU}, local $SIG{WINCH} unless $_is_MSWin32;

   if (!defined $self->{user_tasks}) {
      $self->{_total_workers} = $_max_workers;

      if (defined $_use_threads && $_use_threads == 1) {
         _dispatch_thread($self, $_) for (1 .. $_max_workers);
      } else {
         _dispatch_child($self, $_) for (1 .. $_max_workers);
      }

      $self->{_task}->[0] = { _total_workers => $_max_workers };

      for my $_i (1 .. $_max_workers) {
         $self->{_state}->[$_i] = {
            _task => undef, _task_id => undef, _task_wid => undef,
            _params => undef, _chn => $_i % $_data_channels + 1
         }
      }
   }
   else {
      my ($_task_id, $_wid);

      $self->{_total_workers}  = 0;
      $self->{_total_workers} += $_->{max_workers} for @{ $self->{user_tasks} };

      # Must spawn processes first for extra stability on BSD/Darwin.
      $_task_id = $_wid = 0;

      for my $_task (@{ $self->{user_tasks} }) {
         my $_tsk_use_threads = $_task->{use_threads};

         if (defined $_tsk_use_threads && $_tsk_use_threads == 1) {
            $_wid += $_task->{max_workers};
         } else {
            _dispatch_child($self, ++$_wid, $_task, $_task_id, $_)
               for (1 .. $_task->{max_workers});
         }

         $_task_id++;
      }

      # Then, spawn threads last.
      $_task_id = $_wid = 0;

      for my $_task (@{ $self->{user_tasks} }) {
         my $_tsk_use_threads = $_task->{use_threads};

         if (defined $_tsk_use_threads && $_tsk_use_threads == 1) {
            _dispatch_thread($self, ++$_wid, $_task, $_task_id, $_)
               for (1 .. $_task->{max_workers});
         } else {
            $_wid += $_task->{max_workers};
         }

         $_task_id++;
      }

      # Save state.
      $_task_id = $_wid = 0;

      for my $_task (@{ $self->{user_tasks} }) {
         $self->{_task}->[$_task_id] = {
            _total_running => 0, _total_workers => $_task->{max_workers}
         };
         for my $_i (1 .. $_task->{max_workers}) {
            $_wid += 1;
            $self->{_state}->[$_wid] = {
               _task => $_task, _task_id => $_task_id, _task_wid => $_i,
               _params => undef, _chn => $_wid % $_data_channels + 1
            }
         }

         $_task_id++;
      }
   }

   ## -------------------------------------------------------------------------

   $self->{_send_cnt} = 0, $self->{_spawned} = 1;

   $SIG{__DIE__}  = $_die_handler;
   $SIG{__WARN__} = $_warn_handler;

   $MCE = $self if ($MCE->{_wid} == 0);

   $MCE::_GMUTEX->unlock() if ($_tid && $MCE::_GMUTEX);

   return $self;
}

###############################################################################
## ----------------------------------------------------------------------------
## Process method, relay stubs, and AUTOLOAD for methods not used often.
##
###############################################################################

sub process {
   my $self = shift; $self = $MCE unless ref($self);

   _validate_runstate($self, 'MCE::process');

   my ($_params_ref, $_input_data);

   if (ref $_[0] eq 'HASH' && ref $_[1] eq 'HASH') {
      $_params_ref = $_[0], $_input_data = $_[1];
   } elsif (ref $_[0] eq 'HASH') {
      $_params_ref = $_[0], $_input_data = $_[1];
   } else {
      $_params_ref = $_[1], $_input_data = $_[0];
   }

   @_ = ();

   ## Set input data.
   if (defined $_input_data) {
      $_params_ref->{input_data} = $_input_data;
   }
   elsif ( !defined $_params_ref->{input_data} &&
           !defined $_params_ref->{sequence} ) {
      _croak('MCE::process: (input_data or sequence) is not specified');
   }

   ## Pass 0 to "not" auto-shutdown after processing.
   $self->run(0, $_params_ref);

   return $self;
}

sub relay (;&) {
   _croak('MCE::relay: (init_relay) is not specified')
      unless (defined $MCE->{init_relay});
}

{
   no warnings 'once';
   *relay_unlock = \&relay;
}

sub AUTOLOAD {
   # $AUTOLOAD = MCE::<method_name>

   my $_fcn = substr($MCE::AUTOLOAD, 5);
   my $self = shift; $self = $MCE unless ref($self);

   # "for" sugar methods

   if ($_fcn eq 'forchunk') {
      require MCE::Candy unless $INC{'MCE/Candy.pm'};
      return  MCE::Candy::forchunk($self, @_);
   }
   elsif ($_fcn eq 'foreach') {
      require MCE::Candy unless $INC{'MCE/Candy.pm'};
      return  MCE::Candy::foreach($self, @_);
   }
   elsif ($_fcn eq 'forseq') {
      require MCE::Candy unless $INC{'MCE/Candy.pm'};
      return  MCE::Candy::forseq($self, @_);
   }

   # relay stubs for MCE::Relay

   if ($_fcn eq 'relay_lock' || $_fcn eq 'relay_recv') {
      _croak('MCE::relay: (init_relay) is not specified')
         unless (defined $MCE->{init_relay});
   }
   elsif ($_fcn eq 'relay_final') {
      return;
   }

   # worker immediately exits the chunking loop

   if ($_fcn eq 'last') {
      _croak('MCE::last: method is not allowed by the manager process')
         unless ($self->{_wid});

      $self->{_last_jmp}() if (defined $self->{_last_jmp});

      return;
   }

   # worker starts the next iteration of the chunking loop

   elsif ($_fcn eq 'next') {
      _croak('MCE::next: method is not allowed by the manager process')
         unless ($self->{_wid});

      $self->{_next_jmp}() if (defined $self->{_next_jmp});

      return;
   }

   # return the process ID, include thread ID for threads

   elsif ($_fcn eq 'pid') {
      if (defined $self->{_pid}) {
         return $self->{_pid};
      } elsif ($_has_threads && $self->{use_threads}) {
         return $$ .'.'. threads->tid();
      }
      return $$;
   }

   # return the exit status
   # _wrk_status holds the greatest exit status among workers exiting

   elsif ($_fcn eq 'status') {
      _croak('MCE::status: method is not allowed by the worker process')
         if ($self->{_wid});

      return (defined $self->{_wrk_status}) ? $self->{_wrk_status} : 0;
   }

   _croak("Can't locate object method \"$_fcn\" via package \"MCE\"");
}

###############################################################################
## ----------------------------------------------------------------------------
## Restart worker method.
##
###############################################################################

sub restart_worker {
   my $self = shift; $self = $MCE unless ref($self);

   @_ = ();

   _croak('MCE::restart_worker: method is not allowed by the worker process')
      if ($self->{_wid});

   my $_wid = $self->{_exited_wid};

   my $_params   = $self->{_state}->[$_wid]->{_params};
   my $_task_wid = $self->{_state}->[$_wid]->{_task_wid};
   my $_task_id  = $self->{_state}->[$_wid]->{_task_id};
   my $_task     = $self->{_state}->[$_wid]->{_task};
   my $_chn      = $self->{_state}->[$_wid]->{_chn};

   $_params->{_chn} = $_chn;

   my $_use_threads = (defined $_task_id)
      ? $_task->{use_threads} : $self->{use_threads};

   $self->{_task}->[$_task_id]->{_total_running} += 1 if (defined $_task_id);
   $self->{_task}->[$_task_id]->{_total_workers} += 1 if (defined $_task_id);

   $self->{_total_running} += 1;
   $self->{_total_workers} += 1;

   if (defined $_use_threads && $_use_threads == 1) {
      _dispatch_thread($self, $_wid, $_task, $_task_id, $_task_wid, $_params);
   } else {
      _dispatch_child($self, $_wid, $_task, $_task_id, $_task_wid, $_params);
   }

   delete $self->{_retry_cnt};

   if (defined $self->{spawn_delay} && $self->{spawn_delay} > 0.0) {
      sleep $self->{spawn_delay};
   } elsif ($_tid || $_is_MSWin32) {
      sleep 0.045;
   }

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Run method.
##
###############################################################################

sub run {
   my $self = shift; $self = $MCE unless ref($self);

   _croak('MCE::run: method is not allowed by the worker process')
      if ($self->{_wid});

   my ($_auto_shutdown, $_params_ref);

   if (ref $_[0] eq 'HASH') {
      $_auto_shutdown = (defined $_[1]) ? $_[1] : 1;
      $_params_ref    = $_[0];
   } else {
      $_auto_shutdown = (defined $_[0]) ? $_[0] : 1;
      $_params_ref    = $_[1];
   }

   @_ = ();

   my $_has_user_tasks = (defined $self->{user_tasks}) ? 1 : 0;
   my $_requires_shutdown = 0;

   ## Unset params if workers have already been sent user_data via send.
   ## Set user_func to NOOP if not specified.

   $_params_ref = undef if ($self->{_send_cnt});

   if (!defined $self->{user_func} && !defined $_params_ref->{user_func}) {
      $self->{user_func} = \&MCE::Signal::_NOOP;
   }

   ## Set user specified params if specified.
   ## Shutdown workers if determined by _sync_params or if processing a
   ## scalar reference. Workers need to be restarted in order to pick up
   ## on the new code or scalar reference.

   if (defined $_params_ref && ref $_params_ref eq 'HASH') {
      $_requires_shutdown = _sync_params($self, $_params_ref);
      _validate_args($self);
   }
   if ($_has_user_tasks) {
      $self->{input_data} = $self->{user_tasks}->[0]->{input_data}
         if ($self->{user_tasks}->[0]->{input_data});
      $self->{use_slurpio} = $self->{user_tasks}->[0]->{use_slurpio}
         if ($self->{user_tasks}->[0]->{use_slurpio});
      $self->{parallel_io} = $self->{user_tasks}->[0]->{parallel_io}
         if ($self->{user_tasks}->[0]->{parallel_io});
      $self->{RS} = $self->{user_tasks}->[0]->{RS}
         if ($self->{user_tasks}->[0]->{RS});
   }
   if (ref $self->{input_data} eq 'SCALAR') {
      if (refaddr($self->{input_data}) != $self->{_last_sref}) {
         $_requires_shutdown = 1;
      }
      $self->{_last_sref} = refaddr($self->{input_data});
   }

   $self->shutdown() if ($_requires_shutdown);

   ## -------------------------------------------------------------------------

   $self->{_wrk_status} = 0;

   ## Spawn workers.
   $self->spawn() unless ($self->{_spawned});
   return $self   unless ($self->{_total_workers});

   local $SIG{__DIE__}  = \&MCE::Signal::_die_handler;
   local $SIG{__WARN__} = \&MCE::Signal::_warn_handler;

   $MCE = $self if ($MCE->{_wid} == 0);

   my ($_input_data, $_input_file, $_input_glob, $_seq);
   my ($_abort_msg, $_first_msg, $_run_mode, $_single_dim);
   my $_chunk_size = $self->{chunk_size};

   $_seq = ($_has_user_tasks && $self->{user_tasks}->[0]->{sequence})
      ? $self->{user_tasks}->[0]->{sequence}
      : $self->{sequence};

   ## Determine run mode for workers.
   if (defined $_seq) {
      my ($_begin, $_end, $_step) = (ref $_seq eq 'ARRAY')
         ? @{ $_seq } : ($_seq->{begin}, $_seq->{end}, $_seq->{step});

      $_chunk_size = $self->{user_tasks}->[0]->{chunk_size}
         if ($_has_user_tasks && $self->{user_tasks}->[0]->{chunk_size});

      $_run_mode  = 'sequence';
      $_abort_msg = int(($_end - $_begin) / $_step / $_chunk_size); # + 1;

      # Previously + 1 above. Below, support for large numbers, 1e16 and beyond.
      # E.g. sequence => [ 1, 1e16 ], chunk_size => 1e11
      #
      # Perl: int((1e15 - 1) / 1 / 1e11) =   9999
      # Perl: int((1e16 - 1) / 1 / 1e11) = 100000 wrong, due to precision limit
      # Calc: int((1e16 - 1) / 1 / 1e11) =  99999

      if ( $_step > 0 ) {
         $_abort_msg++
            if ($_abort_msg * $_chunk_size * abs($_step) + $_begin <= $_end);
      } else {
         $_abort_msg++
            if ($_abort_msg * $_chunk_size * abs($_step) + $_end <= $_begin);
      }

      $_first_msg = 0;
   }
   elsif (defined $self->{input_data}) {
      my $_ref = ref $self->{input_data};

      if ($_ref eq '') {                              # File mode
         $_run_mode   = 'file';
         $_input_file = $self->{input_data};
         $_input_data = $_input_glob = undef;
         $_abort_msg  = (-s $_input_file) + 1;
         $_first_msg  = 0; ## Begin at offset position

         if ((-s $_input_file) == 0) {
            $self->shutdown() if ($_auto_shutdown == 1);
            return $self;
         }
      }
      elsif ($_ref eq 'ARRAY') {                      # Array mode
         $_run_mode   = 'array';
         $_input_data = $self->{input_data};
         $_input_file = $_input_glob = undef;
         $_single_dim = 1 if (ref $_input_data->[0] eq '');
         $_abort_msg  = 0; ## Flag: Has Data: No
         $_first_msg  = 1; ## Flag: Has Data: Yes

         if (@{ $_input_data } == 0) {
            $self->shutdown() if ($_auto_shutdown == 1);
            return $self;
         }
      }
      elsif ($_ref eq 'HASH') {                       # Hash mode
         $_run_mode   = 'hash';
         $_input_data = $self->{input_data};
         $_input_file = $_input_glob = undef;
         $_abort_msg  = 0; ## Flag: Has Data: No
         $_first_msg  = 1; ## Flag: Has Data: Yes

         if (scalar( keys %{ $_input_data } ) == 0) {
            $self->shutdown() if ($_auto_shutdown == 1);
            return $self;
         }
      }
      elsif ($_ref =~ /^(?:GLOB|FileHandle|IO::)/) {  # Glob mode
         $_run_mode   = 'glob';
         $_input_glob = $self->{input_data};
         $_input_data = $_input_file = undef;
         $_abort_msg  = 0; ## Flag: Has Data: No
         $_first_msg  = 1; ## Flag: Has Data: Yes
      }
      elsif ($_ref eq 'CODE') {                       # Iterator mode
         $_run_mode   = 'iterator';
         $_input_data = $self->{input_data};
         $_input_file = $_input_glob = undef;
         $_abort_msg  = 0; ## Flag: Has Data: No
         $_first_msg  = 1; ## Flag: Has Data: Yes
      }
      elsif ($_ref eq 'SCALAR') {                     # Memory mode
         $_run_mode   = 'memory';
         $_input_data = $_input_file = $_input_glob = undef;
         $_abort_msg  = length(${ $self->{input_data} }) + 1;
         $_first_msg  = 0; ## Begin at offset position

         if (length(${ $self->{input_data} }) == 0) {
            return $self->shutdown() if ($_auto_shutdown == 1);
         }
      }
      else {
         _croak('MCE::run: (input_data) is not valid');
      }
   }
   else {                                             # Nodata mode
      $_abort_msg = undef, $_run_mode = 'nodata';
   }

   ## -------------------------------------------------------------------------

   my $_total_workers = $self->{_total_workers};
   my $_send_cnt      = $self->{_send_cnt};

   if ($_send_cnt) {
      $self->{_total_running} = $_send_cnt;
      $self->{_task}->[0]->{_total_running} = $_send_cnt;
   }
   else {
      $self->{_total_running} = $_total_workers;

      my ($_frozen_nodata, $_wid, %_params_nodata, %_task0_wids);
      my  $_COM_R_SOCK   = $self->{_com_r_sock};
      my  $_submit_delay = $self->{submit_delay};

      my %_params = (
         '_abort_msg'   => $_abort_msg,  '_chunk_size' => $_chunk_size,
         '_input_file'  => $_input_file, '_run_mode'   => $_run_mode,
         '_bounds_only' => $self->{bounds_only},
         '_max_retries' => $self->{max_retries},
         '_parallel_io' => $self->{parallel_io},
         '_progress'    => $self->{progress} ? 1 : 0,
         '_sequence'    => $self->{sequence},
         '_user_args'   => $self->{user_args},
         '_use_slurpio' => $self->{use_slurpio},
         '_RS'          => $self->{RS}
      );

      my $_frozen_params = $self->{freeze}(\%_params);
         $_frozen_params = length($_frozen_params).$LF . $_frozen_params;

      if ($_has_user_tasks) {
         %_params_nodata = ( %_params,
            '_abort_msg' => undef, '_run_mode' => 'nodata'
         );
         $_frozen_nodata = $self->{freeze}(\%_params_nodata);
         $_frozen_nodata = length($_frozen_nodata).$LF . $_frozen_nodata;

         for my $_t (@{ $self->{_task} }) {
            $_t->{_total_running} = $_t->{_total_workers};
         }
         for my $_i (1 .. @{ $self->{_state} } - 1) {
            $_task0_wids{$_i} = undef unless ($self->{_state}[$_i]{_task_id});
         }
      }

      local $\ = undef; local $/ = $LF;

      ## Insert the first message into the queue if defined.
      if (defined $_first_msg) {
         syswrite($self->{_que_w_sock}, pack($_que_template, 0, $_first_msg));
      }

      ## Submit params data to workers.
      for my $_i (1 .. $_total_workers) {
         print({$_COM_R_SOCK} $_i.$LF), chomp($_wid = <$_COM_R_SOCK>);

         if (!$_has_user_tasks || exists $_task0_wids{$_wid}) {
            print({$_COM_R_SOCK} $_frozen_params), <$_COM_R_SOCK>;
            $self->{_state}[$_wid]{_params} = \%_params;
         } else {
            print({$_COM_R_SOCK} $_frozen_nodata), <$_COM_R_SOCK>;
            $self->{_state}[$_wid]{_params} = \%_params_nodata;
         }

         sleep $_submit_delay
            if defined($_submit_delay) && $_submit_delay > 0.0;
      }
   }

   ## -------------------------------------------------------------------------

   $self->{_total_exited} = 0;

   ## Call the output function.
   if ($self->{_total_running} > 0) {
      $self->{_mgr_live}   = 1;
      $self->{_abort_msg}  = $_abort_msg;
      $self->{_single_dim} = $_single_dim;

      lock $self->{_run_lock} if $_is_MSWin32;

      if (!$_send_cnt) {
         ## Notify workers to commence processing.
         if ($_is_MSWin32) {
            my $_buf = _sprintf("%${_total_workers}s", "");
            syswrite($self->{_bsb_r_sock}, $_buf);
         } else {
            my $_BSB_R_SOCK = $self->{_bsb_r_sock};
            for my $_i (1 .. $_total_workers) {
               syswrite($_BSB_R_SOCK, $LF);
            }
         }
      }

      _output_loop( $self, $_input_data, $_input_glob,
         \%_plugin_function, \@_plugin_loop_begin, \@_plugin_loop_end
      );

      $self->{_mgr_live} = $self->{_abort_msg} = $self->{_single_dim} = undef;
   }

   ## Remove the last message from the queue.
   if (!$_send_cnt && $_run_mode ne 'nodata') {
      MCE::Util::_sysread($self->{_que_r_sock}, my($_buf), $_que_read_size)
         if ( defined $self->{_que_r_sock} );
   }

   $self->{_send_cnt} = 0;

   ## Shutdown workers.
   if ($_auto_shutdown || $self->{_total_exited}) {
      $self->shutdown();
   }
   elsif ($^S || $ENV{'PERL_IPERL_RUNNING'}) {
      if (
         !$INC{'Mojo/IOLoop.pm'} && !$INC{'Win32/GUI.pm'} &&
         !$INC{'Gearman/XS.pm'} && !$INC{'Gearman/Util.pm'} &&
         !$INC{'Tk.pm'} && !$INC{'Wx.pm'}
      ) {
         # running inside eval or IPerl, check stack trace
         my $_t = Carp::longmess(); $_t =~ s/\teval [^\n]+\n$//;

         if ( $_t =~ /^(?:[^\n]+\n){1,7}\teval / ||
              $_t =~ /\n\teval [^\n]+\n\t(?:eval|Try)/ ||
              $_t =~ /\n\tMCE::_dispatch\(\) [^\n]+ thread \d+\n$/ ||
              ( $_tid && !$self->{use_threads} ) )
         {
            $self->shutdown();
         }
      }
   }

   return $self;
}

###############################################################################
## ----------------------------------------------------------------------------
## Send method.
##
###############################################################################

sub send {
   my $self = shift; $self = $MCE unless ref($self);

   _croak('MCE::send: method is not allowed by the worker process')
      if ($self->{_wid});
   _croak('MCE::send: method is not allowed while running')
      if ($self->{_total_running});

   _croak('MCE::send: method cannot be used with input_data or sequence')
      if (defined $self->{input_data} || defined $self->{sequence});
   _croak('MCE::send: method cannot be used with user_tasks')
      if (defined $self->{user_tasks});

   my $_data_ref;

   if (ref $_[0] eq 'ARRAY' || ref $_[0] eq 'HASH' || ref $_[0] eq 'PDL') {
      $_data_ref = $_[0];
   } else {
      _croak('MCE::send: ARRAY, HASH, or a PDL reference is not specified');
   }

   @_ = ();

   $self->{_send_cnt} = 0 unless (defined $self->{_send_cnt});

   ## -------------------------------------------------------------------------

   ## Spawn workers.
   $self->spawn() unless ($self->{_spawned});

   _croak('MCE::send: Sending greater than # of workers is not allowed')
      if ($self->{_send_cnt} >= $self->{_task}->[0]->{_total_workers});

   local $SIG{__DIE__}  = \&MCE::Signal::_die_handler;
   local $SIG{__WARN__} = \&MCE::Signal::_warn_handler;

   ## Begin data submission.
   local $\ = undef; local $/ = $LF;

   my $_COM_R_SOCK   = $self->{_com_r_sock};
   my $_submit_delay = $self->{submit_delay};
   my $_frozen_data  = $self->{freeze}($_data_ref);
   my $_len          = length $_frozen_data;

   ## Submit data to worker.
   print({$_COM_R_SOCK} '_data'.$LF), <$_COM_R_SOCK>;
   print({$_COM_R_SOCK} $_len.$LF, $_frozen_data), <$_COM_R_SOCK>;

   $self->{_send_cnt} += 1;

   sleep $_submit_delay
      if defined($_submit_delay) && $_submit_delay > 0.0;

   return $self;
}

###############################################################################
## ----------------------------------------------------------------------------
## Shutdown method.
##
###############################################################################

sub shutdown {
   my $self = shift; $self = $MCE unless ref($self);
   my $_no_lock = shift || 0;

   @_ = ();

   ## Return unless spawned or already shutdown.
   return unless $self->{_spawned};

   ## Return if signaled.
   if ($MCE::Signal::KILLED) {
      if (defined $self->{_sess_dir}) {
         my $_sess_dir = delete $self->{_sess_dir};
         rmdir $_sess_dir if -d $_sess_dir;
      }
      return;
   }

   _validate_runstate($self, 'MCE::shutdown');

   ## Complete processing before shutting down.
   $self->run(0) if ($self->{_send_cnt});

   local $SIG{__DIE__}  = \&MCE::Signal::_die_handler;
   local $SIG{__WARN__} = \&MCE::Signal::_warn_handler;

   my $_COM_R_SOCK     = $self->{_com_r_sock};
   my $_data_channels  = $self->{_data_channels};
   my $_total_workers  = $self->{_total_workers};
   my $_sess_dir       = $self->{_sess_dir};

   if (defined $TOP_HDLR && refaddr($self) == refaddr($TOP_HDLR)) {
      $TOP_HDLR = undef;
   }

   ## -------------------------------------------------------------------------

   lock $_MCE_LOCK if ($_has_threads && $_is_winenv && !$_no_lock);

   ## Notify workers to exit loop.
   local ($!, $?, $_); local $\ = undef; local $/ = $LF;

   for (1 .. $_total_workers) {
      print({$_COM_R_SOCK} '_exit'.$LF), <$_COM_R_SOCK>;
   }

   ## Reap children and/or threads.
   if (@{ $self->{_pids} } > 0) {
      my $_list = $self->{_pids};
      for my $i (0 .. @{ $_list }) {
         waitpid($_list->[$i], 0) if $_list->[$i];
      }
   }
   if (@{ $self->{_thrs} } > 0) {
      my $_list = $self->{_thrs};
      for my $i (0 .. @{ $_list }) {
         $_list->[$i]->join() if $_list->[$i];
      }
   }

   ## Close sockets.
   $_COM_R_SOCK = undef;

   MCE::Util::_destroy_socks($self, qw(
      _bsb_w_sock _bsb_r_sock _com_w_sock _com_r_sock
      _dat_w_sock _dat_r_sock _rla_w_sock _rla_r_sock
   ));

   ($_is_MSWin32)
      ? MCE::Util::_destroy_pipes($self, qw( _que_w_sock _que_r_sock ))
      : MCE::Util::_destroy_socks($self, qw( _que_w_sock _que_r_sock ));

   ## -------------------------------------------------------------------------

   ## Destroy mutexes.
   for my $_i (0 .. $_data_channels) { delete $self->{'_mutex_'.$_i}; }

   ## Remove session directory.
   rmdir $_sess_dir if (defined $_sess_dir && -d $_sess_dir);

   ## Reset instance.
   undef @{$self->{_pids}};  undef @{$self->{_thrs}};   undef @{$self->{_tids}};
   undef @{$self->{_state}}; undef @{$self->{_status}}; undef @{$self->{_task}};

   $self->{_chunk_id} = $self->{_send_cnt} = $self->{_spawned} = 0;
   $self->{_total_running} = $self->{_total_exited} = 0;
   $self->{_total_workers} = 0;
   $self->{_sess_dir} = undef;

   if ($self->{loop_timeout}) {
      delete $self->{_pids_t};
      delete $self->{_pids_w};
   }

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Barrier sync and yield methods.
##
###############################################################################

sub sync {
   my $self = shift; $self = $MCE unless ref($self);

   return unless ($self->{_wid});

   ## Barrier synchronization is supported for task 0 at this time.
   ## Note: Workers are assigned task_id 0 when omitting user_tasks.

   return if ($self->{_task_id} > 0);

   my $_chn        = $self->{_chn};
   my $_DAT_W_SOCK = $self->{_dat_w_sock}->[0];
   my $_BSB_R_SOCK = $self->{_bsb_r_sock};
   my $_BSB_W_SOCK = $self->{_bsb_w_sock};
   my $_buf;

   local $\ = undef if (defined $\);

   ## Notify the manager process (barrier begin).
   print {$_DAT_W_SOCK} OUTPUT_B_SYN.$LF . $_chn.$LF;

   ## Wait until all workers from (task_id 0) have synced.
   MCE::Util::_sock_ready($_BSB_R_SOCK, -1) if $_is_MSWin32;
   MCE::Util::_sysread($_BSB_R_SOCK, $_buf, 1);

   ## Notify the manager process (barrier end).
   print {$_DAT_W_SOCK} OUTPUT_E_SYN.$LF . $_chn.$LF;

   ## Wait until all workers from (task_id 0) have un-synced.
   MCE::Util::_sock_ready($_BSB_W_SOCK, -1) if $_is_MSWin32;
   MCE::Util::_sysread($_BSB_W_SOCK, $_buf, 1);

   return;
}

sub yield {
   my $self = shift; $self = $MCE unless ref($self);

   return unless ($self->{_wid});

   my $_chn        = $self->{_chn};
   my $_DAT_LOCK   = $self->{_dat_lock};
   my $_DAT_W_SOCK = $self->{_dat_w_sock}->[0];
   my $_DAU_W_SOCK = $self->{_dat_w_sock}->[$_chn];
   my $_lock_chn   = $self->{_lock_chn};
   my $_delay;

   local $\ = undef if (defined $\);
   local $/ = $LF if (!$/ || $/ ne $LF);

   $_DAT_LOCK->lock() if $_lock_chn;
   print({$_DAT_W_SOCK} OUTPUT_I_DLY.$LF . $_chn.$LF),
   print({$_DAU_W_SOCK} $self->{_task_id}.$LF);
   chomp($_delay = <$_DAU_W_SOCK>);
   $_DAT_LOCK->unlock() if $_lock_chn;

   MCE::Util::_sleep( $_delay );
}

###############################################################################
## ----------------------------------------------------------------------------
## Miscellaneous methods: abort exit sess_dir tmp_dir.
##
###############################################################################

## Abort current job.

sub abort {
   my $self = shift; $self = $MCE unless ref($self);

   my $_QUE_R_SOCK = $self->{_que_r_sock};
   my $_QUE_W_SOCK = $self->{_que_w_sock};
   my $_abort_msg  = $self->{_abort_msg};

   if (defined $_abort_msg) {
      local $\ = undef;

      if ($_abort_msg > 0) {
         MCE::Util::_sysread($_QUE_R_SOCK, my($_next), $_que_read_size);
         syswrite($_QUE_W_SOCK, pack($_que_template, 0, $_abort_msg));
      }

      if ($self->{_wid} > 0) {
         my $_chn        = $self->{_chn};
         my $_DAT_LOCK   = $self->{_dat_lock};
         my $_DAT_W_SOCK = $self->{_dat_w_sock}->[0];
         my $_DAU_W_SOCK = $self->{_dat_w_sock}->[$_chn];
         my $_lock_chn   = $self->{_lock_chn};

         $_DAT_LOCK->lock() if $_lock_chn;
         print {$_DAT_W_SOCK} OUTPUT_W_ABT.$LF . $_chn.$LF;
         $_DAT_LOCK->unlock() if $_lock_chn;
      }
   }

   return;
}

## Worker exits from MCE.

sub exit {
   my $self = shift; $self = $MCE unless ref($self);

   my $_exit_status = (defined $_[0]) ? $_[0] : $?;
   my $_exit_msg    = (defined $_[1]) ? $_[1] : '';
   my $_exit_id     = (defined $_[2]) ? $_[2] : $self->chunk_id;

   @_ = ();

   _croak('MCE::exit: method is not allowed by the manager process')
      unless ($self->{_wid});

   my $_chn        = $self->{_chn};
   my $_DAT_LOCK   = $self->{_dat_lock};
   my $_DAT_W_SOCK = $self->{_dat_w_sock}->[0];
   my $_DAU_W_SOCK = $self->{_dat_w_sock}->[$_chn];
   my $_lock_chn   = $self->{_lock_chn};
   my $_task_id    = $self->{_task_id};

   unless ( $self->{_exiting} ) {
      $self->{_exiting} = 1;

      my $_pid = $self->{_is_thread} ? $$ .'.'. threads->tid() : $$;
      my $_max_retries = $self->{max_retries};
      my $_chunk_id = $self->{_chunk_id};

      if ( defined $self->{init_relay} && !$self->{_relayed} && !$_task_id &&
           exists $self->{_wuf} && $self->{_pid} eq $_pid ) {

         $self->{_retry_cnt} = -1 unless defined( $self->{_retry_cnt} );

         if ( !$_max_retries || ++$self->{_retry_cnt} == $_max_retries ) {
            MCE::relay { warn "Error: chunk $_chunk_id failed\n" if $_chunk_id };
         }
      }

      ## Check for nested workers not yet joined.
      MCE::Child->finish('MCE') if $INC{'MCE/Child.pm'};

      MCE::Hobo->finish('MCE')
         if ( $INC{'MCE/Hobo.pm'} && MCE::Hobo->can('_clear') );

      local $\ = undef if (defined $\);
      my $_len = length $_exit_msg;

      $_exit_id =~ s/[\r\n][\r\n]*/ /mg;
      $_DAT_LOCK->lock() if $_lock_chn;

      if ($self->{_retry} && $self->{_retry}->[2]--) {
         $_exit_status = 0; my $_buf = $self->{freeze}($self->{_retry});
         print({$_DAT_W_SOCK} OUTPUT_W_EXT.$LF . $_chn.$LF),
         print({$_DAU_W_SOCK}
            $_task_id.$LF . $self->{_wid}.$LF . $self->{_exit_pid}.$LF .
            $_exit_status.$LF . $_exit_id.$LF . $_len.$LF . $_exit_msg .
            length($_buf).$LF, $_buf
         );
      }
      else {
         print({$_DAT_W_SOCK} OUTPUT_W_EXT.$LF . $_chn.$LF),
         print({$_DAU_W_SOCK}
            $_task_id.$LF . $self->{_wid}.$LF . $self->{_exit_pid}.$LF .
            $_exit_status.$LF . $_exit_id.$LF . $_len.$LF . $_exit_msg .
            '0'.$LF
         );
      }

      $_DAT_LOCK->unlock() if $_lock_chn;
   }

   _exit($self);
}

## Return the session dir, made on demand.

sub sess_dir {
   my $self = shift; $self = $MCE unless ref($self);
   return $self->{_sess_dir} if defined $self->{_sess_dir};

   if ($self->{_wid} == 0) {
      $self->{_sess_dir} = $self->{_spawned}
         ? _make_sessdir($self) : undef;
   }
   else {
      my $_chn        = $self->{_chn};
      my $_DAT_LOCK   = $self->{_dat_lock};
      my $_DAT_W_SOCK = $self->{_dat_w_sock}->[0];
      my $_DAU_W_SOCK = $self->{_dat_w_sock}->[$_chn];
      my $_lock_chn   = $self->{_lock_chn};
      my $_sess_dir;

      local $\ = undef if (defined $\);
      local $/ = $LF if (!$/ || $/ ne $LF);

      $_DAT_LOCK->lock() if $_lock_chn;
      print({$_DAT_W_SOCK} OUTPUT_S_DIR.$LF . $_chn.$LF);
      chomp($_sess_dir = <$_DAU_W_SOCK>);
      $_DAT_LOCK->unlock() if $_lock_chn;

      $self->{_sess_dir} = $_sess_dir;
   }
}

## Return the temp dir, made on demand.

sub tmp_dir {
   my $self = shift; $self = $MCE unless ref($self);
   return $self->{tmp_dir} if defined $self->{tmp_dir};

   if ($self->{_wid} == 0) {
      $self->{tmp_dir} = MCE::Signal::_make_tmpdir();
   }
   else {
      my $_chn        = $self->{_chn};
      my $_DAT_LOCK   = $self->{_dat_lock};
      my $_DAT_W_SOCK = $self->{_dat_w_sock}->[0];
      my $_DAU_W_SOCK = $self->{_dat_w_sock}->[$_chn];
      my $_lock_chn   = $self->{_lock_chn};
      my $_tmp_dir;

      local $\ = undef if (defined $\);
      local $/ = $LF if (!$/ || $/ ne $LF);

      $_DAT_LOCK->lock() if $_lock_chn;
      print({$_DAT_W_SOCK} OUTPUT_T_DIR.$LF . $_chn.$LF);
      chomp($_tmp_dir = <$_DAU_W_SOCK>);
      $_DAT_LOCK->unlock() if $_lock_chn;

      $self->{tmp_dir} = $_tmp_dir;
   }
}

###############################################################################
## ----------------------------------------------------------------------------
## Methods for serializing data from workers to the main process.
##
###############################################################################

## Do method. Additional arguments are optional.

sub do {
   my $self = shift; $self = $MCE unless ref($self);
   my $_pkg = caller() eq 'MCE' ? caller(1) : caller();

   _croak('MCE::do: (code ref) is not supported')
      if (ref $_[0] eq 'CODE');
   _croak('MCE::do: (callback) is not specified')
      unless (defined ( my $_func = shift ));

   $_func = $_pkg.'::'.$_func if (index($_func, ':') < 0);

   if ($self->{_wid}) {
      return _do_callback($self, $_func, [ @_ ]);
   }
   else {
      no strict 'refs';
      return $_func->(@_);
   }
}

## Gather method.

sub gather {
   my $self = shift; $self = $MCE unless ref($self);

   _croak('MCE::gather: method is not allowed by the manager process')
      unless ($self->{_wid});

   return _do_gather($self, [ @_ ]);
}

## Sendto method.

{
   my %_sendto_lkup = (
      'file'  => SENDTO_FILEV1, 'stderr' => SENDTO_STDERR,
      'file:' => SENDTO_FILEV2, 'stdout' => SENDTO_STDOUT,
      'fd:'   => SENDTO_FD,
   );

   my $_v2_regx = qr/^([^:]+:)(.+)/;

   sub sendto {

      my $self = shift; $self = $MCE unless ref($self);
      my $_to  = shift;

      _croak('MCE::sendto: method is not allowed by the manager process')
         unless ($self->{_wid});

      return unless (defined $_[0]);

      my $_dest = exists $_sendto_lkup{ lc($_to) }
                       ? $_sendto_lkup{ lc($_to) } : undef;
      my $_value;

      if (!defined $_dest) {
         my $_fd;

         if (ref($_to) && ( defined ($_fd = fileno($_to)) ||
                            defined ($_fd = eval { $_to->fileno }) )) {

            if (my $_ob = tied *{ $_to }) {
               if (ref $_ob eq 'IO::TieCombine::Handle') {
                  $_fd = 1 if (lc($_ob->{slot_name}) eq 'stdout');
                  $_fd = 2 if (lc($_ob->{slot_name}) eq 'stderr');
               }
            }

            my $_data_ref = (scalar @_ == 1) ? \(''.$_[0]) : \join('', @_);
            return _do_send_glob($self, $_to, $_fd, $_data_ref);
         }
         elsif (reftype($_to) eq 'GLOB') {
            return _croak('Cannot write to filehandle');
         }

         if (defined $_to && $_to =~ /$_v2_regx/o) {
            $_dest  = exists $_sendto_lkup{ lc($1) }
                           ? $_sendto_lkup{ lc($1) } : undef;
            $_value = $2;
         }

         if (!defined $_dest || ( !defined $_value && (
               $_dest == SENDTO_FILEV2 || $_dest == SENDTO_FD
         ))) {
            my $_msg  = "\n";
               $_msg .= "MCE::sendto: improper use of method\n";
               $_msg .= "\n";
               $_msg .= "## usage:\n";
               $_msg .= "##    ->sendto(\"stderr\", ...);\n";
               $_msg .= "##    ->sendto(\"stdout\", ...);\n";
               $_msg .= "##    ->sendto(\"file:/path/to/file\", ...);\n";
               $_msg .= "##    ->sendto(\"fd:2\", ...);\n";
               $_msg .= "\n";

            _croak($_msg);
         }
      }

      if ($_dest == SENDTO_FILEV1) {            # sendto 'file', $a, $path
         return if (!defined $_[1] || @_ > 2);  # Please switch to using V2
         $_value = $_[1]; delete $_[1];         # sendto 'file:/path', $a
         $_dest  = SENDTO_FILEV2;
      }

      return _do_send($self, $_dest, $_value, @_);
   }
}

###############################################################################
## ----------------------------------------------------------------------------
## Functions for serializing print, printf and say statements.
##
###############################################################################

sub print {
   my $self = shift; $self = $MCE unless ref($self);
   my ($_fd, $_glob, $_data);

   if (ref($_[0]) && ( defined ($_fd = fileno($_[0])) ||
                       defined ($_fd = eval { $_[0]->fileno }) )) {

      if (my $_ob = tied *{ $_[0] }) {
         if (ref $_ob eq 'IO::TieCombine::Handle') {
            $_fd = 1 if (lc($_ob->{slot_name}) eq 'stdout');
            $_fd = 2 if (lc($_ob->{slot_name}) eq 'stderr');
         }
      }

      $_glob = shift;
   }
   elsif (reftype($_[0]) eq 'GLOB') {
      return _croak('Cannot write to filehandle');
   }

   $_data = join('', scalar @_ ? @_ : $_);

   return _do_send_glob($self, $_glob, $_fd, \$_data) if $_fd;
   return _do_send($self, SENDTO_STDOUT, undef, \$_data) if $self->{_wid};
   return _do_send_glob($self, \*STDOUT, 1, \$_data);
}

sub printf {
   my $self = shift; $self = $MCE unless ref($self);
   my ($_fd, $_glob, $_fmt, $_data);

   if (ref($_[0]) && ( defined ($_fd = fileno($_[0])) ||
                       defined ($_fd = eval { $_[0]->fileno }) )) {

      if (my $_ob = tied *{ $_[0] }) {
         if (ref $_ob eq 'IO::TieCombine::Handle') {
            $_fd = 1 if (lc($_ob->{slot_name}) eq 'stdout');
            $_fd = 2 if (lc($_ob->{slot_name}) eq 'stderr');
         }
      }

      $_glob = shift;
   }
   elsif (reftype($_[0]) eq 'GLOB') {
      return _croak('Cannot write to filehandle');
   }

   $_fmt  = shift || '%s';
   $_data = sprintf($_fmt, scalar @_ ? @_ : $_);

   return _do_send_glob($self, $_glob, $_fd, \$_data) if $_fd;
   return _do_send($self, SENDTO_STDOUT, undef, \$_data) if $self->{_wid};
   return _do_send_glob($self, \*STDOUT, 1, \$_data);
}

sub say {
   my $self = shift; $self = $MCE unless ref($self);
   my ($_fd, $_glob, $_data);

   if (ref($_[0]) && ( defined ($_fd = fileno($_[0])) ||
                       defined ($_fd = eval { $_[0]->fileno }) )) {

      if (my $_ob = tied *{ $_[0] }) {
         if (ref $_ob eq 'IO::TieCombine::Handle') {
            $_fd = 1 if (lc($_ob->{slot_name}) eq 'stdout');
            $_fd = 2 if (lc($_ob->{slot_name}) eq 'stderr');
         }
      }

      $_glob = shift;
   }
   elsif (reftype($_[0]) eq 'GLOB') {
      return _croak('Cannot write to filehandle');
   }

   $_data = join('', scalar @_ ? @_ : $_) . "\n";

   return _do_send_glob($self, $_glob, $_fd, \$_data) if $_fd;
   return _do_send($self, SENDTO_STDOUT, undef, \$_data) if $self->{_wid};
   return _do_send_glob($self, \*STDOUT, 1, \$_data);
}

###############################################################################
## ----------------------------------------------------------------------------
## Private methods.
##
###############################################################################

sub _exit {
   my $self = shift;

   delete $self->{_wuf}; _end();

   ## Exit thread/child process.
   $SIG{__DIE__}  = sub {} unless $_tid;
   $SIG{__WARN__} = sub {};

   threads->exit(0) if $self->{use_threads};

   if (! $_tid) {
      $SIG{HUP} = $SIG{INT} = $SIG{QUIT} = $SIG{TERM} = sub {
         $SIG{$_[0]} = $SIG{INT} = $SIG{TERM} = sub {};

         CORE::kill($_[0], getppid())
            if (($_[0] eq 'INT' || $_[0] eq 'TERM') && $^O ne 'MSWin32');

         CORE::kill('KILL', $$);
      };
   }

   if ($self->{posix_exit} && !$_is_MSWin32) {
      eval { MCE::Mutex::Channel::_destroy() };
      POSIX::_exit(0) if $INC{'POSIX.pm'};
      CORE::kill('KILL', $$);
   }

   CORE::exit(0);
}

sub _get_max_workers {
   my $self = shift; $self = $MCE unless ref($self);

   if (defined $self->{user_tasks}) {
      if (defined $self->{user_tasks}->[0]->{max_workers}) {
         return $self->{user_tasks}->[0]->{max_workers};
      }
   }

   return $self->{max_workers};
}

sub _make_sessdir {
   my $self = shift; $self = $MCE unless ref($self);

   my $_sess_dir = $self->{_sess_dir};

   unless (defined $_sess_dir) {
      $self->{tmp_dir} = MCE::Signal::_make_tmpdir()
         unless defined $self->{tmp_dir};

      my $_mce_tid = $INC{'threads.pm'} ? threads->tid() : '';
         $_mce_tid = '' unless defined $self->{_mce_tid};

      my $_mce_sid = $$ .'.'. $_mce_tid .'.'. (++$_mce_count);
      my $_tmp_dir = $self->{tmp_dir};

      _croak("MCE::sess_dir: (tmp_dir) is not defined")
         if (!defined $_tmp_dir || $_tmp_dir eq '');
      _croak("MCE::sess_dir: ($_tmp_dir) is not a directory or does not exist")
         unless (-d $_tmp_dir);
      _croak("MCE::sess_dir: ($_tmp_dir) is not writeable")
         unless (-w $_tmp_dir);

      my $_cnt = 0; $_sess_dir = "$_tmp_dir/$_mce_sid";

      $_sess_dir = "$_tmp_dir/$_mce_sid." . (++$_cnt)
         while ( !(mkdir $_sess_dir, 0770) );
   }

   return $_sess_dir;
}

sub _sprintf {
   my ($_fmt, $_arg) = @_;
   # remove tainted'ness
   ($_fmt) = $_fmt =~ /(.*)/;

   return sprintf("$_fmt", $_arg);
}

sub _sync_buffer_to_array {
   my ($_buffer_ref, $_array_ref, $_chop_str) = @_;

   local $_; my $_cnt = 0;

   open my $_MEM_FH, '<', $_buffer_ref;
   binmode $_MEM_FH, ':raw';

   unless (length $_chop_str) {
      $_array_ref->[$_cnt++] = $_ while (<$_MEM_FH>);
   }
   else {
      $_array_ref->[$_cnt++] = <$_MEM_FH>;
      while (<$_MEM_FH>) {
         $_array_ref->[$_cnt  ]  = $_chop_str;
         $_array_ref->[$_cnt++] .= $_;
      }
   }

   close  $_MEM_FH;
   weaken $_MEM_FH;

   return;
}

sub _sync_params {
   my ($self, $_params_ref) = @_;
   my $_requires_shutdown = 0;

   if (defined $_params_ref->{init_relay} && !defined $self->{init_relay}) {
      $_requires_shutdown = 1;
   }
   for my $_p (qw( user_begin user_func user_end )) {
      if (defined $_params_ref->{$_p}) {
         $self->{$_p} = delete $_params_ref->{$_p};
         $_requires_shutdown = 1;
      }
   }
   for my $_p (keys %{ $_params_ref }) {
      _croak("MCE::_sync_params: ($_p) is not a valid params argument")
         unless (exists $_params_allowed_args{$_p});

      $self->{$_p} = $_params_ref->{$_p};
   }

   return ($self->{_spawned}) ? $_requires_shutdown : 0;
}

###############################################################################
## ----------------------------------------------------------------------------
## Dispatch methods.
##
###############################################################################

sub _dispatch {
   my @_args = @_; my $_is_thread = shift @_args;
   my $self = $MCE = $_args[0];

   ## To avoid (Scalars leaked: N) messages; fixed in Perl 5.12.x
   @_ = ();

   $ENV{'PERL_MCE_IPC'} = 'win32' if ( $_is_MSWin32 && (
      defined($self->{max_retries}) ||
      $INC{'MCE/Child.pm'} ||
      $INC{'MCE/Hobo.pm'}
   ));

   delete $self->{_relayed};

   $self->{_is_thread} = $_is_thread;
   $self->{_pid}       = $_is_thread ? $$ .'.'. threads->tid() : $$;

   ## Sets the seed of the base generator uniquely between workers.
   ## The new seed is computed using the current seed and $_wid value.
   ## One may set the seed at the application level for predictable
   ## results (non-thread workers only). Ditto for Math::Prime::Util,
   ## Math::Random, and Math::Random::MT::Auto.

   {
      my ($_wid, $_seed) = ($_args[1], $self->{_seed});
      srand(abs($_seed - ($_wid * 100000)) % 2147483560);

      if (!$self->{use_threads}) {
         Math::Prime::Util::srand(abs($_seed - ($_wid * 100000)) % 2147483560)
            if ( $INC{'Math/Prime/Util.pm'} );

         MCE::Hobo->_clear()
            if ( $INC{'MCE/Hobo.pm'} && MCE::Hobo->can('_clear') );

         MCE::Child->_clear() if $INC{'MCE/Child.pm'};
      }
   }

   if (!$self->{use_threads} && $INC{'Math/Random.pm'}) {
      my ($_wid, $_cur_seed) = ($_args[1], Math::Random::random_get_seed());

      my $_new_seed = ($_cur_seed < 1073741781)
         ? $_cur_seed + (($_wid * 100000) % 1073741780)
         : $_cur_seed - (($_wid * 100000) % 1073741780);

      Math::Random::random_set_seed($_new_seed, $_new_seed);
   }

   if (!$self->{use_threads} && $INC{'Math/Random/MT/Auto.pm'}) {
      my ($_wid, $_cur_seed) = (
         $_args[1], Math::Random::MT::Auto::get_seed()->[0]
      );
      my $_new_seed = ($_cur_seed < 1073741781)
         ? $_cur_seed + (($_wid * 100000) % 1073741780)
         : $_cur_seed - (($_wid * 100000) % 1073741780);

      Math::Random::MT::Auto::set_seed($_new_seed);
   }

   ## Run.

   _worker_main(@_args, \@_plugin_worker_init);

   _exit($self);
}

sub _dispatch_thread {
   my ($self, $_wid, $_task, $_task_id, $_task_wid, $_params) = @_;

   @_ = (); local $_;

   my $_thr = threads->create( \&_dispatch,
      1, $self, $_wid, $_task, $_task_id, $_task_wid, $_params
   );

   _croak("MCE::_dispatch_thread: Failed to spawn worker $_wid: $!")
      if (!defined $_thr);

   ## Store into an available slot (restart), otherwise append to arrays.
   if (defined $_params) { for my $_i (0 .. @{ $self->{_tids} } - 1) {
      unless (defined $self->{_tids}->[$_i]) {
         $self->{_thrs}->[$_i] = $_thr;
         $self->{_tids}->[$_i] = $_thr->tid();
         return;
      }
   }}

   push @{ $self->{_thrs} }, $_thr;
   push @{ $self->{_tids} }, $_thr->tid();

   sleep $self->{spawn_delay}
      if defined($self->{spawn_delay}) && $self->{spawn_delay} > 0.0;

   return;
}

sub _dispatch_child {
   my ($self, $_wid, $_task, $_task_id, $_task_wid, $_params) = @_;

   @_ = (); local $_;
   my $_pid = fork();

   _croak("MCE::_dispatch_child: Failed to spawn worker $_wid: $!")
      if (!defined $_pid);

   _dispatch(0, $self, $_wid, $_task, $_task_id, $_task_wid, $_params)
      if ($_pid == 0);

   ## Store into an available slot (restart), otherwise append to array.
   if (defined $_params) { for my $_i (0 .. @{ $self->{_pids} } - 1) {
      unless (defined $self->{_pids}->[$_i]) {
         $self->{_pids}->[$_i] = $_pid;
         return;
      }
   }}

   push @{ $self->{_pids} }, $_pid;

   if ($self->{loop_timeout} && !$_is_MSWin32) {
      $self->{_pids_t}{$_pid} = $_task_id;
      $self->{_pids_w}{$_pid} = $_wid;
   }

   sleep $self->{spawn_delay}
      if defined($self->{spawn_delay}) && $self->{spawn_delay} > 0.0;

   return;
}

1;

