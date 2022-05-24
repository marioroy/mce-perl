###############################################################################
## ----------------------------------------------------------------------------
## Hybrid (normal and priority) queues.
##
###############################################################################

package MCE::Queue;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized );

our $VERSION = '1.879';

## no critic (Subroutines::ProhibitExplicitReturnUndef)
## no critic (TestingAndDebugging::ProhibitNoStrict)

use Scalar::Util qw( looks_like_number );
use MCE::Util qw( $LF );
use MCE::Mutex ();

###############################################################################
## ----------------------------------------------------------------------------
## Import routine.
##
###############################################################################

our ($HIGHEST,$LOWEST, $FIFO,$LIFO, $LILO,$FILO) = (1,0, 1,0, 1,0);

my ($_def, $_imported) = ({});

sub import {
   my ($_class, $_pkg) = (shift, caller);

   ## Process module arguments.
   my $_p = $_def->{$_pkg} = {
      AWAIT => 0, PORDER => $HIGHEST, TYPE => $FIFO,
   };

   while (my $_argument = shift) {
      my $_arg = lc $_argument;

      $_p->{AWAIT } = shift, next if ( $_arg eq 'await'  );
      $_p->{PORDER} = shift, next if ( $_arg eq 'porder' );
      $_p->{TYPE  } = shift, next if ( $_arg eq 'type'   );

      _croak("Error: ($_argument) invalid module option");
   }

   return if $_imported++;

   ## Define public methods to internal methods.
   no strict 'refs'; no warnings 'redefine';

   if ($INC{'MCE.pm'} && MCE->wid == 0) {
      _mce_m_init();
   }

   *{ 'MCE::Queue::await'      } = \&_mce_m_await;
   *{ 'MCE::Queue::clear'      } = \&_mce_m_clear;
   *{ 'MCE::Queue::end'        } = \&_mce_m_end;
   *{ 'MCE::Queue::enqueue'    } = \&_mce_m_enqueue;
   *{ 'MCE::Queue::enqueuep'   } = \&_mce_m_enqueuep;
   *{ 'MCE::Queue::dequeue'    } = \&_mce_m_dequeue;
   *{ 'MCE::Queue::dequeue_nb' } = \&_mce_m_dequeue_nb;
   *{ 'MCE::Queue::pending'    } = \&_mce_m_pending;
   *{ 'MCE::Queue::insert'     } = \&_mce_m_insert;
   *{ 'MCE::Queue::insertp'    } = \&_mce_m_insertp;
   *{ 'MCE::Queue::peek'       } = \&_mce_m_peek;
   *{ 'MCE::Queue::peekp'      } = \&_mce_m_peekp;
   *{ 'MCE::Queue::peekh'      } = \&_mce_m_peekh;
   *{ 'MCE::Queue::heap'       } = \&_mce_m_heap;

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Define constants & variables.
##
###############################################################################

use constant {
   OUTPUT_W_QUE => 'W~QUE',  # Await from the queue
   OUTPUT_C_QUE => 'C~QUE',  # Clear the queue
   OUTPUT_E_QUE => 'E~QUE',  # End the queue

   OUTPUT_A_QUE => 'A~QUE',  # Enqueue into queue (array)
   OUTPUT_A_QUP => 'A~QUP',  # Enqueue into queue (array (p))
   OUTPUT_D_QUE => 'D~QUE',  # Dequeue from queue (blocking)
   OUTPUT_D_QUN => 'D~QUN',  # Dequeue from queue (non-blocking)

   OUTPUT_N_QUE => 'N~QUE',  # Return the number of items
   OUTPUT_I_QUE => 'I~QUE',  # Insert into queue
   OUTPUT_I_QUP => 'I~QUP',  # Insert into queue (p)

   OUTPUT_P_QUE => 'P~QUE',  # Peek into queue
   OUTPUT_P_QUP => 'P~QUP',  # Peek into queue (p)
   OUTPUT_P_QUH => 'P~QUH',  # Peek into heap
   OUTPUT_H_QUE => 'H~QUE'   # Return the heap
};

## Attributes used internally.
## _qr_sock _qw_sock _datp _datq _dsem _heap _id _init_pid _porder _type
## _ar_sock _aw_sock _asem _tsem

my $_tid = $INC{'threads.pm'} ? threads->tid() : 0;

my %_valid_fields_new = map { $_ => 1 } qw(
   await barrier fast gather porder queue type
);

my $_all = {};
my $_qid = 0;

sub CLONE {
   $_tid = threads->tid() if $INC{'threads.pm'};
}

sub DESTROY {
   my ($_Q) = @_;
   my $_pid = $_tid ? $$ .'.'. $_tid : $$;

   delete $_all->{ $_Q->{_id} } if exists $_Q->{_id};
   undef $_Q->{_datp}, undef $_Q->{_datq}, undef $_Q->{_heap};

   if (exists $_Q->{_init_pid} && $_Q->{_init_pid} eq $_pid) {
      MCE::Util::_destroy_socks($_Q, qw(_aw_sock _ar_sock _qw_sock _qr_sock));
   }

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## New instance instantiation.
##
###############################################################################

sub new {
   my ($_class, %_argv) = @_;
   my $_pkg = caller;

   @_ = ();

   my $_Q = {}; bless($_Q, ref($_class) || $_class);

   for my $_p (keys %_argv) {
      _croak("Queue: ($_p) is not a valid constructor argument")
         unless (exists $_valid_fields_new{$_p});
   }

   $_Q->{_asem} =  0;  # Semaphore count variable for the ->await method
   $_Q->{_datp} = {};  # Priority data { p1 => [ ], p2 => [ ], pN => [ ] }
   $_Q->{_heap} = [];  # Priority heap [ pN, p2, p1 ] in heap order
                       # fyi, _datp will always dequeue before _datq

   $_Q->{_await} = (defined $_argv{await})
      ? $_argv{await} : $_def->{$_pkg}{AWAIT} || 0;

   $_Q->{_porder} = (defined $_argv{porder})
      ? $_argv{porder} : $_def->{$_pkg}{PORDER} || $HIGHEST;

   $_Q->{_type} = (defined $_argv{type})
      ? $_argv{type} : $_def->{$_pkg}{TYPE} || $FIFO;

   ## -------------------------------------------------------------------------

   if (exists $_argv{queue}) {
      _croak('Queue: (queue) is not an ARRAY reference')
         unless (ref $_argv{queue} eq 'ARRAY');

      $_Q->{_datq} = $_argv{queue};
   }
   else {
      $_Q->{_datq} = [];
   }

   if (exists $_argv{gather}) {
      _croak('Queue: (gather) is not a CODE reference')
         unless (ref $_argv{gather} eq 'CODE');

      $_Q->{gather} = $_argv{gather};
   }

   ## -------------------------------------------------------------------------

   $_Q->{_init_pid} = $_tid ? $$ .'.'. $_tid : $$;
   $_Q->{_id} = ++$_qid; $_all->{$_qid} = $_Q;
   $_Q->{_dsem} = 0;

   MCE::Util::_sock_pair($_Q, qw(_qr_sock _qw_sock), undef, 1);
   MCE::Util::_sock_pair($_Q, qw(_ar_sock _aw_sock), undef, 1) if $_Q->{_await};

   return $_Q;
}

###############################################################################
## ----------------------------------------------------------------------------
## Private methods.
##
###############################################################################

sub _croak {
   unless ($INC{'MCE.pm'}) {
      $\ = undef; require Carp; goto &Carp::croak;
   } else {
      goto &MCE::_croak;
   }
}

## Add items to the tail of the queue with priority level.

sub _enqueuep {
   my ($_Q, $_p) = (shift, shift);

   ## Enlist priority into the heap.
   if (!exists $_Q->{_datp}->{$_p} || @{ $_Q->{_datp}->{$_p} } == 0) {

      unless (scalar @{ $_Q->{_heap} }) {
         push @{ $_Q->{_heap} }, $_p;
      }
      elsif ($_Q->{_porder}) {
         $_Q->_heap_insert_high($_p);
      }
      else {
         $_Q->_heap_insert_low($_p);
      }
   }

   ## Append item(s) into the queue.
   push @{ $_Q->{_datp}->{$_p} }, @_;

   return;
}

## Return one item from the queue.

sub _dequeue {
   my ($_Q) = @_;

   ## Return item from the non-priority queue.
   unless (scalar @{ $_Q->{_heap} }) {
      return ($_Q->{_type})
         ? shift @{ $_Q->{_datq} } : pop @{ $_Q->{_datq} };
   }

   my $_p = $_Q->{_heap}->[0];

   ## Delist priority from the heap when 1 item remains.
   shift @{ $_Q->{_heap} } if (@{ $_Q->{_datp}->{$_p} } == 1);

   ## Return item from the priority queue.
   return ($_Q->{_type})
      ? shift @{ $_Q->{_datp}->{$_p} } : pop @{ $_Q->{_datp}->{$_p} };
}

## Helper method for getting the reference to the underlying array.
## Use with test scripts for comparing data only (not a public API).

sub _get_aref {
   my ($_Q, $_p) = @_;

   return if ($INC{'MCE.pm'} && !defined $MCE::MCE->{_wid});
   return if (defined $MCE::MCE && $MCE::MCE->{_wid});

   if (defined $_p) {
      _croak('Queue: (get_aref priority) is not an integer')
         if (!looks_like_number($_p) || int($_p) != $_p);

      return undef unless (exists $_Q->{_datp}->{$_p});
      return $_Q->{_datp}->{$_p};
   }

   return $_Q->{_datq};
}

## Insert priority into the heap. A lower priority level comes first.

sub _heap_insert_low {
   my ($_Q, $_p) = @_;

   ## Insert priority at the head of the heap.
   if ($_p < $_Q->{_heap}->[0]) {
      unshift @{ $_Q->{_heap} }, $_p;
   }

   ## Insert priority at the end of the heap.
   elsif ($_p > $_Q->{_heap}->[-1]) {
      push @{ $_Q->{_heap} }, $_p;
   }

   ## Insert priority through binary search.
   else {
      my $_lower = 0; my $_upper = @{ $_Q->{_heap} };

      while ($_lower < $_upper) {
         my $_midpoint = $_lower + (($_upper - $_lower) >> 1);
         if ($_p > $_Q->{_heap}->[$_midpoint]) {
            $_lower = $_midpoint + 1;
         } else {
            $_upper = $_midpoint;
         }
      }

      ## Insert priority into the heap.
      splice @{ $_Q->{_heap} }, $_lower, 0, $_p;
   }

   return;
}

## Insert priority into the heap. A higher priority level comes first.

sub _heap_insert_high {
   my ($_Q, $_p) = @_;

   ## Insert priority at the head of the heap.
   if ($_p > $_Q->{_heap}->[0]) {
      unshift @{ $_Q->{_heap} }, $_p;
   }

   ## Insert priority at the end of the heap.
   elsif ($_p < $_Q->{_heap}->[-1]) {
      push @{ $_Q->{_heap} }, $_p;
   }

   ## Insert priority through binary search.
   else {
      my $_lower = 0; my $_upper = @{ $_Q->{_heap} };

      while ($_lower < $_upper) {
         my $_midpoint = $_lower + (($_upper - $_lower) >> 1);
         if ($_p < $_Q->{_heap}->[$_midpoint]) {
            $_lower = $_midpoint + 1;
         } else {
            $_upper = $_midpoint;
         }
      }

      ## Insert priority into the heap.
      splice @{ $_Q->{_heap} }, $_lower, 0, $_p;
   }

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Output routines for the manager process.
##
###############################################################################

{
   my ($_MCE, $_DAU_R_SOCK_REF, $_DAU_R_SOCK, $_cnt, $_i, $_id);
   my ($_len, $_p, $_t, $_Q, $_has_data, $_pending);

   my %_output_function = (

      OUTPUT_W_QUE.$LF => sub {                   # Await from the queue
         $_DAU_R_SOCK = ${ $_DAU_R_SOCK_REF };

         chomp($_id = <$_DAU_R_SOCK>),
         chomp($_t  = <$_DAU_R_SOCK>);

         $_Q = $_all->{$_id};
         $_Q->{_tsem} = $_t;

         if ($_Q->pending() <= $_t) {
            syswrite($_Q->{_aw_sock}, $LF);
         } else {
            $_Q->{_asem} += 1;
         }

         print {$_DAU_R_SOCK} $LF;

         return;
      },

      OUTPUT_C_QUE.$LF => sub {                   # Clear the queue
         $_DAU_R_SOCK = ${ $_DAU_R_SOCK_REF };

         chomp($_id = <$_DAU_R_SOCK>);
         _mce_m_clear($_all->{$_id});

         print {$_DAU_R_SOCK} $LF;

         return;
      },

      OUTPUT_E_QUE.$LF => sub {                   # End the queue
         $_DAU_R_SOCK = ${ $_DAU_R_SOCK_REF };

         chomp($_id = <$_DAU_R_SOCK>);
         _mce_m_end($_all->{$_id});

         print {$_DAU_R_SOCK} $LF;

         return;
      },

      ## ----------------------------------------------------------------------

      OUTPUT_A_QUE.$LF => sub {                   # Enqueue into queue (A)
         $_DAU_R_SOCK = ${ $_DAU_R_SOCK_REF };

         chomp($_id  = <$_DAU_R_SOCK>),
         chomp($_len = <$_DAU_R_SOCK>);

         read $_DAU_R_SOCK, my($_buf), $_len;

         $_Q = $_all->{$_id};

         if ($_Q->{gather}) {
            local $_ = $_MCE->{thaw}($_buf);
            $_Q->{gather}($_Q, @{ $_ });
         }
         else {
            $_Q->_mce_m_enqueue(@{ $_MCE->{thaw}($_buf) });
         }

         return;
      },

      OUTPUT_A_QUP.$LF => sub {                   # Enqueue into queue (A,p)
         $_DAU_R_SOCK = ${ $_DAU_R_SOCK_REF };

         chomp($_id  = <$_DAU_R_SOCK>),
         chomp($_p   = <$_DAU_R_SOCK>),
         chomp($_len = <$_DAU_R_SOCK>);

         read $_DAU_R_SOCK, my($_buf), $_len;

         $_Q = $_all->{$_id};
         $_Q->_mce_m_enqueuep($_p, @{ $_MCE->{thaw}($_buf) });

         return;
      },

      ## ----------------------------------------------------------------------

      OUTPUT_D_QUE.$LF => sub {                   # Dequeue from queue (B)
         $_DAU_R_SOCK = ${ $_DAU_R_SOCK_REF };

         chomp($_id  = <$_DAU_R_SOCK>),
         chomp($_cnt = <$_DAU_R_SOCK>);

         $_cnt = 0 if ($_cnt == 1);
         $_Q = $_all->{$_id};

         my (@_items, $_buf);

         if ($_cnt) {
            my $_pending = @{ $_Q->{_datq} };

            if ($_pending < $_cnt && scalar @{ $_Q->{_heap} }) {
               for my $_h (@{ $_Q->{_heap} }) {
                  $_pending += @{ $_Q->{_datp}->{$_h} };
               }
            }
            $_cnt = $_pending if $_pending < $_cnt;

            for my $_i (1 .. $_cnt) { push @_items, $_Q->_dequeue() }
         }
         else {
            $_has_data = ( @{ $_Q->{_datq} } || @{ $_Q->{_heap} } ) ? 1 : 0;
            $_buf      = $_Q->_dequeue();
         }

         if ($_cnt) {
            $_buf = $_MCE->{freeze}(\@_items);
            print {$_DAU_R_SOCK} length($_buf).$LF, $_buf;
         }
         elsif ($_has_data) {
            $_buf = $_MCE->{freeze}([ $_buf ]);
            print {$_DAU_R_SOCK} length($_buf).$LF, $_buf;
         }
         elsif (exists $_Q->{_ended}) {
            print {$_DAU_R_SOCK} '-2'.$LF;
         }
         else {
            print {$_DAU_R_SOCK} '-1'.$LF;
            $_Q->{_dsem} += 1;
         }

         if ($_Q->{_await} && $_Q->{_asem} && $_Q->pending() <= $_Q->{_tsem}) {
            for my $_i (1 .. $_Q->{_asem}) {
               syswrite($_Q->{_aw_sock}, $LF);
            }
            $_Q->{_asem} = 0;
         }

         return;
      },

      OUTPUT_D_QUN.$LF => sub {                   # Dequeue from queue (NB)
         $_DAU_R_SOCK = ${ $_DAU_R_SOCK_REF };

         chomp($_id  = <$_DAU_R_SOCK>),
         chomp($_cnt = <$_DAU_R_SOCK>);

         $_Q = $_all->{$_id};

         if ($_cnt == 1) {
            my $_buf = $_Q->_dequeue();

            if (defined $_buf) {
               $_buf = $_MCE->{freeze}([ $_buf ]);
               print {$_DAU_R_SOCK} length($_buf).$LF, $_buf;
            }
            else {
               print {$_DAU_R_SOCK} '-1'.$LF;
            }
         }
         else {
            my @_items;
            my $_pending = @{ $_Q->{_datq} };

            if ($_pending < $_cnt && scalar @{ $_Q->{_heap} }) {
               for my $_h (@{ $_Q->{_heap} }) {
                  $_pending += @{ $_Q->{_datp}->{$_h} };
               }
            }
            $_cnt = $_pending if $_pending < $_cnt;

            for my $_i (1 .. $_cnt) { push @_items, $_Q->_dequeue() }

            if ($_cnt) {
               my $_buf = $_MCE->{freeze}(\@_items);
               print {$_DAU_R_SOCK} length($_buf).$LF, $_buf;
            }
            else {
               print {$_DAU_R_SOCK} '-1'.$LF;
            }
         }

         if ($_Q->{_await} && $_Q->{_asem} && $_Q->pending() <= $_Q->{_tsem}) {
            for my $_i (1 .. $_Q->{_asem}) {
               syswrite($_Q->{_aw_sock}, $LF);
            }
            $_Q->{_asem} = 0;
         }

         return;
      },

      ## ----------------------------------------------------------------------

      OUTPUT_N_QUE.$LF => sub {                   # Return number of items
         $_DAU_R_SOCK = ${ $_DAU_R_SOCK_REF };

         chomp($_id = <$_DAU_R_SOCK>);

         print {$_DAU_R_SOCK} $_all->{$_id}->_mce_m_pending().$LF;

         return;
      },

      OUTPUT_I_QUE.$LF => sub {                   # Insert into queue
         $_DAU_R_SOCK = ${ $_DAU_R_SOCK_REF };

         chomp($_id  = <$_DAU_R_SOCK>),
         chomp($_i   = <$_DAU_R_SOCK>),
         chomp($_len = <$_DAU_R_SOCK>);

         read $_DAU_R_SOCK, my($_buf), $_len;

         $_Q = $_all->{$_id};
         $_Q->_mce_m_insert($_i, @{ $_MCE->{thaw}($_buf) });

         return;
      },

      OUTPUT_I_QUP.$LF => sub {                   # Insert into queue (p)
         $_DAU_R_SOCK = ${ $_DAU_R_SOCK_REF };

         chomp($_id  = <$_DAU_R_SOCK>),
         chomp($_p   = <$_DAU_R_SOCK>),
         chomp($_i   = <$_DAU_R_SOCK>),
         chomp($_len = <$_DAU_R_SOCK>);

         read $_DAU_R_SOCK, my($_buf), $_len;

         $_Q = $_all->{$_id};
         $_Q->_mce_m_insertp($_p, $_i, @{ $_MCE->{thaw}($_buf) });

         return;
      },

      ## ----------------------------------------------------------------------

      OUTPUT_P_QUE.$LF => sub {                   # Peek into queue
         my $_buf; $_DAU_R_SOCK = ${ $_DAU_R_SOCK_REF };

         chomp($_id = <$_DAU_R_SOCK>),
         chomp($_i  = <$_DAU_R_SOCK>);

         $_Q   = $_all->{$_id};
         $_buf = $_Q->_mce_m_peek($_i);

         if (defined $_buf) {
            $_buf = $_MCE->{freeze}([ $_buf ]);
            print {$_DAU_R_SOCK} length($_buf).$LF, $_buf;
         } else {
            print {$_DAU_R_SOCK} '-1'.$LF;
         }

         return;
      },

      OUTPUT_P_QUP.$LF => sub {                   # Peek into queue (p)
         my $_buf; $_DAU_R_SOCK = ${ $_DAU_R_SOCK_REF };

         chomp($_id = <$_DAU_R_SOCK>),
         chomp($_p  = <$_DAU_R_SOCK>),
         chomp($_i  = <$_DAU_R_SOCK>);

         $_Q   = $_all->{$_id};
         $_buf = $_Q->_mce_m_peekp($_p, $_i);

         if (defined $_buf) {
            $_buf = $_MCE->{freeze}([ $_buf ]);
            print {$_DAU_R_SOCK} length($_buf).$LF, $_buf;
         } else {
            print {$_DAU_R_SOCK} '-1'.$LF;
         }

         return;
      },

      OUTPUT_P_QUH.$LF => sub {                   # Peek into heap
         my $_buf; $_DAU_R_SOCK = ${ $_DAU_R_SOCK_REF };

         chomp($_id = <$_DAU_R_SOCK>),
         chomp($_i  = <$_DAU_R_SOCK>);

         $_Q   = $_all->{$_id};
         $_buf = $_Q->_mce_m_peekh($_i);

         if (defined $_buf) {
            $_buf = $_MCE->{freeze}([ $_buf ]);
            print {$_DAU_R_SOCK} length($_buf).$LF, $_buf;
         } else {
            print {$_DAU_R_SOCK} '-1'.$LF;
         }

         return;
      },

      OUTPUT_H_QUE.$LF => sub {                   # Return the heap
         my $_buf; $_DAU_R_SOCK = ${ $_DAU_R_SOCK_REF };

         chomp($_id = <$_DAU_R_SOCK>);

         $_Q   = $_all->{$_id};
         $_buf = $_MCE->{freeze}([ $_Q->_mce_m_heap() ]);

         print {$_DAU_R_SOCK} length($_buf).$LF, $_buf;

         return;
      },

   );

   ## -------------------------------------------------------------------------

   sub _mce_m_loop_begin {
      ($_MCE, $_DAU_R_SOCK_REF) = @_;

      return;
   }

   sub _mce_m_loop_end {
      $_MCE = $_DAU_R_SOCK_REF = $_DAU_R_SOCK = $_cnt = $_i = $_id =
         $_len = $_p = $_Q = undef;

      return;
   }

   sub _mce_m_init {
      MCE::_attach_plugin(
         \%_output_function, \&_mce_m_loop_begin, \&_mce_m_loop_end,
         \&_mce_w_init
      );

      return;
   }

}

###############################################################################
## ----------------------------------------------------------------------------
## Methods for the manager process.
##
###############################################################################

## await ( pending_threshold )

sub _mce_m_await {
   # Handled by the manager process when called by MCE workers.
   return;
}

## clear ( )

sub _mce_m_clear {
   my ($_Q) = @_;

   %{ $_Q->{_datp} } = ();
   @{ $_Q->{_datq} } = ();
   @{ $_Q->{_heap} } = ();

   return;
}

## end ( )

sub _mce_m_end {
   my ($_Q) = @_;

   if (!exists $_Q->{_ended}) {
      for my $_i (1 .. $_Q->{_dsem}) { syswrite($_Q->{_qw_sock}, $LF) }
      $_Q->{_dsem} = 0, $_Q->{_ended} = undef;
   }

   return;
}

## enqueue ( item [, item, ... ] )

sub _mce_m_enqueue {
   my $_Q = shift;

   return unless (scalar @_);

   if (exists $_Q->{_ended}) {
      warn "Queue: (enqueue) called on queue that has been 'end'ed\n";
      return;
   }

   if ($_Q->{_dsem}) {
      for my $_i (1 .. scalar @_) {
         $_Q->{_dsem} -= 1, syswrite($_Q->{_qw_sock}, $LF);
         last unless $_Q->{_dsem};
      }
   }

   ## Append item(s) into the queue.
   push @{ $_Q->{_datq} }, @_;

   return;
}

## enqueuep ( priority, item [, item, ... ] )

sub _mce_m_enqueuep {
   my ($_Q, $_p) = (shift, shift);

   _croak('Queue: (enqueuep priority) is not an integer')
      if (!looks_like_number($_p) || int($_p) != $_p);

   return unless (scalar @_);

   if (exists $_Q->{_ended}) {
      warn "Queue: (enqueuep) called on queue that has been 'end'ed\n";
      return;
   }

   if ($_Q->{_dsem}) {
      for my $_i (1 .. scalar @_) {
         $_Q->{_dsem} -= 1, syswrite($_Q->{_qw_sock}, $LF);
         last unless $_Q->{_dsem};
      }
   }

   $_Q->_enqueuep($_p, @_);

   return;
}

## dequeue ( count )
## dequeue ( )

sub _mce_m_dequeue {
   my ($_Q, $_cnt) = @_;
   my (@_items, $_has_data, $_buf);

   if (defined $_cnt && $_cnt ne '1') {
      _croak('Queue: (dequeue count argument) is not valid')
         if (!looks_like_number($_cnt) || int($_cnt) != $_cnt || $_cnt < 1);

      my $_pending = @{ $_Q->{_datq} };

      if ($_pending < $_cnt && scalar @{ $_Q->{_heap} }) {
         for my $_h (@{ $_Q->{_heap} }) {
            $_pending += @{ $_Q->{_datp}->{$_h} };
         }
      }
      $_cnt = $_pending if $_pending < $_cnt;

      for my $_i (1 .. $_cnt) { push @_items, $_Q->_dequeue() }
   }
   else {
      $_has_data = ( @{ $_Q->{_datq} } || @{ $_Q->{_heap} } ) ? 1 : 0;
      $_buf      = $_Q->_dequeue();
   }

   return @_items if (scalar  @_items);
   return $_buf   if ($_has_data);
   return ()      if (exists  $_Q->{_ended});

   $_Q->{_dsem} += 1, MCE::Util::_sysread($_Q->{_qr_sock}, my($_next), 1);

   goto \&_mce_m_dequeue;
}

## dequeue_nb ( count )
## dequeue_nb ( )

sub _mce_m_dequeue_nb {
   my ($_Q, $_cnt) = @_;

   if (defined $_cnt && $_cnt ne '1') {
      _croak('Queue: (dequeue count argument) is not valid')
         if (!looks_like_number($_cnt) || int($_cnt) != $_cnt || $_cnt < 1);

      my $_pending = @{ $_Q->{_datq} };

      if ($_pending < $_cnt && scalar @{ $_Q->{_heap} }) {
         for my $_h (@{ $_Q->{_heap} }) {
            $_pending += @{ $_Q->{_datp}->{$_h} };
         }
      }

      $_cnt = $_pending if $_pending < $_cnt;

      return map { $_Q->_dequeue() } 1 .. $_cnt;
   }

   my $_buf = $_Q->_dequeue();

   return defined($_buf) ? $_buf : ();
}

## pending ( )

sub _mce_m_pending {
   my ($_Q) = @_;
   my $_pending = @{ $_Q->{_datq} };

   if (scalar @{ $_Q->{_heap} }) {
      for my $_h (@{ $_Q->{_heap} }) {
         $_pending += @{ $_Q->{_datp}->{$_h} };
      }
   }

   return (exists $_Q->{_ended})
      ? $_pending ? $_pending : undef
      : $_pending;
}

## insert ( index, item [, item, ... ] )

sub _mce_m_insert {
   my ($_Q, $_i) = (shift, shift);

   _croak('Queue: (insert index) is not an integer')
      if (!looks_like_number($_i) || int($_i) != $_i);

   return unless (scalar @_);

   if (exists $_Q->{_ended}) {
      warn "Queue: (insert) called on queue that has been 'end'ed\n";
      return;
   }

   if ($_Q->{_dsem}) {
      for my $_i (1 .. scalar @_) {
         $_Q->{_dsem} -= 1, syswrite($_Q->{_qw_sock}, $LF);
         last unless $_Q->{_dsem};
      }
   }

   if (abs($_i) > scalar @{ $_Q->{_datq} }) {
      if ($_i >= 0) {
         if ($_Q->{_type}) {
            push @{ $_Q->{_datq} }, @_;
         } else {
            unshift @{ $_Q->{_datq} }, @_;
         }
      }
      else {
         if ($_Q->{_type}) {
            unshift @{ $_Q->{_datq} }, @_;
         } else {
            push @{ $_Q->{_datq} }, @_;
         }
      }
   }
   else {
      if (!$_Q->{_type}) {
         $_i = ($_i >= 0)
            ? scalar(@{ $_Q->{_datq} }) - $_i
            : abs($_i);
      }
      splice @{ $_Q->{_datq} }, $_i, 0, @_;
   }

   return;
}

## insertp ( priority, index, item [, item, ... ] )

sub _mce_m_insertp {
   my ($_Q, $_p, $_i) = (shift, shift, shift);

   _croak('Queue: (insertp priority) is not an integer')
      if (!looks_like_number($_p) || int($_p) != $_p);
   _croak('Queue: (insertp index) is not an integer')
      if (!looks_like_number($_i) || int($_i) != $_i);

   return unless (scalar @_);

   if (exists $_Q->{_ended}) {
      warn "Queue: (insertp) called on queue that has been 'end'ed\n";
      return;
   }

   if ($_Q->{_dsem}) {
      for my $_i (1 .. scalar @_) {
         $_Q->{_dsem} -= 1, syswrite($_Q->{_qw_sock}, $LF);
         last unless $_Q->{_dsem};
      }
   }

   if (exists $_Q->{_datp}->{$_p} && scalar @{ $_Q->{_datp}->{$_p} }) {

      if (abs($_i) > scalar @{ $_Q->{_datp}->{$_p} }) {
         if ($_i >= 0) {
            if ($_Q->{_type}) {
               push @{ $_Q->{_datp}->{$_p} }, @_;
            } else {
               unshift @{ $_Q->{_datp}->{$_p} }, @_;
            }
         }
         else {
            if ($_Q->{_type}) {
               unshift @{ $_Q->{_datp}->{$_p} }, @_;
            } else {
               push @{ $_Q->{_datp}->{$_p} }, @_;
            }
         }
      }
      else {
         if (!$_Q->{_type}) {
            $_i = ($_i >=0)
               ? scalar(@{ $_Q->{_datp}->{$_p} }) - $_i
               : abs($_i);
         }
         splice @{ $_Q->{_datp}->{$_p} }, $_i, 0, @_;
      }
   }
   else {
      $_Q->_enqueuep($_p, @_);
   }

   return;
}

## peek ( index )
## peek ( )

sub _mce_m_peek {
   my ($_Q, $_i) = @_;

   if ($_i) {
      _croak('Queue: (peek index) is not an integer')
         if (!looks_like_number($_i) || int($_i) != $_i);
   }
   else { $_i = 0 }

   return undef if (abs($_i) > scalar @{ $_Q->{_datq} });

   if (!$_Q->{_type}) {
      $_i = ($_i >= 0)
         ? scalar(@{ $_Q->{_datq} }) - ($_i + 1)
         : abs($_i + 1);
   }

   return $_Q->{_datq}->[$_i];
}

## peekp ( priority, index )
## peekp ( priority )

sub _mce_m_peekp {
   my ($_Q, $_p, $_i) = @_;

   if ($_i) {
      _croak('Queue: (peekp index) is not an integer')
         if (!looks_like_number($_i) || int($_i) != $_i);
   }
   else { $_i = 0 }

   _croak('Queue: (peekp priority) is not an integer')
      if (!looks_like_number($_p) || int($_p) != $_p);

   return undef unless (exists $_Q->{_datp}->{$_p});
   return undef if (abs($_i) > scalar @{ $_Q->{_datp}->{$_p} });

   if (!$_Q->{_type}) {
      $_i = ($_i >= 0)
         ? scalar(@{ $_Q->{_datp}->{$_p} }) - ($_i + 1)
         : abs($_i + 1);
   }

   return $_Q->{_datp}->{$_p}->[$_i];
}

## peekh ( index )
## peekh ( )

sub _mce_m_peekh {
   my ($_Q, $_i) = @_;

   if ($_i) {
      _croak('Queue: (peekh index) is not an integer')
         if (!looks_like_number($_i) || int($_i) != $_i);
   }
   else { $_i = 0 }

   return undef if (abs($_i) > scalar @{ $_Q->{_heap} });
   return $_Q->{_heap}->[$_i];
}

## heap ( )

sub _mce_m_heap {
   return @{ shift->{_heap} };
}

###############################################################################
## ----------------------------------------------------------------------------
## Methods for the worker process.
##
###############################################################################

{
   my (
      $_MCE, $_DAT_LOCK, $_DAT_W_SOCK, $_DAU_W_SOCK, $_chn, $_lock_chn,
      $_dat_ex, $_dat_un, $_len, $_pending
   );

   my $_is_MSWin32 = ($^O eq 'MSWin32') ? 1 : 0;

   my $_req1 = sub {
      local $\ = undef if (defined $\);

      $_dat_ex->() if $_lock_chn;
      print({$_DAT_W_SOCK} $_[0].$LF . $_chn.$LF),
      print({$_DAU_W_SOCK} $_[1], $_[2]);

      $_dat_un->() if $_lock_chn;
   };

   my $_req2 = sub {
      local $\ = undef if (defined $\);
      local $/ = $LF if ($/ ne $LF);

      $_dat_ex->() if $_lock_chn;
      print({$_DAT_W_SOCK} $_[0].$LF . $_chn.$LF),
      print({$_DAU_W_SOCK} $_[1]);
      <$_DAU_W_SOCK>;

      $_dat_un->() if $_lock_chn;
   };

   my $_req3 = sub {
      local $\ = undef if (defined $\);
      local $/ = $LF if ($/ ne $LF);

      $_dat_ex->() if $_lock_chn;
      print({$_DAT_W_SOCK} $_[0].$LF . $_chn.$LF),
      print({$_DAU_W_SOCK} $_[1]);

      chomp($_len = <$_DAU_W_SOCK>);

      if ($_len < 0) {
         $_dat_un->() if $_lock_chn;
         return defined($_[3]) ? () : undef;
      }

      read $_DAU_W_SOCK, my($_buf), $_len;
      $_dat_un->() if $_lock_chn;

      ($_[2] == 1)
         ? ($_MCE->{thaw}($_buf))->[0]
         : @{ $_MCE->{thaw}($_buf) };
   };

   sub _mce_w_init {
      ($_MCE)      = @_;
      $_chn        = $_MCE->{_chn};
      $_DAT_LOCK   = $_MCE->{_dat_lock};
      $_DAT_W_SOCK = $_MCE->{_dat_w_sock}->[0];
      $_DAU_W_SOCK = $_MCE->{_dat_w_sock}->[$_chn];
      $_lock_chn   = $_MCE->{_lock_chn};

      if ($_lock_chn) {
         # inlined for performance
         $_dat_ex = sub {
            my $_pid = $_tid ? $$ .'.'. $_tid : $$;
            MCE::Util::_sysread($_DAT_LOCK->{_r_sock}, my($b), 1), $_DAT_LOCK->{ $_pid } = 1
               unless $_DAT_LOCK->{ $_pid };
         };
         $_dat_un = sub {
            my $_pid = $_tid ? $$ .'.'. $_tid : $$;
            syswrite($_DAT_LOCK->{_w_sock}, '0'), $_DAT_LOCK->{ $_pid } = 0
               if $_DAT_LOCK->{ $_pid };
         };
      }

      $_all = {};

      no strict 'refs'; no warnings 'redefine';

      *{ 'MCE::Queue::await'      } = \&_mce_w_await;
      *{ 'MCE::Queue::clear'      } = \&_mce_w_clear;
      *{ 'MCE::Queue::end'        } = \&_mce_w_end;
      *{ 'MCE::Queue::enqueue'    } = \&_mce_w_enqueue;
      *{ 'MCE::Queue::enqueuep'   } = \&_mce_w_enqueuep;
      *{ 'MCE::Queue::dequeue'    } = \&_mce_w_dequeue;
      *{ 'MCE::Queue::dequeue_nb' } = \&_mce_w_dequeue_nb;
      *{ 'MCE::Queue::pending'    } = \&_mce_w_pending;
      *{ 'MCE::Queue::insert'     } = \&_mce_w_insert;
      *{ 'MCE::Queue::insertp'    } = \&_mce_w_insertp;
      *{ 'MCE::Queue::peek'       } = \&_mce_w_peek;
      *{ 'MCE::Queue::peekp'      } = \&_mce_w_peekp;
      *{ 'MCE::Queue::peekh'      } = \&_mce_w_peekh;
      *{ 'MCE::Queue::heap'       } = \&_mce_w_heap;

      return;
   }

   ## -------------------------------------------------------------------------

   sub _mce_w_await {
      my $_Q = shift; my $_t = shift || 0;

      return $_Q->_mce_m_await() if (exists $_all->{ $_Q->{_id} });

      _croak('Queue: (await) is not enabled for this queue')
         unless ($_Q->{_await});
      _croak('Queue: (await threshold) is not an integer')
         if (!looks_like_number($_t) || int($_t) != $_t);

      $_t = 0 if ($_t < 0);
      $_req2->(OUTPUT_W_QUE, $_Q->{_id}.$LF . $_t.$LF);

      MCE::Util::_sock_ready($_Q->{_ar_sock}) if $_is_MSWin32;
      MCE::Util::_sysread($_Q->{_ar_sock}, my($_next), 1);

      return;
   }

   sub _mce_w_clear {
      my ($_Q) = @_;

      return $_Q->_mce_m_clear() if (exists $_all->{ $_Q->{_id} });

      $_req2->(OUTPUT_C_QUE, $_Q->{_id}.$LF);

      return;
   }

   sub _mce_w_end {
      my ($_Q) = @_;

      return $_Q->_mce_m_end() if (exists $_all->{ $_Q->{_id} });

      $_req2->(OUTPUT_E_QUE, $_Q->{_id}.$LF);

      return;
   }

   ## -------------------------------------------------------------------------

   sub _mce_w_enqueue {
      my $_Q = shift;

      return $_Q->_mce_m_enqueue(@_) if (exists $_all->{ $_Q->{_id} });

      if (scalar @_) {
         my $_tmp = $_MCE->{freeze}([ @_ ]);
         my $_buf = $_Q->{_id}.$LF . length($_tmp).$LF;
         $_req1->(OUTPUT_A_QUE, $_buf, $_tmp);
      }

      return;
   }

   sub _mce_w_enqueuep {
      my ($_Q, $_p) = (shift, shift);

      return $_Q->_mce_m_enqueuep($_p, @_) if (exists $_all->{ $_Q->{_id} });

      _croak('Queue: (enqueuep priority) is not an integer')
         if (!looks_like_number($_p) || int($_p) != $_p);

      if (scalar @_) {
         my $_tmp = $_MCE->{freeze}([ @_ ]);
         my $_buf = $_Q->{_id}.$LF . $_p.$LF . length($_tmp).$LF;
         $_req1->(OUTPUT_A_QUP, $_buf, $_tmp);
      }

      return;
   }

   ## -------------------------------------------------------------------------

   sub _mce_w_dequeue {
      my $_buf; my ($_Q, $_cnt) = @_;

      return $_Q->_mce_m_dequeue($_cnt) if (exists $_all->{ $_Q->{_id} });

      if (defined $_cnt && $_cnt ne '1') {
         _croak('Queue: (dequeue count argument) is not valid')
            if (!looks_like_number($_cnt) || int($_cnt) != $_cnt || $_cnt < 1);
      }
      else {
         $_cnt = 1;
      }

      {
         local $\ = undef if (defined $\);
         local $/ = $LF if ($/ ne $LF);

         $_dat_ex->() if $_lock_chn;

         print({$_DAT_W_SOCK} OUTPUT_D_QUE.$LF . $_chn.$LF),
         print({$_DAU_W_SOCK} $_Q->{_id}.$LF . $_cnt.$LF);
         chomp($_len = <$_DAU_W_SOCK>);

         read($_DAU_W_SOCK, $_buf, $_len) if ($_len >= 0);

         $_dat_un->() if $_lock_chn;
      }

      return ($_MCE->{thaw}($_buf))->[0] if ($_len > 0 && $_cnt == 1);
      return @{ $_MCE->{thaw}($_buf) }   if ($_len > 0);
      return                             if ($_len == -2);

      MCE::Util::_sock_ready($_Q->{_qr_sock}) if $_is_MSWin32;
      MCE::Util::_sysread($_Q->{_qr_sock}, my($_next), 1);

      goto \&_mce_w_dequeue;
   }

   sub _mce_w_dequeue_nb {
      my ($_Q, $_cnt) = @_;

      return $_Q->_mce_m_dequeue_nb($_cnt) if (exists $_all->{ $_Q->{_id} });

      if (defined $_cnt && $_cnt ne '1') {
         _croak('Queue: (dequeue count argument) is not valid')
            if (!looks_like_number($_cnt) || int($_cnt) != $_cnt || $_cnt < 1);
      } else {
         $_cnt = 1;
      }

      $_req3->(OUTPUT_D_QUN, $_Q->{_id}.$LF . $_cnt.$LF, $_cnt, 1);
   }

   ## -------------------------------------------------------------------------

   sub _mce_w_pending {
      my ($_Q) = @_;

      return $_Q->_mce_m_pending() if (exists $_all->{ $_Q->{_id} });

      local $\ = undef if (defined $\);
      local $/ = $LF if ($/ ne $LF);

      $_dat_ex->() if $_lock_chn;
      print({$_DAT_W_SOCK} OUTPUT_N_QUE.$LF . $_chn.$LF),
      print({$_DAU_W_SOCK} $_Q->{_id}.$LF);

      chomp($_pending = <$_DAU_W_SOCK>);
      $_dat_un->() if $_lock_chn;

      length($_pending) ? int($_pending) : undef;
   }

   sub _mce_w_insert {
      my ($_Q, $_i) = (shift, shift);

      return $_Q->_mce_m_insert($_i, @_) if (exists $_all->{ $_Q->{_id} });

      _croak('Queue: (insert index) is not an integer')
         if (!looks_like_number($_i) || int($_i) != $_i);

      return unless (scalar @_);

      my $_tmp = $_MCE->{freeze}([ @_ ]);
      my $_buf = $_Q->{_id}.$LF . $_i.$LF . length($_tmp).$LF . $_tmp;

      $_req1->(OUTPUT_I_QUE, $_buf, '');

      return;
   }

   sub _mce_w_insertp {
      my ($_Q, $_p, $_i) = (shift, shift, shift);

      return $_Q->_mce_m_insertp($_p, $_i, @_) if (exists $_all->{ $_Q->{_id} });

      _croak('Queue: (insertp priority) is not an integer')
         if (!looks_like_number($_p) || int($_p) != $_p);
      _croak('Queue: (insertp index) is not an integer')
         if (!looks_like_number($_i) || int($_i) != $_i);

      return unless (scalar @_);

      my $_tmp = $_MCE->{freeze}([ @_ ]);
      my $_buf = $_Q->{_id}.$LF . $_p.$LF . $_i.$LF . length($_tmp).$LF . $_tmp;

      $_req1->(OUTPUT_I_QUP, $_buf, '');

      return;
   }

   ## -------------------------------------------------------------------------

   sub _mce_w_peek {
      my $_Q = shift; my $_i = shift || 0;

      return $_Q->_mce_m_peek($_i, @_) if (exists $_all->{ $_Q->{_id} });

      _croak('Queue: (peek index) is not an integer')
         if (!looks_like_number($_i) || int($_i) != $_i);

      $_req3->(OUTPUT_P_QUE, $_Q->{_id}.$LF . $_i.$LF, 1);
   }

   sub _mce_w_peekp {
      my ($_Q, $_p) = (shift, shift); my $_i = shift || 0;

      return $_Q->_mce_m_peekp($_p, $_i, @_) if (exists $_all->{ $_Q->{_id} });

      _croak('Queue: (peekp priority) is not an integer')
         if (!looks_like_number($_p) || int($_p) != $_p);
      _croak('Queue: (peekp index) is not an integer')
         if (!looks_like_number($_i) || int($_i) != $_i);

      $_req3->(OUTPUT_P_QUP, $_Q->{_id}.$LF . $_p.$LF . $_i.$LF, 1);
   }

   sub _mce_w_peekh {
      my $_Q = shift; my $_i = shift || 0;

      return $_Q->_mce_m_peekh($_i, @_) if (exists $_all->{ $_Q->{_id} });

      _croak('Queue: (peekh index) is not an integer')
         if (!looks_like_number($_i) || int($_i) != $_i);

      my $_ret = $_req3->(OUTPUT_P_QUH, $_Q->{_id}.$LF . $_i.$LF, 1);

      length($_ret) ? int($_ret) : undef;
   }

   sub _mce_w_heap {
      my ($_Q) = @_;

      return $_Q->_mce_m_heap() if (exists $_all->{ $_Q->{_id} });

      $_req3->(OUTPUT_H_QUE, $_Q->{_id}.$LF, 0);
   }

}

1;

__END__

###############################################################################
## ----------------------------------------------------------------------------
## Module usage.
##
###############################################################################

=head1 NAME

MCE::Queue - Hybrid (normal and priority) queues

=head1 VERSION

This document describes MCE::Queue version 1.879

=head1 SYNOPSIS

 use MCE;
 use MCE::Queue;

 my $q = MCE::Queue->new;

 $q->enqueue( qw/ wherefore art thou romeo / );

 my $item = $q->dequeue;

 if ( $q->pending ) {
    ;
 }

=head1 DESCRIPTION

This module provides a queue interface supporting normal and priority
queues and utilizing the IPC engine behind MCE. Data resides under the
manager process. Three options are available for overriding the default
value for new queues. The porder option applies to priority queues only.

 use MCE::Queue porder => $MCE::Queue::HIGHEST,
                type   => $MCE::Queue::FIFO;

 use MCE::Queue;                # Same as above

 ## Possible values

 porder => $MCE::Queue::HIGHEST # Highest priority items dequeue first
           $MCE::Queue::LOWEST  # Lowest priority items dequeue first

 type   => $MCE::Queue::FIFO    # First in, first out
           $MCE::Queue::LIFO    # Last in, first out
           $MCE::Queue::LILO    # (Synonym for FIFO)
           $MCE::Queue::FILO    # (Synonym for LIFO)

=head1 DEMONSTRATION

MCE::Queue provides two run modes.

(A) The C<MCE::Queue> object is constructed before running MCE. The data
resides under the manager process. Workers send and request data via IPC.

(B) Workers might want to construct a queue for local access. In this mode,
the data resides under the worker process and not available to other workers
including the manager process.

 use MCE;
 use MCE::Queue;

 my $F = MCE::Queue->new( fast => 1 );
 my $consumers = 8;

 my $mce = MCE->new(

    task_end => sub {
       my ($mce, $task_id, $task_name) = @_;
       $F->end() if $task_name eq 'dir';
    },

    user_tasks => [{
       max_workers => 1, task_name => 'dir',

       user_func => sub {
          ## Create a "standalone queue" only accessible to this worker.
          my $D = MCE::Queue->new(queue => [ MCE->user_args->[0] ]);

          while (defined (my $dir = $D->dequeue_nb)) {
             my (@files, @dirs); foreach (glob("$dir/*")) {
                if (-d $_) { push @dirs, $_; next; }
                push @files, $_;
             }
             $D->enqueue(@dirs ) if scalar @dirs;
             $F->enqueue(@files) if scalar @files;
          }
       }
    },{
       max_workers => $consumers, task_name => 'file',

       user_func => sub {
          while (defined (my $file = $F->dequeue)) {
             MCE->say($file);
          }
       }
    }]

 )->run({ user_args => [ $ARGV[0] || '.' ] });

 __END__

 Results taken from files_mce.pl and files_thr.pl on the web.
 https://github.com/marioroy/mce-examples/tree/master/other

 Usage:
    time ./files_mce.pl /usr 0 | wc -l
    time ./files_mce.pl /usr 1 | wc -l
    time ./files_thr.pl /usr   | wc -l

 Darwin (OS)    /usr:    216,271 files
    MCE::Queue, fast => 0 :    4.17s
    MCE::Queue, fast => 1 :    2.62s
    Thread::Queue         :    4.14s

 Linux (VM)     /usr:    186,154 files
    MCE::Queue, fast => 0 :   12.57s
    MCE::Queue, fast => 1 :    3.36s
    Thread::Queue         :    5.91s

 Solaris (VM)   /usr:    603,051 files
    MCE::Queue, fast => 0 :   39.04s
    MCE::Queue, fast => 1 :   18.08s
    Thread::Queue      * Perl not built to support threads

=head1 API DOCUMENTATION

=head2 MCE::Queue->new ( [ queue => \@array, await => 1, fast => 1 ] )

This creates a new queue. Available options are queue, porder, type, await,
and gather. Note: The barrier and fast options are silentently ignored (no-op)
if specified; starting with 1.867.

 use MCE;
 use MCE::Queue;

 my $q1 = MCE::Queue->new();
 my $q2 = MCE::Queue->new( queue  => [ 0, 1, 2 ] );

 my $q3 = MCE::Queue->new( porder => $MCE::Queue::HIGHEST );
 my $q4 = MCE::Queue->new( porder => $MCE::Queue::LOWEST  );

 my $q5 = MCE::Queue->new( type   => $MCE::Queue::FIFO );
 my $q6 = MCE::Queue->new( type   => $MCE::Queue::LIFO );

 my $q7 = MCE::Queue->new( await  => 1, barrier => 0 );
 my $q8 = MCE::Queue->new( fast   => 1 );

The C<await> option, when enabled, allows workers to block (semaphore-like)
until the number of items pending is equal to or less than a threshold value.
The $q->await method is described below.

Obsolete: On Unix platforms, C<barrier> mode (enabled by default) prevents
many workers from dequeuing simultaneously to lessen overhead for the OS kernel.
Specify 0 to disable barrier mode and not allocate sockets. The barrier option
has no effect if constructing the queue inside a thread or enabling C<fast>.

Obsolete: The C<fast> option speeds up dequeues and is not enabled by default.
It is beneficial for queues not calling (->dequeue_nb) and not altering the
count value while running; e.g. ->dequeue($count).

The C<gather> option is mainly for running with MCE and wanting to pass item(s)
to a callback function for appending to the queue. Multiple queues may point to
the same callback function. The callback receives the queue object as the first
argument and items after it.

 sub _append {
    my ($q, @items) = @_;
    $q->enqueue(@items);
 }

 my $q7 = MCE::Queue->new( gather => \&_append );
 my $q8 = MCE::Queue->new( gather => \&_append );

 ## Items are diverted to the callback function, not the queue.
 $q7->enqueue( 'apple', 'orange' );

Specifying the C<gather> option allows one to store items temporarily while
ensuring output order. Although a queue object is not required, this is
simply a demonstration of the gather option in the context of a queue.

 use MCE;
 use MCE::Queue;

 sub preserve_order {
    my %tmp; my $order_id = 1;

    return sub {
       my ($q, $chunk_id, $data) = @_;
       $tmp{$chunk_id} = $data;

       while (1) {
          last unless exists $tmp{$order_id};
          $q->enqueue( delete $tmp{$order_id++} );
       }

       return;
    };
 }

 my @squares; my $q = MCE::Queue->new(
    queue => \@squares, gather => preserve_order
 );

 my $mce = MCE->new(
    chunk_size => 1, input_data => [ 1 .. 100 ],
    user_func => sub {
       $q->enqueue( MCE->chunk_id, $_ * $_ );
    }
 );

 $mce->run;

 print "@squares\n";

=head2 $q->await ( $pending_threshold )

The await method is beneficial when wanting to throttle worker(s) appending
to the queue. Perhaps, consumers are running a bit behind and wanting to keep
tabs on memory consumption. Below, the number of items pending will never go
above 20.

 use Time::HiRes qw( sleep );

 use MCE::Flow;
 use MCE::Queue;

 my $q = MCE::Queue->new( await => 1, fast => 1 );
 my ( $producers, $consumers ) = ( 1, 8 );

 mce_flow {
    task_name   => [ 'producer', 'consumer' ],
    max_workers => [ $producers, $consumers ],
 },
 sub {
    ## producer
    for my $item ( 1 .. 100 ) {
       $q->enqueue($item);

       ## blocks until the # of items pending reaches <= 10
       if ($item % 10 == 0) {
          MCE->say( 'pending: '.$q->pending() );
          $q->await(10);
       }
    }

    ## notify consumers no more work
    $q->end();

 },
 sub {
    ## consumers
    while (defined (my $next = $q->dequeue())) {
       MCE->say( MCE->task_wid().': '.$next );
       sleep 0.100;
    }
 };

=head2 $q->clear ( void )

Clears the queue of any items. This has the effect of nulling the queue and
the socket used for blocking.

 my @a; my $q = MCE::Queue->new( queue => \@a );

 @a = ();     ## bad, the blocking socket may become out of sync
 $q->clear;   ## ok

=head2 $q->end ( void )

Stops the queue from receiving more items. Any worker blocking on C<dequeue>
will be unblocked automatically. Subsequent calls to C<dequeue> will behave
like C<dequeue_nb>. Current API available since MCE 1.818.

 $q->end();

MCE Models (e.g. MCE::Flow) may persist between runs. In that case, one might
want to enqueue C<undef>'s versus calling C<end>. The number of C<undef>'s
depends on how many items workers dequeue at a time.

 $q->enqueue((undef) x ($N_workers * 1));  # $q->dequeue()   1 item
 $q->enqueue((undef) x ($N_workers * 2));  # $q->dequeue(2)  2 items
 $q->enqueue((undef) x ($N_workers * N));  # $q->dequeue(N)  N items

=head2 $q->enqueue ( $item [, $item, ... ] )

Appends a list of items onto the end of the normal queue.

 $q->enqueue( 'foo' );
 $q->enqueue( 'bar', 'baz' );

=head2 $q->enqueuep ( $p, $item [, $item, ... ] )

Appends a list of items onto the end of the priority queue with priority.

 $q->enqueue( $priority, 'foo' );
 $q->enqueue( $priority, 'bar', 'baz' );

=head2 $q->dequeue ( [ $count ] )

Returns the requested number of items (default 1) from the queue. Priority
data will always dequeue first before any data from the normal queue.

 $q->dequeue( 2 );
 $q->dequeue; # default 1

The method will block if the queue contains zero items. If the queue contains
fewer than the requested number of items, the method will not block, but
return whatever items there are on the queue.

The $count, used for requesting the number of items, is beneficial when workers
are passing parameters through the queue. For this reason, always remember to
dequeue using the same multiple for the count. This is unlike Thread::Queue
which will block until the requested number of items are available.

 # MCE::Queue 1.820 and prior releases
 while ( my @items = $q->dequeue(2) ) {
    last unless ( defined $items[0] );
    ...
 }

 # MCE::Queue 1.821 and later
 while ( my @items = $q->dequeue(2) ) {
    ...
 }

=head2 $q->dequeue_nb ( [ $count ] )

Returns the requested number of items (default 1) from the queue. Like with
dequeue, priority data will always dequeue first. This method is non-blocking
and returns C<undef> in the absence of data.

 $q->dequeue_nb( 2 );
 $q->dequeue_nb; # default 1

=head2 $q->insert ( $index, $item [, $item, ... ] )

Adds the list of items to the queue at the specified index position (0 is the
head of the list). The head of the queue is that item which would be removed
by a call to dequeue.

 $q = MCE::Queue->new( type => $MCE::Queue::FIFO );
 $q->enqueue(1, 2, 3, 4);
 $q->insert(1, 'foo', 'bar'); 
 # Queue now contains: 1, foo, bar, 2, 3, 4

 $q = MCE::Queue->new( type => $MCE::Queue::LIFO );
 $q->enqueue(1, 2, 3, 4);
 $q->insert(1, 'foo', 'bar'); 
 # Queue now contains: 1, 2, 3, 'foo', 'bar', 4

=head2 $q->insertp ( $p, $index, $item [, $item, ... ] )

Adds the list of items to the queue at the specified index position with
priority. The behavior is similarly to C<< $q->insert >> otherwise.

=head2 $q->pending ( void )

Returns the number of items in the queue. The count includes both normal
and priority data. Returns C<undef> if the queue has been ended, and there
are no more items in the queue.

 $q = MCE::Queue->new();
 $q->enqueuep(5, 'foo', 'bar');
 $q->enqueue('sunny', 'day');

 print $q->pending(), "\n";
 # Output: 4

=head2 $q->peek ( [ $index ] )

Returns an item from the normal queue, at the specified index, without
dequeuing anything. It defaults to the head of the queue if index is not
specified. The head of the queue is that item which would be removed by a
call to dequeue. Negative index values are supported, similarly to arrays.

 $q = MCE::Queue->new( type => $MCE::Queue::FIFO );
 $q->enqueue(1, 2, 3, 4, 5);

 print $q->peek(1), ' ', $q->peek(-2), "\n";
 # Output: 2 4

 $q = MCE::Queue->new( type => $MCE::Queue::LIFO );
 $q->enqueue(1, 2, 3, 4, 5);

 print $q->peek(1), ' ', $q->peek(-2), "\n";
 # Output: 4 2

=head2 $q->peekp ( $p [, $index ] )

Returns an item from the queue with priority, at the specified index, without
dequeuing anything. It defaults to the head of the queue if index is not
specified. The behavior is similarly to C<< $q->peek >> otherwise.

=head2 $q->peekh ( [ $index ] )

Returns an item from the head of the heap or at the specified index.

 $q = MCE::Queue->new( porder => $MCE::Queue::HIGHEST );
 $q->enqueuep(5, 'foo');
 $q->enqueuep(6, 'bar');
 $q->enqueuep(4, 'sun');

 print $q->peekh(0), "\n";
 # Output: 6

 $q = MCE::Queue->new( porder => $MCE::Queue::LOWEST );
 $q->enqueuep(5, 'foo');
 $q->enqueuep(6, 'bar');
 $q->enqueuep(4, 'sun');

 print $q->peekh(0), "\n";
 # Output: 4

=head2 $q->heap ( void )

Returns an array containing the heap data. Heap data consists of priority
numbers, not the data.

 @h = $q->heap;   # $MCE::Queue::HIGHEST
 # Heap contains: 6, 5, 4

 @h = $q->heap;   # $MCE::Queue::LOWEST
 # Heap contains: 4, 5, 6

=head1 ACKNOWLEDGMENTS

=over 3

=item * L<List::BinarySearch>

The bsearch_num_pos method was helpful for accommodating the highest and lowest
order in MCE::Queue.

=item * L<POE::Queue::Array>

For extra optimization, two if statements were adopted for checking if the item
belongs at the end or head of the queue.

=item * L<List::Priority>

MCE::Queue supports both normal and priority queues.

=item * L<Thread::Queue>

Thread::Queue is used as a template for identifying and documenting the methods.

MCE::Queue is not fully compatible due to supporting normal and priority queues
simultaneously; e.g.

 $q->enqueue( $item [, $item, ... ] );         # normal queue
 $q->enqueuep( $p, $item [, $item, ... ] );    # priority queue

 $q->dequeue( [ $count ] );      # priority data dequeues first
 $q->dequeue_nb( [ $count ] );

 $q->pending();                  # counts both normal/priority queues

=item * L<Parallel::DataPipe>

The recursion example, in the synopsis above, was largely adopted from this
module.

=back

=head1 INDEX

L<MCE|MCE>, L<MCE::Core>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

