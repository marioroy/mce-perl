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
   if ( $^O eq 'cygwin' ) {
      plan skip_all => "MCE::Channel::Threads not used on Cygwin";
   }

   eval 'use threads'; ## no critic
   plan skip_all => "threads not available" if $@;

   use_ok 'MCE::Channel';
   use_ok 'MCE::Channel::Simple';
   use_ok 'MCE::Channel::SimpleFast';
   use_ok 'MCE::Channel::Threads';
   use_ok 'MCE::Channel::ThreadsFast';
}

# https://sacred-texts.com/cla/usappho/sph02.htm (III)

my $sappho_text =
  "ἄρμ᾽ ὐποζεύξαια, κάλοι δέ σ᾽ ἆγον
   ὤκεεσ στροῦθοι περὶ γᾶσ μελαίνασ
   πύκνα δινεῦντεσ πτέῤ ἀπ᾽ ὠράνω
   αἴθεροσ διὰ μέσσω.";

my $translation =
  "With chariot yoked to thy fleet-winged coursers,
   Fluttering swift pinions over earth's darkness,
   And bringing thee through the infinite, gliding
   Downwards from heaven.";

my $come_then_i_pray = "さあ、私は祈る" . "Ǣ";

my $chnl1 = MCE::Channel->new( impl => 'Simple' );
is $chnl1->impl(), 'Simple', 'implementation name';

my $chnl2 = MCE::Channel->new( impl => 'Threads' );
is $chnl2->impl(), 'Threads', 'implementation name';

my $chnl3 = MCE::Channel->new( impl => 'SimpleFast' );
is $chnl3->impl(), 'SimpleFast', 'implementation name';

my $chnl4 = MCE::Channel->new( impl => 'ThreadsFast' );
is $chnl4->impl(), 'ThreadsFast', 'implementation name';

# send recv_nb

for my $chnl ($chnl1, $chnl2)
{
   $chnl->send('a string');
   is $chnl->recv_nb, 'a string', 'send recv_nb scalar';

   $chnl->send($sappho_text);
   is $chnl->recv_nb, $sappho_text, 'send recv_nb utf8';

   $chnl->send($come_then_i_pray);
   is $chnl->recv_nb, $come_then_i_pray, 'send recv_nb utf8_ja';

   $chnl->send(qw/ a list of arguments /);
   is scalar( my @args = $chnl->recv_nb ), 4, 'send recv_nb list';

   $chnl->send({ complex => 'structure' });
   is ref( $chnl->recv_nb ), 'HASH', 'send recv_nb complex';
}

for my $chnl ($chnl3, $chnl4)
{
   $chnl->send('a string');
   is $chnl->recv_nb, 'a string', 'send recv_nb scalar';

   $chnl->send('');
   is $chnl->recv_nb, '', 'send recv_nb blank string';

   $chnl->send(undef);
   is $chnl->recv_nb, '', 'send recv_nb undef stringified';
}

# send2 recv2_nb

for my $chnl ($chnl1, $chnl2)
{
   $chnl->send2('a string');
   is $chnl->recv2_nb, 'a string', 'send2 recv2_nb scalar';

   $chnl->send2($sappho_text);
   is $chnl->recv2_nb, $sappho_text, 'send2 recv2_nb utf8';

   $chnl->send2($come_then_i_pray);
   is $chnl->recv2_nb, $come_then_i_pray, 'send2 recv2_nb utf8_ja';

   $chnl->send2(qw/ a list of arguments /);
   is scalar( my @args = $chnl->recv2_nb ), 4, 'send2 recv2_nb list';

   $chnl->send2({ complex => 'structure' });
   is ref( $chnl->recv2_nb ), 'HASH', 'send2 recv2_nb complex';
}

for my $chnl ($chnl3, $chnl4)
{
   $chnl->send2('a string');
   is $chnl->recv2_nb, 'a string', 'send2 recv2_nb scalar';

   $chnl->send2('');
   is $chnl->recv2_nb, '', 'send2 recv2_nb blank string';

   $chnl->send2(undef);
   is $chnl->recv2_nb, '', 'send2 recv2_nb undef stringified';
}

# enqueue dequeue_nb

for my $chnl ($chnl1, $chnl2)
{
   $chnl->enqueue('a string');
   is $chnl->dequeue_nb, 'a string', 'enqueue dequeue_nb scalar';

   $chnl->enqueue($sappho_text);
   is $chnl->dequeue_nb, $sappho_text, 'enqueue dequeue_nb utf8';

   $chnl->enqueue($come_then_i_pray);
   is $chnl->dequeue_nb, $come_then_i_pray, 'enqueue dequeue_nb utf8_ja';

   $chnl->enqueue(qw/ a list of items /);
   is scalar( my $item1 = $chnl->dequeue_nb ), 'a',     'enqueue dequeue_nb item1';
   is scalar( my $item2 = $chnl->dequeue_nb ), 'list',  'enqueue dequeue_nb item2';
   is scalar( my $item3 = $chnl->dequeue_nb ), 'of',    'enqueue dequeue_nb item3';
   is scalar( my $item4 = $chnl->dequeue_nb ), 'items', 'enqueue dequeue_nb item4';

   $chnl->enqueue({ complex => 'structure' });
   is ref( $chnl->dequeue_nb ), 'HASH', 'enqueue dequeue_nb complex';

   $chnl->enqueue(qw/ a b c /);
   is join( '', $chnl->dequeue_nb(3) ), 'abc', 'enqueue dequeue_nb count';
}

for my $chnl ($chnl3, $chnl4)
{
   $chnl->enqueue('a string');
   is $chnl->dequeue_nb, 'a string', 'enqueue dequeue_nb scalar';

   $chnl->enqueue(qw/ a list of items /);
   is scalar( my $item1 = $chnl->dequeue_nb ), 'a',     'enqueue dequeue_nb item1';
   is scalar( my $item2 = $chnl->dequeue_nb ), 'list',  'enqueue dequeue_nb item2';
   is scalar( my $item3 = $chnl->dequeue_nb ), 'of',    'enqueue dequeue_nb item3';
   is scalar( my $item4 = $chnl->dequeue_nb ), 'items', 'enqueue dequeue_nb item4';

   $chnl->enqueue('');
   is $chnl->dequeue_nb, '', 'enqueue dequeue_nb blank string';

   $chnl->enqueue(undef);
   is $chnl->dequeue_nb, '', 'enqueue dequeue_nb undef stringified';

   $chnl->enqueue(qw/ a b c /);
   is join( '', $chnl->dequeue_nb(3) ), 'abc', 'enqueue dequeue_nb count';
}

done_testing;

