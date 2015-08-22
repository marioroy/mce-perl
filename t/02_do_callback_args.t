#!/usr/bin/env perl

use strict;
use warnings;

use Test::More tests => 4;

use MCE;

sub callback1 {
   my ($a_ref, $h_ref, $s_ref) = @_;

   is($a_ref->[1], 'two', 'check array reference');
   is($h_ref->{'two'}, 'TWO', 'check hash reference');
   is(${ $s_ref }, 'fall colors', 'check scalar reference');

   return;
}

sub callback2 {
   my ($wid) = @_;
   is($wid, 1, 'check scalar value');
   return;
}

my $mce = MCE->new(
   max_workers => 1,

   user_func => sub {
      my ($self) = @_;

      my @a = ('one', 'two');
      my %h = ('one' => 'ONE', 'two' => 'TWO');
      my $s = 'fall colors';

      $self->do('callback1', \@a, \%h, \$s);
      $self->do('callback2', $self->wid());

      return;
   }
);

$mce->run;

