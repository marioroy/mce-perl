###############################################################################
## ----------------------------------------------------------------------------
## Array reference and Glob reference input reader.
##
## This package provides the request chunk method used internally by the worker
## process. Distribution follows a bank-queuing model.
##
## There is no public API.
##
###############################################################################

package MCE::Core::Input::Request;

use strict;
use warnings;

our $VERSION = '1.879';

## Items below are folded into MCE.

package # hide from rpm
   MCE;

no warnings qw( threads recursion uninitialized );

###############################################################################
## ----------------------------------------------------------------------------
## Worker process -- Request chunk.
##
###############################################################################

my $_is_MSWin32 = ( $^O eq 'MSWin32' ) ? 1 : 0;

sub _worker_request_chunk {

   my ($self, $_proc_type) = @_;

   @_ = ();

   _croak('MCE::_worker_request_chunk: (user_func) is not specified')
      unless (defined $self->{user_func});

   my $_chn         = $self->{_chn};
   my $_DAT_LOCK    = $self->{_dat_lock};
   my $_DAT_W_SOCK  = $self->{_dat_w_sock}->[0];
   my $_DAU_W_SOCK  = $self->{_dat_w_sock}->[$_chn];
   my $_lock_chn    = $self->{_lock_chn};
   my $_chunk_size  = $self->{chunk_size};
   my $_use_slurpio = $self->{use_slurpio};
   my $_RS          = $self->{RS} || $/;
   my $_wuf         = $self->{_wuf};

   my ($_dat_ex, $_dat_un, $_pid);

   if ($_lock_chn) {
      $_pid = $INC{'threads.pm'} ? $$ .'.'. threads->tid() : $$;

      # inlined for performance
      $_dat_ex = sub {
         MCE::Util::_sysread($_DAT_LOCK->{_r_sock}, my($b), 1), $_DAT_LOCK->{ $_pid } = 1
            unless $_DAT_LOCK->{ $_pid };
      };
      $_dat_un = sub {
         syswrite($_DAT_LOCK->{_w_sock}, '0'), $_DAT_LOCK->{ $_pid } = 0
            if $_DAT_LOCK->{ $_pid };
      };
   }

   my ($_chunk_id, $_len, $_output_tag);
   my ($_chop_len, $_chop_str, $_p);

   if ($_proc_type == REQUEST_ARRAY) {
      $_output_tag = OUTPUT_A_REF;
      $_chop_len   = 0;
   }
   elsif ($_proc_type == REQUEST_HASH) {
      $_output_tag = OUTPUT_H_REF;
      $_chop_len   = 0;
   }
   else {
      $_output_tag = OUTPUT_G_REF;
      if (length $_RS > 1 && substr($_RS, 0, 1) eq "\n") {
         $_chop_str = substr($_RS, 1);
         $_chop_len = length $_chop_str;
      } else {
         $_chop_str = '';
         $_chop_len = 0;
      }
   }

   ## -------------------------------------------------------------------------

   $self->{_next_jmp} = sub { goto _WORKER_REQUEST_CHUNK__NEXT; };
   $self->{_last_jmp} = sub { goto _WORKER_REQUEST_CHUNK__LAST; };

   local $_;

   _WORKER_REQUEST_CHUNK__NEXT:

   while (1) {
      undef $_ if (length > MAX_GC_SIZE);

      $_ = '';

      ## Obtain the next chunk of data.
      {
         local $\ = undef if (defined $\);
         local $/ = $LF   if ($/ ne $LF );

         $_dat_ex->() if $_lock_chn;
         print {$_DAT_W_SOCK} $_output_tag . $LF . $_chn . $LF;
         MCE::Util::_sock_ready($_DAU_W_SOCK, -1) if $_is_MSWin32;
         chomp($_len = <$_DAU_W_SOCK>);

         unless ($_len) {
            $_dat_un->() if $_lock_chn;
            return;
         }

         chomp($_chunk_id = <$_DAU_W_SOCK>);

         if ($_chunk_id > 1 && $_chop_len) {
            $_p = $_chop_len; $_ = $_chop_str;
         } else {
            $_p = 0;
         }

         read $_DAU_W_SOCK, $_, $_len, $_p;

         $_dat_un->() if $_lock_chn;
      }

      ## Call user function.
      if ($_proc_type == REQUEST_ARRAY) {
         my $_chunk_ref = $self->{thaw}($_); undef $_;
         $_ = ($_chunk_size == 1) ? $_chunk_ref->[0] : $_chunk_ref;
         $_wuf->($self, $_chunk_ref, $_chunk_id);
      }
      elsif ($_proc_type == REQUEST_HASH) {
         my $_chunk_ref = { @{ $self->{thaw}($_) } }; undef $_;
         $_ = $_chunk_ref;
         $_wuf->($self, $_chunk_ref, $_chunk_id);
      }
      else {
         $_ = ${ $self->{thaw}($_) };
         if ($_use_slurpio) {
            if ($_chop_len && substr($_, -$_chop_len) eq $_chop_str) {
               substr($_, -$_chop_len, $_chop_len, '');
            }
            local $_ = \$_;
            $_wuf->($self, $_, $_chunk_id);
         }
         else {
            if ($_chunk_size == 1) {
               if ($_chop_len && substr($_, -$_chop_len) eq $_chop_str) {
                  substr($_, -$_chop_len, $_chop_len, '');
               }
               $_wuf->($self, [ $_ ], $_chunk_id);
            }
            else {
               my @_recs;
               {
                  local $/ = $_RS if ($/ ne $_RS);
                  _sync_buffer_to_array(\$_, \@_recs, $_chop_str);
                  undef $_;
               }
               if ($_chop_len) {
                  for my $i (0 .. @_recs - 1) {
                     if (substr($_recs[$i], -$_chop_len) eq $_chop_str) {
                        substr($_recs[$i], -$_chop_len, $_chop_len, '');
                     }
                  }
               }
               local $_ = \@_recs;
               $_wuf->($self, \@_recs, $_chunk_id);
            }
         }
      }
   }

   _WORKER_REQUEST_CHUNK__LAST:

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

MCE::Core::Input::Request - Array reference and Glob reference input reader

=head1 VERSION

This document describes MCE::Core::Input::Request version 1.879

=head1 DESCRIPTION

This package provides the request chunk method used internally by the worker
process. Distribution follows a bank-queuing model.

There is no public API.

=head1 SEE ALSO

The syntax for the C<input_data> option is described in L<MCE::Core>.

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

