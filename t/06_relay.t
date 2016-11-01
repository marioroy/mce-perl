#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;

BEGIN {
   use_ok 'MCE::Flow';
}

MCE::Flow::init {
   max_workers => 4,
   init_relay  => 1,
};

## input_data is not required to run mce_flow
##
## statement(s) between relay_recv and relay
## are processed serially and orderly

my @a = mce_flow sub {
   for my $i ( 1 .. 2 ) {
      my $n = MCE->relay_recv;
      MCE->gather( $n );
      MCE->relay( sub { $_ += 1 } );
   }
};

my $v = MCE->relay_final;

is( join('', sort @a), '12345678', 'check relayed data' );
is( $v, '9', 'check final value' );

MCE::Flow::finish;

done_testing;

