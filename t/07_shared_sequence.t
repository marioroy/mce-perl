#!/usr/bin/env perl

use strict;
use warnings;

use Test::More tests => 10;
use MCE::Shared;
                             # beg, end, step, fmt
my $s1 = MCE::Shared->sequence( 1, 10            );
my $s2 = MCE::Shared->sequence( 1, 10,  2, '%2d' );
my $s3 = MCE::Shared->sequence( 10, 1            );
my $s4 = MCE::Shared->sequence( 10, 1, -2, '%2d' );

my (@a1, @a2, @a3, @a4);

sub cmp_array {
   no warnings qw(uninitialized);

   return ok(0, $_[2]) if (ref $_[0] ne 'ARRAY' || ref $_[1] ne 'ARRAY');
   return ok(0, $_[2]) if (@{ $_[0] } != @{ $_[1] });

   for (0 .. $#{ $_[0] }) {
      return ok(0, $_[2]) if ($_[0][$_] ne $_[1][$_]);
   }

   ok(1, $_[2]);
}

## --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- ---

while ( my $num = $s1->next ) { push @a1, $num; }
while ( my $num = $s2->next ) { push @a2, $num; }
while ( my $num = $s3->next ) { push @a3, $num; }
while ( my $num = $s4->next ) { push @a4, $num; }

cmp_array(
   [ @a1 ], [ 1 .. 10 ],
   'shared sequence, check sequence 1: next'
);
cmp_array(
   [ @a2 ], [ ' 1', ' 3', ' 5', ' 7', ' 9' ],
   'shared sequence, check sequence 2: next'
);
cmp_array(
   [ @a3 ], [ reverse( 1 .. 10 ) ],
   'shared sequence, check sequence 3: next'
);
cmp_array(
   [ @a4 ], [ '10', ' 8', ' 6', ' 4', ' 2' ],
   'shared sequence, check sequence 4: next'
);

@a1 = (); $s1->rewind;
@a2 = (); $s2->rewind( 1, 5 );
@a3 = (); $s3->rewind;
@a4 = (); $s4->rewind;

while ( my $num = $s1->next ) { push @a1, $num; }
while ( my $num = $s2->next ) { push @a2, $num; }

cmp_array(
   [ @a1 ], [ 1 .. 10 ],
   'shared sequence, check sequence 1: rewind'
);
cmp_array(
   [ @a2 ], [ 1 .. 5 ],
   'shared sequence, check sequence 1: rewind( 1, 5 )'
);

@a1 = (); $s1->rewind;
@a2 = (); $s2->rewind;

## --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- ---

$s1 = MCE::Shared->sequence(
   { chunk_size => 10, bounds_only => 1 }, 1, 100
);

while ( my ( $beg, $end ) = $s1->next ) {
   push @a1, $beg;
   push @a2, $end;
}

cmp_array(
   [ @a1 ], [ qw/ 1 11 21 31 41 51 61 71 81 91 / ],
   'shared sequence, check sequence: bounds_only beg values'
);
cmp_array(
   [ @a2 ], [ qw/ 10 20 30 40 50 60 70 80 90 100 / ],
   'shared sequence, check sequence: bounds_only end values'
);

@a1 = (), @a2 = ();

$s1->rewind( { chunk_size => 10 }, 1, 20 );

@a1 = $s1->next();
@a2 = $s1->next();

cmp_array(
   [ @a1 ], [ qw/ 1 2 3 4 5 6 7 8 9 10 / ],
   'shared sequence, check sequence: chunk_size chunk 1'
);
cmp_array(
   [ @a2 ], [ qw/ 11 12 13 14 15 16 17 18 19 20 / ],
   'shared sequence, check sequence: chunk_size chunk 2'
);

