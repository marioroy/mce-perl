###############################################################################
## ----------------------------------------------------------------------------
## A threads-like parallelization module.
##
###############################################################################

package MCE::Hobo;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized redefine );

our $VERSION = '1.700';

## no critic (BuiltinFunctions::ProhibitStringyEval)
## no critic (Subroutines::ProhibitExplicitReturnUndef)
## no critic (Subroutines::ProhibitSubroutinePrototypes)
## no critic (TestingAndDebugging::ProhibitNoStrict)

use Carp ();

my $_has_threads;

BEGIN {
   if ($^O eq 'MSWin32' && !defined $threads::VERSION) {
      local $@; local $SIG{__DIE__} = sub { };
      eval 'use threads; use threads::shared';
   }
   elsif (defined $threads::VERSION) {
      unless (defined $threads::shared::VERSION) {
         local $@; local $SIG{__DIE__} = sub { };
         eval 'use threads::shared';
      }
   }

   $_has_threads = $INC{'threads/shared.pm'} ? 1 : 0;
}

use Time::HiRes qw(sleep);
use Storable ();
use bytes;

use MCE::Shared::Ordhash;
use MCE::Shared::Hash;
use MCE::Shared ();

use overload (
   q(==)    => \&equal,
   q(!=)    => sub { !equal(@_) },
   fallback => 1
);

my $_tid = $INC{'threads.pm'} ? threads->tid() : 0;
my $_EXT_LOCK : shared = 1;

my $_FREEZE = \&Storable::freeze;
my $_THAW   = \&Storable::thaw;
my $_imported;

sub CLONE { $_tid = threads->tid() }

END { finish() }

sub import {
   my $_class = shift;

   { no strict 'refs'; *{ caller().'::mce_async' } = \&async; }

   return if $_imported++;

   while ( my $_argument = shift ) {
      my $_arg = lc $_argument;

      $_FREEZE = shift, next if ( $_arg eq 'freeze' );
      $_THAW   = shift, next if ( $_arg eq 'thaw' );

      if ( $_arg eq 'sereal' ) {
         if (shift eq '1') {
            local $@; eval 'use Sereal qw(encode_sereal decode_sereal)';
            $_FREEZE = \&encode_sereal, $_THAW = \&decode_sereal unless $@;
         }
         next;
      }

      _croak("Error: ($_argument) invalid module option");
   }

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## 'new', 'async (mce_async)', and 'create' for threads-like similarity.
##
###############################################################################

my ($_SELF, $_LIST, $_STAT, $_DATA);

bless $_SELF = {
   MGR_ID => "$$.$_tid", WRK_ID => "$$.$_tid", PID => $$
}, 'MCE::Hobo';

## 'new' is an alias for 'create'

*new = \&create;

## Use "goto" trick to avoid pad problems from 5.8.1 (fixed in 5.8.2)
## Applies same tip found in threads::async.

sub async (&;@) {
   unless (defined $_[0] && $_[0] eq 'MCE::Hobo') {
      unshift(@_, 'MCE::Hobo');
   }
   goto &create;
}

sub create {
   my $class  = shift;
   my $self   = ref($_[0]) eq 'HASH' ? shift : {};
   my $func   = shift;
   my $mgr_id = "$$.$_tid";

   $self->{MGR_ID} = $mgr_id;

   bless $self, $class;

   ## error checking -- --- --- --- --- --- --- --- --- --- --- --- --- --- ---

   if ($^O eq 'MSWin32' && $INC{'MCE.pm'} && MCE->wid()) {
      my $m = "running MCE::Hobo by MCE Worker is not supported on MSWin32";
      print {*STDERR} "$m\n";

      return undef;
   }

   if (ref($func) ne 'CODE' && !length($func)) {
      print {*STDERR} "FUNCTION is not specified or valid\n";

      return undef;
   }
   else {
      $func = "main::$func" if (!ref($func) && index($func, ':') < 0);
   }

   ## one time setup
   $_LIST = MCE::Shared::Ordhash->new() unless defined $_LIST;

   unless (defined $_DATA) {
      $_DATA = MCE::Shared::Hash->new();            # non-shared
      $_STAT = MCE::Shared::Hash->new();
   }

   unless ($_DATA->exists($mgr_id)) {
      MCE::Shared::start();
      $_DATA->set( $mgr_id, MCE::Shared->hash() );  # shared
      $_STAT->set( $mgr_id, MCE::Shared->hash() );
      $_STAT->set("$mgr_id:id", 0 );
   }

   ## spawn a hobo process  --- --- --- --- --- --- --- --- --- --- --- --- ---

   my $_id = $_STAT->incr("$mgr_id:id");
   my $pid = fork();

   if (!defined $pid) {
      print {*STDERR} "fork error: $!\n";

      return undef;
   }
   elsif ($pid) {                                   # parent
      my $wrk_id = "$pid.$_tid";
      $self->{WRK_ID} = $wrk_id, $self->{PID} = $pid;
      $_LIST->set($wrk_id, $self);

      return $self;
   }
   else {                                           # child
      my $wrk_id = "$$.$_tid";
      local $| = 1;

      $SIG{QUIT} = \&_exit; $SIG{TERM} = $SIG{INT} = $SIG{HUP} = \&_trap;
      MCE::Shared::init() if (! $INC{'MCE.pm'} || ! MCE->wid());

      $_SELF = $self, $_SELF->{WRK_ID} = $wrk_id, $_SELF->{PID} = $$;
      $_LIST = undef;

      ## Sets the seed of the base generator uniquely between processes.
      ## The new seed is computed using the current seed and $_id value.
      ## Thus, okay to set the seed at the application level for
      ## predictable results.

      if ($INC{'Math/Random.pm'}) {
         my $cur_seed = Math::Random::random_get_seed();

         my $new_seed = ($cur_seed < 1073741781)
            ? $cur_seed + ((abs($_id) * 10000) % 1073741780)
            : $cur_seed - ((abs($_id) * 10000) % 1073741780);

         Math::Random::random_set_seed($new_seed, $new_seed);
      }

      ## Run.
      $_STAT->get($mgr_id)->set($wrk_id, "running");
      my @result = eval { no strict 'refs'; $func->(@_) };

      $_DATA->get($mgr_id)->set($wrk_id, $_FREEZE->(\@result));
      $_STAT->get($mgr_id)->set($wrk_id, "joinable: $@");

      _exit();
   }
}

###############################################################################
## ----------------------------------------------------------------------------
## Public methods.
##
###############################################################################

sub equal {
   return 0 unless ref($_[0]) && ref($_[1]);
   $_[0]->{PID} == $_[1]->{PID} ? 1 : 0;
}

sub error {
   _croak('Usage: $hobo->error()') unless ref($_[0]);
   $_[0]->{ERROR} || undef;
}

sub exit {
   shift if (defined $_[0] && $_[0] eq 'MCE::Hobo');

   my ($self) = (ref($_[0]) ? shift : $_SELF);
   my $mgr_id = $self->{MGR_ID};
   my $wrk_id = $self->{WRK_ID};

   if ($mgr_id eq "$$.$_tid" && $mgr_id ne $wrk_id) {
      return $self if (exists $self->{JOINED});
      sleep 0.01 until $_STAT->get($mgr_id)->exists($wrk_id);
      sleep(0.01), CORE::kill('QUIT', $self->{PID});

      $self;
   }
   elsif ($mgr_id ne $wrk_id) {
      $_STAT->get($mgr_id)->set($wrk_id, "joinable: ");
      _exit();
   }
   else {
      CORE::exit(@_);
   }
}

sub finish {
   _croak('Usage: MCE::Hobo->finish()') if ref($_[0]);

   if (defined $_LIST) {
      return if ($INC{'MCE/Signal.pm'} && $MCE::Signal::KILLED);
      return if ($MCE::Shared::Server::KILLED);

      _croak('Finished with active hobos') if $_LIST->len;

      my $mgr_id = "$$.$_tid";
      $_LIST = undef;

      if (defined $_DATA && $_DATA->exists($mgr_id)) {
         $_DATA->del( $mgr_id )->destroy;
         $_STAT->del( $mgr_id )->destroy;
         $_STAT->del("$mgr_id:id");
      }
   }

   return;
}

sub is_joinable {
   _croak('Usage: $hobo->is_joinable()') unless ref($_[0]);

   my ($self) = @_;
   my $mgr_id = $self->{MGR_ID};
   my $wrk_id = $self->{WRK_ID};

   if ($mgr_id eq "$$.$_tid" && $mgr_id ne $wrk_id) {
      return undef if (exists $self->{JOINED});
      sleep 0.01 until $_STAT->get($mgr_id)->exists($wrk_id);

      ($_STAT->get($mgr_id)->get($wrk_id) =~ /^joinable/) ? 1 : '';
   }
   else {
      '';
   }
}

sub is_running {
   _croak('Usage: $hobo->is_running()') unless ref($_[0]);

   my ($self) = @_;
   my $mgr_id = $self->{MGR_ID};
   my $wrk_id = $self->{WRK_ID};

   if ($mgr_id eq "$$.$_tid" && $mgr_id ne $wrk_id) {
      return undef if (exists $self->{JOINED});
      sleep 0.01 until $_STAT->get($mgr_id)->exists($wrk_id);

      ($_STAT->get($mgr_id)->get($wrk_id) eq "running") ? 1 : '';
   }
   else {
      1;
   }
}

sub join {
   _croak('Usage: $hobo->join()') unless ref($_[0]);

   my ($self) = @_;
   my $mgr_id = $self->{MGR_ID};
   my $wrk_id = $self->{WRK_ID};

   if ($mgr_id eq "$$.$_tid" && $mgr_id ne $wrk_id) {
      if (exists $self->{JOINED}) {
         (defined wantarray)
            ? wantarray ? @{ $self->{RESULT} } : $self->{RESULT}->[-1]
            : ();
      }
      else {
         waitpid($self->{PID}, 0);

         my $result = $_DATA->get($mgr_id)->del($wrk_id);
         my $error  = $_STAT->get($mgr_id)->del($wrk_id);

         $self->{ERROR}  = (length $error > 10) ? substr($error, 10) : "";
         $self->{RESULT} = (defined $result) ? $_THAW->($result) : [];
         $self->{JOINED} = 1;

         $_LIST->del($wrk_id);

         (defined wantarray)
            ? wantarray ? @{ $self->{RESULT} } : $self->{RESULT}->[-1]
            : ();
      }
   }
   elsif ($mgr_id ne $wrk_id) {
      _croak('Cannot join manager process');
   }
   else {
      _croak('Cannot join self');
   }
}

sub kill {
   _croak('Usage: $hobo->kill()') unless ref($_[0]);

   my ($self, $signal) = @_;
   my $mgr_id = $self->{MGR_ID};
   my $wrk_id = $self->{WRK_ID};

   if ($mgr_id eq "$$.$_tid" && $mgr_id ne $wrk_id) {
      return $self if (exists $self->{JOINED});
      sleep 0.01 until $_STAT->get($mgr_id)->exists($wrk_id);
      sleep(0.01), CORE::kill($signal || 'INT', $self->{PID});
   }
   else {
      CORE::kill($signal || 'INT', $self->{PID});
   }

   $self;
}

sub list {
   _croak('Usage: MCE::Hobo->list()') if ref($_[0]);

   (defined $_LIST) ? $_LIST->vals : ();
}

sub list_joinable {
   _croak('Usage: MCE::Hobo->list_joinable()') if ref($_[0]);

   if (defined $_LIST) {
      my ($mgr_id, $wrk_id) = ("$$.$_tid");
      for my $self ($_LIST->vals) {
         if (!exists $self->{JOINED}) {
            $wrk_id = $self->{WRK_ID};
            sleep 0.01 until $_STAT->get($mgr_id)->exists($wrk_id);
         }
      }
      my %lkup = $_STAT->get($mgr_id)->pairs('val =~ /^joinable/');
      map { exists $lkup{$_} ? $_LIST->get($_) : () } $_LIST->keys;
   }
   else {
      ();
   }
}

sub list_running {
   _croak('Usage: MCE::Hobo->list_running()') if ref($_[0]);

   if (defined $_LIST) {
      my ($mgr_id, $wrk_id) = ("$$.$_tid");
      for my $self ($_LIST->vals) {
         if (!exists $self->{JOINED}) {
            $wrk_id = $self->{WRK_ID};
            sleep 0.01 until $_STAT->get($mgr_id)->exists($wrk_id);
         }
      }
      my %lkup = $_STAT->get($mgr_id)->pairs('val eq running');
      map { exists $lkup{$_} ? $_LIST->get($_) : () } $_LIST->keys;
   }
   else {
      ();
   }
}

sub pending {
   _croak('Usage: MCE::Hobo->pending()') if ref($_[0]);

   (defined $_LIST) ? $_LIST->len : 0;
}

sub pid {
   ref($_[0]) ? $_[0]->{PID} : $_SELF->{PID};
}

sub result {
   my ($self) = @_;
   _croak('Usage: $hobo->result()') unless ref($self);

   return $self->join() unless exists $self->{JOINED};
   wantarray ? @{ $self->{RESULT} } : $self->{RESULT}->[-1];
}

sub self {
   ref($_[0]) ? $_[0] : $_SELF;
}

sub tid {
   ref($_[0]) ? $_[0]->{WRK_ID} : $_SELF->{WRK_ID};
}

sub waitall {
   _croak('Usage: MCE::Hobo->waitall()') if ref($_[0]);
   return () if (!defined $_LIST || !$_LIST->len);

   if (defined wantarray) {
      map { MCE::Hobo->waitone } 1 .. $_LIST->len;
   }
   else {
      $_->join for MCE::Hobo->list;
   }
}

sub waitone {
   _croak('Usage: MCE::Hobo->waitone()') if ref($_[0]);
   return undef if (!defined $_LIST || !$_LIST->len);

   my $pid = CORE::wait();

   my $mgr_id = "$$.$_tid";
   my $wrk_id = "$pid.$_tid";

   if ( $_DATA->exists($mgr_id) && ( my $self = $_LIST->del($wrk_id) ) ) {
      my $result = $_DATA->get($mgr_id)->del($wrk_id);
      my $error  = $_STAT->get($mgr_id)->del($wrk_id);

      $self->{ERROR}  = (length $error > 10) ? substr($error, 10) : "";
      $self->{RESULT} = (defined $result) ? $_THAW->($result) : [];
      $self->{JOINED} = 1;

      $self;
   }
   else {
      undef;
   }
}

sub yield {
   _croak('Usage: MCE::Hobo->yield()') if ref($_[0]);
   shift if (defined $_[0] && $_[0] eq 'MCE::Hobo');

   ($^O eq 'MSWin32')
      ? sleep($_[0] || 0.0010)
      : sleep($_[0] || 0.0002);
}

###############################################################################
## ----------------------------------------------------------------------------
## Private methods.
##
###############################################################################

sub _noop { }

sub _croak {
   if (defined $MCE::VERSION) {
      goto &MCE::_croak;
   }
   else {
      require MCE::Shared::Base unless $INC{'MCE/Shared/Base.pm'};
      goto &MCE::Shared::Base::_croak;
   }
}

sub _exit {
   $SIG{__DIE__} = $SIG{__WARN__} = sub {};

   if ($_has_threads && $^O eq 'MSWin32') {
      { lock $_EXT_LOCK; sleep 0.002; }
      threads->exit(0);
   }
   elsif ($_SELF->{posix_exit}) {
      require POSIX unless $INC{'POSIX.pm'};
      POSIX::_exit(0);
   }

   CORE::exit(0);
}

sub _trap {
   $SIG{ $_[0] } = sub { };
   print {*STDERR} "Signal $_[0] received in process $$.$_tid\n";
   _exit();
}

1;

__END__

###############################################################################
## ----------------------------------------------------------------------------
## Module usage.
##
###############################################################################

=head1 NAME

MCE::Hobo - A threads-like parallelization module

=head1 VERSION

This document describes MCE::Hobo version 1.700

=head1 SYNOPSIS

   use MCE::Hobo;

   MCE::Hobo->create( sub { print "Hello from hobo\n" } )->join();

   sub parallel {
       my ($arg1) = @_;
       print "Hello again, $arg1\n";
   }

   MCE::Hobo->create( \&parallel, $_ ) for 1 .. 3;

   my @hobos    = MCE::Hobo->list();
   my @running  = MCE::Hobo->list_running();
   my @joinable = MCE::Hobo->list_joinable();
   my @count    = MCE::Hobo->pending();

   # Joining is orderly, e.g. hobo1 is joined first, hobo2, hobo3.
   $_->join() for @hobos;

   # Joining occurs immediately as hobo(s) complete execution.
   1 while MCE::Hobo->waitone();

   my $hobo = mce_async { foreach (@files) { ... } };
   $hobo->join();

   if ( my $err = $hobo->error() ) {
      warn("Hobo error: $err\n");
   }

   # Get a hobo's object
   $hobo = MCE::Hobo->self();

   # Get a hobo's ID
   $tid = MCE::Hobo->tid();  # "$$.tid"
   $tid = $hobo->tid();
   $pid = MCE::Hobo->pid();  #  $$
   $pid = $hobo->pid();

   # Test hobo objects
   if ( $hobo1 == $hobo2 ) {
      ...
   }

   # Give other hobos a chance to run
   MCE::Hobo->yield();
   MCE::Hobo->yield(0.05);

   # Return context, wantarray aware
   my ($value1, $value2) = $hobo->join();
   my $value = $hobo->join();

   # Check hobo's state
   if ( $hobo->is_running() ) {
       sleep 1;
   }
   if ( $hobo->is_joinable() ) {
       $hobo->join();
   }

   # Send a signal to a hobo
   $hobo->kill('SIGUSR1');

   # Exit a hobo
   MCE::Hobo->exit();

=head1 DESCRIPTION

A hobo is a migratory worker inside the machine that carries the
asynchronous gene. Hobos are equipped with C<threads>-like capability
for running code asynchronously. Unlike threads, each hobo is a unique
process to the underlying OS. The IPC is managed by C<MCE::Shared>,
which runs on all major platforms including Cygwin.

C<MCE::Hobo> may be used as a standalone or together with C<MCE>
including running alongside C<threads>.

The following is a parallel demonstration.

   use strict;
   use warnings;

   use MCE::Hobo;
   use MCE::Shared Sereal => 1;  # Serialization via Sereal if available.
   use MCE::Shared::Ordhash;     # Ordered hash for non-shared use below.

   # synopsis: head -20 file.txt | perl script.pl

   my $ifh  = MCE::Shared->handle( "<", \*STDIN  );  # shared
   my $ofh  = MCE::Shared->handle( ">", \*STDOUT );
   my $ary  = MCE::Shared->array();

   sub parallel_task {
      my ( $id ) = @_;

      while ( <$ifh> ) {
         printf {$ofh} "[ %4d ] %s", $., $_;

       # $ary->[ $. - 1 ] = "[ ID $id ] read line $.\n" );  # dereferencing
         $ary->set( $. - 1, "[ ID $id ] read line $.\n" );  # faster via OO
      }
   }

   my $hobo1 = MCE::Hobo->new( "parallel_task", 1 );
   my $hobo2 = MCE::Hobo->new( \&parallel_task, 2 );
   my $hobo3 = MCE::Hobo->new( sub { parallel_task(3) } );

   $_->join for MCE::Hobo->list();

   # search array -- single IPC
   my @vals = $ary->vals( "val =~ / ID 2 /" );

   print {*STDERR} join( "", @vals );

=head1 OVERRIDING DEFAULTS

The following list options which may be overridden when loading the module.

   use Sereal qw( encode_sereal decode_sereal );
   use CBOR::XS qw( encode_cbor decode_cbor );
   use JSON::XS qw( encode_json decode_json );

   use MCE::Hobo
         freeze => \&encode_sereal,       ## \&Storable::freeze
         thaw   => \&decode_sereal        ## \&Storable::thaw
   ;

There is a simpler way to enable Sereal. The following will attempt to use
Sereal if available, otherwise defaults to Storable for serialization.

   use MCE::Hobo Sereal => 1;
   use MCE::Shared Sereal => 1;  # <-- supports Sereal only at this time

=head1 API DOCUMENTATION

=over 3

=item $hobo = MCE::Hobo->create( { posix_exit => 1 }, FUNCTION, ARGS )

=item $hobo = MCE::Hobo->create( FUNCTION, ARGS )

=item $hobo = MCE::Hobo->new( FUNCTION, ARGS )

This will create a new hobo that will begin execution with function as the
entry point, and optionally ARGS for list of parameters. It will return the
corresponding MCE::Hobo object, or undef if hobo creation failed.

Options may be specified via a hash structure. At this time, C<posix_exit> is
the only option supported which calls C<POSIX::_exit(0)> when finished. The
default is C<CORE::exit(0)>. Set C<posix_exit> to avoid all END and destructor
processing.

I<FUNCTION> may either be the name of a function, an anonymous subroutine, or
a code ref.

   my $hobo = MCE::Hobo->create( "func_name", ... );
       # or
   my $hobo = MCE::Hobo->create( sub { ... }, ... );
       # or
   my $hobo = MCE::Hobo->create( \&func, ... );

The C<new()> method is an alias for C<create()>.

=item mce_async { BLOCK } ARGS;

=item mce_async { BLOCK };

C<mce_async> runs the block asynchronously similarly to C<MCE::Hobo->create()>.
It returns the hobo object, or undef if hobo creation failed.

   my $hobo = mce_async { foreach (@files) { ... } };

   $hobo->join();

   if ( my $err = $hobo->error() ) {
      warn("Hobo error: $err\n");
   }

=item $hobo->join()

This will wait for the corresponding hobo to complete its execution. In
non-voided context, C<join()> will return the value(s) of the entry point
function.

The context (void, scalar or list) for the return value(s) for C<join> is
determined at the time of joining and mostly C<wantarray> aware.

   my $hobo1 = MCE::Hobo->create( sub {
      my @res = qw(foo bar baz);
      return (@res);
   });

   my @res1 = $hobo1->join();  # ( foo, bar, baz )
   my $res1 = $hobo1->join();  #   baz

   my $hobo2 = MCE::Hobo->create( sub {
      return 'foo';
   });

   my @res2 = $hobo2->join();  # ( foo )
   my $res2 = $hobo2->join();  #   foo

=item $hobo1->equal( $hobo2 )

Tests if two hobo objects are the same hobo or not. Hobo comparison is based
on process IDs. This is overloaded to the more natural forms.

    if ( $hobo1 == $hobo2 ) {
        print("Hobos are the same\n");
    }
    # or
    if ( $hobo1 != $hobo2 ) {
        print("Hobos differ\n");
    }

=item $hobo->error()

Hobos are executed in an C<eval> context. This method will return C<undef>
if the hobo terminates I<normally>. Otherwise, it returns the value of
C<$@> associated with the hobo's execution status in its C<eval> context.

=item $hobo->exit()

This sends C<'SIGQUIT'> to the hobo object, notifying hobo to exit. It returns
the hobo object to allow for method chaining. It is important to join later if
not immediately to not leave a zombie or defunct process.

   $hobo->exit()->join();

   ...

   $hobo->join();  # later

=item MCE::Hobo->exit()

A hobo can be exited at any time by calling C<MCE::Hobo->exit()>.
This behaves the same as C<exit(status)> when called from the main process.

=item MCE::Hobo->finish()

This class method is called automatically by C<END>, but may be called
explicitly. Two shared objects to C<MCE::Shared> are destroyed. An error is
emitted via croak if there are active hobos not yet joined.

   MCE::Hobo->create( 'task1', $_ ) for 1 .. 4;

   $_->join for MCE::Hobo->list();

   MCE::Hobo->create( 'task2', $_ ) for 1 .. 4;

   $_->join for MCE::Hobo->list();

   MCE::Hobo->create( 'task3', $_ ) for 1 .. 4;

   $_->join for MCE::Hobo->list();

   MCE::Hobo->finish();

=item $hobo->is_running()

Returns true if a hobo is still running.

=item $hobo->is_joinable()

Returns true if the hobo has finished running and not yet joined.

=item $hobo->kill( 'SIG...' )

Sends the specified signal to the hobo. Returns the hobo object to allow for
method chaining. As with C<exit>, it is important to join eventually if not
immediately to not leave a zombie or defunct process.

   $hobo->kill('SIG...')->join();

The following is a parallel demonstration comparing C<MCE::Shared> against
C<Redis> and C<Redis::Fast> on a Fedora 23 VM. Joining begins after all
workers have been notified to quit.

   use Time::HiRes qw(time);

   use Redis;
   use Redis::Fast;

   use MCE::Hobo;
   use MCE::Shared;

   my $redis = Redis->new();
   my $rfast = Redis::Fast->new();
   my $array = MCE::Shared->array();

   sub parallel_redis {
      my ($_redis) = @_;
      my ($count, $quit, $len) = (0, 0);

      # instead, use a flag to exit loop
      $SIG{'QUIT'} = sub { $quit = 1 };

      while (1) {
         $len = $_redis->rpush('list', $count++);
         last if $quit;
      }

      $count;
   }

   sub parallel_array {
      my ($count, $quit, $len) = (0, 0);

      # do not exit from inside handler
      $SIG{'QUIT'} = sub { $quit = 1 };

      while (1) {
         $len = $array->push($count++);
         last if $quit;
      }

      $count;
   }

   sub benchmark_this {
      my ($desc, $num_hobos, $timeout, $code, @args) = @_;
      my ($start, $total) = (time(), 0);

      MCE::Hobo->new($code, @args) for 1..$num_hobos;
      sleep $timeout;

      # joining is not immediate; ok
      $_->kill('QUIT') for MCE::Hobo->list();

      # joining later; ok
      $total += $_->join() for MCE::Hobo->list();

      printf "$desc <> duration: %0.03f secs, count: $total\n",
         time() - $start;

      sleep 0.2;
   }

   benchmark_this('Redis      ', 8, 5.0, \&parallel_redis, $redis);
   benchmark_this('Redis::Fast', 8, 5.0, \&parallel_redis, $rfast);
   benchmark_this('MCE::Shared', 8, 5.0, \&parallel_array);

=item MCE::Hobo->list()

Returns a list of all hobos not yet joined.

   @hobos = MCE::Hobo->list();

=item MCE::Hobo->list_running()

Returns a list of all hobos that are still running.

   @hobos = MCE::Hobo->list_running();

=item MCE::Hobo->list_joinable()

Returns a list of all hobos that have completed running. Thus, ready to be
joined without blocking.

   @hobos = MCE::Hobo->list_joinable();

=item MCE::Hobo->pending()

Returns a count of all hobos not yet joined.

   $count = MCE::Hobo->pending();

=item $hobo->result()

Returns the result obtained by C<join>, C<waitone>, or C<waitall>. If the
process has not yet exited, waits for the corresponding hobo to complete its
execution.

   use MCE::Hobo;
   use Time::HiRes qw(sleep);

   sub task {
      my ($id) = @_;
      sleep $id * 0.333;
      return $id;
   }

   MCE::Hobo->create('task', $_) for ( reverse 1 .. 3 );

   # 1 while MCE::Hobo->waitone;

   while ( my $hobo = MCE::Hobo->waitone() ) {
      my $err = $hobo->error() // 'no error';
      my $res = $hobo->result();
      my $pid = $hobo->pid();

      print "[$pid] $err : $res\n";
   }

Like C<join> described above, the context (void, scalar or list) for the
return value(s) is determined at the time C<result> is called and mostly
C<wantarray> aware.

   my $hobo1 = MCE::Hobo->create( sub {
      my @res = qw(foo bar baz);
      return (@res);
   });

   my @res1 = $hobo1->result();  # ( foo, bar, baz )
   my $res1 = $hobo1->result();  #   baz

   my $hobo2 = MCE::Hobo->create( sub {
      return 'foo';
   });

   my @res2 = $hobo2->result();  # ( foo )
   my $res2 = $hobo2->result();  #   foo

=item MCE::Hobo->self()

Class method that allows a hobo to obtain it's own I<MCE::Hobo> object.

=item $hobo->pid()

=item $hobo->tid()

Returns the ID of the hobo. I<TID> is composed of process and thread IDs
together as a string value.

   PID:  $$
   TID: "$$.tid"

=item MCE::Hobo->pid()

=item MCE::Hobo->tid()

Class methods that allows a hobo to obtain its own ID.

=item MCE::Hobo->waitone()

=item MCE::Hobo->waitall()

Meaningful for the manager process only, waits for one or all hobos to
complete execution. Afterwards, returns the corresponding hobo(s). If a
hobo does not exist, returns the C<undef> value or an empty list for
C<waitone> and C<waitall> respectively.

   use MCE::Hobo;
   use Time::HiRes qw(sleep);

   sub task {
      my $id = shift;
      sleep $id * 0.333;
      return $id;
   }

   MCE::Hobo->create('task', $_) for ( reverse 1 .. 3 );

   # join, traditional use case
   $_->join() for MCE::Hobo->list();

   # waitone, simplistic use case
   1 while MCE::Hobo->waitone();

   # waitone
   while ( my $hobo = MCE::Hobo->waitone() ) {
      my $err = $hobo->error() // 'no error';
      my $res = $hobo->result();
      my $pid = $hobo->pid();

      print "[$pid] $err : $res\n";
   }

   # waitall
   my @hobos = MCE::Hobo->waitall();

   for ( @hobos ) {
      my $err = $_->error() // 'no error';
      my $res = $_->result();
      my $pid = $_->pid();

      print "[$pid] $err : $res\n";
   }

=item MCE::Hobo->yield( floating_seconds )

Let this hobo yield CPU time to other hobos. By default, the class method
calls C<sleep(0.0002)> on Unix including Cygwin and C<sleep(0.001)> on Windows.

   MCE::Hobo->yield();
   MCE::Hobo->yield(0.05);

=back

=head1 CREDITS

The inspiration for C<MCE::Hobo> comes from wanting C<threads>-like behavior
for processes. Both can run side-by-side including safe-use by MCE workers.
Likewise, the documentation resembles C<threads>.

The inspiration for C<waitall> and C<waitone> comes from C<Parallel::WorkUnit>.

=head1 SEE ALSO

=over 3

=item * L<forks>

=item * L<forks::BerkeleyDB>

=item * L<Parallel::ForkManager>

=item * L<Parallel::Loops>

=item * L<Parallel::WorkUnit>

=item * L<Thread::Tie>

=item * L<threads>

=back

=head1 INDEX

L<MCE|MCE>, L<MCE::Core>, L<MCE::Shared>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

