###############################################################################
## ----------------------------------------------------------------------------
## Sequence helper class.
##
###############################################################################

package MCE::Shared::Sequence;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized numeric );

our $VERSION = '1.699_011';

use Scalar::Util qw( looks_like_number );
use MCE::Shared::Base;

use constant {
   _BEGV => 0,  # sequence begin value
   _ENDV => 1,  # sequence end value
   _STEP => 2,  # sequence step size
   _FMT  => 3,  # sequence format
   _ITER => 4,  # iterator count
};

use overload (
   q("")    => \&MCE::Shared::Base::_stringify,
   q(0+)    => \&MCE::Shared::Base::_numify,
   fallback => 1
);

sub _croak {
   goto &MCE::Shared::Base::_croak;
}

sub _reset {
   my $self   = shift;
   @{ $self } = @_;

   _croak('invalid begin') unless looks_like_number( $self->[_BEGV] );
   _croak('invalid end'  ) unless looks_like_number( $self->[_ENDV] );

   $self->[_STEP] = ( $self->[_BEGV] <= $self->[_ENDV] ) ? 1 : -1
      unless ( defined $self->[_STEP] );

   $self->[_FMT] =~ s/%// if ( defined $self->[_FMT] );

   _croak('invalid step' ) unless looks_like_number( $self->[_STEP] );

   $self->[_ITER] = undef;

   return;
}

# new ( begin, end [, step, format ] )
# new ( )

sub new {
   my ( $class, $self ) = ( shift, [] );

   if ( @_ ) {
      _reset( $self, @_ );
   }
   else {
      @{ $self } = ( 0, 0, 1, '__NOOP__', 1 );
   }

   bless $self, $class;
}

# next ( )

sub next {
   my ( $self ) = @_;
   my $iter = $self->[_ITER];

   if ( defined $iter ) {
      my $seq; my ( $begv, $endv, $step, $fmt ) = @{ $self };
      # always compute from _BEGV value to not lose precision

      if ( $begv <= $endv ) {
         $seq = $begv + ( $iter * $step );
         return unless ( $seq >= $begv && $seq <= $endv );
      }
      else {
         $seq = $begv - -( $iter * $step );
         return unless ( $seq >= $endv && $seq <= $begv );
      }

      $self->[_ITER]++, ( defined $fmt )
         ? sprintf( "%$fmt", $seq )
         : $seq;
   }
   else {
      $self->[_ITER] = 0;
      $self->next();
   }
}

# rewind ( begin, end [, step, format ] )
# rewind ( )

sub rewind {
   my $self = shift;

   if ( scalar @_ ) {
      _reset( $self, @_ );
   }
   else {
      $self->[_ITER] = undef unless ( $self->[_FMT] eq '__NOOP__' );
   }

   return;
}

1;

__END__

###############################################################################
## ----------------------------------------------------------------------------
## Module usage.
##
###############################################################################

=head1 NAME

MCE::Shared::Sequence - Sequence helper class

=head1 VERSION

This document describes MCE::Shared::Sequence version 1.699_011

=head1 SYNOPSIS

   # non-shared
   use MCE::Shared::Sequence;

   my $seq = MCE::Shared::Sequence->new( $begin, $end, $step, $fmt );

   # shared
   use MCE::Hobo;
   use MCE::Shared Sereal => 1;

   my $seq = MCE::Shared->sequence( 1, 100 );

   sub parallel {
      my ( $id ) = @_;
      while ( my $num = $seq->next ) {
         print "$id: $num\n";
      }
   }

   MCE::Hobo->new( \&parallel, $_ ) for 1 .. 8;

   $_->join for MCE::Hobo->list();

=head1 DESCRIPTION

A number sequence class for L<MCE::Shared>.

=head1 API DOCUMENTATION

=over 3

=item new ( begin, end [, step, format ] )

Constructs a new object. C<step>, if omitted, defaults to C<1> if C<begin> is
smaller than C<end> or C<-1> if C<begin> is greater than C<end>. The C<format>
string is passed to C<sprintf> behind the scene (% may be omitted).

   $seq_n_formatted = sprintf( "%4.1f", $seq_n );

Options may be specified later with C<rewind> before calling C<next>.

   # non-shared
   use MCE::Shared::Sequence;

   $seq = MCE::Shared::Sequence->new( -1, 1, 0.1, "%4.1f" );
   $seq = MCE::Shared::Sequence->new( );
   $seq->rewind( -1, 1, 0.1, "%4.1f" );

   # shared
   use MCE::Shared;

   $seq = MCE::Shared->sequence( 1, 100 );
   $seq = MCE::Shared->sequence( );
   $seq->rewind( 1, 100 );

=item next

Returns the next computed sequence. An undefined value is returned when the
computed value exceeds the value held by C<end>.

   $num = $seq->next;

=item rewind ( begin, end [, step, format ] )

When options are specified, resets parameters internally. Otherwise, sets the
initial value back to the value held by C<begin>.

   $seq->rewind( 10, 1, -1 );
   $seq->next; # repeatedly

   $seq->rewind;
   $seq->next; # repeatedly

=back

=head1 INDEX

L<MCE>, L<MCE::Core>, L<MCE::Shared>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

