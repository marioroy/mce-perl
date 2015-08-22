#!/usr/bin/env perl

use strict;
use warnings;

use Test::More tests => 3;

use MCE;

my @ans;

sub callback {
   my ($element) = @_;
   push @ans, $element;
   return;
}

my $mce = MCE->new(
   max_workers => 2,

   user_func => sub {
      my ($self, $chunk_ref, $chunk_id) = @_;

      for ( @{ $chunk_ref } ) {
         MCE->do('callback', $_);
      }

      return;
   }
);

@ans = ();
$mce->process([ 0 .. 3 ], { chunk_size => 1 });

is(
   join('', sort @ans), '0123',
   'check that ans is correct for chunk_size of 1'
);

@ans = ();
$mce->process([ 0 .. 7 ], { chunk_size => 2 });

is(
   join('', sort @ans), '01234567',
   'check that ans is correct for chunk_size of 2'
);

@ans = ();
$mce->process([ 0 .. 9 ], { chunk_size => 4 });

is(
   join('', sort @ans), '0123456789',
   'check that ans is correct for chunk_size of 4'
);

$mce->shutdown();

