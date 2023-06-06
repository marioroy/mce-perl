#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
use open qw(:std :utf8);

use Test::More;

BEGIN {
   use_ok 'MCE::Flow';
   use_ok 'MCE::Queue';
}

MCE::Flow->init(
   max_workers => 1
);

###############################################################################

##  MCE::Queue provides 2 operating modes (manager and worker).
##  This will test (normal queue) by the MCE worker process.
##
##  *{ 'MCE::Queue::clear'    } = \&MCE::Queue::_mce_w_clear;
##  *{ 'MCE::Queue::enqueue'  } = \&MCE::Queue::_mce_w_enqueue;
##  *{ 'MCE::Queue::dequeue'  } = \&MCE::Queue::_mce_w_dequeue;
##  *{ 'MCE::Queue::insert'   } = \&MCE::Queue::_mce_w_insert;
##  *{ 'MCE::Queue::pending'  } = \&MCE::Queue::_mce_w_pending;
##  *{ 'MCE::Queue::peek'     } = \&MCE::Queue::_mce_w_peek;

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

my (@a, $q);

###############################################################################

sub check_clear {
   my ($description) = @_;
   is( scalar(@a), 0, $description );
}

sub check_enqueue {
   my ($description) = @_;
   is( join('', @a), '12345', $description );
}

sub check_insert {
   my ($description, $expected) = @_;
   is( join('', @a), $expected, $description );
}

sub check_pending {
   my ($description, $pending) = @_;
   is( $pending, 14, $description );
}

sub check_unicode_in {
   my ($description) = @_;
   is( join('', @{ $q->_get_aref() }), $sappho_text, $description );
}

sub check_unicode_out {
   my ($description, $value) = @_;
   is( $value, $sappho_text, $description );
}

sub check {
   my ($description, $expected, $value) = @_;
   is( $value, $expected, $description );
}

###############################################################################

##  FIFO tests

@a = ();
$q = MCE::Queue->new( queue => \@a, type => $MCE::Queue::FIFO );

sub check_dequeue_fifo {
   my (@r) = @_;
   is( join('', @r), '1234', 'fifo, check dequeue' );
   is( join('', @a),    '5', 'fifo, check array'   );
}

mce_flow sub {
   my ($mce) = @_;

   $q->enqueue('1', '2');
   $q->enqueue('3');
   $q->enqueue('4', '5');

   MCE->do('check_enqueue', 'fifo, check enqueue');

   my @r = $q->dequeue(2);
   push @r, $q->dequeue;
   push @r, $q->dequeue(1); # Dequeue 1 explicitly

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

   $q->clear;

   $q->enqueue($sappho_text);
   MCE->do('check_unicode_in',  'fifo, check unicode enqueue');
   MCE->do('check_unicode_out', 'fifo, check unicode dequeue', $q->dequeue);

   $q->insert(0, $sappho_text);
   MCE->do('check_unicode_out', 'fifo, check unicode peek', $q->peek(0));
   MCE->do('check_unicode_out', 'fifo, check unicode insert', $q->dequeue_nb);

   $q->enqueue($sappho_text);
   MCE->do('check_unicode_out', 'fifo, check unicode dequeue_timed', $q->dequeue_timed);

   return;
};

MCE::Flow->finish;

###############################################################################

##  LIFO tests

@a = ();
$q = MCE::Queue->new( queue => \@a, type => $MCE::Queue::LIFO );

sub check_dequeue_lifo {
   my (@r) = @_;
   is( join('', @r), '5432', 'lifo, check dequeue' );
   is( join('', @a),    '1', 'lifo, check array'   );
}

mce_flow sub {
   my ($mce) = @_;

   $q->enqueue('1', '2');
   $q->enqueue('3');
   $q->enqueue('4', '5');

   MCE->do('check_enqueue', 'lifo, check enqueue');

   my @r = $q->dequeue(2);
   push @r, $q->dequeue;
   push @r, $q->dequeue(1); # Dequeue 1 explicitly

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

   $q->clear;

   $q->enqueue($sappho_text);
   MCE->do('check_unicode_in',  'lifo, check unicode enqueue');
   MCE->do('check_unicode_out', 'lifo, check unicode dequeue', $q->dequeue);

   $q->insert(0, $sappho_text);
   MCE->do('check_unicode_out', 'lifo, check unicode peek', $q->peek(0));
   MCE->do('check_unicode_out', 'lifo, check unicode insert', $q->dequeue_nb);

   $q->enqueue($sappho_text);
   MCE->do('check_unicode_out', 'lifo, check unicode dequeue_timed', $q->dequeue_timed);

   return;
};

MCE::Flow->finish;

done_testing;

