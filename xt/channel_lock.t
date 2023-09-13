#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Time::HiRes 'time';
use MCE::Mutex;

my $mutex = MCE::Mutex->new( impl => 'Channel' );

is($mutex->impl(), 'Channel', 'implementation name');

sub task1 {
    $mutex->lock_exclusive;
    sleep(1) for 1..2;
    $mutex->unlock;
}
sub task2 {
    my $guard = $mutex->guard_lock;
    sleep(1) for 1..2;
}

sub spawn {
    my ($i) = @_;
    my $pid = fork;
    if ($pid == 0) {
        task1() if ($i % 2 != 0);
        task2() if ($i % 2 == 0);
        exit();
    }
    return $pid;
}

my $start = time;
my @pids  = map { spawn($_) } 1..3;

waitpid($_, 0) for @pids;

my $success = (time - $start > 3) ? 1 : 0;
is($success, 1, 'mutex lock_exclusive');

done_testing;

