#!/usr/bin/env perl

use strict;
use warnings;

use Test::More tests => 59;
use MCE::Flow max_workers => 1;
use MCE::Shared;

tie my @a1, 'MCE::Shared', ( 10, '', '' );
tie my $e1, 'MCE::Shared';
tie my $e2, 'MCE::Shared';
tie my $d1, 'MCE::Shared';
tie my $s1, 'MCE::Shared';
tie my $s2, 'MCE::Shared';
tie my $s3, 'MCE::Shared';

my $a5 = MCE::Shared->array(0);

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

MCE::Flow::run( sub {
   $a1[0]  +=  5;
   $a1[1]  .= '';
   $a1[2]  .= 'foobar';
   $s1      = scalar @a1;
   $#a1     = 20;
   $s2      = scalar @a1;
   $a5->[0] = 20;
});

MCE::Flow::finish;

is( $a1[0], 15, 'shared array, check fetch, store' );
is( $a1[1], '', 'shared array, check blank value' );
is( $a1[2], 'foobar', 'shared array, check concatenation' );
is( $s1, 3, 'shared array, check fetchsize' );
is( $s2, 21, 'shared array, check storesize' );
is( $a5->[0], 20, 'shared array, check value' );

MCE::Flow::run( sub {
   $e1 = exists $a1[1] ? 1 : 0;
   $d1 = delete $a1[1];
   $e2 = exists $a1[1] ? 1 : 0;
   @a1 = (); $s1 = scalar @a1;
   $a1[2] = [ 'wind', 'air' ];
});

MCE::Flow::finish;

is( $e1,  1, 'shared array, check exists before delete' );
is( $d1, '', 'shared array, check delete' );
is( $e2,  0, 'shared array, check exists after delete' );
is( $s1,  0, 'shared array, check clear' );
is( $a1[2]->[1], 'air', 'shared array, check auto freeze/thaw' );

@a1 = qw( One for all... All for one... );

MCE::Flow::run( sub {
   push(@a1, 'sun', 'moon'); unshift(@a1, 'wind', 'air');
   my @tmp = splice(@a1, 2, 6); $s3 = length(join('', @tmp));
   $s1 = shift(@a1); $s2 = pop(@a1);
});

MCE::Flow::finish;

is( $s3, 24, 'shared array, check splice' );
is( join(' ', @a1), 'air sun', 'shared array, check push, unshift' );
is( $s1, 'wind', 'shared array, check shift' );
is( $s2, 'moon', 'shared array, check pop' );

## --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- ---

## {
##       0 => 'me',
##       1 => 'channel',
##       2 => 'Your',
##       3 => 'Where',
##       4 => 'despair',
##       5 => 'life',
##       6 => 'me',
##       7 => 'hope...',
##       8 => 'there'
##       9 => 'darkness',
##      10 => 'light...',
##      11 => '18',
##      12 => '9',
##      13 => '3',
## }

$a5->clear();

$a5->merge( qw(
   0 me 1 channel 2 Your 3 Where 4 despair 5 life 6 me 7 hope...
   8 there 9 darkness 10 light... 11 18 12 9 13 3
));

## find vals

cmp_array(
   [ $a5->find('val =~ /\.\.\./') ],
   [ qw/ 7 hope... 10 light... / ],
   'shared array, check find vals =~ match'
);
cmp_array(
   [ $a5->find('val !~ /^[a-z]/') ],
   [ qw/ 2 Your 3 Where 11 18 12 9 13 3 / ],
   'shared array, check find vals !~ match'
);
cmp_array(
   [ $a5->find('val eq life') ], [ qw/ 5 life / ],
   'shared array, check find vals eq match'
);

is( $a5->find('val ne despair'), 26, 'shared array, check find vals ne match' );
is( $a5->find('val lt hope...'), 16, 'shared array, check find vals lt match' );
is( $a5->find('val le hope...'), 18, 'shared array, check find vals le match' );
is( $a5->find('val gt hope...'), 10, 'shared array, check find vals gt match' );
is( $a5->find('val ge hope...'), 12, 'shared array, check find vals ge match' );

cmp_array(
   [ $a5->find('val == 9') ], [ qw/ 12 9 / ],
   'shared array, check find vals == match'
);

is( $a5->find('val !=  9'), 4, 'shared array, check find vals != match' );
is( $a5->find('val <   9'), 2, 'shared array, check find vals <  match' );
is( $a5->find('val <=  9'), 4, 'shared array, check find vals <= match' );
is( $a5->find('val >  18'), 0, 'shared array, check find vals >  match' );
is( $a5->find('val >= 18'), 2, 'shared array, check find vals >= match' );

## find undef

$a5->clear();

$a5->merge( qw/ 0 summer 1 winter / );
$a5->set( 2, undef );

cmp_array(
   [ $a5->find('val eq undef') ], [ 2, undef ],
   'shared array, check find vals eq undef'
);
cmp_array(
   [ $a5->find('val ne undef') ], [ qw/ 0 summer 1 winter / ],
   'shared array, check find vals ne undef'
);

## --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- ---

$a5->clear(); $a5->push( 1, 2, 3, 6, 5, 4, 10 );

cmp_array(
   [ $a5->sort() ], [ qw/ 1 2 3 4 5 6 10 / ],
   'shared array, check sort'
);
cmp_array(
   [ $a5->sort("desc") ], [ qw/ 10 6 5 4 3 2 1 / ],
   'shared array, check sort desc'
);
cmp_array(
   [ $a5->sort("alpha") ], [ qw/ 1 10 2 3 4 5 6 / ],
   'shared array, check sort alpha'
);
cmp_array(
   [ $a5->sort("alpha desc") ], [ qw/ 6 5 4 3 2 10 1 / ],
   'shared array, check sort alpha desc'
);

## --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- ---

$a5->clear(); $a5->merge( 0, 'over', 1, 'the', 2, 'rainbow', 3, 77 );

cmp_array(
   [ $a5->pairs() ], [ qw/ 0 over 1 the 2 rainbow 3 77 / ],
   'shared array, check merge'
);
cmp_array(
   [ $a5->mget(0, 2) ], [ qw/ over rainbow / ],
   'shared array, check mget'
);
cmp_array(
   [ $a5->keys() ], [ qw/ 0 1 2 3 / ],
   'shared array, check keys'
);
cmp_array(
   [ $a5->values() ], [ qw/ over the rainbow 77 / ],
   'shared array, check values'
);
cmp_array(
   [ $a5->pairs() ], [ qw/ 0 over 1 the 2 rainbow 3 77 / ],
   'shared array, check pairs'
);

is( $a5->length(), 4, 'shared array, check length' );
is( $a5->length(2), 7, 'shared array, check length( idx )' );
is( $a5->incr(3), 78, 'shared array, check incr' );
is( $a5->decr(3), 77, 'shared array, check decr' );
is( $a5->incrby(3, 4), 81, 'shared array, check incrby' );
is( $a5->decrby(3, 4), 77, 'shared array, check decrby' );
is( $a5->pincr(3), 77, 'shared array, check pincr' );
is( $a5->get(3), 78, 'shared array, check value after pincr' );
is( $a5->pdecr(3), 78, 'shared array, check pdecr' );
is( $a5->get(3), 77, 'shared array, check value after pdecr' );
is( $a5->append(3, 'ba'), 4, 'shared array, check append' );
is( $a5->get(3), '77ba', 'shared array, check value after append' );

my $a6 = $a5->clone();
my $a7 = $a5->clone(2, 3);
my $a8 = $a5->flush();

is( ref($a7), 'MCE::Shared::Array', 'shared array, check ref' );

cmp_array(
   [ $a6->pairs() ], [ qw/ 0 over 1 the 2 rainbow 3 77ba / ],
   'shared array, check clone'
);
cmp_array(
   [ $a7->pairs() ], [ qw/ 0 rainbow 1 77ba / ],
   'shared array, check clone( indices )'
);
cmp_array(
   [ $a8->pairs() ], [ qw/ 0 over 1 the 2 rainbow 3 77ba / ],
   'shared array, check flush'
);

is( $a5->length(), 0, 'shared array, check emptied' );

my $iter  = $a7->iterator();
my $count = 0;
my @check;

while ( my ($idx, $val) = $iter->() ) {
   push @check, $idx, $val;
   $count++;
}

$iter = $a7->iterator();

while ( my $val = $iter->() ) {
   push @check, $val;
   $count++;
}

is( $count, 4, 'shared array, check iterator count' );

cmp_array(
   [ @check ], [ qw/ 0 rainbow 1 77ba rainbow 77ba / ],
   'shared array, check iterator results'
);

