###############################################################################
## ----------------------------------------------------------------------------
## Parallel step model for building creative steps.
##
###############################################################################

package MCE::Step;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized );

our $VERSION = '1.879';

## no critic (BuiltinFunctions::ProhibitStringyEval)
## no critic (Subroutines::ProhibitSubroutinePrototypes)
## no critic (TestingAndDebugging::ProhibitNoStrict)

use Scalar::Util qw( looks_like_number );

use MCE;
use MCE::Queue;

our @CARP_NOT = qw( MCE );

my $_tid = $INC{'threads.pm'} ? threads->tid() : 0;

sub CLONE {
   $_tid = threads->tid() if $INC{'threads.pm'};
}

###############################################################################
## ----------------------------------------------------------------------------
## Import routine.
##
###############################################################################

my ($_MCE, $_def, $_params, $_tag) = ({}, {}, {}, 'MCE::Step');
my ($_prev_c, $_prev_n, $_prev_t, $_prev_w) = ({}, {}, {}, {});
my ($_user_tasks, $_queue, $_last_task_id, $_lkup) = ({}, {}, {}, {});

sub import {
   my ($_class, $_pkg) = (shift, caller);

   my $_p = $_def->{$_pkg} = {
      MAX_WORKERS => 'auto',
      CHUNK_SIZE  => 'auto',
   };

   ## Import functions.
   no strict 'refs'; no warnings 'redefine';

   *{ $_pkg.'::mce_step_f' } = \&run_file;
   *{ $_pkg.'::mce_step_s' } = \&run_seq;
   *{ $_pkg.'::mce_step'   } = \&run;

   ## Process module arguments.
   while ( my $_argument = shift ) {
      my $_arg = lc $_argument;

      $_p->{MAX_WORKERS} = shift, next if ( $_arg eq 'max_workers' );
      $_p->{CHUNK_SIZE}  = shift, next if ( $_arg eq 'chunk_size' );
      $_p->{TMP_DIR}     = shift, next if ( $_arg eq 'tmp_dir' );
      $_p->{FREEZE}      = shift, next if ( $_arg eq 'freeze' );
      $_p->{THAW}        = shift, next if ( $_arg eq 'thaw' );

                           shift, next if ( $_arg eq 'fast' ); # ignored

      ## Sereal 3.015+, if available, is used automatically by MCE 1.8+.
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

   $_p->{MAX_WORKERS} = MCE::_parse_max_workers($_p->{MAX_WORKERS});

   MCE::_validate_number($_p->{MAX_WORKERS}, 'MAX_WORKERS', $_tag);
   MCE::_validate_number($_p->{CHUNK_SIZE}, 'CHUNK_SIZE', $_tag)
      unless ($_p->{CHUNK_SIZE} eq 'auto');

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## The task end callback for when a task completes.
##
###############################################################################

sub _task_end {

   my ($_mce, $_task_id, $_task_name) = @_;
   my $_pid = $_mce->{_init_pid}.'.'.$_mce->{_caller};

   if (defined $_mce->{user_tasks}->[$_task_id + 1]) {
      my $n_workers = $_mce->{user_tasks}->[$_task_id + 1]->{max_workers};
      $_queue->{$_pid}[$_task_id]->enqueue((undef) x $n_workers);
   }

   $_params->{task_end}->($_mce, $_task_id, $_task_name)
      if (exists $_params->{task_end} && ref $_params->{task_end} eq 'CODE');

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Methods for MCE; step, enq, enqp, await.
##
###############################################################################

{
   no warnings 'redefine';

   sub MCE::step {

      my $x = shift; my $self = ref($x) ? $x : $MCE::MCE;
      my $_pid = $self->{_init_pid}.'.'.$self->{_caller};

      _croak('MCE::step: method is not allowed by the manager process')
         unless ($self->{_wid});

      my $_task_id = $self->{_task_id};

      if ($_task_id < $_last_task_id->{$_pid}) {
         $_queue->{$_pid}[$_task_id]->enqueue($self->freeze([ @_ ]));
      }
      else {
         _croak('MCE::step: method is not allowed by the last task');
      }

      return;
   }

   ############################################################################

   sub MCE::enq {

      my $x = shift; my $self = ref($x) ? $x : $MCE::MCE;
      my $_pid = $self->{_init_pid}.'.'.$self->{_caller};
      my $_name = shift;

      _croak('MCE::enq: method is not allowed by the manager process')
         unless ($self->{_wid});
      _croak('MCE::enq: (task_name) is not specified or valid')
         if (!defined $_name || !exists $_lkup->{$_pid}{$_name});
      _croak('MCE::enq: stepping to same task or backwards is not allowed')
         if ($_lkup->{$_pid}{$_name} <= $self->{_task_id});

      my $_task_id = $_lkup->{$_pid}{$_name} - 1;

      if ($_task_id < $_last_task_id->{$_pid}) {
         if (scalar @_ > 1) {
            my @_items = map { $self->freeze([ $_ ]) } @_;
            $_queue->{$_pid}[$_task_id]->enqueue(@_items);
         }
         else {
            $_queue->{$_pid}[$_task_id]->enqueue($self->freeze([ @_ ]));
         }
      }
      else {
         _croak('MCE::enq: method is not allowed by the last task');
      }

      return;
   }

   ############################################################################

   sub MCE::enqp {

      my $x = shift; my $self = ref($x) ? $x : $MCE::MCE;
      my $_pid = $self->{_init_pid}.'.'.$self->{_caller};
      my ($_name, $_p) = (shift, shift);

      _croak('MCE::enqp: method is not allowed by the manager process')
         unless ($self->{_wid});
      _croak('MCE::enqp: (task_name) is not specified or valid')
         if (!defined $_name || !exists $_lkup->{$_pid}{$_name});
      _croak('MCE::enqp: stepping to same task or backwards is not allowed')
         if ($_lkup->{$_pid}{$_name} <= $self->{_task_id});
      _croak('MCE::enqp: (priority) is not an integer')
         if (!looks_like_number($_p) || int($_p) != $_p);

      my $_task_id = $_lkup->{$_pid}{$_name} - 1;

      if ($_task_id < $_last_task_id->{$_pid}) {
         if (scalar @_ > 1) {
            my @_items = map { $self->freeze([ $_ ]) } @_;
            $_queue->{$_pid}[$_task_id]->enqueuep($_p, @_items);
         }
         else {
            $_queue->{$_pid}[$_task_id]->enqueuep($_p, $self->freeze([ @_ ]));
         }
      }
      else {
         _croak('MCE::enqp: method is not allowed by the last task');
      }

      return;
   }

   ############################################################################

   sub MCE::await {

      my $x = shift; my $self = ref($x) ? $x : $MCE::MCE;
      my $_pid = $self->{_init_pid}.'.'.$self->{_caller};
      my $_name = shift;

      _croak('MCE::await: method is not allowed by the manager process')
         unless ($self->{_wid});
      _croak('MCE::await: (task_name) is not specified or valid')
         if (!defined $_name || !exists $_lkup->{$_pid}{$_name});
      _croak('MCE::await: awaiting from same task or backwards is not allowed')
         if ($_lkup->{$_pid}{$_name} <= $self->{_task_id});

      my $_task_id = $_lkup->{$_pid}{$_name} - 1;  my $_t = shift || 0;

      _croak('MCE::await: (threshold) is not an integer')
         if (!looks_like_number($_t) || int($_t) != $_t);

      if ($_task_id < $_last_task_id->{$_pid}) {
         $_queue->{$_pid}[$_task_id]->await($_t);
      } else {
         _croak('MCE::await: method is not allowed by the last task');
      }

      return;
   }

}

###############################################################################
## ----------------------------------------------------------------------------
## Init and finish routines.
##
###############################################################################

sub init (@) {

   shift if (defined $_[0] && $_[0] eq 'MCE::Step');
   my $_pkg = "$$.$_tid.".caller();

   $_params->{$_pkg} = (ref $_[0] eq 'HASH') ? shift : { @_ };

   @_ = ();

   return;
}

sub finish (@) {

   shift if (defined $_[0] && $_[0] eq 'MCE::Step');
   my $_pkg = (defined $_[0]) ? shift : "$$.$_tid.".caller();

   if ( $_pkg eq 'MCE' ) {
      for my $_k ( keys %{ $_MCE } ) { MCE::Step->finish($_k, 1); }
   }
   elsif ( $_MCE->{$_pkg} && $_MCE->{$_pkg}{_init_pid} eq "$$.$_tid" ) {
      $_MCE->{$_pkg}->shutdown(@_) if $_MCE->{$_pkg}{_spawned};

      delete $_lkup->{$_pkg};
      delete $_last_task_id->{$_pkg};

      delete $_user_tasks->{$_pkg};
      delete $_prev_c->{$_pkg};
      delete $_prev_n->{$_pkg};
      delete $_prev_t->{$_pkg};
      delete $_prev_w->{$_pkg};
      delete $_MCE->{$_pkg};

      if (defined $_queue->{$_pkg}) {
         local $_;
         $_->DESTROY() for (@{ $_queue->{$_pkg} });
         delete $_queue->{$_pkg};
      }
   }

   @_ = ();

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Parallel step with MCE -- file.
##
###############################################################################

sub run_file (@) {

   shift if (defined $_[0] && $_[0] eq 'MCE::Step');

   my ($_file, $_pos); my $_start_pos = (ref $_[0] eq 'HASH') ? 2 : 1;
   my $_pid = "$$.$_tid.".caller();

   if (defined (my $_p = $_params->{$_pid})) {
      delete $_p->{input_data} if (exists $_p->{input_data});
      delete $_p->{sequence}   if (exists $_p->{sequence});
   }
   else {
      $_params->{$_pid} = {};
   }

   for my $_i ($_start_pos .. @_ - 1) {
      my $_r = ref $_[$_i];
      if ($_r eq '' || $_r eq 'SCALAR' || $_r =~ /^(?:GLOB|FileHandle|IO::)/) {
         $_file = $_[$_i]; $_pos = $_i;
         last;
      }
   }

   if (defined $_file && ref $_file eq '' && $_file ne '') {
      _croak("$_tag: ($_file) does not exist")      unless (-e $_file);
      _croak("$_tag: ($_file) is not readable")     unless (-r $_file);
      _croak("$_tag: ($_file) is not a plain file") unless (-f $_file);
      $_params->{$_pid}{_file} = $_file;
   }
   elsif (ref $_file eq 'SCALAR' || ref($_file) =~ /^(?:GLOB|FileHandle|IO::)/) {
      $_params->{$_pid}{_file} = $_file;
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
## Parallel step with MCE -- sequence.
##
###############################################################################

sub run_seq (@) {

   shift if (defined $_[0] && $_[0] eq 'MCE::Step');

   my ($_begin, $_end, $_pos); my $_start_pos = (ref $_[0] eq 'HASH') ? 2 : 1;
   my $_pid = "$$.$_tid.".caller();

   if (defined (my $_p = $_params->{$_pid})) {
      delete $_p->{sequence}   if (exists $_p->{sequence});
      delete $_p->{input_data} if (exists $_p->{input_data});
      delete $_p->{_file}      if (exists $_p->{_file});
   }
   else {
      $_params->{$_pid} = {};
   }

   for my $_i ($_start_pos .. @_ - 1) {
      my $_r = ref $_[$_i];

      if ($_r eq '' || $_r =~ /^Math::/ || $_r eq 'HASH' || $_r eq 'ARRAY') {
         $_pos = $_i;

         if ($_r eq '' || $_r =~ /^Math::/) {
            $_begin = $_[$_pos]; $_end = $_[$_pos + 1];
            $_params->{$_pid}{sequence} = [
               $_[$_pos], $_[$_pos + 1], $_[$_pos + 2], $_[$_pos + 3]
            ];
         }
         elsif ($_r eq 'HASH') {
            $_begin = $_[$_pos]->{begin}; $_end = $_[$_pos]->{end};
            $_params->{$_pid}{sequence} = $_[$_pos];
         }
         elsif ($_r eq 'ARRAY') {
            $_begin = $_[$_pos]->[0]; $_end = $_[$_pos]->[1];
            $_params->{$_pid}{sequence} = $_[$_pos];
         }

         last;
      }
   }

   _croak("$_tag: (sequence) is not specified or valid")
      unless (exists $_params->{$_pid}{sequence});
   _croak("$_tag: (begin) is not specified for sequence")
      unless (defined $_begin);
   _croak("$_tag: (end) is not specified for sequence")
      unless (defined $_end);

   $_params->{$_pid}{sequence_run} = undef;

   if (defined $_pos) {
      pop @_ for ($_pos .. @_ - 1);
   }

   return run(@_);
}

###############################################################################
## ----------------------------------------------------------------------------
## Parallel step with MCE.
##
###############################################################################

sub run (@) {

   shift if (defined $_[0] && $_[0] eq 'MCE::Step');

   my $_pkg = caller() eq 'MCE::Step' ? caller(1) : caller();
   my $_pid = "$$.$_tid.$_pkg";

   if (ref $_[0] eq 'HASH') {
      $_params->{$_pid} = {} unless defined $_params->{$_pid};
      for my $_p (keys %{ $_[0] }) {
         $_params->{$_pid}{$_p} = $_[0]->{$_p};
      }

      shift;
   }

   ## -------------------------------------------------------------------------

   my (@_code, @_name, @_thrs, @_wrks); my $_init_mce = 0; my $_pos = 0;

   %{ $_lkup->{$_pid} } = ();

   while (ref $_[0] eq 'CODE') {
      push @_code, $_[0];

      if (defined (my $_p = $_params->{$_pid})) {
         push @_name, (ref $_p->{task_name} eq 'ARRAY')
            ? $_p->{task_name}->[$_pos] : undef;
         push @_thrs, (ref $_p->{use_threads} eq 'ARRAY')
            ? $_p->{use_threads}->[$_pos] : undef;
         push @_wrks, (ref $_p->{max_workers} eq 'ARRAY')
            ? $_p->{max_workers}->[$_pos] : undef;
      }

      $_lkup->{$_pid}{ $_name[ $_pos ] } = $_pos if (defined $_name[ $_pos ]);

      $_init_mce = 1 if (
         !defined $_prev_c->{$_pid}[$_pos] ||
         $_prev_c->{$_pid}[$_pos] != $_code[$_pos]
      );

      $_init_mce = 1 if ($_prev_n->{$_pid}[$_pos] ne $_name[$_pos]);
      $_init_mce = 1 if ($_prev_t->{$_pid}[$_pos] ne $_thrs[$_pos]);
      $_init_mce = 1 if ($_prev_w->{$_pid}[$_pos] ne $_wrks[$_pos]);

      $_prev_c->{$_pid}[$_pos] = $_code[$_pos];
      $_prev_n->{$_pid}[$_pos] = $_name[$_pos];
      $_prev_t->{$_pid}[$_pos] = $_thrs[$_pos];
      $_prev_w->{$_pid}[$_pos] = $_wrks[$_pos];

      shift; $_pos++;
   }

   if (defined $_prev_c->{$_pid}[$_pos]) {
      pop @{ $_prev_c->{$_pid} } for ($_pos .. $#{ $_prev_c->{$_pid } });
      pop @{ $_prev_n->{$_pid} } for ($_pos .. $#{ $_prev_n->{$_pid } });
      pop @{ $_prev_t->{$_pid} } for ($_pos .. $#{ $_prev_t->{$_pid } });
      pop @{ $_prev_w->{$_pid} } for ($_pos .. $#{ $_prev_w->{$_pid } });

      $_init_mce = 1;
   }

   return unless (scalar @_code);

   ## -------------------------------------------------------------------------

   my $_input_data; my $_max_workers = $_def->{$_pkg}{MAX_WORKERS};
   my $_r = ref $_[0];

   if (@_ == 1 && $_r =~ /^(?:ARRAY|HASH|SCALAR|GLOB|FileHandle|IO::)/) {
      $_input_data = shift;
   }

   if (defined (my $_p = $_params->{$_pid})) {
      $_max_workers = MCE::_parse_max_workers($_p->{max_workers})
         if (exists $_p->{max_workers} && ref $_p->{max_workers} ne 'ARRAY');

      delete $_p->{sequence}   if (defined $_input_data || scalar @_);
      delete $_p->{user_func}  if (exists $_p->{user_func});
      delete $_p->{user_tasks} if (exists $_p->{user_tasks});
   }

   if (@_code > 1 && $_max_workers > 1) {
      $_max_workers = int($_max_workers / @_code + 0.5) + 1;
   }

   my $_chunk_size = MCE::_parse_chunk_size(
      $_def->{$_pkg}{CHUNK_SIZE}, $_max_workers, $_params->{$_pid},
      $_input_data, scalar @_
   );

   if (defined (my $_p = $_params->{$_pid})) {
      if (exists $_p->{_file}) {
         $_input_data = delete $_p->{_file};
      } else {
         $_input_data = $_p->{input_data} if exists $_p->{input_data};
      }
   }

   ## -------------------------------------------------------------------------

   MCE::_save_state($_MCE->{$_pid});

   if ($_init_mce || !exists $_queue->{$_pid}) {
      $_MCE->{$_pid}->shutdown() if (defined $_MCE->{$_pid});
      $_queue->{$_pid} = [] if (!defined $_queue->{$_pid});

      my $_Q = $_queue->{$_pid};
      pop(@{ $_Q })->DESTROY for (@_code .. @{ $_Q });

      push @{ $_Q }, MCE::Queue->new(await => 1)
         for (@{ $_Q } .. @_code - 2);

      $_last_task_id->{$_pid} = @_code - 1;

      ## must clear arrays for nested session to work with Perl < v5.14
      _gen_user_tasks($_pid,$_Q, [@_code],[@_name],[@_thrs],[@_wrks], $_chunk_size);

      @_code = @_name = @_thrs = @_wrks = ();

      my %_opts = (
         max_workers => $_max_workers, task_name => $_tag,
         user_tasks  => $_user_tasks->{$_pid}, task_end  => \&_task_end,
      );

      if (defined (my $_p = $_params->{$_pid})) {
         local $_;

         for (keys %{ $_p }) {
            next if ($_ eq 'max_workers' && ref $_p->{max_workers} eq 'ARRAY');
            next if ($_ eq 'task_name'   && ref $_p->{task_name}   eq 'ARRAY');
            next if ($_ eq 'use_threads' && ref $_p->{use_threads} eq 'ARRAY');

            next if ($_ eq 'chunk_size');
            next if ($_ eq 'input_data');
            next if ($_ eq 'sequence_run');
            next if ($_ eq 'task_end');

            _croak("$_tag: ($_) is not a valid constructor argument")
               unless (exists $MCE::_valid_fields_new{$_});

            $_opts{$_} = $_p->{$_};
         }
      }

      for my $_k (qw/ tmp_dir freeze thaw /) {
         $_opts{$_k} = $_def->{$_pkg}{uc($_k)}
            if (exists $_def->{$_pkg}{uc($_k)} && !exists $_opts{$_k});
      }

      $_MCE->{$_pid} = MCE->new(pkg => $_pkg, %_opts);
   }
   else {
      ## Workers may persist after running. Thus, updating the MCE instance.
      ## These options do not require respawning.
      if (defined (my $_p = $_params->{$_pid})) {
         for my $_k (qw(
            RS interval stderr_file stdout_file user_error user_output
            job_delay submit_delay on_post_exit on_post_run user_args
            flush_file flush_stderr flush_stdout gather max_retries
         )) {
            $_MCE->{$_pid}{$_k} = $_p->{$_k} if (exists $_p->{$_k});
         }
      }
   }

   ## -------------------------------------------------------------------------

   my @_a; my $_wa = wantarray; $_MCE->{$_pid}{gather} = \@_a if (defined $_wa);

   if (defined $_input_data) {
      @_ = ();
      $_MCE->{$_pid}->process({ chunk_size => $_chunk_size }, $_input_data);
      delete $_MCE->{$_pid}{input_data};
   }
   elsif (scalar @_) {
      $_MCE->{$_pid}->process({ chunk_size => $_chunk_size }, \@_);
      delete $_MCE->{$_pid}{input_data};
   }
   else {
      if (defined $_params->{$_pid} && exists $_params->{$_pid}{sequence}) {
         $_MCE->{$_pid}->run({
             chunk_size => $_chunk_size,
             sequence   => $_params->{$_pid}{sequence}
         }, 0);
         if (exists $_params->{$_pid}{sequence_run}) {
             delete $_params->{$_pid}{sequence_run};
             delete $_params->{$_pid}{sequence};
         }
         delete $_MCE->{$_pid}{sequence};
      }
      else {
         $_MCE->{$_pid}->run({ chunk_size => $_chunk_size }, 0);
      }
   }

   MCE::_restore_state();

   # destroy queue(s) if MCE::run requested workers to shutdown
   if (!$_MCE->{$_pid}{_spawned}) {
      $_->DESTROY() for @{ $_queue->{$_pid} };
      delete $_queue->{$_pid};
   }

   delete $_MCE->{$_pid}{gather} if (defined $_wa);

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

sub _gen_user_func {

   my ($_qref, $_cref, $_chunk_size, $_pos) = @_;

   my $_q_in = $_qref->[$_pos - 1];
   my $_code = $_cref->[$_pos];

   return sub {
      my ($_mce) = @_;

      $_mce->{_next_jmp} = sub { goto _MCE_STEP__NEXT; };
      $_mce->{_last_jmp} = sub { goto _MCE_STEP__LAST; };

      _MCE_STEP__NEXT:

      while (defined (local $_ = $_q_in->dequeue())) {
         my $_args = $_mce->thaw($_);  $_ = $_args->[0];
         $_code->($_mce, @{ $_args });
      }

      _MCE_STEP__LAST:

      return;
   };
}

sub _gen_user_tasks {

   my ($_pid, $_qref, $_cref, $_nref, $_tref, $_wref, $_chunk_size) = @_;

   @{ $_user_tasks->{$_pid} } = ();

   push @{ $_user_tasks->{$_pid} }, {
      task_name   => $_nref->[0],
      use_threads => $_tref->[0],
      max_workers => $_wref->[0],
      user_func   => sub { $_cref->[0]->(@_); return; }
   };

   for my $_pos (1 .. @{ $_cref } - 1) {
      push @{ $_user_tasks->{$_pid} }, {
         task_name   => $_nref->[$_pos],
         use_threads => $_tref->[$_pos],
         max_workers => $_wref->[$_pos],
         user_func   => _gen_user_func(
            $_qref, $_cref, $_chunk_size, $_pos
         )
      };
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

MCE::Step - Parallel step model for building creative steps

=head1 VERSION

This document describes MCE::Step version 1.879

=head1 DESCRIPTION

MCE::Step is similar to L<MCE::Flow> for writing custom apps. The main
difference comes from the transparent use of queues between sub-tasks.
MCE 1.7 adds mce_enq, mce_enqp, and mce_await methods described under
QUEUE-LIKE FEATURES below.

It is trivial to parallelize with mce_stream shown below.

 ## Native map function
 my @a = map { $_ * 4 } map { $_ * 3 } map { $_ * 2 } 1..10000;

 ## Same as with MCE::Stream (processing from right to left)
 @a = mce_stream
      sub { $_ * 4 }, sub { $_ * 3 }, sub { $_ * 2 }, 1..10000;

 ## Pass an array reference to have writes occur simultaneously
 mce_stream \@a,
      sub { $_ * 4 }, sub { $_ * 3 }, sub { $_ * 2 }, 1..10000;

However, let's have MCE::Step compute the same in parallel. Unlike the example
in L<MCE::Flow>, the use of MCE::Queue is totally transparent. This calls for
preserving output order provided by MCE::Candy.

 use MCE::Step;
 use MCE::Candy;

Next are the 3 sub-tasks. Compare these 3 sub-tasks with the same as described
in L<MCE::Flow>. The call to MCE->step simplifies the passing of data to
subsequent sub-task.

 sub task_a {
    my @ans; my ($mce, $chunk_ref, $chunk_id) = @_;
    push @ans, map { $_ * 2 } @{ $chunk_ref };
    MCE->step(\@ans, $chunk_id);
 }

 sub task_b {
    my @ans; my ($mce, $chunk_ref, $chunk_id) = @_;
    push @ans, map { $_ * 3 } @{ $chunk_ref };
    MCE->step(\@ans, $chunk_id);
 }

 sub task_c {
    my @ans; my ($mce, $chunk_ref, $chunk_id) = @_;
    push @ans, map { $_ * 4 } @{ $chunk_ref };
    MCE->gather($chunk_id, \@ans);
 }

In summary, MCE::Step builds out a MCE instance behind the scene and starts
running. The task_name (shown), max_workers, and use_threads options can take
an anonymous array for specifying the values uniquely per each sub-task.

The task_name option is required to use ->enq, ->enqp, and ->await.

 my @a;

 mce_step {
    task_name => [ 'a', 'b', 'c' ],
    gather => MCE::Candy::out_iter_array(\@a)

 }, \&task_a, \&task_b, \&task_c, 1..10000;

 print "@a\n";

=head1 STEP DEMO

In the demonstration below, one may call ->gather or ->step any number of times
although ->step is not allowed in the last sub-block. Data is gathered to @arr
which may likely be out-of-order. Gathering data is optional. All sub-blocks
receive $mce as the first argument.

First, defining 3 sub-tasks.

 use MCE::Step;

 sub task_a {
    my ($mce, $chunk_ref, $chunk_id) = @_;

    if ($_ % 2 == 0) {
       MCE->gather($_);
     # MCE->gather($_ * 4);        ## Ok to gather multiple times
    }
    else {
       MCE->print("a step: $_, $_ * $_\n");
       MCE->step($_, $_ * $_);
     # MCE->step($_, $_ * 4 );     ## Ok to step multiple times
    }
 }

 sub task_b {
    my ($mce, $arg1, $arg2) = @_;

    MCE->print("b args: $arg1, $arg2\n");

    if ($_ % 3 == 0) {             ## $_ is the same as $arg1
       MCE->gather($_);
    }
    else {
       MCE->print("b step: $_ * $_\n");
       MCE->step($_ * $_);
    }
 }

 sub task_c {
    my ($mce, $arg1) = @_;

    MCE->print("c: $_\n");
    MCE->gather($_);
 }

Next, pass MCE options, using chunk_size 1, and run all 3 tasks in parallel.
Notice how max_workers and use_threads can take an anonymous array, similarly
to task_name.

 my @arr = mce_step {
    task_name   => [ 'a', 'b', 'c' ],
    max_workers => [  2,   2,   2  ],
    use_threads => [  0,   0,   0  ],
    chunk_size  => 1

 }, \&task_a, \&task_b, \&task_c, 1..10;

Finally, sort the array and display its contents.

 @arr = sort { $a <=> $b } @arr;

 print "\n@arr\n\n";

 -- Output

 a step: 1, 1 * 1
 a step: 3, 3 * 3
 a step: 5, 5 * 5
 a step: 7, 7 * 7
 a step: 9, 9 * 9
 b args: 1, 1
 b step: 1 * 1
 b args: 3, 9
 b args: 7, 49
 b step: 7 * 7
 b args: 5, 25
 b step: 5 * 5
 b args: 9, 81
 c: 1
 c: 49
 c: 25

 1 2 3 4 6 8 9 10 25 49

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

 ## Exports mce_step, mce_step_f, and mce_step_s
 use MCE::Step;

 MCE::Step->init(
    chunk_size => 1
 );

 ## Array or array_ref
 mce_step sub { do_work($_) }, 1..10000;
 mce_step sub { do_work($_) }, \@list;

 ## Important; pass an array_ref for deeply input data
 mce_step sub { do_work($_) }, [ [ 0, 1 ], [ 0, 2 ], ... ];
 mce_step sub { do_work($_) }, \@deeply_list;

 ## File path, glob ref, IO::All::{ File, Pipe, STDIO } obj, or scalar ref
 ## Workers read directly and not involve the manager process
 mce_step_f sub { chomp; do_work($_) }, "/path/to/file"; # efficient

 ## Involves the manager process, therefore slower
 mce_step_f sub { chomp; do_work($_) }, $file_handle;
 mce_step_f sub { chomp; do_work($_) }, $io;
 mce_step_f sub { chomp; do_work($_) }, \$scalar;

 ## Sequence of numbers (begin, end [, step, format])
 mce_step_s sub { do_work($_) }, 1, 10000, 5;
 mce_step_s sub { do_work($_) }, [ 1, 10000, 5 ];

 mce_step_s sub { do_work($_) }, {
    begin => 1, end => 10000, step => 5, format => undef
 };

=head1 SYNOPSIS when CHUNK_SIZE is GREATER THAN 1

Follow this synopsis when chunk_size equals 'auto' or greater than 1.
This means having to loop through the chunk from inside the first block.

 use MCE::Step;

 MCE::Step->init(           ## Chunk_size defaults to 'auto' when
    chunk_size => 'auto'    ## not specified. Therefore, the init
 );                         ## function may be omitted.

 ## Syntax is shown for mce_step for demonstration purposes.
 ## Looping inside the block is the same for mce_step_f and
 ## mce_step_s.

 ## Array or array_ref
 mce_step sub { do_work($_) for (@{ $_ }) }, 1..10000;
 mce_step sub { do_work($_) for (@{ $_ }) }, \@list;

 ## Important; pass an array_ref for deeply input data
 mce_step sub { do_work($_) for (@{ $_ }) }, [ [ 0, 1 ], [ 0, 2 ], ... ];
 mce_step sub { do_work($_) for (@{ $_ }) }, \@deeply_list;

 ## Resembles code using the core MCE API
 mce_step sub {
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
The fast option is obsolete in 1.867 onwards; ignored if specified.

 use Sereal qw( encode_sereal decode_sereal );
 use CBOR::XS qw( encode_cbor decode_cbor );
 use JSON::XS qw( encode_json decode_json );

 use MCE::Step
     max_workers => 8,                # Default 'auto'
     chunk_size => 500,               # Default 'auto'
     tmp_dir => "/path/to/app/tmp",   # $MCE::Signal::tmp_dir
     freeze => \&encode_sereal,       # \&Storable::freeze
     thaw => \&decode_sereal,         # \&Storable::thaw
     fast => 1                        # Default 0 (fast dequeue)
 ;

From MCE 1.8 onwards, Sereal 3.015+ is loaded automatically if available.
Specify C<< Sereal => 0 >> to use Storable instead.

 use MCE::Step Sereal => 0;

=head1 CUSTOMIZING MCE

=over 3

=item MCE::Step->init ( options )

=item MCE::Step::init { options }

=back

The init function accepts a hash of MCE options. Unlike with MCE::Stream,
both gather and bounds_only options may be specified when calling init
(not shown below).

 use MCE::Step;

 MCE::Step->init(
    chunk_size => 1, max_workers => 4,

    user_begin => sub {
       print "## ", MCE->wid, " started\n";
    },

    user_end => sub {
       print "## ", MCE->wid, " completed\n";
    }
 );

 my %a = mce_step sub { MCE->gather($_, $_ * $_) }, 1..100;

 print "\n", "@a{1..100}", "\n";

 -- Output

 ## 3 started
 ## 1 started
 ## 4 started
 ## 2 started
 ## 3 completed
 ## 4 completed
 ## 1 completed
 ## 2 completed

 1 4 9 16 25 36 49 64 81 100 121 144 169 196 225 256 289 324 361
 400 441 484 529 576 625 676 729 784 841 900 961 1024 1089 1156
 1225 1296 1369 1444 1521 1600 1681 1764 1849 1936 2025 2116 2209
 2304 2401 2500 2601 2704 2809 2916 3025 3136 3249 3364 3481 3600
 3721 3844 3969 4096 4225 4356 4489 4624 4761 4900 5041 5184 5329
 5476 5625 5776 5929 6084 6241 6400 6561 6724 6889 7056 7225 7396
 7569 7744 7921 8100 8281 8464 8649 8836 9025 9216 9409 9604 9801
 10000

Like with MCE::Step->init above, MCE options may be specified using an
anonymous hash for the first argument. Notice how task_name, max_workers,
and use_threads can take an anonymous array for setting uniquely per
each code block.

Unlike MCE::Stream which processes from right-to-left, MCE::Step begins
with the first code block, thus processing from left-to-right.

The following takes 9 seconds to complete. The 9 seconds is from having
only 2 workers assigned for the last sub-task and waiting 1 or 2 seconds
initially before calling MCE->step.

Removing both calls to MCE->step will cause the script to complete in just
1 second. The reason is due to the 2nd and subsequent sub-tasks awaiting
data from an internal queue. Workers terminate upon receiving an undef.

 use threads;
 use MCE::Step;

 my @a = mce_step {
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
 sub { sleep 1; MCE->step(""); },   ## 3 workers, named a
 sub { sleep 2; MCE->step(""); },   ## 4 workers, named b
 sub { sleep 3;                };   ## 2 workers, named c

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

Although input data is optional for MCE::Step, the following assumes chunk_size
equals 1 in order to demonstrate all the possibilities for providing input data.

=over 3

=item MCE::Step->run ( sub { code }, list )

=item mce_step sub { code }, list

=back

Input data may be defined using a list, an array ref, or a hash ref.

Unlike MCE::Loop, Map, and Grep which take a block as C<{ ... }>, Step takes a
C<sub { ... }> or a code reference. The other difference is that the comma is
needed after the block.

 # $_ contains the item when chunk_size => 1

 mce_step sub { do_work($_) }, 1..1000;
 mce_step sub { do_work($_) }, \@list;

 # Important; pass an array_ref for deeply input data

 mce_step sub { do_work($_) }, [ [ 0, 1 ], [ 0, 2 ], ... ];
 mce_step sub { do_work($_) }, \@deeply_list;

 # Chunking; any chunk_size => 1 or greater

 my %res = mce_step sub {
    my ($mce, $chunk_ref, $chunk_id) = @_;
    my %ret;
    for my $item (@{ $chunk_ref }) {
       $ret{$item} = $item * 2;
    }
    MCE->gather(%ret);
 },
 \@list;

 # Input hash; current API available since 1.828

 my %res = mce_step sub {
    my ($mce, $chunk_ref, $chunk_id) = @_;
    my %ret;
    for my $key (keys %{ $chunk_ref }) {
       $ret{$key} = $chunk_ref->{$key} * 2;
    }
    MCE->gather(%ret);
 },
 \%hash;

 # Unlike MCE::Loop, MCE::Step doesn't need input to run

 mce_step { max_workers => 4 }, sub {
    MCE->say( MCE->wid );
 };

 # ... and can run multiple tasks

 mce_step {
    max_workers => [  1,   3  ],
    task_name   => [ 'p', 'c' ]
 },
 sub {
    # 1 producer
    MCE->say( "producer: ", MCE->wid );
 },
 sub {
    # 3 consumers
    MCE->say( "consumer: ", MCE->wid );
 };

 # Here, options are specified via init

 MCE::Step->init(
    max_workers => [  1,   3  ],
    task_name   => [ 'p', 'c' ]
 );

 mce_step \&producer, \&consumers;

=over 3

=item MCE::Step->run_file ( sub { code }, file )

=item mce_step_f sub { code }, file

=back

The fastest of these is the /path/to/file. Workers communicate the next offset
position among themselves with zero interaction by the manager process.

C<IO::All> { File, Pipe, STDIO } is supported since MCE 1.845.

 # $_ contains the line when chunk_size => 1

 mce_step_f sub { $_ }, "/path/to/file";  # faster
 mce_step_f sub { $_ }, $file_handle;
 mce_step_f sub { $_ }, $io;              # IO::All
 mce_step_f sub { $_ }, \$scalar;

 # chunking, any chunk_size => 1 or greater

 my %res = mce_step_f sub {
    my ($mce, $chunk_ref, $chunk_id) = @_;
    my $buf = '';
    for my $line (@{ $chunk_ref }) {
       $buf .= $line;
    }
    MCE->gather($chunk_id, $buf);
 },
 "/path/to/file";

=over 3

=item MCE::Step->run_seq ( sub { code }, $beg, $end [, $step, $fmt ] )

=item mce_step_s sub { code }, $beg, $end [, $step, $fmt ]

=back

Sequence may be defined as a list, an array reference, or a hash reference.
The functions require both begin and end values to run. Step and format are
optional. The format is passed to sprintf (% may be omitted below).

 my ($beg, $end, $step, $fmt) = (10, 20, 0.1, "%4.1f");

 # $_ contains the sequence number when chunk_size => 1

 mce_step_s sub { $_ }, $beg, $end, $step, $fmt;
 mce_step_s sub { $_ }, [ $beg, $end, $step, $fmt ];

 mce_step_s sub { $_ }, {
    begin => $beg, end => $end,
    step => $step, format => $fmt
 };

 # chunking, any chunk_size => 1 or greater

 my %res = mce_step_s sub {
    my ($mce, $chunk_ref, $chunk_id) = @_;
    my $buf = '';
    for my $seq (@{ $chunk_ref }) {
       $buf .= "$seq\n";
    }
    MCE->gather($chunk_id, $buf);
 },
 [ $beg, $end ];

The sequence engine can compute 'begin' and 'end' items only, for the chunk,
and not the items in between (hence boundaries only). This option applies
to sequence only and has no effect when chunk_size equals 1.

The time to run is 0.006s below. This becomes 0.827s without the bounds_only
option due to computing all items in between, thus creating a very large
array. Basically, specify bounds_only => 1 when boundaries is all you need
for looping inside the block; e.g. Monte Carlo simulations.

Time was measured using 1 worker to emphasize the difference.

 use MCE::Step;

 MCE::Step->init(
    max_workers => 1, chunk_size => 1_250_000,
    bounds_only => 1
 );

 # Typically, the input scalar $_ contains the sequence number
 # when chunk_size => 1, unless the bounds_only option is set
 # which is the case here. Thus, $_ points to $chunk_ref.

 mce_step_s sub {
    my ($mce, $chunk_ref, $chunk_id) = @_;

    # $chunk_ref contains 2 items, not 1_250_000
    # my ( $begin, $end ) = ( $_->[0], $_->[1] );

    my $begin = $chunk_ref->[0];
    my $end   = $chunk_ref->[1];

    # for my $seq ( $begin .. $end ) {
    #    ...
    # }

    MCE->printf("%7d .. %8d\n", $begin, $end);
 },
 [ 1, 10_000_000 ];

 -- Output

       1 ..  1250000
 1250001 ..  2500000
 2500001 ..  3750000
 3750001 ..  5000000
 5000001 ..  6250000
 6250001 ..  7500000
 7500001 ..  8750000
 8750001 .. 10000000

=over 3

=item MCE::Step->run ( { input_data => iterator }, sub { code } )

=item mce_step { input_data => iterator }, sub { code }

=back

An iterator reference may be specified for input_data. The only other way
is to specify input_data via MCE::Step->init. This prevents MCE::Step from
configuring the iterator reference as another user task which will not work.

Iterators are described under section "SYNTAX for INPUT_DATA" at L<MCE::Core>.

 MCE::Step->init(
    input_data => iterator
 );

 mce_step sub { $_ };

=head1 QUEUE-LIKE FEATURES

=over 3

=item MCE->step ( item )

=item MCE->step ( arg1, arg2, argN )

=back

The ->step method is the simplest form for passing elements into the next
sub-task.

 use MCE::Step;

 sub provider {
    MCE->step( $_, rand ) for 10 .. 19;
 }

 sub consumer {
    my ( $mce, @args ) = @_;
    MCE->printf( "%d: %d, %03.06f\n", MCE->wid, $args[0], $args[1] );
 }

 MCE::Step->init(
    task_name   => [ 'p', 'c' ],
    max_workers => [  1 ,  4  ]
 );

 mce_step \&provider, \&consumer;

 -- Output

 2: 10, 0.583551
 4: 11, 0.175319
 3: 12, 0.843662
 4: 15, 0.748302
 2: 14, 0.591752
 3: 16, 0.357858
 5: 13, 0.953528
 4: 17, 0.698907
 2: 18, 0.985448
 3: 19, 0.146548

=over 3

=item MCE->enq ( task_name, item )

=item MCE->enq ( task_name, [ arg1, arg2, argN ] )

=item MCE->enq ( task_name, [ arg1, arg2 ], [ arg1, arg2 ] )

=item MCE->enqp ( task_name, priority, item )

=item MCE->enqp ( task_name, priority, [ arg1, arg2, argN ] )

=item MCE->enqp ( task_name, priority, [ arg1, arg2 ], [ arg1, arg2 ] )

=back

The MCE 1.7 release enables finer control. Unlike ->step, which take multiple
arguments, the ->enq and ->enqp methods push items at the end of the array
internally. Passing multiple arguments is possible by enclosing the arguments
inside an anonymous array.

The direction of flow is forward only. Thus, stepping to itself or backwards
will cause an error.

 use MCE::Step;

 sub provider {
    if ( MCE->wid % 2 == 0 ) {
       MCE->enq( 'c', [ $_, rand ] ) for 10 .. 19;
    } else {
       MCE->enq( 'd', [ $_, rand ] ) for 20 .. 29;
    }
 }

 sub consumer_c {
    my ( $mce, $args ) = @_;
    MCE->printf( "C%d: %d, %03.06f\n", MCE->wid, $args->[0], $args->[1] );
 }

 sub consumer_d {
    my ( $mce, $args ) = @_;
    MCE->printf( "D%d: %d, %03.06f\n", MCE->wid, $args->[0], $args->[1] );
 }

 MCE::Step->init(
    task_name   => [ 'p', 'c', 'd' ],
    max_workers => [  2 ,  3 ,  3  ]
 );

 mce_step \&provider, \&consumer_c, \&consumer_d;

 -- Output

 C4: 10, 0.527531
 D6: 20, 0.420108
 C5: 11, 0.839770
 D8: 21, 0.386414
 C3: 12, 0.834645
 C4: 13, 0.191014
 D6: 23, 0.924027
 C5: 14, 0.899357
 D8: 24, 0.706186
 C4: 15, 0.083823
 D7: 22, 0.479708
 D6: 25, 0.073882
 C3: 16, 0.207446
 D8: 26, 0.560755
 C5: 17, 0.198157
 D7: 27, 0.324909
 C4: 18, 0.147505
 C5: 19, 0.318371
 D6: 28, 0.220465
 D8: 29, 0.630111

=over 3

=item MCE->await ( task_name, pending_threshold )

=back

Providers may sometime run faster than consumers. Thus, increasing memory
consumption. MCE 1.7 adds the ->await method for pausing momentarily until
the receiving sub-task reaches the minimum threshold for the number of
items pending in its queue.

 use MCE::Step;
 use Time::HiRes 'sleep';

 sub provider {
    for ( 10 .. 29 ) {
       # wait until 10 or less items pending
       MCE->await( 'c', 10 );
       # forward item to a later sub-task ( 'c' comes after 'p' )
       MCE->enq( 'c', [ $_, rand ] );
    }
 }

 sub consumer {
    my ($mce, $args) = @_;
    MCE->printf( "%d: %d, %03.06f\n", MCE->wid, $args->[0], $args->[1] );
    sleep 0.05;
 }

 MCE::Step->init(
    task_name   => [ 'p', 'c' ],
    max_workers => [  1 ,  4  ]
 );

 mce_step \&provider, \&consumer;

 -- Output

 3: 10, 0.527307
 2: 11, 0.036193
 5: 12, 0.987168
 4: 13, 0.998140
 5: 14, 0.219526
 4: 15, 0.061609
 2: 16, 0.557664
 3: 17, 0.658684
 4: 18, 0.240932
 3: 19, 0.241042
 5: 20, 0.884830
 2: 21, 0.902223
 4: 22, 0.699223
 3: 23, 0.208270
 5: 24, 0.438919
 2: 25, 0.268854
 4: 26, 0.596425
 5: 27, 0.979818
 2: 28, 0.918173
 3: 29, 0.358266

=head1 GATHERING DATA

Unlike MCE::Map where gather and output order are done for you automatically,
the gather method is used to have results sent back to the manager process.

 use MCE::Step chunk_size => 1;

 ## Output order is not guaranteed.
 my @a = mce_step sub { MCE->gather($_ * 2) }, 1..100;
 print "@a\n\n";

 ## Outputs to a hash instead (key, value).
 my %h1 = mce_step sub { MCE->gather($_, $_ * 2) }, 1..100;
 print "@h1{1..100}\n\n";

 ## This does the same thing due to chunk_id starting at one.
 my %h2 = mce_step sub { MCE->gather(MCE->chunk_id, $_ * 2) }, 1..100;
 print "@h2{1..100}\n\n";

The gather method may be called multiple times within the block unlike return
which would leave the block. Therefore, think of gather as yielding results
immediately to the manager process without actually leaving the block.

 use MCE::Step chunk_size => 1, max_workers => 3;

 my @hosts = qw(
    hosta hostb hostc hostd hoste
 );

 my %h3 = mce_step sub {
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

 my %h3 = mce_step sub {
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

 use MCE::Step;

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
 ## workers must persist; e.g. mce_step { ... }, \&foo, 1..100000.

 MCE::Step->init(
    chunk_size => 'auto', max_workers => 'auto'
 );

 for (1..2) {
    my @m2;

    mce_step {
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

 MCE::Step->finish;

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

=item MCE::Step->finish

=item MCE::Step::finish

=back

Workers remain persistent as much as possible after running. Shutdown occurs
automatically when the script terminates. Call finish when workers are no
longer needed.

 use MCE::Step;

 MCE::Step->init(
    chunk_size => 20, max_workers => 'auto'
 );

 mce_step sub { ... }, 1..100;

 MCE::Step->finish;

=head1 INDEX

L<MCE|MCE>, L<MCE::Core>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

