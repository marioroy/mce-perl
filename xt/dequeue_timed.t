#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

BEGIN {
   use_ok 'MCE';
   use_ok 'MCE::Flow';
   use_ok 'MCE::Queue';
}

my @a = ();
my $q = MCE::Queue->new( queue => \@a );

sub check_enqueue {
   my ($description) = @_;
   is( join('', @a), '12345', $description );
}

sub check_dequeue_nb {
   my ($description, $value) = @_;
   is( $value, '12345', $description );
   is( join('', @a), '', 'queue emptied' );
}

sub check_dequeue_timed {
   my ($description, $success) = @_;
   is( $success, 1, $description );
}

## Manager tests

{
   $q->enqueue('12345');
   check_enqueue('manager: check enqueue');
   check_dequeue_nb('manager: check dequeue_nb', $q->dequeue_timed);

   my $start = MCE::Util::_time();
   my $ret = $q->dequeue_timed(2.0); # no timed support for the manager process
   my $success = (!$ret && MCE::Util::_time() - $start < 1.0) ? 1 : 0;
   check_dequeue_timed('manager: check dequeue_timed', $success);
}

## Worker tests

MCE::Flow->init( max_workers => 1 );

mce_flow sub {
   my ($mce) = @_;

   $q->enqueue('12345');
   MCE->do('check_enqueue', 'worker: check enqueue');
   MCE->do('check_dequeue_nb', 'worker: check dequeue_nb', $q->dequeue_timed);

   my $start = MCE::Util::_time();
   my $ret = $q->dequeue_timed(2.0);
   my $success = (!$ret && MCE::Util::_time() - $start > 1.0) ? 1 : 0;
   MCE->do('check_dequeue_timed', 'worker: check dequeue_timed', $success);

   return;
};

MCE::Flow->finish;

## Parallel demo

my $s = MCE::Util::_time();
my @r;

MCE->new(
   user_tasks => [{
      # consumers
      max_workers => 8,
      chunk_size  => 1,
      sequence    => [ 1, 40 ],
      gather      => \@r,
      user_func   => sub {
         # each worker calls dequeue_timed approximately 5 times
         if (defined(my $ret = $q->dequeue_timed(1.0))) {
            MCE->printf("$ret: time %0.3f, pid $$\n", MCE::Util::_time());
            MCE->gather($ret);
         }
      }
   },{
      # provider
      max_workers => 1,
      user_func   => sub {
         $q->enqueue($_) for 'a'..'d';
         sleep 1;
         $q->enqueue('e');
         sleep 1;
         $q->enqueue('f');
         sleep 1;
         $q->enqueue('g');
      }
   }]
)->run;

my $duration = MCE::Util::_time() - $s;
printf "%0.3f seconds\n", $duration;

my $success = (abs(5.0 - $duration) < 2.0) ? 1 : 0;
is( $success, 1, 'parallel demo duration' );
is( scalar(@r), 7, 'gathered size' );
is( join('', sort @r), 'abcdefg', 'gathered data' );

done_testing;

