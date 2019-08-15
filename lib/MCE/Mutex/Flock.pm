###############################################################################
## ----------------------------------------------------------------------------
## MCE::Mutex::Flock - Mutex locking via Fcntl.
##
###############################################################################

package MCE::Mutex::Flock;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized once );

our $VERSION = '1.844';

use base 'MCE::Mutex';
use Fcntl ':flock';
use Carp ();

my $has_threads = $INC{'threads.pm'} ? 1 : 0;
my $tid = $has_threads ? threads->tid()  : 0;

sub CLONE {
    $tid = threads->tid() if $has_threads;
}

sub DESTROY {
    my ($pid, $obj) = ($has_threads ? $$ .'.'. $tid : $$, @_);

    $obj->unlock(), close(delete $obj->{_fh}) if $obj->{ $pid };

    unlink $obj->{path} if ($obj->{_init} && $obj->{_init} eq $pid);

    return;
}

sub _open {
    my ($pid, $obj) = ($has_threads ? $$ .'.'. $tid : $$, @_);
    return if exists $obj->{ $pid };

    open $obj->{_fh}, '+>>:raw:stdio', $obj->{path}
        or Carp::croak("Could not create temp file $obj->{path}: $!");

    return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Public methods.
##
###############################################################################

my ($id, $prog_name) = (0);

$prog_name =  $0;
$prog_name =~ s{^.*[\\/]}{}g;
$prog_name =  'perl' if ($prog_name eq '-e' || $prog_name eq '-');

sub new {
    my ($class, %obj) = (@_, impl => 'Flock');

    if (! defined $obj{path}) {
        my ($pid, $tmp_dir, $tmp_file) = ( abs($$) );

        if ($ENV{TEMP} && -d $ENV{TEMP} && -w _) {
            if ($^O =~ /mswin|mingw|msys|cygwin/i) {
                $tmp_dir  = $ENV{TEMP};
                $tmp_dir .= ($^O eq 'MSWin32') ? "\\Perl-MCE" : "/Perl-MCE";
                mkdir $tmp_dir unless (-d $tmp_dir);
            }
            else {
                $tmp_dir = $ENV{TEMP};
            }
        }
        elsif ($ENV{TMPDIR} && -d $ENV{TMPDIR} && -w _) {
            $tmp_dir = $ENV{TMPDIR};
        }
        elsif (-d '/tmp' && -w _) {
            $tmp_dir = '/tmp';
        }
        else {
            Carp::croak("No writable dir found for a temp file");
        }

        $id++, $tmp_dir =~ s{[\\/]$}{};

        # remove tainted'ness from $tmp_dir
        if ($^O eq 'MSWin32') {
            ($tmp_file) = "$tmp_dir\\$prog_name.$pid.$tid.$id" =~ /(.*)/;
        } else {
            ($tmp_file) = "$tmp_dir/$prog_name.$pid.$tid.$id" =~ /(.*)/;
        }

        $obj{_init} = $has_threads ? $$ .'.'. $tid : $$;
        $obj{ path} = $tmp_file.'.lock';

        # test open
        open my $fh, '+>>:raw:stdio', $obj{path}
            or Carp::croak("Could not create temp file $obj{path}: $!");

        close $fh;

        # set permission
        chmod 0600, $obj{path};
    }
    else {
        # test open
        open my $fh, '+>>:raw:stdio', $obj{path}
            or Carp::croak("Could not obtain flock on file $obj{path}: $!");

        close $fh;
    }

    return bless(\%obj, $class);
}

sub lock {
    my ($pid, $obj) = ($has_threads ? $$ .'.'. $tid : $$, @_);
    $obj->_open() unless exists $obj->{ $pid };

    flock ($obj->{_fh}, LOCK_EX), $obj->{ $pid } = 1
        unless $obj->{ $pid };

    return;
}

*lock_exclusive = \&lock;

sub lock_shared {
    my ($pid, $obj) = ($has_threads ? $$ .'.'. $tid : $$, @_);
    $obj->_open() unless exists $obj->{ $pid };

    flock ($obj->{_fh}, LOCK_SH), $obj->{ $pid } = 1
        unless $obj->{ $pid };

    return;
}

sub unlock {
    my ($pid, $obj) = ($has_threads ? $$ .'.'. $tid : $$, @_);

    flock ($obj->{_fh}, LOCK_UN), $obj->{ $pid } = 0
        if $obj->{ $pid };

    return;
}

sub synchronize {
    my ($pid, $obj, $code, @ret) = (
        $has_threads ? $$ .'.'. $tid : $$, shift, shift
    );
    return unless ref($code) eq 'CODE';

    $obj->_open() unless exists $obj->{ $pid };

    # lock, run, unlock - inlined for performance
    flock ($obj->{_fh}, LOCK_EX), $obj->{ $pid } = 1
        unless $obj->{ $pid };

    (defined wantarray)
      ? @ret = wantarray ? $code->(@_) : scalar $code->(@_)
      : $code->(@_);

    flock ($obj->{_fh}, LOCK_UN), $obj->{ $pid } = 0;

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

MCE::Mutex::Flock - Mutex locking via Fcntl

=head1 VERSION

This document describes MCE::Mutex::Flock version 1.844

=head1 DESCRIPTION

A Fcntl implementation for C<MCE::Mutex>.

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

