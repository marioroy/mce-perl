#!/usr/bin/env perl

use strict;
use warnings;

use Test::More tests => 5;

use MCE;

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
   my ($h_ref) = @_;

   @rpl = ();

   foreach (sort keys %{ $h_ref }) {
      $rpl[$_ - 1] = $h_ref->{$_};
   }

   return;
}

$mce = MCE->new(
   max_workers => 1,

   user_func => sub {
      my @reply = MCE->do('callback4');
      my %reply = MCE->do('callback5', \@reply);

      MCE->do('callback6', \%reply);

      return;
   }
);

$mce->run;

is(join('', sort @ans), '1234', 'test4: check that list is correct');
is(join('', sort @rpl), '2468', 'test5: check that hash is correct');

