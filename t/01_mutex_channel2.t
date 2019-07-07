#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use MCE::Mutex;

{
    my $mutex = MCE::Mutex->new( impl => 'Channel2' );

    is( $mutex->impl(), 'Channel2', 'implementation name 1' );
}

done_testing;

