#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Test::More;

BEGIN {
   use_ok 'MCE';
}

my $come_then_i_pray = "さあ、私は祈る";

my (@ans, @rpl, $mce);

###############################################################################

sub callback {
   my ($wid) = @_;
   push @ans, $wid;
   return;
}

$mce = MCE->new(
   max_workers => 4,

   user_func => sub {
      MCE->do('callback', MCE->wid());
      return;
   }
);

@ans = ();
$mce->run;

is(join('', sort @ans), '1234', 'test1: check that wid is correct');

###############################################################################

sub callback2 {
   my ($wid) = @_;
   push @ans, $wid;
   return $wid * 2;
}

sub callback3 {
   my ($ans) = @_;
   push @rpl, $ans;
   return;
}

$mce = MCE->new(
   max_workers => 4,

   user_func => sub {
      my $reply = MCE->do('callback2', MCE->wid());
      MCE->do('callback3', $reply);
      return;
   }
);

@ans = (); @rpl = ();
$mce->run;

is(join('', sort @ans), '1234', 'test2: check that wid is correct');
is(join('', sort @rpl), '2468', 'test3: check that scalar is correct');

###############################################################################

sub callback4 {
   return @rpl;
}

sub callback5 {
   my ($a_ref) = @_;
   my %h = ();

   @ans = ();

   foreach (@{ $a_ref }) {
      push @ans, $_ / 2;
      $h{$_ / 2} = $_;
   }

   return %h;
}

sub callback6 {
   return $come_then_i_pray;
}

sub callback7 {
   my ($h_ref) = @_;

   @rpl = ();

   foreach (sort keys %{ $h_ref }) {
      $rpl[$_ - 1] = $h_ref->{$_};
   }

   return;
}

sub callback8 {
   my ($utf8) = @_;
   push @ans, $utf8;
}

$mce = MCE->new(
   max_workers => 1,

   user_func => sub {
      my @reply = MCE->do('callback4');
      my %reply = MCE->do('callback5', \@reply);
      my $utf8  = MCE->do('callback6');

      MCE->do('callback7', \%reply);
      MCE->do('callback8', $utf8);

      return;
   }
);

$mce->run;

is(pop(@ans), $come_then_i_pray, 'test4: check that utf8 is correct');
is(join('', sort @ans), '1234',  'test5: check that list is correct');
is(join('', sort @rpl), '2468',  'test6: check that hash is correct');

done_testing;

