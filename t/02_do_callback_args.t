#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
use open qw(:std :utf8);

use Test::More;

BEGIN {
   use_ok 'MCE';
}

my $come_then_i_pray = "さあ、私は祈る";

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

sub callback3 {
   my ($text) = @_;
   is($text, $come_then_i_pray, 'check utf8 value');
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
      $self->do('callback3', $come_then_i_pray);

      return;
   }
);

$mce->run;

done_testing;

