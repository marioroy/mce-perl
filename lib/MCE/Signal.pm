###############################################################################
## ----------------------------------------------------------------------------
## Temporary directory creation/cleanup and signal handling.
##
###############################################################################

package MCE::Signal;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized once );

our $VERSION = '1.879';

## no critic (BuiltinFunctions::ProhibitStringyEval)

our ($display_die_with_localtime, $display_warn_with_localtime);
our ($main_proc_id, $prog_name, $tmp_dir);

tie $tmp_dir, 'MCE::Signal::_tmpdir';

use Carp ();

BEGIN {
   $main_proc_id =  $$;
   $prog_name    =  $0;
   $prog_name    =~ s{^.*[\\/]}{}g;
   $prog_name    =  'perl' if ($prog_name eq '-e' || $prog_name eq '-');

   return;
}

use base qw( Exporter );
use Time::HiRes ();

our @EXPORT_OK = qw( $tmp_dir sys_cmd stop_and_exit );
our %EXPORT_TAGS = (
   all     => \@EXPORT_OK,
   tmp_dir => [ qw( $tmp_dir ) ]
);

END {
   MCE::Signal->stop_and_exit($?)
      if ($$ == $main_proc_id && !$MCE::Signal::KILLED && !$MCE::Signal::STOPPED);
}

###############################################################################
## ----------------------------------------------------------------------------
## Process import, export, & module arguments.
##
###############################################################################

sub _croak { $\ = undef; goto &Carp::croak }
sub _usage { _croak "MCE::Signal error: ($_[0]) is not a valid option" }
sub _flag  { 1 }

my $_is_MSWin32   = ($^O eq 'MSWin32') ? 1 : 0;
my $_keep_tmp_dir = 0;
my $_use_dev_shm  = 0;
my $_no_kill9     = 0;
my $_imported;

sub import {
   my $_class = shift;
   return if $_imported++;

   my ($_no_setpgrp, $_no_sigmsg, $_setpgrp, @_export_args) = (0, 0, 0);

   while (my $_arg = shift) {
      $_setpgrp      = _flag() and next if ($_arg eq '-setpgrp');
      $_keep_tmp_dir = _flag() and next if ($_arg eq '-keep_tmp_dir');
      $_use_dev_shm  = _flag() and next if ($_arg eq '-use_dev_shm');
      $_no_kill9     = _flag() and next if ($_arg eq '-no_kill9');

      # deprecated options for backwards compatibility
      $_no_setpgrp   = _flag() and next if ($_arg eq '-no_setpgrp');
      $_no_sigmsg    = _flag() and next if ($_arg eq '-no_sigmsg');

      _usage($_arg) if ($_arg =~ /^-/);

      push @_export_args, $_arg;
   }

   local $Exporter::ExportLevel = 1;
   Exporter::import($_class, @_export_args);

   ## Sets the current process group for the current process.
   setpgrp(0,0) if ($_setpgrp == 1 && !$_is_MSWin32);

   ## Make tmp_dir if caller requested it.
   _make_tmpdir() if ($_use_dev_shm || grep /tmp_dir/, @_export_args);

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Configure signal handling.
##
###############################################################################

## Set traps to catch signals.
if ( !$_is_MSWin32 ) {
   $SIG{HUP}  = \&stop_and_exit;  # UNIX SIG  1
   $SIG{INT}  = \&stop_and_exit;  # UNIX SIG  2
   $SIG{PIPE} = \&stop_and_exit;  # UNIX SIG 13
   $SIG{QUIT} = \&stop_and_exit;  # UNIX SIG  3
   $SIG{TERM} = \&stop_and_exit;  # UNIX SIG 15

   ## MCE handles the reaping of its children.
   $SIG{CHLD} = 'DEFAULT';
}

my $_safe_clean = 0;

sub _make_tmpdir {
   my ($_count, $_tmp_base_dir) = (0);

   return $tmp_dir if (defined $tmp_dir && -d $tmp_dir && -w _);

   if ($ENV{TEMP} && -d $ENV{TEMP} && -w _) {
      if ($^O =~ /mswin|mingw|msys|cygwin/i) {
         $_tmp_base_dir = $ENV{TEMP} . '/Perl-MCE';
         mkdir $_tmp_base_dir unless -d $_tmp_base_dir;
      } else {
         $_tmp_base_dir = $ENV{TEMP};
      }
   }
   else {
      $_tmp_base_dir = ($_use_dev_shm && -d '/dev/shm' && -w _)
         ? '/dev/shm' : '/tmp';
   }

   _croak("Error: MCE::Signal: ($_tmp_base_dir) is not writeable")
      if (! exists $ENV{'MOBASTARTUPDIR'} && ! -w $_tmp_base_dir);

   ## Remove tainted'ness from $tmp_dir.
   ($tmp_dir) = "$_tmp_base_dir/$prog_name.$$.$_count" =~ /(.*)/;

   while ( !(mkdir $tmp_dir, 0770) ) {
      ($tmp_dir) = ("$_tmp_base_dir/$prog_name.$$.".(++$_count)) =~ /(.*)/;
   }

   $_safe_clean = 1;

   return $tmp_dir;
}

sub _remove_tmpdir {
   return if (!defined $tmp_dir || $tmp_dir eq '' || ! -d $tmp_dir);

   if ($_keep_tmp_dir == 1) {
      print {*STDERR} "$prog_name: saved tmp_dir = $tmp_dir\n";
   }
   elsif ($_safe_clean) {
      if ($ENV{'TEMP'} && $^O =~ /mswin|mingw|msys|cygwin/i) {
         ## remove tainted'ness
         my ($_dir) = $ENV{'TEMP'} =~ /(.*)/;
         chdir $_dir if -d $_dir;
      }
      rmdir $tmp_dir;
      if (-d $tmp_dir) {
         local $@; local $SIG{__DIE__};
         eval 'require File::Path; File::Path::rmtree($tmp_dir)';
      }
   }

   $tmp_dir = undef;
}

###############################################################################
## ----------------------------------------------------------------------------
## Stops execution, removes temp directory and exits cleanly.
##
## Provides safe reentrant logic for parent and child processes.
## The $main_proc_id variable is defined above.
##
###############################################################################

BEGIN {
   $MCE::Signal::IPC = 0;   # 1 = defer signal_handling until completed IPC
   $MCE::Signal::SIG = '';  # signal received during IPC in MCE::Shared 1.863
}

sub defer {
   $MCE::Signal::SIG = $_[0] if $_[0];
   return;
}

my %_sig_name_lkup = map { $_ => 1 } qw(
   __DIE__ HUP INT PIPE QUIT TERM __WARN__
);

my $_count = 0;

my $_handler_count = $INC{'threads/shared.pm'}
   ? threads::shared::share($_count)
   : \$_count;

sub stop_and_exit {
   shift @_ if (defined $_[0] && $_[0] eq 'MCE::Signal');
   return MCE::Signal::defer($_[0]) if $MCE::Signal::IPC;

   my ($_exit_status, $_is_sig, $_sig_name) = ($?, 0, $_[0] || 0);
   $SIG{__DIE__} = $SIG{__WARN__} = sub {};

   if (exists $_sig_name_lkup{$_sig_name}) {
      $_exit_status = $MCE::Signal::KILLED = $_is_sig = 1;
      $_exit_status = 255, $_sig_name = 'TERM' if ($_sig_name eq '__DIE__');
      $_exit_status = 0 if ($_sig_name eq 'PIPE');
      $SIG{INT} = $SIG{$_sig_name} = sub {};
   }
   else {
      $_exit_status = $_sig_name if ($_sig_name =~ /^\d+$/);
      $MCE::Signal::STOPPED = 1;
   }

   ## Main process.
   if ($$ == $main_proc_id) {

      if (++${ $_handler_count } == 1) {
         ## Kill process group if signaled.
         if ($_is_sig == 1) {
            ($_sig_name eq 'PIPE')
               ? CORE::kill('PIPE', $_is_MSWin32 ? -$$ : -getpgrp)
               : CORE::kill('INT' , $_is_MSWin32 ? -$$ : -getpgrp);

            if ($_sig_name eq 'PIPE') {
               for my $_i (1..2) { Time::HiRes::sleep(0.015); }
            } else {
               for my $_i (1..3) { Time::HiRes::sleep(0.060); }
            }
         }

         ## Remove temp directory.
         _remove_tmpdir() if defined($tmp_dir);

         ## Signal process group to die.
         if ($_is_sig == 1) {
            if ($_sig_name eq 'INT' && -t STDIN) { ## no critic
               print {*STDERR} "\n";
            }
            if ($INC{'threads.pm'} && ($] lt '5.012000' || threads->tid())) {
               ($_no_kill9 == 1 || $_sig_name eq 'PIPE')
                  ? CORE::kill('INT', $_is_MSWin32 ? -$$ : -getpgrp)
                  : CORE::kill('KILL', -$$);
            }
            else {
               CORE::kill('INT', $_is_MSWin32 ? -$$ : -getpgrp);
            }
         }
      }
   }

   ## Child processes.
   elsif ($_is_sig) {

      ## Windows support, from nested workers.
      if ($_is_MSWin32) {
         _remove_tmpdir() if defined($tmp_dir);
         CORE::kill('KILL', $main_proc_id, -$$);
      }

      ## Real child processes.
      else {
         CORE::kill($_sig_name, $main_proc_id, -$$);
         CORE::kill('KILL', -$$, $$);
      }
   }

   ## Exit with status.
   CORE::exit($_exit_status);
}

###############################################################################
## ----------------------------------------------------------------------------
## Run command via the system(...) function.
##
## The system function in Perl ignores SIGINT and SIGQUIT. These 2 signals
## are sent to the command being executed via system() but not back to
## the underlying Perl script. The code below will ensure the Perl script
## receives the same signal in order to raise an exception immediately
## after the system call.
##
## Returns the actual exit status.
##
###############################################################################

sub sys_cmd {
   shift @_ if (defined $_[0] && $_[0] eq 'MCE::Signal');

   _croak('MCE::Signal::sys_cmd: no arguments were specified') if (@_ == 0);

   my $_status = system(@_);
   my $_sig_no = $_status & 127;
   my $_exit_status = $_status >> 8;

   ## Kill the process group if command caught SIGINT or SIGQUIT.

   CORE::kill('INT',  $main_proc_id, $_is_MSWin32 ? -$$ : -getpgrp)
      if $_sig_no == 2;

   CORE::kill('QUIT', $main_proc_id, $_is_MSWin32 ? -$$ : -getpgrp)
      if $_sig_no == 3;

   return $_exit_status;
}

###############################################################################
## ----------------------------------------------------------------------------
## Signal handlers for __DIE__ & __WARN__ utilized by MCE.
##
###############################################################################

sub _die_handler {
   shift @_ if (defined $_[0] && $_[0] eq 'MCE::Signal');

   if (!defined $^S || $^S) {
      if ( ($INC{'threads.pm'} && threads->tid() != 0) ||
            $ENV{'PERL_IPERL_RUNNING'}
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

   local $\ = undef;

   ## Set $MCE::Signal::display_die_with_localtime = 1;
   ## when wanting the output to contain the localtime.

   if (defined $_[0]) {
      if ($MCE::Signal::display_die_with_localtime) {
         my $_time_stamp = localtime;
         print {*STDERR} "## $_time_stamp: $prog_name: ERROR:\n", $_[0];
      }
      else {
         print {*STDERR} $_[0];
      }
   }

   MCE::Signal::stop_and_exit('__DIE__');
}

sub _warn_handler {
   shift @_ if (defined $_[0] && $_[0] eq 'MCE::Signal');

   ## Ignore thread warnings during exiting.

   return if (
      $_[0] =~ /^A thread exited while \d+ threads were running/ ||
      $_[0] =~ /^Attempt to free unreferenced scalar/            ||
      $_[0] =~ /^Perl exited with active threads/                ||
      $_[0] =~ /^Thread \d+ terminated abnormally/
   );

   local $\ = undef;

   ## Set $MCE::Signal::display_warn_with_localtime = 1;
   ## when wanting the output to contain the localtime.

   if (defined $_[0]) {
      if ($MCE::Signal::display_warn_with_localtime) {
         my $_time_stamp = localtime;
         print {*STDERR} "## $_time_stamp: $prog_name: WARNING:\n", $_[0];
      }
      else {
         print {*STDERR} $_[0];
      }
   }

   return;
}

1;

###############################################################################
## ----------------------------------------------------------------------------
## TIE scalar package for making $MCE::Signal::tmp_dir on demand.
##
###############################################################################

package MCE::Signal::_tmpdir;

sub TIESCALAR {
   my $_class = shift;
   bless \do{ my $o = defined $_[0] ? shift : undef }, $_class;
}

sub STORE {
   ${ $_[0] } = $_[1];

   $_safe_clean = 0 if ( length $_[1] < 9 );
   $_safe_clean = 0 if ( $ENV{'TEMP'} && $ENV{'TEMP'} eq $_[1] );
   $_safe_clean = 0 if ( $_[1] =~ m{[\\/](?:etc|bin|lib|sbin)} );
   $_safe_clean = 0 if ( $_[1] =~ m{[\\/](?:temp|tmp)[\\/]?$}i );

   $_[1];
}

sub FETCH {
   if (!defined ${ $_[0] }) {
      my $_caller = caller();
      if ($_caller ne 'MCE' && $_caller ne 'MCE::Signal') {
         if ($INC{'MCE.pm'} && MCE->wid() > 0) {
            ${ $_[0] } = MCE->tmp_dir();
         } else {
            ${ $_[0] } = MCE::Signal::_make_tmpdir();
         }
      }
   }
   ${ $_[0] };
}

1;

__END__

###############################################################################
## ----------------------------------------------------------------------------
## Module usage.
##
###############################################################################

=head1 NAME

MCE::Signal - Temporary directory creation/cleanup and signal handling

=head1 VERSION

This document describes MCE::Signal version 1.879

=head1 SYNOPSIS

 ## Creates tmp_dir under $ENV{TEMP} if defined, otherwise /tmp.

 use MCE::Signal;

 ## Attempts to create tmp_dir under /dev/shm if writable.

 use MCE::Signal qw( -use_dev_shm );

 ## Keeps tmp_dir after the script terminates.

 use MCE::Signal qw( -keep_tmp_dir );
 use MCE::Signal qw( -use_dev_shm -keep_tmp_dir );

 ## MCE loads MCE::Signal by default when not present.
 ## Therefore, load MCE::Signal first for options to take effect.

 use MCE::Signal qw( -keep_tmp_dir -use_dev_shm );
 use MCE;

=head1 DESCRIPTION

This package configures $SIG{ HUP, INT, PIPE, QUIT, and TERM } to point to
stop_and_exit and creates a temporary directory. The main process and workers
receiving said signals call stop_and_exit, which signals all workers to
terminate, removes the temporary directory unless -keep_tmp_dir is specified,
and terminates itself.

The location of the temp directory resides under $ENV{TEMP} if defined,
otherwise /dev/shm if writeable and -use_dev_shm is specified, or /tmp.
On Windows, the temp directory is made under $ENV{TEMP}/Perl-MCE/.

As of MCE 1.405, MCE::Signal no longer calls setpgrp by default. Pass the
-setpgrp option to MCE::Signal to call setpgrp.

 ## Running MCE through Daemon::Control requires setpgrp to be called
 ## for MCE releases 1.511 and below.

 use MCE::Signal qw(-setpgrp);   ## Not necessary for MCE 1.512 and above
 use MCE;

The following are available options and their meanings.

 -keep_tmp_dir     - The temporary directory is not removed during exiting
                     A message is displayed with the location afterwards

 -use_dev_shm      - Create the temporary directory under /dev/shm
 -no_kill9         - Do not kill -9 after receiving a signal to terminate

 -setpgrp          - Calls setpgrp to set the process group for the process
                     This option ensures all workers terminate when reading
                     STDIN for MCE releases 1.511 and below.

                        cat big_input_file | ./mce_script.pl | head -10

                     This works fine without the -setpgrp option:

                        ./mce_script.pl < big_input_file | head -10

Nothing is exported by default. Exportable are 1 variable and 2 subroutines.

 use MCE::Signal qw( $tmp_dir stop_and_exit sys_cmd );
 use MCE::Signal qw( :all );

 $tmp_dir          - Path to the temporary directory.
 stop_and_exit     - Described below
 sys_cmd           - Described below

=head2 stop_and_exit ( [ $exit_status | $signal ] )

Stops execution, removes temp directory, and exits the entire application.
Pass 'INT' to terminate a spawned or running MCE session.

 MCE::Signal::stop_and_exit(1);
 MCE::Signal::stop_and_exit('INT');

=head2 sys_cmd ( $command )

The system function in Perl ignores SIGINT and SIGQUIT. These 2 signals are
sent to the command being executed via system() but not back to the underlying
Perl script. For this reason, sys_cmd was added to MCE::Signal.

 ## Execute command and return the actual exit status. The perl script
 ## is also signaled if command caught SIGINT or SIGQUIT.

 use MCE::Signal qw(sys_cmd);   ## Include before MCE
 use MCE;

 my $exit_status = sys_cmd($command);

=head1 DEFER SIGNAL

=head2 defer ( $signal )

Returns immediately inside a signal handler if signaled during IPC.
The signal is deferred momentarily and re-signaled automatically upon
completing IPC. Currently, all IPC related methods in C<MCE::Shared> and
one method C<send2> in C<MCE::Channel> set the flag C<$MCE::Signal::IPC>
before initiating IPC.

Current API available since 1.863.

 sub sig_handler {
    return MCE::Signal::defer($_[0]) if $MCE::Signal::IPC;
    ...
 }

In a nutshell, C<defer> helps safeguard IPC from stalling between workers
and the shared manager-process. The following is a demonstration for Unix
platforms. Deferring the signal inside the C<WINCH> handler prevents the
app from eventually failing while resizing the window.

 use strict;
 use warnings;

 use MCE::Hobo;
 use MCE::Shared;
 use Time::HiRes 'sleep';

 my $count = MCE::Shared->scalar(0);
 my $winch = MCE::Shared->scalar(0);
 my $done  = MCE::Shared->scalar(0);

 $SIG{WINCH} = sub {
    # defer signal if signaled during IPC
    return MCE::Signal::defer($_[0]) if $MCE::Signal::IPC;

    # mask signal handler
    local $SIG{$_[0]} = 'IGNORE';

    printf "inside winch handler %d\n", $winch->incr;
 };

 $SIG{INT} = sub {
    # defer signal if signaled during IPC
    return MCE::Signal::defer($_[0]) if $MCE::Signal::IPC;

    # set flag for workers to leave loop
    $done->set(1);
 };

 sub task {
    while ( ! $done->get ) {
       $count->incr;
       sleep 0.03;
    };
 }

 print "Resize the terminal window continuously.\n";
 print "Press Ctrl-C to stop.\n";

 MCE::Hobo->create('task') for 1..8;
 sleep 0.015 until $done->get;
 MCE::Hobo->wait_all;

 printf "\ncount incremented %d times\n\n", $count->get;

=head1 INDEX

L<MCE|MCE>, L<MCE::Core>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

