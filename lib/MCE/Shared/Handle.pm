###############################################################################
## ----------------------------------------------------------------------------
## Handle helper class.
##
###############################################################################

package MCE::Shared::Handle;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized numeric );

our $VERSION = '1.700';

## no critic (InputOutput::ProhibitTwoArgOpen)

use MCE::Shared::Base;
use bytes;

sub _croak {
   goto &MCE::Shared::Base::_croak;
}

sub TIEHANDLE {
   my $class = shift;

   if (ref $_[0] eq 'ARRAY') {
      # For use with MCE::Shared to reach the Server process
      # without a GLOB initially.
      bless $_[0], $class;
   }
   else {
      my $fh = \do { local *HANDLE };
      bless $fh, $class;

      if (@_ == 2 && ref $_[1] && defined(my $_fd = fileno($_[1]))) {
         $fh->OPEN($_[0]."&=$_fd") or _croak("open error: $!");
      } elsif (@_) {
         $fh->OPEN(@_) or _croak("open error: $!");
      }

      $fh;
   }
}

sub new {
   my $class = shift;
   my $fh = \do { local *HANDLE };
   tie *{ $fh }, $class, @_;

   (@_ && !defined(fileno $fh)) ? undef : $fh;
}

# Based on Tie::StdHandle.

sub EOF     { eof($_[0]) }
sub TELL    { tell($_[0]) }
sub FILENO  { fileno($_[0]) }
sub SEEK    { seek($_[0], $_[1], $_[2]) }
sub CLOSE   { close($_[0]) }
sub BINMODE { binmode($_[0]) }

sub OPEN {
   $_[0]->CLOSE if defined($_[0]->FILENO);
   @_ == 2 ? open($_[0], $_[1]) : open($_[0], $_[1], $_[2]);
}

sub READ { &CORE::read(shift(), \shift(), @_) }
sub GETC { getc($_[0]) }

sub READLINE {
   # support special case; e.g. $/ = "\n>" for bioinformatics
   # anchoring ">" at the start of line

   if (length $/ > 1 && substr($/, 0, 1) eq "\n" && !eof $_[0]) {
      my ($len, $buf) = (length($/) - 1);

      if (tell $_[0]) {
         $buf = substr($/, 1), $buf .= readline($_[0]);
      } else {
         $buf = readline($_[0]);
      }
      substr($buf, -$len, $len, '')
         if (substr($buf, -$len) eq substr($/, 1));

      $buf;
   }
   else {
      scalar(readline($_[0]));
   }
}

sub PRINT {
   my $fh  = shift;
   my $buf = join(defined $, ? $, : "", @_);
   $buf   .= $\ if defined $\;
   local $\; # don't print any line terminator
   print $fh $buf;
}

sub PRINTF {
   my $fh  = shift;
   my $buf = sprintf(shift, @_);
   local $\; # ditto
   print $fh $buf;
}

sub WRITE {
   @_ > 2 ? syswrite($_[0], $_[1], $_[2], $_[3] || 0)
          : syswrite($_[0], $_[1]);
}

1;

__END__

###############################################################################
## ----------------------------------------------------------------------------
## Module usage.
##
###############################################################################

=head1 NAME

MCE::Shared::Handle - Handle helper class

=head1 VERSION

This document describes MCE::Shared::Handle version 1.700

=head1 SYNOPSIS

   # shared
   use MCE::Shared;

   my $fh = MCE::Shared->handle( "<", "sample.fasta" );

   # demo
   use MCE::Hobo;
   use MCE::Shared;

   my $ofh = MCE::Shared->handle( '>>', \*STDOUT );
   my $ifh = MCE::Shared->handle( '<', '/path/to/input/file' );

   # output is serialized (not garbled), but not ordered
   sub parallel {
      $/ = "\n"; # can set the input record separator
      while (my $line = <$ifh>) {
         printf {$ofh} "[%5d] %s", $., $line;
      }
   }

   MCE::Hobo->create( \&parallel ) for 1 .. 4;

   $_->join() for MCE::Hobo->list();

   # handle functions
   my $bool = eof($ifh);
   my $off  = tell($ifh);
   my $fd   = fileno($ifh);
   my $char = getc($ifh);
   my $line = readline($ifh);

   binmode $ifh;

   seek $ifh, 10, 0;
   read $ifh, my($buf), 80;

   print  {$ofh} "foo\n";
   printf {$ofh} "%s\n", "bar";

   open $ofh, ">>", \*STDERR;
   syswrite $ofh, "shared handle to STDERR\n";

   close $ifh;
   close $ofh;

=head1 DESCRIPTION

Helper class for L<MCE::Shared>.

=head1 API DOCUMENTATION

=over 3

=item new ( expr )

=item new ( mode, expr )

=item new ( mode, reference )

Constructs a new object by opening the file whose filename is given by C<expr>,
and returns a C<filehandle>. Unlike C<open>, MCE::Shared will emit an error
message and stop if an error occurs during opening of the file.

   use MCE::Shared;

Simple examples to open a shared file for reading:

   $fh = MCE::Shared->handle( "< input.txt" );
   $fh = MCE::Shared->handle( "<", "input.txt" );
   $fh = MCE::Shared->handle( "<", \*STDIN );

and for writing:

   $fh = MCE::Shared->handle( "> output.txt" );
   $fh = MCE::Shared->handle( ">", "output.txt" );
   $fh = MCE::Shared->handle( ">", \*STDOUT );

=back

=head1 LIMITATION

When passing a C<reference>, be sure to construct its C<file handle> associated
with C<reference> prior to starting the shared-manager process. Constructing a
shared object C<{ Array, Handle, Hash, Minidb, Ordhash, Scalar, Sequence }>
starts the manager process automatically.

Perl must have the L<IO::FDPass> module installed for C<MCE::Shared> to pass a
C<file_descriptor> higher than 2 to the shared-manager process.

=head1 CREDITS

Implementation inspired by L<Tie::StdHandle>.

=head1 INDEX

L<MCE|MCE>, L<MCE::Core>, L<MCE::Shared>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

