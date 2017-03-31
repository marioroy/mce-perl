#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;

## MCE::Signal is loaded by MCE automatically and is not neccessary in
## scripts unless wanting to export or pass options.

BEGIN {
   use_ok('MCE::Signal');

   use_ok('MCE');
   use_ok('MCE::Util');

   use_ok('MCE::Mutex');
   use_ok('MCE::Mutex::Channel');
   use_ok('MCE::Mutex::Flock');

   use_ok('MCE::Core::Input::Generator');
   use_ok('MCE::Core::Input::Handle');
   use_ok('MCE::Core::Input::Iterator');
   use_ok('MCE::Core::Input::Request');
   use_ok('MCE::Core::Input::Sequence');

   use_ok('MCE::Core::Manager');
   use_ok('MCE::Core::Validation');
   use_ok('MCE::Core::Worker');

   use_ok('MCE::Candy');
   use_ok('MCE::Queue');
   use_ok('MCE::Relay');
   use_ok('MCE::Subs');

   use_ok('MCE::Flow');
   use_ok('MCE::Grep');
   use_ok('MCE::Loop');
   use_ok('MCE::Map');
   use_ok('MCE::Step');
   use_ok('MCE::Stream');
}

done_testing;

