#!/usr/bin/env perl

use strict;
use warnings;

use Test::More tests => 7;
use MCE::Signal qw( $tmp_dir );
use MCE::Shared;
use bytes;

## --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- ---

my ($buf, $fno, $ret1, $ret2, $ret3, $ret4, $ret5) = ('');
my $tmp_file = "$tmp_dir/test.txt";

my $fh = MCE::Shared->handle(">:raw", $tmp_file);

$fno = fileno $fh;

for (1 .. 9) {
   print  $fh "$_\n";
   printf $fh "%2s\n", $_;
}

close $fh;

## --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- --- ---

open $fh, "<:raw", $tmp_file;

$ret1 = eof $fh;

while ( <$fh> ) {
   chomp, $buf .= $_;
}

$ret2 = eof $fh;
$ret3 = tell $fh;

seek $fh, 12, 0;
read $fh, $ret4, 2;

$ret5 = getc $fh;

close $fh;

like( $fno, qr/\A\d+\z/, 'shared file, OPEN, FILENO, CLOSE' );

is( $buf, '1 12 23 34 45 56 67 78 89 9', 'shared file, PRINT, PRINTF, READLINE' );

is( $ret1, '',   'shared file, EOF (test 1)' );
is( $ret2, '1',  'shared file, EOF (test 2)' );
is( $ret3, '45', 'shared file, TELL' );
is( $ret4, ' 3', 'shared file, SEEK, READ' );
is( $ret5, "\n", 'shared file, GETC' );

unlink $tmp_file if -f $tmp_file;

