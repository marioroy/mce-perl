#!/usr/bin/env perl

use strict;
use warnings;

use Test::More tests => 1;

use MCE::Step;

MCE::Step::init {
   max_workers => 4
};

##  input_data is not required to run mce_step

my @a = mce_step sub {
   MCE->gather(MCE->wid * 2);
};

is( join('', sort @a), '2468', 'check gathered data' );

MCE::Step::finish;

