###############################################################################
## ----------------------------------------------------------------------------
## Queue-like and two-way communication capability.
##
###############################################################################

package MCE::Channel;

use strict;
use warnings;

no warnings qw( uninitialized once );

our $VERSION = '1.879';

## no critic (BuiltinFunctions::ProhibitStringyEval)
## no critic (TestingAndDebugging::ProhibitNoStrict)

use if $^O eq 'MSWin32', 'threads';
use if $^O eq 'MSWin32', 'threads::shared';

use Carp ();

$Carp::Internal{ (__PACKAGE__) }++;

my ( $freeze, $thaw );

BEGIN {
   if ( $] ge '5.008008' && ! $INC{'PDL.pm'} ) {
      local $@;
      eval 'use Sereal::Encoder 3.015; use Sereal::Decoder 3.015;';
      if ( ! $@ ) {
         my $encoder_ver = int( Sereal::Encoder->VERSION() );
         my $decoder_ver = int( Sereal::Decoder->VERSION() );
         if ( $encoder_ver - $decoder_ver == 0 ) {
            $freeze = \&Sereal::Encoder::encode_sereal;
            $thaw   = \&Sereal::Decoder::decode_sereal;
         }
      }
   }

   if ( ! defined $freeze ) {
      require Storable;
      $freeze = \&Storable::freeze;
      $thaw   = \&Storable::thaw;
   }
}

use MCE::Util ();

my $is_MSWin32 = ( $^O eq 'MSWin32' ) ? 1 : 0;
my $tid = $INC{'threads.pm'} ? threads->tid() : 0;

sub new {
   my ( $class, %argv ) = @_;
   my $impl = defined( $argv{impl} ) ? ucfirst( lc $argv{impl} ) : 'Mutex';

   # Replace 'fast' with 'Fast' in the implementation value.
   $impl =~ s/fast$/Fast/;

   $impl = 'Threads'     if ( $impl eq 'Mutex' && $^O eq 'MSWin32' );
   $impl = 'ThreadsFast' if ( $impl eq 'MutexFast' && $^O eq 'MSWin32' );
   $impl = 'Mutex'       if ( $impl eq 'Threads' && $^O eq 'cygwin' );
   $impl = 'MutexFast'   if ( $impl eq 'ThreadsFast' && $^O eq 'cygwin' );

   eval "require MCE::Channel::$impl; 1;" ||
      Carp::croak("Could not load Channel implementation '$impl': $@");

   my $pkg = 'MCE::Channel::'.$impl;
   no strict 'refs';

   $pkg->new(%argv);
}

sub CLONE {
   $tid = threads->tid if $INC{'threads.pm'};
}

sub DESTROY {
   my ( $pid, $self ) = ( $tid ? $$ .'.'. $tid : $$, @_ );

   if ( $self->{'init_pid'} && $self->{'init_pid'} eq $pid ) {
      MCE::Util::_destroy_socks($self, qw(c_sock c2_sock p_sock p2_sock));
      delete($self->{c_mutex}), delete($self->{p_mutex});
   }

   return;
}

sub impl {
   $_[0]->{'impl'} || 'Not defined';
}

sub _get_freeze { $freeze; }
sub _get_thaw   { $thaw;   }

sub _ended {
   warn "WARNING: ($_[0]) called on a channel that has been 'end'ed\n";

   return;
}

sub _read {
   my $bytes = MCE::Util::_sysread( $_[0], $_[1], my $len = $_[2] );
   my $read  = $bytes;

   while ( $bytes && $read != $len ) {
      $bytes = MCE::Util::_sysread( $_[0], $_[1], $len - $read, length($_[1]) );
      $read += $bytes if $bytes;
   }

   return;
}

sub _pid {
   $tid ? $$ .'.'. $tid : $$;
}

1;

__END__

###############################################################################
## ----------------------------------------------------------------------------
## Module usage.
##
###############################################################################

=head1 NAME

MCE::Channel - Queue-like and two-way communication capability

=head1 VERSION

This document describes MCE::Channel version 1.879

=head1 SYNOPSIS

 use MCE::Channel;

 ########################
 # Construction
 ########################

 # A single producer and many consumers supporting processes and threads

 my $c1 = MCE::Channel->new( impl => 'Mutex' );    # default implementation
 my $c2 = MCE::Channel->new( impl => 'Threads' );  # threads::shared locking

 # Set the mp flag if two or more workers (many producers) will be calling
 # enqueue/send or recv2/recv2_nb on the left end of the channel

 my $c3 = MCE::Channel->new( impl => 'Mutex', mp => 1 );
 my $c4 = MCE::Channel->new( impl => 'Threads', mp => 1 );

 # Tuned for one producer and one consumer, no locking

 my $c5 = MCE::Channel->new( impl => 'Simple' );

 ########################
 # Queue-like behavior
 ########################

 # Send data to consumers
 $c1->enqueue('item');
 $c1->enqueue(qw/item1 item2 item3 itemN/);

 # Receive data
 my $item  = $c1->dequeue();      # item
 my @items = $c1->dequeue(2);     # (item1, item2)

 # Receive, non-blocking
 my $item  = $c1->dequeue_nb();   # item
 my @items = $c1->dequeue_nb(2);  # (item1, item2)

 # Signal that there is no more work to be sent
 $c1->end();

 ########################
 # Two-way communication
 ########################

 # Producer(s) sending data
 $c3->send('message');
 $c3->send(qw/arg1 arg2 arg3/);

 # Consumer(s) receiving data
 my $mesg = $c3->recv();          # message
 my @args = $c3->recv();          # (arg1, arg2, arg3)

 # Alternatively, non-blocking
 my $mesg = $c3->recv_nb();       # message
 my @args = $c3->recv_nb();       # (arg1, arg2, arg3)

 # A producer signaling no more work to be sent
 $c3->end();

 # Consumers(s) sending data
 $c3->send2('message');
 $c3->send2(qw/arg1 arg2 arg3/);

 # Producer(s) receiving data
 my $mesg = $c3->recv2();         # message
 my @args = $c3->recv2();         # (arg1, arg2, arg3)

 # Alternatively, non-blocking
 my $mesg = $c3->recv2_nb();      # message
 my @args = $c3->recv2_nb();      # (arg1, arg2, arg3)

=head1 DESCRIPTION

A MCE::Channel object is a container for sending and receiving data using
socketpair handles. Serialization is provided by L<Sereal> if available.
Defaults to L<Storable> otherwise. Excluding the C<Simple> implementation,
both ends of the C<channel> support many workers concurrently (with mp => 1).

=head2 new ( impl => STRING, mp => BOOLEAN )

This creates a new channel. Three implementations are provided C<Mutex>,
C<Threads>, and C<Simple> indicating the locking mechanism to use
C<MCE::Mutex>, C<threads::shared>, and no locking respectively.

 $chnl = MCE::Channel->new();     # default: impl => 'Mutex', mp => 0
                                  # default: impl => 'Threads' on Windows

The C<Mutex> implementation supports processes and threads whereas the
C<Threads> implementation is suited for Windows and threads only.

 $chnl = MCE::Channel->new( impl => 'Mutex' );    # MCE::Mutex locking
 $chnl = MCE::Channel->new( impl => 'Threads' );  # threads::shared locking

 # on Windows, silently becomes impl => 'Threads' when specifying 'Mutex'

Set the C<mp> (m)any (p)roducers option to a true value if there will be two
or more workers calling C<enqueue>, <send>, C<recv2>, or C<recv2_nb> on the
left end of the channel. This is important to not incur a race condition.

 $chnl = MCE::Channel->new( impl => 'Mutex', mp => 1 );
 $chnl = MCE::Channel->new( impl => 'Threads', mp => 1 );

 # on Windows, silently becomes impl => 'Threads' when specifying 'Mutex'

The C<Simple> implementation is optimized for one producer and one consumer max.
It omits locking for maximum performance. This implementation is preferred for
parent to child communication not shared by another worker.

 $chnl = MCE::Channel->new( impl => 'Simple' );

=head1 QUEUE-LIKE BEHAVIOR

=head2 enqueue ( ITEM1 [, ITEM2, ... ] )

Appends a list of items onto the left end of the channel. This will block once
the internal socket buffer becomes full (i.e. awaiting workers to dequeue on the
other end). This prevents producer(s) from running faster than consumer(s).

Object (de)serialization is handled automatically using L<Sereal> if available
or defaults to L<Storable> otherwise.

 $chnl->enqueue('item1');
 $chnl->enqueue(qw/item2 item3 .../);

 $chnl->enqueue([ array_ref1 ]);
 $chnl->enqueue([ array_ref2 ], [ array_ref3 ], ...);

 $chnl->enqueue({ hash_ref1 });
 $chnl->enqueue({ hash_ref2 }, { hash_ref3 }, ...);

=head2 dequeue

=head2 dequeue ( COUNT )

Removes the requested number of items (default 1) from the right end of the
channel. If the channel contains fewer than the requested number of items,
the method will block (i.e. until other producer(s) enqueue more items).

 $item  = $chnl->dequeue();       # item1
 @items = $chnl->dequeue(2);      # ( item2, item3 )

=head2 dequeue_nb

=head2 dequeue_nb ( COUNT )

Removes the requested number of items (default 1) from the right end of the
channel. If the channel contains fewer than the requested number of items,
the method will return what it was able to retrieve and return immediately.
If the channel is empty, then returns C<an empty list> in list context or
C<undef> in scalar context.

 $item  = $chnl->dequeue_nb();    # array_ref1
 @items = $chnl->dequeue_nb(2);   # ( array_ref2, array_ref3 )

=head2 end

This is called by a producer to signal that there is no more work to be sent.
Once ended, no more items may be sent by the producer. Calling C<end> by
multiple producers is not supported.

 $chnl->end;

=head1 TWO-WAY IPC - PRODUCER TO CONSUMER

=head2 send ( ARG1 [, ARG2, ... ] )

Append data onto the left end of the channel. Unlike C<enqueue>, the values
are kept together for the receiving consumer, similarly to calling a method.
Object (de)serialization is handled automatically.

 $chnl->send('item');
 $chnl->send([ list_ref ]);
 $chnl->send([ hash_ref ]);

 $chnl->send(qw/item1 item2 .../);
 $chnl->send($id, [ list_ref ]);
 $chnl->send($id, { hash_ref });

The fast channel implementations, introduced in MCE 1.877, support one item
for C<send>. If you want to pass multiple arguments, simply join the arguments
into a string. That means the receiver will need to split the string.

 $chnl = MCE::Channel->new(impl => "SimpleFast");

 $chnl->send(join(" ", qw/item1 item2 item3/);
 my ($item1, $item2, $item3) = split " ", $chnl->recv();

=head2 recv

=head2 recv_nb

Blocking and non-blocking fetch methods from the right end of the channel.
For the latter and when the channel is empty, returns C<an empty list> in
list context or C<undef> in scalar context.

 $item      = $chnl->recv();
 $array_ref = $chnl->recv();
 $hash_ref  = $chnl->recv();

 ($item1, $item2)  = $chnl->recv_nb();
 ($id, $array_ref) = $chnl->recv_nb();
 ($id, $hash_ref)  = $chnl->recv_nb();

=head1 TWO-WAY IPC - CONSUMER TO PRODUCER

=head2 send2 ( ARG1 [, ARG2, ... ] )

Append data onto the right end of the channel. Unlike C<enqueue>, the values
are kept together for the receiving producer, similarly to calling a method.
Object (de)serialization is handled automatically.

 $chnl->send2('item');
 $chnl->send2([ list_ref ]);
 $chnl->send2([ hash_ref ]);

 $chnl->send2(qw/item1 item2 .../);
 $chnl->send2($id, [ list_ref ]);
 $chnl->send2($id, { hash_ref });

The fast channel implementations, introduced in MCE 1.877, support one item
for C<send2>. If you want to pass multiple arguments, simply join the arguments
into a string. Not to forget, the receiver must split the string as well.

 $chnl = MCE::Channel->new(impl => "MutexFast");

 $chnl->send2(join(" ", qw/item1 item2 item3/);
 my ($item1, $item2, $item3) = split " ", $chnl->recv();

=head2 recv2

=head2 recv2_nb

Blocking and non-blocking fetch methods from the left end of the channel.
For the latter and when the channel is empty, returns C<an empty list> in
list context or C<undef> in scalar context.

 $item      = $chnl->recv2();
 $array_ref = $chnl->recv2();
 $hash_ref  = $chnl->recv2();

 ($item1, $item2)  = $chnl->recv2_nb();
 ($id, $array_ref) = $chnl->recv2_nb();
 ($id, $hash_ref)  = $chnl->recv2_nb();

=head1 DEMONSTRATIONS

=head2 Example 1 - threads

C<MCE::Channel> was made to work efficiently with L<threads>. The reason
comes from using L<threads::shared> for locking versus L<MCE::Mutex>.

 use strict;
 use warnings;

 use threads;
 use MCE::Channel;

 my $queue = MCE::Channel->new( impl => 'Threads' );
 my $num_consumers = 10;

 sub consumer {
    my $count = 0;

    # receive items
    while ( my ($item1, $item2) = $queue->dequeue(2) ) {
       $count += 2;
    }

    # send result
    $queue->send2( threads->tid => $count );
 }

 threads->create('consumer') for 1 .. $num_consumers;

 ## producer

 $queue->enqueue($_, $_ * 2) for 1 .. 40000;
 $queue->end;

 my %results;
 my $total = 0;

 for ( 1 .. $num_consumers ) {
    my ($id, $count) = $queue->recv2;
    $results{$id} = $count;
    $total += $count;
 }

 $_->join for threads->list;

 print $results{$_}, "\n" for keys %results;
 print "$total total\n\n";

 __END__

 # output

 8034
 8008
 8036
 8058
 7990
 7948
 8068
 7966
 7960
 7932
 80000 total

=head2 Example 2 - MCE::Child

The following is similarly threads-like for Perl lacking threads support.
It spawns processes instead, thus requires the C<Mutex> channel implementation
which is the default if omitted.

 use strict;
 use warnings;

 use MCE::Child;
 use MCE::Channel;

 my $queue = MCE::Channel->new( impl => 'Mutex' );
 my $num_consumers = 10;

 sub consumer {
    my $count = 0;

    # receive items
    while ( my ($item1, $item2) = $queue->dequeue(2) ) {
       $count += 2;
    }

    # send result
    $queue->send2( MCE::Child->pid => $count );
 }

 MCE::Child->create('consumer') for 1 .. $num_consumers;

 ## producer

 $queue->enqueue($_, $_ * 2) for 1 .. 40000;
 $queue->end;

 my %results;
 my $total = 0;

 for ( 1 .. $num_consumers ) {
    my ($id, $count) = $queue->recv2;
    $results{$id} = $count;
    $total += $count;
 }

 $_->join for MCE::Child->list;

 print $results{$_}, "\n" for keys %results;
 print "$total total\n\n";

=head2 Example 3 - Consumer requests item

Like the previous example, but have the manager process await a notification
from the consumer before inserting into the queue. This allows the producer
to end the channel early (i.e. exit loop).

 use strict;
 use warnings;

 use MCE::Child;
 use MCE::Channel;

 my $queue = MCE::Channel->new( impl => 'Mutex' );
 my $num_consumers = 10;

 sub consumer {
    # receive items
    my $count = 0;

    while () {
       # Notify the manager process to send items. This allows the
       # manager process to enqueue only when requested. The benefit
       # is being able to end the channel immediately.

       $queue->send2( MCE::Child->pid ); # channel is bi-directional

       my ($item1, $item2) = $queue->dequeue(2);
       last unless ( defined $item1 );   # channel ended

       $count += 2;
    }

    # result
    return ( MCE::Child->pid => $count );
 }

 MCE::Child->create('consumer') for 1 .. $num_consumers;

 ## producer

 for my $num (1 .. 40000) {
    # Await worker notification before inserting (blocking).
    my $consumer_pid = $queue->recv2;
    $queue->enqueue($num, $num * 2);
 }

 $queue->end;

 my %results;
 my $total = 0;

 for my $child ( MCE::Child->list ) {
    my ($id, $count) = $child->join;
    $results{$id} = $count;
    $total += $count;
 }

 print $results{$_}, "\n" for keys %results;
 print "$total total\n\n";

=head2 Example 4 - Many producers

Running with 2 or more producers requires setting the C<mp> option. Internally,
this enables locking support for the left end of the channel. The C<mp> option
applies to C<Mutex> and C<Threads> channel implementations only.

Here, using the MCE facility for gathering the final count.

 use strict;
 use warnings;

 use MCE::Flow;
 use MCE::Channel;

 my $queue = MCE::Channel->new( impl => 'Mutex', mp => 1 );
 my $num_consumers = 10;

 sub consumer {
    # receive items
    my $count = 0;
    while ( my ( $item1, $item2 ) = $queue->dequeue(2) ) {
       $count += 2;
    }
    # send result
    MCE->gather( MCE->wid => $count );
 }

 sub producer {
    $queue->enqueue($_, $_ * 2) for 1 .. 20000;
 }

 ## run 2 producers and many consumers

 MCE::Flow->init(
    max_workers => [ 2, $num_consumers ],
    task_name   => [ 'producer', 'consumer' ],
    task_end    => sub {
       my ($mce, $task_id, $task_name) = @_;
       if ( $task_name eq 'producer' ) {
          $queue->end;
       }
    }
 );

 # consumers call gather above (i.e. send a key-value pair),
 # have MCE append to a hash

 my %results = mce_flow \&producer, \&consumer;

 MCE::Flow->finish;

 my $total = 0;

 for ( keys %results ) {
    $total += $results{$_};
    print $results{$_}, "\n";
 }

 print "$total total\n\n";

=head2 Example 5 - Many channels

This demonstration configures a channel per consumer. Plus, a common channel
for consumers to request the next input item. The C<Simple> implementation is
specified for the individual channels whereas locking may be necessary for the
C<$ready> channel. However, consumers do not incur reading and what is written
is very small (i.e. atomic write is guaranteed by the OS). Thus, am safely
choosing the C<Simple> implementation versus C<Mutex>.

 use strict;
 use warnings;

 use MCE::Flow;
 use MCE::Channel;

 my $prog_name  = $0; $prog_name =~ s{^.*[\\/]}{}g;
 my $input_size = shift || 3000;

 unless ($input_size =~ /\A\d+\z/) {
    print {*STDERR} "usage: $prog_name [ size ]\n";
    exit 1;
 }

 my $consumers = 4;

 my @chnls = map { MCE::Channel->new( impl => 'Simple' ) } 1 .. $consumers;

 my $ready =       MCE::Channel->new( impl => 'Simple' );

 sub producer {
    my $id = 0;

    # send the next input item upon request
    for ( 0 .. $input_size - 1 ) {
       my $chnl_num = $ready->recv2;
       $chnls[ $chnl_num ]->send( ++$id, $_ );
    }

    # signal no more work
    $_->send( 0, undef ) for @chnls;
 }

 sub consumer {
    my $chnl_num = MCE->task_wid - 1;

    while () {
       # notify the producer ready for input
       $ready->send2( $chnl_num );

       # retrieve input data
       my ( $id, $item ) = $chnls[ $chnl_num ]->recv;

       # leave loop if no more work
       last unless $id;

       # compute and send the result to the manager process
       # ordered output requires an id (must be 1st argument)
       MCE->gather( $id, [ $item, sqrt($item) ] );
    }
 }

 # A custom 'ordered' output iterator for MCE's gather facility.
 # It returns a closure block, expecting an ID for 1st argument.

 sub output_iterator {
    my %tmp; my $order_id = 1;

    return sub {
       my ( $id, $result ) = @_;
       $tmp{ $id } = $result;

       while () {
          last unless exists $tmp{ $order_id };
          $result = delete $tmp{ $order_id };
          printf "n: %d sqrt(n): %f\n", $result->[0], $result->[1];
          $order_id++;
       }
    };
 }

 # Run one producer and many consumers.
 # Output to be sent orderly to STDOUT.

 MCE::Flow->init(
    gather => output_iterator(),
    max_workers => [ 1, $consumers ],
 );

 MCE::Flow->run( \&producer, \&consumer );
 MCE::Flow->finish;

 __END__

 # Output

 n: 0 sqrt(n): 0.000000
 n: 1 sqrt(n): 1.000000
 n: 2 sqrt(n): 1.414214
 n: 3 sqrt(n): 1.732051
 n: 4 sqrt(n): 2.000000
 n: 5 sqrt(n): 2.236068
 n: 6 sqrt(n): 2.449490
 n: 7 sqrt(n): 2.645751
 n: 8 sqrt(n): 2.828427
 n: 9 sqrt(n): 3.000000
 ...

=head1 SEE ALSO

=over 3

=item * L<https://github.com/marioroy/mce-examples/tree/master/chameneos>

=item * L<threads::lite>

=back

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2019-2022 by Mario E. Roy

MCE::Channel is released under the same license as Perl.

See L<https://dev.perl.org/licenses/> for more information.

=cut

