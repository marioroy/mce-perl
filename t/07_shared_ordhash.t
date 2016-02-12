#!/usr/bin/env perl

use strict;
use warnings;

use Test::More tests => 163;
use MCE::Flow max_workers => 1;
use MCE::Shared;

my $h1 = MCE::Shared->ordhash( k1 => 10, k2 => '', k3 => '' );

tie my $keys, 'MCE::Shared';
tie my $e1,   'MCE::Shared';
tie my $e2,   'MCE::Shared';
tie my $d1,   'MCE::Shared';
tie my $s1,   'MCE::Shared';

my $h5 = MCE::Shared->ordhash( n => 0 );

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
   $h1->{k1}  +=  5;
   $h1->{k2}  .= '';
   $h1->{k3}  .= 'foobar';
   $keys       = join(' ', $h1->keys);
   $h5->{n}    = 20;
});

MCE::Flow::finish;

is( $h1->{k1}, 15, 'shared ordhash, check fetch, store' );
is( $h1->{k2}, '', 'shared ordhash, check blank value' );
is( $h1->{k3}, 'foobar', 'shared ordhash, check concatenation' );
is( $keys, 'k1 k2 k3', 'shared ordhash, check firstkey, nextkey' );
is( $h5->{n}, 20, 'shared ordhash, check value' );

MCE::Flow::run( sub {
   $e1 = exists $h1->{'k2'} ? 1 : 0;
   $d1 = delete $h1->{'k2'};
   $e2 = exists $h1->{'k2'} ? 1 : 0;
   %{$h1} = (); $s1 = keys %{$h1};
   $h1->{ret} = [ 'wind', 'air' ];
});

MCE::Flow::finish;

is( $e1,  1, 'shared ordhash, check exists before delete' );
is( $d1, '', 'shared ordhash, check delete' );
is( $e2,  0, 'shared ordhash, check exists after delete' );
is( $s1,  0, 'shared ordhash, check clear' );
is( $h1->{ret}->[1], 'air', 'shared ordhash, check auto freeze/thaw' );

## --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- ---

## Somewhere over the rainbow
##    Way up high / And the dreams that you dreamed of / ...

$h1->clear;

$h1->push( s => 'where', o => 'the', r => 'way', u => 'high' );

is( join('', $h1->keys), 'soru', 'shared ordhash, check keys' );
is( join('', $h1->vals), 'wherethewayhigh', 'shared ordhash, check values' );

$h1->push( a => 'the', d => 'that' );

is( join('', $h1->keys), 'soruad', 'shared ordhash, check push' );

$h1->unshift( 'lyrics' => 'to' );

is( join('', $h1->keys), 'lyricssoruad', 'shared ordhash, check unshift' );

$h1->del( $_ ) for qw( lyrics d r );

is( join('', $h1->keys), 'soua', 'shared ordhash, check delete' );
is( join('', $h1->pop), 'athe', 'shared ordhash, check pop' );
is( join('', $h1->shift), 'swhere', 'shared ordhash, check shift' );

$h1->splice( 1, 0, 'you' => 'dreamed' );

is( join('', $h1->pairs), 'otheyoudreameduhigh', 'shared ordhash, check splice' );

## --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- ---

## {
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
## }

$h5->clear();

$h5->mset( qw(
   Make me a channel of Your peace...
   Where there's despair in life let me bring hope...
   Where there is darkness only light...
   16 18 7 9 2 3
));

## MCE::Shared->ordhash is ordered. Therefore, sorting is not required.

## find keys

cmp_array(
   [ $h5->pairs('key =~ /\.\.\./') ], [ qw/ peace... Where / ],
   'shared ordhash, check find keys =~ match (pairs)'
);
cmp_array(
   [ $h5->keys('key =~ /\.\.\./') ], [ qw/ peace... / ],
   'shared ordhash, check find keys =~ match (keys)'
);
cmp_array(
   [ $h5->vals('key =~ /\.\.\./') ], [ qw/ Where / ],
   'shared ordhash, check find keys =~ match (vals)'
);

cmp_array(
   [ $h5->pairs('key !~ /^[a-z]/') ],
   [ qw/ Make me Where there 16 18 7 9 2 3 / ],
   'shared ordhash, check find keys !~ match (pairs)'
);
cmp_array(
   [ $h5->keys('key !~ /^[a-z]/') ],
   [ qw/ Make Where 16 7 2 / ],
   'shared ordhash, check find keys !~ match (keys)'
);
cmp_array(
   [ $h5->vals('key !~ /^[a-z]/') ],
   [ qw/ me there 18 9 3 / ],
   'shared ordhash, check find keys !~ match (vals)'
);

cmp_array(
   [ $h5->pairs('key !~ /^[a-z]/ :AND val =~ /^\d$/') ],
   [ qw/ 7 9 2 3 / ],
   'shared ordhash, check find keys && match (pairs)'
);
cmp_array(
   [ $h5->keys('key !~ /^[a-z]/ :AND val =~ /^\d$/') ],
   [ qw/ 7 2 / ],
   'shared ordhash, check find keys && match (keys)'
);
cmp_array(
   [ $h5->vals('key !~ /^[a-z]/ :AND val =~ /^\d$/') ],
   [ qw/ 9 3 / ],
   'shared ordhash, check find keys && match (vals)'
);

cmp_array(
   [ $h5->pairs('key eq a') ], [ qw/ a channel / ],
   'shared ordhash, check find keys eq match (pairs)'
);
cmp_array(
   [ $h5->keys('key eq a') ], [ qw/ a / ],
   'shared ordhash, check find keys eq match (keys)'
);
cmp_array(
   [ $h5->vals('key eq a') ], [ qw/ channel / ],
   'shared ordhash, check find keys eq match (vals)'
);

is( $h5->pairs('key ne there\'s'), 26, 'shared ordhash, check find keys ne match (pairs)' );
is( $h5->keys('key ne there\'s'), 13, 'shared ordhash, check find keys ne match (keys)' );
is( $h5->vals('key ne there\'s'), 13, 'shared ordhash, check find keys ne match (vals)' );

is( $h5->pairs('key lt bring'),    12, 'shared ordhash, check find keys lt match (pairs)' );
is( $h5->keys('key lt bring'),     6, 'shared ordhash, check find keys lt match (keys)' );
is( $h5->vals('key lt bring'),     6, 'shared ordhash, check find keys lt match (vals)' );

is( $h5->pairs('key le bring'),    14, 'shared ordhash, check find keys le match (pairs)' );
is( $h5->keys('key le bring'),     7, 'shared ordhash, check find keys le match (keys)' );
is( $h5->vals('key le bring'),     7, 'shared ordhash, check find keys le match (vals)' );

is( $h5->pairs('key gt bring'),    14, 'shared ordhash, check find keys gt match (pairs)' );
is( $h5->keys('key gt bring'),     7, 'shared ordhash, check find keys gt match (keys)' );
is( $h5->vals('key gt bring'),     7, 'shared ordhash, check find keys gt match (vals)' );

is( $h5->pairs('key ge bring'),    16, 'shared ordhash, check find keys ge match (pairs)' );
is( $h5->keys('key ge bring'),     8, 'shared ordhash, check find keys ge match (keys)' );
is( $h5->vals('key ge bring'),     8, 'shared ordhash, check find keys ge match (vals)' );

cmp_array(
   [ $h5->pairs('key == 16') ], [ qw/ 16 18 / ],
   'shared ordhash, check find keys == match (pairs)'
);
cmp_array(
   [ $h5->keys('key == 16') ], [ qw/ 16 / ],
   'shared ordhash, check find keys == match (keys)'
);
cmp_array(
   [ $h5->vals('key == 16') ], [ qw/ 18 / ],
   'shared ordhash, check find keys == match (vals)'
);

is( $h5->pairs('key != 16'), 4, 'shared ordhash, check find keys != match (pairs)' );
is( $h5->keys('key != 16'), 2, 'shared ordhash, check find keys != match (keys)' );
is( $h5->vals('key != 16'), 2, 'shared ordhash, check find keys != match (vals)' );

is( $h5->pairs('key <   7'), 2, 'shared ordhash, check find keys <  match (pairs)' );
is( $h5->keys('key <   7'), 1, 'shared ordhash, check find keys <  match (keys)' );
is( $h5->vals('key <   7'), 1, 'shared ordhash, check find keys <  match (vals)' );

is( $h5->pairs('key <=  7'), 4, 'shared ordhash, check find keys <= match (pairs)' );
is( $h5->keys('key <=  7'), 2, 'shared ordhash, check find keys <= match (keys)' );
is( $h5->vals('key <=  7'), 2, 'shared ordhash, check find keys <= match (vals)' );

is( $h5->pairs('key >   2'), 4, 'shared ordhash, check find keys >  match (pairs)' );
is( $h5->keys('key >   2'), 2, 'shared ordhash, check find keys >  match (keys)' );
is( $h5->vals('key >   2'), 2, 'shared ordhash, check find keys >  match (vals)' );

is( $h5->pairs('key >=  2'), 6, 'shared ordhash, check find keys >= match (pairs)' );
is( $h5->keys('key >=  2'), 3, 'shared ordhash, check find keys >= match (keys)' );
is( $h5->vals('key >=  2'), 3, 'shared ordhash, check find keys >= match (vals)' );

## find vals

cmp_array(
   [ $h5->pairs('val =~ /\.\.\./') ],
   [ qw/ bring hope... only light... / ],
   'shared ordhash, check find vals =~ match (pairs)'
);
cmp_array(
   [ $h5->keys('val =~ /\.\.\./') ],
   [ qw/ bring only / ],
   'shared ordhash, check find vals =~ match (keys)'
);
cmp_array(
   [ $h5->vals('val =~ /\.\.\./') ],
   [ qw/ hope... light... / ],
   'shared ordhash, check find vals =~ match (vals)'
);

cmp_array(
   [ $h5->pairs('val !~ /^[a-z]/') ],
   [ qw/ of Your peace... Where 16 18 7 9 2 3 / ],
   'shared ordhash, check find vals !~ match (pairs)'
);
cmp_array(
   [ $h5->keys('val !~ /^[a-z]/') ],
   [ qw/ of peace... 16 7 2 / ],
   'shared ordhash, check find vals !~ match (keys)'
);
cmp_array(
   [ $h5->vals('val !~ /^[a-z]/') ],
   [ qw/ Your Where 18 9 3 / ],
   'shared ordhash, check find vals !~ match (vals)'
);

cmp_array(
   [ $h5->pairs('val =~ /\d/ :OR val eq Where') ],
   [ qw/ peace... Where 16 18 7 9 2 3 / ],
   'shared ordhash, check find vals || match (pairs)'
);
cmp_array(
   [ $h5->keys('val =~ /\d/ :OR val eq Where') ],
   [ qw/ peace... 16 7 2 / ],
   'shared ordhash, check find vals || match (keys)'
);
cmp_array(
   [ $h5->vals('val =~ /\d/ :OR val eq Where') ],
   [ qw/ Where 18 9 3 / ],
   'shared ordhash, check find vals || match (vals)'
);

cmp_array(
   [ $h5->pairs('val eq life') ], [ qw/ in life / ],
   'shared ordhash, check find vals eq match (pairs)'
);
cmp_array(
   [ $h5->keys('val eq life') ], [ qw/ in / ],
   'shared ordhash, check find vals eq match (keys)'
);
cmp_array(
   [ $h5->vals('val eq life') ], [ qw/ life / ],
   'shared ordhash, check find vals eq match (vals)'
);

is( $h5->pairs('val ne despair'), 26, 'shared ordhash, check find vals ne match (pairs)' );
is( $h5->keys('val ne despair'), 13, 'shared ordhash, check find vals ne match (keys)' );
is( $h5->vals('val ne despair'), 13, 'shared ordhash, check find vals ne match (vals)' );

is( $h5->pairs('val lt hope...'), 16, 'shared ordhash, check find vals lt match (pairs)' );
is( $h5->keys('val lt hope...'),  8, 'shared ordhash, check find vals lt match (keys)' );
is( $h5->vals('val lt hope...'),  8, 'shared ordhash, check find vals lt match (vals)' );

is( $h5->pairs('val le hope...'), 18, 'shared ordhash, check find vals le match (pairs)' );
is( $h5->keys('val le hope...'),  9, 'shared ordhash, check find vals le match (keys)' );
is( $h5->vals('val le hope...'),  9, 'shared ordhash, check find vals le match (vals)' );

is( $h5->pairs('val gt hope...'), 10, 'shared ordhash, check find vals gt match (pairs)' );
is( $h5->keys('val gt hope...'),  5, 'shared ordhash, check find vals gt match (keys)' );
is( $h5->vals('val gt hope...'),  5, 'shared ordhash, check find vals gt match (vals)' );

is( $h5->pairs('val ge hope...'), 12, 'shared ordhash, check find vals ge match (pairs)' );
is( $h5->keys('val ge hope...'),  6, 'shared ordhash, check find vals ge match (keys)' );
is( $h5->vals('val ge hope...'),  6, 'shared ordhash, check find vals ge match (vals)' );

cmp_array(
   [ $h5->pairs('val == 9') ], [ qw/ 7 9 / ],
   'shared ordhash, check find vals == match (pairs)'
);
cmp_array(
   [ $h5->keys('val == 9') ], [ qw/ 7 / ],
   'shared ordhash, check find vals == match (keys)'
);
cmp_array(
   [ $h5->vals('val == 9') ], [ qw/ 9 / ],
   'shared ordhash, check find vals == match (vals)'
);

is( $h5->pairs('val !=  9'), 4, 'shared ordhash, check find vals != match (pairs)' );
is( $h5->keys('val !=  9'), 2, 'shared ordhash, check find vals != match (keys)' );
is( $h5->vals('val !=  9'), 2, 'shared ordhash, check find vals != match (vals)' );

is( $h5->pairs('val <   9'), 2, 'shared ordhash, check find vals <  match (pairs)' );
is( $h5->keys('val <   9'), 1, 'shared ordhash, check find vals <  match (keys)' );
is( $h5->vals('val <   9'), 1, 'shared ordhash, check find vals <  match (vals)' );

is( $h5->pairs('val <=  9'), 4, 'shared ordhash, check find vals <= match (pairs)' );
is( $h5->keys('val <=  9'), 2, 'shared ordhash, check find vals <= match (keys)' );
is( $h5->vals('val <=  9'), 2, 'shared ordhash, check find vals <= match (vals)' );

is( $h5->pairs('val >  18'), 0, 'shared ordhash, check find vals >  match (pairs)' );
is( $h5->keys('val >  18'), 0, 'shared ordhash, check find vals >  match (keys)' );
is( $h5->vals('val >  18'), 0, 'shared ordhash, check find vals >  match (vals)' );

is( $h5->pairs('val >= 18'), 2, 'shared ordhash, check find vals >= match (pairs)' );
is( $h5->keys('val >= 18'), 1, 'shared ordhash, check find vals >= match (keys)' );
is( $h5->vals('val >= 18'), 1, 'shared ordhash, check find vals >= match (vals)' );

## find undef

$h5->clear();

$h5->mset( qw/ spring summer fall winter / );
$h5->set( key => undef );

cmp_array(
   [ $h5->pairs('val eq undef') ], [ 'key', undef ],
   'shared ordhash, check find vals eq undef (pairs)'
);
cmp_array(
   [ $h5->keys('val eq undef') ], [ 'key' ],
   'shared ordhash, check find vals eq undef (keys)'
);
cmp_array(
   [ $h5->vals('val eq undef') ], [ undef ],
   'shared ordhash, check find vals eq undef (vals)'
);

cmp_array(
   [ $h5->pairs('val ne undef') ], [ qw/ spring summer fall winter / ],
   'shared ordhash, check find vals ne undef (pairs)'
);
cmp_array(
   [ $h5->keys('val ne undef') ], [ qw/ spring fall / ],
   'shared ordhash, check find vals ne undef (keys)'
);
cmp_array(
   [ $h5->vals('val ne undef') ], [ qw/ summer winter / ],
   'shared ordhash, check find vals ne undef (vals)'
);

## --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- ---

$h5->clear(); $h5->mset( 1 => 1, 6 => 3, 2 => 6, 5 => 5, 4 => 4, 10 => 10 );

## sorted keys: by val

cmp_array(
   [ $h5->sort("by val") ], [ qw/ 1 6 4 5 2 10 / ],
   'shared ordhash, check sorted keys by val'
);
cmp_array(
   [ $h5->sort("by val desc") ], [ qw/ 10 2 5 4 6 1 / ],
   'shared ordhash, check sorted keys by val desc'
);
cmp_array(
   [ $h5->sort("by val alpha") ], [ qw/ 1 10 6 4 5 2 / ],
   'shared ordhash, check sorted keys by val alpha'
);
cmp_array(
   [ $h5->sort("by val alpha desc") ], [ qw/ 2 5 4 6 10 1 / ],
   'shared ordhash, check sorted keys by val alpha desc'
);

## sorted keys: by key

cmp_array(
   [ $h5->sort("by key") ], [ qw/ 1 2 4 5 6 10 / ],
   'shared ordhash, check sorted keys by key'
);
cmp_array(
   [ $h5->sort("by key desc") ], [ qw/ 10 6 5 4 2 1 / ],
   'shared ordhash, check sorted keys by key desc'
);
cmp_array(
   [ $h5->sort("by key alpha") ], [ qw/ 1 10 2 4 5 6 / ],
   'shared ordhash, check sorted keys by key alpha'
);
cmp_array(
   [ $h5->sort("by key alpha desc") ], [ qw/ 6 5 4 2 10 1 / ],
   'shared ordhash, check sorted keys by key alpha desc'
);

## sort keys in-place: by val

$h5->sort("by val"), cmp_array(
   [ $h5->keys() ], [ qw/ 1 6 4 5 2 10 / ],
   'shared ordhash, check in-place sort by val'
);
$h5->sort("by val desc"), cmp_array(
   [ $h5->keys() ], [ qw/ 10 2 5 4 6 1 / ],
   'shared ordhash, check in-place sort by val desc'
);
$h5->sort("by val alpha"), cmp_array(
   [ $h5->keys() ], [ qw/ 1 10 6 4 5 2 / ],
   'shared ordhash, check in-place sort by val alpha'
);
$h5->sort("by val alpha desc"), cmp_array(
   [ $h5->keys() ], [ qw/ 2 5 4 6 10 1 / ],
   'shared ordhash, check in-place sort by val alpha desc'
);

## sort keys in-place: by key

$h5->sort("by key"), cmp_array(
   [ $h5->keys() ], [ qw/ 1 2 4 5 6 10 / ],
   'shared ordhash, check in-place sort by key'
);
$h5->sort("by key desc"), cmp_array(
   [ $h5->keys() ], [ qw/ 10 6 5 4 2 1 / ],
   'shared ordhash, check in-place sort by key desc'
);
$h5->sort("by key alpha"), cmp_array(
   [ $h5->keys() ], [ qw/ 1 10 2 4 5 6 / ],
   'shared ordhash, check in-place sort by key alpha'
);
$h5->sort("by key alpha desc"), cmp_array(
   [ $h5->keys() ], [ qw/ 6 5 4 2 10 1 / ],
   'shared ordhash, check in-place sort by key alpha desc'
);

## --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- ---

## MCE::Shared->ordhash is ordered. Therefore, sorting is not required.

$h5->clear(); $h5->mset( 0, 'over', 1, 'the', 2, 'rainbow', 3, 77 );

cmp_array(
   [ $h5->pairs() ], [ qw/ 0 over 1 the 2 rainbow 3 77 / ],
   'shared ordhash, check mset'
);
cmp_array(
   [ $h5->mget(0, 2) ], [ qw/ over rainbow / ],
   'shared ordhash, check mget'
);
cmp_array(
   [ $h5->keys() ], [ qw/ 0 1 2 3 / ],
   'shared ordhash, check keys'
);
cmp_array(
   [ $h5->vals() ], [ qw/ over the rainbow 77 / ],
   'shared ordhash, check values'
);
cmp_array(
   [ $h5->pairs() ], [ qw/ 0 over 1 the 2 rainbow 3 77 / ],
   'shared ordhash, check pairs'
);

is( $h5->len(), 4, 'shared ordhash, check length' );
is( $h5->len(2), 7, 'shared ordhash, check length( key )' );
is( $h5->incr(3), 78, 'shared ordhash, check incr' );
is( $h5->decr(3), 77, 'shared ordhash, check decr' );
is( $h5->incrby(3, 4), 81, 'shared ordhash, check incrby' );
is( $h5->decrby(3, 4), 77, 'shared ordhash, check decrby' );
is( $h5->getincr(3), 77, 'shared ordhash, check getincr' );
is( $h5->get(3), 78, 'shared ordhash, check value after getincr' );
is( $h5->getdecr(3), 78, 'shared ordhash, check getdecr' );
is( $h5->get(3), 77, 'shared ordhash, check value after getdecr' );
is( $h5->append(3, 'ba'), 4, 'shared ordhash, check append' );
is( $h5->get(3), '77ba', 'shared ordhash, check value after append' );
is( $h5->getset('3', '77bc'), '77ba', 'shared ordhash, check getset' );
is( $h5->get(3), '77bc', 'shared ordhash, check value after getset' );

my $h6 = $h5->clone();
my $h7 = $h5->clone(2, 3);
my $h8 = $h5->flush();

is( ref($h7), 'MCE::Shared::Ordhash', 'shared ordhash, check ref' );

cmp_array(
   [ $h6->pairs() ], [ qw/ 0 over 1 the 2 rainbow 3 77bc / ],
   'shared ordhash, check clone'
);
cmp_array(
   [ $h7->pairs() ], [ qw/ 2 rainbow 3 77bc / ],
   'shared ordhash, check clone( keys )'
);
cmp_array(
   [ $h8->pairs() ], [ qw/ 0 over 1 the 2 rainbow 3 77bc / ],
   'shared ordhash, check flush'
);

is( $h5->len(), 0, 'shared ordhash, check emptied' );

my $iter  = $h7->iterator();
my $count = 0;
my @check;

while ( my ($key, $val) = $iter->() ) {
   push @check, $key, $val;
   $count++;
}

$iter = $h7->iterator();

while ( my $val = $iter->() ) {
   push @check, $val;
   $count++;
}

is( $count, 4, 'shared ordhash, check iterator count' );

cmp_array(
   [ @check ], [ qw/ 2 rainbow 3 77bc rainbow 77bc / ],
   'shared ordhash, check iterator results'
);

## --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- ---

my @list;

$h5->clear(); $h5->mset( 0, 'over', 1, 'the', 2, 'rainbow', 3, 77 );

while ( my $val = $h5->next ) { push @list, $val; }

cmp_array(
   [ @list ], [ qw/ over the rainbow 77 / ],
   'shared ordhash, check next'
);

@list = (); $h5->rewind('val =~ /[a-z]/');

while ( my ($key, $val) = $h5->next ) { push @list, $key, $val; }

cmp_array(
   [ @list ], [ qw/ 0 over 1 the 2 rainbow / ],
   'shared ordhash, check rewind 1'
);

@list = (); $h5->rewind('key =~ /\d/');

while ( my $val = $h5->next ) { push @list, $val; }

cmp_array(
   [ @list ], [ qw/ over the rainbow 77 / ],
   'shared ordhash, check rewind 2'
);

@list = (); $h5->rewind(qw/ 1 2 /);

while ( my $val = $h5->next ) { push @list, $val; }

cmp_array(
   [ sort @list ], [ sort qw/ the rainbow / ],
   'shared ordhash, check rewind 3'
);

is( $h5->mexists(qw/ 0 2 3 /),  1, 'shared ordhash, check mexists 1' );
is( $h5->mexists(qw/ 0 8 3 /), '', 'shared ordhash, check mexists 2' );

is( $h5->mdel(qw/ 3 2 1 0 /), 4, 'shared ordhash, check mdel' );

