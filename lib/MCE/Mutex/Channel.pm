###############################################################################
## ----------------------------------------------------------------------------
## MCE::Mutex::Channel - Mutex locking via a pipe or socket.
##
###############################################################################

package MCE::Mutex::Channel;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized once );

our $VERSION = '1.879';

use base 'MCE::Mutex';
use Scalar::Util qw(weaken);
use MCE::Util ();

my $tid = $INC{'threads.pm'} ? threads->tid() : 0;

sub CLONE {
    $tid = threads->tid() if $INC{'threads.pm'};
}

sub DESTROY {
    my ($pid, $obj) = ($tid ? $$ .'.'. $tid : $$, @_);

    syswrite($obj->{_w_sock}, '0'), $obj->{$pid    } = 0 if $obj->{$pid    };
    syswrite($obj->{_r_sock}, '0'), $obj->{$pid.'b'} = 0 if $obj->{$pid.'b'};

    if ( $obj->{_init_pid} eq $pid ) {
        ($^O eq 'MSWin32' && $obj->{impl} eq 'Channel')
            ? MCE::Util::_destroy_pipes($obj, qw(_w_sock _r_sock))
            : MCE::Util::_destroy_socks($obj, qw(_w_sock _r_sock));
    }

    return;
}

my @mutex;

sub _destroy {
    my $pid = $tid ? $$ .'.'. $tid : $$;

    # Called by { MCE, MCE::Child, and MCE::Hobo }::_exit
    for my $i ( 0 .. @mutex - 1 ) {
        syswrite($mutex[$i]->{_w_sock}, '0'), $mutex[$i]->{$pid} = 0
            if ( $mutex[$i]->{$pid} );
        syswrite($mutex[$i]->{_r_sock}, '0'), $mutex[$i]->{$pid.'b'} = 0
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
    $obj{'_init_pid'} = $tid ? $$ .'.'. $tid : $$;

    ($^O eq 'MSWin32')
        ? MCE::Util::_pipe_pair(\%obj, qw(_r_sock _w_sock))
        : MCE::Util::_sock_pair(\%obj, qw(_r_sock _w_sock), undef, 1);

    syswrite $obj{_w_sock}, '0';

    bless \%obj, $class;

    if ( caller !~ /^MCE:?/ || caller(1) !~ /^MCE:?/ ) {
        MCE::Mutex::Channel::_save_for_global_cleanup(\%obj);
    }

    return \%obj;
}

sub lock {
    my ($pid, $obj) = ($tid ? $$ .'.'. $tid : $$, shift);

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
    MCE::Util::_sysread($obj->{_r_sock}, $b, 1), $obj->{ $pid } = 1
        unless $obj->{ $pid };

    (defined wantarray)
      ? @ret = wantarray ? $code->(@_) : scalar $code->(@_)
      : $code->(@_);

    CORE::syswrite($obj->{_w_sock}, '0'), $obj->{ $pid } = 0;

    return wantarray ? @ret : $ret[-1];
}

*enter = \&synchronize;

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

This document describes MCE::Mutex::Channel version 1.879

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

