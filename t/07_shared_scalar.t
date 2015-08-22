#!/usr/bin/env perl

use strict;
use warnings;

use Test::More tests => 3;
use MCE::Flow max_workers => 1;
use MCE::Shared;

my $s1 : Shared = 10;
my $s2 : Shared = '';

my $s5 = mce_share \do{ my $value = 0 };

## --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- ---

MCE::Flow::run( sub {
   $s1  +=  5;
   $s2  .= '';
   $$s5  = 20;
});

MCE::Flow::finish;

is( $s1,  15, 'shared scalar, check fetch, store' );
is( $s2,  '', 'shared scalar, check blank value' );
is( $$s5, 20, 'shared scalar, check value' );

