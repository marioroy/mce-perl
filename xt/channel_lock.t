#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Time::HiRes 'time';
use MCE::Mutex;

my $mutex = MCE::Mutex->new( impl => 'Channel' );

is($mutex->impl(), 'Channel', 'implementation name');

sub task {
    $mutex->lock_exclusive;
    sleep(1) for 1..2;
    $mutex->unlock;
}
sub spawn {
    my $pid = fork;
    task(), exit() if $pid == 0;
    return $pid;
}

my $start = time;
my @pids  = map { spawn() } 1..3;

waitpid($_, 0) for @pids;

my $success = (time - $start > 3) ? 1 : 0;
is($success, 1, 'mutex lock_exclusive');

done_testing;

