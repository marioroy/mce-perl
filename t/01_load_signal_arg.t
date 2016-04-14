#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;

## Default is $MCE::Signal::tmp_dir which points to $ENV{TEMP} if defined.
## Otherwise, pass argument to module wanting /dev/shm versus /tmp for
## temporary files. MCE::Signal falls back to /tmp unless /dev/shm exists.
##
## One optional argument not tested here is -keep_tmp_dir which omits the
## removal of $tmp_dir on exit. A message is displayed by MCE::Signal stating
## the location of $tmp_dir when exiting.
##
## Always load MCE::Signal before MCE when wanting to export or pass options.

our $tmp_dir;

my $msg_eq = 'Check tmp_dir matches ^/dev/shm/';
my $msg_ne = 'Check tmp_dir does not match ^/dev/shm/';

BEGIN {
   use_ok('MCE::Signal', qw( $tmp_dir -use_dev_shm ));

   if (! exists $ENV{TEMP} && -d '/dev/shm' && -w '/dev/shm') {
      ok($tmp_dir =~ m{^/dev/shm/}x, $msg_eq);
   }
   elsif (exists $ENV{TEMP} && not (-d $ENV{TEMP} && -w $ENV{TEMP})) {
      if (-d '/dev/shm' && -w '/dev/shm') {
         ok($tmp_dir =~ m{^/dev/shm/}x, $msg_eq);
      } else {
         ok($tmp_dir !~ m{^/dev/shm/}x, $msg_ne);
      }
   }
   else {
      ok($tmp_dir !~ m{^/dev/shm/}x, $msg_ne);
   }

   use_ok('MCE');
}

done_testing;

