#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Test::More;

BEGIN {
   use_ok 'MCE::Flow';
}

###############################################################################

## Relay ARRAY

## input_data is not required to run mce_flow
##
## statement(s) between relay_recv and relay
## are processed serially and orderly

{
   my @ret = mce_flow {
      max_workers => 2,
      init_relay  => [ 1, 1 ],
   },
   sub {
      my $ind = MCE->wid - 1;
      for my $i ( 1 .. 4 ) {
         my @data = MCE->relay_recv;
         MCE->gather( $data[ $ind ] );
         MCE->relay( sub { $_->[ $ind ] += 1 } );
      }
   };

   MCE::Flow::finish;

   my @data = MCE->relay_final;

   is( join('', sort @ret), '11223344', 'check relayed data - array' );
   is( join('', @data), '55',           'check final value - array' );
}

###############################################################################

## Relay HASH

{
   my @ret = mce_flow {
      max_workers => 2,
      init_relay  => { 1 => 1, 2 => 1 },
   },
   sub {
      my $key = MCE->wid;
      for my $i ( 1 .. 4 ) {
         my %data = MCE->relay_recv;
         MCE->gather( $data{ $key } );
         MCE->relay( sub { $_->{ $key } += 1 } );
      }
   };

   MCE::Flow::finish;

   my %data = MCE->relay_final;

   is( join('', sort @ret), '11223344', 'check relayed data - hash' );
   is( join('', values %data), '55',    'check final value - hash' );
}

###############################################################################

## Relay SCALAR

{
   my @ret = mce_flow {
      max_workers => 2,
      init_relay  => 1,
   },
   sub {
      for my $i ( 1 .. 4 ) {
         my $n = MCE->relay_recv;
         MCE->gather( $n );
         MCE->relay( sub { $_ += 1 } );
      }
   };

   MCE::Flow::finish;

   my $val = MCE->relay_final;

   is( join('', sort @ret), '12345678', 'check relayed data - scalar' );
   is( $val, '9',                       'check final value - scalar' );
}

###############################################################################

## Relay UTF-8. This also tests gathering UTF-8 strings.

## https://sacred-texts.com/cla/usappho/sph02.htm (VII)

my $sappho_text =
   "ἔλθε μοι καὶ νῦν, χαλεπᾶν δὲ λῦσον\n".
   "ἐκ μερίμναν ὄσσα δέ μοι τέλεσσαι\n".
   "θῦμοσ ἰμμέρρει τέλεσον, σὐ δ᾽ αὔτα\n".
   "σύμμαχοσ ἔσσο.\n";

my $translation =
   "Come then, I pray, grant me surcease from sorrow,\n".
   "Drive away care, I beseech thee, O goddess\n".
   "Fulfil for me what I yearn to accomplish,\n".
   "Be thou my ally.\n";

{
   my @data = mce_flow {
      max_workers => 2,
      init_relay  => $sappho_text,
   },
   sub {
      MCE->relay( sub {
          $_ .= "ὲ";
          MCE->gather( "ἔλθε μοι καὶ νῦν".MCE->wid );
      });
   };

   MCE::Flow::finish;

   my $text = MCE->relay_final;

   is( $data[0], "ἔλθε μοι καὶ νῦν"."1" , 'check gathered data - worker 1' );
   is( $data[1], "ἔλθε μοι καὶ νῦν"."2" , 'check gathered data - worker 2' );
   is( $text   , $sappho_text."ὲὲ"      , 'check final value - utf8' );
}

done_testing;

