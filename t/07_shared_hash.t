#!/usr/bin/env perl

use strict;
use warnings;

use Test::More tests => 64;
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
   [ sort $h5->find('key =~ /\.\.\./') ], [ sort qw/ peace... Where / ],
   'shared hash, check find keys =~ match'
);
cmp_array(
   [ sort $h5->find('key !~ /^[a-z]/') ],
   [ sort qw/ Make me Where there 16 18 7 9 2 3 / ],
   'shared hash, check find keys !~ match'
);
cmp_array(
   [ sort $h5->find('key eq a') ], [ sort qw/ a channel / ],
   'shared hash, check find keys eq match'
);

is( $h5->find('key ne there\'s'), 26, 'shared hash, check find keys ne match' );
is( $h5->find('key lt bring'),    12, 'shared hash, check find keys lt match' );
is( $h5->find('key le bring'),    14, 'shared hash, check find keys le match' );
is( $h5->find('key gt bring'),    14, 'shared hash, check find keys gt match' );
is( $h5->find('key ge bring'),    16, 'shared hash, check find keys ge match' );

cmp_array(
   [ sort $h5->find('key == 16') ], [ sort qw/ 16 18 / ],
   'shared hash, check find keys == match'
);

is( $h5->find('key != 16'), 4, 'shared hash, check find keys != match' );
is( $h5->find('key <   7'), 2, 'shared hash, check find keys <  match' );
is( $h5->find('key <=  7'), 4, 'shared hash, check find keys <= match' );
is( $h5->find('key >   2'), 4, 'shared hash, check find keys >  match' );
is( $h5->find('key >=  2'), 6, 'shared hash, check find keys >= match' );

## find vals

cmp_array(
   [ sort $h5->find('val =~ /\.\.\./') ],
   [ sort qw/ bring hope... only light... / ],
   'shared hash, check find vals =~ match'
);
cmp_array(
   [ sort $h5->find('val !~ /^[a-z]/') ],
   [ sort qw/ of Your peace... Where 16 18 7 9 2 3 / ],
   'shared hash, check find vals !~ match'
);
cmp_array(
   [ sort $h5->find('val eq life') ], [ sort qw/ in life / ],
   'shared hash, check find vals eq match'
);

is( $h5->find('val ne despair'), 26, 'shared hash, check find vals ne match' );
is( $h5->find('val lt hope...'), 16, 'shared hash, check find vals lt match' );
is( $h5->find('val le hope...'), 18, 'shared hash, check find vals le match' );
is( $h5->find('val gt hope...'), 10, 'shared hash, check find vals gt match' );
is( $h5->find('val ge hope...'), 12, 'shared hash, check find vals ge match' );

cmp_array(
   [ sort $h5->find('val == 9') ], [ sort qw/ 7 9 / ],
   'shared hash, check find vals == match'
);

is( $h5->find('val !=  9'), 4, 'shared hash, check find vals != match' );
is( $h5->find('val <   9'), 2, 'shared hash, check find vals <  match' );
is( $h5->find('val <=  9'), 4, 'shared hash, check find vals <= match' );
is( $h5->find('val >  18'), 0, 'shared hash, check find vals >  match' );
is( $h5->find('val >= 18'), 2, 'shared hash, check find vals >= match' );

## find undef

$h5->clear();

$h5->mset( qw/ spring summer fall winter / );
$h5->set( key => undef );

cmp_array(
   [ $h5->find('val eq undef') ], [ 'key', undef ],
   'shared hash, check find vals eq undef'
);
cmp_array(
   [ sort $h5->find('val ne undef') ], [ sort qw/ spring summer fall winter / ],
   'shared hash, check find vals ne undef'
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
   [ sort $h5->values() ], [ sort qw/ over the rainbow 77 / ],
   'shared hash, check values'
);
cmp_array(
   [ sort $h5->pairs() ], [ sort qw/ 0 over 1 the 2 rainbow 3 77 / ],
   'shared hash, check pairs'
);

is( $h5->length(), 4, 'shared hash, check length' );
is( $h5->length(2), 7, 'shared hash, check length( key )' );
is( $h5->incr(3), 78, 'shared hash, check incr' );
is( $h5->decr(3), 77, 'shared hash, check decr' );
is( $h5->incrby(3, 4), 81, 'shared hash, check incrby' );
is( $h5->decrby(3, 4), 77, 'shared hash, check decrby' );
is( $h5->pincr(3), 77, 'shared hash, check pincr' );
is( $h5->get(3), 78, 'shared hash, check value after pincr' );
is( $h5->pdecr(3), 78, 'shared hash, check pdecr' );
is( $h5->get(3), 77, 'shared hash, check value after pdecr' );
is( $h5->append(3, 'ba'), 4, 'shared hash, check append' );
is( $h5->get(3), '77ba', 'shared hash, check value after append' );

my $h6 = $h5->clone();
my $h7 = $h5->clone(2, 3);
my $h8 = $h5->flush();

is( ref($h7), 'MCE::Shared::Hash', 'shared hash, check ref' );

cmp_array(
   [ sort $h6->pairs() ], [ sort qw/ 0 over 1 the 2 rainbow 3 77ba / ],
   'shared hash, check clone'
);
cmp_array(
   [ sort $h7->pairs() ], [ sort qw/ 2 rainbow 3 77ba / ],
   'shared hash, check clone( keys )'
);
cmp_array(
   [ sort $h8->pairs() ], [ sort qw/ 0 over 1 the 2 rainbow 3 77ba / ],
   'shared hash, check flush'
);

is( $h5->length(), 0, 'shared hash, check emptied' );

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
   [ sort @check ], [ sort qw/ 2 rainbow 3 77ba rainbow 77ba / ],
   'shared hash, check iterator results'
);

