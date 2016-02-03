#!/usr/bin/env perl

use strict;
use warnings;

use Test::More tests => 126;
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

$a5->mset( qw(
   0 me 1 channel 2 Your 3 Where 4 despair 5 life 6 me 7 hope...
   8 there 9 darkness 10 light... 11 18 12 9 13 3
));

## find keys

cmp_array(
   [ $a5->pairs('key =~ /3/') ], [ qw/ 3 Where 13 3 / ],
   'shared array, check find keys =~ match (pairs)'
);
cmp_array(
   [ $a5->keys('key =~ /3/') ], [ qw/ 3 13 / ],
   'shared array, check find keys =~ match (keys)'
);
cmp_array(
   [ $a5->vals('key =~ /3/') ], [ qw/ Where 3 / ],
   'shared array, check find keys =~ match (vals)'
);

cmp_array(
   [ $a5->pairs('key !~ /^[1]/') ],
   [ qw/ 0 me 2 Your 3 Where 4 despair 5 life 6 me 7 hope... 8 there 9 darkness / ],
   'shared array, check find keys !~ match (pairs)'
);
cmp_array(
   [ $a5->keys('key !~ /^[1]/') ],
   [ qw/ 0 2 3 4 5 6 7 8 9 / ],
   'shared array, check find keys !~ match (keys)'
);
cmp_array(
   [ $a5->vals('key !~ /^[1]/') ],
   [ qw/ me Your Where despair life me hope... there darkness / ],
   'shared array, check find keys !~ match (vals)'
);

cmp_array(
   [ $a5->pairs('key eq 1') ], [ qw/ 1 channel / ],
   'shared array, check find keys eq match (pairs)'
);
cmp_array(
   [ $a5->keys('key eq 1') ], [ qw/ 1 / ],
   'shared array, check find keys eq match (keys)'
);
cmp_array(
   [ $a5->vals('key eq 1') ], [ qw/ channel / ],
   'shared array, check find keys eq match (vals)'
);

cmp_array(
   [ $a5->pairs('key == 1') ], [ qw/ 1 channel / ],
   'shared array, check find keys == match (pairs)'
);
cmp_array(
   [ $a5->keys('key == 1') ], [ qw/ 1 / ],
   'shared array, check find keys == match (keys)'
);
cmp_array(
   [ $a5->vals('key == 1') ], [ qw/ channel / ],
   'shared array, check find keys == match (vals)'
);

cmp_array(
   [ $a5->pairs('key < 2 :AND val eq me') ], [ qw/ 0 me / ],
   'shared array, check find keys && match (pairs)'
);
cmp_array(
   [ $a5->keys('key < 2 :AND val eq me') ], [ qw/ 0 / ],
   'shared array, check find keys && match (keys)'
);
cmp_array(
   [ $a5->vals('key < 2 :AND val eq me') ], [ qw/ me / ],
   'shared array, check find keys && match (vals)'
);

## find vals

cmp_array(
   [ $a5->pairs('val =~ /\.\.\./') ],
   [ qw/ 7 hope... 10 light... / ],
   'shared array, check find vals =~ match (pairs)'
);
cmp_array(
   [ $a5->keys('val =~ /\.\.\./') ],
   [ qw/ 7 10 / ],
   'shared array, check find vals =~ match (keys)'
);
cmp_array(
   [ $a5->vals('val =~ /\.\.\./') ],
   [ qw/ hope... light... / ],
   'shared array, check find vals =~ match (vals)'
);

cmp_array(
   [ $a5->pairs('val !~ /^[a-z]/') ],
   [ qw/ 2 Your 3 Where 11 18 12 9 13 3 / ],
   'shared array, check find vals !~ match (pairs)'
);
cmp_array(
   [ $a5->keys('val !~ /^[a-z]/') ],
   [ qw/ 2 3 11 12 13 / ],
   'shared array, check find vals !~ match (keys)'
);
cmp_array(
   [ $a5->vals('val !~ /^[a-z]/') ],
   [ qw/ Your Where 18 9 3 / ],
   'shared array, check find vals !~ match (vals)'
);

cmp_array(
   [ $a5->pairs('val =~ /\.\.\./ :OR key >= 12') ],
   [ qw/ 7 hope... 10 light... 12 9 13 3 / ],
   'shared array, check find vals || match (pairs)'
);
cmp_array(
   [ $a5->keys('val =~ /\.\.\./ :OR key >= 12') ],
   [ qw/ 7 10 12 13 / ],
   'shared array, check find vals || match (keys)'
);
cmp_array(
   [ $a5->vals('val =~ /\.\.\./ :OR key >= 12') ],
   [ qw/ hope... light... 9 3 / ],
   'shared array, check find vals || match (vals)'
);

cmp_array(
   [ $a5->pairs('val eq life') ], [ qw/ 5 life / ],
   'shared array, check find vals eq match (pairs)'
);
cmp_array(
   [ $a5->keys('val eq life') ], [ qw/ 5 / ],
   'shared array, check find vals eq match (keys)'
);
cmp_array(
   [ $a5->vals('val eq life') ], [ qw/ life / ],
   'shared array, check find vals eq match (vals)'
);

is( $a5->pairs('val ne despair'), 26, 'shared array, check find vals ne match (pairs)' );
is( $a5->keys('val ne despair'), 13, 'shared array, check find vals ne match (keys)' );
is( $a5->vals('val ne despair'), 13, 'shared array, check find vals ne match (vals)' );

is( $a5->pairs('val lt hope...'), 16, 'shared array, check find vals lt match (pairs)' );
is( $a5->keys('val lt hope...'),  8, 'shared array, check find vals lt match (keys)' );
is( $a5->vals('val lt hope...'),  8, 'shared array, check find vals lt match (vals)' );

is( $a5->pairs('val le hope...'), 18, 'shared array, check find vals le match (pairs)' );
is( $a5->keys('val le hope...'),  9, 'shared array, check find vals le match (keys)' );
is( $a5->vals('val le hope...'),  9, 'shared array, check find vals le match (vals)' );

is( $a5->pairs('val gt hope...'), 10, 'shared array, check find vals gt match (pairs)' );
is( $a5->keys('val gt hope...'),  5, 'shared array, check find vals gt match (keys)' );
is( $a5->vals('val gt hope...'),  5, 'shared array, check find vals gt match (vals)' );

is( $a5->pairs('val ge hope...'), 12, 'shared array, check find vals ge match (pairs)' );
is( $a5->keys('val ge hope...'),  6, 'shared array, check find vals ge match (keys)' );
is( $a5->vals('val ge hope...'),  6, 'shared array, check find vals ge match (vals)' );

cmp_array(
   [ $a5->pairs('val == 9') ], [ qw/ 12 9 / ],
   'shared array, check find vals == match (pairs)'
);
cmp_array(
   [ $a5->keys('val == 9') ], [ qw/ 12 / ],
   'shared array, check find vals == match (keys)'
);
cmp_array(
   [ $a5->vals('val == 9') ], [ qw/ 9 / ],
   'shared array, check find vals == match (vals)'
);

is( $a5->pairs('val !=  9'), 4, 'shared array, check find vals != match (pairs)' );
is( $a5->keys('val !=  9'), 2, 'shared array, check find vals != match (keys)' );
is( $a5->vals('val !=  9'), 2, 'shared array, check find vals != match (vals)' );

is( $a5->pairs('val <   9'), 2, 'shared array, check find vals <  match (pairs)' );
is( $a5->keys('val <   9'), 1, 'shared array, check find vals <  match (keys)' );
is( $a5->vals('val <   9'), 1, 'shared array, check find vals <  match (vals)' );

is( $a5->pairs('val <=  9'), 4, 'shared array, check find vals <= match (pairs)' );
is( $a5->keys('val <=  9'), 2, 'shared array, check find vals <= match (keys)' );
is( $a5->vals('val <=  9'), 2, 'shared array, check find vals <= match (vals)' );

is( $a5->pairs('val >  18'), 0, 'shared array, check find vals >  match (pairs)' );
is( $a5->keys('val >  18'), 0, 'shared array, check find vals >  match (keys)' );
is( $a5->vals('val >  18'), 0, 'shared array, check find vals >  match (vals)' );

is( $a5->pairs('val >= 18'), 2, 'shared array, check find vals >= match (pairs)' );
is( $a5->keys('val >= 18'), 1, 'shared array, check find vals >= match (keys)' );
is( $a5->vals('val >= 18'), 1, 'shared array, check find vals >= match (vals)' );

## find undef

$a5->clear();

$a5->mset( qw/ 0 summer 1 winter / );
$a5->set( 2, undef );

cmp_array(
   [ $a5->pairs('val eq undef') ], [ 2, undef ],
   'shared array, check find vals eq undef (pairs)'
);
cmp_array(
   [ $a5->keys('val eq undef') ], [ 2 ],
   'shared array, check find vals eq undef (keys)'
);
cmp_array(
   [ $a5->vals('val eq undef') ], [ undef ],
   'shared array, check find vals eq undef (vals)'
);

cmp_array(
   [ $a5->pairs('val ne undef') ], [ qw/ 0 summer 1 winter / ],
   'shared array, check find vals ne undef (pairs)'
);
cmp_array(
   [ $a5->keys('val ne undef') ], [ qw/ 0 1 / ],
   'shared array, check find vals ne undef (keys)'
);
cmp_array(
   [ $a5->vals('val ne undef') ], [ qw/ summer winter / ],
   'shared array, check find vals ne undef (vals)'
);

## --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- ---

$a5->clear(); $a5->push( 1, 2, 3, 6, 5, 4, 10 );

## sorted vals

cmp_array(
   [ $a5->sort() ], [ qw/ 1 2 3 4 5 6 10 / ],
   'shared array, check sorted vals'
);
cmp_array(
   [ $a5->sort("desc") ], [ qw/ 10 6 5 4 3 2 1 / ],
   'shared array, check sorted vals desc'
);
cmp_array(
   [ $a5->sort("alpha") ], [ qw/ 1 10 2 3 4 5 6 / ],
   'shared array, check sorted vals alpha'
);
cmp_array(
   [ $a5->sort("alpha desc") ], [ qw/ 6 5 4 3 2 10 1 / ],
   'shared array, check sorted vals alpha desc'
);

## sort vals in-place

$a5->sort(), cmp_array(
   [ $a5->vals() ], [ qw/ 1 2 3 4 5 6 10 / ],
   'shared array, check in-place sort'
);
$a5->sort("desc"), cmp_array(
   [ $a5->vals() ], [ qw/ 10 6 5 4 3 2 1 / ],
   'shared array, check in-place sort desc'
);
$a5->sort("alpha"), cmp_array(
   [ $a5->vals() ], [ qw/ 1 10 2 3 4 5 6 / ],
   'shared array, check in-place sort alpha'
);
$a5->sort("alpha desc"), cmp_array(
   [ $a5->vals() ], [ qw/ 6 5 4 3 2 10 1 / ],
   'shared array, check in-place sort alpha desc'
);

## --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- ---

$a5->clear(); $a5->mset( 0, 'over', 1, 'the', 2, 'rainbow', 3, 77 );

cmp_array(
   [ $a5->pairs() ], [ qw/ 0 over 1 the 2 rainbow 3 77 / ],
   'shared array, check mset'
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
   [ $a5->vals() ], [ qw/ over the rainbow 77 / ],
   'shared array, check values'
);
cmp_array(
   [ $a5->pairs() ], [ qw/ 0 over 1 the 2 rainbow 3 77 / ],
   'shared array, check pairs'
);

is( $a5->len(), 4, 'shared array, check length' );
is( $a5->len(2), 7, 'shared array, check length( idx )' );
is( $a5->incr(3), 78, 'shared array, check incr' );
is( $a5->decr(3), 77, 'shared array, check decr' );
is( $a5->incrby(3, 4), 81, 'shared array, check incrby' );
is( $a5->decrby(3, 4), 77, 'shared array, check decrby' );
is( $a5->getincr(3), 77, 'shared array, check getincr' );
is( $a5->get(3), 78, 'shared array, check value after getincr' );
is( $a5->getdecr(3), 78, 'shared array, check getdecr' );
is( $a5->get(3), 77, 'shared array, check value after getdecr' );
is( $a5->append(3, 'ba'), 4, 'shared array, check append' );
is( $a5->get(3), '77ba', 'shared array, check value after append' );
is( $a5->getset('3', '77bc'), '77ba', 'shared array, check getset' );
is( $a5->get(3), '77bc', 'shared array, check value after getset' );

my $a6 = $a5->clone();
my $a7 = $a5->clone(2, 3);
my $a8 = $a5->flush();

is( ref($a7), 'MCE::Shared::Array', 'shared array, check ref' );

cmp_array(
   [ $a6->pairs() ], [ qw/ 0 over 1 the 2 rainbow 3 77bc / ],
   'shared array, check clone'
);
cmp_array(
   [ $a7->pairs() ], [ qw/ 0 rainbow 1 77bc / ],
   'shared array, check clone( indices )'
);
cmp_array(
   [ $a8->pairs() ], [ qw/ 0 over 1 the 2 rainbow 3 77bc / ],
   'shared array, check flush'
);

is( $a5->len(), 0, 'shared array, check emptied' );

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
   [ @check ], [ qw/ 0 rainbow 1 77bc rainbow 77bc / ],
   'shared array, check iterator results'
);

## --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- ---

my @list;

$a5->clear(); $a5->mset( 0, 'over', 1, 'the', 2, 'rainbow', 3, 77 );

while ( my $val = $a5->next ) { push @list, $val; }

cmp_array(
   [ sort @list ], [ sort qw/ over the rainbow 77 / ],
   'shared array, check next'
);

@list = (); $a5->rewind('val =~ /[a-z]/');

while ( my ($key, $val) = $a5->next ) { push @list, $key, $val; }

cmp_array(
   [ sort @list ], [ sort qw/ 0 over 1 the 2 rainbow / ],
   'shared array, check rewind 1'
);

@list = (); $a5->rewind(qw/ 1 2 /);

while ( my $val = $a5->next ) { push @list, $val; }

cmp_array(
   [ sort @list ], [ sort qw/ the rainbow / ],
   'shared array, check rewind 2'
);

is( $a5->mexists(qw/ 0 2 3 /),  1, 'shared array, check mexists 1' );
is( $a5->mexists(qw/ 0 8 3 /), '', 'shared array, check mexists 2' );

is( $a5->mdel(qw/ 3 2 1 0 /), 4, 'shared array, check mdel' );

##

$a5->push( qw/ one two three / );

cmp_array(
   [ $a5->range(0, 0) ], [ 'one' ],
   'shared array, check range 1'
);
cmp_array(
   [ $a5->range(-3, 2) ], [ 'one', 'two', 'three' ],
   'shared array, check range 2'
);
cmp_array(
   [ $a5->range(-100, 100) ], [ 'one', 'two', 'three' ],
   'shared array, check range 3'
);
cmp_array(
   [ $a5->range(5, 10) ], [ ],
   'shared array, check range 4'
);
cmp_array(
   [ $a5->range(-1, -1) ], [ 'three' ],
   'shared array, check range 5'
);

