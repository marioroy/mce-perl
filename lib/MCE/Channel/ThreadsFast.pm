###############################################################################
## ----------------------------------------------------------------------------
## Channel for producer(s) and many consumers supporting threads only.
##
###############################################################################

package MCE::Channel::ThreadsFast;

use strict;
use warnings;

no warnings qw( uninitialized once );

our $VERSION = '1.879';

use threads;
use threads::shared;

use base 'MCE::Channel';

my $LF = "\012"; Internals::SvREADONLY($LF, 1);
my $is_MSWin32 = ( $^O eq 'MSWin32' ) ? 1 : 0;

sub new {
   my ( $class, %obj ) = ( @_, impl => 'ThreadsFast' );

   $obj{init_pid} = MCE::Channel::_pid();
   MCE::Util::_sock_pair( \%obj, 'p_sock', 'c_sock' );
   MCE::Util::_sock_pair( \%obj, 'p2_sock', 'c2_sock' ) if $is_MSWin32;

   # locking for the consumer side of the channel
   $obj{cr_mutex} = threads::shared::share( my $cr_mutex );
   $obj{cw_mutex} = threads::shared::share( my $cw_mutex );

   # optionally, support many-producers writing and reading
   $obj{pr_mutex} = threads::shared::share( my $pr_mutex ) if $obj{mp};
   $obj{pw_mutex} = threads::shared::share( my $pw_mutex ) if $obj{mp};

   return bless \%obj, $class;
}

###############################################################################
## ----------------------------------------------------------------------------
## Queue-like methods.
##
###############################################################################

sub end {
   my ( $self ) = @_;

   local $\ = undef if (defined $\);
   MCE::Util::_sock_ready_w( $self->{p_sock} ) if $is_MSWin32;
   print { $self->{p_sock} } pack('i', -1);

   $self->{ended} = 1;
}

sub enqueue {
   my $self = shift;
   return MCE::Channel::_ended('enqueue') if $self->{ended};

   local $\ = undef if (defined $\);

   {
      CORE::lock $self->{pw_mutex} if $self->{pw_mutex};
      MCE::Util::_sock_ready_w( $self->{p_sock} ) if $is_MSWin32;

      while ( @_ ) {
         my $data = ''.shift;
         print { $self->{p_sock} } pack('i', length $data), $data;
      }
   }

   return 1;
}

sub dequeue {
   my ( $self, $count ) = @_;
   $count = 1 if ( !$count || $count < 1 );

   if ( $count == 1 ) {
      my ( $plen, $data );

      {
         CORE::lock $self->{cr_mutex};
         MCE::Util::_sock_ready( $self->{c_sock} ) if $is_MSWin32;
         MCE::Util::_sysread( $self->{c_sock}, $plen, 4 );

         my $len = unpack('i', $plen);
         if ( $len < 0 ) {
            $self->end;
            return wantarray ? () : undef;
         }

         return '' unless $len;
         MCE::Channel::_read( $self->{c_sock}, $data, $len );
      }

      $data;
   }
   else {
      my ( $plen, @ret );

      {
         CORE::lock $self->{cr_mutex};
         MCE::Util::_sock_ready( $self->{c_sock} ) if $is_MSWin32;

         while ( $count-- ) {
            MCE::Util::_sysread( $self->{c_sock}, $plen, 4 );

            my $len = unpack('i', $plen);
            if ( $len < 0 ) {
               $self->end;
               last;
            }

            push(@ret, ''), next unless $len;
            MCE::Channel::_read( $self->{c_sock}, my($data), $len );
            push @ret, $data;
         }
      }

      wantarray ? @ret : $ret[-1];
   }
}

sub dequeue_nb {
   my ( $self, $count ) = @_;
   $count = 1 if ( !$count || $count < 1 );

   my ( $plen, @ret );

   {
      CORE::lock $self->{cr_mutex};

      while ( $count-- ) {
         MCE::Util::_nonblocking( $self->{c_sock}, 1 );
         MCE::Util::_sysread( $self->{c_sock}, $plen, 4 );
         MCE::Util::_nonblocking( $self->{c_sock}, 0 );

         my $len; $len = unpack('i', $plen) if $plen;
         if ( !$len || $len < 0 ) {
            $self->end    if defined $len && $len < 0;
            push @ret, '' if defined $len && $len == 0;
            last;
         }

         MCE::Channel::_read( $self->{c_sock}, my($data), $len );
         push @ret, $data;
      }
   }

   wantarray ? @ret : $ret[-1];
}

###############################################################################
## ----------------------------------------------------------------------------
## Methods for two-way communication; producer(s) to consumers.
##
###############################################################################

sub send {
   my $self = shift;
   return MCE::Channel::_ended('send') if $self->{ended};

   my $data = ''.shift;

   local $\ = undef if (defined $\);

   {
      CORE::lock $self->{pw_mutex} if $self->{pw_mutex};
      MCE::Util::_sock_ready_w( $self->{p_sock} ) if $is_MSWin32;
      print { $self->{p_sock} } pack('i', length $data), $data;
   }

   return 1;
}

sub recv {
   my ( $self ) = @_;
   my ( $plen, $data );

   {
      CORE::lock $self->{cr_mutex};
      MCE::Util::_sock_ready( $self->{c_sock} ) if $is_MSWin32;
      MCE::Util::_sysread( $self->{c_sock}, $plen, 4 );

      my $len = unpack('i', $plen);
      if ( $len < 0 ) {
         $self->end;
         return wantarray ? () : undef;
      }

      return '' unless $len;

      MCE::Channel::_read( $self->{c_sock}, $data, $len );
   }

   $data;
}

sub recv_nb {
   my ( $self ) = @_;
   my ( $plen, $data );

   {
      CORE::lock $self->{cr_mutex};
      MCE::Util::_nonblocking( $self->{c_sock}, 1 );
      MCE::Util::_sysread( $self->{c_sock}, $plen, 4 );
      MCE::Util::_nonblocking( $self->{c_sock}, 0 );

      my $len; $len = unpack('i', $plen) if $plen;
      if ( !$len || $len < 0 ) {
         $self->end if defined $len && $len < 0;
         return ''  if defined $len && $len == 0;
         return wantarray ? () : undef;
      }

      MCE::Channel::_read( $self->{c_sock}, $data, $len );
   }

   $data;
}

###############################################################################
## ----------------------------------------------------------------------------
## Methods for two-way communication; consumers to producer(s).
##
###############################################################################

sub send2 {
   my $self = shift;
   my $data = ''.shift;

   local $\ = undef if (defined $\);
   local $MCE::Signal::SIG;

   {
      my $c_sock = $self->{c2_sock} || $self->{c_sock};

      local $MCE::Signal::IPC = 1;
      CORE::lock $self->{cw_mutex};

      MCE::Util::_sock_ready_w( $c_sock ) if $is_MSWin32;
      print { $c_sock } pack('i', length $data), $data;
   }

   CORE::kill($MCE::Signal::SIG, $$) if $MCE::Signal::SIG;

   return 1;
}

sub recv2 {
   my ( $self ) = @_;
   my ( $plen, $data );

   local $/ = $LF if ( $/ ne $LF );

   {
      my $p_sock   = $self->{p2_sock} || $self->{p_sock};
      my $pr_mutex = $self->{pr_mutex};

      CORE::lock $pr_mutex if $pr_mutex;
      MCE::Util::_sock_ready( $p_sock ) if $is_MSWin32;

      ( $pr_mutex || $is_MSWin32 )
         ? MCE::Util::_sysread( $p_sock, $plen, 4 )
         : read( $p_sock, $plen, 4 );

      my $len = unpack('i', $plen);
      return '' unless $len;

      ( $pr_mutex || $is_MSWin32 )
         ? MCE::Channel::_read( $p_sock, $data, $len )
         : read( $p_sock, $data, $len );
   }

   $data;
}

sub recv2_nb {
   my ( $self ) = @_;
   my ( $plen, $data );

   local $/ = $LF if ( $/ ne $LF );

   {
      my $p_sock   = $self->{p2_sock} || $self->{p_sock};
      my $pr_mutex = $self->{pr_mutex};

      CORE::lock $pr_mutex if $pr_mutex;
      MCE::Util::_nonblocking( $p_sock, 1 );

      ( $pr_mutex || $is_MSWin32 )
         ? MCE::Util::_sysread( $p_sock, $plen, 4 )
         : read( $p_sock, $plen, 4 );

      MCE::Util::_nonblocking( $p_sock, 0 );

      my $len; $len = unpack('i', $plen) if $plen;

      return '' if defined $len && $len == 0;
      return wantarray ? () : undef unless $len;

      ( $pr_mutex || $is_MSWin32 )
         ? MCE::Channel::_read( $p_sock, $data, $len )
         : read( $p_sock, $data, $len );
   }

   $data;
}

1;

__END__

###############################################################################
## ----------------------------------------------------------------------------
## Module usage.
##
###############################################################################

=head1 NAME

MCE::Channel::ThreadsFast - Fast channel for producer(s) and many consumers

=head1 VERSION

This document describes MCE::Channel::ThreadsFast version 1.879

=head1 DESCRIPTION

A channel class providing queue-like and two-way communication
for threads only. Locking is handled using threads::shared.

This is similar to L<MCE::Channel::Threads> but optimized for
non-Unicode strings only. The main difference is that this module
lacks freeze-thaw serialization. Non-string arguments become
stringified; i.e. numbers and undef.

The API is described in L<MCE::Channel> with the sole difference
being C<send> and C<send2> handle one argument.

Current module available since MCE 1.877.

=over 3

=item new

 use MCE::Channel;

 # The default is tuned for one producer and many consumers.
 my $chnl_a = MCE::Channel->new( impl => 'ThreadsFast' );

 # Specify the 'mp' option for safe use by two or more producers
 # sending or recieving on the left side of the channel (i.e.
 # ->enqueue/->send or ->recv2/->recv2_nb).

 my $chnl_b = MCE::Channel->new( impl => 'ThreadsFast', mp => 1 );

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

=head1 LIMITATIONS

The t/04_channel_threads tests are disabled on Unix platforms for Perl
less than 5.10.1. Basically, the MCE::Channel::ThreadsFast implementation
is not supported on older Perls unless the OS vendor applied upstream
patches (i.e. works on RedHat/CentOS 5.x running Perl 5.8.x).

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

