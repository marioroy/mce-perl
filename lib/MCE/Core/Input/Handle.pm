###############################################################################
## ----------------------------------------------------------------------------
## File_path and Scalar_ref input reader.
##
## This package provides the read handle method used internally by the worker
## process. Distribution follows a bank-queuing model.
##
## There is no public API.
##
###############################################################################

package MCE::Core::Input::Handle;

use strict;
use warnings;

our $VERSION = '1.805';

## Items below are folded into MCE.

package # hide from rpm
   MCE;

no warnings qw( threads recursion uninitialized );

use Fcntl qw( SEEK_CUR );
use bytes;

my $_que_read_size = $MCE::_que_read_size;
my $_que_template  = $MCE::_que_template;

###############################################################################
## ----------------------------------------------------------------------------
## Worker process -- Read handle.
##
###############################################################################

sub _systell {
   sysseek($_[0], 0, SEEK_CUR);
}

sub _worker_read_handle {

   my ($self, $_proc_type, $_input_data) = @_;

   @_ = ();

   _croak('MCE::_worker_read_handle: (user_func) is not specified')
      unless (defined $self->{user_func});

   my $_QUE_R_SOCK  = $self->{_que_r_sock};
   my $_QUE_W_SOCK  = $self->{_que_w_sock};
   my $_chunk_size  = $self->{chunk_size};
   my $_use_slurpio = $self->{use_slurpio};
   my $_parallel_io = $self->{parallel_io};
   my $_RS          = $self->{RS} || $/;
   my $_RS_FLG      = (!$_RS || $_RS ne $LF);
   my $_wuf         = $self->{_wuf};

   my ($_data_size, $_next, $_chunk_id, $_offset_pos, $_IN_FILE, $_tmp_cs);
   my ($_chop_len, $_chop_str, $_p);

   if (length $_RS > 1 && substr($_RS, 0, 1) eq "\n") {
      $_chop_str = substr($_RS, 1);
      $_chop_len = length $_chop_str;
   } else {
      $_chop_str = '';
      $_chop_len = 0;
   }

   $_data_size = ($_proc_type == READ_MEMORY)
      ? length ${ $_input_data } : -s $_input_data;

   $_chunk_id  = $_offset_pos = 0;

   open    $_IN_FILE, '<', $_input_data or die "$_input_data: $!\n";
   binmode $_IN_FILE;

   ## -------------------------------------------------------------------------

   $self->{_next_jmp} = sub { goto _WORKER_READ_HANDLE__NEXT; };
   $self->{_last_jmp} = sub { goto _WORKER_READ_HANDLE__LAST; };

   local $_;

   _WORKER_READ_HANDLE__NEXT:

   while (1) {
      my @_recs; undef $_ if (length > MAX_CHUNK_SIZE);

      $_ = '';

      ## Obtain the next chunk_id and offset position.
      sysread $_QUE_R_SOCK, $_next, $_que_read_size;
      ($_chunk_id, $_offset_pos) = unpack($_que_template, $_next);

      if ($_offset_pos >= $_data_size) {
         syswrite $_QUE_W_SOCK, pack($_que_template, 0, $_offset_pos);
         close $_IN_FILE; undef $_IN_FILE;
         return;
      }

      if (++$_chunk_id > 1 && $_chop_len) {
         $_p = $_chop_len; $_ = $_chop_str;
      } else {
         $_p = 0;
      }

      ## Read data.
      if ($_chunk_size <= MAX_RECS_SIZE) {        # One or many records.
         local $/ = $_RS if ($_RS_FLG);
         seek $_IN_FILE, $_offset_pos, 0;

         if ($_chunk_size == 1) {
            if ($_p) {
               $_ .= <$_IN_FILE>;
            } else {
               $_  = <$_IN_FILE>;
            }
         }
         else {
            if ($_use_slurpio) {
               for my $i (0 .. $_chunk_size - 1) {
                  $_ .= <$_IN_FILE>;
               }
            }
            else {
               if ($_chop_len) {
                  $_recs[0]  = ($_chunk_id > 1) ? $_chop_str : '';
                  $_recs[0] .= <$_IN_FILE>;
                  for my $i (1 .. $_chunk_size - 1) {
                     $_recs[$i]  = $_chop_str;
                     $_recs[$i] .= <$_IN_FILE>;
                     if (length $_recs[$i] == $_chop_len) {
                        delete $_recs[$i];
                        last;
                     }
                  }
               }
               else {
                  for my $i (0 .. $_chunk_size - 1) {
                     $_recs[$i] = <$_IN_FILE>;
                     unless (defined $_recs[$i]) {
                        delete $_recs[$i];
                        last;
                     }
                  }
               }
            }
         }

         syswrite $_QUE_W_SOCK,
            pack($_que_template, $_chunk_id, tell $_IN_FILE);
      }
      else {                                      # Large chunk.
         local $/ = $_RS if ($_RS_FLG);

         if ($_parallel_io && ! $_RS_FLG) {
            syswrite $_QUE_W_SOCK,
               pack($_que_template, $_chunk_id, $_offset_pos + $_chunk_size);

            $_tmp_cs = $_chunk_size;
            seek $_IN_FILE, $_offset_pos, 0;

            if ($_offset_pos) {
               $_tmp_cs -= length <$_IN_FILE> || 0;
            }

            if ($_proc_type == READ_FILE) {
               sysseek $_IN_FILE, tell( $_IN_FILE ), 0;
               sysread $_IN_FILE, $_, $_tmp_cs, $_p;
                  seek $_IN_FILE, _systell( $_IN_FILE ), 0;
            }
            else {
               read $_IN_FILE, $_, $_tmp_cs, $_p;
            }

            $_ .= <$_IN_FILE>;
         }
         else {
            if ($_proc_type == READ_FILE) {
               sysseek $_IN_FILE, $_offset_pos, 0;
               sysread $_IN_FILE, $_, $_chunk_size, $_p;
                  seek $_IN_FILE, _systell( $_IN_FILE ), 0;
            }
            else {
               seek $_IN_FILE, $_offset_pos, 0;
               read $_IN_FILE, $_, $_chunk_size, $_p;
            }

            $_ .= <$_IN_FILE>;

            syswrite $_QUE_W_SOCK,
               pack($_que_template, $_chunk_id, tell $_IN_FILE);
         }
      }

      ## Call user function.
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
            if ($_chunk_size > MAX_RECS_SIZE) {
               local $/ = $_RS if ($_RS_FLG);
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

   _WORKER_READ_HANDLE__LAST:

   close $_IN_FILE; undef $_IN_FILE;

   return;
}

1;

