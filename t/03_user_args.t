#!/usr/bin/env perl

use strict;
use warnings;

use Test::More tests => 4;

use MCE::Flow max_workers => 1;

sub check_hello {
   my ($arg1, $arg2) = @_;

   is( $arg1, 'hello', 'check user_args, hello' );
   is( $arg2, 'there', 'check user_args, there' );

   return;
}

sub check_other {
   my ($arg1, $arg2) = @_;

   is( $arg1, 'sunny', 'check user_args, sunny' );
   is( $arg2, 'today', 'check user_args, today' );

   return;
}

##  Workers persist between runs when passed a reference to a subroutine.

sub task {
   my ($arg1, $arg2) = @{ MCE->user_args };

   if ($arg1 eq 'hello') {
      MCE->do('check_hello', $arg1, $arg2);
   }
   else {
      MCE->do('check_other', $arg1, $arg2);
   }

   return;
}

mce_flow { user_args => [ 'hello', 'there' ] }, \&task;
mce_flow { user_args => [ 'sunny', 'today' ] }, \&task;

##  Shutdown workers.

MCE::Flow::finish;

