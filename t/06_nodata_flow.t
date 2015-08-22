#!/usr/bin/env perl

use strict;
use warnings;

use Test::More tests => 1;

use MCE::Flow;

MCE::Flow::init {
   max_workers => 4
};

##  input_data is not required to run mce_flow

my @a = mce_flow sub {
   MCE->gather(MCE->wid * 2);
};

is( join('', sort @a), '2468', 'check gathered data' );

MCE::Flow::finish;

