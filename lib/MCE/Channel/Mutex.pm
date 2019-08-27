###############################################################################
## ----------------------------------------------------------------------------
## Channel for producer(s) and many consumers supporting processes and threads.
##
###############################################################################

package MCE::Channel::Mutex;

use strict;
use warnings;

no warnings qw( uninitialized once );

our $VERSION = '1.846';

use base 'MCE::Channel';
use MCE::Mutex ();
use bytes;

my $is_MSWin32 = ( $^O eq 'MSWin32' ) ? 1 : 0;
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

   if ( caller !~ /^MCE:?/ || caller(1) !~ /^MCE:?/ ) {
      MCE::Mutex::Channel::_save_for_global_destruction($obj{c_mutex});
      MCE::Mutex::Channel::_save_for_global_destruction($obj{p_mutex})
         if $obj{mp};
   }

   return \%obj;
}

###############################################################################
## ----------------------------------------------------------------------------
## Queue-like methods.
##
###############################################################################

sub end {
   my ( $self ) = @_;
   return if $self->{ended};

   MCE::Util::_sock_ready_w( $self->{p_sock} ) if $is_MSWin32;
   print { $self->{p_sock} } pack('i', -1);

   $self->{ended} = 1;
}

sub enqueue {
   my $self = shift;
   return MCE::Channel::_ended('enqueue') if $self->{ended};

   my $p_mutex = $self->{p_mutex};
   $p_mutex->lock2 if $p_mutex;

   MCE::Util::_sock_ready_w( $self->{p_sock} ) if $is_MSWin32;

   while ( @_ ) {
      my $data;
      if ( ref $_[0] || !defined $_[0] ) {
         $data = $freeze->([ shift ]), $data .= '1';
      } else {
         $data = shift, $data .= '0';
      }
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
      MCE::Util::_sock_ready( $self->{c_sock} ) if $is_MSWin32;
      MCE::Util::_sysread( $self->{c_sock}, my($plen), 4 );

      my $len = unpack('i', $plen);
      if ( $len < 0 ) {
         $self->end, $c_mutex->unlock;
         return wantarray ? () : undef;
      }

      MCE::Channel::_read( $self->{c_sock}, my($data), $len );
      $c_mutex->unlock;

      chop( $data )
         ? wantarray ? @{ $thaw->($data) } : ( $thaw->($data) )->[-1]
         : wantarray ? ( $data ) : $data;
   }
   else {
      my ( $plen, @ret );

      ( my $c_mutex = $self->{c_mutex} )->lock;
      MCE::Util::_sock_ready( $self->{c_sock} ) if $is_MSWin32;

      while ( $count-- ) {
         MCE::Util::_sysread( $self->{c_sock}, $plen, 4 );

         my $len = unpack('i', $plen);
         if ( $len < 0 ) {
            $self->end;
            last;
         }

         MCE::Channel::_read( $self->{c_sock}, my($data), $len );
         push @ret, chop($data) ? @{ $thaw->($data) } : $data;
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
      push @ret, chop($data) ? @{ $thaw->($data) } : $data;
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

   my $data;
   if ( @_ > 1 || ref $_[0] || !defined $_[0] ) {
      $data = $freeze->([ @_ ]), $data .= '1';
   } else {
      $data = $_[0], $data .= '0';
   }

   my $p_mutex = $self->{p_mutex};
   $p_mutex->lock2 if $p_mutex;

   MCE::Util::_sock_ready_w( $self->{p_sock} ) if $is_MSWin32;
   print { $self->{p_sock} } pack('i', length $data), $data;

   $p_mutex->unlock2 if $p_mutex;

   return 1;
}

sub recv {
   my ( $self ) = @_;

   ( my $c_mutex = $self->{c_mutex} )->lock;
   MCE::Util::_sock_ready( $self->{c_sock} ) if $is_MSWin32;
   MCE::Util::_sysread( $self->{c_sock}, my($plen), 4 );

   my $len = unpack('i', $plen);
   if ( $len < 0 ) {
      $self->end, $c_mutex->unlock;
      return wantarray ? () : undef;
   }

   MCE::Channel::_read( $self->{c_sock}, my($data), $len );
   $c_mutex->unlock;

   chop( $data )
      ? wantarray ? @{ $thaw->($data) } : ( $thaw->($data) )->[-1]
      : wantarray ? ( $data ) : $data;
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

   chop( $data )
      ? wantarray ? @{ $thaw->($data) } : ( $thaw->($data) )->[-1]
      : wantarray ? ( $data ) : $data;
}

###############################################################################
## ----------------------------------------------------------------------------
## Methods for two-way communication; consumer to producer.
##
###############################################################################

sub send2 {
   my $self = shift;

   my $data;
   if ( @_ > 1 || ref $_[0] || !defined $_[0] ) {
      $data = $freeze->([ @_ ]), $data .= '1';
   } else {
      $data = $_[0], $data .= '0';
   }

   ( my $c_mutex = $self->{c_mutex} )->lock2;
   MCE::Util::_sock_ready_w( $self->{c_sock} ) if $is_MSWin32;
   print { $self->{c_sock} } pack('i', length $data), $data;
   $c_mutex->unlock2;

   return 1;
}

sub recv2 {
   my ( $self ) = @_;
   my ( $plen, $data );

   my $p_mutex = $self->{p_mutex};
   $p_mutex->lock if $p_mutex;

   MCE::Util::_sock_ready( $self->{p_sock} ) if $is_MSWin32;

   ( $p_mutex || $is_MSWin32 )
      ? MCE::Util::_sysread( $self->{p_sock}, $plen, 4 )
      : read( $self->{p_sock}, $plen, 4 );

   my $len = unpack('i', $plen);

   ( $p_mutex || $is_MSWin32 )
      ? MCE::Channel::_read( $self->{p_sock}, $data, $len )
      : read( $self->{p_sock}, $data, $len );

   $p_mutex->unlock if $p_mutex;

   chop( $data )
      ? wantarray ? @{ $thaw->($data) } : ( $thaw->($data) )->[-1]
      : wantarray ? ( $data ) : $data;
}

sub recv2_nb {
   my ( $self ) = @_;
   my ( $plen, $data );

   my $p_mutex = $self->{p_mutex};
   $p_mutex->lock if $p_mutex;

   MCE::Util::_nonblocking( $self->{p_sock}, 1 );

   ( $p_mutex || $is_MSWin32 )
      ? MCE::Util::_sysread( $self->{p_sock}, $plen, 4 )
      : read( $self->{p_sock}, $plen, 4 );

   MCE::Util::_nonblocking( $self->{p_sock}, 0 );

   my $len; $len = unpack('i', $plen) if $plen;
   if ( !$len ) {
      $p_mutex->unlock if $p_mutex;
      return wantarray ? () : undef;
   }

   ( $p_mutex || $is_MSWin32 )
      ? MCE::Channel::_read( $self->{p_sock}, $data, $len )
      : read( $self->{p_sock}, $data, $len );

   $p_mutex->unlock if $p_mutex;

   chop( $data )
      ? wantarray ? @{ $thaw->($data) } : ( $thaw->($data) )->[-1]
      : wantarray ? ( $data ) : $data;
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

This document describes MCE::Channel::Mutex version 1.846

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

