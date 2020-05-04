#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Test::More;
use Time::HiRes 'sleep';

BEGIN {
   use_ok 'MCE::Child';
}

{
   my ( $cnt, @list, %pids, %ret ); local $_;
   my ( $come_then_i_pray ) = ( "さあ、私は祈る" . "Ǣ" );

   ok( 1, "spawning asynchronously" );

   MCE::Child->create( sub { sleep 2; "$come_then_i_pray $_" } ) for ( 1 .. 3 );

   %pids = map { $_ => undef } MCE::Child->list_pids;
   is ( scalar( keys %pids ), 3, 'check for unique pids' );

   @list = MCE::Child->list_running;
   is ( scalar @list, 3, 'check list_running' );

   @list = MCE::Child->list_joinable;
   is ( scalar @list, 0, 'check list_joinable' );

   @list = MCE::Child->list;
   is ( scalar @list, 3, 'check list' );
   is ( MCE::Child->pending, 3, 'check pending' );

   $cnt = 0;

   for ( @list ) {
      ++$cnt;
      is ( $_->is_running, 1, 'check is_running child'.$cnt );
      is ( $_->is_joinable, '', 'check is_joinable child'.$cnt );
   }

   $cnt = 0;

   for ( @list ) {
      ++$cnt; $ret{ $_->join } = 1;
      is ( $_->error, undef, 'check error child'.$cnt );
   }

   is ( scalar keys %ret, 3, 'check for unique values' );

   for ( sort keys %ret ) {
      my $id = chop; s/ $//;
      is ( $_, $come_then_i_pray, "check for utf8 string $id" );
   };
}

{
   my ( $cnt, @procs ); local $_;

   for ( 1 .. 3 ) {
      push @procs, MCE::Child->create( sub { sleep 1 for 1 .. 9; return 1 } );
   }

   $procs[0]->exit();
   $procs[1]->exit();
   $procs[2]->kill('QUIT');

   $cnt = 0;

   for ( @procs ) {
      ++$cnt;
      is ( $_->join, undef, 'check exit child'.$cnt );
   }
}

{
   sub task {
      my ( $id ) = @_;
      return $id;
   }

   my $cnt_start  = 0;
   my $cnt_finish = 0;

   MCE::Child->init(
      on_start => sub {
         my ( $pid, $id ) = @_;
         ++$cnt_start;
      },
      on_finish => sub {
         my ( $pid, $exit, $id, $sig, $err, @ret ) = @_;
         ++$cnt_finish;
      }
   );

   MCE::Child->create(\&task, 2);

   my $child = MCE::Child->wait_one();
   my $err   = $child->error || 'no error';
   my $res   = $child->result;
   my $pid   = $child->pid;

   is ( $res, "2", 'check wait_one' );

   my @result; local $_;

   MCE::Child->create(\&task, $_) for ( 1 .. 3 );

   my @procs = MCE::Child->wait_all();

   for my $child ( @procs ) {
      my $err = $child->error || 'no error';
      my $res = $child->result;
      my $pid = $child->pid;

      push @result, $res;
   }

   @result = sort @result;

   is ( "@result", "1 2 3", 'check wait_all' );
   is ( $cnt_start , 4, 'check on_start'  );
   is ( $cnt_finish, 4, 'check on_finish' );
}

is ( MCE::Child->finish(), undef, 'check finish' );

done_testing;

