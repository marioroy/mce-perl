#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
use open qw(:std :utf8);

use Test::More;

# Non-blocking tests (dequeue_nb and recv_nb) were disabled
# in MCE 1.884 for the Windows platform; copied here in xt.
# The following tests pass on Windows, typically.

BEGIN {
   use_ok 'MCE::Flow';
   use_ok 'MCE::Queue';
}

MCE::Flow->init(
   max_workers => 1
);

# https://sacred-texts.com/cla/usappho/sph02.htm (VI)

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

sub check_unicode_out {
   my ($description, $value) = @_;
   is( $value, $sappho_text, $description );
}

# MCE::Queue provides 2 operating modes (manager and worker).
# This will test (normal queue) by the manager process.

my @a = ();
my $q = MCE::Queue->new( queue => \@a );

$q->enqueue($sappho_text);
is( $q->dequeue_nb, $sappho_text, 'check dequeue_nb - manager' );

# This will test (normal queue) by the MCE worker process.

mce_flow sub {
   $q->enqueue($sappho_text);
   MCE->do('check_unicode_out', 'check dequeue_nb - worker', $q->dequeue_nb);
   return;
};

MCE::Flow->finish;

done_testing;

