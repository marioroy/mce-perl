###############################################################################
## ----------------------------------------------------------------------------
## Parallel grep model similar to the native grep function.
##
###############################################################################

package MCE::Grep;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized );

our $VERSION = '1.879';

## no critic (BuiltinFunctions::ProhibitStringyEval)
## no critic (Subroutines::ProhibitSubroutinePrototypes)
## no critic (TestingAndDebugging::ProhibitNoStrict)

use Scalar::Util qw( looks_like_number weaken );
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

my ($_MCE, $_def, $_params, $_prev_c, $_tag) = ({}, {}, {}, {}, 'MCE::Grep');

sub import {
   my ($_class, $_pkg) = (shift, caller);

   my $_p = $_def->{$_pkg} = {
      MAX_WORKERS => 'auto',
      CHUNK_SIZE  => 'auto',
   };

   ## Import functions.
   no strict 'refs'; no warnings 'redefine';

   *{ $_pkg.'::mce_grep_f' } = \&run_file;
   *{ $_pkg.'::mce_grep_s' } = \&run_seq;
   *{ $_pkg.'::mce_grep'   } = \&run;

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
## Gather callback for storing by chunk_id => chunk_ref into a hash.
##
###############################################################################

my ($_total_chunks, %_tmp);

sub _gather {

   my ($_chunk_id, $_data_ref) = @_;

   $_tmp{$_chunk_id} = $_data_ref;
   $_total_chunks++;

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Init and finish routines.
##
###############################################################################

sub init (@) {

   shift if (defined $_[0] && $_[0] eq 'MCE::Grep');
   my $_pkg = "$$.$_tid.".caller();

   $_params->{$_pkg} = (ref $_[0] eq 'HASH') ? shift : { @_ };

   _croak("$_tag: (HASH) not allowed as input by this MCE model")
      if ( ref $_params->{$_pkg}{input_data} eq 'HASH' );

   @_ = ();

   return;
}

sub finish (@) {

   shift if (defined $_[0] && $_[0] eq 'MCE::Grep');
   my $_pkg = (defined $_[0]) ? shift : "$$.$_tid.".caller();

   if ( $_pkg eq 'MCE' ) {
      for my $_k ( keys %{ $_MCE } ) { MCE::Grep->finish($_k, 1); }
   }
   elsif ( $_MCE->{$_pkg} && $_MCE->{$_pkg}{_init_pid} eq "$$.$_tid" ) {
      $_MCE->{$_pkg}->shutdown(@_) if $_MCE->{$_pkg}{_spawned};
      $_total_chunks = undef, undef %_tmp;

      delete $_prev_c->{$_pkg};
      delete $_MCE->{$_pkg};
   }

   @_ = ();

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Parallel grep with MCE -- file.
##
###############################################################################

sub run_file (&@) {

   shift if (defined $_[0] && $_[0] eq 'MCE::Grep');

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
## Parallel grep with MCE -- sequence.
##
###############################################################################

sub run_seq (&@) {

   shift if (defined $_[0] && $_[0] eq 'MCE::Grep');

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
## Parallel grep with MCE.
##
###############################################################################

sub run (&@) {

   shift if (defined $_[0] && $_[0] eq 'MCE::Grep');

   my $_code = shift;  $_total_chunks = 0; undef %_tmp;
   my $_pkg  = caller() eq 'MCE::Grep' ? caller(1) : caller();
   my $_pid  = "$$.$_tid.$_pkg";

   my $_input_data; my $_max_workers = $_def->{$_pkg}{MAX_WORKERS};
   my $_r = ref $_[0];

   if (@_ == 1 && $_r =~ /^(?:ARRAY|HASH|SCALAR|CODE|GLOB|FileHandle|IO::)/) {
      _croak("$_tag: (HASH) not allowed as input by this MCE model")
         if $_r eq 'HASH';
      $_input_data = shift;
   }

   if (defined (my $_p = $_params->{$_pid})) {
      $_max_workers = MCE::_parse_max_workers($_p->{max_workers})
         if (exists $_p->{max_workers});

      delete $_p->{sequence}    if (defined $_input_data || scalar @_);
      delete $_p->{user_func}   if (exists $_p->{user_func});
      delete $_p->{user_tasks}  if (exists $_p->{user_tasks});
      delete $_p->{use_slurpio} if (exists $_p->{use_slurpio});
      delete $_p->{bounds_only} if (exists $_p->{bounds_only});
      delete $_p->{gather}      if (exists $_p->{gather});
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
         user_func => sub {

            my ($_mce, $_chunk_ref, $_chunk_id) = @_;
            my $_wantarray = $_mce->{user_args}[0];

            if ($_wantarray) {
               my @_a;

               if (ref $_chunk_ref eq 'SCALAR') {
                  local $/ = $_mce->{RS} if defined $_mce->{RS};
                  open my $_MEM_FH, '<', $_chunk_ref;
                  binmode $_MEM_FH, ':raw';
                  while (<$_MEM_FH>) { push (@_a, $_) if &{ $_code }; }
                  close   $_MEM_FH;
                  weaken  $_MEM_FH;
               }
               else {
                  if (ref $_chunk_ref) {
                     push @_a, grep { &{ $_code } } @{ $_chunk_ref };
                  } else {
                     push @_a, grep { &{ $_code } } $_chunk_ref;
                  }
               }

               MCE->gather($_chunk_id, \@_a);
            }
            else {
               my $_cnt = 0;

               if (ref $_chunk_ref eq 'SCALAR') {
                  local $/ = $_mce->{RS} if defined $_mce->{RS};
                  open my $_MEM_FH, '<', $_chunk_ref;
                  binmode $_MEM_FH, ':raw';
                  while (<$_MEM_FH>) { $_cnt++ if &{ $_code }; }
                  close   $_MEM_FH;
                  weaken  $_MEM_FH;
               }
               else {
                  if (ref $_chunk_ref) {
                     $_cnt += grep { &{ $_code } } @{ $_chunk_ref };
                  } else {
                     $_cnt += grep { &{ $_code } } $_chunk_ref;
                  }
               }

               MCE->gather($_cnt) if defined $_wantarray;
            }
         },
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

   my $_cnt = 0; my $_wantarray = wantarray;

   $_MCE->{$_pid}{use_slurpio} = ($_chunk_size > &MCE::MAX_RECS_SIZE) ? 1 : 0;
   $_MCE->{$_pid}{user_args}   = [ $_wantarray ];

   $_MCE->{$_pid}{gather} = $_wantarray
      ? \&_gather : sub { $_cnt += $_[0]; return; };

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

   if ($_wantarray) {
      return map { @{ $_ } } delete @_tmp{ 1 .. $_total_chunks };
   }
   elsif (defined $_wantarray) {
      return $_cnt;
   }

   return;
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

MCE::Grep - Parallel grep model similar to the native grep function

=head1 VERSION

This document describes MCE::Grep version 1.879

=head1 SYNOPSIS

 ## Exports mce_grep, mce_grep_f, and mce_grep_s
 use MCE::Grep;

 ## Array or array_ref
 my @a = mce_grep { $_ % 5 == 0 } 1..10000;
 my @b = mce_grep { $_ % 5 == 0 } \@list;

 ## Important; pass an array_ref for deeply input data
 my @c = mce_grep { $_->[1] % 2 == 0 } [ [ 0, 1 ], [ 0, 2 ], ... ];
 my @d = mce_grep { $_->[1] % 2 == 0 } \@deeply_list;

 ## File path, glob ref, IO::All::{ File, Pipe, STDIO } obj, or scalar ref
 ## Workers read directly and not involve the manager process
 my @e = mce_grep_f { /pattern/ } "/path/to/file"; # efficient

 ## Involves the manager process, therefore slower
 my @f = mce_grep_f { /pattern/ } $file_handle;
 my @g = mce_grep_f { /pattern/ } $io;
 my @h = mce_grep_f { /pattern/ } \$scalar;

 ## Sequence of numbers (begin, end [, step, format])
 my @i = mce_grep_s { %_ * 3 == 0 } 1, 10000, 5;
 my @j = mce_grep_s { %_ * 3 == 0 } [ 1, 10000, 5 ];

 my @k = mce_grep_s { %_ * 3 == 0 } {
    begin => 1, end => 10000, step => 5, format => undef
 };

=head1 DESCRIPTION

This module provides a parallel grep implementation via Many-Core Engine.
MCE incurs a small overhead due to passing of data. A fast code block will
run faster natively. However, the overhead will likely diminish as the
complexity increases for the code.

 my @m1 =     grep { $_ % 5 == 0 } 1..1000000;          ## 0.065 secs
 my @m2 = mce_grep { $_ % 5 == 0 } 1..1000000;          ## 0.194 secs

Chunking, enabled by default, greatly reduces the overhead behind the scene.
The time for mce_grep below also includes the time for data exchanges between
the manager and worker processes. More parallelization will be seen when the
code incurs additional CPU time.

 my @m1 =     grep { /[2357][1468][9]/ } 1..1000000;    ## 0.353 secs
 my @m2 = mce_grep { /[2357][1468][9]/ } 1..1000000;    ## 0.218 secs

Even faster is mce_grep_s; useful when input data is a range of numbers.
Workers generate sequences mathematically among themselves without any
interaction from the manager process. Two arguments are required for
mce_grep_s (begin, end). Step defaults to 1 if begin is smaller than end,
otherwise -1.

 my @m3 = mce_grep_s { /[2357][1468][9]/ } 1, 1000000;  ## 0.165 secs

Although this document is about MCE::Grep, the L<MCE::Stream> module can write
results immediately without waiting for all chunks to complete. This is made
possible by passing the reference to an array (in this case @m4 and @m5).

 use MCE::Stream default_mode => 'grep';

 my @m4; mce_stream \@m4, sub { /[2357][1468][9]/ }, 1..1000000;

    ## Completed in 0.203 secs. This is amazing considering the
    ## overhead for passing data between the manager and workers.

 my @m5; mce_stream_s \@m5, sub { /[2357][1468][9]/ }, 1, 1000000;

    ## Completed in 0.120 secs. Like with mce_grep_s, specifying a
    ## sequence specification turns out to be faster due to lesser
    ## overhead for the manager process.

A common scenario is grepping for pattern(s) inside a massive log file.
Notice how parallelism increases as complexity increases for the pattern.
Testing was done against a 300 MB file containing 250k lines.

 use MCE::Grep;

 my @m; open my $LOG, "<", "/path/to/log/file" or die "$!\n";

 @m = grep { /pattern/ } <$LOG>;                      ##  0.756 secs
 @m = grep { /foobar|[2357][1468][9]/ } <$LOG>;       ## 24.681 secs

 ## Parallelism with mce_grep. This involves the manager process
 ## due to processing a file handle.

 @m = mce_grep { /pattern/ } <$LOG>;                  ##  0.997 secs
 @m = mce_grep { /foobar|[2357][1468][9]/ } <$LOG>;   ##  7.439 secs

 ## Even faster with mce_grep_f. Workers access the file directly
 ## with zero interaction from the manager process.

 my $LOG = "/path/to/file";
 @m = mce_grep_f { /pattern/ } $LOG;                  ##  0.112 secs
 @m = mce_grep_f { /foobar|[2357][1468][9]/ } $LOG;   ##  6.840 secs

=head1 PARSING HUGE FILES

The MCE::Grep module lacks an optimization for quickly determining if a match
is found from not knowing the pattern inside the code block. Use the following
snippet as a template to achieve better performance. Also, take a look at
examples/egrep.pl, included with the distribution.

 use MCE::Loop;

 MCE::Loop->init(
    max_workers => 8, use_slurpio => 1
 );

 my $pattern  = 'karl';
 my $hugefile = 'very_huge.file';

 my @result = mce_loop_f {
    my ($mce, $slurp_ref, $chunk_id) = @_;

    ## Quickly determine if a match is found.
    ## Process slurped chunk only if true.

    if ($$slurp_ref =~ /$pattern/m) {
       my @matches;

       ## The following is fast on Unix. Performance degrades
       ## drastically on Windows beyond 4 workers.

       open my $MEM_FH, '<', $slurp_ref;
       binmode $MEM_FH, ':raw';
       while (<$MEM_FH>) { push @matches, $_ if (/$pattern/); }
       close   $MEM_FH;

       ## Therefore, use the following construct on Windows.

       while ( $$slurp_ref =~ /([^\n]+\n)/mg ) {
          my $line = $1; # save $1 to not lose the value
          push @matches, $line if ($line =~ /$pattern/);
       }

       ## Gather matched lines.

       MCE->gather(@matches);
    }

 } $hugefile;

 print join('', @result);

=head1 OVERRIDING DEFAULTS

The following list options which may be overridden when loading the module.

 use Sereal qw( encode_sereal decode_sereal );
 use CBOR::XS qw( encode_cbor decode_cbor );
 use JSON::XS qw( encode_json decode_json );

 use MCE::Grep
     max_workers => 4,                # Default 'auto'
     chunk_size => 100,               # Default 'auto'
     tmp_dir => "/path/to/app/tmp",   # $MCE::Signal::tmp_dir
     freeze => \&encode_sereal,       # \&Storable::freeze
     thaw => \&decode_sereal          # \&Storable::thaw
 ;

From MCE 1.8 onwards, Sereal 3.015+ is loaded automatically if available.
Specify C<< Sereal => 0 >> to use Storable instead.

 use MCE::Grep Sereal => 0;

=head1 CUSTOMIZING MCE

=over 3

=item MCE::Grep->init ( options )

=item MCE::Grep::init { options }

=back

The init function accepts a hash of MCE options. The gather option, if
specified, is ignored due to being used internally by the module.

 use MCE::Grep;

 MCE::Grep->init(
    chunk_size => 1, max_workers => 4,

    user_begin => sub {
       print "## ", MCE->wid, " started\n";
    },

    user_end => sub {
       print "## ", MCE->wid, " completed\n";
    }
 );

 my @a = mce_grep { $_ % 5 == 0 } 1..100;

 print "\n", "@a", "\n";

 -- Output

 ## 2 started
 ## 3 started
 ## 1 started
 ## 4 started
 ## 3 completed
 ## 4 completed
 ## 1 completed
 ## 2 completed

 5 10 15 20 25 30 35 40 45 50 55 60 65 70 75 80 85 90 95 100

=head1 API DOCUMENTATION

=over 3

=item MCE::Grep->run ( sub { code }, list )

=item mce_grep { code } list

=back

Input data may be defined using a list or an array reference. Unlike MCE::Loop,
Flow, and Step, specifying a hash reference as input data isn't allowed.

 ## Array or array_ref
 my @a = mce_grep { /[2357]/ } 1..1000;
 my @b = mce_grep { /[2357]/ } \@list;

 ## Important; pass an array_ref for deeply input data
 my @c = mce_grep { $_->[1] =~ /[2357]/ } [ [ 0, 1 ], [ 0, 2 ], ... ];
 my @d = mce_grep { $_->[1] =~ /[2357]/ } \@deeply_list;

 ## Not supported
 my @z = mce_grep { ... } \%hash;

=over 3

=item MCE::Grep->run_file ( sub { code }, file )

=item mce_grep_f { code } file

=back

The fastest of these is the /path/to/file. Workers communicate the next offset
position among themselves with zero interaction by the manager process.

C<IO::All> { File, Pipe, STDIO } is supported since MCE 1.845.

 my @c = mce_grep_f { /pattern/ } "/path/to/file";  # faster
 my @d = mce_grep_f { /pattern/ } $file_handle;
 my @e = mce_grep_f { /pattern/ } $io;              # IO::All
 my @f = mce_grep_f { /pattern/ } \$scalar;

=over 3

=item MCE::Grep->run_seq ( sub { code }, $beg, $end [, $step, $fmt ] )

=item mce_grep_s { code } $beg, $end [, $step, $fmt ]

=back

Sequence may be defined as a list, an array reference, or a hash reference.
The functions require both begin and end values to run. Step and format are
optional. The format is passed to sprintf (% may be omitted below).

 my ($beg, $end, $step, $fmt) = (10, 20, 0.1, "%4.1f");

 my @f = mce_grep_s { /[1234]\.[5678]/ } $beg, $end, $step, $fmt;
 my @g = mce_grep_s { /[1234]\.[5678]/ } [ $beg, $end, $step, $fmt ];

 my @h = mce_grep_s { /[1234]\.[5678]/ } {
    begin => $beg, end => $end,
    step => $step, format => $fmt
 };

=over 3

=item MCE::Grep->run ( sub { code }, iterator )

=item mce_grep { code } iterator

=back

An iterator reference may be specified for input_data. Iterators are described
under section "SYNTAX for INPUT_DATA" at L<MCE::Core>.

 my @a = mce_grep { $_ % 3 == 0 } make_iterator(10, 30, 2);

=head1 MANUAL SHUTDOWN

=over 3

=item MCE::Grep->finish

=item MCE::Grep::finish

=back

Workers remain persistent as much as possible after running. Shutdown occurs
automatically when the script terminates. Call finish when workers are no
longer needed.

 use MCE::Grep;

 MCE::Grep->init(
    chunk_size => 20, max_workers => 'auto'
 );

 my @a = mce_grep { ... } 1..100;

 MCE::Grep->finish;

=head1 INDEX

L<MCE|MCE>, L<MCE::Core>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

