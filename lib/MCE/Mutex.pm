###############################################################################
## ----------------------------------------------------------------------------
## Locking for Many-Core Engine.
##
###############################################################################

package MCE::Mutex;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized );

our $VERSION = '1.879';

## no critic (BuiltinFunctions::ProhibitStringyEval)
## no critic (TestingAndDebugging::ProhibitNoStrict)

use Carp ();

## global Mutex used by MCE, MCE::Child, and MCE::Hobo inside threads
## on UNIX platforms

if ( $INC{'threads.pm'} && $^O !~ /mswin|mingw|msys|cygwin/i ) {
    $MCE::_GMUTEX = MCE::Mutex->new( impl => 'Channel' );
    MCE::Mutex::Channel::_save_for_global_cleanup($MCE::_GMUTEX);
}

sub new {
    my ($class, %argv) = @_;
    my $impl = defined($argv{'impl'})
        ? $argv{'impl'} : defined($argv{'path'}) ? 'Flock' : 'Channel';

    $impl = ucfirst( lc $impl );

    eval "require MCE::Mutex::$impl; 1;" ||
        Carp::croak("Could not load Mutex implementation '$impl': $@");

    my $pkg = 'MCE::Mutex::'.$impl;
    no strict 'refs';

    return $pkg->new( %argv );
}

## base class methods

sub impl {
    return $_[0]->{'impl'} || 'Not defined';
}

sub timedwait {
    my ($obj, $timeout) = @_;

    local $@; local $SIG{'ALRM'} = sub { alarm 0; die "timed out\n" };

    eval { alarm $timeout || 1; $obj->lock_exclusive; };

    alarm 0;

    ( $@ && $@ eq "timed out\n" ) ? '' : 1;
}

1;

__END__

###############################################################################
## ----------------------------------------------------------------------------
## Module usage.
##
###############################################################################

=head1 NAME

MCE::Mutex - Locking for Many-Core Engine

=head1 VERSION

This document describes MCE::Mutex version 1.879

=head1 SYNOPSIS

 use MCE::Mutex;

 my $mutex = MCE::Mutex->new;

 {
     use MCE::Flow max_workers => 4;

     mce_flow sub {
         $mutex->lock;

         # access shared resource
         my $wid = MCE->wid; MCE->say($wid); sleep 1;

         $mutex->unlock;
     };
 }

 {
     use MCE::Hobo;

     MCE::Hobo->create('work', $_) for 1..4;
     MCE::Hobo->waitall;
 }

 {
     use threads;

     threads->create('work', $_)   for 5..8;
     $_->join for ( threads->list );
 }

 sub work {
     my ($id) = @_;
     $mutex->lock;

     # access shared resource
     print $id, "\n";
     sleep 1;

     $mutex->unlock;
 }

=head1 DESCRIPTION

This module implements locking methods that can be used to coordinate access
to shared data from multiple workers spawned as processes or threads.

The inspiration for this module came from reading Mutex for Ruby.

=head1 API DOCUMENTATION

=head2 MCE::Mutex->new ( )

=head2 MCE::Mutex->new ( impl => "Channel" )

=head2 MCE::Mutex->new ( impl => "Flock", [ path => "/tmp/file.lock" ] )

=head2 MCE::Mutex->new ( path => "/tmp/file.lock" )

Creates a new mutex.

Channel locking (the default), unless C<path> is given, is through a pipe
or socket depending on the platform. The advantage of channel locking is
not having to re-establish handles inside new processes and threads.

For Fcntl-based locking, it is the responsibility of the caller to remove
the C<tempfile>, associated with the mutex, when path is given. Otherwise,
it establishes a C<tempfile> internally including removal on scope exit.

=head2 $mutex->impl ( void )

Returns the implementation used for the mutex.

 $m1 = MCE::Mutex->new( );
 $m1->impl();   # Channel

 $m2 = MCE::Mutex->new( path => /tmp/my.lock );
 $m2->impl();   # Flock

 $m3 = MCE::Mutex->new( impl => "Channel" );
 $m3->impl();   # Channel

 $m4 = MCE::Mutex->new( impl => "Flock" );
 $m4->impl();   # Flock

Current API available since 1.822.

=head2 $mutex->lock ( void )

=head2 $mutex->lock_exclusive ( void )

Attempts to grab an exclusive lock and waits if not available. Multiple calls
to mutex->lock by the same process or thread is safe. The mutex will remain
locked until mutex->unlock is called.

The method C<lock_exclusive> is an alias for C<lock>, available since 1.822.

 ( my $mutex = MCE::Mutex->new( path => $0 ) )->lock_exclusive;

=head2 $mutex->lock_shared ( void )

Like C<lock_exclusive>, but attempts to grab a shared lock instead.
The C<lock_shared> method is an alias to C<lock> otherwise for non-Fcntl
implementations.

Current API available since 1.822.

=head2 $mutex->unlock ( void )

Releases the lock. A held lock by an exiting process or thread is released
automatically.

=head2 $mutex->synchronize ( sub { ... }, @_ )

=head2 $mutex->enter ( sub { ... }, @_ )

Obtains a lock, runs the code block, and releases the lock after the block
completes. Optionally, the method is C<wantarray> aware.

 my $val = $mutex->synchronize( sub {
     # access shared resource
     return 'scalar';
 });

 my @ret = $mutex->enter( sub {
     # access shared resource
     return @list;
 });

The method C<enter> is an alias for C<synchronize>, available since 1.822.

=head2 $mutex->timedwait ( timeout )

Blocks until obtaining an exclusive lock. A false value is returned
if the timeout is reached, and a true value otherwise. The default is
1 second when omitting timeout.

 my $mutex = MCE::Mutex->new( path => $0 );

 # terminate script if a previous instance is still running

 exit unless $mutex->timedwait( 2 );

 ...

Current API available since 1.822.

=head1 INDEX

L<MCE|MCE>, L<MCE::Core>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

