###############################################################################
## ----------------------------------------------------------------------------
## Utility functions.
##
###############################################################################

package MCE::Util;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized numeric );

our $VERSION = '1.879';

## no critic (BuiltinFunctions::ProhibitStringyEval)

use IO::Handle ();
use Socket qw( AF_UNIX SOL_SOCKET SO_SNDBUF SO_RCVBUF );
use Time::HiRes qw( sleep time );
use Errno ();
use base qw( Exporter );

my ($_is_winenv, $_zero_bytes, %_sock_ready);

BEGIN {
   $_is_winenv  = ( $^O =~ /mswin|mingw|msys|cygwin/i ) ? 1 : 0;
   $_zero_bytes = "\x00\x00\x00\x00";
}

our $LF = "\012";  Internals::SvREADONLY($LF, 1);

our @EXPORT_OK   = qw( $LF get_ncpu );
our %EXPORT_TAGS = ( all => \@EXPORT_OK );

###############################################################################
## ----------------------------------------------------------------------------
## The get_ncpu subroutine, largely adopted from Test::Smoke::Util.pm,
## returns the number of logical (online/active/enabled) CPU cores;
## never smaller than one.
##
## A warning is emitted to STDERR when it cannot recognize the operating
## system or the external command failed.
##
###############################################################################

my $g_ncpu;

sub get_ncpu {
   return $g_ncpu if (defined $g_ncpu);

   local $ENV{PATH} = "/usr/sbin:/sbin:/usr/bin:/bin:$ENV{PATH}";
   $ENV{PATH} =~ /(.*)/; $ENV{PATH} = $1;   ## Remove tainted'ness

   my $ncpu = 1;

   OS_CHECK: {
      local $_ = lc $^O;

      /linux/ && do {
         my ( $count, $fh );
         if ( open $fh, '<', '/proc/stat' ) {
            $count = grep { /^cpu\d/ } <$fh>;
            close $fh;
         }
         $ncpu = $count if $count;
         last OS_CHECK;
      };

      /bsd|darwin|dragonfly/ && do {
         chomp( my @output = `sysctl -n hw.ncpu 2>/dev/null` );
         $ncpu = $output[0] if @output;
         last OS_CHECK;
      };

      /aix/ && do {
         my @output = `lparstat -i 2>/dev/null | grep "^Online Virtual CPUs"`;
         if ( @output ) {
            $output[0] =~ /(\d+)\n$/;
            $ncpu = $1 if $1;
         }
         if ( !$ncpu ) {
            @output = `pmcycles -m 2>/dev/null`;
            if ( @output ) {
               $ncpu = scalar @output;
            } else {
               @output = `lsdev -Cc processor -S Available 2>/dev/null`;
               $ncpu = scalar @output if @output;
            }
         }
         last OS_CHECK;
      };

      /gnu/ && do {
         chomp( my @output = `nproc 2>/dev/null` );
         $ncpu = $output[0] if @output;
         last OS_CHECK;
      };

      /haiku/ && do {
         my @output = `sysinfo -cpu 2>/dev/null | grep "^CPU #"`;
         $ncpu = scalar @output if @output;
         last OS_CHECK;
      };

      /hp-?ux/ && do {
         my $count = grep { /^processor/ } `ioscan -fkC processor 2>/dev/null`;
         $ncpu = $count if $count;
         last OS_CHECK;
      };

      /irix/ && do {
         my @out = grep { /\s+processors?$/i } `hinv -c processor 2>/dev/null`;
         $ncpu = (split ' ', $out[0])[0] if @out;
         last OS_CHECK;
      };

      /osf|solaris|sunos|svr5|sco/ && do {
         if (-x '/usr/sbin/psrinfo') {
            my $count = grep { /on-?line/ } `psrinfo 2>/dev/null`;
            $ncpu = $count if $count;
         }
         else {
            my @output = grep { /^NumCPU = \d+/ } `uname -X 2>/dev/null`;
            $ncpu = (split ' ', $output[0])[2] if @output;
         }
         last OS_CHECK;
      };

      /mswin|mingw|msys|cygwin/ && do {
         if (exists $ENV{NUMBER_OF_PROCESSORS}) {
            $ncpu = $ENV{NUMBER_OF_PROCESSORS};
         }
         last OS_CHECK;
      };

      warn "MCE::Util::get_ncpu: command failed or unknown operating system\n";
   }

   $ncpu = 1 if (!$ncpu || $ncpu < 1);

   return $g_ncpu = $ncpu;
}

###############################################################################
## ----------------------------------------------------------------------------
## Private methods for pipes and sockets.
##
###############################################################################

sub _destroy_pipes {
   my ($_obj, @_params) = @_;
   local ($!,$?); local $SIG{__DIE__};

   for my $_p (@_params) {
      next unless (defined $_obj->{$_p});

      if (ref $_obj->{$_p} eq 'ARRAY') {
         for my $_i (0 .. @{ $_obj->{$_p} } - 1) {
            next unless (defined $_obj->{$_p}[$_i]);
            close $_obj->{$_p}[$_i] if (fileno $_obj->{$_p}[$_i]);
            undef $_obj->{$_p}[$_i];
         }
      }
      else {
         close $_obj->{$_p} if (fileno $_obj->{$_p});
         undef $_obj->{$_p};
      }
   }

   return;
}

sub _destroy_socks {
   my ($_obj, @_params) = @_;
   local ($!,$?,$@); local $SIG{__DIE__};

   for my $_p (@_params) {
      next unless (defined $_obj->{$_p});

      if (ref $_obj->{$_p} eq 'ARRAY') {
         for my $_i (0 .. @{ $_obj->{$_p} } - 1) {
            next unless (defined $_obj->{$_p}[$_i]);
            if (fileno $_obj->{$_p}[$_i]) {
               syswrite($_obj->{$_p}[$_i], '0') if $_is_winenv;
               eval q{ CORE::shutdown($_obj->{$_p}[$_i], 2) };
               close $_obj->{$_p}[$_i];
            }
            undef $_obj->{$_p}[$_i];
         }
      }
      else {
         if (fileno $_obj->{$_p}) {
            syswrite($_obj->{$_p}, '0') if $_is_winenv;
            eval q{ CORE::shutdown($_obj->{$_p}, 2) };
            close $_obj->{$_p};
         }
         undef $_obj->{$_p};
      }
   }

   return;
}

sub _pipe_pair {
   my ($_obj, $_r_sock, $_w_sock, $_i) = @_;
   local $!;

   if (defined $_i) {
      # remove tainted'ness
      ($_i) = $_i =~ /(.*)/;
      pipe($_obj->{$_r_sock}[$_i], $_obj->{$_w_sock}[$_i]) or die "pipe: $!\n";
      $_obj->{$_w_sock}[$_i]->autoflush(1);
   }
   else {
      pipe($_obj->{$_r_sock}, $_obj->{$_w_sock}) or die "pipe: $!\n";
      $_obj->{$_w_sock}->autoflush(1);
   }

   return;
}

sub _sock_pair {
   my ($_obj, $_r_sock, $_w_sock, $_i, $_seq) = @_;
   my $_size = 16384; local ($!, $@);

   if (defined $_i) {
      # remove tainted'ness
      ($_i) = $_i =~ /(.*)/;

      if ($_seq && $^O eq 'linux' && eval q{ Socket::SOCK_SEQPACKET() }) {
         socketpair( $_obj->{$_r_sock}[$_i], $_obj->{$_w_sock}[$_i],
            AF_UNIX, Socket::SOCK_SEQPACKET(), 0 ) or do {
               socketpair( $_obj->{$_r_sock}[$_i], $_obj->{$_w_sock}[$_i],
                  AF_UNIX, Socket::SOCK_STREAM(), 0 ) or die "socketpair: $!\n";
            };
      }
      else {
         socketpair( $_obj->{$_r_sock}[$_i], $_obj->{$_w_sock}[$_i],
            AF_UNIX, Socket::SOCK_STREAM(), 0 ) or die "socketpair: $!\n";
      }

      if ($^O ne 'aix' && $^O ne 'linux') {
         setsockopt($_obj->{$_r_sock}[$_i], SOL_SOCKET, SO_SNDBUF, int $_size);
         setsockopt($_obj->{$_r_sock}[$_i], SOL_SOCKET, SO_RCVBUF, int $_size);
         setsockopt($_obj->{$_w_sock}[$_i], SOL_SOCKET, SO_SNDBUF, int $_size);
         setsockopt($_obj->{$_w_sock}[$_i], SOL_SOCKET, SO_RCVBUF, int $_size);
      }

      $_obj->{$_r_sock}[$_i]->autoflush(1);
      $_obj->{$_w_sock}[$_i]->autoflush(1);
   }
   else {
      if ($_seq && $^O eq 'linux' && eval q{ Socket::SOCK_SEQPACKET() }) {
         socketpair( $_obj->{$_r_sock}, $_obj->{$_w_sock},
            AF_UNIX, Socket::SOCK_SEQPACKET(), 0 ) or do {
               socketpair( $_obj->{$_r_sock}, $_obj->{$_w_sock},
                  AF_UNIX, Socket::SOCK_STREAM(), 0 ) or die "socketpair: $!\n";
            };
      }
      else {
         socketpair( $_obj->{$_r_sock}, $_obj->{$_w_sock},
            AF_UNIX, Socket::SOCK_STREAM(), 0 ) or die "socketpair: $!\n";
      }

      if ($^O ne 'aix' && $^O ne 'linux') {
         setsockopt($_obj->{$_r_sock}, SOL_SOCKET, SO_SNDBUF, int $_size);
         setsockopt($_obj->{$_r_sock}, SOL_SOCKET, SO_RCVBUF, int $_size);
         setsockopt($_obj->{$_w_sock}, SOL_SOCKET, SO_SNDBUF, int $_size);
         setsockopt($_obj->{$_w_sock}, SOL_SOCKET, SO_RCVBUF, int $_size);
      }

      $_obj->{$_r_sock}->autoflush(1);
      $_obj->{$_w_sock}->autoflush(1);
   }

   return;
}

sub _sock_ready {
   my ($_socket, $_timeout) = @_;
   return '' if !defined $_timeout && $_sock_ready{"$_socket"} > 1;

   my ($_delay, $_val_bytes, $_start) = (0, "\x00\x00\x00\x00", time);
   my $_ptr_bytes = unpack('I', pack('P', $_val_bytes));

   if (!defined $_timeout) {
      $_sock_ready{"$_socket"}++;
   }
   else {
      $_timeout = undef    if $_timeout < 0;
      $_timeout += $_start if $_timeout;
   }

   while (1) {
      # MSWin32 FIONREAD - from winsock2.h macro
      ioctl($_socket, 0x4004667f, $_ptr_bytes);

      return '' if $_val_bytes ne $_zero_bytes;
      return  1 if $_timeout && time > $_timeout;

      # delay after a while to not consume a CPU core
      sleep(0.015), next if $_delay;
      $_delay = 1 if time - $_start > 0.015;
   }
}

sub _sock_ready_w {
   my ($_socket) = @_;
   return if $_sock_ready{"${_socket}_w"} > 1;

   my $_vec = '';
   $_sock_ready{"${_socket}_w"}++;

   while (1) {
      vec($_vec, fileno($_socket), 1) = 1;
      return if select(undef, $_vec, undef, 0) > 0;
      sleep 0.045;
   }

   return;
}

sub _sysread {
   (  @_ == 3
      ? CORE::sysread($_[0], $_[1], $_[2])
      : CORE::sysread($_[0], $_[1], $_[2], $_[3])
   )
   or do {
      goto \&_sysread if ($! == Errno::EINTR());
   };
}

sub _sysread2 {
   my ($_bytes, $_delay, $_start);
   # called by MCE/Core/Manager.pm

   SYSREAD: $_bytes = ( @_ == 3
      ? CORE::sysread($_[0], $_[1], $_[2])
      : CORE::sysread($_[0], $_[1], $_[2], $_[3])
   )
   or do {
      unless ( defined $_bytes ) {
         goto SYSREAD if ($! == Errno::EINTR());

         # non-blocking operation could not be completed
         if ( $! == Errno::EWOULDBLOCK() || $! == Errno::EAGAIN() ) {
            sleep(0.015), goto SYSREAD if $_delay;

            # delay after a while to not consume a CPU core
            $_start = time unless $_start;
            $_delay = 1 if time - $_start > 0.030;

            goto SYSREAD;
         }
      }
   };

   return $_bytes;
}

sub _nonblocking {
   if ($^O eq 'MSWin32') {
      # MSWin32 FIONBIO - from winsock2.h macro
      my $nonblocking = $_[1] ? "\x00\x00\x00\x01" : "\x00\x00\x00\x00";

      ioctl($_[0], 0x8004667e, unpack("I", pack('P', $nonblocking)));
   }
   else {
      $_[0]->blocking( $_[1] ? 0 : 1 );
   }

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Private methods, providing high-resolution time, for MCE->yield,
## MCE::Child->yield, and MCE::Hobo->yield.
##
###############################################################################

## Use monotonic clock if available.

use constant CLOCK_MONOTONIC => eval {
   Time::HiRes::clock_gettime( Time::HiRes::CLOCK_MONOTONIC() );
   1;
};

sub _sleep {
   my ( $seconds ) = @_;
   return if ( $seconds < 0 );

   if ( $INC{'Coro/AnyEvent.pm'} ) {
      Coro::AnyEvent::sleep( $seconds );
   }
   elsif ( &Time::HiRes::d_nanosleep ) {
      Time::HiRes::nanosleep( $seconds * 1e9 );
   }
   elsif ( &Time::HiRes::d_usleep ) {
      Time::HiRes::usleep( $seconds * 1e6 );
   }
   else {
      Time::HiRes::sleep( $seconds );
   }

   return;
}

sub _time {
   return ( CLOCK_MONOTONIC )
      ? Time::HiRes::clock_gettime( Time::HiRes::CLOCK_MONOTONIC() )
      : Time::HiRes::time();
}

1;

__END__

###############################################################################
## ----------------------------------------------------------------------------
## Module usage.
##
###############################################################################

=head1 NAME

MCE::Util - Utility functions

=head1 VERSION

This document describes MCE::Util version 1.879

=head1 SYNOPSIS

 use MCE::Util;

=head1 DESCRIPTION

A utility module for MCE. Nothing is exported by default. Exportable is
get_ncpu.

=head2 get_ncpu()

Returns the number of logical (online/active/enabled) CPU cores; never smaller
than one.

 my $ncpu = MCE::Util::get_ncpu();

Specifying 'auto' for max_workers calls MCE::Util::get_ncpu automatically.
MCE 1.521 sets an upper-limit when specifying 'auto'. The reason is mainly
to safeguard apps from spawning 100 workers on a box having 100 cores.
This is important for apps which are IO-bound.

 use MCE;

 ## 'Auto' is the total # of logical cores (lcores) (8 maximum, MCE 1.521).
 ## The computed value will not exceed the # of logical cores on the box.

 my $mce = MCE->new(

 max_workers => 'auto',       ##  1 on HW with 1-lcores;  2 on  2-lcores
 max_workers =>  16,          ## 16 on HW with 4-lcores; 16 on 32-lcores

 max_workers => 'auto',       ##  4 on HW with 4-lcores;  8 on 16-lcores
 max_workers => 'auto*1.5',   ##  4 on HW with 4-lcores; 12 on 16-lcores
 max_workers => 'auto*2.0',   ##  4 on HW with 4-lcores; 16 on 16-lcores
 max_workers => 'auto/2.0',   ##  2 on HW with 4-lcores;  4 on 16-lcores
 max_workers => 'auto+3',     ##  4 on HW with 4-lcores; 11 on 16-lcores
 max_workers => 'auto-1',     ##  3 on HW with 4-lcores;  7 on 16-lcores

 max_workers => MCE::Util::get_ncpu,   ## run on all lcores
 );

In summary:

 1. Auto has an upper-limit of 8 in MCE 1.521 (# of lcores, 8 maximum)
 2. Math may be applied with auto (*/+-) to change the upper limit
 3. The computed value for auto will not exceed the total # of lcores
 4. One can specify max_workers explicitly to a hard value
 5. MCE::Util::get_ncpu returns the actual # of lcores

=head1 ACKNOWLEDGMENTS

The portable code for detecting the number of processors was adopted from
L<Test::Smoke::SysInfo>.

=head1 INDEX

L<MCE|MCE>, L<MCE::Core>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

