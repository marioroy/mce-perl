#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Time::HiRes 'time';
use MCE::Mutex;

my $mutex = MCE::Mutex->new( impl => 'Flock' );

is($mutex->impl(), 'Flock', 'implementation name');

sub task {
    $mutex->lock_exclusive;
    sleep 1;
    $mutex->unlock;
}
sub spawn {
    my $pid = fork;
    task(), exit() if $pid == 0;
    return $pid;
}

my $start = time;
my @pids  = map { spawn() } 1..4;

waitpid($_, 0) for @pids;

my $success = (time - $start > 2) ? 1 : 0;
is($success, 1, 'mutex lock_exclusive');

done_testing;

