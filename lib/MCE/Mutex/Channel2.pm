###############################################################################
## ----------------------------------------------------------------------------
## MCE::Mutex::Channel2 - Provides two mutexes using a single channel.
##
###############################################################################

package MCE::Mutex::Channel2;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized once );

our $VERSION = '1.879';

use base 'MCE::Mutex::Channel';
use MCE::Util ();

my $tid = $INC{'threads.pm'} ? threads->tid() : 0;

sub CLONE {
    $tid = threads->tid() if $INC{'threads.pm'};
}

###############################################################################
## ----------------------------------------------------------------------------
## Public methods.
##
###############################################################################

sub new {
    my ($class, %obj) = (@_, impl => 'Channel2');
    $obj{'_init_pid'} = $tid ? $$ .'.'. $tid : $$;

    MCE::Util::_sock_pair(\%obj, qw(_r_sock _w_sock), undef, 1);

    syswrite $obj{_r_sock}, '0';
    syswrite $obj{_w_sock}, '0';

    bless \%obj, $class;

    if ( caller !~ /^MCE:?/ || caller(1) !~ /^MCE:?/ ) {
        MCE::Mutex::Channel::_save_for_global_cleanup(\%obj);
    }

    return \%obj;
}

sub lock2 {
    my ($pid, $obj) = ($tid ? $$ .'.'. $tid : $$, shift);

    MCE::Util::_sysread($obj->{_w_sock}, my($b), 1), $obj->{ $pid.'b' } = 1
        unless $obj->{ $pid.'b' };

    return;
}

*lock_exclusive2 = \&lock2;
*lock_shared2    = \&lock2;

sub unlock2 {
    my ($pid, $obj) = ($tid ? $$ .'.'. $tid : $$, shift);

    CORE::syswrite($obj->{_r_sock}, '0'), $obj->{ $pid.'b' } = 0
        if $obj->{ $pid.'b' };

    return;
}

sub synchronize2 {
    my ($pid, $obj, $code) = ($tid ? $$ .'.'. $tid : $$, shift, shift);
    my (@ret, $b);

    return unless ref($code) eq 'CODE';

    # lock, run, unlock - inlined for performance
    MCE::Util::_sysread($obj->{_w_sock}, $b, 1), $obj->{ $pid.'b' } = 1
        unless $obj->{ $pid.'b' };

    (defined wantarray)
      ? @ret = wantarray ? $code->(@_) : scalar $code->(@_)
      : $code->(@_);

    CORE::syswrite($obj->{_r_sock}, '0'), $obj->{ $pid.'b' } = 0;

    return wantarray ? @ret : $ret[-1];
}

*enter2 = \&synchronize2;

sub timedwait2 {
    my ($obj, $timeout) = @_;

    local $@; local $SIG{'ALRM'} = sub { alarm 0; die "timed out\n" };

    eval { alarm $timeout || 1; $obj->lock_exclusive2 };

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

MCE::Mutex::Channel2 - Provides two mutexes using a single channel

=head1 VERSION

This document describes MCE::Mutex::Channel2 version 1.879

=head1 DESCRIPTION

A socket implementation based on C<MCE::Mutex>. The secondary lock is accessed
by calling methods with the C<2> suffix.

The API is described in L<MCE::Mutex>.

=head2 construction

=over 3

=item new

 my $mutex = MCE::Mutex->new( impl => 'Channel2' );

=back

=head2 primary lock

=over 3

=item lock

=item lock_exclusive

=item lock_shared

=item unlock

=item synchronize

=item enter

=item timedwait

=back

=head2 secondary lock

=over 3

=item lock2

=item lock_exclusive2

=item lock_shared2

=item unlock2

=item synchronize2

=item enter2

=item timedwait2

=back

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

