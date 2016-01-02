#!/usr/bin/env perl

use strict;
use warnings;

use Test::Deep qw( !blessed );
use Test::More tests => 8;
use MCE::Shared;

                             # beg, end, step, fmt
my $s1 = MCE::Shared->sequence( 1, 10            );
my $s2 = MCE::Shared->sequence( 1, 10,  2, '%2d' );
my $s3 = MCE::Shared->sequence( 10, 1            );
my $s4 = MCE::Shared->sequence( 10, 1, -2, '%2d' );

my (@a1, @a2, @a3, @a4);

## --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- ---

while ( my $num = $s1->next ) { push @a1, $num; }
while ( my $num = $s2->next ) { push @a2, $num; }
while ( my $num = $s3->next ) { push @a3, $num; }
while ( my $num = $s4->next ) { push @a4, $num; }

cmp_deeply(
   [ @a1 ], [ 1 .. 10 ],
   'shared sequence, check sequence 1: next'
);
cmp_deeply(
   [ @a2 ], [ ' 1', ' 3', ' 5', ' 7', ' 9' ],
   'shared sequence, check sequence 2: next'
);
cmp_deeply(
   [ @a3 ], [ reverse( 1 .. 10 ) ],
   'shared sequence, check sequence 3: next'
);
cmp_deeply(
   [ @a4 ], [ '10', ' 8', ' 6', ' 4', ' 2' ],
   'shared sequence, check sequence 4: next'
);

@a1 = (); $s1->reset;
@a2 = (); $s2->reset;
@a3 = (); $s3->reset;
@a4 = (); $s4->reset;

## --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- ---

while ( my $num = $s1->prev ) { push @a1, $num; }
while ( my $num = $s2->prev ) { push @a2, $num; }
while ( my $num = $s3->prev ) { push @a3, $num; }
while ( my $num = $s4->prev ) { push @a4, $num; }

cmp_deeply(
   [ @a1 ], [ reverse( 1 .. 10 ) ],
   'shared sequence, check sequence 1: prev'
);
cmp_deeply(
   [ @a2 ], [ ' 9', ' 7', ' 5', ' 3', ' 1' ],
   'shared sequence, check sequence 2: prev'
);
cmp_deeply(
   [ @a3 ], [ 1 .. 10 ],
   'shared sequence, check sequence 3: prev'
);
cmp_deeply(
   [ @a4 ], [ ' 2', ' 4', ' 6', ' 8', '10' ],
   'shared sequence, check sequence 4: prev'
);

@a1 = (); $s1->reset;
@a2 = (); $s2->reset;
@a3 = (); $s3->reset;
@a4 = (); $s4->reset;

