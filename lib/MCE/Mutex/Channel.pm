###############################################################################
## ----------------------------------------------------------------------------
## MCE::Mutex::Channel - Mutex locking via a pipe or socket.
##
###############################################################################

package MCE::Mutex::Channel;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized once );

our $VERSION = '1.840';

use base 'MCE::Mutex';
use Scalar::Util qw(refaddr weaken);
use MCE::Util ();

my $has_threads = $INC{'threads.pm'} ? 1 : 0;
my $tid = $has_threads ? threads->tid()  : 0;

my @MUTEX;

sub CLONE {
    $tid = threads->tid() if $has_threads;
}

sub DESTROY {
    my ($pid, $obj) = ($has_threads ? $$ .'.'. $tid : $$, @_);

    syswrite($obj->{_w_sock}, '0'), $obj->{$pid    } = 0 if $obj->{$pid    };
    syswrite($obj->{_r_sock}, '0'), $obj->{$pid.'b'} = 0 if $obj->{$pid.'b'};

    if ( $obj->{_init_pid} eq $pid ) {
        my $addr = refaddr $obj;

        ($^O eq 'MSWin32' && $obj->{impl} eq 'Channel')
            ? MCE::Util::_destroy_pipes($obj, qw(_w_sock _r_sock))
            : MCE::Util::_destroy_socks($obj, qw(_w_sock _r_sock));

        if ( ! $has_threads ) {
            @MUTEX = map { refaddr($_) == $addr ? () : $_ } @MUTEX;
        }
    }

    return;
}

sub _destroy {
    # Called by { MCE, MCE::Child, and MCE::Hobo }::_exit.
    # This must iterate a copy.

    if ( @MUTEX ) { local $_; &DESTROY($_) for @{[ @MUTEX ]}; }
}

sub _save_for_global_destruction {
    if ( ! $has_threads ) {
        push @MUTEX, $_[0];
        weaken $MUTEX[-1];
    }
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

    syswrite $obj{_w_sock}, '0';

    bless \%obj, $class;

    if ( caller !~ /^MCE:?/ || caller(1) !~ /^MCE:?/ ) {
        MCE::Mutex::Channel::_save_for_global_destruction(\%obj);
    }

    return \%obj;
}

sub lock {
    my ($pid, $obj) = ($has_threads ? $$ .'.'. $tid : $$, @_);

    MCE::Util::_sysread($obj->{_r_sock}, my($b), 1), $obj->{ $pid } = 1
        unless $obj->{ $pid };

    return;
}

*lock_exclusive = \&lock;
*lock_shared    = \&lock;

sub unlock {
    my ($pid, $obj) = ($has_threads ? $$ .'.'. $tid : $$, @_);

    syswrite($obj->{_w_sock}, '0'), $obj->{ $pid } = 0
        if $obj->{ $pid };

    return;
}

sub synchronize {
    my ($pid, $obj, $code, @ret) = (
        $has_threads ? $$ .'.'. $tid : $$, shift, shift
    );
    return unless ref($code) eq 'CODE';

    # lock, run, unlock - inlined for performance
    MCE::Util::_sysread($obj->{_r_sock}, my($b), 1), $obj->{ $pid } = 1
        unless $obj->{ $pid };

    (defined wantarray)
      ? @ret = wantarray ? $code->(@_) : scalar $code->(@_)
      : $code->(@_);

    syswrite($obj->{_w_sock}, '0'), $obj->{ $pid } = 0;

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

This document describes MCE::Mutex::Channel version 1.840

=head1 DESCRIPTION

A pipe-socket implementation for L<MCE::Mutex>. See documentation there.

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

