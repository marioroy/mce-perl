#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Test::More;

BEGIN {
   use_ok 'MCE::Flow';
}

my $come_then_i_pray = "さあ、私は祈る";

MCE::Flow::init {
   max_workers => 1
};

sub check_hello {
   my ($arg1, $arg2, $arg3) = @_;

   is( $arg1, 'hello',           'check user_args (array ref), hello' );
   is( $arg2, 'there',           'check user_args (array ref), there' );
   is( $arg3, $come_then_i_pray, 'check user_args (array ref), utf8'  );

   return;
}

sub check_sunny {
   my ($arg1, $arg2, $arg3) = @_;

   is( $arg1, 'sunny',           'check user_args (array ref), sunny' );
   is( $arg2, 'today',           'check user_args (array ref), today' );
   is( $arg3, $come_then_i_pray, 'check user_args (array ref), utf8'  );

   return;
}

sub check_utf_8 {
   my ($text) = @_;

   is( $text, $come_then_i_pray, 'check user_args (scalar val), utf8' );

   return;
}

##  Workers persist between runs when passed a reference to a subroutine.

sub task {
   my $data = MCE->user_args;

   # array reference
   if (ref $data) {
      my ($arg1, $arg2, $arg3) = @{ $data };

      if ($data->[0] eq 'hello') {
         MCE->do('check_hello', $arg1, $arg2, $arg3);
      } else {
         MCE->do('check_sunny', $arg1, $arg2, $arg3);
      }
   }
   # scalar value
   else {
      MCE->do('check_utf_8', $data);
   }

   return;
}

mce_flow { user_args => [ 'hello', 'there', $come_then_i_pray ] }, \&task;
mce_flow { user_args => [ 'sunny', 'today', $come_then_i_pray ] }, \&task;
mce_flow { user_args => $come_then_i_pray }, \&task;

##  Shutdown workers.

MCE::Flow::finish;

done_testing;

