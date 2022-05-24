###############################################################################
## ----------------------------------------------------------------------------
## Sequence of numbers (for task_id == 0).
##
## This package provides a sequence of numbers used internally by the worker
## process. Distribution follows a bank-queuing model.
##
## There is no public API.
##
###############################################################################

package MCE::Core::Input::Sequence;

use strict;
use warnings;

our $VERSION = '1.879';

## Items below are folded into MCE.

package # hide from rpm
   MCE;

no warnings qw( threads recursion uninitialized );

my $_que_read_size = $MCE::_que_read_size;
my $_que_template  = $MCE::_que_template;

###############################################################################
## ----------------------------------------------------------------------------
## Worker process -- Sequence Queue (distribution via bank queuing model).
##
###############################################################################

sub _worker_sequence_queue {

   my ($self) = @_;

   @_ = ();

   _croak('MCE::_worker_sequence_queue: (user_func) is not specified')
      unless (defined $self->{user_func});

   my $_DAT_LOCK    = $self->{_dat_lock};
   my $_QUE_R_SOCK  = $self->{_que_r_sock};
   my $_QUE_W_SOCK  = $self->{_que_w_sock};
   my $_lock_chn    = $self->{_lock_chn};
   my $_bounds_only = $self->{bounds_only} || 0;
   my $_chunk_size  = $self->{chunk_size};
   my $_wuf         = $self->{_wuf};

   my ($_next, $_chunk_id, $_seq_n, $_begin, $_end, $_step, $_fmt);
   my ($_dat_ex, $_dat_un, $_pid, $_abort, $_offset);

   if ($_lock_chn) {
      $_pid = $INC{'threads.pm'} ? $$ .'.'. threads->tid() : $$;

      # inlined for performance
      if ($self->{_data_channels} > 5) {
         $_DAT_LOCK = $self->{'_mutex_'.( $self->{_wid} % 5 + 1 )};
      }
      $_dat_ex = sub {
         MCE::Util::_sysread($_DAT_LOCK->{_r_sock}, my($b), 1), $_DAT_LOCK->{ $_pid } = 1
            unless $_DAT_LOCK->{ $_pid };
      };
      $_dat_un = sub {
         syswrite($_DAT_LOCK->{_w_sock}, '0'), $_DAT_LOCK->{ $_pid } = 0
            if $_DAT_LOCK->{ $_pid };
      };
   }

   if (ref $self->{sequence} eq 'ARRAY') {
      ($_begin, $_end, $_step, $_fmt) = @{ $self->{sequence} };
   }
   else {
      $_begin = $self->{sequence}->{begin};
      $_end   = $self->{sequence}->{end};
      $_step  = $self->{sequence}->{step};
      $_fmt   = $self->{sequence}->{format};
   }

   $_abort    = $self->{_abort_msg};
   $_chunk_id = $_offset = 0;

   $_fmt =~ s/%// if (defined $_fmt);

   ## -------------------------------------------------------------------------

   $self->{_next_jmp} = sub { goto _WORKER_SEQUENCE__NEXT; };
   $self->{_last_jmp} = sub { goto _WORKER_SEQUENCE__LAST; };

   local $_;

   _WORKER_SEQUENCE__NEXT:

   while (1) {

      ## Obtain the next chunk_id and sequence number.
      $_dat_ex->() if $_lock_chn;
      MCE::Util::_sysread($_QUE_R_SOCK, $_next, $_que_read_size);

      ($_chunk_id, $_offset) = unpack($_que_template, $_next);

      if ($_offset >= $_abort) {
         syswrite($_QUE_W_SOCK, pack($_que_template, 0, $_offset));
         $_dat_un->() if $_lock_chn;
         return;
      }

      syswrite(
         $_QUE_W_SOCK, pack($_que_template, $_chunk_id + 1, $_offset + 1)
      );

      $_dat_un->() if $_lock_chn;
      $_chunk_id++;

      ## Call user function.
      if ($_chunk_size == 1 || $_begin == $_end) {
         $_ = $_offset * $_step + $_begin;
         $_ = _sprintf("%$_fmt", $_) if (defined $_fmt);
         if ($_chunk_size > 1 || $_bounds_only) {
            $_ = ($_bounds_only) ? [ $_, $_ ] : [ $_ ];
         }
         $_wuf->($self, $_, $_chunk_id);
      }
      else {
         my $_n_begin = ($_offset * $_chunk_size) * $_step + $_begin;
         my @_n = ();    $_seq_n = $_n_begin;

         ## -------------------------------------------------------------------

         if ($_bounds_only) {
            my ($_tmp_b, $_tmp_e) = ($_seq_n);

            if ($_begin <= $_end) {
               if ($_step * ($_chunk_size - 1) + $_n_begin <= $_end) {
                  $_tmp_e = $_step * ($_chunk_size - 1) + $_n_begin;
               }
               elsif ($_step == 1) {
                  $_tmp_e = $_end;
               }
               else {
                  for my $_i (1 .. $_chunk_size) {
                     last if ($_seq_n > $_end);
                     $_tmp_e = $_seq_n;
                     $_seq_n = $_step * $_i + $_n_begin;
                  }
               }
            }
            else {
               if ($_step * ($_chunk_size - 1) + $_n_begin >= $_end) {
                  $_tmp_e = $_step * ($_chunk_size - 1) + $_n_begin;
               }
               elsif ($_step == -1) {
                  $_tmp_e = $_end;
               }
               else {
                  for my $_i (1 .. $_chunk_size) {
                     last if ($_seq_n < $_end);
                     $_tmp_e = $_seq_n;
                     $_seq_n = $_step * $_i + $_n_begin;
                  }
               }
            }

            @_n = (defined $_fmt)
               ? ( _sprintf("%$_fmt",$_tmp_b), _sprintf("%$_fmt",$_tmp_e) )
               : ( $_tmp_b, $_tmp_e );
         }

         ## -------------------------------------------------------------------

         else {
            if ($_begin <= $_end) {
               if (!defined $_fmt && $_step == 1 && abs($_end) < ~1 && abs($_begin) < ~1) {
                  $_ = ($_seq_n + $_chunk_size <= $_end)
                     ? [ $_seq_n .. $_seq_n + $_chunk_size - 1 ]
                     : [ $_seq_n .. $_end ];

                  $_wuf->($self, $_, $_chunk_id);
                  next;
               }
               else {
                  for my $_i (1 .. $_chunk_size) {
                     last if ($_seq_n > $_end);

                     push @_n, (defined $_fmt)
                        ? _sprintf("%$_fmt", $_seq_n) : $_seq_n;

                     $_seq_n = $_step * $_i + $_n_begin;
                  }
               }
            }
            else {
               for my $_i (1 .. $_chunk_size) {
                  last if ($_seq_n < $_end);

                  push @_n, (defined $_fmt)
                     ? _sprintf("%$_fmt", $_seq_n) : $_seq_n;

                  $_seq_n = $_step * $_i + $_n_begin;
               }
            }
         }

         ## -------------------------------------------------------------------

         $_ = \@_n;
         $_wuf->($self, \@_n, $_chunk_id);
      }
   }

   _WORKER_SEQUENCE__LAST:

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

MCE::Core::Input::Sequence - Sequence of numbers (for task_id == 0)

=head1 VERSION

This document describes MCE::Core::Input::Sequence version 1.879

=head1 DESCRIPTION

This package provides a sequence of numbers used internally by the worker
process. Distribution follows a bank-queuing model.

There is no public API.

=head1 SEE ALSO

The syntax for the C<sequence> option is described in L<MCE::Core>.

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

