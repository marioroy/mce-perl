#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
use open qw(:std :utf8);

use Test::More;

BEGIN {
   use_ok 'MCE::Queue';
}

###############################################################################

##  MCE::Queue provides 2 operating modes (manager and worker).
##  This will test (normal queue) by the manager process.
##
##  *{ 'MCE::Queue::clear'    } = \&MCE::Queue::_mce_m_clear;
##  *{ 'MCE::Queue::enqueue'  } = \&MCE::Queue::_mce_m_enqueue;
##  *{ 'MCE::Queue::dequeue'  } = \&MCE::Queue::_mce_m_dequeue;
##  *{ 'MCE::Queue::insert'   } = \&MCE::Queue::_mce_m_insert;
##  *{ 'MCE::Queue::pending'  } = \&MCE::Queue::_mce_m_pending;
##  *{ 'MCE::Queue::peek'     } = \&MCE::Queue::_mce_m_peek;

## https://sacred-texts.com/cla/usappho/sph02.htm (VI)

my $sappho_text =
  "καὶ γάρ αἰ φεύγει, ταχέωσ διώξει,
   αἰ δὲ δῶρα μὴ δέκετ ἀλλά δώσει,
   αἰ δὲ μὴ φίλει ταχέωσ φιλήσει,
   κωὐκ ἐθέλοισα." . "Ǣ";

my $translation =
  "For if now she flees, quickly she shall follow
   And if she spurns gifts, soon shall she offer them
   Yea, if she knows not love, soon shall she feel it
   Even reluctant.";

my (@a, $q, @r);

###############################################################################

##  FIFO tests

@a = ();
$q = MCE::Queue->new( queue => \@a, type => $MCE::Queue::FIFO );

$q->enqueue('1', '2');
$q->enqueue('3');
$q->enqueue('4', '5');

is( join('', @a), '12345', 'fifo, check enqueue' );

@r = $q->dequeue(2);
push @r, $q->dequeue;
push @r, $q->dequeue(1); # Dequeue 1 explicitly

is( join('', @r), '1234', 'fifo, check dequeue' );
is( join('', @a),    '5', 'fifo, check array'   );

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

$q->clear;

$q->enqueue($sappho_text);
is( join('', @{ $q->_get_aref() }), $sappho_text, 'fifo, check unicode enqueue' );
is( $q->dequeue, $sappho_text, 'fifo, check unicode dequeue' );

$q->insert(0, $sappho_text);
is( $q->peek(0), $sappho_text,    'fifo, check unicode peek' );
is( $q->dequeue_nb, $sappho_text, 'fifo, check unicode insert' );

$q->enqueue($sappho_text);
is( $q->dequeue_timed, $sappho_text, 'fifo, check unicode dequeue_timed' );

###############################################################################

##  LIFO tests

@a = ();
$q = MCE::Queue->new( queue => \@a, type => $MCE::Queue::LIFO );

$q->enqueue('1', '2');
$q->enqueue('3');
$q->enqueue('4', '5');

##  Note (lifo)
##
##  Enqueue appends to an array similarly to fifo
##  Thus, the enqueue check is identical to fifo

is( join('', @a), '12345', 'lifo, check enqueue' );

@r = $q->dequeue(2);
push @r, $q->dequeue;
push @r, $q->dequeue(1); # Dequeue 1 explicitly

is( join('', @r), '5432', 'lifo, check dequeue' );
is( join('', @a),    '1', 'lifo, check array'   );

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

$q->clear;

$q->enqueue($sappho_text);
is( join('', @{ $q->_get_aref() }), $sappho_text, 'lifo, check unicode enqueue' );
is( $q->dequeue, $sappho_text, 'lifo, check unicode dequeue' );

$q->insert(0, $sappho_text);
is( $q->peek(0), $sappho_text,    'lifo, check unicode peek' );
is( $q->dequeue_nb, $sappho_text, 'lifo, check unicode insert' );

$q->enqueue($sappho_text);
is( $q->dequeue_timed, $sappho_text, 'lifo, check unicode dequeue_timed' );

done_testing;

