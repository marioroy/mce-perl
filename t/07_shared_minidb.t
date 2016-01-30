#!/usr/bin/env perl

use strict;
use warnings;

use Test::More tests => 44;
use MCE::Shared;

my (@keys, @vals);

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
## { k2 } => {
##   ...
## },
##
##############################################################################

$db->hset( 'k2', qw(
   Make me a channel of Your peace...
   Where there's despair in life let me bring hope...
   Where there is darkness only light...
   16 18 7 9 2 3
));

is( $db->hlen('k2'),    14, 'shared minidb hash, check len k2' );
is( $db->hlen('k2','a'), 7, 'shared minidb hash, check len k2->{ field }' );
is( $db->hlen(),         1, 'shared minidb hash, check len' );

$db->hclear('k2');
is( $db->hlen('k2'),     0, 'shared minidb hash, check clear k2' );

$db->hclear();
is( $db->hlen(),         0, 'shared minidb hash, check clear' );

$db->hset( 'k1', qw(
   Make me a channel of Your peace...
   Where there's despair in life let me bring hope...
   Where there is darkness only light...
   baz 18 7 9 2 3
));
$db->hset( 'k2', qw(
   make me a channel of your peace...
   where there's despair in life let me bring hope...
   where there is darkness only light...
   baz 20 7 9 2 3
));

is( $db->hkeys(),  2, 'shared minidb hash, check keys count' );
is( $db->hvals(),  2, 'shared minidb hash, check vals count' );
is( $db->hpairs(), 4, 'shared minidb hash, check pairs count' );

is( $db->hkeys('k2'),  14, 'shared minidb hash, check keys("k2") count' );
is( $db->hvals('k2'),  14, 'shared minidb hash, check vals("k2") count' );
is( $db->hpairs('k2'), 28, 'shared minidb hash, check pairs("k2") count' );

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
   $db->hvals('peace... =~ /where/i'), 2,
   'shared minidb hash, check hkeys("query3")'
);
is(
   $db->hpairs('peace... =~ /where/i'), 4,
   'shared minidb hash, check hkeys("query4")'
);

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

@keys = (), @vals = (); $db->rewind(':hashes', 'baz == 20');

while ( my ($key, $val) = $db->next ) {
   push @keys, $key;
   push @vals, $val->{'baz'};
}

cmp_array(
   [ @keys ], [ qw/ k2 / ],
   'shared minidb hash, check rewind/next 3'
);
cmp_array(
   [ @vals ], [ qw/ 20 / ],
   'shared minidb hash, check rewind/next 4'
);

@keys = (), @vals = (); $db->rewind(':hashes', 'k2', 'val =~ /e/');

while ( my ($key, $val) = $db->next ) {
   push @keys, $key;
   push @vals, $val;
}

cmp_array(
   [ sort @keys ], [ sort qw/ make a peace... there's in let bring where is / ],
   'shared minidb hash, check rewind/next 5'
);
cmp_array(
   [ sort @vals ], [ sort qw/ me channel where despair life me hope... there darkness / ],
   'shared minidb hash, check rewind/next 6'
);

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
## { k2 } => [
##   ...
## ],
##
##############################################################################

$db->lset( 'k2', qw(
   0 me 1 channel 2 Your 3 Where 4 despair 5 life 6 me 7 hope...
   8 there 9 darkness 10 light... 11 18 12 9 13 3
));

is( $db->llen('k2'),    14, 'shared minidb list, check len k2' );
is( $db->llen('k2','1'), 7, 'shared minidb list, check len k2->[ index ]' );
is( $db->llen(),         1, 'shared minidb list, check len' );

$db->lclear('k2');
is( $db->llen('k2'),     0, 'shared minidb list, check clear k2' );

$db->lclear();
is( $db->llen(),         0, 'shared minidb list, check clear' );

$db->lset( 'k1', qw(
   0 me 1 channel 2 Your 3 Where 4 despair 5 life 6 me 7 hope...
   8 there 9 darkness 10 light... 11 18 12 9 13 3
));
$db->lset( 'k2', qw(
   0 me 1 channel 2 your 3 where 4 despair 5 life 6 me 7 hope...
   8 there 9 darkness 10 light... 11 20 12 9 13 3
));

is( $db->lkeys(),  2, 'shared minidb list, check keys count' );
is( $db->lvals(),  2, 'shared minidb list, check vals count' );
is( $db->lpairs(), 4, 'shared minidb list, check pairs count' );

is( $db->lkeys('k2'),  14, 'shared minidb list, check keys("k2") count' );
is( $db->lvals('k2'),  14, 'shared minidb list, check vals("k2") count' );
is( $db->lpairs('k2'), 28, 'shared minidb list, check pairs("k2") count' );

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
   $db->lvals('3 =~ /where/i'), 2,
   'shared minidb list, check lvals("query3")'
);
is(
   $db->lpairs('3 =~ /where/i'), 4,
   'shared minidb list, check lpairs("query4")'
);

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

@keys = (), @vals = (); $db->rewind(':lists', '11 == 20');

while ( my ($key, $val) = $db->next ) {
   push @keys, $key;
   push @vals, $val->[11];
}

cmp_array(
   [ @keys ], [ qw/ k2 / ],
   'shared minidb list, check rewind/next 3'
);
cmp_array(
   [ @vals ], [ qw/ 20 / ],
   'shared minidb list, check rewind/next 4'
);

@keys = (), @vals = (); $db->rewind(':lists', 'k2', 'val =~ /e/');

while ( my ($key, $val) = $db->next ) {
   push @keys, $key;
   push @vals, $val;
}

cmp_array(
   [ @keys ], [ qw/ 0 1 3 4 5 6 7 8 9 / ],
   'shared minidb list, check rewind/next 5'
);
cmp_array(
   [ @vals ], [ qw/ me channel where despair life me hope... there darkness / ],
   'shared minidb list, check rewind/next 6'
);

