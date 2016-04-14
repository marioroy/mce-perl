#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;

## Always load MCE::Signal before MCE when wanting to export or pass options.

BEGIN {
   use_ok('MCE::Signal', qw( :all :tmp_dir ));
   use_ok('MCE');
}

done_testing;

