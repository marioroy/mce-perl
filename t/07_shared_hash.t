#!/usr/bin/env perl

use strict;
use warnings;

use Test::More tests => 10;
use MCE::Flow max_workers => 1;
use MCE::Shared;

my %h1   : Shared = ( k1 => 10, k2 => '', k3 => '' );
my $keys : Shared;
my $e1   : Shared;
my $e2   : Shared;
my $d1   : Shared;
my $s1   : Shared;

my $h5   = mce_share { n => 0 };

## --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- ---

MCE::Flow::run( sub {
   $h1{k1}  +=  5;
   $h1{k2}  .= '';
   $h1{k3}  .= 'foobar';
   $keys     = join(' ', sort keys %h1);
   $h5->{n}  = 20;
});

MCE::Flow::finish;

is( $h1{k1}, 15, 'shared hash, check fetch, store' );
is( $h1{k2}, '', 'shared hash, check blank value' );
is( $h1{k3}, 'foobar', 'shared hash, check concatenation' );
is( $keys, 'k1 k2 k3', 'shared hash, check firstkey, nextkey' );
is( $h5->{n}, 20, 'shared hash, check value' );

## --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- ---

MCE::Flow::run( sub {
   $e1 = exists $h1{'k2'} ? 1 : 0;
   $d1 = delete $h1{'k2'};
   $e2 = exists $h1{'k2'} ? 1 : 0;
   %h1 = (); $s1 = scalar %h1;
   $h1{ret} = [ 'wind', 'air' ];
});

MCE::Flow::finish;

is( $e1,  1, 'shared hash, check exists before delete' );
is( $d1, '', 'shared hash, check delete' );
is( $e2,  0, 'shared hash, check exists after delete' );
is( $s1,  0, 'shared hash, check clear' );
is( $h1{ret}->[1], 'air', 'shared hash, check auto freeze/thaw' );

