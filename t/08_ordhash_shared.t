#!../perl -w

use strict;
use warnings;

use Cwd 'abs_path'; ## Insert lib-path at the head of @INC.
use lib abs_path($0 =~ m{^(.*)[\\/]} && $1 || abs_path) . '/../lib';

##
# Borrowed from Tie::IxHash/t/ixhash.t for checking compatiblity.
# MCE::Shared enables ordered hash automatically when MCE::OrdHash
# is present.
##

use MCE::OrdHash;
use MCE::Shared;

my $TNUM = 0;
print "1..26\n";

sub T { print $_[0] ? "ok " : "not ok ", ++$TNUM, "\n" }

# my %bar : Shared = ('a' => 1, 'q' => 2, 'm' => 'X', 'n' => 'Y');
# my $ixh = tied(%bar);

my @pairs = ('a' => 1, 'q' => 2, 'm' => 'X', 'n' => 'Y');
my $ixh   = mce_share( {}, @pairs );
my @tmp;

$ixh->Push(e => 5, f => 6);
T 'a|1|q|2|m|X|n|Y|e|5|f|6' eq join('|', $ixh->Pairs);

$ixh->Delete('e', 'a');
T 'q|2|m|X|n|Y|f|6' eq join '|', $ixh->Pairs;
T 'q|m|n|f' eq join '|', $ixh->Keys;
T '2|X|Y|6' eq join '|', $ixh->Values;
T 'm|n|f' eq join '|', $ixh->KeysInd(1, 2, 3);
T 'X|Y|6' eq join '|', $ixh->ValuesInd(1, 2, 3);

$ixh->Replace(1, 9);
T 'q|2|m|9|n|Y|f|6' eq join '|', $ixh->Pairs;

$ixh->Replace(0, 8, 'f');
T 'f|8|m|9|n|Y' eq join '|', $ixh->Pairs;
T '2|1' eq join '|', $ixh->Indices('n', 'm');

$ixh->Push(z => 1);
$ixh->SortByValue;
T 'z|f|m|n' eq join '|', $ixh->Keys;

$ixh->SortByKey;
T 'f|m|n|z' eq join '|', $ixh->Keys;
T 'm' eq $ixh->KeysInd(1);
T 'Y' eq $ixh->ValuesInd(2);
T 3 == $ixh->Indices('z');

%{ $ixh } = ('a' => 9, 'c' => 6, 'z' => 7, 'f' => 1);
delete $ixh->{'z'};
$ixh->{'a'} = 10;
T 'a|10|c|6|f|1' eq join '|', %{ $ixh };
T 'a|c|f' eq join '|', keys %{ $ixh };
T '10|6|1' eq join '|', values %{ $ixh };

$ixh->Reorder(sort { $ixh->{$a} <=> $ixh->{$b} } $ixh->Keys);
T 'f|c|a' eq join '|', $ixh->Keys;

$ixh->Reorder('c', 'a', 'z');
T 'c|6|a|10' eq join '|', $ixh->Pairs;

@tmp = $ixh->Splice(0, 3, 'z' => 7, 'm' => 4); 
T 'c|6|a|10' eq join '|', @tmp;
T 'z|7|m|4' eq join '|', $ixh->Pairs;

$ixh->Push('m' => 8);
@tmp = $ixh->Pop;
T 'm|8' eq join '|', @tmp;

$ixh->Push('o' => 2, 'r' => 8);
T 'z|7|o|2|r|8' eq join '|', $ixh->Pairs;

$ixh->Pop;
T 'z|7|o|2' eq join '|', $ixh->Pairs;

$ixh->Splice($ixh->Length,0,$ixh->Pop);
T 'z|7|o|2' eq join '|', $ixh->Pairs;

$ixh->Clear;
T $ixh->Length == 0;

