###############################################################################
## ----------------------------------------------------------------------------
## MCE::Mutex::Channel - Mutex locking via a pipe or socket.
##
###############################################################################

package MCE::Mutex::Channel;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized once );

our $VERSION = '1.823';

use base 'MCE::Mutex';
use MCE::Util ();

my $has_threads = $INC{'threads.pm'} ? 1 : 0;
my $tid = $has_threads ? threads->tid()  : 0;

sub CLONE {
    $tid = threads->tid() if $has_threads;
}

sub DESTROY {
    my ($pid, $obj) = ($has_threads ? $$ .'.'. $tid : $$, @_);

    $obj->unlock() if $obj->{ $pid };

    if ($obj->{'_init_pid'} eq $pid) {
        ($^O eq 'MSWin32')
            ? MCE::Util::_destroy_pipes($obj, qw(_w_sock _r_sock))
            : MCE::Util::_destroy_socks($obj, qw(_w_sock _r_sock));
    }

    return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Public methods.
##
###############################################################################

sub new {
    my ($class, %obj) = (@_, impl => 'Channel');
    $obj{'_init_pid'} = $has_threads ? $$ .'.'. $tid : $$;

    ($^O eq 'MSWin32')
        ? MCE::Util::_pipe_pair(\%obj, qw(_r_sock _w_sock))
        : MCE::Util::_sock_pair(\%obj, qw(_r_sock _w_sock));

    1 until syswrite($obj{_w_sock}, '0') || ($! && !$!{'EINTR'});

    return bless(\%obj, $class);
}

sub lock {
    my ($pid, $obj) = ($has_threads ? $$ .'.'. $tid : $$, @_);
    return if $obj->{ $pid };

    1 until sysread($obj->{_r_sock}, my($b), 1) || ($! && !$!{'EINTR'});

    $obj->{ $pid } = 1;

    return;
}

*lock_exclusive = \&lock;
*lock_shared    = \&lock;

sub unlock {
    my ($pid, $obj) = ($has_threads ? $$ .'.'. $tid : $$, @_);
    return unless $obj->{ $pid };

    1 until syswrite($obj->{_w_sock}, '0') || ($! && !$!{'EINTR'});

    $obj->{ $pid } = 0;

    return;
}

sub synchronize {
    my ($pid, $obj, $code, @ret) = (
        $has_threads ? $$ .'.'. $tid : $$, shift, shift
    );
    return unless ref($code) eq 'CODE';

    # lock mutex
    unless ($obj->{ $pid }) {
        1 until sysread($obj->{_r_sock}, my($b), 1) || ($! && !$!{'EINTR'});
        $obj->{ $pid } = 1;
    }

    (defined wantarray) ? @ret = $code->(@_) : $code->(@_);

    # unlock mutex
    1 until syswrite($obj->{_w_sock}, '0') || ($! && !$!{'EINTR'});
    $obj->{ $pid } = 0;

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

This document describes MCE::Mutex::Channel version 1.823

=head1 DESCRIPTION

A pipe-socket implementation for L<MCE::Mutex>. See documentation there.

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

