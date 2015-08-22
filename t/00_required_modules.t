#!/usr/bin/env perl

use strict;
use warnings;

use Test::More tests => 5;

## The following are minimum Perl modules required by MCE

BEGIN { use_ok('Fcntl', qw( :flock O_CREAT O_TRUNC O_RDWR O_RDONLY )); }
BEGIN { use_ok('File::Path', qw( rmtree )); }
BEGIN { use_ok('Socket', qw( :DEFAULT :crlf )); }
BEGIN { use_ok('Storable', 2.04, qw( store retrieve freeze thaw )); }
BEGIN { use_ok('Time::HiRes', qw( time )); }

