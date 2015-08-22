#!/usr/bin/env perl

use strict;
use warnings;

use Test::More tests => 40;

use MCE::Queue;

###############################################################################

##  MCE::Queue supports 3 operating modes (local, manager, worker).
##  This will test MCE::Queue (priority queue) in local mode.
##
##  Local mode is selected when MCE is not present, during importing of
##  MCE::Queue, or when initiating queues from inside the worker process.
##
##  *{ 'MCE::Queue::clear'    } = \&MCE::Queue::_clear;
##  *{ 'MCE::Queue::enqueuep' } = \&MCE::Queue::_enqueuep;
##  *{ 'MCE::Queue::dequeue'  } = \&MCE::Queue::_dequeue;
##  *{ 'MCE::Queue::insertp'  } = \&MCE::Queue::_insertp;
##  *{ 'MCE::Queue::pending'  } = \&MCE::Queue::_pending;
##  *{ 'MCE::Queue::peekp'    } = \&MCE::Queue::_peekp;
##  *{ 'MCE::Queue::peekh'    } = \&MCE::Queue::_peekh;
##  *{ 'MCE::Queue::heap'     } = \&MCE::Queue::_heap;

my ($q, @r, @h);

###############################################################################

##  FIFO tests

$q = MCE::Queue->new( type => $MCE::Queue::FIFO );

$q->enqueuep(5, '1', '2');
$q->enqueuep(5, '3');
$q->enqueuep(5, '4');

is( join('', @{ $q->_get_aref(5) }), '1234', 'fifo, check enqueuep' );

@r = $q->dequeue(2);
push @r, $q->dequeue;

is( join('', @r), '123', 'fifo, check dequeue' );
is( join('', @{ $q->_get_aref(5) }), '4', 'fifo, check array' );

$q->clear;

is( $q->_get_aref(5), undef, 'fifo, check clear' );

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

is( join('', @{ $q->_get_aref(5) }), 'nmalefgbhcidjk', 'fifo, check insertp' );
is( $q->pending(), 14, 'fifo, check pending' );

is( $q->peekp(5     ),   'n', 'fifo, check peekp at head'      );
is( $q->peekp(5,   0),   'n', 'fifo, check peekp at index   0' );
is( $q->peekp(5,   2),   'a', 'fifo, check peekp at index   2' );
is( $q->peekp(5,  13),   'k', 'fifo, check peekp at index  13' );
is( $q->peekp(5,  20), undef, 'fifo, check peekp at index  20' );
is( $q->peekp(5,  -2),   'j', 'fifo, check peekp at index  -2' );
is( $q->peekp(5, -13),   'm', 'fifo, check peekp at index -13' );
is( $q->peekp(5, -14),   'n', 'fifo, check peekp at index -14' );
is( $q->peekp(5, -15), undef, 'fifo, check peekp at index -15' );
is( $q->peekp(5, -20), undef, 'fifo, check peekp at index -20' );

###############################################################################

##  LIFO tests

$q = MCE::Queue->new( type => $MCE::Queue::LIFO );

$q->enqueuep(5, '1', '2');
$q->enqueuep(5, '3');
$q->enqueuep(5, '4');

##  Note (lifo)
##
##  Enqueue appends to an array similarly to fifo
##  Thus, the enqueuep check is identical to fifo

is( join('', @{ $q->_get_aref(5) }), '1234', 'lifo, check enqueuep' );

@r = $q->dequeue(2);
push @r, $q->dequeue;

is( join('', @r), '432', 'lifo, check dequeue' );
is( join('', @{ $q->_get_aref(5) }), '1', 'lifo, check array' );

$q->clear;

is( $q->_get_aref(5), undef, 'lifo, check clear' );

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

is( join('', @{ $q->_get_aref(5) }), 'kjaibhcgefldmn', 'lifo, check insertp' );
is( $q->pending(), 14, 'lifo, check pending' );

is( $q->peekp(5     ),   'n', 'lifo, check peekp at head'      );
is( $q->peekp(5,   0),   'n', 'lifo, check peekp at index   0' );
is( $q->peekp(5,   2),   'd', 'lifo, check peekp at index   2' );
is( $q->peekp(5,  13),   'k', 'lifo, check peekp at index  13' );
is( $q->peekp(5,  20), undef, 'lifo, check peekp at index  20' );
is( $q->peekp(5,  -2),   'j', 'lifo, check peekp at index  -2' );
is( $q->peekp(5, -13),   'm', 'lifo, check peekp at index -13' );
is( $q->peekp(5, -14),   'n', 'lifo, check peekp at index -14' );
is( $q->peekp(5, -15), undef, 'lifo, check peekp at index -15' );
is( $q->peekp(5, -20), undef, 'lifo, check peekp at index -20' );

###############################################################################

##  HIGHEST priority tests

$q = MCE::Queue->new(
   porder => $MCE::Queue::HIGHEST, type => $MCE::Queue::FIFO
);

$q->enqueuep(5, 'a', 'b');    # priority queue
$q->enqueuep(7, 'e', 'f');    # priority queue
$q->enqueue (   'i', 'j');    # normal   queue
$q->enqueuep(8, 'g', 'h');    # priority queue
$q->enqueuep(6, 'c', 'd');    # priority queue

@h = $q->heap;

is( join('', @h), '8765', 'highest, check heap' );
is( $q->peekh( 0), '8',   'lowest, check peekh at index  0' );
is( $q->peekh(-2), '6',   'lowest, check peekh at index -2' );

@r = $q->dequeue(10);

is( join('', @r), 'ghefcdabij', 'highest, check dequeue' );

###############################################################################

##  LOWEST priority tests

$q = MCE::Queue->new(
   porder => $MCE::Queue::LOWEST, type => $MCE::Queue::FIFO
);

$q->enqueuep(5, 'a', 'b');    # priority queue
$q->enqueuep(7, 'e', 'f');    # priority queue
$q->enqueue (   'i', 'j');    # normal   queue
$q->enqueuep(8, 'g', 'h');    # priority queue
$q->enqueuep(6, 'c', 'd');    # priority queue

@h = $q->heap;

is( join('', @h), '5678', 'lowest, check heap' );
is( $q->peekh( 0), '5',   'lowest, check peekh at index  0' );
is( $q->peekh(-2), '7',   'lowest, check peekh at index -2' );

@r = $q->dequeue(10);

is( join('', @r), 'abcdefghij', 'highest, check dequeue' );

