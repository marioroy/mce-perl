###############################################################################
## ----------------------------------------------------------------------------
## Iterator reader.
##
## This package, used interally by the worker process, provides support for
## user specified iterators assigned to input_data.
##
## There is no public API.
##
###############################################################################

package MCE::Core::Input::Iterator;

use strict;
use warnings;

our $VERSION = '1.879';

## Items below are folded into MCE.

package # hide from rpm
   MCE;

no warnings qw( threads recursion uninitialized );

###############################################################################
## ----------------------------------------------------------------------------
## Worker process -- User Iterator.
##
###############################################################################

my $_is_MSWin32 = ( $^O eq 'MSWin32' ) ? 1 : 0;

sub _worker_user_iterator {

   my ($self) = @_;

   @_ = ();

   _croak('MCE::_worker_user_iterator: (user_func) is not specified')
      unless (defined $self->{user_func});

   my $_chn         = $self->{_chn};
   my $_DAT_LOCK    = $self->{_dat_lock};
   my $_DAT_W_SOCK  = $self->{_dat_w_sock}->[0];
   my $_DAU_W_SOCK  = $self->{_dat_w_sock}->[$_chn];
   my $_lock_chn    = $self->{_lock_chn};
   my $_chunk_size  = $self->{chunk_size};
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

   my ($_chunk_id, $_len);

   ## -------------------------------------------------------------------------

   $self->{_next_jmp} = sub { goto _WORKER_USER_ITERATOR__NEXT; };
   $self->{_last_jmp} = sub { goto _WORKER_USER_ITERATOR__LAST; };

   local $_;

   _WORKER_USER_ITERATOR__NEXT:

   while (1) {
      undef $_ if (length > MAX_GC_SIZE);

      $_ = '';

      ## Obtain the next chunk of data.
      {
         local $\ = undef if (defined $\);
         local $/ = $LF   if ($/ ne $LF );

         $_dat_ex->() if $_lock_chn;
         print {$_DAT_W_SOCK} OUTPUT_I_REF . $LF . $_chn . $LF;
         MCE::Util::_sock_ready($_DAU_W_SOCK, -1) if $_is_MSWin32;
         chomp($_len = <$_DAU_W_SOCK>);

         if ($_len < 0) {
            $_dat_un->() if $_lock_chn;
            return;
         }

         chomp($_chunk_id = <$_DAU_W_SOCK>);
         read $_DAU_W_SOCK, $_, $_len;

         $_dat_un->() if $_lock_chn;
      }

      ## Call user function.
      my $_chunk_ref = $self->{thaw}($_); undef $_;
      $_ = ($_chunk_size == 1) ? $_chunk_ref->[0] : $_chunk_ref;
      $_wuf->($self, $_chunk_ref, $_chunk_id);
   }

   _WORKER_USER_ITERATOR__LAST:

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

MCE::Core::Input::Iterator - Iterator reader

=head1 VERSION

This document describes MCE::Core::Input::Iterator version 1.879

=head1 DESCRIPTION

This package, used interally by the worker process, provides support for
user specified iterators assigned to C<input_data>.

There is no public API.

=head1 SEE ALSO

The syntax for the C<input_data> option is described in L<MCE::Core>.

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

