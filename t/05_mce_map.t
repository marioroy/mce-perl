#!/usr/bin/env perl

use strict;
use warnings;

use Test::More tests => 4;

use MCE::Map;

##  preparation

my $in_file = MCE->tmp_dir . '/input.txt';
my $fh_data = \*DATA;

open my $fh, '>', $in_file;
binmode $fh;
print {$fh} "1\n2\n3\n4\n5\n6\n7\n8\n9\n";
close $fh;

my $answers = '6 12 18 24 30 36 42 48 54';
my @a;

MCE::Map::init {
   max_workers => 2
};

sub _task { chomp; $_ * 2 * 3 }

##  mce_map can take a code block, e.g: mce_map { code } ( 1..9 )
##  below, workers will persist between runs

@a = mce_map \&_task, ( 1..9 );
is( join(' ', @a), $answers, 'block_ref: check results for array' );

@a = mce_map_f \&_task, $in_file;
is( join(' ', @a), $answers, 'block_ref: check results for path' );

@a = mce_map_f \&_task, $fh_data;
is( join(' ', @a), $answers, 'block_ref: check results for glob' );

@a = mce_map_s \&_task, 1, 9, 1;
is( join(' ', @a), $answers, 'block_ref: check results for sequence' );

MCE::Map::finish;

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
