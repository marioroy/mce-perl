#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;

if ($^O eq 'MSWin32') {
   plan 'tests' => 5;
} else {
   plan 'tests' => 6;
}

## Optional signals detected by MCE::Signal and not tested here are
## $SIG{XCPU} & $SIG{XFSZ}. MCE::Signal assigns signal handlers for
## the following by default.
##
ok(exists $SIG{HUP }, 'Check that $SIG{HUP} exists');
ok(exists $SIG{INT }, 'Check that $SIG{INT} exists');
ok(exists $SIG{PIPE}, 'Check that $SIG{PIPE} exists');
ok(exists $SIG{QUIT}, 'Check that $SIG{QUIT} exists');
ok(exists $SIG{TERM}, 'Check that $SIG{TERM} exists');

if ($^O ne 'MSWin32') {
   ok(exists $SIG{CHLD}, 'Check that $SIG{CHLD} exists');
}

