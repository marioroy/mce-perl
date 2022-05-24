###############################################################################
## ----------------------------------------------------------------------------
## Extends Many-Core Engine with relay capabilities.
##
###############################################################################

package MCE::Relay;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized numeric );

our $VERSION = '1.879';

## no critic (Subroutines::ProhibitSubroutinePrototypes)

use constant {
   OUTPUT_W_RLA => 'W~RLA',  # Worker has relayed
   OUTPUT_R_NFY => 'R~NFY',  # Relay notification
};

###############################################################################
## ----------------------------------------------------------------------------
## Import routine.
##
###############################################################################

my $LF = "\012";  Internals::SvREADONLY($LF, 1);
my $_imported;

sub import {

   return if ($_imported++);

   if ($INC{'MCE.pm'}) {
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
   my ($_MCE, $_DAU_R_SOCK_REF, $_DAU_R_SOCK, $_rla_nextid, $_max_workers);

   my %_output_function = (

      OUTPUT_W_RLA.$LF => sub {                   # Worker has relayed

         $_rla_nextid = 0 if ( ++$_rla_nextid == $_max_workers );

         return;
      },

      OUTPUT_R_NFY.$LF => sub {                   # Relay notification

         $_MCE->{_relayed}++;

         return;
      },

   );

   sub _mce_m_loop_begin {

      ($_MCE, $_DAU_R_SOCK_REF) = @_;

      my $_caller = $_MCE->{_caller};

      $_max_workers = (exists $_MCE->{user_tasks})
         ? $_MCE->{user_tasks}[0]{max_workers}
         : $_MCE->{max_workers};

      ## Write initial relay data.
      if (defined $_MCE->{init_relay}) {
         my $_ref = ref $_MCE->{init_relay};

         MCE::_croak("MCE::Relay: (init_relay) is not valid")
            if ($_ref ne '' && $_ref ne 'HASH' && $_ref ne 'ARRAY');

         my $_RLA_W_SOCK = $_MCE->{_rla_w_sock}->[0];
         my $_init_relay;

         $_MCE->{_relayed} = 0;

         if (ref $_MCE->{init_relay} eq '') {
            $_init_relay = $_MCE->{freeze}(\$_MCE->{init_relay}) . '0';
         }
         elsif (ref $_MCE->{init_relay} eq 'HASH') {
            $_init_relay = $_MCE->{freeze}($_MCE->{init_relay}) . '1';
         }
         elsif (ref $_MCE->{init_relay} eq 'ARRAY') {
            $_init_relay = $_MCE->{freeze}($_MCE->{init_relay}) . '2';
         }

         print {$_RLA_W_SOCK} length($_init_relay) . $LF . $_init_relay;

         $_rla_nextid = 0;
      }

      delete $MCE::RLA->{$_caller};

      return;
   }

   sub _mce_m_loop_end {

      ## Obtain final relay data.
      if (defined $_MCE->{init_relay}) {
         my $_RLA_R_SOCK = $_MCE->{_rla_r_sock}->[$_rla_nextid];
         my ($_caller, $_len, $_ret) = ($_MCE->{_caller});

         delete $_MCE->{_relayed};

         MCE::Util::_sock_ready($_RLA_R_SOCK, -1) if $^O eq 'MSWin32';
         chomp($_len = <$_RLA_R_SOCK>);
         read $_RLA_R_SOCK, $_ret, $_len;

         if (chop $_ret) {
            $MCE::RLA->{$_caller} = $_MCE->{thaw}($_ret);
         } else {
            $MCE::RLA->{$_caller} = ${ $_MCE->{thaw}($_ret) };
         }
      }

      ## Clear variables.
      $_MCE = $_DAU_R_SOCK_REF = $_DAU_R_SOCK = undef;
      $_rla_nextid = $_max_workers = undef;

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

package # hide from rpm
   MCE;

no warnings qw( threads recursion uninitialized redefine );

use Scalar::Util qw( weaken );

sub relay_final {

   my $x = shift; my $self = ref($x) ? $x : $MCE::MCE;

   _croak('MCE::relay_final: method is not allowed by the worker process')
      if ($self->{_wid});

   my $_caller = caller;

   if (exists $MCE::RLA->{$_caller}) {
      if (ref $MCE::RLA->{$_caller} eq '') {
         return delete $MCE::RLA->{$_caller};
      }
      elsif (ref $MCE::RLA->{$_caller} eq 'HASH') {
         return %{ delete $MCE::RLA->{$_caller} };
      }
      elsif (ref $MCE::RLA->{$_caller} eq 'ARRAY') {
         return @{ delete $MCE::RLA->{$_caller} };
      }

      # should not reach the following line
      delete $MCE::RLA->{$_caller};
   }

   return;
}

sub relay_recv {

   my $x = shift; my $self = ref($x) ? $x : $MCE::MCE;

   _croak('MCE::relay_recv: (init_relay) is not specified')
      unless (defined $self->{init_relay});
   _croak('MCE::relay_recv: method is not allowed by the manager process')
      unless ($self->{_wid});
   _croak('MCE::relay_recv: method is not allowed by task_id > 0')
      if ($self->{_task_id} > 0);

   my ($_chn, $_nxt, $_rdr, $_len, $_ref); local $_;

   local $\ = undef if (defined $\);
   local $/ = $LF   if ($/ ne $LF );

   $_chn = $self->{_chunk_id} || $self->{_wid};
   $_chn = ($_chn - 1) % $self->{max_workers};
   $_nxt = $_chn + 1;
   $_nxt = 0 if ($_nxt == $self->{max_workers});
   $_rdr = $self->{_rla_r_sock}->[$_chn];

   print {$self->{_dat_w_sock}->[0]} OUTPUT_W_RLA.$LF . '0'.$LF;

   MCE::Util::_sock_ready($_rdr, -1) if $^O eq 'MSWin32';
   chomp($_len = <$_rdr>);
   read $_rdr, $_, $_len;
   $_ref = chop $_;

   if ($_ref == 0) {                                 ## scalar value
      $self->{_rla_data} = ${ $self->{thaw}($_) };
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
   _croak('MCE::relay: method is not allowed by task_id > 0')
      if ($self->{_task_id} > 0);

   if (ref $_code ne 'CODE') {
      _croak('MCE::relay: argument is not a code block') if (defined $_code);
   } else {
      weaken $_code;
   }

   my ($_chn, $_cid, $_nxt, $_rdr, $_wtr);

   local $\ = undef if (defined $\);
   local $/ = $LF   if ($/ ne $LF );

   $_chn = $_cid = $self->{_chunk_id} || $self->{_wid};
   $_chn = ($_chn - 1) % $self->{max_workers};
   $_nxt = $_chn + 1;
   $_nxt = 0 if ($_nxt == $self->{max_workers});
   $_rdr = $self->{_rla_r_sock}->[$_chn];
   $_wtr = $self->{_rla_w_sock}->[$_nxt];

   if (exists $self->{_rla_data}) {
      my $_tmp; local $_ = delete $self->{_rla_data};
      $_code->() if (ref $_code eq 'CODE');

      if (ref $_ eq '') {                         ## scalar value
         $_tmp = $self->{freeze}(\$_) . '0';
      }
      elsif (ref $_ eq 'HASH') {                  ## hash reference
         $_tmp = $self->{freeze}($_) . '1';
      }
      elsif (ref $_ eq 'ARRAY') {                 ## array reference
         $_tmp = $self->{freeze}($_) . '2';
      }

      print {$_wtr} length($_tmp) . $LF . $_tmp;
      print {$self->{_dat_w_sock}->[0]} OUTPUT_R_NFY.$LF . '0'.$LF;
      $self->{_relayed} = $_cid;
   }
   else {
      my ($_len, $_ref); local $_;
      print {$self->{_dat_w_sock}->[0]} OUTPUT_W_RLA.$LF . '0'.$LF;

      MCE::Util::_sock_ready($_rdr, -1) if $^O eq 'MSWin32';
      chomp($_len = <$_rdr>);
      read $_rdr, $_, $_len;
      $_ref = chop $_;

      if ($_ref == 0) {                              ## scalar value
         my $_ret = ${ $self->{thaw}($_) };
         local $_ = $_ret;      $_code->() if (ref $_code eq 'CODE');
         my $_tmp = $self->{freeze}(\$_) . '0';

         print {$_wtr} length($_tmp) . $LF . $_tmp;
         print {$self->{_dat_w_sock}->[0]} OUTPUT_R_NFY.$LF . '0'.$LF;
         $self->{_relayed} = $_cid;

         return unless defined wantarray;
         return $_ret;
      }
      elsif ($_ref == 1) {                           ## hash reference
         my %_ret = %{ $self->{thaw}($_) };
         local $_ = { %_ret };  $_code->() if (ref $_code eq 'CODE');
         my $_tmp = $self->{freeze}($_) . '1';

         print {$_wtr} length($_tmp) . $LF . $_tmp;
         print {$self->{_dat_w_sock}->[0]} OUTPUT_R_NFY.$LF . '0'.$LF;
         $self->{_relayed} = $_cid;

         return unless defined wantarray;
         return %_ret;
      }
      elsif ($_ref == 2) {                           ## array reference
         my @_ret = @{ $self->{thaw}($_) };
         local $_ = [ @_ret ];  $_code->() if (ref $_code eq 'CODE');
         my $_tmp = $self->{freeze}($_) . '2';

         print {$_wtr} length($_tmp) . $LF . $_tmp;
         print {$self->{_dat_w_sock}->[0]} OUTPUT_R_NFY.$LF . '0'.$LF;
         $self->{_relayed} = $_cid;

         return unless defined wantarray;
         return @_ret;
      }
   }

   return;
}

## Aliases.

*relay_lock   = \&relay_recv;
*relay_unlock = \&relay;

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

This document describes MCE::Relay version 1.879

=head1 SYNOPSIS

 use MCE::Flow;

 my $file = shift || \*STDIN;

 ## Line Count #######################################

 mce_flow_f {
    max_workers => 4,
    use_slurpio => 1,
    init_relay  => 0,
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

 $| = 1; # Important, must flush output immediately.

 mce_flow_f {
    max_workers => 2,
    use_slurpio => 1,
    init_relay  => 0,
 },
 sub {
    my ($mce, $slurp_ref, $chunk_id) = @_;

    ## The relay value is relayed and remains 0.
    ## Writes to STDOUT orderly.

    MCE->relay_lock;
    print $$slurp_ref;
    MCE->relay_unlock;

 }, $file;

=head1 DESCRIPTION

This module enables workers to receive and pass on information orderly with
zero involvement by the manager process while running. The module is loaded
automatically when MCE option C<init_relay> is specified.

All workers (belonging to task_id 0) must participate when relaying data.

Relaying is not meant for passing big data. The last worker will stall if
exceeding the buffer size for the socket. Not exceeding 16 KiB - 7 is safe
across all platforms.

=head1 API DOCUMENTATION

=over 3

=item MCE::relay { code }

=item MCE->relay ( sub { code } )

=item $mce->relay ( sub { code } )

=back

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

=over 3

=item MCE->relay_final ( void )

=item $mce->relay_final ( void )

=back

Call this method to obtain the final relay value(s) after running. See included
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

=over 3

=item MCE->relay_recv ( void )

=item $mce->relay_recv ( void )

=back

Call this method to obtain the next relay value before relaying. This allows
serial-code to be processed orderly between workers. The following is a parallel
demonstration for the fasta-benchmark on the web.

 # perl fasta.pl 25000000

 # The Computer Language Benchmarks game
 # https://benchmarksgame-team.pages.debian.net/benchmarksgame/
 #
 # contributed by Barry Walsh
 # port of fasta.rb #6
 #
 # MCE::Flow version by Mario Roy
 # requires MCE 1.807+
 # requires MCE::Shared 1.806+

 use strict;
 use warnings;
 use feature 'say';

 use MCE::Flow;
 use MCE::Shared;
 use MCE::Candy;

 use constant IM => 139968;
 use constant IA => 3877;
 use constant IC => 29573;

 my $LAST = MCE::Shared->scalar( 42 );

 my $alu =
    'GGCCGGGCGCGGTGGCTCACGCCTGTAATCCCAGCACTTTGG' .
    'GAGGCCGAGGCGGGCGGATCACCTGAGGTCAGGAGTTCGAGA' .
    'CCAGCCTGGCCAACATGGTGAAACCCCGTCTCTACTAAAAAT' .
    'ACAAAAATTAGCCGGGCGTGGTGGCGCGCGCCTGTAATCCCA' .
    'GCTACTCGGGAGGCTGAGGCAGGAGAATCGCTTGAACCCGGG' .
    'AGGCGGAGGTTGCAGTGAGCCGAGATCGCGCCACTGCACTCC' .
    'AGCCTGGGCGACAGAGCGAGACTCCGTCTCAAAAA';

 my $iub = [
    [ 'a', 0.27 ], [ 'c', 0.12 ], [ 'g', 0.12 ],
    [ 't', 0.27 ], [ 'B', 0.02 ], [ 'D', 0.02 ],
    [ 'H', 0.02 ], [ 'K', 0.02 ], [ 'M', 0.02 ],
    [ 'N', 0.02 ], [ 'R', 0.02 ], [ 'S', 0.02 ],
    [ 'V', 0.02 ], [ 'W', 0.02 ], [ 'Y', 0.02 ]
 ];

 my $homosapiens = [
    [ 'a', 0.3029549426680 ],
    [ 'c', 0.1979883004921 ],
    [ 'g', 0.1975473066391 ],
    [ 't', 0.3015094502008 ]
 ];

 sub make_repeat_fasta {
    my ( $src, $n ) = @_;
    my $width = qr/(.{1,60})/;
    my $l     = length $src;
    my $s     = $src x ( ($n / $l) + 1 );
    substr( $s, $n, $l ) = '';

    while ( $s =~ m/$width/g ) { say $1 }
 }

 sub make_random_fasta {
    my ( $table, $n ) = @_;
    my $rand   = undef;
    my $width  = 60;
    my $prob   = 0.0;
    my $output = '';
    my ( $c1, $c2, $last );

    $_->[1] = ( $prob += $_->[1] ) for @$table;

    $c1  = '$rand = ( $last = ( $last * IA + IC ) % IM ) / IM;';
    $c1 .= "\$output .= '$_->[0]', next if $_->[1] > \$rand;\n" for @$table;

    my $seq = MCE::Shared->sequence(
       { chunk_size => 2000, bounds_only => 1 },
       1, $n / $width
    );

    my $code1 = q{
       while ( 1 ) {
          # --------------------------------------------
          # Process code orderly between workers.
          # --------------------------------------------

          my $chunk_id = MCE->relay_recv;
          my ( $begin, $end ) = $seq->next;

          MCE->relay, last if ( !defined $begin );

          my $last = $LAST->get;
          my $temp = $last;

          # Pre-compute $LAST value for the next worker
          for ( 1 .. ( $end - $begin + 1 ) * $width ) {
             $temp = ( $temp * IA + IC ) % IM;
          }

          $LAST->set( $temp );

          # Increment chunk_id value
          MCE->relay( sub { $_ += 1 } );

          # --------------------------------------------
          # Also run code in parallel between workers.
          # --------------------------------------------

          for ( $begin .. $end ) {
             for ( 1 .. $width ) { !C! }
             $output .= "\n";
          }

          # --------------------------------------------
          # Display orderly.
          # --------------------------------------------

          MCE->gather( $chunk_id, $output );

          $output = '';
       }
    };

    $code1 =~ s/!C!/$c1/g;

    MCE::Flow->init(
       max_workers => 4, ## MCE::Util->get_ncpu || 4,
       gather      => MCE::Candy::out_iter_fh( \*STDOUT ),
       init_relay  => 1,
       use_threads => 0,
    );

    MCE::Flow->run( sub { eval $code1 } );
    MCE::Flow->finish;

    $last = $LAST->get;

    $c2  = '$rand = ( $last = ( $last * IA + IC ) % IM ) / IM;';
    $c2 .= "print('$_->[0]'), next if $_->[1] > \$rand;\n" for @$table;

    my $code2 = q{
       if ( $n % $width != 0 ) {
          for ( 1 .. $n % $width ) { !C! }
          print "\n";
       }
    };

    $code2 =~ s/!C!/$c2/g;
    eval $code2;

    $LAST->set( $last );
 }

 my $n = $ARGV[0] || 27;

 say ">ONE Homo sapiens alu";
 make_repeat_fasta( $alu, $n * 2 );

 say ">TWO IUB ambiguity codes";
 make_random_fasta( $iub, $n * 3 );

 say ">THREE Homo sapiens frequency";
 make_random_fasta( $homosapiens, $n * 5 );

=over 3

=item MCE->relay_lock ( void )

=item MCE->relay_unlock ( void )

=item $mce->relay_lock ( void )

=item $mce->relay_unlock ( void )

=back

The C<relay_lock> and C<relay_unlock> methods, added to MCE 1.807, are
aliases for C<relay_recv> and C<relay> respectively. Together, they allow
one to perform an exclusive action prior to actual relaying of data.

Relaying is driven by C<chunk_id> or C<task_wid> when not processing input,
as seen here.

 MCE->new(
    max_workers => 8,
    init_relay => 0,
    user_func => sub {
       MCE->relay_lock;
       MCE->say("wid: ", MCE->task_wid);
       MCE->relay_unlock( sub {
          $_ += 2;
       });
    }
 )->run;

 MCE->say("sum: ", MCE->relay_final);

 __END__

 wid: 1
 wid: 2
 wid: 3
 wid: 4
 wid: 5
 wid: 6
 wid: 7
 wid: 8
 sum: 16

Described above, C<relay> takes a code block and combines C<relay_lock> and
C<relay_unlock> into a single call. To make this more interesting, I define
C<init_relay> to a hash containing two key-value pairs.

 MCE->new(
    max_workers => 8,
    init_relay => { count => 0, total => 0 },
    user_func => sub {
       MCE->relay_lock;
       MCE->say("wid: ", MCE->task_wid);
       MCE->relay_unlock( sub {
          $_->{count} += 1;
          $_->{total} += 2;
       });
    }
 )->run;

 my %results = MCE->relay_final;

 MCE->say("count: ", $results{count});
 MCE->say("total: ", $results{total});

 __END__

 wid: 1
 wid: 2
 wid: 3
 wid: 4
 wid: 5
 wid: 6
 wid: 7
 wid: 8
 count: 8
 total: 16

Below, C<user_func> is taken from the C<cat.pl> MCE example. Incrementing
the count is done only when the C<-n> switch is passed to the script.
Otherwise, output is displaced orderly and not necessary to update the
C<$_> value if exclusive locking is all you need.

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
       ## from the manager process. The statement(s) between relay_lock
       ## and relay_unlock run serially and most important orderly.

       MCE->relay_lock;      # alias for MCE->relay_recv
       print $$chunk_ref;    # ensure $| = 1 in script
       MCE->relay_unlock;    # alias for MCE->relay
    }

    return;
 }

The following is a variant of the fasta-benchmark demonstration shown above.
Here, workers write exclusively and orderly to C<STDOUT>.

 # perl fasta.pl 25000000

 # The Computer Language Benchmarks game
 # https://benchmarksgame-team.pages.debian.net/benchmarksgame/
 #
 # contributed by Barry Walsh
 # port of fasta.rb #6
 #
 # MCE::Flow version by Mario Roy
 # requires MCE 1.807+
 # requires MCE::Shared 1.806+

 use strict;
 use warnings;
 use feature 'say';

 use MCE::Flow;
 use MCE::Shared;

 use constant IM => 139968;
 use constant IA => 3877;
 use constant IC => 29573;

 my $LAST = MCE::Shared->scalar( 42 );

 my $alu =
    'GGCCGGGCGCGGTGGCTCACGCCTGTAATCCCAGCACTTTGG' .
    'GAGGCCGAGGCGGGCGGATCACCTGAGGTCAGGAGTTCGAGA' .
    'CCAGCCTGGCCAACATGGTGAAACCCCGTCTCTACTAAAAAT' .
    'ACAAAAATTAGCCGGGCGTGGTGGCGCGCGCCTGTAATCCCA' .
    'GCTACTCGGGAGGCTGAGGCAGGAGAATCGCTTGAACCCGGG' .
    'AGGCGGAGGTTGCAGTGAGCCGAGATCGCGCCACTGCACTCC' .
    'AGCCTGGGCGACAGAGCGAGACTCCGTCTCAAAAA';

 my $iub = [
    [ 'a', 0.27 ], [ 'c', 0.12 ], [ 'g', 0.12 ],
    [ 't', 0.27 ], [ 'B', 0.02 ], [ 'D', 0.02 ],
    [ 'H', 0.02 ], [ 'K', 0.02 ], [ 'M', 0.02 ],
    [ 'N', 0.02 ], [ 'R', 0.02 ], [ 'S', 0.02 ],
    [ 'V', 0.02 ], [ 'W', 0.02 ], [ 'Y', 0.02 ]
 ];

 my $homosapiens = [
    [ 'a', 0.3029549426680 ],
    [ 'c', 0.1979883004921 ],
    [ 'g', 0.1975473066391 ],
    [ 't', 0.3015094502008 ]
 ];

 sub make_repeat_fasta {
    my ( $src, $n ) = @_;
    my $width = qr/(.{1,60})/;
    my $l     = length $src;
    my $s     = $src x ( ($n / $l) + 1 );
    substr( $s, $n, $l ) = '';

    while ( $s =~ m/$width/g ) { say $1 }
 }

 sub make_random_fasta {
    my ( $table, $n ) = @_;
    my $rand   = undef;
    my $width  = 60;
    my $prob   = 0.0;
    my $output = '';
    my ( $c1, $c2, $last );

    $_->[1] = ( $prob += $_->[1] ) for @$table;

    $c1  = '$rand = ( $last = ( $last * IA + IC ) % IM ) / IM;';
    $c1 .= "\$output .= '$_->[0]', next if $_->[1] > \$rand;\n" for @$table;

    my $seq = MCE::Shared->sequence(
       { chunk_size => 2000, bounds_only => 1 },
       1, $n / $width
    );

    my $code1 = q{
       $| = 1; # Important, must flush output immediately.

       while ( 1 ) {
          # --------------------------------------------
          # Process code orderly between workers.
          # --------------------------------------------

          MCE->relay_lock;

          my ( $begin, $end ) = $seq->next;
          print( $output ), $output = '' if ( length $output );

          MCE->relay_unlock, last if ( !defined $begin );

          my $last = $LAST->get;
          my $temp = $last;

          # Pre-compute $LAST value for the next worker
          for ( 1 .. ( $end - $begin + 1 ) * $width ) {
             $temp = ( $temp * IA + IC ) % IM;
          }

          $LAST->set( $temp );

          MCE->relay_unlock;

          # --------------------------------------------
          # Also run code in parallel.
          # --------------------------------------------

          for ( $begin .. $end ) {
             for ( 1 .. $width ) { !C! }
             $output .= "\n";
          }
       }
    };

    $code1 =~ s/!C!/$c1/g;

    MCE::Flow->init(
       max_workers => 4, ## MCE::Util->get_ncpu || 4,
       init_relay  => 0,
       use_threads => 0,
    );

    MCE::Flow->run( sub { eval $code1 } );
    MCE::Flow->finish;

    $last = $LAST->get;

    $c2  = '$rand = ( $last = ( $last * IA + IC ) % IM ) / IM;';
    $c2 .= "print('$_->[0]'), next if $_->[1] > \$rand;\n" for @$table;

    my $code2 = q{
       if ( $n % $width != 0 ) {
          for ( 1 .. $n % $width ) { !C! }
          print "\n";
       }
    };

    $code2 =~ s/!C!/$c2/g;
    eval $code2;

    $LAST->set( $last );
 }

 my $n = $ARGV[0] || 27;

 say ">ONE Homo sapiens alu";
 make_repeat_fasta( $alu, $n * 2 );

 say ">TWO IUB ambiguity codes";
 make_random_fasta( $iub, $n * 3 );

 say ">THREE Homo sapiens frequency";
 make_random_fasta( $homosapiens, $n * 5 );

=head1 GATHER AND RELAY DEMONSTRATIONS

I received a request from John Martel to process a large flat file and expand
each record to many records based on splitting out items in field 4 delimited
by semicolons. Each row in the output is given a unique ID starting with one
while preserving output order.

=over 3

=item Input File, possibly larger than 500 GiB in size

 foo|field2|field3|item1;item2;item3;item4;itemN|field5|field6|field7
 bar|field2|field3|item1;item2;item3;item4;itemN|field5|field6|field7
 baz|field2|field3|item1;item2;item3;item4;itemN|field5|field6|field7
 ...

=item Output File

 000000000000001|item1|foo|field2|field3|field5|field6|field7
 000000000000002|item2|foo|field2|field3|field5|field6|field7
 000000000000003|item3|foo|field2|field3|field5|field6|field7
 000000000000004|item4|foo|field2|field3|field5|field6|field7
 000000000000005|itemN|foo|field2|field3|field5|field6|field7
 000000000000006|item1|bar|field2|field3|field5|field6|field7
 000000000000007|item2|bar|field2|field3|field5|field6|field7
 000000000000008|item3|bar|field2|field3|field5|field6|field7
 000000000000009|item4|bar|field2|field3|field5|field6|field7
 000000000000010|itemN|bar|field2|field3|field5|field6|field7
 000000000000011|item1|baz|field2|field3|field5|field6|field7
 000000000000012|item2|baz|field2|field3|field5|field6|field7
 000000000000013|item3|baz|field2|field3|field5|field6|field7
 000000000000014|item4|baz|field2|field3|field5|field6|field7
 000000000000015|itemN|baz|field2|field3|field5|field6|field7
 ...

=item Example One

=back

This example configures a custom function for preserving output order.
Unfortunately, the sprintf function alone involves extra CPU time causing
the manager process to fall behind. Thus, workers may idle while waiting
for the manager process to respond to the gather request.

 use strict;
 use warnings;

 use MCE::Loop;

 my $infile  = shift or die "Usage: $0 infile\n";
 my $newfile = 'output.dat';

 open my $fh_out, '>', $newfile or die "open error $newfile: $!\n";

 sub preserve_order {
     my ($fh) = @_;
     my ($order_id, $start_idx, $idx, %tmp) = (1, 1);

     return sub {
         my ($chunk_id, $aref) = @_;
         $tmp{ $chunk_id } = $aref;

         while ( my $aref = delete $tmp{ $order_id } ) {
             foreach my $line ( @{ $aref } ) {
                 $idx = sprintf "%015d", $start_idx++;
                 print $fh $idx, $line;
             }
             $order_id++;
         }
     }
 }

 MCE::Loop->init(
     chunk_size => 'auto', max_workers => 3,
     gather => preserve_order($fh_out)
 );

 mce_loop_f {
     my ($mce, $chunk_ref, $chunk_id) = @_;
     my @buf;

     foreach my $line (@{ $chunk_ref }) {
         $line =~ s/\r//g; chomp $line;

         my ($f1,$f2,$f3,$items,$f5,$f6,$f7) = split /\|/, $line;
         my @items_array = split /;/, $items;

         foreach my $item (@items_array) {
             push @buf, "|$item|$f1|$f2|$f3|$f5|$f6|$f7\n";
         }
     }

     MCE->gather($chunk_id, \@buf);

 } $infile;

 MCE::Loop->finish();
 close $fh_out;

=over 3

=item Example Two

=back

In this example, workers obtain the current ID value and increment/relay for
the next worker, ordered by chunk ID behind the scene. Workers call sprintf
in parallel, allowing the manager process (out_iter_fh) to accommodate up to
32 workers and not fall behind.

Relay accounts for the worker handling the next chunk_id value. Therefore, do
not call relay more than once per chunk. Doing so will cause IPC to stall.

 use strict;
 use warnings;

 use MCE::Loop;
 use MCE::Candy;

 my $infile  = shift or die "Usage: $0 infile\n";
 my $newfile = 'output.dat';

 open my $fh_out, '>', $newfile or die "open error $newfile: $!\n";

 MCE::Loop->init(
     chunk_size => 'auto', max_workers => 8,
     gather => MCE::Candy::out_iter_fh($fh_out),
     init_relay => 1
 );

 mce_loop_f {
     my ($mce, $chunk_ref, $chunk_id) = @_;
     my @lines;

     foreach my $line (@{ $chunk_ref }) {
         $line =~ s/\r//g; chomp $line;

         my ($f1,$f2,$f3,$items,$f5,$f6,$f7) = split /\|/, $line;
         my @items_array = split /;/, $items;

         foreach my $item (@items_array) {
             push @lines, "$item|$f1|$f2|$f3|$f5|$f6|$f7\n";
         }
     }

     my $idx = MCE::relay { $_ += scalar @lines };
     my $buf = '';

     foreach my $line ( @lines ) {
         $buf .= sprintf "%015d|%s", $idx++, $line
     }

     MCE->gather($chunk_id, $buf);

 } $infile;

 MCE::Loop->finish();
 close $fh_out;

=head1 INDEX

L<MCE|MCE>, L<MCE::Core>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

