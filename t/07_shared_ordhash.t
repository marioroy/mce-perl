#!/usr/bin/env perl

use strict;
use warnings;

use Test::More tests => 80;
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
is( join('', $h1->values), 'wherethewayhigh', 'shared ordhash, check values' );

$h1->push( a => 'the', d => 'that' );

is( join('', $h1->keys), 'soruad', 'shared ordhash, check push' );

$h1->unshift( 'lyrics' => 'to' );

is( join('', $h1->keys), 'lyricssoruad', 'shared ordhash, check unshift' );

$h1->delete( $_ ) for qw( lyrics d r );

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

## MCE::Shared->ordhash is ordered. Therefore, sorting not required.

## find keys

cmp_array(
   [ $h5->find('key =~ /\.\.\./') ], [ qw/ peace... Where / ],
   'shared ordhash, check find keys =~ match'
);
cmp_array(
   [ $h5->find('key !~ /^[a-z]/') ],
   [ qw/ Make me Where there 16 18 7 9 2 3 / ],
   'shared ordhash, check find keys !~ match'
);
cmp_array(
   [ $h5->find('key eq a') ], [ qw/ a channel / ],
   'shared ordhash, check find keys eq match'
);

is( $h5->find('key ne there\'s'), 26, 'shared ordhash, check find keys ne match' );
is( $h5->find('key lt bring'),    12, 'shared ordhash, check find keys lt match' );
is( $h5->find('key le bring'),    14, 'shared ordhash, check find keys le match' );
is( $h5->find('key gt bring'),    14, 'shared ordhash, check find keys gt match' );
is( $h5->find('key ge bring'),    16, 'shared ordhash, check find keys ge match' );

cmp_array(
   [ $h5->find('key == 16') ], [ qw/ 16 18 / ],
   'shared ordhash, check find keys == match'
);

is( $h5->find('key != 16'), 4, 'shared ordhash, check find keys != match' );
is( $h5->find('key <   7'), 2, 'shared ordhash, check find keys <  match' );
is( $h5->find('key <=  7'), 4, 'shared ordhash, check find keys <= match' );
is( $h5->find('key >   2'), 4, 'shared ordhash, check find keys >  match' );
is( $h5->find('key >=  2'), 6, 'shared ordhash, check find keys >= match' );

## find vals

cmp_array(
   [ $h5->find('val =~ /\.\.\./') ],
   [ qw/ bring hope... only light... / ],
   'shared ordhash, check find vals =~ match'
);
cmp_array(
   [ $h5->find('val !~ /^[a-z]/') ],
   [ qw/ of Your peace... Where 16 18 7 9 2 3 / ],
   'shared ordhash, check find vals !~ match'
);
cmp_array(
   [ $h5->find('val eq life') ], [ qw/ in life / ],
   'shared ordhash, check find vals eq match'
);

is( $h5->find('val ne despair'), 26, 'shared ordhash, check find vals ne match' );
is( $h5->find('val lt hope...'), 16, 'shared ordhash, check find vals lt match' );
is( $h5->find('val le hope...'), 18, 'shared ordhash, check find vals le match' );
is( $h5->find('val gt hope...'), 10, 'shared ordhash, check find vals gt match' );
is( $h5->find('val ge hope...'), 12, 'shared ordhash, check find vals ge match' );

cmp_array(
   [ $h5->find('val == 9') ], [ qw/ 7 9 / ],
   'shared ordhash, check find vals == match'
);

is( $h5->find('val !=  9'), 4, 'shared ordhash, check find vals != match' );
is( $h5->find('val <   9'), 2, 'shared ordhash, check find vals <  match' );
is( $h5->find('val <=  9'), 4, 'shared ordhash, check find vals <= match' );
is( $h5->find('val >  18'), 0, 'shared ordhash, check find vals >  match' );
is( $h5->find('val >= 18'), 2, 'shared ordhash, check find vals >= match' );

## find undef

$h5->clear();

$h5->mset( qw/ spring summer fall winter / );
$h5->set( key => undef );

cmp_array(
   [ $h5->find('val eq undef') ], [ 'key', undef ],
   'shared ordhash, check find vals eq undef'
);
cmp_array(
   [ $h5->find('val ne undef') ], [ qw/ spring summer fall winter / ],
   'shared ordhash, check find vals ne undef'
);

## --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- ---

$h5->clear(); $h5->mset( 1 => 1, 6 => 3, 2 => 6, 5 => 5, 4 => 4, 10 => 10 );

## by val

cmp_array(
   [ $h5->sort() ], [ qw/ 1 3 4 5 6 10 / ],
   'shared ordhash, check sort'
);
cmp_array(
   [ $h5->sort("desc") ], [ qw/ 10 6 5 4 3 1 / ],
   'shared ordhash, check sort desc'
);
cmp_array(
   [ $h5->sort("alpha") ], [ qw/ 1 10 3 4 5 6 / ],
    'shared ordhash, check sort alpha'
);
cmp_array(
   [ $h5->sort("alpha desc") ], [ qw/ 6 5 4 3 10 1 / ],
   'shared ordhash, check sort alpha desc'
);

## by key

cmp_array(
   [ $h5->sort("key") ], [ qw/ 1 6 4 5 3 10 / ],
   'shared ordhash, check sort key'
);
cmp_array(
   [ $h5->sort("key desc") ], [ qw/ 10 3 5 4 6 1 / ],
   'shared ordhash, check sort key desc'
);
cmp_array(
   [ $h5->sort("key alpha") ], [ qw/ 1 10 6 4 5 3 / ],
   'shared ordhash, check sort key alpha'
);
cmp_array(
   [ $h5->sort("key alpha desc") ], [ qw/ 3 5 4 6 10 1 / ],
   'shared ordhash, check sort key alpha desc'
);

## --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- ---

## MCE::Shared->ordhash is ordered. Therefore, sorting not required.

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
   [ $h5->values() ], [ qw/ over the rainbow 77 / ],
   'shared ordhash, check values'
);
cmp_array(
   [ $h5->pairs() ], [ qw/ 0 over 1 the 2 rainbow 3 77 / ],
   'shared ordhash, check pairs'
);

is( $h5->length(), 4, 'shared ordhash, check length' );
is( $h5->length(2), 7, 'shared ordhash, check length( key )' );
is( $h5->incr(3), 78, 'shared ordhash, check incr' );
is( $h5->decr(3), 77, 'shared ordhash, check decr' );
is( $h5->incrby(3, 4), 81, 'shared ordhash, check incrby' );
is( $h5->decrby(3, 4), 77, 'shared ordhash, check decrby' );
is( $h5->pincr(3), 77, 'shared ordhash, check pincr' );
is( $h5->get(3), 78, 'shared ordhash, check value after pincr' );
is( $h5->pdecr(3), 78, 'shared ordhash, check pdecr' );
is( $h5->get(3), 77, 'shared ordhash, check value after pdecr' );
is( $h5->append(3, 'ba'), 4, 'shared ordhash, check append' );
is( $h5->get(3), '77ba', 'shared ordhash, check value after append' );

my $h6 = $h5->clone();
my $h7 = $h5->clone(2, 3);
my $h8 = $h5->flush();

is( ref($h7), 'MCE::Shared::Ordhash', 'shared ordhash, check ref' );

cmp_array(
   [ $h6->pairs() ], [ qw/ 0 over 1 the 2 rainbow 3 77ba / ],
   'shared ordhash, check clone'
);
cmp_array(
   [ $h7->pairs() ], [ qw/ 2 rainbow 3 77ba / ],
   'shared ordhash, check clone( keys )'
);
cmp_array(
   [ $h8->pairs() ], [ qw/ 0 over 1 the 2 rainbow 3 77ba / ],
   'shared ordhash, check flush'
);

is( $h5->length(), 0, 'shared ordhash, check emptied' );

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
   [ @check ], [ qw/ 2 rainbow 3 77ba rainbow 77ba / ],
   'shared ordhash, check iterator results'
);

