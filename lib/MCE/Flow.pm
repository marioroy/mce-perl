###############################################################################
## ----------------------------------------------------------------------------
## Parallel flow model for building creative applications.
##
###############################################################################

package MCE::Flow;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized );

our $VERSION = '1.705';

## no critic (BuiltinFunctions::ProhibitStringyEval)
## no critic (Subroutines::ProhibitSubroutinePrototypes)
## no critic (TestingAndDebugging::ProhibitNoStrict)

use Scalar::Util qw( looks_like_number );
use Storable ();
use MCE::Signal;

our @CARP_NOT = qw( MCE );

###############################################################################
## ----------------------------------------------------------------------------
## Import routine.
##
###############################################################################

my ($MAX_WORKERS, $CHUNK_SIZE) = ('auto', 'auto');

my $TMP_DIR = $MCE::Signal::tmp_dir;
my $FREEZE  = \&Storable::freeze;
my $THAW    = \&Storable::thaw;

my ($_params, @_prev_c, @_prev_n, @_prev_t, @_prev_w, @_user_tasks);
my ($_MCE, $_imported); my $_tag = 'MCE::Flow';

sub import {
   my $_class = shift; return if ($_imported++);

   ## Process module arguments.
   while (my $_argument = shift) {
      my $_arg = lc $_argument;

      $MAX_WORKERS = shift, next if ( $_arg eq 'max_workers' );
      $CHUNK_SIZE  = shift, next if ( $_arg eq 'chunk_size' );
      $FREEZE      = shift, next if ( $_arg eq 'freeze' );
      $THAW        = shift, next if ( $_arg eq 'thaw' );
      $TMP_DIR     = shift, next if ( $_arg eq 'tmp_dir' );

      if ( $_arg eq 'sereal' ) {
         if (shift eq '1') {
            local $@; eval 'use Sereal qw( encode_sereal decode_sereal )';
            if ( !$@ ) {
               $FREEZE = sub { encode_sereal( @_, { freeze_callbacks => 1 } ) };
               $THAW   = \&decode_sereal;
            }
         }
         next;
      }

      _croak("Error: ($_argument) invalid module option");
   }

   ## Preload essential modules.
   require MCE; MCE->import(
      freeze => $FREEZE, thaw => $THAW, tmp_dir => $TMP_DIR
   );

   $MAX_WORKERS = MCE::Util::_parse_max_workers($MAX_WORKERS);
   _validate_number($MAX_WORKERS, 'MAX_WORKERS');

   _validate_number($CHUNK_SIZE, 'CHUNK_SIZE')
      unless ($CHUNK_SIZE eq 'auto');

   ## Import functions.
   no strict 'refs'; no warnings 'redefine';
   my $_pkg = caller;

   *{ $_pkg.'::mce_flow_f' } = \&run_file;
   *{ $_pkg.'::mce_flow_s' } = \&run_seq;
   *{ $_pkg.'::mce_flow'   } = \&run;

   return;
}

END {
   $_MCE = undef;
}

###############################################################################
## ----------------------------------------------------------------------------
## Init and finish routines.
##
###############################################################################

sub init (@) {

   shift if (defined $_[0] && $_[0] eq 'MCE::Flow');

   if (MCE->wid) {
      @_ = (); _croak("$_tag: (init) is not allowed by the worker process");
   }

   finish(); $_params = (ref $_[0] eq 'HASH') ? shift : { @_ };

   @_ = ();

   return;
}

sub finish (@) {

   shift if (defined $_[0] && $_[0] eq 'MCE::Flow');

   if (defined $_MCE && $_MCE->{_spawned}) {
      MCE::_save_state(); $_MCE->shutdown(@_); MCE::_restore_state();
   }

   @_prev_c = (); @_prev_n = (); @_prev_t = (); @_prev_w = ();

   @_user_tasks = ();

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Parallel flow with MCE -- file.
##
###############################################################################

sub run_file (@) {

   shift if (defined $_[0] && $_[0] eq 'MCE::Flow');

   my ($_file, $_pos); my $_start_pos = (ref $_[0] eq 'HASH') ? 2 : 1;

   if (defined $_params) {
      delete $_params->{input_data} if (exists $_params->{input_data});
      delete $_params->{sequence}   if (exists $_params->{sequence});
   }
   else {
      $_params = {};
   }

   for my $_i ($_start_pos .. @_ - 1) {
      my $_r = ref $_[$_i];
      if ($_r eq '' || $_r eq 'GLOB' || $_r eq 'SCALAR' || $_r =~ /^IO::/) {
         $_file = $_[$_i]; $_pos = $_i;
         last;
      }
   }

   if (defined $_file && ref $_file eq '' && $_file ne '') {
      _croak("$_tag: ($_file) does not exist") unless (-e $_file);
      _croak("$_tag: ($_file) is not readable") unless (-r $_file);
      _croak("$_tag: ($_file) is not a plain file") unless (-f $_file);
      $_params->{_file} = $_file;
   }
   elsif (ref $_file eq 'GLOB' || ref $_file eq 'SCALAR' || ref($_file) =~ /^IO::/) {
      $_params->{_file} = $_file;
   }
   else {
      _croak("$_tag: (file) is not specified or valid");
   }

   if (defined $_pos) {
      pop @_ for ($_pos .. @_ - 1);
   }

   return run(@_);
}

###############################################################################
## ----------------------------------------------------------------------------
## Parallel flow with MCE -- sequence.
##
###############################################################################

sub run_seq (@) {

   shift if (defined $_[0] && $_[0] eq 'MCE::Flow');

   my ($_begin, $_end, $_pos); my $_start_pos = (ref $_[0] eq 'HASH') ? 2 : 1;

   if (defined $_params) {
      delete $_params->{sequence}   if (exists $_params->{sequence});
      delete $_params->{input_data} if (exists $_params->{input_data});
      delete $_params->{_file}      if (exists $_params->{_file});
   }
   else {
      $_params = {};
   }

   for my $_i ($_start_pos .. @_ - 1) {
      my $_ref = ref $_[$_i];

      if ($_ref eq '' || $_ref eq 'HASH' || $_ref eq 'ARRAY') {
         $_pos = $_i;

         if ($_ref eq '') {
            $_begin = $_[$_pos]; $_end = $_[$_pos + 1];
            $_params->{sequence} = [
               $_[$_pos], $_[$_pos + 1], $_[$_pos + 2], $_[$_pos + 3]
            ];
         }
         elsif ($_ref eq 'HASH') {
            $_begin = $_[$_pos]->{begin}; $_end = $_[$_pos]->{end};
            $_params->{sequence} = $_[$_pos];
         }
         elsif ($_ref eq 'ARRAY') {
            $_begin = $_[$_pos]->[0]; $_end = $_[$_pos]->[1];
            $_params->{sequence} = $_[$_pos];
         }

         last;
      }
   }

   _croak("$_tag: (sequence) is not specified or valid")
      unless (exists $_params->{sequence});

   _croak("$_tag: (begin) is not specified for sequence")
      unless (defined $_begin);

   _croak("$_tag: (end) is not specified for sequence")
      unless (defined $_end);

   $_params->{sequence_run} = 1;

   if (defined $_pos) {
      pop @_ for ($_pos .. @_ - 1);
   }

   return run(@_);
}

###############################################################################
## ----------------------------------------------------------------------------
## Parallel flow with MCE.
##
###############################################################################

sub run (@) {

   shift if (defined $_[0] && $_[0] eq 'MCE::Flow');

   if (MCE->wid) {
      @_ = (); _croak("$_tag: (run) is not allowed by the worker process");
   }

   if (ref $_[0] eq 'HASH') {
      $_params = {} unless defined $_params;
      for my $_p (keys %{ $_[0] }) {
         $_params->{$_p} = $_[0]->{$_p};
      }

      shift;
   }

   ## -------------------------------------------------------------------------

   my (@_code, @_name, @_thrs, @_wrks); my $_init_mce = 0; my $_pos = 0;

   while (ref $_[0] eq 'CODE') {
      push @_code, $_[0];

      push @_name, (defined $_params && ref $_params->{task_name} eq 'ARRAY')
         ? $_params->{task_name}->[$_pos] : undef;
      push @_thrs, (defined $_params && ref $_params->{use_threads} eq 'ARRAY')
         ? $_params->{use_threads}->[$_pos] : undef;
      push @_wrks, (defined $_params && ref $_params->{max_workers} eq 'ARRAY')
         ? $_params->{max_workers}->[$_pos] : undef;

      if (!defined $_prev_c[$_pos] || $_prev_c[$_pos] != $_code[$_pos]) {
         $_init_mce = 1;
      }

      {
         no warnings;
         $_init_mce = 1 if ($_prev_n[$_pos] ne $_name[$_pos]);
         $_init_mce = 1 if ($_prev_t[$_pos] ne $_thrs[$_pos]);
         $_init_mce = 1 if ($_prev_w[$_pos] ne $_wrks[$_pos]);
      }

      $_prev_c[$_pos] = $_code[$_pos];
      $_prev_n[$_pos] = $_name[$_pos];
      $_prev_t[$_pos] = $_thrs[$_pos];
      $_prev_w[$_pos] = $_wrks[$_pos];

      shift; $_pos++;
   }

   if (defined $_prev_c[$_pos]) {
      pop @_prev_c for ($_pos .. @_prev_c - 1);
      pop @_prev_n for ($_pos .. @_prev_n - 1);
      pop @_prev_t for ($_pos .. @_prev_t - 1);
      pop @_prev_w for ($_pos .. @_prev_w - 1);

      $_init_mce = 1;
   }

   return unless (scalar @_code);

   ## -------------------------------------------------------------------------

   my $_input_data; my $_max_workers = $MAX_WORKERS; my $_r = ref $_[0];

   if ($_r eq 'ARRAY' || $_r eq 'GLOB' || $_r eq 'SCALAR' || $_r =~ /^IO::/) {
      $_input_data = shift;
   }

   if (defined $_params) { my $_p = $_params;
      $_max_workers = MCE::Util::_parse_max_workers($_p->{max_workers})
         if (exists $_p->{max_workers} && ref $_p->{max_workers} ne 'ARRAY');

      delete $_p->{sequence}   if (defined $_input_data || scalar @_);
      delete $_p->{user_func}  if (exists $_p->{user_func});
      delete $_p->{user_tasks} if (exists $_p->{user_tasks});
   }

   if (@_code > 1 && $_max_workers > 1) {
      $_max_workers = int($_max_workers / @_code + 0.5) + 1;
   }

   my $_chunk_size = MCE::Util::_parse_chunk_size(
      $CHUNK_SIZE, $_max_workers, $_params, $_input_data, scalar @_
   );

   if (defined $_params) {
      if (exists $_params->{_file}) {
         $_input_data = delete $_params->{_file};
      }
      else {
         $_input_data = $_params->{input_data} if exists $_params->{input_data};
      }
   }

   MCE::_save_state();

   ## -------------------------------------------------------------------------

   if ($_init_mce) {
      $_MCE->shutdown() if (defined $_MCE);
      _gen_user_tasks(\@_code, \@_name, \@_thrs, \@_wrks);

      my %_options = (
         max_workers => $_max_workers, task_name => $_tag,
         user_tasks  => \@_user_tasks,
      );

      if (defined $_params) {
         local $_; my $_p = $_params;

         for (keys %{ $_p }) {
            next if ($_ eq 'max_workers' && ref $_p->{max_workers} eq 'ARRAY');
            next if ($_ eq 'task_name'   && ref $_p->{task_name}   eq 'ARRAY');
            next if ($_ eq 'use_threads' && ref $_p->{use_threads} eq 'ARRAY');

            next if ($_ eq 'chunk_size');
            next if ($_ eq 'input_data');
            next if ($_ eq 'sequence_run');

            _croak("MCE::Flow: ($_) is not a valid constructor argument")
               unless (exists $MCE::_valid_fields_new{$_});

            $_options{$_} = $_p->{$_};
         }
      }

      $_MCE = MCE->new(%_options);
   }
   else {
      ## Workers may persist after running. Thus, updating the MCE instance.
      ## These options do not require respawning.
      if (defined $_params) {
         for my $_p (qw(
            RS interval stderr_file stdout_file user_error user_output
            job_delay submit_delay on_post_exit on_post_run user_args
            flush_file flush_stderr flush_stdout gather max_retries
         )) {
            $_MCE->{$_p} = $_params->{$_p} if (exists $_params->{$_p});
         }
      }
   }

   ## -------------------------------------------------------------------------

   my @_a; my $_wa = wantarray; $_MCE->{gather} = \@_a if (defined $_wa);

   if (defined $_input_data) {
      @_ = ();
      $_MCE->process({ chunk_size => $_chunk_size }, $_input_data);
      delete $_MCE->{input_data};
   }
   elsif (scalar @_) {
      $_MCE->process({ chunk_size => $_chunk_size }, \@_);
      delete $_MCE->{input_data};
   }
   else {
      if (defined $_params && exists $_params->{sequence}) {
         $_MCE->run({
            chunk_size => $_chunk_size, sequence => $_params->{sequence}
         }, 0);
         if (exists $_params->{sequence_run}) {
            delete $_params->{sequence_run};
            delete $_params->{sequence};
         }
         delete $_MCE->{sequence};
      }
      else {
         $_MCE->run({ chunk_size => $_chunk_size }, 0);
      }
   }

   delete $_MCE->{gather} if (defined $_wa);

   MCE::_restore_state();

   if (exists $_MCE->{_rla_return}) {
      $MCE::MCE->{_rla_return} = delete $_MCE->{_rla_return};
   }

   if ($^S || $ENV{'PERL_IPERL_RUNNING'}) {
      ## shutdown if in eval state
      MCE::_save_state(); $_MCE->shutdown(); MCE::_restore_state();
   }

   return ((defined $_wa) ? @_a : ());
}

###############################################################################
## ----------------------------------------------------------------------------
## Private methods.
##
###############################################################################

sub _croak {

   goto &MCE::_croak;
}

sub _gen_user_tasks {

   my ($_code_ref, $_name_ref, $_thrs_ref, $_wrks_ref) = @_;

   @_user_tasks = ();

   for (my $_i = 0; $_i < @{ $_code_ref }; $_i++) {
      push @_user_tasks, {
         task_name   => $_name_ref->[$_i],
         use_threads => $_thrs_ref->[$_i],
         max_workers => $_wrks_ref->[$_i],
         user_func   => $_code_ref->[$_i]
      }
   }

   return;
}

sub _validate_number {

   my ($_n, $_key) = @_;

   _croak("$_tag: ($_key) is not valid") if (!defined $_n);

   $_n =~ s/K\z//i; $_n =~ s/M\z//i;

   if (!looks_like_number($_n) || int($_n) != $_n || $_n < 1) {
      _croak("$_tag: ($_key) is not valid");
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

MCE::Flow - Parallel flow model for building creative applications

=head1 VERSION

This document describes MCE::Flow version 1.705

=head1 DESCRIPTION

MCE::Flow is great for writing custom apps to maximize on all available cores.
This module was created to help one harness user_tasks within MCE.

It is trivial to parallelize with mce_stream shown below.

   ## Native map function
   my @a = map { $_ * 4 } map { $_ * 3 } map { $_ * 2 } 1..10000;

   ## Same as with MCE::Stream (processing from right to left)
   @a = mce_stream
        sub { $_ * 4 }, sub { $_ * 3 }, sub { $_ * 2 }, 1..10000;

   ## Pass an array reference to have writes occur simultaneously
   mce_stream \@a,
        sub { $_ * 4 }, sub { $_ * 3 }, sub { $_ * 2 }, 1..10000;

However, let's have MCE::Flow compute the same in parallel. MCE::Queue
will be used for data flow among the sub-tasks.

   use MCE::Flow;
   use MCE::Queue;

This calls for preserving output order.

   sub preserve_order {
      my %tmp; my $order_id = 1; my $gather_ref = $_[0];
      @{ $gather_ref } = ();  ## clear the array (optional)

      return sub {
         my ($data_ref, $chunk_id) = @_;
         $tmp{$chunk_id} = $data_ref;

         while (1) {
            last unless exists $tmp{$order_id};
            push @{ $gather_ref }, @{ delete $tmp{$order_id++} };
         }

         return;
      };
   }

Two queues are needed for data flow between the 3 sub-tasks. Notice task_end
and how the value from $task_name is used for determining which task has ended.

   my $b = MCE::Queue->new;
   my $c = MCE::Queue->new;

   sub task_end {
      my ($mce, $task_id, $task_name) = @_;

      if (defined $mce->{user_tasks}->[$task_id + 1]) {
         my $n_workers = $mce->{user_tasks}->[$task_id + 1]->{max_workers};

         if ($task_name eq 'a') {
            $b->enqueue((undef) x $n_workers);
         }
         elsif ($task_name eq 'b') {
            $c->enqueue((undef) x $n_workers);
         }
      }

      return;
   }

Next are the 3 sub-tasks. The first one reads input and begins the flow.
The 2nd task dequeues, performs the calculation, and enqueues into the next.
Finally, the last task calls the gather method.

Although serialization is done for you automatically, it is done here to save
from double serialization. This is the fastest approach for passing data
between sub-tasks. Thus, the least overhead.

   sub task_a {
      my @ans; my ($mce, $chunk_ref, $chunk_id) = @_;

      push @ans, map { $_ * 2 } @{ $chunk_ref };
      $b->enqueue(MCE->freeze([ \@ans, $chunk_id ]));

      return;
   }

   sub task_b {
      my ($mce) = @_;

      while (1) {
         my @ans; my $chunk = $b->dequeue;
         last unless defined $chunk;

         $chunk = MCE->thaw($chunk);
         push @ans, map { $_ * 3 } @{ $chunk->[0] };
         $c->enqueue(MCE->freeze([ \@ans, $chunk->[1] ]));
      }

      return;
   }

   sub task_c {
      my ($mce) = @_;

      while (1) {
         my @ans; my $chunk = $c->dequeue;
         last unless defined $chunk;

         $chunk = MCE->thaw($chunk);
         push @ans, map { $_ * 4 } @{ $chunk->[0] };
         MCE->gather(\@ans, $chunk->[1]);
      }

      return;
   }

In summary, MCE::Flow builds out a MCE instance behind the scene and starts
running. The task_name (shown), max_workers, and use_threads options can take
an anonymous array for specifying the values uniquely per each sub-task.

   my @a;

   mce_flow {
      task_name => [ 'a', 'b', 'c' ], task_end => \&task_end,
      gather => preserve_order(\@a)

   }, \&task_a, \&task_b, \&task_c, 1..10000;

   print "@a\n";

If speed is not a concern and wanting to rid of all the MCE->freeze and
MCE->thaw statements, simply enqueue and dequeue 2 items at a time.
Or better yet, see L<MCE::Step> introduced in MCE 1.506.

First, task_end must be updated. The number of undef(s) must match the number
of workers times the dequeue count. Otherwise, the script will stall.

   sub task_end {
      ...
         if ($task_name eq 'a') {
          # $b->enqueue((undef) x $n_workers);
            $b->enqueue((undef) x ($n_workers * 2));
         }
         elsif ($task_name eq 'b') {
          # $c->enqueue((undef) x $n_workers);
            $c->enqueue((undef) x ($n_workers * 2));
         }
      ...
   }

Next, the 3 sub-tasks enqueuing and dequeuing 2 elements at a time.

   sub task_a {
      my @ans; my ($mce, $chunk_ref, $chunk_id) = @_;

      push @ans, map { $_ * 2 } @{ $chunk_ref };
      $b->enqueue(\@ans, $chunk_id);

      return;
   }

   sub task_b {
      my ($mce) = @_;

      while (1) {
         my @ans; my ($chunk_ref, $chunk_id) = $b->dequeue(2);
         last unless defined $chunk_ref;

         push @ans, map { $_ * 3 } @{ $chunk_ref };
         $c->enqueue(\@ans, $chunk_id);
      }

      return;
   }

   sub task_c {
      my ($mce) = @_;

      while (1) {
         my @ans; my ($chunk_ref, $chunk_id) = $c->dequeue(2);
         last unless defined $chunk_ref;

         push @ans, map { $_ * 4 } @{ $chunk_ref };
         MCE->gather(\@ans, $chunk_id);
      }

      return;
   }

Finally, run as usual.

   my @a;

   mce_flow {
      task_name => [ 'a', 'b', 'c' ], task_end => \&task_end,
      gather => preserve_order(\@a)

   }, \&task_a, \&task_b, \&task_c, 1..10000;

   print "@a\n";

=head1 SYNOPSIS when CHUNK_SIZE EQUALS 1

Although L<MCE::Loop> may be preferred for running using a single code block,
the text below also applies to this module, particularly for the first block.

All models in MCE default to 'auto' for chunk_size. The arguments for the block
are the same as writing a user_func block using the Core API.

Beginning with MCE 1.5, the next input item is placed into the input scalar
variable $_ when chunk_size equals 1. Otherwise, $_ points to $chunk_ref
containing many items. Basically, line 2 below may be omitted from your code
when using $_. One can call MCE->chunk_id to obtain the current chunk id.

   line 1:  user_func => sub {
   line 2:     my ($mce, $chunk_ref, $chunk_id) = @_;
   line 3:
   line 4:     $_ points to $chunk_ref->[0]
   line 5:        in MCE 1.5 when chunk_size == 1
   line 6:
   line 7:     $_ points to $chunk_ref
   line 8:        in MCE 1.5 when chunk_size  > 1
   line 9:  }

Follow this synopsis when chunk_size equals one. Looping is not required from
inside the first block. Hence, the block is called once per each item.

   ## Exports mce_flow, mce_flow_f, and mce_flow_s
   use MCE::Flow;

   MCE::Flow::init {
      chunk_size => 1
   };

   ## Array or array_ref
   mce_flow sub { do_work($_) }, 1..10000;
   mce_flow sub { do_work($_) }, [ 1..10000 ];

   ## File_path, glob_ref, or scalar_ref
   mce_flow_f sub { chomp; do_work($_) }, "/path/to/file";
   mce_flow_f sub { chomp; do_work($_) }, $file_handle;
   mce_flow_f sub { chomp; do_work($_) }, \$scalar;

   ## Sequence of numbers (begin, end [, step, format])
   mce_flow_s sub { do_work($_) }, 1, 10000, 5;
   mce_flow_s sub { do_work($_) }, [ 1, 10000, 5 ];

   mce_flow_s sub { do_work($_) }, {
      begin => 1, end => 10000, step => 5, format => undef
   };

=head1 SYNOPSIS when CHUNK_SIZE is GREATER THAN 1

Follow this synopsis when chunk_size equals 'auto' or greater than 1.
This means having to loop through the chunk from inside the first block.

   use MCE::Flow;

   MCE::Flow::init {          ## Chunk_size defaults to 'auto' when
      chunk_size => 'auto'    ## not specified. Therefore, the init
   };                         ## function may be omitted.

   ## Syntax is shown for mce_flow for demonstration purposes.
   ## Looping inside the block is the same for mce_flow_f and
   ## mce_flow_s.

   mce_flow sub { do_work($_) for (@{ $_ }) }, 1..10000;

   ## Same as above, resembles code using the Core API.

   mce_flow sub {
      my ($mce, $chunk_ref, $chunk_id) = @_;

      for (@{ $chunk_ref }) {
         do_work($_);
      }

   }, 1..10000;

Chunking reduces the number of IPC calls behind the scene. Think in terms of
chunks whenever processing a large amount of data. For relatively small data,
choosing 1 for chunk_size is fine.

=head1 OVERRIDING DEFAULTS

The following list options which may be overridden when loading the module.

   use Sereal qw( encode_sereal decode_sereal );
   use CBOR::XS qw( encode_cbor decode_cbor );
   use JSON::XS qw( encode_json decode_json );

   use MCE::Flow
         max_workers => 8,                ## Default 'auto'
         chunk_size => 500,               ## Default 'auto'
         tmp_dir => "/path/to/app/tmp",   ## $MCE::Signal::tmp_dir
         freeze => \&encode_sereal,       ## \&Storable::freeze
         thaw => \&decode_sereal          ## \&Storable::thaw
   ;

There is a simpler way to enable Sereal. The following will attempt to use
Sereal if available, otherwise defaults to Storable for serialization.

   use MCE::Flow Sereal => 1;

=head1 CUSTOMIZING MCE

=over 3

=item MCE::Flow->init ( options )

=item MCE::Flow::init { options }

The init function accepts a hash of MCE options. Unlike with MCE::Stream,
both gather and bounds_only options may be specified when calling init
(not shown below).

   use MCE::Flow;

   MCE::Flow::init {
      chunk_size => 1, max_workers => 4,

      user_begin => sub {
         print "## ", MCE->wid, " started\n";
      },

      user_end => sub {
         print "## ", MCE->wid, " completed\n";
      }
   };

   my %a = mce_flow sub { MCE->gather($_, $_ * $_) }, 1..100;

   print "\n", "@a{1..100}", "\n";

   -- Output

   ## 3 started
   ## 2 started
   ## 4 started
   ## 1 started
   ## 2 completed
   ## 4 completed
   ## 3 completed
   ## 1 completed

   1 4 9 16 25 36 49 64 81 100 121 144 169 196 225 256 289 324 361
   400 441 484 529 576 625 676 729 784 841 900 961 1024 1089 1156
   1225 1296 1369 1444 1521 1600 1681 1764 1849 1936 2025 2116 2209
   2304 2401 2500 2601 2704 2809 2916 3025 3136 3249 3364 3481 3600
   3721 3844 3969 4096 4225 4356 4489 4624 4761 4900 5041 5184 5329
   5476 5625 5776 5929 6084 6241 6400 6561 6724 6889 7056 7225 7396
   7569 7744 7921 8100 8281 8464 8649 8836 9025 9216 9409 9604 9801
   10000

=back

Like with MCE::Flow::init above, MCE options may be specified using an
anonymous hash for the first argument. Notice how task_name, max_workers,
and use_threads can take an anonymous array for setting uniquely per
each code block.

Unlike MCE::Stream which processes from right-to-left, MCE::Flow begins
with the first code block, thus processing from left-to-right.

   use threads;
   use MCE::Flow;

   my @a = mce_flow {
      task_name   => [ 'a', 'b', 'c' ],
      max_workers => [  3,   4,   2, ],
      use_threads => [  1,   0,   0, ],

      user_end => sub {
         my ($mce, $task_id, $task_name) = @_;
         MCE->print("$task_id - $task_name completed\n");
      },

      task_end => sub {
         my ($mce, $task_id, $task_name) = @_;
         MCE->print("$task_id - $task_name ended\n");
      }
   },
   sub { sleep 1; },   ## 3 workers, named a
   sub { sleep 2; },   ## 4 workers, named b
   sub { sleep 3; };   ## 2 workers, named c

   -- Output

   0 - a completed
   0 - a completed
   0 - a completed
   0 - a ended
   1 - b completed
   1 - b completed
   1 - b completed
   1 - b completed
   1 - b ended
   2 - c completed
   2 - c completed
   2 - c ended

=head1 API DOCUMENTATION

Although input data is optional for MCE::Flow, the following assumes chunk_size
equals 1 in order to demonstrate all the possibilities of passing input data
into the code block.

=over 3

=item MCE::Flow->run ( { input_data => iterator }, sub { code } )

=item mce_flow { input_data => iterator }, sub { code }

An iterator reference can by specified for input_data. The only other way
is to specify input_data via MCE::Flow::init. This prevents MCE::Flow from
configuring the iterator reference as another user task which will not work.

Iterators are described under "SYNTAX for INPUT_DATA" at L<MCE::Core>.

   MCE::Flow::init {
      input_data => iterator
   };

   mce_flow sub { $_ };

=item MCE::Flow->run ( sub { code }, list )

=item mce_flow sub { code }, list

Input data can be defined using a list.

   mce_flow sub { $_ }, 1..1000;
   mce_flow sub { $_ }, [ 1..1000 ];

=item MCE::Flow->run_file ( sub { code }, file )

=item mce_flow_f sub { code }, file

The fastest of these is the /path/to/file. Workers communicate the next offset
position among themselves with zero interaction by the manager process.

   mce_flow_f sub { $_ }, "/path/to/file";
   mce_flow_f sub { $_ }, $file_handle;
   mce_flow_f sub { $_ }, \$scalar;

=item MCE::Flow->run_seq ( sub { code }, $beg, $end [, $step, $fmt ] )

=item mce_flow_s sub { code }, $beg, $end [, $step, $fmt ]

Sequence can be defined as a list, an array reference, or a hash reference.
The functions require both begin and end values to run. Step and format are
optional. The format is passed to sprintf (% may be omitted below).

   my ($beg, $end, $step, $fmt) = (10, 20, 0.1, "%4.1f");

   mce_flow_s sub { $_ }, $beg, $end, $step, $fmt;
   mce_flow_s sub { $_ }, [ $beg, $end, $step, $fmt ];

   mce_flow_s sub { $_ }, {
      begin => $beg, end => $end, step => $step, format => $fmt
   };

The sequence engine can compute 'begin' and 'end' items only, for the chunk,
and not the items in between (hence boundaries only). This option applies
to sequence only and has no effect when chunk_size equals 1.

The time to run is 0.006s below. This becomes 0.827s without the bounds_only
option due to computing all items in between, thus creating a very large
array. Basically, specify bounds_only => 1 when boundaries is all you need
for looping inside the block; e.g. Monte Carlo simulations.

Time was measured using 1 worker to emphasize the difference.

   use MCE::Flow;

   MCE::Flow::init {
      max_workers => 1, chunk_size => 1_250_000,
      bounds_only => 1
   };

   ## For sequence, the input scalar $_ points to $chunk_ref
   ## when chunk_size > 1, otherwise $chunk_ref->[0].
   ##
   ## mce_flow_s sub {
   ##    my $begin = $_->[0]; my $end = $_->[-1];
   ##
   ##    for ($begin .. $end) {
   ##       ...
   ##    }
   ##
   ## }, 1, 10_000_000;

   mce_flow_s sub {
      my ($mce, $chunk_ref, $chunk_id) = @_;
      ## $chunk_ref contains 2 items, not 1_250_000

      my $begin = $chunk_ref->[ 0];
      my $end   = $chunk_ref->[-1];   ## or $chunk_ref->[1]

      MCE->printf("%7d .. %8d\n", $begin, $end);

   }, 1, 10_000_000;

   -- Output

         1 ..  1250000
   1250001 ..  2500000
   2500001 ..  3750000
   3750001 ..  5000000
   5000001 ..  6250000
   6250001 ..  7500000
   7500001 ..  8750000
   8750001 .. 10000000

=back

=head1 GATHERING DATA

Unlike MCE::Map where gather and output order are done for you automatically,
the gather method is used to have results sent back to the manager process.

   use MCE::Flow chunk_size => 1;

   ## Output order is not guaranteed.
   my @a = mce_flow sub { MCE->gather($_ * 2) }, 1..100;
   print "@a\n\n";

   ## Outputs to a hash instead (key, value).
   my %h1 = mce_flow sub { MCE->gather($_, $_ * 2) }, 1..100;
   print "@h1{1..100}\n\n";

   ## This does the same thing due to chunk_id starting at one.
   my %h2 = mce_flow sub { MCE->gather(MCE->chunk_id, $_ * 2) }, 1..100;
   print "@h2{1..100}\n\n";

The gather method can be called multiple times within the block unlike return
which would leave the block. Therefore, think of gather as yielding results
immediately to the manager process without actually leaving the block.

   use MCE::Flow chunk_size => 1, max_workers => 3;

   my @hosts = qw(
      hosta hostb hostc hostd hoste
   );

   my %h3 = mce_flow sub {
      my ($output, $error, $status); my $host = $_;

      ## Do something with $host;
      $output = "Worker ". MCE->wid .": Hello from $host";

      if (MCE->chunk_id % 3 == 0) {
         ## Simulating an error condition
         local $? = 1; $status = $?;
         $error = "Error from $host"
      }
      else {
         $status = 0;
      }

      ## Ensure unique keys (key, value) when gathering to
      ## a hash.
      MCE->gather("$host.out", $output);
      MCE->gather("$host.err", $error) if (defined $error);
      MCE->gather("$host.sta", $status);

   }, @hosts;

   foreach my $host (@hosts) {
      print $h3{"$host.out"}, "\n";
      print $h3{"$host.err"}, "\n" if (exists $h3{"$host.err"});
      print "Exit status: ", $h3{"$host.sta"}, "\n\n";
   }

   -- Output

   Worker 3: Hello from hosta
   Exit status: 0

   Worker 2: Hello from hostb
   Exit status: 0

   Worker 1: Hello from hostc
   Error from hostc
   Exit status: 1

   Worker 3: Hello from hostd
   Exit status: 0

   Worker 2: Hello from hoste
   Exit status: 0

The following uses an anonymous array containing 3 elements when gathering
data. Serialization is automatic behind the scene.

   my %h3 = mce_flow sub {
      ...

      MCE->gather($host, [$output, $error, $status]);

   }, @hosts;

   foreach my $host (@hosts) {
      print $h3{$host}->[0], "\n";
      print $h3{$host}->[1], "\n" if (defined $h3{$host}->[1]);
      print "Exit status: ", $h3{$host}->[2], "\n\n";
   }

Although MCE::Map comes to mind, one may want additional control when
gathering data such as retaining output order.

   use MCE::Flow;

   sub preserve_order {
      my %tmp; my $order_id = 1; my $gather_ref = $_[0];

      return sub {
         $tmp{ (shift) } = \@_;

         while (1) {
            last unless exists $tmp{$order_id};
            push @{ $gather_ref }, @{ delete $tmp{$order_id++} };
         }

         return;
      };
   }

   ## Workers persist for the most part after running. Though, not always
   ## the case and depends on Perl. Pass a reference to a subroutine if
   ## workers must persist; e.g. mce_flow { ... }, \&foo, 1..100000.

   MCE::Flow::init {
      chunk_size => 'auto', max_workers => 'auto'
   };

   for (1..2) {
      my @m2;

      mce_flow {
         gather => preserve_order(\@m2)
      },
      sub {
         my @a; my ($mce, $chunk_ref, $chunk_id) = @_;

         ## Compute the entire chunk data at once.
         push @a, map { $_ * 2 } @{ $chunk_ref };

         ## Afterwards, invoke the gather feature, which
         ## will direct the data to the callback function.
         MCE->gather(MCE->chunk_id, @a);

      }, 1..100000;

      print scalar @m2, "\n";
   }

   MCE::Flow::finish;

All 6 models support 'auto' for chunk_size unlike the Core API. Think of the
models as the basis for providing JIT for MCE. They create the instance, tune
max_workers, and tune chunk_size automatically regardless of the hardware.

The following does the same thing using the Core API. Workers persist after
running.

   use MCE;

   sub preserve_order {
      ...
   }

   my $mce = MCE->new(
      max_workers => 'auto', chunk_size => 8000,

      user_func => sub {
         my @a; my ($mce, $chunk_ref, $chunk_id) = @_;

         ## Compute the entire chunk data at once.
         push @a, map { $_ * 2 } @{ $chunk_ref };

         ## Afterwards, invoke the gather feature, which
         ## will direct the data to the callback function.
         MCE->gather(MCE->chunk_id, @a);
      }
   );

   for (1..2) {
      my @m2;

      $mce->process({ gather => preserve_order(\@m2) }, [1..100000]);

      print scalar @m2, "\n";
   }

   $mce->shutdown;

=head1 MANUAL SHUTDOWN

=over 3

=item MCE::Flow->finish

=item MCE::Flow::finish

Workers remain persistent as much as possible after running. Shutdown occurs
automatically when the script terminates. Call finish when workers are no
longer needed.

   use MCE::Flow;

   MCE::Flow::init {
      chunk_size => 20, max_workers => 'auto'
   };

   mce_flow sub { ... }, 1..100;

   MCE::Flow::finish;

=back

=head1 INDEX

L<MCE|MCE>, L<MCE::Core>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

