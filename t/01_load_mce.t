#!/usr/bin/env perl

use strict;
use warnings;

use Test::More tests => 2;

## MCE::Signal is loaded by MCE automatically and is not neccessary in
## scripts unless wanting to export or pass options.

BEGIN {
   use_ok('MCE');
   use_ok('MCE::Util');
}

