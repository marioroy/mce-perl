###############################################################################
## ----------------------------------------------------------------------------
## Temporary directory creation/cleanup and signal handling.
##
###############################################################################

package MCE::Signal;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized );

our $VERSION = '1.806';

## no critic (BuiltinFunctions::ProhibitStringyEval)

our ($display_die_with_localtime, $display_warn_with_localtime);
our ($main_proc_id, $prog_name, $tmp_dir);

my  ($_is_winenv);

use Carp ();

BEGIN {
   local $@; local $SIG{__DIE__};

   $main_proc_id =  $$;
   $prog_name    =  $0;
   $prog_name    =~ s{^.*[\\/]}{}g;
   $prog_name    =  'perl' if ($prog_name eq '-e' || $prog_name eq '-');

   $_is_winenv   =  ($^O =~ /mswin|mingw|msys|cygwin/i) ? 1 : 0;

   if ($^O eq 'MSWin32' && !$INC{'threads.pm'}) {
      eval 'use threads; use threads::shared';
   }
   elsif ($INC{'threads.pm'} && !$INC{'threads/shared.pm'}) {
      eval 'use threads::shared';
   }

   return;
}

use File::Path ();
use Time::HiRes qw( sleep time );
use Fcntl qw( :flock );
use base qw( Exporter );

our @EXPORT_OK = qw( $tmp_dir sys_cmd stop_and_exit );
our %EXPORT_TAGS = (
   all     => \@EXPORT_OK,
   tmp_dir => [ qw( $tmp_dir ) ]
);

sub _NOOP {}

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
my $_no_sigmsg    = 0;
my $_no_kill9     = 0;
my $_imported;

sub import {

   my $_class = shift; return if ($_imported++);

   my @_export_args = ();
   my $_no_setpgrp  = 0;
   my $_setpgrp     = 0;
   my $_use_dev_shm = 0;

   while (my $_arg = shift) {

      $_keep_tmp_dir = _flag() and next if ($_arg eq '-keep_tmp_dir');
      $_no_sigmsg    = _flag() and next if ($_arg eq '-no_sigmsg');
      $_no_kill9     = _flag() and next if ($_arg eq '-no_kill9');

      $_no_setpgrp   = _flag() and next if ($_arg eq '-no_setpgrp');
      $_setpgrp      = _flag() and next if ($_arg eq '-setpgrp');

      $_use_dev_shm  = _flag() and next if ($_arg eq '-use_dev_shm');

      _usage($_arg) if ($_arg =~ /^-/);
      push @_export_args, $_arg;
   }

   local $Exporter::ExportLevel = 1;
   Exporter::import($_class, @_export_args);

   ## Sets the current process group for the current process.
   setpgrp(0,0) if ($_setpgrp == 1 && !$_is_MSWin32);

   my ($_count, $_tmp_base_dir) = (0);

   if (exists $ENV{TEMP} && -d $ENV{TEMP} && -w $ENV{TEMP}) {
      if ( $_is_winenv ) {
         $_tmp_base_dir = $ENV{TEMP} . '/Perl-MCE';
         mkdir $_tmp_base_dir unless (-d $_tmp_base_dir);
      } else {
         $_tmp_base_dir = $ENV{TEMP};
      }
   }
   else {
      $_tmp_base_dir = ($_use_dev_shm && -d '/dev/shm' && -w '/dev/shm')
         ? '/dev/shm' : '/tmp';
   }

   _croak("Error: MCE::Signal: ($_tmp_base_dir) is not writeable")
      if (! exists $ENV{'MOBASTARTUPDIR'} && ! -w $_tmp_base_dir);

   ## Remove tainted'ness from $tmp_dir.
   ($tmp_dir) = "$_tmp_base_dir/$prog_name.$$.$_count" =~ /(.*)/;

   while ( !(mkdir $tmp_dir, 0770) ) {
      ($tmp_dir) = ("$_tmp_base_dir/$prog_name.$$.".(++$_count)) =~ /(.*)/;
   }

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Configure signal handling.
##
###############################################################################

## Set traps to catch signals.
$SIG{XCPU} = \&stop_and_exit if (exists $SIG{XCPU});   ## UNIX SIG 24
$SIG{XFSZ} = \&stop_and_exit if (exists $SIG{XFSZ});   ## UNIX SIG 25

$SIG{HUP}  = \&stop_and_exit;                          ## UNIX SIG  1
$SIG{INT}  = \&stop_and_exit;                          ## UNIX SIG  2
$SIG{PIPE} = \&stop_and_exit;                          ## UNIX SIG 13
$SIG{QUIT} = \&stop_and_exit;                          ## UNIX SIG  3
$SIG{TERM} = \&stop_and_exit;                          ## UNIX SIG 15

## MCE handles the reaping of its children.
$SIG{CHLD} = 'DEFAULT' unless $_is_MSWin32;

## Call stop_and_exit when exiting the script.
END {
   MCE::Signal->stop_and_exit($?) if ($$ == $main_proc_id);
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
## Stops execution, removes temp directory and exits cleanly.
##
## Provides safe reentrant logic for both parent and child processes.
## The $main_proc_id variable is defined above.
##
###############################################################################

my %_sig_name_lkup = map { $_ => 1 } qw(
   __DIE__ __WARN__ HUP INT PIPE QUIT TERM CHLD XCPU XFSZ
);

my $_handler_cnt : shared = 0;

sub stop_and_exit {

   shift @_ if (defined $_[0] && $_[0] eq 'MCE::Signal');

   my $_is_main_proc = ($$ == $main_proc_id);
   my $_sig_name     = $_[0] || 0;
   my $_exit_status  = $?;
   my $_is_sig       = 0;

   if (exists $_sig_name_lkup{$_sig_name}) {
      $_exit_status     = $MCE::Signal::KILLED = $_is_sig = 1;
      $SIG{$_sig_name}  = \&_NOOP;
   }
   else {
      $_exit_status = $_sig_name if ($_sig_name =~ /^\d+$/);
   }

   $SIG{INT} = $SIG{__DIE__} = $SIG{__WARN__} = \&_NOOP;

   ## -------------------------------------------------------------------------

   ## For the main process.
   if ($_is_main_proc) {
      lock $_handler_cnt if $INC{'threads/shared.pm'};

      if (++$_handler_cnt == 1) {
         open my $_FH, '>>', "$tmp_dir/stopped";
         close   $_FH;

         local $\ = undef;

         ## Display message and kill process group if signaled.
         if ($_is_sig == 1) {
            my $_err_msg = undef;

            if ($_sig_name eq 'XCPU') {
               $_err_msg  = 'exceeded CPU time limit, exiting';
               $_sig_name = 'INT';
            }
            elsif ($_sig_name eq 'XFSZ') {
               $_err_msg  = 'exceeded file size limit, exiting';
               $_sig_name = 'INT';
            }
            elsif ($_sig_name eq 'INT' && -f "$tmp_dir/died") {
               $_err_msg  = 'caught signal (__DIE__), exiting';
            }
            elsif ($_sig_name eq '__DIE__') {
               $_err_msg  = 'caught signal (__DIE__), exiting';
               $_sig_name = 'INT';
            }
            elsif ($_sig_name ne 'PIPE') {
               $_err_msg  = "caught signal ($_sig_name), exiting";
            }

            if ($_err_msg && $_no_sigmsg == 0) {
               print {*STDERR} "\n## $prog_name: $_err_msg\n";
            }

            open my $_FH, '>', "$tmp_dir/killed";
            close   $_FH;

            CORE::kill($_sig_name, $_is_MSWin32 ? -$$ : -getpgrp);

            ## Pause a bit.
            if ($_sig_name eq 'PIPE') {
               sleep 0.015 for (1..2);
            } else {
               sleep 0.060 for (1..3);
            }
         }

         ## Remove temp directory.
         if (defined $tmp_dir && $tmp_dir ne '' && -d $tmp_dir) {
            if ($_keep_tmp_dir == 1) {
               print {*STDERR} "$prog_name: saved tmp_dir = $tmp_dir\n";
            }
            elsif ($tmp_dir ne '/tmp' && $tmp_dir ne '/var/tmp') {
               chdir $ENV{'TEMP'} if ($_is_winenv && $ENV{'TEMP'});
               eval q{ File::Path::rmtree($tmp_dir) };
            }
            $tmp_dir = undef;
         }

         ## Signal process group to die.
         if ($_is_sig == 1) {
            if ($_sig_name eq 'PIPE' && $INC{'MCE/Hobo.pm'}) {
               CORE::kill('QUIT', $_is_MSWin32 ? -$$ : -getpgrp);
            }
            if ($_sig_name ne 'PIPE' && $_no_sigmsg == 0) {
               print {*STDERR} "\n";
            }
            ($_no_kill9 == 1 || $_sig_name eq 'PIPE')
               ? CORE::kill('INT', $_is_MSWin32 ? -$$ : -getpgrp)
               : CORE::kill('KILL', -$$, $main_proc_id);
         }
      }
   }

   ## Otherwise, for child processes.
   elsif ($_is_sig == 1 && $tmp_dir && -d $tmp_dir) {
      lock $_handler_cnt if $INC{'threads/shared.pm'};

      if (++$_handler_cnt == 1) {
         if ($^O eq 'MSWin32') {
            if ($_keep_tmp_dir == 1) {
               print {*STDERR} "$prog_name: saved tmp_dir = $tmp_dir\n";
            }
            elsif ($tmp_dir ne '/tmp' && $tmp_dir ne '/var/tmp') {
               chdir $ENV{'TEMP'} if ($_is_winenv && $ENV{'TEMP'});
               eval q{ File::Path::rmtree($tmp_dir) };
            }
            $tmp_dir = undef;
            CORE::kill('KILL', $main_proc_id, -$$);
         }
         else {
            ## Obtain lock.
            open my $CHILD_LOCK, '+>>', "$tmp_dir/child.lock";
            flock $CHILD_LOCK, LOCK_EX;

            ## Notify the main process that I've died.
            if ($_sig_name eq '__DIE__' && ! -f "$tmp_dir/died") {
               local $@; eval {
                  open my $_FH, '>>', "$tmp_dir/died";
                  close   $_FH;
               };
            }

            ## Signal process group to terminate.
            if (! -f "$tmp_dir/killed" && ! -f "$tmp_dir/stopped") {
               local $@; eval {
                  open my $_FH, '>>', "$tmp_dir/killed";
                  close   $_FH;
               };
               ($_sig_name eq 'PIPE')
                  ? CORE::kill('PIPE', $main_proc_id, -$$)
                  : CORE::kill('INT', $main_proc_id, -$$);
            }

            ## Release lock.
            flock $CHILD_LOCK, LOCK_UN;
            close $CHILD_LOCK;
         }
      }
   }

   ## -------------------------------------------------------------------------

   ## Exit with status.
   if ($_is_sig == 1 && $_no_kill9 == 0) {
      sleep 0.060 for (1..5);
   }

   CORE::exit($_exit_status);
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

   MCE::Signal->stop_and_exit('__DIE__');
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

__END__

###############################################################################
## ----------------------------------------------------------------------------
## Module usage.
##
###############################################################################

=head1 NAME

MCE::Signal - Temporary directory creation/cleanup and signal handling

=head1 VERSION

This document describes MCE::Signal version 1.806

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

This package configures $SIG{HUP,INT,PIPE,QUIT,TERM,XCPU,XFSZ} to point to
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

 -no_sigmsg        - Do not display a message when receiving a signal
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

=head1 INDEX

L<MCE|MCE>, L<MCE::Core>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

