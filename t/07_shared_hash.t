#!/usr/bin/env perl

use strict;
use warnings;

use Test::More tests => 139;
use MCE::Flow max_workers => 1;
use MCE::Shared;

tie my %h1,   'MCE::Shared', ( k1 => 10, k2 => '', k3 => '' );
tie my $keys, 'MCE::Shared';
tie my $e1,   'MCE::Shared';
tie my $e2,   'MCE::Shared';
tie my $d1,   'MCE::Shared';
tie my $s1,   'MCE::Shared';

my $h5 = MCE::Shared->hash( n => 0 );

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

MCE::Flow::run( sub {
   $e1 = exists $h1{'k2'} ? 1 : 0;
   $d1 = delete $h1{'k2'};
   $e2 = exists $h1{'k2'} ? 1 : 0;
   %h1 = (); $s1 = keys %h1;
   $h1{ret} = [ 'wind', 'air' ];
});

MCE::Flow::finish;

is( $e1,  1, 'shared hash, check exists before delete' );
is( $d1, '', 'shared hash, check delete' );
is( $e2,  0, 'shared hash, check exists after delete' );
is( $s1,  0, 'shared hash, check clear' );
is( $h1{ret}->[1], 'air', 'shared hash, check auto freeze/thaw' );

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

## MCE::Shared->hash isn't ordered. Therefore, must sort.

## find keys

cmp_array(
   [ sort $h5->pairs('key =~ /\.\.\./') ], [ sort qw/ peace... Where / ],
   'shared hash, check find keys =~ match (pairs)'
);
cmp_array(
   [ sort $h5->keys('key =~ /\.\.\./') ], [ sort qw/ peace... / ],
   'shared hash, check find keys =~ match (keys)'
);
cmp_array(
   [ sort $h5->vals('key =~ /\.\.\./') ], [ sort qw/ Where / ],
   'shared hash, check find keys =~ match (vals)'
);

cmp_array(
   [ sort $h5->pairs('key !~ /^[a-z]/') ],
   [ sort qw/ Make me Where there 16 18 7 9 2 3 / ],
   'shared hash, check find keys !~ match (pairs)'
);
cmp_array(
   [ sort $h5->keys('key !~ /^[a-z]/') ],
   [ sort qw/ Make Where 16 7 2 / ],
   'shared hash, check find keys !~ match (keys)'
);
cmp_array(
   [ sort $h5->vals('key !~ /^[a-z]/') ],
   [ sort qw/ me there 18 9 3 / ],
   'shared hash, check find keys !~ match (vals)'
);

cmp_array(
   [ sort $h5->pairs('key !~ /^[a-z]/ :AND val =~ /^\d$/') ],
   [ sort qw/ 7 9 2 3 / ],
   'shared hash, check find keys && match (pairs)'
);
cmp_array(
   [ sort $h5->keys('key !~ /^[a-z]/ :AND val =~ /^\d$/') ],
   [ sort qw/ 7 2 / ],
   'shared hash, check find keys && match (keys)'
);
cmp_array(
   [ sort $h5->vals('key !~ /^[a-z]/ :AND val =~ /^\d$/') ],
   [ sort qw/ 9 3 / ],
   'shared hash, check find keys && match (vals)'
);

cmp_array(
   [ sort $h5->pairs('key eq a') ], [ sort qw/ a channel / ],
   'shared hash, check find keys eq match (pairs)'
);
cmp_array(
   [ sort $h5->keys('key eq a') ], [ sort qw/ a / ],
   'shared hash, check find keys eq match (keys)'
);
cmp_array(
   [ sort $h5->vals('key eq a') ], [ sort qw/ channel / ],
   'shared hash, check find keys eq match (vals)'
);

is( $h5->pairs('key ne there\'s'), 26, 'shared hash, check find keys ne match (pairs)' );
is( $h5->keys('key ne there\'s'), 13, 'shared hash, check find keys ne match (keys)' );
is( $h5->vals('key ne there\'s'), 13, 'shared hash, check find keys ne match (vals)' );

is( $h5->pairs('key lt bring'),    12, 'shared hash, check find keys lt match (pairs)' );
is( $h5->keys('key lt bring'),     6, 'shared hash, check find keys lt match (keys)' );
is( $h5->vals('key lt bring'),     6, 'shared hash, check find keys lt match (vals)' );

is( $h5->pairs('key le bring'),    14, 'shared hash, check find keys le match (pairs)' );
is( $h5->keys('key le bring'),     7, 'shared hash, check find keys le match (keys)' );
is( $h5->vals('key le bring'),     7, 'shared hash, check find keys le match (vals)' );

is( $h5->pairs('key gt bring'),    14, 'shared hash, check find keys gt match (pairs)' );
is( $h5->keys('key gt bring'),     7, 'shared hash, check find keys gt match (keys)' );
is( $h5->vals('key gt bring'),     7, 'shared hash, check find keys gt match (vals)' );

is( $h5->pairs('key ge bring'),    16, 'shared hash, check find keys ge match (pairs)' );
is( $h5->keys('key ge bring'),     8, 'shared hash, check find keys ge match (keys)' );
is( $h5->vals('key ge bring'),     8, 'shared hash, check find keys ge match (vals)' );

cmp_array(
   [ sort $h5->pairs('key == 16') ], [ sort qw/ 16 18 / ],
   'shared hash, check find keys == match (pairs)'
);
cmp_array(
   [ sort $h5->keys('key == 16') ], [ sort qw/ 16 / ],
   'shared hash, check find keys == match (keys)'
);
cmp_array(
   [ sort $h5->vals('key == 16') ], [ sort qw/ 18 / ],
   'shared hash, check find keys == match (vals)'
);

is( $h5->pairs('key != 16'), 4, 'shared hash, check find keys != match (pairs)' );
is( $h5->keys('key != 16'), 2, 'shared hash, check find keys != match (keys)' );
is( $h5->vals('key != 16'), 2, 'shared hash, check find keys != match (vals)' );

is( $h5->pairs('key <   7'), 2, 'shared hash, check find keys <  match (pairs)' );
is( $h5->keys('key <   7'), 1, 'shared hash, check find keys <  match (keys)' );
is( $h5->vals('key <   7'), 1, 'shared hash, check find keys <  match (vals)' );

is( $h5->pairs('key <=  7'), 4, 'shared hash, check find keys <= match (pairs)' );
is( $h5->keys('key <=  7'), 2, 'shared hash, check find keys <= match (keys)' );
is( $h5->vals('key <=  7'), 2, 'shared hash, check find keys <= match (vals)' );

is( $h5->pairs('key >   2'), 4, 'shared hash, check find keys >  match (pairs)' );
is( $h5->keys('key >   2'), 2, 'shared hash, check find keys >  match (keys)' );
is( $h5->vals('key >   2'), 2, 'shared hash, check find keys >  match (vals)' );

is( $h5->pairs('key >=  2'), 6, 'shared hash, check find keys >= match (pairs)' );
is( $h5->keys('key >=  2'), 3, 'shared hash, check find keys >= match (keys)' );
is( $h5->vals('key >=  2'), 3, 'shared hash, check find keys >= match (vals)' );

## find vals

cmp_array(
   [ sort $h5->pairs('val =~ /\.\.\./') ],
   [ sort qw/ bring hope... only light... / ],
   'shared hash, check find vals =~ match (pairs)'
);
cmp_array(
   [ sort $h5->keys('val =~ /\.\.\./') ],
   [ sort qw/ bring only / ],
   'shared hash, check find vals =~ match (keys)'
);
cmp_array(
   [ sort $h5->vals('val =~ /\.\.\./') ],
   [ sort qw/ hope... light... / ],
   'shared hash, check find vals =~ match (vals)'
);

cmp_array(
   [ sort $h5->pairs('val !~ /^[a-z]/') ],
   [ sort qw/ of Your peace... Where 16 18 7 9 2 3 / ],
   'shared hash, check find vals !~ match (pairs)'
);
cmp_array(
   [ sort $h5->keys('val !~ /^[a-z]/') ],
   [ sort qw/ of peace... 16 7 2 / ],
   'shared hash, check find vals !~ match (keys)'
);
cmp_array(
   [ sort $h5->vals('val !~ /^[a-z]/') ],
   [ sort qw/ Your Where 18 9 3 / ],
   'shared hash, check find vals !~ match (vals)'
);

cmp_array(
   [ sort $h5->pairs('val =~ /\d/ :OR val eq Where') ],
   [ sort qw/ peace... Where 16 18 7 9 2 3 / ],
   'shared hash, check find vals || match (pairs)'
);
cmp_array(
   [ sort $h5->keys('val =~ /\d/ :OR val eq Where') ],
   [ sort qw/ peace... 16 7 2 / ],
   'shared hash, check find vals || match (keys)'
);
cmp_array(
   [ sort $h5->vals('val =~ /\d/ :OR val eq Where') ],
   [ sort qw/ Where 18 9 3 / ],
   'shared hash, check find vals || match (vals)'
);

cmp_array(
   [ sort $h5->pairs('val eq life') ], [ sort qw/ in life / ],
   'shared hash, check find vals eq match (pairs)'
);
cmp_array(
   [ sort $h5->keys('val eq life') ], [ sort qw/ in / ],
   'shared hash, check find vals eq match (keys)'
);
cmp_array(
   [ sort $h5->vals('val eq life') ], [ sort qw/ life / ],
   'shared hash, check find vals eq match (vals)'
);

is( $h5->pairs('val ne despair'), 26, 'shared hash, check find vals ne match (pairs)' );
is( $h5->keys('val ne despair'), 13, 'shared hash, check find vals ne match (keys)' );
is( $h5->vals('val ne despair'), 13, 'shared hash, check find vals ne match (vals)' );

is( $h5->pairs('val lt hope...'), 16, 'shared hash, check find vals lt match (pairs)' );
is( $h5->keys('val lt hope...'),  8, 'shared hash, check find vals lt match (keys)' );
is( $h5->vals('val lt hope...'),  8, 'shared hash, check find vals lt match (vals)' );

is( $h5->pairs('val le hope...'), 18, 'shared hash, check find vals le match (pairs)' );
is( $h5->keys('val le hope...'),  9, 'shared hash, check find vals le match (keys)' );
is( $h5->vals('val le hope...'),  9, 'shared hash, check find vals le match (vals)' );

is( $h5->pairs('val gt hope...'), 10, 'shared hash, check find vals gt match (pairs)' );
is( $h5->keys('val gt hope...'),  5, 'shared hash, check find vals gt match (keys)' );
is( $h5->vals('val gt hope...'),  5, 'shared hash, check find vals gt match (vals)' );

is( $h5->pairs('val ge hope...'), 12, 'shared hash, check find vals ge match (pairs)' );
is( $h5->keys('val ge hope...'),  6, 'shared hash, check find vals ge match (keys)' );
is( $h5->vals('val ge hope...'),  6, 'shared hash, check find vals ge match (vals)' );

cmp_array(
   [ sort $h5->pairs('val == 9') ], [ sort qw/ 7 9 / ],
   'shared hash, check find vals == match (pairs)'
);
cmp_array(
   [ sort $h5->keys('val == 9') ], [ sort qw/ 7 / ],
   'shared hash, check find vals == match (keys)'
);
cmp_array(
   [ sort $h5->vals('val == 9') ], [ sort qw/ 9 / ],
   'shared hash, check find vals == match (vals)'
);

is( $h5->pairs('val !=  9'), 4, 'shared hash, check find vals != match (pairs)' );
is( $h5->keys('val !=  9'), 2, 'shared hash, check find vals != match (keys)' );
is( $h5->vals('val !=  9'), 2, 'shared hash, check find vals != match (vals)' );

is( $h5->pairs('val <   9'), 2, 'shared hash, check find vals <  match (pairs)' );
is( $h5->keys('val <   9'), 1, 'shared hash, check find vals <  match (keys)' );
is( $h5->vals('val <   9'), 1, 'shared hash, check find vals <  match (vals)' );

is( $h5->pairs('val <=  9'), 4, 'shared hash, check find vals <= match (pairs)' );
is( $h5->keys('val <=  9'), 2, 'shared hash, check find vals <= match (keys)' );
is( $h5->vals('val <=  9'), 2, 'shared hash, check find vals <= match (vals)' );

is( $h5->pairs('val >  18'), 0, 'shared hash, check find vals >  match (pairs)' );
is( $h5->keys('val >  18'), 0, 'shared hash, check find vals >  match (keys)' );
is( $h5->vals('val >  18'), 0, 'shared hash, check find vals >  match (vals)' );

is( $h5->pairs('val >= 18'), 2, 'shared hash, check find vals >= match (pairs)' );
is( $h5->keys('val >= 18'), 1, 'shared hash, check find vals >= match (keys)' );
is( $h5->vals('val >= 18'), 1, 'shared hash, check find vals >= match (vals)' );

## find undef

$h5->clear();

$h5->mset( qw/ spring summer fall winter / );
$h5->set( key => undef );

cmp_array(
   [ $h5->pairs('val eq undef') ], [ 'key', undef ],
   'shared hash, check find vals eq undef (pairs)'
);
cmp_array(
   [ $h5->keys('val eq undef') ], [ 'key' ],
   'shared hash, check find vals eq undef (keys)'
);
cmp_array(
   [ $h5->vals('val eq undef') ], [ undef ],
   'shared hash, check find vals eq undef (vals)'
);

cmp_array(
   [ sort $h5->pairs('val ne undef') ], [ sort qw/ spring summer fall winter / ],
   'shared hash, check find vals ne undef (pairs)'
);
cmp_array(
   [ sort $h5->keys('val ne undef') ], [ sort qw/ spring fall / ],
   'shared hash, check find vals ne undef (keys)'
);
cmp_array(
   [ sort $h5->vals('val ne undef') ], [ sort qw/ summer winter / ],
   'shared hash, check find vals ne undef (vals)'
);

## --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- ---

## MCE::Shared->hash isn't ordered. Therefore, must sort.

$h5->clear(); $h5->mset( 0, 'over', 1, 'the', 2, 'rainbow', 3, 77 );

cmp_array(
   [ sort $h5->pairs() ], [ sort qw/ 0 over 1 the 2 rainbow 3 77 / ],
   'shared hash, check mset'
);
cmp_array(
   [ sort $h5->mget(0, 2) ], [ sort qw/ over rainbow / ],
   'shared hash, check mget'
);
cmp_array(
   [ sort $h5->keys() ], [ sort qw/ 0 1 2 3 / ],
   'shared hash, check keys'
);
cmp_array(
   [ sort $h5->vals() ], [ sort qw/ over the rainbow 77 / ],
   'shared hash, check values'
);
cmp_array(
   [ sort $h5->pairs() ], [ sort qw/ 0 over 1 the 2 rainbow 3 77 / ],
   'shared hash, check pairs'
);

is( $h5->len(), 4, 'shared hash, check length' );
is( $h5->len(2), 7, 'shared hash, check length( key )' );
is( $h5->incr(3), 78, 'shared hash, check incr' );
is( $h5->decr(3), 77, 'shared hash, check decr' );
is( $h5->incrby(3, 4), 81, 'shared hash, check incrby' );
is( $h5->decrby(3, 4), 77, 'shared hash, check decrby' );
is( $h5->getincr(3), 77, 'shared hash, check getincr' );
is( $h5->get(3), 78, 'shared hash, check value after getincr' );
is( $h5->getdecr(3), 78, 'shared hash, check getdecr' );
is( $h5->get(3), 77, 'shared hash, check value after getdecr' );
is( $h5->append(3, 'ba'), 4, 'shared hash, check append' );
is( $h5->get(3), '77ba', 'shared hash, check value after append' );
is( $h5->getset('3', '77bc'), '77ba', 'shared hash, check getset' );
is( $h5->get(3), '77bc', 'shared hash, check value after getset' );

my $h6 = $h5->clone();
my $h7 = $h5->clone(2, 3);
my $h8 = $h5->flush();

is( ref($h7), 'MCE::Shared::Hash', 'shared hash, check ref' );

cmp_array(
   [ sort $h6->pairs() ], [ sort qw/ 0 over 1 the 2 rainbow 3 77bc / ],
   'shared hash, check clone'
);
cmp_array(
   [ sort $h7->pairs() ], [ sort qw/ 2 rainbow 3 77bc / ],
   'shared hash, check clone( keys )'
);
cmp_array(
   [ sort $h8->pairs() ], [ sort qw/ 0 over 1 the 2 rainbow 3 77bc / ],
   'shared hash, check flush'
);

is( $h5->len(), 0, 'shared hash, check emptied' );

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

is( $count, 4, 'shared hash, check iterator count' );

cmp_array(
   [ sort @check ], [ sort qw/ 2 rainbow 3 77bc rainbow 77bc / ],
   'shared hash, check iterator results'
);

## --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- ---

my @list;

$h5->clear(); $h5->mset( 0, 'over', 1, 'the', 2, 'rainbow', 3, 77 );

while ( my $val = $h5->next ) { push @list, $val; }

cmp_array(
   [ sort @list ], [ sort qw/ over the rainbow 77 / ],
   'shared hash, check next'
);

@list = (); $h5->rewind('val =~ /[a-z]/');

while ( my ($key, $val) = $h5->next ) { push @list, $key, $val; }

cmp_array(
   [ sort @list ], [ sort qw/ 0 over 1 the 2 rainbow / ],
   'shared hash, check rewind 1'
);

@list = (); $h5->rewind('key =~ /\d/');

while ( my $val = $h5->next ) { push @list, $val; }

cmp_array(
   [ sort @list ], [ sort qw/ over the rainbow 77 / ],
   'shared hash, check rewind 2'
);

@list = (); $h5->rewind(qw/ 1 2 /);

while ( my $val = $h5->next ) { push @list, $val; }

cmp_array(
   [ sort @list ], [ sort qw/ the rainbow / ],
   'shared hash, check rewind 3'
);

is( $h5->mexists(qw/ 0 2 3 /),  1, 'shared hash, check mexists 1' );
is( $h5->mexists(qw/ 0 8 3 /), '', 'shared hash, check mexists 2' );

is( $h5->mdel(qw/ 3 2 1 0 /), 4, 'shared hash, check mdel' );

