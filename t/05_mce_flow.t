#!/usr/bin/env perl

use strict;
use warnings;

use Test::More tests => 4;

use MCE::Flow;
use MCE::Queue;

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

##  sub-tasks

my $q = MCE::Queue->new;

sub task_a {

   my @ans; my ($mce, $chunk_ref, $chunk_id) = @_;
   push @ans, map { $_ * 2 } @{ $chunk_ref };

   $q->enqueue( [ \@ans, $chunk_id ] );   # forward to task_b
}

sub task_b {

   while (defined (my $next_ref = $q->dequeue)) {
      my @ans; my ($chunk_ref, $chunk_id) = @{ $next_ref };
      push @ans, map { $_ * 3 } @{ $chunk_ref };

      MCE->gather(\@ans, $chunk_id);      # send to output_iterator
   }
}

##  Reminder; MCE::Flow processes sub-tasks from left-to-right

my $answers = '6 12 18 24 30 36 42 48 54';
my @a;

MCE::Flow::init {
   max_workers => [  2  ,  2  ],   # run with 2 workers for both sub-tasks
   task_name   => [ 'a' , 'b' ],

   task_end => sub {
      my ($mce, $task_id, $task_name) = @_;

      if ($task_name eq 'a') {
         $q->enqueue((undef) x 2);
      }
   }
};

mce_flow { gather => output_iterator(\@a) }, \&task_a, \&task_b, ( 1..9 );
is( join(' ', @a), $answers, 'check results for array' );

mce_flow_f { gather => output_iterator(\@a) }, \&task_a, \&task_b, $in_file;
is( join(' ', @a), $answers, 'check results for path' );

mce_flow_f { gather => output_iterator(\@a) }, \&task_a, \&task_b, $fh_data;
is( join(' ', @a), $answers, 'check results for glob' );

mce_flow_s { gather => output_iterator(\@a) }, \&task_a, \&task_b, 1, 9, 1;
is( join(' ', @a), $answers, 'check results for sequence' );

MCE::Flow::finish;

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
