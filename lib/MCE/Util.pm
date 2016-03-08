###############################################################################
## ----------------------------------------------------------------------------
## Utility functions.
##
###############################################################################

package MCE::Util;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized );

our $VERSION = '1.700';

## no critic (BuiltinFunctions::ProhibitStringyEval)

use Socket qw( PF_UNIX PF_UNSPEC SOCK_STREAM SOL_SOCKET SO_SNDBUF SO_RCVBUF );
use Time::HiRes qw( sleep );
use base qw( Exporter );
use bytes;

my  $_is_winenv  = ($^O eq 'MSWin32' || $^O eq 'cygwin') ? 1 : 0;
my  $_zero_bytes = "\x00\x00\x00\x00";

our $LF = "\012";  Internals::SvREADONLY($LF, 1);

our @EXPORT_OK = qw( $LF get_ncpu );
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
         my ($count, $fh);
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
         my @output = `pmcycles -m 2>/dev/null`;
         if (@output) {
            $ncpu = scalar @output;
         } else {
            @output = `lsdev -Cc processor -S Available 2>/dev/null`;
            $ncpu = scalar @output if @output;
         }
         last OS_CHECK;
      };

      /gnu/ && do {
         chomp( my @output = `nproc 2>/dev/null` );
         $ncpu = $output[0] if @output;
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

      /mswin|mingw|cygwin/ && do {
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
## Private methods.
##
###############################################################################

sub _destroy_pipes {

   my ($_obj, @_params) = @_;
   local ($!, $?);

   for my $_p (@_params) {
      if (defined $_obj->{$_p}) {
         if (ref $_obj->{$_p} eq 'ARRAY') {
            for my $_i (0 .. @{ $_obj->{$_p} } - 1) {
               next unless (defined $_obj->{$_p}->[$_i]);
               close $_obj->{$_p}->[$_i];
               undef $_obj->{$_p}->[$_i];
            }
         }
         else {
            close $_obj->{$_p};
         }
         undef $_obj->{$_p};
      }
   }

   return;
}

sub _destroy_socks {

   my ($_obj, @_params) = @_;
   local ($!, $?);

   for my $_p (@_params) {
      if (defined $_obj->{$_p}) {
         if (ref $_obj->{$_p} eq 'ARRAY') {
            for my $_i (0 .. @{ $_obj->{$_p} } - 1) {
               next unless (defined $_obj->{$_p}->[$_i]);
               ## an empty socket may not close immediately in Windows/Cygwin
               syswrite $_obj->{$_p}->[$_i], '0' if ($_is_winenv); # hack
               CORE::shutdown $_obj->{$_p}->[$_i], 2;
               close $_obj->{$_p}->[$_i];
               undef $_obj->{$_p}->[$_i];
            }
         }
         else {
            syswrite $_obj->{$_p}, '0' if ($_is_winenv); # ditto
            CORE::shutdown $_obj->{$_p}, 2;
            close $_obj->{$_p};
         }
         undef $_obj->{$_p};
      }
   }

   return;
}

sub _pipe_pair {

   my ($_obj, $_r_sock, $_w_sock, $_i) = @_;
   my $_hndl; local ($|, $!);

   # Doing $_obj->{$_r_sock}->autoflush(1) adds ~ 5% additional memory
   # consumption from having to load IO::Handle.

   if (defined $_i) {
      pipe($_obj->{$_r_sock}->[$_i], $_obj->{$_w_sock}->[$_i])
         or die "pipe: $!\n";

      $_hndl = select $_obj->{$_r_sock}->[$_i]; $| = 1; # autoflush
               select $_obj->{$_w_sock}->[$_i]; $| = 1;
   }
   else {
      pipe($_obj->{$_r_sock}, $_obj->{$_w_sock})
         or die "pipe: $!\n";

      $_hndl = select $_obj->{$_r_sock}; $| = 1; # ditto
               select $_obj->{$_w_sock}; $| = 1;
   }

   select $_hndl;

   return;
}

sub _sock_pair {

   my ($_obj, $_r_sock, $_w_sock, $_i, $_size) = @_;
   my $_hndl; local ($|, $!);

   $_size = 16384 unless defined $_size;
   # Ditto on not calling autoflush(1).

   if (defined $_i) {
      socketpair( $_obj->{$_r_sock}->[$_i], $_obj->{$_w_sock}->[$_i],
         PF_UNIX, SOCK_STREAM, PF_UNSPEC ) or die "socketpair: $!\n";

      if ($^O ne 'aix' && $^O ne 'linux') {
         setsockopt($_obj->{$_r_sock}->[$_i], SOL_SOCKET, SO_SNDBUF, int $_size);
         setsockopt($_obj->{$_r_sock}->[$_i], SOL_SOCKET, SO_RCVBUF, int $_size);
         setsockopt($_obj->{$_w_sock}->[$_i], SOL_SOCKET, SO_SNDBUF, int $_size);
         setsockopt($_obj->{$_w_sock}->[$_i], SOL_SOCKET, SO_RCVBUF, int $_size);
      }

      $_hndl = select $_obj->{$_r_sock}->[$_i]; $| = 1; # autoflush
               select $_obj->{$_w_sock}->[$_i]; $| = 1;
   }
   else {
      socketpair( $_obj->{$_r_sock}, $_obj->{$_w_sock},
         PF_UNIX, SOCK_STREAM, PF_UNSPEC ) or die "socketpair: $!\n";

      if ($^O ne 'aix' && $^O ne 'linux') {
         setsockopt($_obj->{$_r_sock}, SOL_SOCKET, SO_SNDBUF, int $_size);
         setsockopt($_obj->{$_r_sock}, SOL_SOCKET, SO_RCVBUF, int $_size);
         setsockopt($_obj->{$_w_sock}, SOL_SOCKET, SO_SNDBUF, int $_size);
         setsockopt($_obj->{$_w_sock}, SOL_SOCKET, SO_RCVBUF, int $_size);
      }

      $_hndl = select $_obj->{$_r_sock}; $| = 1; # ditto
               select $_obj->{$_w_sock}; $| = 1;
   }

   select $_hndl;

   return;
}

sub _sock_ready {

   return if (
      !defined $_[1] && !$INC{'MCE/Hobo.pm'} && defined $MCE::VERSION
   );

   my ($_val_bytes, $_socket, $_timeout) = ("\x00\x00\x00\x00", @_);
   my $_ptr_bytes = unpack('I', pack('P', $_val_bytes));

   if ($_timeout) {
      $_timeout += time();
      while (1) {
         ioctl($_socket, 0x4004667f, $_ptr_bytes);  # MSWin32 FIONREAD
       # return '' if unpack('I', $_val_bytes);     # unpack isn't needed here
         return '' if $_val_bytes ne $_zero_bytes;  # this completes 2x faster
         return 1  if time() > $_timeout;
         sleep 0.045;
      }
   }
   else {
      my $_count = 0;
      while (1) {
         ioctl($_socket, 0x4004667f, $_ptr_bytes);  # Ditto
         return if $_val_bytes ne $_zero_bytes;
         $_count = 0, sleep 0.008 if ++$_count > 1618;
      }
   }
}

sub _parse_max_workers {

   my ($_max_workers) = @_;

   @_ = ();

   return $_max_workers unless (defined $_max_workers);

   if ($_max_workers =~ /^auto(?:$|\s*([\-\+\/\*])\s*(.+)$)/i) {
      my ($_ncpu_ul, $_ncpu);

      $_ncpu_ul = $_ncpu = get_ncpu();
      $_ncpu_ul = 8 if ($_ncpu_ul > 8);

      if ($1 && $2) {
         local $@; $_max_workers = eval "int($_ncpu_ul $1 $2 + 0.5)";
         $_max_workers = 1 if (!$_max_workers || $_max_workers < 1);
         $_max_workers = $_ncpu if ($_max_workers > $_ncpu);
      }
      else {
         $_max_workers = $_ncpu_ul;
      }
   }

   return $_max_workers;
}

sub _parse_chunk_size {

   my ($_chunk_size, $_max_workers, $_params, $_input_data, $_array_size) = @_;

   @_ = ();

   return $_chunk_size if (!defined $_chunk_size || !defined $_max_workers);

   if (defined $_params && exists $_params->{chunk_size}) {
      $_chunk_size = $_params->{chunk_size};
   }

   if ($_chunk_size =~ /([0-9\.]+)K\z/i) {
      $_chunk_size = int($1 * 1024 + 0.5);
   }
   elsif ($_chunk_size =~ /([0-9\.]+)M\z/i) {
      $_chunk_size = int($1 * 1024 * 1024 + 0.5);
   }

   if ($_chunk_size eq 'auto') {

      if ( (defined $_params && ref $_params->{input_data} eq 'CODE') ||
           (defined $_input_data && ref $_input_data eq 'CODE')
      ) {
         ## Iterators may optionally use chunk_size to determine how much
         ## to return per iteration. The default is 1 for MCE Models, same
         ## as for the Core API. The user_func receives an array_ref
         ## regardless if 1 or higher.
         ##
         ## sub make_iter {
         ##    ...
         ##    return sub {
         ##       my ($chunk_size) = @_;
         ##       ...
         ##    };
         ## }
         return 1;
      }

      my $_size = (defined $_input_data && ref $_input_data eq 'ARRAY')
         ? scalar @{ $_input_data } : $_array_size;

      my $_is_file;

      if (defined $_params && exists $_params->{sequence}) {
         my ($_begin, $_end, $_step);

         if (ref $_params->{sequence} eq 'HASH') {
            $_begin = $_params->{sequence}->{begin};
            $_end   = $_params->{sequence}->{end};
            $_step  = $_params->{sequence}->{step} || 1;
         }
         else {
            $_begin = $_params->{sequence}->[0];
            $_end   = $_params->{sequence}->[1];
            $_step  = $_params->{sequence}->[2] || 1;
         }

         if (!defined $_input_data && !$_array_size) {
            $_size = abs($_end - $_begin) / $_step + 1;
         }
      }
      elsif (defined $_params && exists $_params->{_file}) {
         my $_ref = ref $_params->{_file};

         if ($_ref eq 'SCALAR') {
            $_size = length ${ $_params->{_file} };
         } elsif ($_ref eq '') {
            $_size = -s $_params->{_file};
         } else {
            $_size = 0; $_chunk_size = 245_760;
         }

         $_is_file = 1;
      }
      elsif (defined $_input_data) {
         if (ref $_input_data eq 'GLOB' || ref($_input_data) =~ /^IO::/) {
            $_is_file = 1; $_size = 0; $_chunk_size = 245_760;
         }
         elsif (ref $_input_data eq 'SCALAR') {
            $_is_file = 1; $_size = length ${ $_input_data };
         }
      }

      if (defined $_is_file) {
         if ($_size) {
            $_chunk_size = int($_size / $_max_workers / 24 + 0.5);
            $_chunk_size = 4_194_304 if $_chunk_size > 4_194_304;  ## 4M
            $_chunk_size = 2 if $_chunk_size <= 8192;
         }
      }
      else {
         $_chunk_size = int($_size / $_max_workers / 24 + 0.5);
         $_chunk_size = 8000 if $_chunk_size > 8000;
         $_chunk_size = 2 if $_chunk_size < 2;
      }
   }

   return $_chunk_size;
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

This document describes MCE::Util version 1.700

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
 2. Math can be applied with auto (*/+-) to change the upper limit
 3. The computed value for auto will not exceed the total # of lcores
 4. One can specify max_workers explicity to a hard value
 5. MCE::Util::get_ncpu returns the actual # of lcores

=head1 ACKNOWLEDGEMENTS

The portable code for detecting the number of processors was adopted from
L<Test::Smoke::SysInfo>.

=head1 INDEX

L<MCE|MCE>, L<MCE::Core>, L<MCE::Shared>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

