#!/usr/bin/env perl

use strict;
use warnings;

use Test::More tests => 32;

use MCE::Flow max_workers => 1;
use MCE::Queue;

###############################################################################

##  MCE::Queue supports 3 operating modes (local, manager, worker).
##  This will test MCE::Queue (normal queue) by the MCE worker process.
##
##  *{ 'MCE::Queue::clear'    } = \&MCE::Queue::_mce_w_clear;
##  *{ 'MCE::Queue::enqueue'  } = \&MCE::Queue::_mce_w_enqueue;
##  *{ 'MCE::Queue::dequeue'  } = \&MCE::Queue::_mce_w_dequeue;
##  *{ 'MCE::Queue::insert'   } = \&MCE::Queue::_mce_w_insert;
##  *{ 'MCE::Queue::pending'  } = \&MCE::Queue::_mce_w_pending;
##  *{ 'MCE::Queue::peek'     } = \&MCE::Queue::_mce_w_peek;

my (@a, $q);

sub check_clear {
   my ($description) = @_;
   is( scalar(@a), 0, $description );
}

sub check_enqueue {
   my ($description) = @_;
   is( join('', @a), '1234', $description );
}

sub check_insert {
   my ($description, $expected) = @_;
   is( join('', @a), $expected, $description );
}

sub check_pending {
   my ($description, $pending) = @_;
   is( $pending, 14, $description );
}

sub check {
   my ($description, $expected, $value) = @_;
   is( $value, $expected, $description );
}

###############################################################################

##  FIFO tests

@a = (); $q = MCE::Queue->new( queue => \@a, type => $MCE::Queue::FIFO );

sub check_dequeue_fifo {
   my (@r) = @_;
   is( join('', @r), '123', 'fifo, check dequeue' );
   is( join('', @a),   '4', 'fifo, check array'   );
}

mce_flow sub {
   my ($mce) = @_;

   $q->enqueue('1', '2');
   $q->enqueue('3');
   $q->enqueue('4');

   MCE->do('check_enqueue', 'fifo, check enqueue');

   my @r = $q->dequeue(2);
   push @r, $q->dequeue;

   MCE->do('check_dequeue_fifo', @r);

   $q->clear;

   MCE->do('check_clear', 'fifo, check clear');

   $q->enqueue('a', 'b', 'c', 'd');

   $q->insert(  1, 'e', 'f');
   $q->insert(  3, 'g');
   $q->insert( -2, 'h');
   $q->insert(  7, 'i');
   $q->insert(  9, 'j');
   $q->insert( 20, 'k');
   $q->insert(-10, 'l');
   $q->insert(-12, 'm');
   $q->insert(-20, 'n');

   MCE->do('check_insert',  'fifo, check insert', 'nmalefgbhcidjk');
   MCE->do('check_pending', 'fifo, check pending', $q->pending());

   MCE->do('check', 'fifo, check peek at head     ',   'n', $q->peek(   ));
   MCE->do('check', 'fifo, check peek at index   0',   'n', $q->peek(  0));
   MCE->do('check', 'fifo, check peek at index   2',   'a', $q->peek(  2));
   MCE->do('check', 'fifo, check peek at index  13',   'k', $q->peek( 13));
   MCE->do('check', 'fifo, check peek at index  20', undef, $q->peek( 20));
   MCE->do('check', 'fifo, check peek at index  -2',   'j', $q->peek( -2));
   MCE->do('check', 'fifo, check peek at index -13',   'm', $q->peek(-13));
   MCE->do('check', 'fifo, check peek at index -14',   'n', $q->peek(-14));
   MCE->do('check', 'fifo, check peek at index -15', undef, $q->peek(-15));
   MCE->do('check', 'fifo, check peek at index -20', undef, $q->peek(-20));

   return;
};

MCE::Flow::finish;

###############################################################################

##  LIFO tests

@a = (); $q = MCE::Queue->new( queue => \@a, type => $MCE::Queue::LIFO );

sub check_dequeue_lifo {
   my (@r) = @_;
   is( join('', @r), '432', 'lifo, check dequeue' );
   is( join('', @a),   '1', 'lifo, check array'   );
}

mce_flow sub {
   my ($mce) = @_;

   $q->enqueue('1', '2');
   $q->enqueue('3');
   $q->enqueue('4');

   MCE->do('check_enqueue', 'lifo, check enqueue');

   my @r = $q->dequeue(2);
   push @r, $q->dequeue;

   MCE->do('check_dequeue_lifo', @r);

   $q->clear;

   MCE->do('check_clear', 'lifo, check clear');

   $q->enqueue('a', 'b', 'c', 'd');

   $q->insert(  1, 'e', 'f');
   $q->insert(  3, 'g');
   $q->insert( -2, 'h');
   $q->insert(  7, 'i');
   $q->insert(  9, 'j');
   $q->insert( 20, 'k');
   $q->insert(-10, 'l');
   $q->insert(-12, 'm');
   $q->insert(-20, 'n');

   MCE->do('check_insert',  'lifo, check insert', 'kjaibhcgefldmn');
   MCE->do('check_pending', 'lifo, check pending', $q->pending());

   MCE->do('check', 'lifo, check peek at head     ',   'n', $q->peek(   ));
   MCE->do('check', 'lifo, check peek at index   0',   'n', $q->peek(  0));
   MCE->do('check', 'lifo, check peek at index   2',   'd', $q->peek(  2));
   MCE->do('check', 'lifo, check peek at index  13',   'k', $q->peek( 13));
   MCE->do('check', 'lifo, check peek at index  20', undef, $q->peek( 20));
   MCE->do('check', 'lifo, check peek at index  -2',   'j', $q->peek( -2));
   MCE->do('check', 'lifo, check peek at index -13',   'm', $q->peek(-13));
   MCE->do('check', 'lifo, check peek at index -14',   'n', $q->peek(-14));
   MCE->do('check', 'lifo, check peek at index -15', undef, $q->peek(-15));
   MCE->do('check', 'lifo, check peek at index -20', undef, $q->peek(-20));

   return;
};

MCE::Flow::finish;

