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
   _CKSZ => 4,  # chunk_size option, default 1
   _ONLY => 5,  # bounds_only option, default 0
   _ITER => 6,  # iterator count
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
   my $self = shift;
   my $opts = ref($_[0]) eq 'HASH' ? shift() : {};

   @{ $self } = @_;

   _croak('invalid begin') unless looks_like_number( $self->[_BEGV] );
   _croak('invalid end'  ) unless looks_like_number( $self->[_ENDV] );

   $self->[_STEP] = ( $self->[_BEGV] <= $self->[_ENDV] ) ? 1 : -1
      unless ( defined $self->[_STEP] );

   $self->[_FMT] =~ s/%// if ( defined $self->[_FMT] );

   _croak('invalid step' ) unless looks_like_number( $self->[_STEP] );

   $self->[_CKSZ] = $opts->{'chunk_size'}  || 1;
   $self->[_ONLY] = $opts->{'bounds_only'} // 0;

   _croak('invalid chunk_size'  ) unless ( $self->[_CKSZ] =~ /^\d+$/  );
   _croak('invalid bounds_only' ) unless ( $self->[_ONLY] =~ /^[01]$/ );

   $self->[_ITER] = undef;

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Public methods.
##
###############################################################################

# new ( begin, end [, step, format ] )
# new ( )

sub new {
   my ( $class, $self ) = ( shift, [] );

   if ( !@_ ) {
      @{ $self } = ( 0, 0, 1, '__NOOP__' );
   } else {
      _reset( $self, @_ );
   }

   bless $self, $class;
}

# next ( )

sub next {
   my ( $self ) = @_;
   my $iter = $self->[_ITER];

   if ( defined $iter ) {
      my ( $begv, $endv, $step, $fmt, $chunk_size, $bounds_only ) = @{ $self };
      my ( $seq );

      # compute from _BEGV value to not lose precision during iteration

      if ( $begv <= $endv ) {
         $seq = $begv + ( $iter++ * $step );
         return if ( $seq > $endv );
      }
      else {
         $seq = $begv - -( $iter++ * $step );
         return if ( $seq < $endv );
      }

      # bounds_only => 1

      if ( $bounds_only ) {
         my ( @n, $seq_e );

         $n[0] = ( defined $fmt ) ? sprintf( "%$fmt", $seq ) : $seq;

         if ( $chunk_size > 1 ) {
            if ( $begv <= $endv ) {
               if ( $step * ( $chunk_size - 1 ) + $seq <= $endv ) {
                  $seq_e = $step * ( $chunk_size - 1 ) + $seq;
                  $iter += $chunk_size - 1;
               }
               else {
                  for my $i ( 2 .. $chunk_size ) {
                     $seq = $begv + ( $iter++ * $step );
                     last if ( $seq > $endv );
                     $seq_e = $seq;
                  }
               }
            }
            else {
               if ( $step * ( $chunk_size - 1 ) + $seq >= $endv ) {
                  $seq_e = $step * ( $chunk_size - 1 ) + $seq;
                  $iter += $chunk_size - 1;
               }
               else {
                  for my $i ( 2 .. $chunk_size ) {
                     $seq = $begv - -( $iter++ * $step );
                     last if ( $seq < $endv );
                     $seq_e = $seq;
                  }
               }
            }
         }

         $self->[_ITER] = $iter;

         if ( defined $seq_e ) {
            $n[1] = ( defined $fmt ) ? sprintf( "%$fmt", $seq_e ) : $seq_e;
         }
         else {
            $n[1] = $n[0];
         }

         @n;  # begin_end pair
      }

      # chunk_size == 1

      elsif ( $chunk_size == 1 ) {
         $self->[_ITER] = $iter;

         ( defined $fmt ) ? sprintf( "%$fmt", $seq ) : $seq;
      }

      # chunk_size > 1

      else {
         push my @n, ( defined $fmt ) ? sprintf( "%$fmt", $seq ) : $seq;

         if ( $begv <= $endv ) {
            for my $i ( 2 .. $chunk_size ) {
               $seq = $begv + ( $iter++ * $step );
               last if ( $seq > $endv );
               push @n, ( defined $fmt ) ? sprintf( "%$fmt", $seq ) : $seq;
            }
         }
         else {
            for my $i ( 2 .. $chunk_size ) {
               $seq = $begv - -( $iter++ * $step );
               last if ( $seq < $endv );
               push @n, ( defined $fmt ) ? sprintf( "%$fmt", $seq ) : $seq;
            }
         }

         $self->[_ITER] = $iter;

         @n;
      }
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

   if ( !@_ ) {
      $self->[_ITER] = undef unless ( $self->[_FMT] eq '__NOOP__' );
   } else {
      _reset( $self, @_ );
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

   my $seq_a = MCE::Shared::Sequence->new( $begin, $end, $step, $fmt );

   my $seq_b = MCE::Shared::Sequence->new(
      { chunk_size => 10, bounds_only => 1 },
      $begin, $end, $step, $fmt
   );

   # shared
   use MCE::Hobo;
   use MCE::Shared;

   my $seq_a = MCE::Shared->sequence( 1, 100 );

   my $seq_b = MCE::Shared->sequence(
      { chunk_size => 10, bounds_only => 1 },
      1, 100
   );

   sub parallel_a {
      my ( $id ) = @_;
      while ( my $num = $seq_a->next ) {
         print "$id: $num\n";
      }
   }

   sub parallel_b {
      my ( $id ) = @_;
      while ( my ( $beg, $end ) = $seq_b->next ) {
         for my $num ( $beg .. $end ) {
            print "$id: $num\n";
         }
      }
   }

   MCE::Hobo->new( \&parallel_a, $_ ) for 1 .. 2;
   MCE::Hobo->new( \&parallel_b, $_ ) for 3 .. 4;

   $_->join for MCE::Hobo->list();

=head1 DESCRIPTION

A number sequence class for L<MCE::Shared>.

=head1 API DOCUMENTATION

=over 3

=item new ( { options }, begin, end [, step, format ] )

=item new ( begin, end [, step, format ] )

Constructs a new object. C<step>, if omitted, defaults to C<1> if C<begin> is
smaller than C<end> or C<-1> if C<begin> is greater than C<end>. The C<format>
string is passed to C<sprintf> behind the scene (% may be omitted).

   $seq_n_formatted = sprintf( "%4.1f", $seq_n );

Two options C<chunk_size> and C<bounds_only> are supported, which default to
1 and 0 respectively. Chunking reduces the number of IPC calls to and from the
shared-manager process for large sequences.

If C<bounds_only => 1> is specified, the C<next> method computes the C<begin>
and C<end> values only for the chunk and not the numbers in between (hence
boundaries only).

   $seq1 = MCE::Shared->sequence(
      { chunk_size => 10, bounds_only => 0 },
      1, 20
   );

   @chunk1 = $seq1->next;  # ( qw/  1  2  3  4  5  6  7  8  9 10 / )
   @chunk2 = $seq1->next;  # ( qw/ 11 12 13 14 15 16 17 18 19 20 / )

   $seq2 = MCE::Shared->sequence(
      { chunk_size => 10, bounds_only => 1 },
      1, 100
   );

   ( $beg, $end ) = $seq2->next;  # (  1,  10 )
   ( $beg, $end ) = $seq2->next;  # ( 11,  20 )
   ( $beg, $end ) = $seq2->next;  # ( 21,  30 )
      ...
   ( $beg, $end ) = $seq2->next;  # ( 81,  90 )
   ( $beg, $end ) = $seq2->next;  # ( 91, 100 )

New values and options may be specified later with the C<rewind> method before
calling C<next>.

   # non-shared
   use MCE::Shared::Sequence;

   $seq = MCE::Shared::Sequence->new( -1, 1, 0.1, "%4.1f" );
   $seq = MCE::Shared::Sequence->new( );
   $seq->rewind( -1, 1, 0.1, "%4.1f" );

   $seq = MCE::Shared::Sequence->new(
      { chunk_size => 10, bounds_only => 1 },
      1, 100
   );

   # shared
   use MCE::Shared;

   $seq = MCE::Shared->sequence( 1, 100 );
   $seq = MCE::Shared->sequence( );
   $seq->rewind( 1, 100 );

   $seq = MCE::Shared->sequence(
      { chunk_size => 10, bounds_only => 1 },
      1, 100
   );

=item next

Returns the next computed sequence(s). An undefined value is returned when
the computed C<begin> value exceeds the value held by C<end>.

   # { chunk_size =>  1, bounds_only => 0 }  default
     $num = $seq->next;

   # { chunk_size => 10, bounds_only => 0 }
     @chunk = $seq->next;

   # { chunk_size => 10, bounds_only => 1 }
     ( $beg, $end ) = $seq->next;

=item rewind ( { options }, begin, end [, step, format ] )

=item rewind ( begin, end [, step, format ] )

When arguments are specified, resets parameters internally. Otherwise, sets
the initial value back to the value held by C<begin>.

   $seq->rewind( 10, 1, -1 );
   $seq->next; # repeatedly

   $seq->rewind;
   $seq->next; # repeatedly

=back

=head1 INDEX

L<MCE|MCE>, L<MCE::Core>, L<MCE::Shared>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

