#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;

BEGIN {
   use_ok 'MCE::Channel';
   use_ok 'MCE::Channel::SimpleFast';
}

my $chnl = MCE::Channel->new( impl => 'SimpleFast' );
is $chnl->impl(), 'SimpleFast', 'implementation name';

# send recv
{
   $chnl->send('a string');
   is $chnl->recv, 'a string', 'send recv scalar';

   $chnl->send('');
   is $chnl->recv, '', 'send recv blank string';

   $chnl->send(undef);
   is $chnl->recv, '', 'send recv undef stringified';
}

# send recv_nb
{
   $chnl->send('a string');
   is $chnl->recv_nb, 'a string', 'send recv_nb scalar';

   $chnl->send('');
   is $chnl->recv_nb, '', 'send recv_nb blank string';

   $chnl->send(undef);
   is $chnl->recv_nb, '', 'send recv_nb undef stringified';
}

# send2 recv2
{
   $chnl->send2('a string');
   is $chnl->recv2, 'a string', 'send2 recv2 scalar';

   $chnl->send2('');
   is $chnl->recv2, '', 'send2 recv2 blank string';

   $chnl->send2(undef);
   is $chnl->recv2, '', 'send2 recv2 undef stringified';
}

# send2 recv2_nb
{
   $chnl->send2('a string');
   is $chnl->recv2_nb, 'a string', 'send2 recv2_nb scalar';

   $chnl->send2('');
   is $chnl->recv2_nb, '', 'send2 recv2_nb blank string';

   $chnl->send2(undef);
   is $chnl->recv2_nb, '', 'send2 recv2_nb undef stringified';
}

# enqueue dequeue
{
   $chnl->enqueue('a string');
   is $chnl->dequeue, 'a string', 'enqueue dequeue scalar';

   $chnl->enqueue(qw/ a list of items /);
   is scalar( my $item1 = $chnl->dequeue ), 'a',     'enqueue dequeue item1';
   is scalar( my $item2 = $chnl->dequeue ), 'list',  'enqueue dequeue item2';
   is scalar( my $item3 = $chnl->dequeue ), 'of',    'enqueue dequeue item3';
   is scalar( my $item4 = $chnl->dequeue ), 'items', 'enqueue dequeue item4';

   $chnl->enqueue('');
   is $chnl->dequeue, '', 'enqueue dequeue blank string';

   $chnl->enqueue(undef);
   is $chnl->dequeue, '', 'enqueue dequeue undef stringified';

   $chnl->enqueue(qw/ a b c /);
   is join( '', $chnl->dequeue(3) ), 'abc', 'enqueue dequeue count';
}

# enqueue dequeue_nb
{
   $chnl->enqueue('a string');
   is $chnl->dequeue_nb, 'a string', 'enqueue dequeue_nb scalar';

   $chnl->enqueue(qw/ a list of items /);
   is scalar( my $item1 = $chnl->dequeue_nb ), 'a',     'enqueue dequeue_nb item1';
   is scalar( my $item2 = $chnl->dequeue_nb ), 'list',  'enqueue dequeue_nb item2';
   is scalar( my $item3 = $chnl->dequeue_nb ), 'of',    'enqueue dequeue_nb item3';
   is scalar( my $item4 = $chnl->dequeue_nb ), 'items', 'enqueue dequeue_nb item4';

   $chnl->enqueue('');
   is $chnl->dequeue_nb, '', 'enqueue dequeue_nb blank string';

   $chnl->enqueue(undef);
   is $chnl->dequeue_nb, '', 'enqueue dequeue_nb undef stringified';

   $chnl->enqueue(qw/ a b c /);
   is join( '', $chnl->dequeue_nb(3) ), 'abc', 'enqueue dequeue_nb count';
}

# end
{
   $chnl->enqueue("item $_") for 1 .. 2;
   $chnl->end;

   for my $method (qw/ send enqueue /) {
      local $SIG{__WARN__} = sub {
         is $_[0],
         "WARNING: ($method) called on a channel that has been 'end'ed\n",
         "channel ended, $method";
      };
      $chnl->$method("item");
   }

   is $chnl->dequeue_nb, 'item 1', 'channel ended, dequeue_nb item 1';
   is $chnl->dequeue_nb, 'item 2', 'channel ended, dequeue_nb item 2';
}

done_testing;

