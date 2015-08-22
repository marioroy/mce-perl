#!/usr/bin/env perl

use strict;
use warnings;

use Test::More tests => 40;

use MCE::Flow max_workers => 1;
use MCE::Queue;

###############################################################################

##  MCE::Queue supports 3 operating modes (local, manager, worker).
##  This will test MCE::Queue (priority queue) by the MCE worker process.
##
##  *{ 'MCE::Queue::clear'    } = \&MCE::Queue::_mce_w_clear;
##  *{ 'MCE::Queue::enqueuep' } = \&MCE::Queue::_mce_w_enqueuep;
##  *{ 'MCE::Queue::dequeue'  } = \&MCE::Queue::_mce_w_dequeue;
##  *{ 'MCE::Queue::pending'  } = \&MCE::Queue::_mce_w_pending;
##  *{ 'MCE::Queue::insertp'  } = \&MCE::Queue::_mce_w_insertp;
##  *{ 'MCE::Queue::peekp'    } = \&MCE::Queue::_mce_w_peekp;
##  *{ 'MCE::Queue::peekh'    } = \&MCE::Queue::_mce_w_peekh;
##  *{ 'MCE::Queue::heap'     } = \&MCE::Queue::_mce_w_heap;

my ($q);

sub check_clear {
   my ($description) = @_;
   is( $q->_get_aref(5), undef, $description );
}

sub check_enqueuep {
   my ($description) = @_;
   is( join('', @{ $q->_get_aref(5) }), '1234', $description );
}

sub check_insertp {
   my ($description, $expected) = @_;
   is( join('', @{ $q->_get_aref(5) }), $expected, $description );
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

$q = MCE::Queue->new( type => $MCE::Queue::FIFO );

sub check_dequeue_fifo {
   my (@r) = @_;
   is( join('', @r), '123', 'fifo, check dequeue' );
   is( join('', @{ $q->_get_aref(5) }), '4', 'fifo, check array' );
}

mce_flow sub {
   my ($mce) = @_;

   $q->enqueuep(5, '1', '2');
   $q->enqueuep(5, '3');
   $q->enqueuep(5, '4');

   MCE->do('check_enqueuep', 'fifo, check enqueuep');

   my @r = $q->dequeue(2);
   push @r, $q->dequeue;

   MCE->do('check_dequeue_fifo', @r);

   $q->clear;

   MCE->do('check_clear', 'fifo, check clear');

   $q->enqueuep(5, 'a', 'b', 'c', 'd');

   $q->insertp(5,   1, 'e', 'f');
   $q->insertp(5,   3, 'g');
   $q->insertp(5,  -2, 'h');
   $q->insertp(5,   7, 'i');
   $q->insertp(5,   9, 'j');
   $q->insertp(5,  20, 'k');
   $q->insertp(5, -10, 'l');
   $q->insertp(5, -12, 'm');
   $q->insertp(5, -20, 'n');

   MCE->do('check_insertp', 'fifo, check insertp', 'nmalefgbhcidjk');
   MCE->do('check_pending', 'fifo, check pending', $q->pending());

   MCE->do('check', 'fifo, check peekp at head     ',   'n', $q->peekp(5     ));
   MCE->do('check', 'fifo, check peekp at index   0',   'n', $q->peekp(5,   0));
   MCE->do('check', 'fifo, check peekp at index   2',   'a', $q->peekp(5,   2));
   MCE->do('check', 'fifo, check peekp at index  13',   'k', $q->peekp(5,  13));
   MCE->do('check', 'fifo, check peekp at index  20', undef, $q->peekp(5,  20));
   MCE->do('check', 'fifo, check peekp at index  -2',   'j', $q->peekp(5,  -2));
   MCE->do('check', 'fifo, check peekp at index -13',   'm', $q->peekp(5, -13));
   MCE->do('check', 'fifo, check peekp at index -14',   'n', $q->peekp(5, -14));
   MCE->do('check', 'fifo, check peekp at index -15', undef, $q->peekp(5, -15));
   MCE->do('check', 'fifo, check peekp at index -20', undef, $q->peekp(5, -20));

   return;
};

MCE::Flow::finish;

###############################################################################

##  LIFO tests

$q = MCE::Queue->new( type => $MCE::Queue::LIFO );

sub check_dequeue_lifo {
   my (@r) = @_;
   is( join('', @r), '432', 'lifo, check dequeue' );
   is( join('', @{ $q->_get_aref(5) }), '1', 'lifo, check array' );
}

mce_flow sub {
   my ($mce) = @_;

   $q->enqueuep(5, '1', '2');
   $q->enqueuep(5, '3');
   $q->enqueuep(5, '4');

   MCE->do('check_enqueuep', 'lifo, check enqueuep');

   my @r = $q->dequeue(2);
   push @r, $q->dequeue;

   MCE->do('check_dequeue_lifo', @r);

   $q->clear;

   MCE->do('check_clear', 'lifo, check clear');

   $q->enqueuep(5, 'a', 'b', 'c', 'd');

   $q->insertp(5,   1, 'e', 'f');
   $q->insertp(5,   3, 'g');
   $q->insertp(5,  -2, 'h');
   $q->insertp(5,   7, 'i');
   $q->insertp(5,   9, 'j');
   $q->insertp(5,  20, 'k');
   $q->insertp(5, -10, 'l');
   $q->insertp(5, -12, 'm');
   $q->insertp(5, -20, 'n');

   MCE->do('check_insertp', 'lifo, check insertp', 'kjaibhcgefldmn');
   MCE->do('check_pending', 'lifo, check pending', $q->pending());

   MCE->do('check', 'lifo, check peekp at head     ',   'n', $q->peekp(5     ));
   MCE->do('check', 'lifo, check peekp at index   0',   'n', $q->peekp(5,   0));
   MCE->do('check', 'lifo, check peekp at index   2',   'd', $q->peekp(5,   2));
   MCE->do('check', 'lifo, check peekp at index  13',   'k', $q->peekp(5,  13));
   MCE->do('check', 'lifo, check peekp at index  20', undef, $q->peekp(5,  20));
   MCE->do('check', 'lifo, check peekp at index  -2',   'j', $q->peekp(5,  -2));
   MCE->do('check', 'lifo, check peekp at index -13',   'm', $q->peekp(5, -13));
   MCE->do('check', 'lifo, check peekp at index -14',   'n', $q->peekp(5, -14));
   MCE->do('check', 'lifo, check peekp at index -15', undef, $q->peekp(5, -15));
   MCE->do('check', 'lifo, check peekp at index -20', undef, $q->peekp(5, -20));

   return;
};

MCE::Flow::finish;

###############################################################################

##  HIGHEST priority tests, mix-mode (normal and priority)

$q = MCE::Queue->new(
   porder => $MCE::Queue::HIGHEST, type => $MCE::Queue::FIFO
);

mce_flow sub {
   my ($mce) = @_;

   $q->enqueuep(5, 'a', 'b');    # priority queue
   $q->enqueuep(7, 'e', 'f');    # priority queue
   $q->enqueue (   'i', 'j');    # normal   queue
   $q->enqueuep(8, 'g', 'h');    # priority queue
   $q->enqueuep(6, 'c', 'd');    # priority queue

   my @h = $q->heap;

   MCE->do('check', 'highest, check heap', '8765', join('', @h));
   MCE->do('check', 'highest, check peekh at index  0', '8', $q->peekh( 0));
   MCE->do('check', 'highest, check peekh at index -2', '6', $q->peekh(-2));

   my @r = $q->dequeue(10);

   MCE->do('check', 'highest, check dequeue', 'ghefcdabij', join('', @r));

   return;
};

MCE::Flow::finish;

###############################################################################

##  LOWEST priority tests, mix-mode (normal and priority)

$q = MCE::Queue->new(
   porder => $MCE::Queue::LOWEST, type => $MCE::Queue::FIFO
);

mce_flow sub {
   my ($mce) = @_;

   $q->enqueuep(5, 'a', 'b');    # priority queue
   $q->enqueuep(7, 'e', 'f');    # priority queue
   $q->enqueue (   'i', 'j');    # normal   queue
   $q->enqueuep(8, 'g', 'h');    # priority queue
   $q->enqueuep(6, 'c', 'd');    # priority queue

   my @h = $q->heap;

   MCE->do('check', 'lowest, check heap', '5678', join('', @h));
   MCE->do('check', 'lowest, check peekh at index  0', '5', $q->peekh( 0));
   MCE->do('check', 'lowest, check peekh at index -2', '7', $q->peekh(-2));

   my @r = $q->dequeue(10);

   MCE->do('check', 'lowest, check dequeue', 'abcdefghij', join('', @r));

   return;
};

MCE::Flow::finish;

