###############################################################################
## ----------------------------------------------------------------------------
## Channel for producer(s) and many consumers supporting processes and threads.
##
###############################################################################

package MCE::Channel::Mutex;

use strict;
use warnings;

no warnings qw( uninitialized once );

our $VERSION = '1.879';

use base 'MCE::Channel';
use MCE::Mutex ();

my $LF = "\012"; Internals::SvREADONLY($LF, 1);
my $freeze     = MCE::Channel::_get_freeze();
my $thaw       = MCE::Channel::_get_thaw();

sub new {
   my ( $class, %obj ) = ( @_, impl => 'Mutex' );

   $obj{init_pid} = MCE::Channel::_pid();
   MCE::Util::_sock_pair( \%obj, 'p_sock', 'c_sock' );

   # locking for the consumer side of the channel
   $obj{c_mutex} = MCE::Mutex->new( impl => 'Channel2' );

   # optionally, support many-producers writing and reading
   $obj{p_mutex} = MCE::Mutex->new( impl => 'Channel2' ) if $obj{mp};

   bless \%obj, $class;

   MCE::Mutex::Channel::_save_for_global_cleanup($obj{c_mutex});
   MCE::Mutex::Channel::_save_for_global_cleanup($obj{p_mutex}) if $obj{mp};

   return \%obj;
}

END {
   MCE::Child->finish('MCE') if $INC{'MCE/Child.pm'};
}

###############################################################################
## ----------------------------------------------------------------------------
## Queue-like methods.
##
###############################################################################

sub end {
   my ( $self ) = @_;

   local $\ = undef if (defined $\);
   print { $self->{p_sock} } pack('i', -1);

   $self->{ended} = 1;
}

sub enqueue {
   my $self = shift;
   return MCE::Channel::_ended('enqueue') if $self->{ended};

   local $\ = undef if (defined $\);
   my $p_mutex = $self->{p_mutex};
   $p_mutex->lock2 if $p_mutex;

   while ( @_ ) {
      my $data = $freeze->([ shift ]);
      print { $self->{p_sock} } pack('i', length $data), $data;
   }

   $p_mutex->unlock2 if $p_mutex;

   return 1;
}

sub dequeue {
   my ( $self, $count ) = @_;
   $count = 1 if ( !$count || $count < 1 );

   if ( $count == 1 ) {
      ( my $c_mutex = $self->{c_mutex} )->lock;
      MCE::Util::_sysread( $self->{c_sock}, my($plen), 4 );

      my $len = unpack('i', $plen);
      if ( $len < 0 ) {
         $self->end, $c_mutex->unlock;
         return wantarray ? () : undef;
      }

      MCE::Channel::_read( $self->{c_sock}, my($data), $len );
      $c_mutex->unlock;

      wantarray ? @{ $thaw->($data) } : ( $thaw->($data) )->[-1];
   }
   else {
      my ( $plen, @ret );

      ( my $c_mutex = $self->{c_mutex} )->lock;

      while ( $count-- ) {
         MCE::Util::_sysread( $self->{c_sock}, $plen, 4 );

         my $len = unpack('i', $plen);
         if ( $len < 0 ) {
            $self->end;
            last;
         }

         MCE::Channel::_read( $self->{c_sock}, my($data), $len );
         push @ret, @{ $thaw->($data) };
      }

      $c_mutex->unlock;

      wantarray ? @ret : $ret[-1];
   }
}

sub dequeue_nb {
   my ( $self, $count ) = @_;
   $count = 1 if ( !$count || $count < 1 );

   my ( $plen, @ret );
   ( my $c_mutex = $self->{c_mutex} )->lock;

   while ( $count-- ) {
      MCE::Util::_nonblocking( $self->{c_sock}, 1 );
      MCE::Util::_sysread( $self->{c_sock}, $plen, 4 );
      MCE::Util::_nonblocking( $self->{c_sock}, 0 );

      my $len; $len = unpack('i', $plen) if $plen;
      if ( !$len || $len < 0 ) {
         $self->end if defined $len && $len < 0;
         last;
      }

      MCE::Channel::_read( $self->{c_sock}, my($data), $len );
      push @ret, @{ $thaw->($data) };
   }

   $c_mutex->unlock;

   wantarray ? @ret : $ret[-1];
}

###############################################################################
## ----------------------------------------------------------------------------
## Methods for two-way communication; producer to consumer.
##
###############################################################################

sub send {
   my $self = shift;
   return MCE::Channel::_ended('send') if $self->{ended};

   my $data = $freeze->([ @_ ]);

   local $\ = undef if (defined $\);
   my $p_mutex = $self->{p_mutex};
   $p_mutex->lock2 if $p_mutex;

   print { $self->{p_sock} } pack('i', length $data), $data;
   $p_mutex->unlock2 if $p_mutex;

   return 1;
}

sub recv {
   my ( $self ) = @_;

   ( my $c_mutex = $self->{c_mutex} )->lock;
   MCE::Util::_sysread( $self->{c_sock}, my($plen), 4 );

   my $len = unpack('i', $plen);
   if ( $len < 0 ) {
      $self->end, $c_mutex->unlock;
      return wantarray ? () : undef;
   }

   MCE::Channel::_read( $self->{c_sock}, my($data), $len );
   $c_mutex->unlock;

   wantarray ? @{ $thaw->($data) } : ( $thaw->($data) )->[-1];
}

sub recv_nb {
   my ( $self ) = @_;

   ( my $c_mutex = $self->{c_mutex} )->lock;
   MCE::Util::_nonblocking( $self->{c_sock}, 1 );
   MCE::Util::_sysread( $self->{c_sock}, my($plen), 4 );
   MCE::Util::_nonblocking( $self->{c_sock}, 0 );

   my $len; $len = unpack('i', $plen) if $plen;
   if ( !$len || $len < 0 ) {
      $self->end if defined $len && $len < 0;
      $c_mutex->unlock;
      return wantarray ? () : undef;
   }

   MCE::Channel::_read( $self->{c_sock}, my($data), $len );
   $c_mutex->unlock;

   wantarray ? @{ $thaw->($data) } : ( $thaw->($data) )->[-1];
}

###############################################################################
## ----------------------------------------------------------------------------
## Methods for two-way communication; consumer to producer.
##
###############################################################################

sub send2 {
   my $self = shift;
   my $data = $freeze->([ @_ ]);

   local $\ = undef if (defined $\);
   local $MCE::Signal::SIG;

   {
      local $MCE::Signal::IPC = 1;
      ( my $c_mutex = $self->{c_mutex} )->lock2;

      print { $self->{c_sock} } pack('i', length $data), $data;
      $c_mutex->unlock2;
   }

   CORE::kill($MCE::Signal::SIG, $$) if $MCE::Signal::SIG;

   return 1;
}

sub recv2 {
   my ( $self ) = @_;
   my ( $plen, $data );

   local $/ = $LF if ( $/ ne $LF );
   my $p_mutex = $self->{p_mutex};
   $p_mutex->lock if $p_mutex;

   ( $p_mutex )
      ? MCE::Util::_sysread( $self->{p_sock}, $plen, 4 )
      : read( $self->{p_sock}, $plen, 4 );

   my $len = unpack('i', $plen);

   ( $p_mutex )
      ? MCE::Channel::_read( $self->{p_sock}, $data, $len )
      : read( $self->{p_sock}, $data, $len );

   $p_mutex->unlock if $p_mutex;

   wantarray ? @{ $thaw->($data) } : ( $thaw->($data) )->[-1];
}

sub recv2_nb {
   my ( $self ) = @_;
   my ( $plen, $data );

   local $/ = $LF if ( $/ ne $LF );
   my $p_mutex = $self->{p_mutex};
   $p_mutex->lock if $p_mutex;

   MCE::Util::_nonblocking( $self->{p_sock}, 1 );

   ( $p_mutex )
      ? MCE::Util::_sysread( $self->{p_sock}, $plen, 4 )
      : read( $self->{p_sock}, $plen, 4 );

   MCE::Util::_nonblocking( $self->{p_sock}, 0 );

   my $len; $len = unpack('i', $plen) if $plen;
   if ( !$len ) {
      $p_mutex->unlock if $p_mutex;
      return wantarray ? () : undef;
   }

   ( $p_mutex )
      ? MCE::Channel::_read( $self->{p_sock}, $data, $len )
      : read( $self->{p_sock}, $data, $len );

   $p_mutex->unlock if $p_mutex;

   wantarray ? @{ $thaw->($data) } : ( $thaw->($data) )->[-1];
}

1;

__END__

###############################################################################
## ----------------------------------------------------------------------------
## Module usage.
##
###############################################################################

=head1 NAME

MCE::Channel::Mutex - Channel for producer(s) and many consumers

=head1 VERSION

This document describes MCE::Channel::Mutex version 1.879

=head1 DESCRIPTION

A channel class providing queue-like and two-way communication
for processes and threads. Locking is handled using MCE::Mutex.

The API is described in L<MCE::Channel>.

=over 3

=item new

 use MCE::Channel;

 # The default is tuned for one producer and many consumers.
 my $chnl_a = MCE::Channel->new( impl => 'Mutex' );

 # Specify the 'mp' option for safe use by two or more producers
 # sending or recieving on the left side of the channel (i.e.
 # ->enqueue/->send or ->recv2/->recv2_nb).

 my $chnl_b = MCE::Channel->new( impl => 'Mutex', mp => 1 );

=back

=head1 QUEUE-LIKE BEHAVIOR

=over 3

=item enqueue

=item dequeue

=item dequeue_nb

=item end

=back

=head1 TWO-WAY IPC - PRODUCER TO CONSUMER

=over 3

=item send

=item recv

=item recv_nb

=back

=head1 TWO-WAY IPC - CONSUMER TO PRODUCER

=over 3

=item send2

=item recv2

=item recv2_nb

=back

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

