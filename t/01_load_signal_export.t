#!/usr/bin/env perl

use strict;
use warnings;

use Test::More tests => 2;

## Always load MCE::Signal before MCE when wanting to export or pass options.

BEGIN {
   use_ok('MCE::Signal', qw( $tmp_dir sys_cmd stop_and_exit ));
   use_ok('MCE');
}

