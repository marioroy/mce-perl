#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;

BEGIN {
   use_ok 'MCE';
   use_ok 'MCE::Flow';
   use_ok 'MCE::Candy';
}

{
   my @data;

   MCE->new(
      max_workers => 4,
      input_data => [ 1 .. 4 ],
      gather => MCE::Candy::out_iter_array(\@data),
      user_func => sub {
         my ($mce, $chunk_ref, $chunk_id) = @_;
         MCE->gather( $chunk_id, $chunk_ref->[0] * 2 );
      }
   )->run;

   is( join('', @data), '2468', 'check out_iter_array' );
}

{
   my @data;

   sub append_data {
      push @data, $_[0];
   }

   mce_flow {
      max_workers => 4,
      gather => MCE::Candy::out_iter_callback(\&append_data)
   },
   sub {
      MCE->gather( MCE->wid, MCE->wid * 2 );
   };

   MCE::Flow->finish;

   is( join('', @data), '2468', 'check out_iter_callback' );
}

done_testing;

