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
    sleep 5;
    $mutex->unlock;
}
sub task2 {
    $mutex->lock_exclusive2;
    sleep 5;
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

{
    my $pid   = spawn(); sleep 1;
    my $start = time; my $ret = $mutex->timedwait(2);
    my $end   = time;

    waitpid($pid, 0);

    my $success = ($end - $start < 3) ? 1 : 0;
    is($success, 1, 'mutex timedwait');
    is($ret, '', 'mutex timedwait value');
}

{
    my $pid   = spawn2(); sleep 1;
    my $start = time; my $ret = $mutex->timedwait2(2);
    my $end   = time;

    waitpid($pid, 0);

    my $success = ($end - $start < 3) ? 1 : 0;
    is($success, 1, 'mutex timedwait2');
    is($ret, '', 'mutex timedwait2 value');
}

done_testing;

