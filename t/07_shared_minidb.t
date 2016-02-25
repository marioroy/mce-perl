#!/usr/bin/env perl

use strict;
use warnings;

use Test::More tests => 197;
use MCE::Shared;

my (@keys, @vals, @rows, $iter);

my $db = MCE::Shared->minidb();

sub cmp_array {
   no warnings qw(uninitialized);

   return ok(0, $_[2]) if (ref $_[0] ne 'ARRAY' || ref $_[1] ne 'ARRAY');
   return ok(0, $_[2]) if (@{ $_[0] } != @{ $_[1] });

   for (0 .. $#{ $_[0] }) {
      return ok(0, $_[2]) if ($_[0][$_] ne $_[1][$_]);
   }

   ok(1, $_[2]);
}

##############################################################################
## ---------------------------------------------------------------------------
## HoH - Hashes
##
## { k1 } => {
##       'Make' => 'me',
##          'a' => 'channel',
##         'of' => 'Your',
##   'peace...' => 'Where',
##   'there\'s' => 'despair',
##         'in' => 'life',
##        'let' => 'me',
##      'bring' => 'hope...',
##      'Where' => 'there'
##         'is' => 'darkness',
##       'only' => 'light...',
##         '16' => '18',
##          '7' => '9',
##          '2' => '3',
## },
##
## { k2 } => {
##   ...
## },
##
##############################################################################

## hlen, hclear

$db->hset( 'k2', qw(
   Make me a channel of Your peace...
   Where there's despair in life let me bring hope...
   Where there is darkness only light...
   16 18 7 9 2 3
));

is( $db->hlen('k2'), 14, 'shared minidb hash, check len k2' );
is( $db->hlen('k2','a'), 7, 'shared minidb hash, check len k2->{ field }' );
is( $db->hlen(), 1, 'shared minidb hash, check len' );

$db->hclear('k2');
is( $db->hlen('k2'), 0, 'shared minidb hash, check clear k2' );

$db->hclear();
is( $db->hlen(), 0, 'shared minidb hash, check clear' );

$db->hset( 'k1', qw(
   Make me f2 channel of Your peace...
   Where there's despair f6 life let me bring hope...
   Where there is darkness only light...
   baz 18 7 9 2 3
));

$db->hset( 'k2', qw(
   make me f2 channel of your peace...
   where there's despair f6 life let me bring hope...
   where there is darkness only light...
   baz 20 7 9 2 3
));

## hkeys, hpairs, hvals

is( $db->hkeys(),  2, 'shared minidb hash, check keys count' );
is( $db->hpairs(), 2, 'shared minidb hash, check pairs count' );
is( $db->hvals(),  2, 'shared minidb hash, check vals count' );

is( $db->hkeys('k2'),  14, 'shared minidb hash, check keys("k2") count' );
is( $db->hpairs('k2'), 14, 'shared minidb hash, check pairs("k2") count' );
is( $db->hvals('k2'),  14, 'shared minidb hash, check vals("k2") count' );

is(
   $db->hkeys('k1', 'key =~ /^(?:Make|a|of)$/ :OR key < 3 :OR val =~ /e/'), 11,
   'shared minidb hash, check hkeys("k1", "query") count'
);
is(
   $db->hkeys('peace... eq where'), 1,
   'shared minidb hash, check hkeys("query1") count'
);

cmp_array(
   [ $db->hkeys('peace... =~ /where/i') ], [ 'k1', 'k2' ],
   'shared minidb hash, check hkeys("query2")'
);
is(
   $db->hpairs('peace... =~ /where/i'), 4,
   'shared minidb hash, check hkeys("query4")'
);
is(
   $db->hvals('peace... =~ /where/i'), 2,
   'shared minidb hash, check hkeys("query3")'
);

## rewind/next, parallel iteration; available in shared context

@keys = (), @vals = (); $db->rewind(':hashes');

while ( my ($key, $val) = $db->next ) {
   push @keys, $key;
   push @vals, $val->{'peace...'};
}

cmp_array(
   [ @keys ], [ qw/ k1 k2 / ],
   'shared minidb hash, check rewind/next 1'
);
cmp_array(
   [ @vals ], [ qw/ Where where / ],
   'shared minidb hash, check rewind/next 2'
);

@keys = (), @vals = (); $db->rewind(':hashes', qw/ k1 k2 /);

while ( my ($key, $val) = $db->next ) {
   push @keys, $key;
   push @vals, $val->{'peace...'};
}

cmp_array(
   [ @keys ], [ qw/ k1 k2 / ],
   'shared minidb hash, check rewind/next 3'
);
cmp_array(
   [ @vals ], [ qw/ Where where / ],
   'shared minidb hash, check rewind/next 4'
);

@keys = (), @vals = (); $db->rewind(':hashes', 'baz == 20');

while ( my ($key, $val) = $db->next ) {
   push @keys, $key;
   push @vals, $val->{'baz'};
}

cmp_array(
   [ @keys ], [ qw/ k2 / ],
   'shared minidb hash, check rewind/next 5'
);
cmp_array(
   [ @vals ], [ qw/ 20 / ],
   'shared minidb hash, check rewind/next 6'
);

@keys = (), @vals = (); $db->rewind(':hashes', 'k2', 'val =~ /e/');

while ( my ($key, $val) = $db->next ) {
   push @keys, $key;
   push @vals, $val;
}

cmp_array(
   [ sort @keys ], [ sort qw/ make f2 peace... there's f6 let bring where is / ],
   'shared minidb hash, check rewind/next 7'
);
cmp_array(
   [ sort @vals ], [ sort qw/ me channel where despair life me hope... there darkness / ],
   'shared minidb hash, check rewind/next 8'
);

## iterator, non-parallel iteration

@keys = (), @vals = (); $iter = $db->iterator(':hashes');

while ( my ($key, $val) = $iter->() ) {
   push @keys, $key;
   push @vals, $val->{'peace...'};
}

cmp_array(
   [ @keys ], [ qw/ k1 k2 / ],
   'shared minidb hash, check iterator 1'
);
cmp_array(
   [ @vals ], [ qw/ Where where / ],
   'shared minidb hash, check iterator 2'
);

@keys = (), @vals = (); $iter = $db->iterator(':hashes', qw/ k1 k2 /);

while ( my ($key, $val) = $iter->() ) {
   push @keys, $key;
   push @vals, $val->{'peace...'};
}

cmp_array(
   [ @keys ], [ qw/ k1 k2 / ],
   'shared minidb hash, check iterator 3'
);
cmp_array(
   [ @vals ], [ qw/ Where where / ],
   'shared minidb hash, check iterator 4'
);

@keys = (), @vals = (); $iter = $db->iterator(':hashes', 'baz == 20');

while ( my ($key, $val) = $iter->() ) {
   push @keys, $key;
   push @vals, $val->{'baz'};
}

cmp_array(
   [ @keys ], [ qw/ k2 / ],
   'shared minidb hash, check iterator 5'
);
cmp_array(
   [ @vals ], [ qw/ 20 / ],
   'shared minidb hash, check iterator 6'
);

@keys = (), @vals = (); $iter = $db->iterator(':hashes', 'k2', 'val =~ /e/');

while ( my ($key, $val) = $iter->() ) {
   push @keys, $key;
   push @vals, $val;
}

cmp_array(
   [ sort @keys ], [ sort qw/ make f2 peace... there's f6 let bring where is / ],
   'shared minidb hash, check iterator 7'
);
cmp_array(
   [ sort @vals ], [ sort qw/ me channel where despair life me hope... there darkness / ],
   'shared minidb hash, check iterator 8'
);

## select_aref ( ':hashes', 'query string' )

@rows = $db->select_aref(':hashes', 'f2 f6 baz :ORDER BY baz DESC');
is( $rows[1][1][2], 18, 'shared minidb hash, check select_aref 1' );

@rows = $db->select_aref(':hashes', 'f2 f6 baz :WHERE baz == 20');
is( $rows[0][1][2], 20, 'shared minidb hash, check select_aref 2' );
is( @rows, 1, 'shared minidb hash, check select_aref 2 count' );

@rows = $db->select_aref(':hashes', 'f2 f6 baz');
is( @rows, 2, 'shared minidb hash, check select_aref 3 count' );

## select_href ( ':hashes', 'query string' )

@rows = $db->select_href(':hashes', 'f2 f6 baz :ORDER BY baz DESC');
is( $rows[1][1]{baz}, 18, 'shared minidb hash, check select_href 1' );

@rows = $db->select_href(':hashes', 'f2 f6 baz :WHERE baz == 20');
is( $rows[0][1]{baz}, 20, 'shared minidb hash, check select_href 2' );
is( @rows, 1, 'shared minidb hash, check select_href 2 count' );

@rows = $db->select_href(':hashes', 'f2 f6 baz');
is( @rows, 2, 'shared minidb hash, check select_href 3 count' );

## hget

is(
   ref($db->hget('k1')), 'MCE::Shared::Hash',
   'shared minidb hash, check hget key'
);
is(
   $db->hget('k1', 'f6'), 'life',
   'shared minidb hash, check hget field'
);
cmp_array(
   [ $db->hget('k1', 'f2', 'f6') ], [ 'channel', 'life' ],
   'shared minidb hash, check hget fields'
);

## hexists

is(
   $db->hexists('k1'), 1,
   'shared minidb hash, check hexists valid key'
);
is(
   $db->hexists('k1','f2'), 1,
   'shared minidb hash, check hexists valid field'
);
is(
   $db->hexists('k1','f2','f6'), 1,
   'shared minidb hash, check hexists valid fields'
);

is(
   $db->hexists('k3'), '',
   'shared minidb hash, check hexists invalid key'
);
is(
   $db->hexists('k3','f3'), '',
   'shared minidb hash, check hexists invalid field'
);
is(
   $db->hexists('k3','f3','f2'), '',
   'shared minidb hash, check hexists invalid fields'
);

## hdel

is(
   $db->hdel('k1', 'let', 'only'), 2,
   'shared minidb hash, check hdel fields'
);
is(
   $db->hdel('k1', 'f6'), 'life',
   'shared minidb hash, check hdel field'
);
is(
   ref($db->hdel('k1')), 'MCE::Shared::Hash',
   'shared minidb hash, check hdel key'
);

## hset

is(
   $db->hset('k2', 'f15', 'foo', 'f16', 'bar'), 16,
   'shared minidb hash, check hset fields'
);
is(
   $db->hset('k2', 'f17', 'baz'), 'baz',
   'shared minidb hash, check hset field'
);
is(
   $db->hset('k3'), undef,  # no-op without field/value
   'shared minidb hash, check hset key, no-op'
);

## hsort

$db->hclear;

$db->hset('k1', qw/ f1 bb f2 10 f3 aa /);
$db->hset('k9', qw/ f1 cc f2 40 f3 bb /);
$db->hset('k5', qw/ f1 aa f2 20 f3 hh /);
$db->hset('k3', qw/ f1 dd f2 30 f3 ee /);
$db->hset( '2', qw/ f1 ff f2 80 f3 cc /);
$db->hset( '1', qw/ f1 hh f2 70 f3 ff /);
$db->hset('10', qw/ f1 ee f2 90 f3 dd /);

cmp_array(
   [ $db->hsort('BY key DESC ALPHA') ], [ qw/ k9 k5 k3 k1 2 10 1 / ],
   'shared minidb hash, check hsort (list-context) by key 1'
);
cmp_array(
   [ $db->hsort('BY key DESC') ], [ qw/ 10 2 1 k1 k9 k5 k3 / ],
   'shared minidb hash, check hsort (list-context) by key 2'
);
cmp_array(
   [ $db->hsort('BY key ALPHA') ], [ qw/ 1 10 2 k1 k3 k5 k9 / ],
   'shared minidb hash, check hsort (list-context) by key 3'
);
cmp_array(
   [ $db->hsort('BY key') ], [ qw/ k1 k9 k5 k3 1 2 10 / ],
   'shared minidb hash, check hsort (list-context) by key 4'
);

cmp_array(
   [ $db->hsort('BY f1 DESC ALPHA') ], [ qw/ 1 2 10 k3 k9 k1 k5 / ],
   'shared minidb hash, check hsort (list-context) by field 1'
);
cmp_array(
   [ $db->hsort('BY f2 DESC') ], [ qw/ 10 2 1 k9 k3 k5 k1 / ],
   'shared minidb hash, check hsort (list-context) by field 2'
);
cmp_array(
   [ $db->hsort('BY f1 ALPHA') ], [ qw/ k5 k1 k9 k3 10 2 1 / ],
   'shared minidb hash, check hsort (list-context) by field 3'
);
cmp_array(
   [ $db->hsort('BY f2') ], [ qw/ k1 k5 k3 k9 1 2 10 / ],
   'shared minidb hash, check hsort (list-context) by field 4'
);

cmp_array(
   [ $db->hkeys ], [ qw/ k1 k9 k5 k3 2 1 10 / ],
   'shared minidb hash, check hsort (list-context)'
);

$db->hsort('BY key DESC ALPHA');

cmp_array(
   [ $db->hkeys() ], [ qw/ k9 k5 k3 k1 2 10 1 / ],
   'shared minidb hash, check hsort (in-place) by key 1'
);

$db->hsort('BY key DESC');

cmp_array(
   [ $db->hkeys() ], [ qw/ 10 2 1 k9 k5 k3 k1 / ],
   'shared minidb hash, check hsort (in-place) by key 2'
);

$db->hsort('BY key ALPHA');

cmp_array(
   [ $db->hkeys() ], [ qw/ 1 10 2 k1 k3 k5 k9 / ],
   'shared minidb hash, check hsort (in-place) by key 3'
);

$db->hsort('BY key');

cmp_array(
   [ $db->hkeys() ], [ qw/ k1 k3 k5 k9 1 2 10 / ],
   'shared minidb hash, check hsort (in-place) by key 4'
);

$db->hsort('BY f1 DESC ALPHA');

cmp_array(
   [ $db->hkeys() ], [ qw/ 1 2 10 k3 k9 k1 k5 / ],
   'shared minidb hash, check hsort (in-place) by field 1'
);

$db->hsort('BY f2 DESC');

cmp_array(
   [ $db->hkeys() ], [ qw/ 10 2 1 k9 k3 k5 k1 / ],
   'shared minidb hash, check hsort (in-place) by field 2'
);

$db->hsort('BY f1 ALPHA');

cmp_array(
   [ $db->hkeys() ], [ qw/ k5 k1 k9 k3 10 2 1 / ],
   'shared minidb hash, check hsort (in-place) by field 3'
);

$db->hsort('BY f2');

cmp_array(
   [ $db->hkeys() ], [ qw/ k1 k5 k3 k9 1 2 10 / ],
   'shared minidb hash, check hsort (in-place) by field 4'
);

# sugar API

$db->hclear;
$db->hset('k1','f1', 77);

is ( $db->hincr('k1','f1'), 78, 'shared minidb hash, check hincr' );
is ( $db->hdecr('k1','f1'), 77, 'shared minidb hash, check hdecr' );
is ( $db->hincrby('k1','f1', 4), 81, 'shared minidb hash, check hincrby' );
is ( $db->hdecrby('k1','f1', 4), 77, 'shared minidb hash, check hdecrby' );
is ( $db->hgetincr('k1','f1'), 77, 'shared minidb hash, check hgetincr' );
is ( $db->hget('k1','f1'), 78, 'shared minidb hash, check value after hgetincr' );
is ( $db->hgetdecr('k1','f1'), 78, 'shared minidb hash, check hgetdecr' );
is ( $db->hget('k1','f1'), 77, 'shared minidb hash, check value after hgetdecr' );
is ( $db->happend('k1','f1','ba'), 4, 'shared minidb hash, check happend' );
is ( $db->hget('k1','f1'), '77ba', 'shared minidb hash, check value after happend' );
is ( $db->hgetset('k1','f1','77bc'), '77ba', 'shared minidb hash, check hgetset' );
is ( $db->hget('k1','f1'), '77bc', 'shared minidb hash, check value after hgetset' );


##############################################################################
## ---------------------------------------------------------------------------
## HoA - Lists
##
## { k1 } => [
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
## ],
##
## { k2 } => [
##   ...
## ],
##
##############################################################################

## llen, llclear

$db->lset( 'k2', qw(
   0 me 1 channel 2 Your 3 Where 4 despair 5 life 6 me 7 hope...
   8 there 9 darkness 10 light... 11 18 12 9 13 3
));

is( $db->llen('k2'), 14, 'shared minidb list, check len k2' );
is( $db->llen('k2','1'), 7, 'shared minidb list, check len k2->[ index ]' );
is( $db->llen(), 1, 'shared minidb list, check len' );

$db->lclear('k2');
is( $db->llen('k2'), 0, 'shared minidb list, check clear k2' );

$db->lclear();
is( $db->llen(), 0, 'shared minidb list, check clear' );

$db->lset( 'k1', qw(
   0 me 1 channel 2 Your 3 Where 4 despair 5 life 6 me 7 hope...
   8 there 9 darkness 10 light... 11 18 12 9 13 3
));

$db->lset( 'k2', qw(
   0 me 1 channel 2 your 3 where 4 despair 5 life 6 me 7 hope...
   8 there 9 darkness 10 light... 11 20 12 9 13 3
));

## lkeys, lpairs, lvals

is( $db->lkeys(),  2, 'shared minidb list, check keys count' );
is( $db->lpairs(), 2, 'shared minidb list, check pairs count' );
is( $db->lvals(),  2, 'shared minidb list, check vals count' );

is( $db->lkeys('k2'),  14, 'shared minidb list, check keys("k2") count' );
is( $db->lpairs('k2'), 14, 'shared minidb list, check pairs("k2") count' );
is( $db->lvals('k2'),  14, 'shared minidb list, check vals("k2") count' );

is(
   $db->lkeys('k1', 'key < 4 :OR key > 12 :OR val =~ /e/'), 11,
   'shared minidb list, check lkeys("k1", "query") count'
);
is(
   $db->lkeys('3 eq where'), 1,
   'shared minidb list, check lkeys("query1") count'
);

cmp_array(
   [ $db->lkeys('3 =~ /where/i') ], [ 'k1', 'k2' ],
   'shared minidb list, check lkeys("query2")'
);
is(
   $db->lpairs('3 =~ /where/i'), 4,
   'shared minidb list, check lpairs("query4")'
);
is(
   $db->lvals('3 =~ /where/i'), 2,
   'shared minidb list, check lvals("query3")'
);

## rewind/next, parallel iteration; available in shared context

@keys = (), @vals = (); $db->rewind(':lists');

while ( my ($key, $val) = $db->next ) {
   push @keys, $key;
   push @vals, $val->[3];
}

cmp_array(
   [ @keys ], [ qw/ k1 k2 / ],
   'shared minidb list, check rewind/next 1'
);
cmp_array(
   [ @vals ], [ qw/ Where where / ],
   'shared minidb list, check rewind/next 2'
);

@keys = (), @vals = (); $db->rewind(':lists', qw/ k1 k2 /);

while ( my ($key, $val) = $db->next ) {
   push @keys, $key;
   push @vals, $val->[3];
}

cmp_array(
   [ @keys ], [ qw/ k1 k2 / ],
   'shared minidb list, check rewind/next 3'
);
cmp_array(
   [ @vals ], [ qw/ Where where / ],
   'shared minidb list, check rewind/next 4'
);

@keys = (), @vals = (); $db->rewind(':lists', '11 == 20');

while ( my ($key, $val) = $db->next ) {
   push @keys, $key;
   push @vals, $val->[11];
}

cmp_array(
   [ @keys ], [ qw/ k2 / ],
   'shared minidb list, check rewind/next 5'
);
cmp_array(
   [ @vals ], [ qw/ 20 / ],
   'shared minidb list, check rewind/next 6'
);

@keys = (), @vals = (); $db->rewind(':lists', 'k2', 'val =~ /e/');

while ( my ($key, $val) = $db->next ) {
   push @keys, $key;
   push @vals, $val;
}

cmp_array(
   [ @keys ], [ qw/ 0 1 3 4 5 6 7 8 9 / ],
   'shared minidb list, check rewind/next 7'
);
cmp_array(
   [ @vals ], [ qw/ me channel where despair life me hope... there darkness / ],
   'shared minidb list, check rewind/next 8'
);

## iterator, non-parallel iteration

@keys = (), @vals = (); $iter = $db->iterator(':lists');

while ( my ($key, $val) = $iter->() ) {
   push @keys, $key;
   push @vals, $val->[3];
}

cmp_array(
   [ @keys ], [ qw/ k1 k2 / ],
   'shared minidb list, check iterator 1'
);
cmp_array(
   [ @vals ], [ qw/ Where where / ],
   'shared minidb list, check iterator 2'
);

@keys = (), @vals = (); $iter = $db->iterator(':lists', qw/ k1 k2 /);

while ( my ($key, $val) = $iter->() ) {
   push @keys, $key;
   push @vals, $val->[3];
}

cmp_array(
   [ @keys ], [ qw/ k1 k2 / ],
   'shared minidb list, check iterator 3'
);
cmp_array(
   [ @vals ], [ qw/ Where where / ],
   'shared minidb list, check iterator 4'
);

@keys = (), @vals = (); $iter = $db->iterator(':lists', '11 == 20');

while ( my ($key, $val) = $iter->() ) {
   push @keys, $key;
   push @vals, $val->[11];
}

cmp_array(
   [ @keys ], [ qw/ k2 / ],
   'shared minidb list, check iterator 5'
);
cmp_array(
   [ @vals ], [ qw/ 20 / ],
   'shared minidb list, check iterator 6'
);

@keys = (), @vals = (); $iter = $db->iterator(':lists', 'k2', 'val =~ /e/');

while ( my ($key, $val) = $iter->() ) {
   push @keys, $key;
   push @vals, $val;
}

cmp_array(
   [ @keys ], [ qw/ 0 1 3 4 5 6 7 8 9 / ],
   'shared minidb list, check iterator 7'
);
cmp_array(
   [ @vals ], [ qw/ me channel where despair life me hope... there darkness / ],
   'shared minidb list, check iterator 8'
);

## select_aref ( ':lists', 'query string' )

@rows = $db->select_aref(':lists', '1 5 11 :ORDER BY 11 DESC');
is( $rows[1][1][2], 18, 'shared minidb list, check select_aref 1' );

@rows = $db->select_aref(':lists', '1 5 11 :WHERE 11 == 20');
is( @rows, 1, 'shared minidb list, check select_aref 2 count' );
is( $rows[0][1][2], 20, 'shared minidb list, check select_aref 2' );

@rows = $db->select_aref(':lists', '1 5 11');
is( @rows, 2, 'shared minidb list, check select_aref 3 count' );

@rows = $db->select_aref(':lists', ':ORDER BY 11 DESC');
is( @rows, 2, 'shared minidb list, check select_aref 4 count' );

cmp_array(
   $rows[1][1], [ qw/ me channel Your Where despair life me hope... there darkness light... 18 9 3 / ],
   'shared minidb list, check select_aref 4 values'
);

@rows = $db->select_aref(':lists', '11 == 20');
is( @rows, 1, 'shared minidb list, check select_aref 5 count' );

cmp_array(
   $rows[0][1], [ qw/ me channel your where despair life me hope... there darkness light... 20 9 3 / ],
   'shared minidb list, check select_aref 5 values'
);

## select_href ( ':lists', 'query string' )

@rows = $db->select_href(':lists', '1 5 11 :ORDER BY 11 DESC');
is( $rows[1][1]{11}, 18, 'shared minidb list, check select_href 1' );

@rows = $db->select_href(':lists', '1 5 11 :WHERE 11 == 20');
is( @rows, 1, 'shared minidb list, check select_href 2 count' );
is( $rows[0][1]{11}, 20, 'shared minidb list, check select_href 2' );

@rows = $db->select_href(':lists', '1 5 11');
is( @rows, 2, 'shared minidb list, check select_href 3 count' );

@rows = $db->select_href(':lists', ':ORDER BY 11 DESC');
is( @rows, 2, 'shared minidb list, check select_href 4 count' );
is( $rows[1][1]{11}, 18, 'shared minidb list, check select_href 4 value' );

@rows = $db->select_href(':lists', '11 == 20');
is( @rows, 1, 'shared minidb list, check select_href 5 count' );
is( $rows[0][1]{11}, 20, 'shared minidb list, check select_href 5 value' );

## lget

is(
   ref($db->lget('k1')), 'MCE::Shared::Array',
   'shared minidb list, check lget key'
);
is(
   $db->lget('k1', 5), 'life',
   'shared minidb list, check lget field'
);
cmp_array(
   [ $db->lget('k1', 1, 5) ], [ 'channel', 'life' ],
   'shared minidb list, check lget fields'
);

## lexists

is(
   $db->lexists('k1'), 1,
   'shared minidb list, check lexists valid key'
);
is(
   $db->lexists('k1',1), 1,
   'shared minidb list, check lexists valid field'
);
is(
   $db->lexists('k1',1,5), 1,
   'shared minidb list, check lexists valid fields'
);

is(
   $db->lexists('k3'), '',
   'shared minidb list, check lexists invalid key'
);
is(
   $db->lexists('k3',30), '',
   'shared minidb list, check lexists invalid field'
);
is(
   $db->lexists('k3',30,1), '',
   'shared minidb list, check lexists invalid fields'
);

## ldel

is(
   $db->ldel('k1', 6, 10), 2,
   'shared minidb list, check ldel fields'
);
is(
   $db->ldel('k1', 5), 'life',
   'shared minidb list, check ldel field'
);
is(
   ref($db->ldel('k1')), 'MCE::Shared::Array',
   'shared minidb list, check ldel key'
);

## lset

is(
   $db->lset('k2', 14, 'foo', 15, 'bar'), 16,
   'shared minidb list, check lset fields'
);
is(
   $db->lset('k2', 16, 'baz'), 'baz',
   'shared minidb list, check lset field'
);
is(
   $db->lset('k3'), undef,  # no-op without field/value
   'shared minidb list, check lset key, no-op'
);

## lpush/rpush, lpop/rpop

$db->lpush('k1', qw/ a b c d e /);

is(
   $db->lpush('k1', qw/ f /), 6,
   'shared minidb list, check lpush count'
);
cmp_array(
   [ $db->lvals('k1') ], [ qw/ f a b c d e / ],
   'shared minidb list, check lpush values'
);

$db->rpush('k1', qw/ g h i j k /);

is(
   $db->rpush('k1', qw/ l /), 12,
   'shared minidb list, check rpush count'
);
cmp_array(
   [ $db->lvals('k1') ], [ qw/ f a b c d e g h i j k l / ],
   'shared minidb list, check rpush values'
);

is( $db->lpop('k1'), 'f', 'shared minidb list, check lpop value' );
is( $db->rpop('k1'), 'l', 'shared minidb list, check rpop value' );

cmp_array(
   [ $db->lvals('k1') ], [ qw/ a b c d e g h i j k / ],
   'shared minidb list, check values after pop'
);

## lrange

cmp_array(
   [ $db->lrange('k1', 0, 0) ], [ qw/ a / ],
   'shared minidb list, check lrange 1'
);
cmp_array(
   [ $db->lrange('k1', -10, 9) ], [ qw/ a b c d e g h i j k / ],
   'shared minidb list, check lrange 2'
);
cmp_array(
   [ $db->lrange('k1', -100, 100) ], [ qw/ a b c d e g h i j k / ],
   'shared minidb list, check lrange 3'
);
cmp_array(
   [ $db->lrange('k1', 10, 15) ], [ ],
   'shared minidb list, check lrange 4'
);
cmp_array(
   [ $db->lrange('k1', -1, -1) ], [ qw/ k / ],
   'shared minidb list, check lrange 5'
);

## lsplice

cmp_array(
   [ $db->lsplice('k1', 2, 6) ], [ qw/ c d e g h i / ],
   'shared minidb list, check lsplice 1'
);
is(
   $db->lsplice('k1', 1, 2), 'j',
   'shared minidb list, check lsplice 2'
);

$db->lsplice('k1', 1, 4, qw/ d e g h /);

cmp_array(
   [ $db->lvals('k1') ], [ qw/ a d e g h / ],
   'shared minidb list, check lsplice 3'
);
cmp_array(
   [ $db->lsplice('k1', -2, 2) ], [ qw/ g h / ],
   'shared minidb list, check lsplice 4'
);
cmp_array(
   [ $db->lvals('k1') ], [ qw/ a d e / ],
   'shared minidb list, check lsplice 5'
);

## lsort 2 arguments

cmp_array(
   [ $db->lsort('k1', 'BY val DESC ALPHA') ], [ qw/ e d a / ],
   'shared minidb list, check lsort (list-context) key, by val'
);
cmp_array(
   [ $db->lvals('k1') ], [ qw/ a d e / ],
   'shared minidb list, check lsort (list-context) key'
);

$db->rpush('k1', qw/ 10 1 2 /);
$db->lsort('k1', 'BY val ALPHA');

cmp_array(
   [ $db->lvals('k1') ], [ qw/ 1 10 2 a d e / ],
   'shared minidb list, check lsort (in-place) key, by val'
);

$db->lsort('k1', 'BY val');

cmp_array(
   [ $db->lvals('k1') ], [ qw/ a d e 1 2 10 / ],
   'shared minidb list, check lsort (in-place) key'
);

## lsort 1 argument

$db->lclear;

$db->lset('k1', qw/ 0 bb 1 10 2 aa /);
$db->lset('k9', qw/ 0 cc 1 40 2 bb /);
$db->lset('k5', qw/ 0 aa 1 20 2 hh /);
$db->lset('k3', qw/ 0 dd 1 30 2 ee /);
$db->lset( '2', qw/ 0 ff 1 80 2 cc /);
$db->lset( '1', qw/ 0 hh 1 70 2 ff /);
$db->lset('10', qw/ 0 ee 1 90 2 dd /);

cmp_array(
   [ $db->lsort('BY key DESC ALPHA') ], [ qw/ k9 k5 k3 k1 2 10 1 / ],
   'shared minidb list, check lsort (list-context) by key 1'
);
cmp_array(
   [ $db->lsort('BY key DESC') ], [ qw/ 10 2 1 k1 k9 k5 k3 / ],
   'shared minidb list, check lsort (list-context) by key 2'
);
cmp_array(
   [ $db->lsort('BY key ALPHA') ], [ qw/ 1 10 2 k1 k3 k5 k9 / ],
   'shared minidb list, check lsort (list-context) by key 3'
);
cmp_array(
   [ $db->lsort('BY key') ], [ qw/ k1 k9 k5 k3 1 2 10 / ],
   'shared minidb list, check lsort (list-context) by key 4'
);

cmp_array(
   [ $db->lsort('BY 0 DESC ALPHA') ], [ qw/ 1 2 10 k3 k9 k1 k5 / ],
   'shared minidb list, check lsort (list-context) by field 1'
);
cmp_array(
   [ $db->lsort('BY 1 DESC') ], [ qw/ 10 2 1 k9 k3 k5 k1 / ],
   'shared minidb list, check lsort (list-context) by field 2'
);
cmp_array(
   [ $db->lsort('BY 0 ALPHA') ], [ qw/ k5 k1 k9 k3 10 2 1 / ],
   'shared minidb list, check lsort (list-context) by field 3'
);
cmp_array(
   [ $db->lsort('BY 1') ], [ qw/ k1 k5 k3 k9 1 2 10 / ],
   'shared minidb list, check lsort (list-context) by field 4'
);

cmp_array(
   [ $db->lkeys ], [ qw/ k1 k9 k5 k3 2 1 10 / ],
   'shared minidb list, check lsort (list-context)'
);

$db->lsort('BY key DESC ALPHA');

cmp_array(
   [ $db->lkeys() ], [ qw/ k9 k5 k3 k1 2 10 1 / ],
   'shared minidb list, check lsort (in-place) by key 1'
);

$db->lsort('BY key DESC');

cmp_array(
   [ $db->lkeys() ], [ qw/ 10 2 1 k9 k5 k3 k1 / ],
   'shared minidb list, check lsort (in-place) by key 2'
);

$db->lsort('BY key ALPHA');

cmp_array(
   [ $db->lkeys() ], [ qw/ 1 10 2 k1 k3 k5 k9 / ],
   'shared minidb list, check lsort (in-place) by key 3'
);

$db->lsort('BY key');

cmp_array(
   [ $db->lkeys() ], [ qw/ k1 k3 k5 k9 1 2 10 / ],
   'shared minidb list, check lsort (in-place) by key 4'
);

$db->lsort('BY 0 DESC ALPHA');

cmp_array(
   [ $db->lkeys() ], [ qw/ 1 2 10 k3 k9 k1 k5 / ],
   'shared minidb list, check lsort (in-place) by field 1'
);

$db->lsort('BY 1 DESC');

cmp_array(
   [ $db->lkeys() ], [ qw/ 10 2 1 k9 k3 k5 k1 / ],
   'shared minidb list, check lsort (in-place) by field 2'
);

$db->lsort('BY 0 ALPHA');

cmp_array(
   [ $db->lkeys() ], [ qw/ k5 k1 k9 k3 10 2 1 / ],
   'shared minidb list, check lsort (in-place) by field 3'
);

$db->lsort('BY 1');

cmp_array(
   [ $db->lkeys() ], [ qw/ k1 k5 k3 k9 1 2 10 / ],
   'shared minidb list, check lsort (in-place) by field 4'
);

# sugar API

$db->lclear;
$db->lset('k1', 0, 77);

is ( $db->lincr('k1', 0), 78, 'shared minidb list, check lincr' );
is ( $db->ldecr('k1', 0), 77, 'shared minidb list, check ldecr' );
is ( $db->lincrby('k1', 0, 4), 81, 'shared minidb list, check lincrby' );
is ( $db->ldecrby('k1', 0, 4), 77, 'shared minidb list, check ldecrby' );
is ( $db->lgetincr('k1', 0), 77, 'shared minidb list, check lgetincr' );
is ( $db->lget('k1', 0), 78, 'shared minidb list, check value after lgetincr' );
is ( $db->lgetdecr('k1', 0), 78, 'shared minidb list, check lgetdecr' );
is ( $db->lget('k1', 0), 77, 'shared minidb list, check value after lgetdecr' );
is ( $db->lappend('k1', 0, 'ba'), 4, 'shared minidb list, check lappend' );
is ( $db->lget('k1', 0), '77ba', 'shared minidb list, check value after lappend' );
is ( $db->lgetset('k1', 0, '77bc'), '77ba', 'shared minidb list, check lgetset' );
is ( $db->lget('k1', 0), '77bc', 'shared minidb list, check value after lgetset' );


