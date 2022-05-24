###############################################################################
## ----------------------------------------------------------------------------
## MCE model for building parallel loops.
##
###############################################################################

package MCE::Loop;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized );

our $VERSION = '1.879';

## no critic (BuiltinFunctions::ProhibitStringyEval)
## no critic (Subroutines::ProhibitSubroutinePrototypes)
## no critic (TestingAndDebugging::ProhibitNoStrict)

use Scalar::Util qw( looks_like_number );
use MCE;

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

my ($_MCE, $_def, $_params, $_prev_c, $_tag) = ({}, {}, {}, {}, 'MCE::Loop');

sub import {
   my ($_class, $_pkg) = (shift, caller);

   my $_p = $_def->{$_pkg} = {
      MAX_WORKERS => 'auto',
      CHUNK_SIZE  => 'auto',
   };

   ## Import functions.
   no strict 'refs'; no warnings 'redefine';

   *{ $_pkg.'::mce_loop_f' } = \&run_file;
   *{ $_pkg.'::mce_loop_s' } = \&run_seq;
   *{ $_pkg.'::mce_loop'   } = \&run;

   ## Process module arguments.
   while ( my $_argument = shift ) {
      my $_arg = lc $_argument;

      $_p->{MAX_WORKERS} = shift, next if ( $_arg eq 'max_workers' );
      $_p->{CHUNK_SIZE}  = shift, next if ( $_arg eq 'chunk_size' );
      $_p->{TMP_DIR}     = shift, next if ( $_arg eq 'tmp_dir' );
      $_p->{FREEZE}      = shift, next if ( $_arg eq 'freeze' );
      $_p->{THAW}        = shift, next if ( $_arg eq 'thaw' );

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
## Init and finish routines.
##
###############################################################################

sub init (@) {

   shift if (defined $_[0] && $_[0] eq 'MCE::Loop');
   my $_pkg = "$$.$_tid.".caller();

   $_params->{$_pkg} = (ref $_[0] eq 'HASH') ? shift : { @_ };

   @_ = ();

   return;
}

sub finish (@) {

   shift if (defined $_[0] && $_[0] eq 'MCE::Loop');
   my $_pkg = (defined $_[0]) ? shift : "$$.$_tid.".caller();

   if ( $_pkg eq 'MCE' ) {
      for my $_k ( keys %{ $_MCE } ) { MCE::Loop->finish($_k, 1); }
   }
   elsif ( $_MCE->{$_pkg} && $_MCE->{$_pkg}{_init_pid} eq "$$.$_tid" ) {
      $_MCE->{$_pkg}->shutdown(@_) if $_MCE->{$_pkg}{_spawned};

      delete $_prev_c->{$_pkg};
      delete $_MCE->{$_pkg};
   }

   @_ = ();

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Parallel loop with MCE -- file.
##
###############################################################################

sub run_file (&@) {

   shift if (defined $_[0] && $_[0] eq 'MCE::Loop');

   my $_code = shift; my $_file = shift;
   my $_pid  = "$$.$_tid.".caller();

   if (defined (my $_p = $_params->{$_pid})) {
      delete $_p->{input_data} if (exists $_p->{input_data});
      delete $_p->{sequence}   if (exists $_p->{sequence});
   }
   else {
      $_params->{$_pid} = {};
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

   @_ = ();

   return run($_code);
}

###############################################################################
## ----------------------------------------------------------------------------
## Parallel loop with MCE -- sequence.
##
###############################################################################

sub run_seq (&@) {

   shift if (defined $_[0] && $_[0] eq 'MCE::Loop');

   my $_code = shift;
   my $_pid  = "$$.$_tid.".caller();

   if (defined (my $_p = $_params->{$_pid})) {
      delete $_p->{input_data} if (exists $_p->{input_data});
      delete $_p->{_file}      if (exists $_p->{_file});
   }
   else {
      $_params->{$_pid} = {};
   }

   my ($_begin, $_end);

   if (ref $_[0] eq 'HASH') {
      $_begin = $_[0]->{begin}; $_end = $_[0]->{end};
      $_params->{$_pid}{sequence} = $_[0];
   }
   elsif (ref $_[0] eq 'ARRAY') {
      $_begin = $_[0]->[0]; $_end = $_[0]->[1];
      $_params->{$_pid}{sequence} = $_[0];
   }
   elsif (ref $_[0] eq '' || ref($_[0]) =~ /^Math::/) {
      $_begin = $_[0]; $_end = $_[1];
      $_params->{$_pid}{sequence} = [ @_ ];
   }
   else {
      _croak("$_tag: (sequence) is not specified or valid");
   }

   _croak("$_tag: (begin) is not specified for sequence")
      unless (defined $_begin);
   _croak("$_tag: (end) is not specified for sequence")
      unless (defined $_end);

   $_params->{$_pid}{sequence_run} = undef;

   @_ = ();

   return run($_code);
}

###############################################################################
## ----------------------------------------------------------------------------
## Parallel loop with MCE.
##
###############################################################################

sub run (&@) {

   shift if (defined $_[0] && $_[0] eq 'MCE::Loop');

   my $_code = shift;
   my $_pkg  = caller() eq 'MCE::Loop' ? caller(1) : caller();
   my $_pid  = "$$.$_tid.$_pkg";

   my $_input_data; my $_max_workers = $_def->{$_pkg}{MAX_WORKERS};
   my $_r = ref $_[0];

   if (@_ == 1 && $_r =~ /^(?:ARRAY|HASH|SCALAR|CODE|GLOB|FileHandle|IO::)/) {
      $_input_data = shift;
   }

   if (defined (my $_p = $_params->{$_pid})) {
      $_max_workers = MCE::_parse_max_workers($_p->{max_workers})
         if (exists $_p->{max_workers});

      delete $_p->{sequence}   if (defined $_input_data || scalar @_);
      delete $_p->{user_func}  if (exists $_p->{user_func});
      delete $_p->{user_tasks} if (exists $_p->{user_tasks});
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

   if (!defined $_prev_c->{$_pid} || $_prev_c->{$_pid} != $_code) {
      $_MCE->{$_pid}->shutdown() if (defined $_MCE->{$_pid});
      $_prev_c->{$_pid} = $_code;

      my %_opts = (
         max_workers => $_max_workers, task_name => $_tag,
         user_func => $_code,
      );

      if (defined (my $_p = $_params->{$_pid})) {
         for my $_k (keys %{ $_p }) {
            next if ($_k eq 'sequence_run');
            next if ($_k eq 'input_data');
            next if ($_k eq 'chunk_size');

            _croak("$_tag: ($_k) is not a valid constructor argument")
               unless (exists $MCE::_valid_fields_new{$_k});

            $_opts{$_k} = $_p->{$_k};
         }
      }

      for my $_k (qw/ tmp_dir freeze thaw /) {
         $_opts{$_k} = $_def->{$_pkg}{uc($_k)}
            if (exists $_def->{$_pkg}{uc($_k)} && !exists $_opts{$_k});
      }

      $_MCE->{$_pid} = MCE->new(pkg => $_pkg, %_opts);
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
   }

   MCE::_restore_state();

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

1;

__END__

###############################################################################
## ----------------------------------------------------------------------------
## Module usage.
##
###############################################################################

=head1 NAME

MCE::Loop - MCE model for building parallel loops

=head1 VERSION

This document describes MCE::Loop version 1.879

=head1 DESCRIPTION

This module provides a parallel loop implementation through Many-Core Engine.
MCE::Loop is not MCE::Map but more along the lines of an easy way to spin up a
MCE instance and have user_func pointing to your code block. If you want
something similar to map, then see L<MCE::Map>.

 ## Construction when chunking is not desired

 use MCE::Loop;

 MCE::Loop->init(
    max_workers => 5, chunk_size => 1
 );

 mce_loop {
    my ($mce, $chunk_ref, $chunk_id) = @_;
    MCE->say("$chunk_id: $_");
 } 40 .. 48;

 -- Output

 3: 42
 1: 40
 2: 41
 4: 43
 5: 44
 6: 45
 7: 46
 8: 47
 9: 48

 ## Construction for 'auto' or greater than 1

 use MCE::Loop;

 MCE::Loop->init(
    max_workers => 5, chunk_size => 'auto'
 );

 mce_loop {
    my ($mce, $chunk_ref, $chunk_id) = @_;
    for (@{ $chunk_ref }) {
       MCE->say("$chunk_id: $_");
    }
 } 40 .. 48;

 -- Output

 1: 40
 2: 42
 1: 41
 4: 46
 2: 43
 5: 48
 3: 44
 4: 47
 3: 45

=head1 SYNOPSIS when CHUNK_SIZE EQUALS 1

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
inside the block. Hence, the block is called once per each item.

 ## Exports mce_loop, mce_loop_f, and mce_loop_s
 use MCE::Loop;

 MCE::Loop->init(
    chunk_size => 1
 );

 ## Array or array_ref
 mce_loop { do_work($_) } 1..10000;
 mce_loop { do_work($_) } \@list;

 ## Important; pass an array_ref for deeply input data
 mce_loop { do_work($_) } [ [ 0, 1 ], [ 0, 2 ], ... ];
 mce_loop { do_work($_) } \@deeply_list;

 ## File path, glob ref, IO::All::{ File, Pipe, STDIO } obj, or scalar ref
 ## Workers read directly and not involve the manager process
 mce_loop_f { chomp; do_work($_) } "/path/to/file"; # efficient

 ## Involves the manager process, therefore slower
 mce_loop_f { chomp; do_work($_) } $file_handle;
 mce_loop_f { chomp; do_work($_) } $io;
 mce_loop_f { chomp; do_work($_) } \$scalar;

 ## Sequence of numbers (begin, end [, step, format])
 mce_loop_s { do_work($_) } 1, 10000, 5;
 mce_loop_s { do_work($_) } [ 1, 10000, 5 ];

 mce_loop_s { do_work($_) } {
    begin => 1, end => 10000, step => 5, format => undef
 };

=head1 SYNOPSIS when CHUNK_SIZE is GREATER THAN 1

Follow this synopsis when chunk_size equals 'auto' or greater than 1.
This means having to loop through the chunk from inside the block.

 use MCE::Loop;

 MCE::Loop->init(           ## Chunk_size defaults to 'auto' when
    chunk_size => 'auto'    ## not specified. Therefore, the init
 );                         ## function may be omitted.

 ## Syntax is shown for mce_loop for demonstration purposes.
 ## Looping inside the block is the same for mce_loop_f and
 ## mce_loop_s.

 ## Array or array_ref
 mce_loop { do_work($_) for (@{ $_ }) } 1..10000;
 mce_loop { do_work($_) for (@{ $_ }) } \@list;

 ## Important; pass an array_ref for deeply input data
 mce_loop { do_work($_) for (@{ $_ }) } [ [ 0, 1 ], [ 0, 2 ], ... ];
 mce_loop { do_work($_) for (@{ $_ }) } \@deeply_list;

 ## Resembles code using the core MCE API
 mce_loop {
    my ($mce, $chunk_ref, $chunk_id) = @_;

    for (@{ $chunk_ref }) {
       do_work($_);
    }

 } 1..10000;

Chunking reduces the number of IPC calls behind the scene. Think in terms of
chunks whenever processing a large amount of data. For relatively small data,
choosing 1 for chunk_size is fine.

=head1 OVERRIDING DEFAULTS

The following list options which may be overridden when loading the module.

 use Sereal qw( encode_sereal decode_sereal );
 use CBOR::XS qw( encode_cbor decode_cbor );
 use JSON::XS qw( encode_json decode_json );

 use MCE::Loop
     max_workers => 4,                # Default 'auto'
     chunk_size => 100,               # Default 'auto'
     tmp_dir => "/path/to/app/tmp",   # $MCE::Signal::tmp_dir
     freeze => \&encode_sereal,       # \&Storable::freeze
     thaw => \&decode_sereal          # \&Storable::thaw
 ;

From MCE 1.8 onwards, Sereal 3.015+ is loaded automatically if available.
Specify C<< Sereal => 0 >> to use Storable instead.

 use MCE::Loop Sereal => 0;

=head1 CUSTOMIZING MCE

=over 3

=item MCE::Loop->init ( options )

=item MCE::Loop::init { options }

=back

The init function accepts a hash of MCE options.

 use MCE::Loop;

 MCE::Loop->init(
    chunk_size => 1, max_workers => 4,

    user_begin => sub {
       print "## ", MCE->wid, " started\n";
    },

    user_end => sub {
       print "## ", MCE->wid, " completed\n";
    }
 );

 my %a = mce_loop { MCE->gather($_, $_ * $_) } 1..100;

 print "\n", "@a{1..100}", "\n";

 -- Output

 ## 3 started
 ## 1 started
 ## 2 started
 ## 4 started
 ## 1 completed
 ## 2 completed
 ## 3 completed
 ## 4 completed

 1 4 9 16 25 36 49 64 81 100 121 144 169 196 225 256 289 324 361
 400 441 484 529 576 625 676 729 784 841 900 961 1024 1089 1156
 1225 1296 1369 1444 1521 1600 1681 1764 1849 1936 2025 2116 2209
 2304 2401 2500 2601 2704 2809 2916 3025 3136 3249 3364 3481 3600
 3721 3844 3969 4096 4225 4356 4489 4624 4761 4900 5041 5184 5329
 5476 5625 5776 5929 6084 6241 6400 6561 6724 6889 7056 7225 7396
 7569 7744 7921 8100 8281 8464 8649 8836 9025 9216 9409 9604 9801
 10000

=head1 API DOCUMENTATION

The following assumes chunk_size equals 1 in order to demonstrate all the
possibilities for providing input data.

=over 3

=item MCE::Loop->run ( sub { code }, list )

=item mce_loop { code } list

=back

Input data may be defined using a list, an array ref, or a hash ref.

 # $_ contains the item when chunk_size => 1

 mce_loop { do_work($_) } 1..1000;
 mce_loop { do_work($_) } \@list;

 # Important; pass an array_ref for deeply input data

 mce_loop { do_work($_) } [ [ 0, 1 ], [ 0, 2 ], ... ];
 mce_loop { do_work($_) } \@deeply_list;

 # Chunking; any chunk_size => 1 or greater

 my %res = mce_loop {
    my ($mce, $chunk_ref, $chunk_id) = @_;
    my %ret;
    for my $item (@{ $chunk_ref }) {
       $ret{$item} = $item * 2;
    }
    MCE->gather(%ret);
 }
 \@list;

 # Input hash; current API available since 1.828

 my %res = mce_loop {
    my ($mce, $chunk_ref, $chunk_id) = @_;
    my %ret;
    for my $key (keys %{ $chunk_ref }) {
       $ret{$key} = $chunk_ref->{$key} * 2;
    }
    MCE->gather(%ret);
 }
 \%hash;

=over 3

=item MCE::Loop->run_file ( sub { code }, file )

=item mce_loop_f { code } file

=back

The fastest of these is the /path/to/file. Workers communicate the next offset
position among themselves with zero interaction by the manager process.

C<IO::All> { File, Pipe, STDIO } is supported since MCE 1.845.

 # $_ contains the line when chunk_size => 1

 mce_loop_f { $_ } "/path/to/file";  # faster
 mce_loop_f { $_ } $file_handle;
 mce_loop_f { $_ } $io;              # IO::All
 mce_loop_f { $_ } \$scalar;

 # chunking, any chunk_size => 1 or greater

 my %res = mce_loop_f {
    my ($mce, $chunk_ref, $chunk_id) = @_;
    my $buf = '';
    for my $line (@{ $chunk_ref }) {
       $buf .= $line;
    }
    MCE->gather($chunk_id, $buf);
 }
 "/path/to/file";

=over 3

=item MCE::Loop->run_seq ( sub { code }, $beg, $end [, $step, $fmt ] )

=item mce_loop_s { code } $beg, $end [, $step, $fmt ]

=back

Sequence may be defined as a list, an array reference, or a hash reference.
The functions require both begin and end values to run. Step and format are
optional. The format is passed to sprintf (% may be omitted below).

 my ($beg, $end, $step, $fmt) = (10, 20, 0.1, "%4.1f");

 # $_ contains the sequence number when chunk_size => 1

 mce_loop_s { $_ } $beg, $end, $step, $fmt;
 mce_loop_s { $_ } [ $beg, $end, $step, $fmt ];

 mce_loop_s { $_ } {
    begin => $beg, end => $end,
    step => $step, format => $fmt
 };

 # chunking, any chunk_size => 1 or greater

 my %res = mce_loop_s {
    my ($mce, $chunk_ref, $chunk_id) = @_;
    my $buf = '';
    for my $seq (@{ $chunk_ref }) {
       $buf .= "$seq\n";
    }
    MCE->gather($chunk_id, $buf);
 }
 [ $beg, $end ];

The sequence engine can compute 'begin' and 'end' items only, for the chunk,
and not the items in between (hence boundaries only). This option applies
to sequence only and has no effect when chunk_size equals 1.

The time to run is 0.006s below. This becomes 0.827s without the bounds_only
option due to computing all items in between, thus creating a very large
array. Basically, specify bounds_only => 1 when boundaries is all you need
for looping inside the block; e.g. Monte Carlo simulations.

Time was measured using 1 worker to emphasize the difference.

 use MCE::Loop;

 MCE::Loop->init(
    max_workers => 1, chunk_size => 1_250_000,
    bounds_only => 1
 );

 # Typically, the input scalar $_ contains the sequence number
 # when chunk_size => 1, unless the bounds_only option is set
 # which is the case here. Thus, $_ points to $chunk_ref.

 mce_loop_s {
    my ($mce, $chunk_ref, $chunk_id) = @_;

    # $chunk_ref contains 2 items, not 1_250_000
    # my ( $begin, $end ) = ( $_->[0], $_->[1] );

    my $begin = $chunk_ref->[0];
    my $end   = $chunk_ref->[1];

    # for my $seq ( $begin .. $end ) {
    #    ...
    # }

    MCE->printf("%7d .. %8d\n", $begin, $end);
 }
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

=item MCE::Loop->run ( sub { code }, iterator )

=item mce_loop { code } iterator

=back

An iterator reference may be specified for input_data. Iterators are described
under section "SYNTAX for INPUT_DATA" at L<MCE::Core>.

 mce_loop { $_ } make_iterator(10, 30, 2);

=head1 GATHERING DATA

Unlike MCE::Map where gather and output order are done for you automatically,
the gather method is used to have results sent back to the manager process.

 use MCE::Loop chunk_size => 1;

 ## Output order is not guaranteed.
 my @a1 = mce_loop { MCE->gather($_ * 2) } 1..100;
 print "@a1\n\n";

 ## Outputs to a hash instead (key, value).
 my %h1 = mce_loop { MCE->gather($_, $_ * 2) } 1..100;
 print "@h1{1..100}\n\n";

 ## This does the same thing due to chunk_id starting at one.
 my %h2 = mce_loop { MCE->gather(MCE->chunk_id, $_ * 2) } 1..100;
 print "@h2{1..100}\n\n";

The gather method may be called multiple times within the block unlike return
which would leave the block. Therefore, think of gather as yielding results
immediately to the manager process without actually leaving the block.

 use MCE::Loop chunk_size => 1, max_workers => 3;

 my @hosts = qw(
    hosta hostb hostc hostd hoste
 );

 my %h3 = mce_loop {
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

 } @hosts;

 foreach my $host (@hosts) {
    print $h3{"$host.out"}, "\n";
    print $h3{"$host.err"}, "\n" if (exists $h3{"$host.err"});
    print "Exit status: ", $h3{"$host.sta"}, "\n\n";
 }

 -- Output

 Worker 2: Hello from hosta
 Exit status: 0

 Worker 1: Hello from hostb
 Exit status: 0

 Worker 3: Hello from hostc
 Error from hostc
 Exit status: 1

 Worker 2: Hello from hostd
 Exit status: 0

 Worker 1: Hello from hoste
 Exit status: 0

The following uses an anonymous array containing 3 elements when gathering
data. Serialization is automatic behind the scene.

 my %h3 = mce_loop {
    ...

    MCE->gather($host, [$output, $error, $status]);

 } @hosts;

 foreach my $host (@hosts) {
    print $h3{$host}->[0], "\n";
    print $h3{$host}->[1], "\n" if (defined $h3{$host}->[1]);
    print "Exit status: ", $h3{$host}->[2], "\n\n";
 }

Although MCE::Map comes to mind, one may want additional control when
gathering data such as retaining output order.

 use MCE::Loop;

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

 my @m2;

 MCE::Loop->init(
    chunk_size => 'auto', max_workers => 'auto',
    gather => preserve_order(\@m2)
 );

 mce_loop {
    my @a; my ($mce, $chunk_ref, $chunk_id) = @_;

    ## Compute the entire chunk data at once.
    push @a, map { $_ * 2 } @{ $chunk_ref };

    ## Afterwards, invoke the gather feature, which
    ## will direct the data to the callback function.
    MCE->gather(MCE->chunk_id, @a);

 } 1..100000;

 MCE::Loop->finish;

 print scalar @m2, "\n";

All 6 models support 'auto' for chunk_size unlike the Core API. Think of the
models as the basis for providing JIT for MCE. They create the instance, tune
max_workers, and tune chunk_size automatically regardless of the hardware.

The following does the same thing using the Core API.

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

 my @m2;

 $mce->process({ gather => preserve_order(\@m2) }, [1..100000]);
 $mce->shutdown;

 print scalar @m2, "\n";

=head1 MANUAL SHUTDOWN

=over 3

=item MCE::Loop->finish

=item MCE::Loop::finish

=back

Workers remain persistent as much as possible after running. Shutdown occurs
automatically when the script terminates. Call finish when workers are no
longer needed.

 use MCE::Loop;

 MCE::Loop->init(
    chunk_size => 20, max_workers => 'auto'
 );

 mce_loop { ... } 1..100;

 MCE::Loop->finish;

=head1 INDEX

L<MCE|MCE>, L<MCE::Core>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

