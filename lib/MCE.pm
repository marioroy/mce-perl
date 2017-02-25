###############################################################################
## ----------------------------------------------------------------------------
## MCE - Many-Core Engine for Perl providing parallel processing capabilities.
##
###############################################################################

package MCE;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized );

our $VERSION = '1.816';

## no critic (BuiltinFunctions::ProhibitStringyEval)
## no critic (Subroutines::ProhibitSubroutinePrototypes)
## no critic (TestingAndDebugging::ProhibitNoStrict)

use Carp ();

my ($_has_threads, $_freeze, $_thaw, $_tid, $_oid);

BEGIN {
   local $@; local $SIG{__DIE__};

   if ($^O eq 'MSWin32' && !$INC{'threads.pm'}) {
      eval 'use threads; use threads::shared';
   }
   elsif ($INC{'threads.pm'} && !$INC{'threads/shared.pm'}) {
      eval 'use threads::shared';
   }

   $_has_threads = $INC{'threads.pm'} ? 1 : 0;
   $_tid = $_has_threads ? threads->tid() : 0;
   $_oid = "$$.$_tid";

   eval 'PDL::no_clone_skip_warning()' if $INC{'PDL.pm'};
   eval 'use PDL::IO::Storable'        if $INC{'PDL.pm'};

   if (!exists $INC{'PDL.pm'}) {
      eval '
         use Sereal::Encoder 3.015 qw( encode_sereal );
         use Sereal::Decoder 3.015 qw( decode_sereal );
      ';
      if ( !$@ ) {
         my $_encoder_ver = int( Sereal::Encoder->VERSION() );
         my $_decoder_ver = int( Sereal::Decoder->VERSION() );
         if ( $_encoder_ver - $_decoder_ver == 0 ) {
            $_freeze = sub { encode_sereal( @_, { freeze_callbacks => 1 } ) };
            $_thaw   = \&decode_sereal;
         }
      }
   }

   if (!defined $_freeze) {
      require Storable;
      $_freeze = \&Storable::freeze;
      $_thaw   = \&Storable::thaw;
   }

   return;
}

use Scalar::Util qw( looks_like_number refaddr weaken );
use Time::HiRes qw( sleep time );

use Symbol qw( qualify_to_ref );
use Socket qw( SOL_SOCKET SO_RCVBUF );

use MCE::Util qw( $LF );
use MCE::Signal;
use MCE::Mutex;
use bytes;

our ($MCE, $RLA, $_que_template, $_que_read_size);
our (%_valid_fields_new);

my  ($TOP_HDLR, $_is_MSWin32, $_is_winenv, $_prev_mce);
my  (%_valid_fields_task, %_params_allowed_args);

BEGIN {
   ## Configure pack/unpack template for writing to and from the queue.
   ## Each entry contains 2 positive numbers: chunk_id & msg_id.
   ## Attempt 64-bit size, otherwize fall back to machine's word length.
   {
      local $@; eval { $_que_read_size = length pack('Q2', 0, 0); };
      $_que_template  = ($@) ? 'I2' : 'Q2';
      $_que_read_size = length pack($_que_template, 0, 0);
   }

   ## Attributes used internally.
   ## _abort_msg _caller _chn _com_lock _dat_lock _mgr_live _rla_data _seed
   ## _chunk_id _mce_sid _mce_tid _pids _run_mode _single_dim _thrs _tids _wid
   ## _exiting _exit_pid _total_exited _total_running _total_workers _task_wid
   ## _send_cnt _sess_dir _spawned _state _status _task _task_id _wrk_status
   ## _init_pid _init_total_workers _last_sref _wuf
   ##
   ## _bsb_r_sock _bsb_w_sock _bse_r_sock _bse_w_sock _com_r_sock _com_w_sock
   ## _dat_r_sock _dat_w_sock _que_r_sock _que_w_sock _rla_r_sock _rla_w_sock
   ## _data_channels _lock_chn _mutex_n

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

   for my $_p (qw(
      chunk_size max_retries max_workers task_name tmp_dir user_args
   )) {
      *{ $_p } = sub () {
         my $self = shift; $self = $MCE unless ref($self);
         return $self->{$_p};
      };
   }
   for my $_p (qw( chunk_id sess_dir task_id task_wid wid )) {
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

   ## Preload essential modules.
   require MCE::Core::Validation;
   require MCE::Core::Manager;
   require MCE::Core::Worker;

   no strict 'refs'; no warnings 'redefine';
   *{ 'MCE::_parse_max_workers' } = \&MCE::Util::_parse_max_workers;

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

   MAX_CHUNK_SIZE => 1024 * 1024 * 64,  # Maximum chunk size allowed

   # Max data channels. This cannot be greater than 8 on MSWin32.
   DATA_CHANNELS  => ($^O eq 'MSWin32') ? 8 : 12,

   MAX_RECS_SIZE  => 8192,     # Reads number of records if N <= value
                               # Reads number of bytes if N > value

   OUTPUT_W_ABT   => 'W~ABT',  # Worker has aborted
   OUTPUT_W_DNE   => 'W~DNE',  # Worker has completed
   OUTPUT_W_RLA   => 'W~RLA',  # Worker has relayed
   OUTPUT_W_EXT   => 'W~EXT',  # Worker has exited
   OUTPUT_A_ARY   => 'A~ARY',  # Array  << Array
   OUTPUT_S_GLB   => 'S~GLB',  # Scalar << Glob FH
   OUTPUT_U_ITR   => 'U~ITR',  # User   << Iterator
   OUTPUT_A_CBK   => 'A~CBK',  # Callback w/ multiple args
   OUTPUT_S_CBK   => 'S~CBK',  # Callback w/ 1 scalar arg
   OUTPUT_N_CBK   => 'N~CBK',  # Callback w/ no args
   OUTPUT_A_GTR   => 'A~GTR',  # Gather array/ref
   OUTPUT_S_GTR   => 'S~GTR',  # Gather scalar
   OUTPUT_O_SND   => 'O~SND',  # Send >> STDOUT
   OUTPUT_E_SND   => 'E~SND',  # Send >> STDERR
   OUTPUT_F_SND   => 'F~SND',  # Send >> File
   OUTPUT_D_SND   => 'D~SND',  # Send >> File descriptor
   OUTPUT_B_SYN   => 'B~SYN',  # Barrier sync - begin
   OUTPUT_E_SYN   => 'E~SYN',  # Barrier sync - end
   OUTPUT_S_IPC   => 'S~IPC',  # Change to win32 IPC
   OUTPUT_P_NFY   => 'P~NFY',  # Progress notification
   OUTPUT_I_DLY   => 'I~DLY',  # Interval delay

   READ_FILE      => 0,        # Worker reads file handle
   READ_MEMORY    => 1,        # Worker reads memory handle

   REQUEST_ARRAY  => 0,        # Worker requests next array chunk
   REQUEST_GLOB   => 1,        # Worker requests next glob chunk

   SENDTO_FILEV1  => 0,        # Worker sends to 'file', $a, '/path'
   SENDTO_FILEV2  => 1,        # Worker sends to 'file:/path', $a
   SENDTO_STDOUT  => 2,        # Worker sends to STDOUT
   SENDTO_STDERR  => 3,        # Worker sends to STDERR
   SENDTO_FD      => 4,        # Worker sends to file descriptor

   WANTS_UNDEF    => 0,        # Callee wants nothing
   WANTS_ARRAY    => 1,        # Callee wants list
   WANTS_SCALAR   => 2,        # Callee wants scalar
   WANTS_REF      => 3         # Callee wants H/A/S ref
};

my $_mce_count = 0;

sub CLONE {
   $_tid = threads->tid() if $_has_threads;
}

sub DESTROY {
   if ( $_[0] && $_[0]->{_spawned} && $_[0]->{_init_pid} eq "$$.$_tid" ) {
      $_[0]->shutdown(1);
   }
}

END {
   if ( defined $MCE ) {
      if ( !$_has_threads || (defined $TOP_HDLR && !$TOP_HDLR->{use_threads}) ) {
         MCE::Flow->finish   ( 'MCE' ) if $INC{'MCE/Flow.pm'};
         MCE::Grep->finish   ( 'MCE' ) if $INC{'MCE/Grep.pm'};
         MCE::Loop->finish   ( 'MCE' ) if $INC{'MCE/Loop.pm'};
         MCE::Map->finish    ( 'MCE' ) if $INC{'MCE/Map.pm'};
         MCE::Step->finish   ( 'MCE' ) if $INC{'MCE/Step.pm'};
         MCE::Stream->finish ( 'MCE' ) if $INC{'MCE/Stream.pm'};
      }
      $TOP_HDLR = undef if defined $TOP_HDLR;
      $MCE      = undef;
   }
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
      $_plugin_list{$_ext_module} = 1;

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

## Functions for saving and restoring $MCE. This is mainly helpful for
## modules using MCE. e.g. MCE::Map.

sub _restore_state { $MCE = $_prev_mce; $_prev_mce = undef; return; }
sub _save_state    { $_prev_mce = $MCE; return; }

###############################################################################
## ----------------------------------------------------------------------------
## New instance instantiation.
##
###############################################################################

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

   for my $_p (keys %self) {
      _croak("MCE::new: ($_p) is not a valid constructor argument")
         unless (exists $_valid_fields_new{$_p});
   }

   $self{_caller} = $_pkg, $self{_init_pid} = "$$.$_tid";

   if (defined $self{use_threads}) {
      if (!$_has_threads && $self{use_threads} ne '0') {
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
      $self{posix_exit} = 1 if ($_has_threads && $_tid);
      $self{posix_exit} = 1 if ($INC{'CGI.pm'} || $INC{'FCGI.pm'});
      $self{posix_exit} = 1 if ($INC{'Mojo/IOLoop.pm'} || $INC{'Tk.pm'});
      $self{posix_exit} = 1 if ($INC{'Gearman/XS.pm'} || $INC{'Gearman/Util.pm'});
   }

   $self{flush_file}   ||= 0;
   $self{flush_stderr} ||= 0;
   $self{flush_stdout} ||= 0;
   $self{loop_timeout} ||= 0;
   $self{max_retries}  ||= 0;
   $self{parallel_io}  ||= 0;
   $self{use_slurpio}  ||= 0;

   ## -------------------------------------------------------------------------
   ## Validation.

   _croak("MCE::new: ($self{tmp_dir}) is not a directory or does not exist")
      unless (-d $self{tmp_dir});
   _croak("MCE::new: ($self{tmp_dir}) is not writeable")
      unless (-w $self{tmp_dir});

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

   $self{chunk_size}  = MAX_CHUNK_SIZE if ($self{chunk_size} > MAX_CHUNK_SIZE);
   $self{_run_lock}   = threads::shared::share($_run_lock) if $_is_MSWin32;

   $self{_last_sref}  = (ref $self{input_data} eq 'SCALAR')
      ? refaddr($self{input_data}) : 0;

   my $_data_channels = ($_oid eq "$$.$_tid") ? DATA_CHANNELS : 4;
   my $_total_workers = 0;

   if (defined $self{user_tasks}) {
      $_total_workers += $_->{max_workers} for (@{ $self{user_tasks} });
   } else {
      $_total_workers  = $self{max_workers};
   }

   $self{_init_total_workers} = $_total_workers;

   $self{_data_channels} = ($_total_workers < $_data_channels)
      ? $_total_workers : $_data_channels;

   $self{_lock_chn} = ($_total_workers > $_data_channels) ? 1 : 0;
   $self{_lock_chn} = 1 if ($INC{'MCE/Hobo.pm'});

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

   lock $_MCE_LOCK if $_has_threads;  # Obtain locks
   lock $_WIN_LOCK if $_is_MSWin32;

   ## Start the shared-manager process if present.
   MCE::Shared->start() if $INC{'MCE/Shared.pm'};

   ## Load input module.
   if (defined $self->{sequence}) {
      require MCE::Core::Input::Sequence
         unless $INC{'MCE/Core/Input/Sequence.pm'};
   }
   elsif (defined $self->{input_data}) {
      my $_ref = ref $self->{input_data};
      if ($_ref eq 'ARRAY' || $_ref =~ /^(?:GLOB|FileHandle|IO::)/) {
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

   my $_die_handler  = $SIG{__DIE__};  $SIG{__DIE__}  = \&_die;
   my $_warn_handler = $SIG{__WARN__}; $SIG{__WARN__} = \&_warn;

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
         print  {$_DAT_W_SOCK} OUTPUT_S_IPC.$LF . '0'.$LF;
         sysread $_DAT_W_SOCK, my($_buf), 1;
      }
   }

   ## Configure tid/sid for this instance here, not in the new method above.
   ## We want the actual thread id in which spawn was called under.
   unless ($self->{_mce_sid}) {
      $self->{_mce_tid} = ($_has_threads) ? threads->tid() : '';
      $self->{_mce_tid} = '' unless (defined $self->{_mce_tid});
      $self->{_mce_sid} = $$ .'.'. $self->{_mce_tid} .'.'. (++$_mce_count);
   }

   my $_mce_sid  = $self->{_mce_sid};
   my $_sess_dir = $self->{_sess_dir};
   my $_tmp_dir  = $self->{tmp_dir};

   ## Create temp dir.
   unless ($_sess_dir) {
      _croak("MCE::spawn: ($_tmp_dir) is not defined")
         if (!defined $_tmp_dir || $_tmp_dir eq '');
      _croak("MCE::spawn: ($_tmp_dir) is not a directory or does not exist")
         unless (-d $_tmp_dir);
      _croak("MCE::spawn: ($_tmp_dir) is not writeable")
         unless (-w $_tmp_dir);

      my $_cnt = 0; $_sess_dir = $self->{_sess_dir} = "$_tmp_dir/$_mce_sid";

      $_sess_dir = $self->{_sess_dir} = "$_tmp_dir/$_mce_sid." . (++$_cnt)
         while ( !(mkdir $_sess_dir, 0770) );
   }

   ## -------------------------------------------------------------------------

   my $_data_channels = $self->{_data_channels};
   my $_max_workers   = _get_max_workers($self);
   my $_use_threads   = $self->{use_threads};

   ## Create locks for data channels.
   $self->{'_mutex_0'} = MCE::Mutex->new();

   if ($self->{_lock_chn}) {
      $self->{'_mutex_'.$_} = MCE::Mutex->new() for (1 .. $_data_channels);
   }

   ## Create sockets for IPC.
   MCE::Util::_sock_pair($self, qw(_bsb_r_sock _bsb_w_sock));       # sync
   MCE::Util::_sock_pair($self, qw(_bse_r_sock _bse_w_sock));       # sync
   MCE::Util::_sock_pair($self, qw(_com_r_sock _com_w_sock));       # core
   MCE::Util::_sock_pair($self, qw(_dat_r_sock _dat_w_sock), $_)    # core
      for (0 .. $_data_channels);

   setsockopt($self->{_dat_r_sock}->[0], SOL_SOCKET, SO_RCVBUF, pack('i', 4096))
      if ($^O ne 'aix' && $^O ne 'linux');

   ($_is_MSWin32)                                                   # input
      ? MCE::Util::_pipe_pair($self, qw(_que_r_sock _que_w_sock))
      : MCE::Util::_sock_pair($self, qw(_que_r_sock _que_w_sock));

   if (defined $self->{init_relay}) {                               # relay
      unless (defined $MCE::Relay::VERSION) {
         require MCE::Relay; MCE::Relay->import();
      }
      MCE::Util::_sock_pair($self, qw(_rla_r_sock _rla_w_sock), $_)
         for (0 .. $_max_workers - 1);
   }

   $self->{_seed} = int(rand() * 1e9);

   ## -------------------------------------------------------------------------

   ## Spawn workers.
   $self->{_pids}   = [], $self->{_thrs}  = [], $self->{_tids} = [];
   $self->{_status} = [], $self->{_state} = [], $self->{_task} = [];

   if (!defined $self->{user_tasks}) {
      $self->{_total_workers} = $_max_workers;

      if (defined $_use_threads && $_use_threads == 1) {
         _dispatch_thread($self, $_) for (1 .. $_max_workers);
      } else {
         _dispatch_child($self, $_) for (1 .. $_max_workers);
      }

      $self->{_task}->[0] = { _total_workers => $_max_workers };

      for my $_i (1 .. $_max_workers) {
         keys(%{ $self->{_state}->[$_i] }) = 5;
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
            keys(%{ $self->{_state}->[++$_wid] }) = 5;
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

   return $self;
}

###############################################################################
## ----------------------------------------------------------------------------
## "for" sugar methods, process method, and relay stubs for MCE::Relay.
##
###############################################################################

sub forchunk {
   require MCE::Candy unless (defined $MCE::Candy::VERSION);
   return  MCE::Candy::forchunk(@_);
}
sub foreach {
   require MCE::Candy unless (defined $MCE::Candy::VERSION);
   return  MCE::Candy::foreach(@_);
}
sub forseq {
   require MCE::Candy unless (defined $MCE::Candy::VERSION);
   return  MCE::Candy::forseq(@_);
}

sub process {

   my $self = shift; $self = $MCE unless ref($self);

   _validate_runstate($self, 'MCE::process');

   my ($_input_data, $_params_ref);

   if (ref $_[0] eq 'HASH') {
      $_input_data = $_[1]; $_params_ref = $_[0];
   } else {
      $_input_data = $_[0]; $_params_ref = $_[1];
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

sub relay_final {}

sub relay_recv {
   _croak('MCE::relay: (init_relay) is not specified')
      unless (defined $MCE->{init_relay});
}
sub relay (;&) {
   _croak('MCE::relay: (init_relay) is not specified')
      unless (defined $MCE->{init_relay});
}

*relay_lock   = \&relay_recv;
*relay_unlock = \&relay;

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
      $self->{user_func} = \&_NOOP;
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

   local $SIG{__DIE__}  = \&_die;
   local $SIG{__WARN__} = \&_warn;

   $MCE = $self if ($MCE->{_wid} == 0);

   my ($_input_data, $_input_file, $_input_glob, $_seq);
   my ($_abort_msg, $_first_msg, $_run_mode, $_single_dim);
   my $_chunk_size = $self->{chunk_size};

   $_seq = ($_has_user_tasks && $self->{user_tasks}->[0]->{sequence})
      ? $self->{user_tasks}->[0]->{sequence}
      : $self->{sequence};

   ## Determine run mode for workers.
   if (defined $_seq) {
      my ($_begin, $_end, $_step, $_fmt) = (ref $_seq eq 'ARRAY')
         ? @{ $_seq } : ($_seq->{begin}, $_seq->{end}, $_seq->{step});

      $_chunk_size = $self->{user_tasks}->[0]->{chunk_size}
         if ($_has_user_tasks && $self->{user_tasks}->[0]->{chunk_size});

      $_run_mode  = 'sequence';
      $_abort_msg = int(($_end - $_begin) / $_step / $_chunk_size) + 1;
      $_first_msg = 0;
   }
   elsif (defined $self->{input_data}) {
      my $_ref = ref $self->{input_data};

      if ($_ref eq 'ARRAY') {                         # Array mode
         $_run_mode   = 'array';
         $_input_data = $self->{input_data};
         $_input_file = $_input_glob = undef;
         $_single_dim = 1 if (ref $_input_data->[0] eq '');
         $_abort_msg  = 0; ## Flag: Has Data: No
         $_first_msg  = 1; ## Flag: Has Data: Yes

         if (@{ $_input_data } == 0) {
            return $self->shutdown() if ($_auto_shutdown == 1);
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
      elsif ($_ref eq '') {                           # File mode
         $_run_mode   = 'file';
         $_input_file = $self->{input_data};
         $_input_data = $_input_glob = undef;
         $_abort_msg  = (-s $_input_file) + 1;
         $_first_msg  = 0; ## Begin at offset position

         if ((-s $_input_file) == 0) {
            return $self->shutdown() if ($_auto_shutdown == 1);
         }
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
         '_single_dim'  => $_single_dim,
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
            $_task0_wids{$_i} = 1 unless ($self->{_state}[$_i]{_task_id});
         }
      }

      local $\ = undef; local $/ = $LF;

      ## Insert the first message into the queue if defined.
      if (defined $_first_msg) {
         my $_QUE_W_SOCK = $self->{_que_w_sock};
         syswrite $_QUE_W_SOCK, pack($_que_template, 0, $_first_msg);
      }

      ## Submit params data to workers.
      for my $_i (1 .. $_total_workers) {
         print {$_COM_R_SOCK} $_i.$LF;
         chomp($_wid = <$_COM_R_SOCK>);

         if (!$_has_user_tasks || exists $_task0_wids{$_wid}) {
            print {$_COM_R_SOCK} $_frozen_params;
            $self->{_state}[$_wid]{_params} = \%_params;
         } else {
            print {$_COM_R_SOCK} $_frozen_nodata;
            $self->{_state}[$_wid]{_params} = \%_params_nodata;
         }

         <$_COM_R_SOCK>;

         if (defined $_submit_delay && $_submit_delay > 0.0) {
            sleep $_submit_delay;
         }
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
            my $_buf = sprintf("%${_total_workers}s", "");
            syswrite $self->{_bse_w_sock}, $_buf;
         } else {
            my $_BSE_W_SOCK = $self->{_bse_w_sock};
            for my $_i (1 .. $_total_workers) {
               syswrite $_BSE_W_SOCK, $LF;
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
      if (defined $self->{_que_r_sock}) {
         my $_QUE_R_SOCK = $self->{_que_r_sock};
         sysread $_QUE_R_SOCK, my($_next), $_que_read_size;
      }
   }

   $self->{_send_cnt} = 0;

   ## Shutdown workers.
   if ( $_auto_shutdown || $self->{_total_exited} ) {
      $self->shutdown();
   }
   elsif ($^S || $ENV{'PERL_IPERL_RUNNING'}) {
      if (
         !$INC{'Gearman/XS.pm'} && !$INC{'Gearman/Util.pm'} &&
         !$INC{'Mojo/IOLoop.pm'} && !$INC{'Tk.pm'}
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

   local $SIG{__DIE__}  = \&_die;
   local $SIG{__WARN__} = \&_warn;

   ## Begin data submission.
   local $\ = undef; local $/ = $LF;

   my $_COM_R_SOCK   = $self->{_com_r_sock};
   my $_sess_dir     = $self->{_sess_dir};
   my $_submit_delay = $self->{submit_delay};
   my $_frozen_data  = $self->{freeze}($_data_ref);
   my $_len          = length $_frozen_data;

   ## Submit data to worker.
   print {$_COM_R_SOCK} '_data'.$LF;
   <$_COM_R_SOCK>;

   print {$_COM_R_SOCK} $_len.$LF, $_frozen_data;
   <$_COM_R_SOCK>;

   if (defined $_submit_delay && $_submit_delay > 0.0) {
      sleep $_submit_delay;
   }

   $self->{_send_cnt} += 1;

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

   ## Return if workers have not been spawned or have already been shutdown.
   return unless ($self->{_spawned});
   return unless (defined $MCE::Signal::tmp_dir);

   _validate_runstate($self, 'MCE::shutdown');

   ## Wait for workers to complete processing before shutting down.
   $self->run(0) if ($self->{_send_cnt});

   local $SIG{__DIE__}  = \&_die;
   local $SIG{__WARN__} = \&_warn;

   my $_COM_R_SOCK     = $self->{_com_r_sock};
   my $_data_channels  = $self->{_data_channels};
   my $_total_workers  = $self->{_total_workers};
   my $_sess_dir       = $self->{_sess_dir};
   my $_mce_sid        = $self->{_mce_sid};

   if (defined $TOP_HDLR && refaddr($self) == refaddr($TOP_HDLR)) {
      $TOP_HDLR = undef;
   }

   ## -------------------------------------------------------------------------

   lock $_MCE_LOCK if ($_has_threads && $_is_winenv && !$_no_lock);

   ## Notify workers to exit loop.
   local ($!, $?, $_); local $\ = undef; local $/ = $LF;

   for (1 .. $_total_workers) {
      print {$_COM_R_SOCK} '_exit'.$LF;
      <$_COM_R_SOCK>;
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
      _bsb_w_sock _bsb_r_sock _bse_w_sock _bse_r_sock
      _com_w_sock _com_r_sock _dat_w_sock _dat_r_sock
      _rla_w_sock _rla_r_sock
   ));

   ($_is_MSWin32)
      ? MCE::Util::_destroy_pipes($self, qw( _que_w_sock _que_r_sock ))
      : MCE::Util::_destroy_socks($self, qw( _que_w_sock _que_r_sock ));

   ## -------------------------------------------------------------------------

   ## Destroy locks. Remove the session directory afterwards.
   if (defined $_sess_dir) {
      $self->{_mutex_0}->DESTROY('shutdown') if (defined $self->{_mutex_0});
      if ($self->{_lock_chn}) {
         for my $_i (1 .. $_data_channels) {
            $self->{'_mutex_'.$_i}->DESTROY('shutdown')
               if (defined $self->{'_mutex_'.$_i});
         }
      }
      rmdir "$_sess_dir";
   }

   ## Reset instance.
   undef @{$self->{_pids}};  undef @{$self->{_thrs}};   undef @{$self->{_tids}};
   undef @{$self->{_state}}; undef @{$self->{_status}}; undef @{$self->{_task}};

   $self->{_mce_sid}  = $self->{_mce_tid}  = $self->{_sess_dir} = undef;
   $self->{_chunk_id} = $self->{_send_cnt} = $self->{_spawned}  = 0;

   $self->{_total_running} = $self->{_total_exited} = 0;
   $self->{_total_workers} = 0;

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
   my $_BSE_R_SOCK = $self->{_bse_r_sock};
   my $_buf;

   local $\ = undef if (defined $\);

   ## Notify the manager process (barrier begin).
   print {$_DAT_W_SOCK} OUTPUT_B_SYN.$LF . $_chn.$LF;

   ## Wait until all workers from (task_id 0) have synced.
   MCE::Util::_sock_ready($_BSB_R_SOCK) if $_is_MSWin32;
   sysread $_BSB_R_SOCK, $_buf, 1;

   ## Notify the manager process (barrier end).
   print {$_DAT_W_SOCK} OUTPUT_E_SYN.$LF . $_chn.$LF;

   ## Wait until all workers from (task_id 0) have un-synced.
   sysread $_BSE_R_SOCK, $_buf, 1;

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

   $_DAT_LOCK->lock() if $_lock_chn;
   print {$_DAT_W_SOCK} OUTPUT_I_DLY.$LF . $_chn.$LF;
   print {$_DAU_W_SOCK} $self->{_task_id}.$LF;
   chomp($_delay = <$_DAU_W_SOCK>);
   $_DAT_LOCK->unlock() if $_lock_chn;

   sleep $_delay if ($_delay > 0.0);

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Miscellaneous methods: abort exit last next pid status.
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
         sysread  $_QUE_R_SOCK, my($_next), $_que_read_size;
         syswrite $_QUE_W_SOCK, pack($_que_template, 0, $_abort_msg);
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
   my $_exit_id     = (defined $_[2]) ? $_[2] : '';

   @_ = ();

   _croak('MCE::exit: method is not allowed by the manager process')
      unless ($self->{_wid});

   my $_chn        = $self->{_chn};
   my $_DAT_LOCK   = $self->{_dat_lock};
   my $_DAT_W_SOCK = $self->{_dat_w_sock}->[0];
   my $_DAU_W_SOCK = $self->{_dat_w_sock}->[$_chn];
   my $_lock_chn   = $self->{_lock_chn};
   my $_task_id    = $self->{_task_id};
   my $_sess_dir   = $self->{_sess_dir};

   unless ($self->{_exiting}) {
      $self->{_exiting} = 1;

      local $\ = undef if (defined $\);
      my $_len = length $_exit_msg;

      $_exit_id =~ s/[\r\n][\r\n]*/ /mg;

      $_DAT_LOCK->lock() if $_lock_chn;

      print {$_DAT_W_SOCK} OUTPUT_W_EXT.$LF . $_chn.$LF;
      print {$_DAU_W_SOCK}
         $_task_id.$LF . $self->{_wid}.$LF . $self->{_exit_pid}.$LF .
         $_exit_status.$LF . $_exit_id.$LF . $_len.$LF . $_exit_msg
      ;

      if ($self->{_retry} && $self->{_retry}->[2]--) {
         my $_buf = $self->{freeze}($self->{_retry});
         print {$_DAU_W_SOCK} length($_buf).$LF, $_buf;
      }
      else {
         print {$_DAU_W_SOCK} '0'.$LF;
      }

      $_DAT_LOCK->unlock() if $_lock_chn;
   }

   _exit($self);
}

## Worker immediately exits the chunking loop.

sub last {

   my $self = shift; $self = $MCE unless ref($self);

   _croak('MCE::last: method is not allowed by the manager process')
      unless ($self->{_wid});

   $self->{_last_jmp}() if (defined $self->{_last_jmp});

   return;
}

## Worker starts the next iteration of the chunking loop.

sub next {

   my $self = shift; $self = $MCE unless ref($self);

   _croak('MCE::next: method is not allowed by the manager process')
      unless ($self->{_wid});

   $self->{_next_jmp}() if (defined $self->{_next_jmp});

   return;
}

## Return the process ID. Attach the thread ID for threads.

sub pid {

   my $self = shift; $self = $MCE unless ref($self);

   if (defined $self->{_pid}) {
      $self->{_pid};
   } elsif ($_has_threads && $self->{use_threads}) {
      $$ .'.'. threads->tid();
   } else {
      $$;
   }
}

## Return the exit status. "_wrk_status" holds the greatest exit status
## among workers exiting.

sub status {

   my $self = shift; $self = $MCE unless ref($self);

   _croak('MCE::status: method is not allowed by the worker process')
      if ($self->{_wid});

   return (defined $self->{_wrk_status}) ? $self->{_wrk_status} : 0;
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

   _croak('MCE::do: method is not allowed by the manager process')
      unless ($self->{_wid});

   if (ref $_[0] eq 'CODE') {
      _croak('MCE::do: (code ref) is not supported');
   }
   else {
      _croak('MCE::do: (callback) is not specified')
         unless (defined ( my $_func = shift ));

      $_func = $_pkg.'::'.$_func if (index($_func, ':') < 0);

      return _do_callback($self, $_func, [ @_ ]);
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
      'file'   => SENDTO_FILEV1, 'FILE'   => SENDTO_FILEV1,
      'file:'  => SENDTO_FILEV2, 'FILE:'  => SENDTO_FILEV2,
      'stdout' => SENDTO_STDOUT, 'STDOUT' => SENDTO_STDOUT,
      'stderr' => SENDTO_STDERR, 'STDERR' => SENDTO_STDERR,
      'fd:'    => SENDTO_FD,     'FD:'    => SENDTO_FD,
   );

   my $_v2_regx = qr/^([^:]+:)(.+)/;

   sub sendto {

      my $self = shift; $self = $MCE unless ref($self);
      my $_to = shift;

      _croak('MCE::sendto: method is not allowed by the manager process')
         unless ($self->{_wid});

      return unless (defined $_[0]);

      my ($_dest, $_value);
      $_dest = (exists $_sendto_lkup{$_to}) ? $_sendto_lkup{$_to} : undef;

      if (!defined $_dest) {
         if (ref $_to && defined (my $_fd = fileno($_to))) {
            if (my $_ob = tied *{ $_to }) {
               if (ref $_ob eq 'IO::TieCombine::Handle') {
                  $_fd = 1 if (lc($_ob->{slot_name}) eq 'stdout');
                  $_fd = 2 if (lc($_ob->{slot_name}) eq 'stderr');
               }
            }
            my $_data_ref = (scalar @_ == 1) ? \$_[0] : \join('', @_);
            return _do_send_glob($self, $_to, $_fd, $_data_ref);
         }
         if (defined $_to && $_to =~ /$_v2_regx/o) {
            $_dest  = (exists $_sendto_lkup{$1}) ? $_sendto_lkup{$1} : undef;
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
   my ($_fd, $_glob, $_data_ref);

   if (ref $_[0] && defined ($_fd = fileno($_[0]))) {
      if (my $_ob = tied *{ $_[0] }) {
         if (ref $_ob eq 'IO::TieCombine::Handle') {
            $_fd = 1 if (lc($_ob->{slot_name}) eq 'stdout');
            $_fd = 2 if (lc($_ob->{slot_name}) eq 'stderr');
         }
      }
      $_glob = shift;
   }

   if (scalar @_ == 1  ) {
      $_data_ref = \$_[0];
   } elsif (scalar @_ > 1) {
      $_data_ref = \join('', @_);
   } else {
      $_data_ref = \$_;
   }

   return _do_send_glob($self, $_glob, $_fd, $_data_ref) if $_fd;
   return _do_send($self, SENDTO_STDOUT, undef, $_data_ref) if $self->{_wid};
   return _do_send_glob($self, \*STDOUT, 1, $_data_ref);
}

sub printf {

   my $self = shift; $self = $MCE unless ref($self);
   my ($_fd, $_glob, $_fmt, $_data);

   if (ref $_[0] && defined ($_fd = fileno($_[0]))) {
      if (my $_ob = tied *{ $_[0] }) {
         if (ref $_ob eq 'IO::TieCombine::Handle') {
            $_fd = 1 if (lc($_ob->{slot_name}) eq 'stdout');
            $_fd = 2 if (lc($_ob->{slot_name}) eq 'stderr');
         }
      }
      $_glob = shift;
   }

   $_fmt  = shift || '%s';
   $_data = (scalar @_) ? sprintf($_fmt, @_) : sprintf($_fmt, $_);

   return _do_send_glob($self, $_glob, $_fd, \$_data) if $_fd;
   return _do_send($self, SENDTO_STDOUT, undef, \$_data) if $self->{_wid};
   return _do_send_glob($self, \*STDOUT, 1, \$_data);
}

sub say {

   my $self = shift; $self = $MCE unless ref($self);
   my ($_fd, $_glob, $_data);

   if (ref $_[0] && defined ($_fd = fileno($_[0]))) {
      if (my $_ob = tied *{ $_[0] }) {
         if (ref $_ob eq 'IO::TieCombine::Handle') {
            $_fd = 1 if (lc($_ob->{slot_name}) eq 'stdout');
            $_fd = 2 if (lc($_ob->{slot_name}) eq 'stderr');
         }
      }
      $_glob = shift;
   }

   $_data = (scalar @_) ? join('', @_) . "\n" : $_ . "\n";

   return _do_send_glob($self, $_glob, $_fd, \$_data) if $_fd;
   return _do_send($self, SENDTO_STDOUT, undef, \$_data) if $self->{_wid};
   return _do_send_glob($self, \*STDOUT, 1, \$_data);
}

###############################################################################
## ----------------------------------------------------------------------------
## Private methods.
##
###############################################################################

sub _die  { return MCE::Signal->_die_handler(@_); }
sub _warn { return MCE::Signal->_warn_handler(@_); }
sub _NOOP {}

sub _croak {

   if (MCE->wid == 0 || ! $^S) {
      $SIG{__DIE__}  = \&MCE::_die;
      $SIG{__WARN__} = \&MCE::_warn;
   }

   $\ = undef; goto &Carp::croak;
}

sub _exit {

   my $self = shift;

   ## Exit thread/child process.
   $SIG{__DIE__}  = sub { } unless $_tid;
   $SIG{__WARN__} = sub { };

   if ($self->{use_threads}) {
      threads->exit(0);
   }
   elsif ($self->{posix_exit} && !$_is_MSWin32) {
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

   $ENV{'PERL_MCE_IPC'} = 'win32' if ($_is_MSWin32 && $INC{'MCE/Hobo.pm'});

   ## Sets the seed of the base generator uniquely between workers.
   ## The new seed is computed using the current seed and $_wid value.
   ## One may set the seed at the application level for predictable
   ## results (non-thread workers only). Ditto for Math::Random.

   if (!$self->{use_threads}) {
      my ($_wid, $_seed) = ($_args[1], $self->{_seed});
      srand(abs($_seed - ($_wid * 100000)) % 2147483560);
   }

   if ($INC{'Math/Random.pm'} && !$self->{use_threads}) {
      my ($_wid, $_cur_seed) = ($_args[1], Math::Random::random_get_seed());

      my $_new_seed = ($_cur_seed < 1073741781)
         ? $_cur_seed + ($_wid * 100000)
         : $_cur_seed - ($_wid * 100000);

      Math::Random::random_set_seed($_new_seed, $_new_seed);
   }

   ## Run.

   $self->{_pid} = ($_is_thread) ? $$ .'.'. threads->tid() : $$;

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

   if (defined $self->{spawn_delay} && $self->{spawn_delay} > 0.0) {
      sleep $self->{spawn_delay};
   }

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

   if (defined $self->{spawn_delay} && $self->{spawn_delay} > 0.0) {
      sleep $self->{spawn_delay};
   }

   return;
}

1;

