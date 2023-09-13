#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Time::HiRes 'time';
use MCE::Mutex;

my $mutex = MCE::Mutex->new( impl => 'Channel2' );

is($mutex->impl(), 'Channel2', 'implementation name');

sub task1a {
    $mutex->lock_exclusive;
    sleep(1) for 1..2;
    $mutex->unlock;
}
sub task1b {
    my $guard = $mutex->guard_lock;
    sleep(1) for 1..2;
}

sub spawn1 {
    my ($i) = @_;
    my $pid = fork;
    if ($pid == 0) {
        task1a() if ($i % 2 != 0);
        task1b() if ($i % 2 == 0);
        exit();
    }
    return $pid;
}

sub task2a {
    $mutex->lock_exclusive2;
    sleep(1) for 1..2;
    $mutex->unlock2;
}
sub task2b {
    my $guard = $mutex->guard_lock2;
    sleep(1) for 1..2;
}

sub spawn2 {
    my ($i) = @_;
    my $pid = fork;
    if ($pid == 0) {
        task2a() if ($i % 2 != 0);
        task2b() if ($i % 2 == 0);
        exit();
    }
    return $pid;
}

my $start = time;
my @pids  = map { spawn1($_), spawn2($_) } 1..3;

waitpid($_, 0) for @pids;

my $success = (time - $start > 3) ? 1 : 0;
is($success, 1, 'mutex lock_exclusive2');

done_testing;

