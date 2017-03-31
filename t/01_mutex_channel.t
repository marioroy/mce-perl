#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use MCE::Mutex;

{
    my $mutex = MCE::Mutex->new( impl => 'Channel' );

    is( $mutex->impl(), 'Channel', 'implementation name 1' );
}
{
    my $mutex = MCE::Mutex->new();

    is( $mutex->impl(), 'Channel', 'implementation name 2' );
}

done_testing;

