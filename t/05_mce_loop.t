#!/usr/bin/env perl

use strict;
use warnings;

use Test::More tests => 4;

use MCE::Loop;

##  preparation

my $in_file = MCE->tmp_dir . '/input.txt';
my $fh_data = \*DATA;

open my $fh, '>', $in_file;
binmode $fh;
print {$fh} "1\n2\n3\n4\n5\n6\n7\n8\n9\n";
close $fh;

##  output iterator to ensure output order

sub output_iterator {

   my ($gather_ref) = @_;
   my %tmp; my $order_id = 1;

   @{ $gather_ref } = ();     ## reset array

   return sub {
      my ($data_ref, $chunk_id) = @_;
      $tmp{ $chunk_id } = $data_ref;

      while (1) {
         last unless exists $tmp{$order_id};
         push @{ $gather_ref }, @{ $tmp{$order_id} };
         delete $tmp{$order_id++};
      }

      return;
   };
}

##  sub-task

sub _task {

   my @ans; my ($mce, $chunk_ref, $chunk_id) = @_;
   push @ans, map { $_ * 2 * 3 } @{ $chunk_ref };

   MCE->gather(\@ans, $chunk_id);   # send to output_iterator
}

my $answers = '6 12 18 24 30 36 42 48 54';
my @a;

MCE::Loop::init {
   max_workers => 2, gather => output_iterator(\@a)
};

##  mce_loop can take a code block, e.g: mce_loop { code } ( 1..9 )
##  below, workers will persist between runs

mce_loop \&_task, ( 1..9 );
is( join(' ', @a), $answers, 'check results for array' );
   
mce_loop_f \&_task, $in_file;
is( join(' ', @a), $answers, 'check results for path' );

mce_loop_f \&_task, $fh_data;
is( join(' ', @a), $answers, 'check results for glob' );

mce_loop_s \&_task, 1, 9, 1;
is( join(' ', @a), $answers, 'check results for sequence' );

MCE::Loop::finish;

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
