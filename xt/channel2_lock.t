#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Time::HiRes 'time';
use MCE::Mutex;

my $mutex = MCE::Mutex->new( impl => 'Channel2' );

is($mutex->impl(), 'Channel2', 'implementation name');

sub task {
    $mutex->lock_exclusive;
    sleep 1;
    $mutex->unlock;
}
sub task2 {
    $mutex->lock_exclusive2;
    sleep 1;
    $mutex->unlock2;
}

sub spawn {
    my $pid = fork;
    task(), exit() if $pid == 0;
    return $pid;
}
sub spawn2 {
    my $pid = fork;
    task2(), exit() if $pid == 0;
    return $pid;
}

my $start = time;
my @pids  = map { spawn(), spawn2() } 1..4;

waitpid($_, 0) for @pids;

my $success = (time - $start > 2) ? 1 : 0;
is($success, 1, 'mutex lock_exclusive2');

done_testing;

