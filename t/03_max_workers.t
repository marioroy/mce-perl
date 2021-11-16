#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

BEGIN {
   use_ok 'MCE';
   use_ok 'MCE::Flow';
}

{
   no warnings 'redefine';
   sub MCE::Util::get_ncpu { return 16; }
}

{
   # Going higher than the HW ncpu limit is possible. Simply specify the
   # number of workers desired. The minimum number of workers is 1.

   my $mce = MCE->new(max_workers => 0);
   is($mce->max_workers(), 1, "check that max_workers=>0 is 1");

   $mce = MCE->new(max_workers => 5);
   is($mce->max_workers(), 5, "check that max_workers=>5 is 5");

   $mce = MCE->new(max_workers => 20);
   is($mce->max_workers(), 20, "check that max_workers=>20 is 20");
}

{
   # The limit for 'auto' is 8 including on HW with more than 8 logical cores.
   # The minimum number of workers is 1.

   my $mce = MCE->new(max_workers => 'auto');
   is($mce->max_workers(), 8,
      "check that max_workers=>'auto' is 8 on HW with 16 logical cores"
   );

   $mce = MCE->new(max_workers => 'auto-8');
   is($mce->max_workers(), 1,
      "check that max_workers=>'auto-8' is 1 on HW with 16 logical cores"
   );

   $mce = MCE->new(max_workers => 'auto-1');
   is($mce->max_workers(), 7,
      "check that max_workers=>'auto-1' is 7 on HW with 16 logical cores"
   );

   $mce = MCE->new(max_workers => 'auto+1');
   is($mce->max_workers(), 9,
      "check that max_workers=>'auto+1' is 9 on HW with 16 logical cores"
   );

   $mce = MCE->new(max_workers => 'auto/2');
   is($mce->max_workers(), 4,
      "check that max_workers=>'auto/2' is 4 on HW with 16 logical cores"
   );

   $mce = MCE->new(max_workers => 'auto*0');
   is($mce->max_workers(), 1,
      "check that max_workers=>'auto*0' is 1 on HW with 16 logical cores"
   );

   $mce = MCE->new(max_workers => 'auto*2');
   is($mce->max_workers(), 16,
      "check that max_workers=>'auto*2' is 16 on HW with 16 logical cores"
   );

   $mce = MCE->new(user_tasks => [
      { max_workers => 1 },
      { max_workers => 'auto/2' },
      { max_workers => 'auto+2' },
   ]);

   is($mce->{user_tasks}[0]{max_workers}, 1,
      "check that task 0 max_workers=>'1' is 1 on HW with 16 logical cores"
   );
   is($mce->{user_tasks}[1]{max_workers}, 4,
      "check that task 1 max_workers=>'auto/2' is 4 on HW with 16 logical cores"
   );
   is($mce->{user_tasks}[2]{max_workers}, 10,
      "check that task 2 max_workers=>'auto+2' is 10 on HW with 16 logical cores"
   );
}

{
   # One may specify a percentage starting with MCE 1.875.
   # Thanks to kcott@PerlMonks (Ken) for the idea.
   # https://www.perlmonks.org/?node_id=11134439
   # The min-max number of workers is 1 and MCE::Util::get_ncpu().

   my $mce = MCE->new(max_workers => '0%');
   is($mce->max_workers(), 1,
      "check that max_workers=>'0%' is 1 on HW with 16 logical cores"
   );

   $mce = MCE->new(max_workers => '1%');
   is($mce->max_workers(), 1,
      "check that max_workers=>'1%' is 1 on HW with 16 logical cores"
   );

   $mce = MCE->new(max_workers => '25%');
   is($mce->max_workers(), 4,
      "check that max_workers=>'25%' is 4 on HW with 16 logical cores"
   );

   $mce = MCE->new(max_workers => '37.5%');
   is($mce->max_workers(), 6,
      "check that max_workers=>'37.5%' is 6 on HW with 16 logical cores"
   );

   $mce = MCE->new(max_workers => '100%');
   is($mce->max_workers(), 16,
      "check that max_workers=>'100%' is 16 on HW with 16 logical cores"
   );

   $mce = MCE->new(max_workers => '200%');
   is($mce->max_workers(), 16,
      "check that max_workers=>'200%' is 16 on HW with 16 logical cores"
   );

   $mce = MCE->new(user_tasks => [
      { max_workers => 1 },
      { max_workers => '25%' },
      { max_workers => '50%' },
   ]);

   is($mce->{user_tasks}[0]{max_workers}, 1,
      "check that task 0 max_workers=>'1' is 1 on HW with 16 logical cores"
   );
   is($mce->{user_tasks}[1]{max_workers}, 4,
      "check that task 1 max_workers=>'25%' is 4 on HW with 16 logical cores"
   );
   is($mce->{user_tasks}[2]{max_workers}, 8,
      "check that task 2 max_workers=>'50%' is 8 on HW with 16 logical cores"
   );
}

{
   MCE::Flow::init(max_workers => [1, '25%']);

   my @res;
   mce_flow { gather => \@res },
       sub { MCE->gather('a'.MCE->task_wid()); },  # 1 worker
       sub { MCE->gather('b'.MCE->task_wid()); };  # 4 workers

   @res = sort @res;
   is("@res", "a1 b1 b2 b3 b4", "check that MCE::Flow ran with 5 workers");

   MCE::Flow->finish();
}

done_testing;

