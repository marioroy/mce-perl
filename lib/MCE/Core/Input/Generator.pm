###############################################################################
## ----------------------------------------------------------------------------
## Sequence of numbers (for task_id > 0).
##
## This package provides a sequence of numbers used internally by the worker
## process. Distribution is divided equally among workers. This allows sequence
## to be configured independently among multiple user tasks.
##
## There is no public API.
##
###############################################################################

package MCE::Core::Input::Generator;

use strict;
use warnings;

our $VERSION = '1.879';

## Items below are folded into MCE.

package # hide from rpm
   MCE;

no warnings qw( threads recursion uninitialized );

###############################################################################
## ----------------------------------------------------------------------------
## Worker process -- Sequence Generator (equal distribution among workers).
##
###############################################################################

sub _worker_sequence_generator {

   my ($self) = @_;

   @_ = ();

   _croak('MCE::_worker_sequence_generator: (user_func) is not specified')
      unless (defined $self->{user_func});

   my $_bounds_only = $self->{bounds_only} || 0;
   my $_max_workers = $self->{max_workers};
   my $_chunk_size  = $self->{chunk_size};
   my $_wuf         = $self->{_wuf};

   my ($_begin, $_end, $_step, $_fmt);

   if (ref $self->{sequence} eq 'ARRAY') {
      ($_begin, $_end, $_step, $_fmt) = @{ $self->{sequence} };
   }
   else {
      $_begin = $self->{sequence}->{begin};
      $_end   = $self->{sequence}->{end};
      $_step  = $self->{sequence}->{step};
      $_fmt   = $self->{sequence}->{format};
   }

   my $_wid      = $self->{_task_wid} || $self->{_wid};
   my $_next     = ($_wid - 1) * $_chunk_size * $_step + $_begin;
   my $_chunk_id = $_wid;

   $_fmt =~ s/%// if (defined $_fmt);

   ## -------------------------------------------------------------------------

   local $_;

   $self->{_last_jmp} = sub { goto _WORKER_SEQ_GEN__LAST; };

   if ($_begin == $_end) {                        ## Identical, yes.

      if ($_wid == 1) {
         $self->{_next_jmp} = sub { goto _WORKER_SEQ_GEN__LAST; };

         $_ = (defined $_fmt) ? _sprintf("%$_fmt", $_next) : $_next;

         if ($_chunk_size > 1 || $_bounds_only) {
            $_ = ($_bounds_only) ? [ $_, $_ ] : [ $_ ];
         }

         $_wuf->($self, $_, $_chunk_id);
      }
   }
   elsif ($_chunk_size == 1) {                    ## Chunking, no.

      $self->{_next_jmp} = sub { goto _WORKER_SEQ_GEN__NEXT_A; };

      my $_flag = ($_begin < $_end);

      while (1) {
         return if ( $_flag && $_next > $_end);
         return if (!$_flag && $_next < $_end);

         $_ = (defined $_fmt) ? _sprintf("%$_fmt", $_next) : $_next;
         $_ = [ $_, $_ ] if ($_bounds_only);

         $_wuf->($self, $_, $_chunk_id);

         _WORKER_SEQ_GEN__NEXT_A:

         $_chunk_id += $_max_workers;
         $_next      = ($_chunk_id - 1) * $_step + $_begin;
      }
   }
   else {                                         ## Chunking, yes.

      $self->{_next_jmp} = sub { goto _WORKER_SEQ_GEN__NEXT_B; };

      while (1) {
         my @_n = (); my $_n_begin = $_next;

         ## -------------------------------------------------------------------

         if ($_bounds_only) {
            my ($_tmp_b, $_tmp_e) = ($_next);

            if ($_begin <= $_end) {
               if ($_step * ($_chunk_size - 1) + $_n_begin <= $_end) {
                  $_tmp_e = $_step * ($_chunk_size - 1) + $_n_begin;
               }
               elsif ($_step == 1) {
                  $_tmp_e = $_end if ($_next <= $_end);
               }
               else {
                  for my $_i (1 .. $_chunk_size) {
                     last if ($_next > $_end);
                     $_tmp_e = $_next;
                     $_next  = $_step * $_i + $_n_begin;
                  }
               }
            }
            else {
               if ($_step * ($_chunk_size - 1) + $_n_begin >= $_end) {
                  $_tmp_e = $_step * ($_chunk_size - 1) + $_n_begin;
               }
               elsif ($_step == -1) {
                  $_tmp_e = $_end if ($_next >= $_end);
               }
               else {
                  for my $_i (1 .. $_chunk_size) {
                     last if ($_next < $_end);
                     $_tmp_e = $_next;
                     $_next  = $_step * $_i + $_n_begin;
                  }
               }
            }

            return unless (defined $_tmp_e);

            @_n = (defined $_fmt)
               ? ( _sprintf("%$_fmt",$_tmp_b), _sprintf("%$_fmt",$_tmp_e) )
               : ( $_tmp_b, $_tmp_e );
         }

         ## -------------------------------------------------------------------

         else {
            if ($_begin <= $_end) {
               if (!defined $_fmt && $_step == 1 && abs($_end) < ~1 && abs($_begin) < ~1) {
                  @_n = ($_next + $_chunk_size <= $_end)
                     ? ($_next .. $_next + $_chunk_size - 1)
                     : ($_next .. $_end);
               }
               else {
                  for my $_i (1 .. $_chunk_size) {
                     last if ($_next > $_end);

                     push @_n, (defined $_fmt)
                        ? _sprintf("%$_fmt", $_next) : $_next;

                     $_next = $_step * $_i + $_n_begin;
                  }
               }
            }
            else {
               for my $_i (1 .. $_chunk_size) {
                  last if ($_next < $_end);

                  push @_n, (defined $_fmt)
                     ? _sprintf("%$_fmt", $_next) : $_next;

                  $_next = $_step * $_i + $_n_begin;
               }
            }

            return unless (scalar @_n);
         }

         ## -------------------------------------------------------------------

         $_ = \@_n;
         $_wuf->($self, \@_n, $_chunk_id);

         _WORKER_SEQ_GEN__NEXT_B:

         $_chunk_id += $_max_workers;
         $_next      = ($_chunk_id - 1) * $_chunk_size * $_step + $_begin;
      }
   }

   _WORKER_SEQ_GEN__LAST:

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

MCE::Core::Input::Generator - Sequence of numbers (for task_id > 0)

=head1 VERSION

This document describes MCE::Core::Input::Generator version 1.879

=head1 DESCRIPTION

This package provides a sequence of numbers used internally by the worker
process. Distribution is divided equally among workers. This allows sequence
to be configured independently among multiple user tasks.

There is no public API.

=head1 SEE ALSO

The syntax for the C<sequence> option is described in L<MCE::Core>.

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

