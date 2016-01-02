#!/usr/bin/env perl

use strict;
use warnings;

use Test::More tests => 32;
use MCE::Flow max_workers => 1;
use MCE::Shared;
use MCE::Shared::Queue;

###############################################################################

## Queues must be shared first before anything else or it will not work.
## The reason is for the socket handles to be in place before starting the
## server. Sharing a hash or array will cause the server to start.

my $q1 = MCE::Shared->queue( type => $MCE::Shared::Queue::FIFO );
my $q2 = MCE::Shared->queue( type => $MCE::Shared::Queue::LIFO );
my $q;

## One must explicitly start the server for queues. Not necessary otherwise.

MCE::Shared->start();

###############################################################################

sub check_clear {
   my ($description) = @_;
   is( scalar(@{ $q->_get_aref() }), 0, $description );
}

sub check_enqueue {
   my ($description) = @_;
   is( join('', @{ $q->_get_aref() }), '1234', $description );
}

sub check_insert {
   my ($description, $expected) = @_;
   is( join('', @{ $q->_get_aref() }), $expected, $description );
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

$q = $q1;

sub check_dequeue_fifo {
   my (@r) = @_;
   is( join('', @r), '123', 'fifo, check dequeue' );
   is( join('', @{ $q->_get_aref() }), '4', 'fifo, check array' );
}

mce_flow sub {
   my ($mce) = @_;
   my $w; # effect is waiting for the check (MCE->do) to complete

   $q->enqueue('1', '2');
   $q->enqueue('3');
   $q->enqueue('4');

   $w = MCE->do('check_enqueue', 'fifo, check enqueue');

   my @r = $q->dequeue(2);
   push @r, $q->dequeue;

   $w = MCE->do('check_dequeue_fifo', @r);

   $q->clear;

   $w = MCE->do('check_clear', 'fifo, check clear');

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

   $w = MCE->do('check_insert',  'fifo, check insert', 'nmalefgbhcidjk');
   $w = MCE->do('check_pending', 'fifo, check pending', $q->pending());

   $w = MCE->do('check', 'fifo, check peek at head     ',   'n', $q->peek(   ));
   $w = MCE->do('check', 'fifo, check peek at index   0',   'n', $q->peek(  0));
   $w = MCE->do('check', 'fifo, check peek at index   2',   'a', $q->peek(  2));
   $w = MCE->do('check', 'fifo, check peek at index  13',   'k', $q->peek( 13));
   $w = MCE->do('check', 'fifo, check peek at index  20', undef, $q->peek( 20));
   $w = MCE->do('check', 'fifo, check peek at index  -2',   'j', $q->peek( -2));
   $w = MCE->do('check', 'fifo, check peek at index -13',   'm', $q->peek(-13));
   $w = MCE->do('check', 'fifo, check peek at index -14',   'n', $q->peek(-14));
   $w = MCE->do('check', 'fifo, check peek at index -15', undef, $q->peek(-15));
   $w = MCE->do('check', 'fifo, check peek at index -20', undef, $q->peek(-20));

   return;
};

MCE::Flow::finish;

###############################################################################

##  LIFO tests

$q = $q2;

sub check_dequeue_lifo {
   my (@r) = @_;
   is( join('', @r), '432', 'lifo, check dequeue' );
   is( join('', @{ $q->_get_aref() }), '1', 'lifo, check array' );
}

mce_flow sub {
   my ($mce) = @_;
   my $w; # effect is waiting for the check (MCE->do) to complete

   $q->enqueue('1', '2');
   $q->enqueue('3');
   $q->enqueue('4');

   $w = MCE->do('check_enqueue', 'lifo, check enqueue');

   my @r = $q->dequeue(2);
   push @r, $q->dequeue;

   $w = MCE->do('check_dequeue_lifo', @r);

   $q->clear;

   $w = MCE->do('check_clear', 'lifo, check clear');

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

   $w = MCE->do('check_insert',  'lifo, check insert', 'kjaibhcgefldmn');
   $w = MCE->do('check_pending', 'lifo, check pending', $q->pending());

   $w = MCE->do('check', 'lifo, check peek at head     ',   'n', $q->peek(   ));
   $w = MCE->do('check', 'lifo, check peek at index   0',   'n', $q->peek(  0));
   $w = MCE->do('check', 'lifo, check peek at index   2',   'd', $q->peek(  2));
   $w = MCE->do('check', 'lifo, check peek at index  13',   'k', $q->peek( 13));
   $w = MCE->do('check', 'lifo, check peek at index  20', undef, $q->peek( 20));
   $w = MCE->do('check', 'lifo, check peek at index  -2',   'j', $q->peek( -2));
   $w = MCE->do('check', 'lifo, check peek at index -13',   'm', $q->peek(-13));
   $w = MCE->do('check', 'lifo, check peek at index -14',   'n', $q->peek(-14));
   $w = MCE->do('check', 'lifo, check peek at index -15', undef, $q->peek(-15));
   $w = MCE->do('check', 'lifo, check peek at index -20', undef, $q->peek(-20));

   return;
};

MCE::Flow::finish;

