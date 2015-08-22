#!/usr/bin/env perl

use strict;
use warnings;

use Test::More tests => 32;

use MCE::Flow max_workers => 1;
use MCE::Queue;

###############################################################################

##  MCE::Queue supports 3 operating modes (local, manager, worker).
##  This will test MCE::Queue (normal queue) by the MCE manager process.
##
##  *{ 'MCE::Queue::clear'    } = \&MCE::Queue::_mce_m_clear;
##  *{ 'MCE::Queue::enqueue'  } = \&MCE::Queue::_mce_m_enqueue;
##  *{ 'MCE::Queue::dequeue'  } = \&MCE::Queue::_mce_m_dequeue;
##  *{ 'MCE::Queue::insert'   } = \&MCE::Queue::_mce_m_insert;
##  *{ 'MCE::Queue::pending'  } = \&MCE::Queue::_pending;
##  *{ 'MCE::Queue::peek'     } = \&MCE::Queue::_peek;

my (@a, $q, @r);

###############################################################################

##  FIFO tests

@a = (); $q = MCE::Queue->new( queue => \@a, type => $MCE::Queue::FIFO );

$q->enqueue('1', '2');
$q->enqueue('3');
$q->enqueue('4');

is( join('', @a), '1234', 'fifo, check enqueue' );

@r = $q->dequeue(2);
push @r, $q->dequeue;

is( join('', @r), '123', 'fifo, check dequeue' );
is( join('', @a),   '4', 'fifo, check array'   );

$q->clear;

is( scalar(@a), 0, 'fifo, check clear' );

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

is( join('', @a) , 'nmalefgbhcidjk', 'fifo, check insert' );
is( $q->pending(), 14, 'fifo, check pending' );

is( $q->peek(   ),   'n', 'fifo, check peek at head'      );
is( $q->peek(  0),   'n', 'fifo, check peek at index   0' );
is( $q->peek(  2),   'a', 'fifo, check peek at index   2' );
is( $q->peek( 13),   'k', 'fifo, check peek at index  13' );
is( $q->peek( 20), undef, 'fifo, check peek at index  20' );
is( $q->peek( -2),   'j', 'fifo, check peek at index  -2' );
is( $q->peek(-13),   'm', 'fifo, check peek at index -13' );
is( $q->peek(-14),   'n', 'fifo, check peek at index -14' );
is( $q->peek(-15), undef, 'fifo, check peek at index -15' );
is( $q->peek(-20), undef, 'fifo, check peek at index -20' );

###############################################################################

##  LIFO tests

@a = (); $q = MCE::Queue->new( queue => \@a, type => $MCE::Queue::LIFO );

$q->enqueue('1', '2');
$q->enqueue('3');
$q->enqueue('4');

##  Note (lifo)
##
##  Enqueue appends to an array similarly to fifo
##  Thus, the enqueue check is identical to fifo

is( join('', @a), '1234', 'lifo, check enqueue' );

@r = $q->dequeue(2);
push @r, $q->dequeue;

is( join('', @r), '432', 'lifo, check dequeue' );
is( join('', @a),   '1', 'lifo, check array'   );

$q->clear;

is( scalar(@a), 0, 'lifo, check clear' );

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

is( join('', @a) , 'kjaibhcgefldmn', 'lifo, check insert' );
is( $q->pending(), 14, 'lifo, check pending' );

is( $q->peek(   ),   'n', 'lifo, check peek at head'      );
is( $q->peek(  0),   'n', 'lifo, check peek at index   0' );
is( $q->peek(  2),   'd', 'lifo, check peek at index   2' );
is( $q->peek( 13),   'k', 'lifo, check peek at index  13' );
is( $q->peek( 20), undef, 'lifo, check peek at index  20' );
is( $q->peek( -2),   'j', 'lifo, check peek at index  -2' );
is( $q->peek(-13),   'm', 'lifo, check peek at index -13' );
is( $q->peek(-14),   'n', 'lifo, check peek at index -14' );
is( $q->peek(-15), undef, 'lifo, check peek at index -15' );
is( $q->peek(-20), undef, 'lifo, check peek at index -20' );

