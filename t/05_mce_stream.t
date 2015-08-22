#!/usr/bin/env perl

use strict;
use warnings;

use Test::More tests => 9;

use MCE::Stream;

##  preparation

my $in_file = MCE->tmp_dir . '/input.txt';
my $fh_data = \*DATA;
my $fh_pos  = tell $fh_data;

open my $fh, '>', $in_file;
binmode $fh;
print {$fh} "1\n2\n3\n4\n5\n6\n7\n8\n9\n";
close $fh;

##  reminder ; MCE::Stream processes sub-tasks from right-to-left

my $answers = '6 12 18 24 30 36 42 48 54';
my $ans_mix = '18 36 54';
my @a;

MCE::Stream::init {
   max_workers => [  2  ,  2  ],   # run with 2 workers for both sub-tasks
   task_name   => [ 'b' , 'a' ]
};

sub _task_a { chomp; $_ * 2 }
sub _task_b { $_ * 3 }

##  @a = mce_stream ...       # @a is populated after running
                              # not recommended for big input data

@a = mce_stream \&_task_b, \&_task_a, ( 1..9 );
is( join(' ', @a), $answers, 'array: check results for array' );

@a = mce_stream_f \&_task_b, \&_task_a, $in_file;
is( join(' ', @a), $answers, 'array: check results for path' );

@a = mce_stream_f \&_task_b, \&_task_a, $fh_data;
is( join(' ', @a), $answers, 'array: check results for glob' );

@a = mce_stream_s \&_task_b, \&_task_a, 1, 9, 1;
is( join(' ', @a), $answers, 'array: check results for sequence' );

seek($fh_data, $fh_pos, 0);

##  mce_stream \@a, ...       # @a is populated while running
                              # faster and consumes less memory

mce_stream \@a, \&_task_b, \&_task_a, ( 1..9 );
is( join(' ', @a), $answers, 'array_ref: check results for array' );

mce_stream_f \@a, \&_task_b, \&_task_a, $in_file;
is( join(' ', @a), $answers, 'array_ref: check results for path' );

mce_stream_f \@a, \&_task_b, \&_task_a, $fh_data;
is( join(' ', @a), $answers, 'array_ref: check results for glob' );

mce_stream_s \@a, \&_task_b, \&_task_a, 1, 9, 1;
is( join(' ', @a), $answers, 'array_ref: check results for sequence' );

MCE::Stream::finish;

@a = mce_stream
   { mode => 'map',  code => sub { $_ * 2 * 3 } },
   { mode => 'grep', code => sub { $_ % 3 == 0 } },
( 1..9 );

is( join(' ', @a), $ans_mix, 'array: check results for mix_mode' );

MCE::Stream::finish;

##  cleanup

unlink $in_file;

__DATA__
1
2
3
4
5
6
7
8
9
