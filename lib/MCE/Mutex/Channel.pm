###############################################################################
## ----------------------------------------------------------------------------
## MCE::Mutex::Channel - Mutex locking via a pipe or socket.
##
###############################################################################

package MCE::Mutex::Channel;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized once );

our $VERSION = '1.884';

use base 'MCE::Mutex';
use MCE::Util ();
use Scalar::Util qw(looks_like_number weaken);
use Time::HiRes 'alarm';

my $is_MSWin32 = ($^O eq 'MSWin32') ? 1 : 0;
my $use_pipe = ($^O !~ /mswin|mingw|msys|cygwin/i && $] gt '5.010000');
my $tid = $INC{'threads.pm'} ? threads->tid : 0;

sub CLONE {
    $tid = threads->tid if $INC{'threads.pm'};
}

sub DESTROY {
    my ($pid, $obj) = ($tid ? $$ .'.'. $tid : $$, @_);

    CORE::syswrite($obj->{_w_sock}, '0'), $obj->{$pid    } = 0 if $obj->{$pid    };
    CORE::syswrite($obj->{_r_sock}, '0'), $obj->{$pid.'b'} = 0 if $obj->{$pid.'b'};

    if ( $obj->{_init_pid} eq $pid ) {
        (!$use_pipe || $obj->{impl} eq 'Channel2')
            ? MCE::Util::_destroy_socks($obj, qw(_w_sock _r_sock))
            : MCE::Util::_destroy_pipes($obj, qw(_w_sock _r_sock));
    }

    return;
}

my @mutex;

sub _destroy {
    my $pid = $tid ? $$ .'.'. $tid : $$;

    # Called by { MCE, MCE::Child, and MCE::Hobo }::_exit
    for my $i ( 0 .. @mutex - 1 ) {
        CORE::syswrite($mutex[$i]->{_w_sock}, '0'), $mutex[$i]->{$pid} = 0
            if ( $mutex[$i]->{$pid} );
        CORE::syswrite($mutex[$i]->{_r_sock}, '0'), $mutex[$i]->{$pid.'b'} = 0
            if ( $mutex[$i]->{$pid.'b'} );
    }
}

sub _save_for_global_cleanup {
    push(@mutex, $_[0]), weaken($mutex[-1]);
}

###############################################################################
## ----------------------------------------------------------------------------
## Public methods.
##
###############################################################################

sub new {
    my ($class, %obj) = (@_, impl => 'Channel');
    $obj{_init_pid} = $tid ? $$ .'.'. $tid : $$;

    $use_pipe
        ? MCE::Util::_pipe_pair(\%obj, qw(_r_sock _w_sock))
        : MCE::Util::_sock_pair(\%obj, qw(_r_sock _w_sock));

    CORE::syswrite($obj{_w_sock}, '0');
    bless \%obj, $class;

    if ( caller !~ /^MCE:?/ || caller(1) !~ /^MCE:?/ ) {
        MCE::Mutex::Channel::_save_for_global_cleanup(\%obj);
    }

    return \%obj;
}

sub lock {
    my ($pid, $obj) = ($tid ? $$ .'.'. $tid : $$, shift);

    MCE::Util::_sock_ready($obj->{_r_sock}) if $is_MSWin32;
    MCE::Util::_sysread($obj->{_r_sock}, my($b), 1), $obj->{ $pid } = 1
        unless $obj->{ $pid };

    return;
}

*lock_exclusive = \&lock;
*lock_shared    = \&lock;

sub unlock {
    my ($pid, $obj) = ($tid ? $$ .'.'. $tid : $$, shift);

    CORE::syswrite($obj->{_w_sock}, '0'), $obj->{ $pid } = 0
        if $obj->{ $pid };

    return;
}

sub synchronize {
    my ($pid, $obj, $code) = ($tid ? $$ .'.'. $tid : $$, shift, shift);
    my (@ret, $b);

    return unless ref($code) eq 'CODE';

    # lock, run, unlock - inlined for performance
    MCE::Util::_sock_ready($obj->{_r_sock}) if $is_MSWin32;
    MCE::Util::_sysread($obj->{_r_sock}, $b, 1), $obj->{ $pid } = 1
        unless $obj->{ $pid };

    (defined wantarray)
      ? @ret = wantarray ? $code->(@_) : scalar $code->(@_)
      : $code->(@_);

    CORE::syswrite($obj->{_w_sock}, '0'), $obj->{ $pid } = 0;

    return wantarray ? @ret : $ret[-1];
}

*enter = \&synchronize;

sub timedwait {
    my ($obj, $timeout) = @_;

    $timeout = 1 unless defined $timeout;
    Carp::croak('MCE::Mutex::Channel: timedwait (timeout) is not valid')
        if (!looks_like_number($timeout) || $timeout < 0);

    $timeout = 0.0003 if $timeout < 0.0003;
    local $@; my $ret = '';

    eval {
        local $SIG{ALRM} = sub { alarm 0; die "alarm clock restart\n" };
        alarm $timeout unless $is_MSWin32;

        die "alarm clock restart\n"
            if $is_MSWin32 && MCE::Util::_sock_ready($obj->{_r_sock}, $timeout);

        (!$is_MSWin32)
            ? ($obj->lock_exclusive, $ret = 1, alarm(0))
            : ($obj->lock_exclusive, $ret = 1);
    };

    alarm 0 unless $is_MSWin32;

    $ret;
}

1;

__END__

###############################################################################
## ----------------------------------------------------------------------------
## Module usage.
##
###############################################################################

=head1 NAME

MCE::Mutex::Channel - Mutex locking via a pipe or socket

=head1 VERSION

This document describes MCE::Mutex::Channel version 1.884

=head1 DESCRIPTION

A pipe-socket implementation for C<MCE::Mutex>.

The API is described in L<MCE::Mutex>.

=over 3

=item new

=item lock

=item lock_exclusive

=item lock_shared

=item unlock

=item synchronize

=item enter

=item timedwait

=back

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

