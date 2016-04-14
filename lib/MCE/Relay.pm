###############################################################################
## ----------------------------------------------------------------------------
## Extends Many-Core Engine with relay capabilities.
##
###############################################################################

package MCE::Relay;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized );

our $VERSION = '1.705';

## no critic (Subroutines::ProhibitSubroutinePrototypes)

use bytes;

use constant {
   OUTPUT_W_RLA => 'W~RLA',  # Worker has relayed
};

###############################################################################
## ----------------------------------------------------------------------------
## Import routine.
##
###############################################################################

my $LF = "\012";  Internals::SvREADONLY($LF, 1);
my $_imported;

sub import {

   my $_class = shift; return if ($_imported++);

   if (defined $MCE::VERSION) {
      _mce_m_init();
   }
   else {
      $\ = undef; require Carp;
      Carp::croak(
         "MCE::Relay cannot be used directly. Please consult the MCE::Relay\n".
         "documentation for more information.\n\n"
      );
   }

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Output routines for the manager process.
##
###############################################################################

{
   my ($_MCE, $_DAU_R_SOCK_REF, $_DAU_R_SOCK, $_rla_chunkid, $_rla_nextid);

   my %_output_function = (

      OUTPUT_W_RLA.$LF => sub {                   # Worker has relayed

         $_DAU_R_SOCK = ${ $_DAU_R_SOCK_REF };

         my ($_chunk_id, $_next_id) = split(':', <$_DAU_R_SOCK>);

         if ($_chunk_id > $_rla_chunkid) {
            chomp $_next_id;
            $_rla_chunkid = $_chunk_id;
            $_rla_nextid  = $_next_id;
         }

         return;
      },

   );

   sub _mce_m_loop_begin {

      ($_MCE, $_DAU_R_SOCK_REF) = @_;

      ## Write initial relay data.
      if (defined $_MCE->{init_relay}) {
         my $_ref = ref $_MCE->{init_relay};

         MCE::_croak("MCE::Relay: (init_relay) is not valid")
            if ($_ref ne '' && $_ref ne 'HASH' && $_ref ne 'ARRAY');

         my $_RLA_W_SOCK = $_MCE->{_rla_w_sock}->[0];
         my $_init_relay;

         if (ref $_MCE->{init_relay} eq '') {
            $_init_relay = $_MCE->{init_relay} . '0';
         }
         elsif (ref $_MCE->{init_relay} eq 'HASH') {
            $_init_relay = $_MCE->{freeze}($_MCE->{init_relay}) . '1';
         }
         elsif (ref $_MCE->{init_relay} eq 'ARRAY') {
            $_init_relay = $_MCE->{freeze}($_MCE->{init_relay}) . '2';
         }

         print {$_RLA_W_SOCK} length($_init_relay) . $LF . $_init_relay;
         delete $_MCE->{_rla_return} if (exists $_MCE->{_rla_return});

         $_rla_chunkid = $_rla_nextid = 0;
      }

      return;
   }

   sub _mce_m_loop_end {

      ## Obtain final relay data.
      if (defined $_MCE->{init_relay}) {
         my $_RLA_R_SOCK = $_MCE->{_rla_r_sock}->[$_rla_nextid];
         my ($_len, $_ret); chomp($_len = <$_RLA_R_SOCK>);

         read $_RLA_R_SOCK, $_ret, $_len;

         if (chop $_ret) {
            $_MCE->{_rla_return} = $_MCE->{thaw}($_ret);
         } else {
            $_MCE->{_rla_return} = $_ret;
         }
      }

      ## Clear variables.
      $_MCE = $_DAU_R_SOCK_REF = $_DAU_R_SOCK = $_rla_chunkid = $_rla_nextid =
         undef;

      return;
   }

   sub _mce_m_init {

      MCE::_attach_plugin(
         \%_output_function, \&_mce_m_loop_begin, \&_mce_m_loop_end
      );

      return;
   }
}

###############################################################################
## ----------------------------------------------------------------------------
## Relay methods.
##
###############################################################################

## Items below are folded into MCE.

package MCE;

no warnings 'threads';
no warnings 'recursion';
no warnings 'uninitialized';

use Scalar::Util qw( weaken );
use bytes;

no warnings 'redefine';

sub relay_final {

   my $x = shift; my $self = ref($x) ? $x : $MCE::MCE;

   _croak('MCE::relay_final: method is not allowed by the worker process')
      if ($self->{_wid});

   if (exists $self->{_rla_return}) {
      if (ref $self->{_rla_return} eq '') {
         return delete $self->{_rla_return};
      }
      elsif (ref $self->{_rla_return} eq 'HASH') {
         return %{ delete $self->{_rla_return} };
      }
      elsif (ref $self->{_rla_return} eq 'ARRAY') {
         return @{ delete $self->{_rla_return} };
      }
   }

   return;
}

sub relay_recv {

   my $x = shift; my $self = ref($x) ? $x : $MCE::MCE;

   _croak('MCE::relay: (init_relay) is not specified')
      unless (defined $self->{init_relay});
   _croak('MCE::relay: method is not allowed by the manager process')
      unless ($self->{_wid});
   _croak('MCE::relay: method is not allowed by this sub task')
      if ($self->{_task_id} > 0);

   my $_chn = ($self->{_chunk_id} - 1) % $self->{max_workers};
   my $_rdr = $self->{_rla_r_sock}->[$_chn];

   my ($_len, $_ref); local $_;

   chomp($_len = <$_rdr>);
   read $_rdr, $_, $_len;
   $_ref = chop $_;

   if ($_ref == 0) {                                 ## scalar value
      $self->{_rla_data} = $_;
      return unless defined wantarray;
      return $self->{_rla_data};
   }
   elsif ($_ref == 1) {                              ## hash reference
      $self->{_rla_data} = $self->{thaw}($_);
      return unless defined wantarray;
      return %{ $self->{_rla_data} };
   }
   elsif ($_ref == 2) {                              ## array reference
      $self->{_rla_data} = $self->{thaw}($_);
      return unless defined wantarray;
      return @{ $self->{_rla_data} };
   }

   return;
}

sub relay (;&) {

   my ($self, $_code);

   if (ref $_[0] eq 'CODE') {
      ($self, $_code) = ($MCE::MCE, shift);
   } else {
      my $x = shift; $self = ref($x) ? $x : $MCE::MCE;
      $_code = shift;
   }

   _croak('MCE::relay: (init_relay) is not specified')
      unless (defined $self->{init_relay});
   _croak('MCE::relay: method is not allowed by the manager process')
      unless ($self->{_wid});
   _croak('MCE::relay: method is not allowed by this sub task')
      if ($self->{_task_id} > 0);

   if (ref $_code ne 'CODE') {
      _croak('MCE::relay: argument is not a code block') if (defined $_code);
   } else {
      weaken $_code;
   }

   my $_chn = ($self->{_chunk_id} - 1) % $self->{max_workers};
   my $_nxt = $_chn + 1; $_nxt = 0 if ($_nxt == $self->{max_workers});
   my $_rdr = $self->{_rla_r_sock}->[$_chn];
   my $_wtr = $self->{_rla_w_sock}->[$_nxt];

   $self->{_rla_return} = $self->{_chunk_id} .':'. $_nxt;

   if (exists $self->{_rla_data}) {
      local $_ = delete $self->{_rla_data};
      $_code->() if (ref $_code eq 'CODE');

      if (ref $_ eq '') {                         ## scalar value
         my $_tmp = $_ . '0';
         print {$_wtr} length($_tmp) . $LF . $_tmp;
      }
      elsif (ref $_ eq 'HASH') {                  ## hash reference
         my $_tmp = $self->{freeze}($_) . '1';
         print {$_wtr} length($_tmp) . $LF . $_tmp;
      }
      elsif (ref $_ eq 'ARRAY') {                 ## array reference
         my $_tmp = $self->{freeze}($_) . '2';
         print {$_wtr} length($_tmp) . $LF . $_tmp;
      }
   }
   else {
      my ($_len, $_ref); local $_;

      chomp($_len = <$_rdr>);
      read $_rdr, $_, $_len;
      $_ref = chop $_;

      if ($_ref == 0) {                              ## scalar value
         my $_ret = $_;         $_code->() if (ref $_code eq 'CODE');
         my $_tmp = $_ . '0';
         print {$_wtr} length($_tmp) . $LF . $_tmp;
         return unless defined wantarray;
         return $_ret;
      }
      elsif ($_ref == 1) {                           ## hash reference
         my %_ret = %{ $self->{thaw}($_) };
         local $_ = { %_ret };  $_code->() if (ref $_code eq 'CODE');
         my $_tmp = $self->{freeze}($_) . '1';
         print {$_wtr} length($_tmp) . $LF . $_tmp;
         return unless defined wantarray;
         return %_ret;
      }
      elsif ($_ref == 2) {                           ## array reference
         my @_ret = @{ $self->{thaw}($_) };
         local $_ = [ @_ret ];  $_code->() if (ref $_code eq 'CODE');
         my $_tmp = $self->{freeze}($_) . '2';
         print {$_wtr} length($_tmp) . $LF . $_tmp;
         return unless defined wantarray;
         return @_ret;
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

MCE::Relay - Extends Many-Core Engine with relay capabilities

=head1 VERSION

This document describes MCE::Relay version 1.705

=head1 SYNOPSIS

   use MCE::Flow;

   my $file = shift || \*STDIN;

   ## Line Count #######################################

   mce_flow_f {
      use_slurpio => 1, init_relay => 0,
   },
   sub {
      my ($mce, $slurp_ref, $chunk_id) = @_;
      my $line_count = ($$slurp_ref =~ tr/\n//);

      ## Receive and pass on updated information.
      my $lines_read = MCE::relay { $_ += $line_count };

   }, $file;

   my $total_lines = MCE->relay_final;

   print {*STDERR} "$total_lines\n";

   ## Orderly Action ###################################

   mce_flow_f {
      use_slurpio => 1, init_relay => 0,
   },
   sub {
      my ($mce, $slurp_ref, $chunk_id) = @_;

      ## Exclusive access to STDOUT. Relays 0.
      MCE::relay { print $$slurp_ref };

   }, $file;

=head1 DESCRIPTION

This module enables workers to receive and pass on information orderly with
zero involvement by the manager process while running. The module is loaded
automatically when init_relay is specified.

All workers must participate when relaying data. Calling relay more than once
is not recommended inside the block. Doing so will stall the application.

Relaying is not meant for passing big data. The last worker will likely stall
if exceeding the buffer size for the socket. Not exceeding 16 KiB - 7 is safe
across all platforms.

=head1 API DOCUMENTATION

=over 3

=item MCE->relay ( sub { code } )

=item MCE::relay { code }

Relay is enabled by specifying the init_relay option which takes a hash or array
reference, or a scalar value. Relaying is orderly and driven by chunk_id when
processing data, otherwise task_wid. Omitting the code block (e.g. MCE::relay)
relays forward.

Below, relaying multiple values via a HASH reference.

   use MCE::Flow max_workers => 4;

   mce_flow {
      init_relay => { p => 0, e => 0 },
   },
   sub {
      my $wid = MCE->wid;

      ## do work
      my $pass = $wid % 3;
      my $errs = $wid % 2;

      ## relay
      my %last_rpt = MCE::relay { $_->{p} += $pass; $_->{e} += $errs };

      MCE->print("$wid: passed $pass, errors $errs\n");

      return;
   };

   my %results = MCE->relay_final;

   print "   passed $results{p}, errors $results{e} final\n\n";

   -- Output

   1: passed 1, errors 1
   2: passed 2, errors 0
   3: passed 0, errors 1
   4: passed 1, errors 0
      passed 4, errors 2 final

Or multiple values via an ARRAY reference.

   use MCE::Flow max_workers => 4;

   mce_flow {
      init_relay => [ 0, 0 ],
   },
   sub {
      my $wid = MCE->wid;

      ## do work
      my $pass = $wid % 3;
      my $errs = $wid % 2;

      ## relay
      my @last_rpt = MCE::relay { $_->[0] += $pass; $_->[1] += $errs };

      MCE->print("$wid: passed $pass, errors $errs\n");

      return;
   };

   my ($pass, $errs) = MCE->relay_final;

   print "   passed $pass, errors $errs final\n\n";

   -- Output

   1: passed 1, errors 1
   2: passed 2, errors 0
   3: passed 0, errors 1
   4: passed 1, errors 0
      passed 4, errors 2 final

Or simply a scalar value.

   use MCE::Flow max_workers => 4;

   mce_flow {
      init_relay => 0,
   },
   sub {
      my $wid = MCE->wid;

      ## do work
      my $bytes_read = 1000 + ((MCE->wid % 3) * 3);

      ## relay
      my $last_offset = MCE::relay { $_ += $bytes_read };

      ## output
      MCE->print("$wid: $bytes_read\n");

      return;
   };

   my $total = MCE->relay_final;

   print "   $total size\n\n";

   -- Output

   1: 1003
   2: 1006
   3: 1000
   4: 1003
      4012 size

=item MCE->relay_final ( void )

Call this method to obtain the final relay values after running. See included
example findnull.pl for another use case.

   use MCE max_workers => 4;

   my $mce = MCE->new(
      init_relay => [ 0, 100 ],       ## initial values (two counters)

      user_func => sub {
         my ($mce) = @_;

         ## do work
         my ($acc1, $acc2) = (10, 20);

         ## relay to next worker
         MCE::relay { $_->[0] += $acc1; $_->[1] += $acc2 };

         return;
      }
   )->run;

   my ($cnt1, $cnt2) = $mce->relay_final;

   print "$cnt1 : $cnt2\n";

   -- Output

   40 : 180

=item MCE->relay_recv ( void )

The relay_recv method allows one to perform an exclusive action prior to
relaying. Below, the user_func is taken from the cat.pl example. Relaying
is chunk_id driven (or task_wid when not processing input), thus orderly.

   user_func => sub {
      my ($mce, $chunk_ref, $chunk_id) = @_;

      if ($n_flag) {
         ## Relays the total lines read.

         my $output = ''; my $line_count = ($$chunk_ref =~ tr/\n//);
         my $lines_read = MCE::relay { $_ += $line_count };

         open my $fh, '<', $chunk_ref;
         $output .= sprintf "%6d\t%s", ++$lines_read, $_ while (<$fh>);
         close $fh;

         $output .= ":$chunk_id";
         MCE->do('display_chunk', $output);
      }
      else {
         ## The following is another way to have ordered output. Workers
         ## write directly to STDOUT exclusively without any involvement
         ## from the manager process. The statements between relay_recv
         ## and relay run serially and most important orderly.

         ## STDERR/OUT flush automatically inside worker threads and
         ## processes. Disable buffering on file handles otherwise.

         MCE->relay_recv;             ## my $val = MCE->relay_recv;
                                      ## relay simply forwards 0 below

         print $$chunk_ref;           ## exclusive access to STDOUT
                                      ## important, flush immediately

         MCE->relay;
      }

      return;
   }

=back

=head1 INDEX

L<MCE|MCE>, L<MCE::Core>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

