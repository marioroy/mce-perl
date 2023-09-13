#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Time::HiRes 'time';
use MCE::Mutex;

my $mutex = MCE::Mutex->new( impl => 'Flock' );

is($mutex->impl(), 'Flock', 'implementation name');

sub task1 {
    $mutex->lock_exclusive;
    sleep 1;
    $mutex->unlock;
}
sub task2 {
    my $guard = $mutex->guard_lock;
    sleep 1;
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
my @pids  = map { spawn($_) } 1..4;

waitpid($_, 0) for @pids;

my $success = (time - $start > 2) ? 1 : 0;
is($success, 1, 'mutex lock_exclusive');

done_testing;

