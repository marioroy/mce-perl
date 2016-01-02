###############################################################################
## ----------------------------------------------------------------------------
## Server/Object core classes for MCE::Shared.
##
###############################################################################

package MCE::Shared::Server;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized once );

our $VERSION = '1.699_001';

## no critic (BuiltinFunctions::ProhibitStringyEval)
## no critic (Subroutines::ProhibitExplicitReturnUndef)
## no critic (TestingAndDebugging::ProhibitNoStrict)
## no critic (InputOutput::ProhibitTwoArgOpen)

use Time::HiRes qw( sleep );
use Scalar::Util qw( blessed reftype );
use Socket qw( SOL_SOCKET SO_RCVBUF );
use Storable ();
use bytes;

my ($_freeze, $_thaw);

BEGIN {
   $_freeze = \&Storable::freeze;
   $_thaw   = \&Storable::thaw;
   local $@;

   if ($^O eq 'MSWin32' && !defined $threads::VERSION) {
      eval 'use threads; use threads::shared';
   }
   elsif (defined $threads::VERSION) {
      eval 'use threads::shared' unless defined($threads::shared::VERSION);
   }

   eval 'use IO::FDPass' if !$INC{'IO/FDPass.pm'} && $^O ne 'cygwin';

   eval 'PDL::no_clone_skip_warning()' if $INC{'PDL.pm'};
}

use MCE::Util ();
use MCE::Mutex;

use constant {
   DATA_CHANNELS => 8,    # Max data channels
   MAX_DQ_DEPTH  => 192,  # Maximum dequeue notifications
   WA_ARRAY      => 1,    # Wants list

   SHR_M_NEW => 'M~NEW',  # New share
   SHR_M_CNT => 'M~CNT',  # Increment count
   SHR_M_DNE => 'M~DNE',  # Done sharing
   SHR_M_CID => 'M~CID',  # ClientID request
   SHR_M_OBJ => 'M~OBJ',  # Object request
   SHR_M_BLE => 'M~BLE',  # Blessed request
   SHR_M_DES => 'M~DES',  # Destroy request
   SHR_M_EXP => 'M~EXP',  # Export request
   SHR_M_NXT => 'M~NXT',  # Iterator next
   SHR_M_PRE => 'M~PRE',  # Iterator prev
   SHR_M_RES => 'M~RES',  # Iterator reset
   SHR_M_PDL => 'M~PDL',  # PDL::ins inplace(this),what,coords

   # Items not listed below are handled via Perl's AUTOLOAD feature.
   # For extra performance, run with option Sereal => 1.

   SHR_O_FSZ => 'O~FSZ',  # A FETCHSIZE
   SHR_O_SET => 'O~SET',  # A,H,OH,S set
   SHR_O_GET => 'O~GET',  # A,H,OH,S get
   SHR_O_DEL => 'O~DEL',  # A,H,OH delete
   SHR_O_EXI => 'O~EXI',  # A,H,OH exists
   SHR_O_CLR => 'O~CLR',  # A,H,OH clear
   SHR_O_MSE => 'O~MSE',  # A,H,OH mset
   SHR_O_POP => 'O~POP',  # A,OH pop
   SHR_O_PSH => 'O~PSH',  # A,OH push
   SHR_O_SFT => 'O~SFT',  # A,OH shift
   SHR_O_UNS => 'O~UNS',  # A,OH unshift
   SHR_O_CLO => 'O~CLO',  # Handle CLOSE
   SHR_O_OPN => 'O~OPN',  # Handle OPEN
   SHR_O_REA => 'O~REA',  # Handle READ
   SHR_O_RLN => 'O~RLN',  # Handle READLINE
   SHR_O_PRI => 'O~PRI',  # Handle PRINT
   SHR_O_WRI => 'O~WRI',  # Handle WRITE
   SHR_O_CVB => 'O~CVB',  # Condvar broadcast
   SHR_O_CVS => 'O~CVS',  # Condvar signal
   SHR_O_CVT => 'O~CVT',  # Condvar timedwait
   SHR_O_CVW => 'O~CVW',  # Condvar wait
   SHR_O_QUA => 'O~QUA',  # Queue await
   SHR_O_QUD => 'O~QUD',  # Queue dequeue
   SHR_O_QUN => 'O~QUN',  # Queue dequeue non-blocking
   SHR_O_QUP => 'O~QUP',  # Queue pending
};

###############################################################################
## ----------------------------------------------------------------------------
## Private functions.
##
###############################################################################

my ($_SVR, %_all, %_aref, %_href, %_obj, %_ob2, %_itr, %_new) = (undef);
my ($_next_id, $_is_client, $_init_pid, $_svr_pid) = (0, 1);
my $LF = "\012"; Internals::SvREADONLY($LF, 1);

my $_is_MSWin32  = ($^O eq 'MSWin32') ? 1 : 0;
my $_has_threads = $INC{'threads.pm'} ? 1 : 0;
my $_tid = $_has_threads ? threads->tid() : 0;

sub _croak { require Carp unless $INC{'Carp.pm'}; goto &Carp::croak }
sub  CLONE { $_tid = threads->tid() }

sub _use_sereal {
   local $@; eval 'use Sereal qw( encode_sereal decode_sereal )';
   $_freeze = \&encode_sereal, $_thaw = \&decode_sereal unless $@;
}

END {
   %_aref = (), %_href = ();
   return unless ($_init_pid && $_init_pid eq "$$.$_tid");
   _stop();
}

{
   my $_handler_cnt : shared = 0;

   sub _trap {
      my $_sig_name = $_[0];
      $MCE::Shared::Server::KILLED = 1;

      $SIG{INT} = $SIG{__DIE__} = $SIG{__WARN__} = $SIG{$_[0]} = sub {};
      lock $_handler_cnt if $INC{'threads/shared.pm'};

      if (++$_handler_cnt == 1) {
         CORE::kill($_sig_name, $_is_MSWin32 ? -$$ : -getpgrp);

         if ($_sig_name eq 'PIPE') {
            sleep 0.015 for (1..2);
         } else {
            sleep 0.065 for (1..3);
         }

         CORE::kill('QUIT', $_is_MSWin32 ? -$$ : -getpgrp)
            if ($_sig_name eq 'PIPE' && $INC{'MCE/Hobo.pm'});

         ($_is_MSWin32)
            ? CORE::kill('KILL', -$$, $$)
            : CORE::kill('INT', -getpgrp);
      }

      sleep 0.065 for (1..5);

      CORE::exit($?);
   }
}

sub _new {
   my ($_class, $_deeply, %_hndls) = ($_[0]->{class}, $_[0]->{_DEEPLY_});

   unless ($_svr_pid) {
      ## Minimum support for environments without IO::FDPass.
      ## Must share Condvar and Queue before others.
      return _share(@_)
         if (!$INC{'IO/FDPass.pm'} && $_class =~
               /^MCE::Shared::(?:Condvar|Queue)$/
         );
      _start();
   }

   if ($_class =~ /^MCE::Shared::(?:Condvar|Queue)$/) {
      if (!$INC{'IO/FDPass.pm'}) {
         _croak(
            "\nSharing a $_class object while the server is running\n",
            "requires the IO::FDPass module.\n\n"
         );
      }
      for my $k (qw(
         _qw_sock _qr_sock _aw_sock _ar_sock _cw_sock _cr_sock _mutex
      )) {
         if (defined $_[1]->{ $k }) {
            $_hndls{ $k } = delete $_[1]->{ $k };
            $_[1]->{ $k } = undef;
         }
      }
   }

   my ($_buf, $_id, $_len);

   my $_chn        = 1;
   my $_DAT_LOCK   = $_SVR->{'_mutex_'.$_chn};
   my $_DAT_W_SOCK = $_SVR->{_dat_w_sock}->[0];
   my $_DAU_W_SOCK = $_SVR->{_dat_w_sock}->[$_chn];

   local $\ = undef if (defined $\);
   local $/ = $LF if (!$/ || $/ ne $LF);

   $_DAT_LOCK->lock();
   print {$_DAT_W_SOCK} SHR_M_NEW.$LF . $_chn.$LF;

   $_buf = $_freeze->(shift);  print {$_DAU_W_SOCK} length($_buf).$LF . $_buf;
   $_buf = $_freeze->([ @_ ]); print {$_DAU_W_SOCK} length($_buf).$LF . $_buf;
   undef $_buf;

   print {$_DAU_W_SOCK} (keys %_hndls ? 1 : 0).$LF;
   <$_DAU_W_SOCK>;

   if (keys %_hndls) {
      for my $k (qw( _qw_sock _qr_sock _aw_sock _cw_sock )) {
         if (exists $_hndls{ $k }) {
            IO::FDPass::send( fileno $_DAU_W_SOCK, fileno $_hndls{ $k } );
            <$_DAU_W_SOCK>;
         }
      }
   }

   chomp($_id = <$_DAU_W_SOCK>);
   if (keys %_hndls) {
      $_all{ $_id } = $_class;
      $_obj{ $_id } = \%_hndls;
   }

   chomp($_len = <$_DAU_W_SOCK>);
   read $_DAU_W_SOCK, $_buf, $_len;
   $_DAT_LOCK->unlock();

   unless ($_deeply) {
      ## for auto-destroy
      $_new{ $_id } = $_has_threads ? $$ .'.'. $_tid : $$;
   }

   return $_thaw->($_buf);
}

sub _incr_count {
   return unless $_svr_pid;

   my $_chn        = 1;
   my $_DAT_LOCK   = $_SVR->{'_mutex_'.$_chn};
   my $_DAT_W_SOCK = $_SVR->{_dat_w_sock}->[0];
   my $_DAU_W_SOCK = $_SVR->{_dat_w_sock}->[$_chn];

   local $\ = undef if (defined $\);
   local $/ = $LF if (!$/ || $/ ne $LF);

   $_DAT_LOCK->lock();
   print {$_DAT_W_SOCK} SHR_M_CNT.$LF . $_chn.$LF;
   print {$_DAU_W_SOCK} $_[0].$LF;
   <$_DAU_W_SOCK>;

   $_DAT_LOCK->unlock();

   return;
}

sub _share {
   my ($_params, $_item) = (shift, shift);
   my ($_id, $_class) = (++$_next_id, delete $_params->{'class'});

   if ($_class eq ':construct_pdl:') {
      local $@; local $SIG{__DIE__} = sub {};

      $_class = 'PDL', $_item = eval q{
         use PDL; my $_func = pop @{ $_item };

         if    ($_func eq 'byte'    ) { byte     (@{ $_item }) }
         elsif ($_func eq 'short'   ) { short    (@{ $_item }) }
         elsif ($_func eq 'ushort'  ) { ushort   (@{ $_item }) }
         elsif ($_func eq 'long'    ) { long     (@{ $_item }) }
         elsif ($_func eq 'longlong') { longlong (@{ $_item }) }
         elsif ($_func eq 'float'   ) { float    (@{ $_item }) }
         elsif ($_func eq 'double'  ) { double   (@{ $_item }) }
         elsif ($_func eq 'ones'    ) { ones     (@{ $_item }) }
         elsif ($_func eq 'sequence') { sequence (@{ $_item }) }
         elsif ($_func eq 'zeroes'  ) { zeroes   (@{ $_item }) }
         elsif ($_func eq 'indx'    ) { indx     (@{ $_item }) }
         else                         { pdl      (@{ $_item }) }
      };
   }
   elsif (!exists $INC{ join('/',split(/::/,$_class)).'.pm' }) {
      local $@; local $SIG{__DIE__} = sub {};
      eval "use $_class ()";
   }

   $_all{ $_id } = $_class; $_all{ "$_id:count" } = 1;

   if ($_class eq 'MCE::Shared::Handle') {
      require Symbol unless $INC{'Symbol.pm'};
      $_obj{ $_id } = Symbol::gensym();
      bless $_obj{ $_id }, 'MCE::Shared::Handle';
   }
   else {
      $_obj{ $_id } = $_item;
   }

   bless \$_id, 'MCE::Shared::Object';
   $_ob2{ $_id } = $_freeze->(\$_id);

   return \$_id;
}

sub _start {
   return if $_svr_pid;

   $SIG{HUP} = $SIG{INT} = $SIG{PIPE} = $SIG{QUIT} = $SIG{TERM} = \&_trap
      unless $INC{'MCE/Signal.pm'};

   my $_data_channels = ($INC{'MCE.pm'} && MCE->wid()) ? 1 : DATA_CHANNELS;
   my $_is_child = ($INC{'threads.pm'} || $_is_MSWin32) ? 0 : 1;

   $_SVR = { _data_channels => $_data_channels };
   local $_; $_init_pid = "$$.$_tid";

   MCE::Util::_sock_pair($_SVR, qw(_dat_r_sock _dat_w_sock), $_)
      for (0 .. $_data_channels);
   $_SVR->{'_mutex_'.$_} = MCE::Mutex->new()
      for (1 .. $_data_channels);

   setsockopt($_SVR->{_dat_r_sock}->[0], SOL_SOCKET, SO_RCVBUF, 4096)
      if ($^O ne 'aix' && $^O ne 'linux');

   MCE::Shared::Object::_server_init();

   if ($_is_child) {
      $_svr_pid = fork();
      unless ($_svr_pid) {
         $SIG{CHLD} = 'IGNORE' unless $_is_MSWin32;
         _loop($_is_child);
      }
   }
   else {
      require threads unless $INC{'threads.pm'};
      $_svr_pid = threads->create(\&_loop, $_is_child);
      $_svr_pid->detach() if defined $_svr_pid;
   }

   _croak("cannot start server process: $!") unless (defined $_svr_pid);

   return;
}

sub _stop {
   return unless ($_init_pid && $_init_pid eq "$$.$_tid");
   return if ($INC{'MCE/Signal.pm'} && $MCE::Signal::KILLED);
   return if ($MCE::Shared::Server::KILLED);

   %_all = (), %_aref = (), %_href = (), %_obj = ();

   if (defined $_svr_pid) {
      my $_chn  = 1;
      $_svr_pid = undef; local $\ = undef if (defined $\);

      print {$_SVR->{_dat_w_sock}->[0]} SHR_M_DNE.$LF . $_chn.$LF;
      sleep($_is_MSWin32 ? 0.1 : 0.05);

      MCE::Util::_destroy_socks($_SVR, qw( _dat_w_sock _dat_r_sock ));

      for my $_i (1 .. $_SVR->{_data_channels}) {
         $_SVR->{'_mutex_'.$_i}->DESTROY('shutdown');
      }
   }

   return;
}

sub _destroy {
   my ($_lkup, $_item, $_id) = @_;

   ## safety for circular references to not destroy dangerously
   return if exists $_all{ "$_id:count" } && --$_all{ "$_id:count" } > 0;

   ## safety for circular references to not loop endlessly
   return if exists $_lkup->{ $_id };

   $_lkup->{ $_id } = 1;

   if ($_all{ $_id } =~ /^MCE::Shared::(?:Array|Hash|Ordhash)$/) {
      for my $k ($_item->keys) {
         if (blessed($_item->get($k))) {
            my $_oid = $_item->get($k)->SHARED_ID();
            _destroy($_lkup, $_obj{ $_oid }, $_oid);
         }
      }
   }
   elsif ($_all{ $_id } eq 'MCE::Shared::Scalar') {
      if (blessed($_item->get())) {
         my $_oid = $_item->get()->SHARED_ID();
         _destroy($_lkup, $_obj{ $_oid }, $_oid);
      }
      undef ${ $_obj{ $_id } };
   }
   elsif ($_all{ $_id } eq 'MCE::Shared::Handle') {
      close $_obj{ $_id } if defined(fileno($_obj{ $_id }));
   }

   delete $_all{ $_id }; delete $_all{ "$_id:count" };
   delete $_obj{ $_id }; delete $_ob2{ $_id };
   delete $_itr{ $_id };

   return;
}

sub _done {
   %_all = (), %_obj = (), %_ob2 = (), %_itr = ();
}

###############################################################################
## ----------------------------------------------------------------------------
## Server loop.
##
###############################################################################

sub _loop {
   my ($_is_child) = @_;
   require POSIX if $_is_child;

   $_is_client = 0;

   $SIG{PIPE} = sub {
      _done(); $_is_child ? POSIX::_exit($?) : CORE::exit($?);
   };

   $SIG{HUP} = $SIG{INT} = $SIG{QUIT} = $SIG{TERM} = sub {
      $SIG{INT} = $SIG{$_[0]} = sub {};
      CORE::kill($_[0], $_is_MSWin32 ? -$$ : -getpgrp);
      _done(); $_is_child ? POSIX::_exit($?) : CORE::exit($?);
   };

   $SIG{__DIE__} = sub {
      $SIG{INT} = $SIG{__DIE__} = $SIG{__WARN__} = sub {};
      print {*STDERR} $_[0];
      CORE::kill('INT', $_is_MSWin32 ? -$$ : -getpgrp);
      _done(); $_is_child ? POSIX::_exit($?) : CORE::exit($?);
   };

   local $\ = undef; local $/ = $LF; $| = 1;

   my ($_DAU_R_SOCK, $_id, $_fn, $_wa, $_key, $_len, $_ret, $_func);
   my ($_CV, $_Q, $_cnt, $_pending, $_t, $_frozen);
   my ($_client_id, $_done) = (0, 0);

   my $_DAT_R_SOCK = $_SVR->{_dat_r_sock}->[0];
   my $_channels   = $_SVR->{_dat_r_sock};

   my $_fetch = sub {
      if (ref($_[0])) {
         my $_buf = (blessed($_[0]) && $_[0]->can('SHARED_ID'))
            ? $_ob2{ $_[0]->SHARED_ID() } || $_freeze->($_[0])
            : $_freeze->($_[0]);
         print {$_DAU_R_SOCK} length($_buf).'1'.$LF, $_buf;
      }
      elsif (defined $_[0]) {
         print {$_DAU_R_SOCK} length($_[0]).'0'.$LF, $_[0];
      }
      else {
         print {$_DAU_R_SOCK} '-1'.$LF;
      }

      return;
   };

   my $_iterator = sub {
      my ($_id, $_wa) = (shift, shift);

      if (!exists $_itr{ $_id }) {
         if ($_all{ $_id } =~ /^MCE::Shared::(?:Array|Hash|Ordhash)$/) {
            @{ $_itr{ $_id } } = $_obj{ $_id }->keys;
         }
         else {
            print {$_DAU_R_SOCK} '-1'.$LF;
            return;
         }
      }

      my $_key = $_[0] ? shift @{ $_itr{ $_id } } : pop @{ $_itr{ $_id } };

      if (!defined $_key) {
         print {$_DAU_R_SOCK} '-1'.$LF;
      }
      else {
         my $_buf = ($_wa)
            ? $_freeze->([ $_key, $_obj{ $_id }->get($_key) ])
            : $_freeze->([ $_obj{ $_id }->get($_key) ]);

         print {$_DAU_R_SOCK} length($_buf).$LF, $_buf;
      }

      return;
   };

   ## -------------------------------------------------------------------------

   my %_output_function = (

      SHR_M_NEW.$LF => sub {                      # New share
         my ($_buf, $_params, $_args, $_fd, $_item, %_hndls);

         chomp($_len = <$_DAU_R_SOCK>);
         read $_DAU_R_SOCK, $_buf, $_len;
         $_params = $_thaw->($_buf);

         chomp($_len = <$_DAU_R_SOCK>);
         read $_DAU_R_SOCK, $_buf, $_len;
         $_args = $_thaw->($_buf); undef $_buf;

         chomp($_len = <$_DAU_R_SOCK>);
         print {$_DAU_R_SOCK} $LF;

         if ($_len) {
            for my $k (qw( _qw_sock _qr_sock _aw_sock _cw_sock )) {
               if (exists $_args->[0]->{ $k }) {
                   delete $_args->[0]->{ $k };
                   $_fd = IO::FDPass::recv(fileno $_DAU_R_SOCK); $_fd >= 0
                     or _croak("cannot receive file handle: $!");

                   open $_args->[0]->{ $k }, "+<&=$_fd"
                     or _croak("cannot convert file discriptor to handle: $!");

                   print {$_DAU_R_SOCK} $LF;
               }
            }
         }

         $_item = _share($_params, @{ $_args });
         print {$_DAU_R_SOCK} $_item->SHARED_ID().$LF;

         $_buf = $_freeze->($_item);
         print {$_DAU_R_SOCK} length($_buf).$LF . $_buf;

         return;
      },

      SHR_M_CNT.$LF => sub {                      # Increment count
         chomp($_id = <$_DAU_R_SOCK>);

         $_all{ "$_id:count" }++;
         print {$_DAU_R_SOCK} $LF;

         return;
      },

      SHR_M_DNE.$LF => sub {                      # Done sharing
         _done(); $_done = 1;

         return;
      },

      SHR_M_CID.$LF => sub {                      # ClientID request
         print {$_DAU_R_SOCK} (++$_client_id).$LF;
         $_client_id = 0 if ($_client_id > 2e6);

         return;
      },

      SHR_M_OBJ.$LF => sub {                      # Object request
         my $_buf;

         chomp($_id  = <$_DAU_R_SOCK>),
         chomp($_fn  = <$_DAU_R_SOCK>),
         chomp($_wa  = <$_DAU_R_SOCK>),
         chomp($_len = <$_DAU_R_SOCK>);

         if ($_len >= 0) {
            $_frozen = chop($_len);
            read $_DAU_R_SOCK, $_buf, $_len;
         }

         unless (exists $_obj{ $_id }) {
            _croak(
               "Can't locate object method \"$_fn\" via shared object\n",
               "or maybe, the object has been destroyed\n"
            );
         }

         my $_var = $_obj{ $_id };

         if (my $_code = $_var->can( $_fn )) {
            if ($_wa == WA_ARRAY) {
               my @_ret = $_code->( $_var,
                  $_len < 0 ? () : ( $_frozen ? @{ $_thaw->($_buf) } : $_buf )
               );
               $_buf = $_freeze->(\@_ret);
               print {$_DAU_R_SOCK} length($_buf).'1'.$LF, $_buf;
            }
            elsif ($_wa) {
               my $_ret = $_code->( $_var,
                  $_len < 0 ? () : ( $_frozen ? @{ $_thaw->($_buf) } : $_buf )
               );
               if (!ref($_ret) && defined $_ret) {
                  print {$_DAU_R_SOCK} length($_ret).'0'.$LF, $_ret;
               } else {
                  $_buf = $_freeze->([ $_ret ]);
                  print {$_DAU_R_SOCK} length($_buf).'1'.$LF, $_buf;
               }
            }
            else {
               $_code->( $_var,
                  $_len < 0 ? () : ( $_frozen ? @{ $_thaw->($_buf) } : $_buf )
               );
            }
         }
         else {
            my $_pkg = blessed($_obj{ $_id });
            _croak(
               "Can't locate object method \"$_fn\" via package \"$_pkg\""
            );
         }

         return;
      },

      SHR_M_BLE.$LF => sub {                      # Blessed request
         chomp($_id = <$_DAU_R_SOCK>);

         print {$_DAU_R_SOCK} $_all{ $_id }.$LF;

         return;
      },

      SHR_M_DES.$LF => sub {                      # Destroy request
         chomp($_id = <$_DAU_R_SOCK>);

         $_ret = (exists $_all{ $_id }) ? '1' : '0';
         _destroy({}, $_obj{ $_id }, $_id) if $_ret;
         %_aref = (), %_href = ();

         print {$_DAU_R_SOCK} $_ret.$LF;

         return;
      },

      SHR_M_EXP.$LF => sub {                      # Export request
         chomp($_id  = <$_DAU_R_SOCK>),
         chomp($_len = <$_DAU_R_SOCK>);

         read($_DAU_R_SOCK, my($_keys), $_len) if $_len;

         if (exists $_obj{ $_id }) {
            my $_buf;

            if ($_all{ $_id } =~ /^MCE::Shared::(?:Array|Hash|Ordhash)$/) {
               $_buf = ($_len)
                  ? $_freeze->($_obj{ $_id }->clone(@{ $_thaw->($_keys) }))
                  : $_freeze->($_obj{ $_id });
            }
            elsif ($_all{ $_id } =~ /^MCE::Shared::(?:Condvar|Queue)$/) {
               my %_ret = %{ $_obj{ $_id } }; bless \%_ret, $_all{ $_id };
               delete @_ret{ qw(
                  _qw_sock _qr_sock _aw_sock _ar_sock
                  _cw_sock _cr_sock _mutex
               ) };
               $_buf = $_freeze->(\%_ret);
            }
            else {
               $_buf = $_freeze->($_obj{ $_id });
            }

            print {$_DAU_R_SOCK} length($_buf).'1'.$LF, $_buf;
            undef $_buf;
         }
         else {
            print {$_DAU_R_SOCK} '-1'.$LF;
         }

         return;
      },

      SHR_M_NXT.$LF => sub {                      # Iterator next
         chomp($_id = <$_DAU_R_SOCK>),
         chomp($_wa = <$_DAU_R_SOCK>);

         my $_var = $_obj{ $_id };

         if ( my $_code = $_var->can('next') ) {
            my $_buf = $_freeze->([ $_code->( $_var ) ]);
            print {$_DAU_R_SOCK} length($_buf).$LF, $_buf;
         } else {
            $_iterator->( $_id, $_wa, 1 );
         }

         return;
      },

      SHR_M_PRE.$LF => sub {                      # Iterator prev
         chomp($_id = <$_DAU_R_SOCK>),
         chomp($_wa = <$_DAU_R_SOCK>);

         my $_var = $_obj{ $_id };

         if ( my $_code = $_var->can('prev') ) {
            my $_buf = $_freeze->([ $_code->( $_var ) ]);
            print {$_DAU_R_SOCK} length($_buf).$LF, $_buf;
         } else {
            $_iterator->( $_id, $_wa, 0 );
         }

         return;
      },

      SHR_M_RES.$LF => sub {                      # Iterator reset
         chomp($_id = <$_DAU_R_SOCK>);

         my $_var = $_obj{ $_id };

         if ( my $_code = $_var->can('reset') ) {
            $_code->( $_var );
         } else {
            delete $_itr{ $_id };
         }

         print {$_DAU_R_SOCK} $LF;

         return;
      },

      SHR_M_PDL.$LF => sub {                      # PDL::ins inplace(this),...
         chomp($_id  = <$_DAU_R_SOCK>),
         chomp($_len = <$_DAU_R_SOCK>);

         read $_DAU_R_SOCK, my($_buf), $_len;

         if ($_all{ $_id } eq 'PDL') {
            local @_ = @{ $_thaw->($_buf) };
            $_obj{ $_id }->slice( $_[0] ) .= $_[1]  if @_ == 2;
            ins( inplace( $_obj{ $_id } ), @_ )     if @_  > 2;
         }

         return;
      },

      ## ----------------------------------------------------------------------

      SHR_O_FSZ.$LF => sub {                      # A FETCHSIZE
         chomp($_id = <$_DAU_R_SOCK>);

         $_ret = $_obj{ $_id }->FETCHSIZE() || 0;
         print {$_DAU_R_SOCK} $_ret.$LF;

         return;
      },

      SHR_O_SET.$LF => sub {                      # A,H,OH,S set
         chomp($_id  = <$_DAU_R_SOCK>),
         chomp($_len = <$_DAU_R_SOCK>);

         $_frozen = chop($_len);
         read $_DAU_R_SOCK, my($_buf), $_len;

         ($_frozen)
            ? $_obj{ $_id }->set(@{ $_thaw->($_buf) })
            : $_obj{ $_id }->set($_buf);

         return;
      },

      SHR_O_GET.$LF => sub {                      # A,H,OH,S get
         chomp($_id  = <$_DAU_R_SOCK>),
         chomp($_len = <$_DAU_R_SOCK>);

         if ($_len) {
            read $_DAU_R_SOCK, $_key, $_len;
            $_fetch->($_obj{ $_id }->get($_key));
         }
         else {
            $_fetch->($_obj{ $_id }->get());
         }

         return;
      },

      SHR_O_DEL.$LF => sub {                      # A,H,OH delete
         chomp($_id  = <$_DAU_R_SOCK>),
         chomp($_wa  = <$_DAU_R_SOCK>),
         chomp($_len = <$_DAU_R_SOCK>);

         read $_DAU_R_SOCK, my($_key), $_len;

         if ($_wa) {
            my $_buf = $_freeze->([ $_obj{ $_id }->delete($_key) ]);
            print {$_DAU_R_SOCK} length($_buf).$LF, $_buf;
         }
         else {
            my $_item = $_obj{ $_id }->delete($_key);
            if (blessed($_item)) {
               my $_oid  = $_item->SHARED_ID();
               my $_keep = { $_id => 1 };
               _destroy($_keep, $_obj{ $_oid }, $_oid);
            }
         }

         return;
      },

      SHR_O_EXI.$LF => sub {                      # A,H,OH exists
         chomp($_id  = <$_DAU_R_SOCK>),
         chomp($_len = <$_DAU_R_SOCK>);

         read $_DAU_R_SOCK, $_key, $_len;
         $_ret = $_obj{ $_id }->exists($_key) ? '1' : '';

         print {$_DAU_R_SOCK} $_ret.$LF;

         return;
      },

      SHR_O_CLR.$LF => sub {                      # A,H,OH clear
         chomp($_id = <$_DAU_R_SOCK>);

         if (ref($_obj{ $_id }) =~ /^MCE::Shared::(?:Array|Hash|Ordhash)$/) {
            my $_item = $_obj{ $_id };
            my $_keep = { $_id => 1 };
            for my $k ($_item->keys) {
               if (blessed($_item->get($k))) {
                  my $_oid = $_item->get($k)->SHARED_ID();
                  _destroy($_keep, $_obj{ $_oid }, $_oid);
               }
            }
         }

         $_obj{ $_id }->clear();

         return;
      },

      SHR_O_MSE.$LF => sub {                      # A,H,OH mset
         chomp($_id  = <$_DAU_R_SOCK>),
         chomp($_wa  = <$_DAU_R_SOCK>),
         chomp($_len = <$_DAU_R_SOCK>);

         read $_DAU_R_SOCK, my($_buf), $_len;
         $_ret = $_obj{ $_id }->mset(@{ $_thaw->($_buf) });
         print {$_DAU_R_SOCK} $_ret.$LF if $_wa;

         return;
      },

      SHR_O_POP.$LF => sub {                      # A,OH pop
         chomp($_id = <$_DAU_R_SOCK>);

         my $_buf = $_freeze->([ $_obj{ $_id }->pop() ]);
         print {$_DAU_R_SOCK} length($_buf).$LF, $_buf;

         return;
      },

      SHR_O_PSH.$LF => sub {                      # A,OH push
         chomp($_id  = <$_DAU_R_SOCK>),
         chomp($_wa  = <$_DAU_R_SOCK>),
         chomp($_len = <$_DAU_R_SOCK>);

         read $_DAU_R_SOCK, my($_buf), $_len;
         $_ret = $_obj{ $_id }->push(@{ $_thaw->($_buf) });
         print {$_DAU_R_SOCK} $_ret.$LF if $_wa;

         return;
      },

      SHR_O_SFT.$LF => sub {                      # A,OH shift
         chomp($_id = <$_DAU_R_SOCK>);

         my $_buf = $_freeze->([ $_obj{ $_id }->shift() ]);
         print {$_DAU_R_SOCK} length($_buf).$LF, $_buf;

         return;
      },

      SHR_O_UNS.$LF => sub {                      # A,OH unshift
         chomp($_id  = <$_DAU_R_SOCK>),
         chomp($_wa  = <$_DAU_R_SOCK>),
         chomp($_len = <$_DAU_R_SOCK>);

         read $_DAU_R_SOCK, my($_buf), $_len;
         $_ret = $_obj{ $_id }->unshift(@{ $_thaw->($_buf) });
         print {$_DAU_R_SOCK} $_ret.$LF if $_wa;

         return;
      },

      SHR_O_CLO.$LF => sub {                      # Handle CLOSE
         chomp($_id = <$_DAU_R_SOCK>);

         close $_obj{ $_id } if defined fileno($_obj{ $_id });

         return;
      },

      SHR_O_OPN.$LF => sub {                      # Handle OPEN
         my ($_fd, $_buf);

         chomp($_id  = <$_DAU_R_SOCK>),
         chomp($_fd  = <$_DAU_R_SOCK>),
         chomp($_len = <$_DAU_R_SOCK>);

         read $_DAU_R_SOCK, $_buf, $_len;
         print {$_DAU_R_SOCK} $LF;

         if ($_fd > 2) {
            $_fd = IO::FDPass::recv(fileno $_DAU_R_SOCK); $_fd >= 0
               or _croak("cannot receive file handle: $!");
         }

         my $_args = $_thaw->($_buf);

         close $_obj{ $_id } if defined fileno($_obj{ $_id });

         if (@{ $_args } == 2) {
            open $_obj{ $_id }, "$_args->[0]", $_args->[1]
               or _croak("open error: $!");
         } else {
            open $_obj{ $_id }, $_args->[0]
               or _croak("open error: $!");
         }

         print {$_DAU_R_SOCK} $LF;

         return;
      },

      SHR_O_REA.$LF => sub {                      # Handle READ
         my ($_buf, $_a3); local $!;

         chomp($_id = <$_DAU_R_SOCK>),
         chomp($_a3 = <$_DAU_R_SOCK>);

         $_ret = read($_obj{ $_id }, $_buf, $_a3);
         print {$_DAU_R_SOCK} $_ret.$LF . length($_buf).$LF, $_buf;

         return;
      },

      SHR_O_RLN.$LF => sub {                      # Handle READLINE
         chomp($_id  = <$_DAU_R_SOCK>),
         chomp($_len = <$_DAU_R_SOCK>);

         local $/; read($_DAU_R_SOCK, $/, $_len) if ($_len);
         my ($_fh, $_buf) = ($_obj{ $_id });

         # support special case; e.g. $/ = "\n>" for bioinformatics
         # anchoring ">" at the start of line

         if (length $/ > 1 && substr($/, 0, 1) eq "\n" && !eof $_fh) {
            $_len = length($/) - 1;
            if (tell $_fh) {
               $_buf = substr($/, 1), $_buf .= readline($_fh);
            } else {
               $_buf = readline($_fh);
            }
            substr($_buf, -$_len, $_len, '')
               if (substr($_buf, -$_len) eq substr($/, 1));
         }
         else {
            $_buf = readline($_fh);
         }

         print {$_DAU_R_SOCK} "$.$LF" . length($_buf).$LF, $_buf;

         return;
      },

      SHR_O_PRI.$LF => sub {                      # Handle PRINT
         chomp($_id  = <$_DAU_R_SOCK>),
         chomp($_len = <$_DAU_R_SOCK>);

         read $_DAU_R_SOCK, my($_buf), $_len;
         print {$_obj{ $_id }} $_buf;

         return;
      },

      SHR_O_WRI.$LF => sub {                      # Handle WRITE
         chomp($_id  = <$_DAU_R_SOCK>),
         chomp($_len = <$_DAU_R_SOCK>);

         read $_DAU_R_SOCK, my($_buf), $_len;
         $_ret = syswrite $_obj{ $_id }, $_buf;

         print {$_DAU_R_SOCK} $_ret.$LF;

         return;
      },

      SHR_O_CVB.$LF => sub {                      # Condvar broadcast
         chomp($_id = <$_DAU_R_SOCK>);

         $_CV = $_obj{ $_id };
         my $_hndl = $_CV->{_cw_sock};
         syswrite($_hndl, $LF) for 1 .. $_CV->{_count};
         $_CV->{_count} = 0;

         print {$_DAU_R_SOCK} $LF;

         return;
      },

      SHR_O_CVS.$LF => sub {                      # Condvar signal
         chomp($_id = <$_DAU_R_SOCK>);

         $_CV = $_obj{ $_id };

         $_CV->{_count} -= 1, syswrite $_CV->{_cw_sock}, $LF
            if ( $_CV->{_count} >= 0 );

         print {$_DAU_R_SOCK} $LF;

         return;
      },

      SHR_O_CVT.$LF => sub {                      # Condvar timedwait
         chomp($_id = <$_DAU_R_SOCK>);

         $_CV = $_obj{ $_id };
         $_CV->{_count} -= 1;

         print {$_DAU_R_SOCK} $LF;

         return;
      },

      SHR_O_CVW.$LF => sub {                      # Condvar wait
         chomp($_id = <$_DAU_R_SOCK>);

         $_CV = $_obj{ $_id };
         $_CV->{_count} += 1;

         return;
      },

      SHR_O_QUA.$LF => sub {                      # Queue await
         chomp($_id = <$_DAU_R_SOCK>),
         chomp($_t  = <$_DAU_R_SOCK>);

         $_Q = $_obj{ $_id };
         $_Q->{_tsem} = $_t;

         if ($_Q->pending() <= $_t) {
            syswrite $_Q->{_aw_sock}, $LF;
         } else {
            $_Q->{_asem} += 1;
         }

         return;
      },

      SHR_O_QUD.$LF => sub {                      # Queue dequeue
         chomp($_id  = <$_DAU_R_SOCK>),
         chomp($_cnt = <$_DAU_R_SOCK>);

         $_cnt = 0 if ($_cnt == 1);
         $_Q = $_obj{ $_id };

         my (@_items, $_buf);

         if ($_cnt) {
            push(@_items, $_Q->_dequeue()) for (1 .. $_cnt);
         } else {
            $_buf = $_Q->_dequeue();
         }

         if ($_Q->{_fast}) {
            ## The 'fast' option may reduce wait time, thus run faster
            if ($_Q->{_dsem} <= 1) {
               $_pending = $_Q->pending();
               $_pending = int($_pending / $_cnt) if ($_cnt);
               if ($_pending) {
                  $_pending = MAX_DQ_DEPTH if ($_pending > MAX_DQ_DEPTH);
                  syswrite $_Q->{_qw_sock}, $LF for (1 .. $_pending);
               }
               $_Q->{_dsem}  = $_pending;
            }
            else {
               $_Q->{_dsem} -= 1;
            }
         }
         else {
            ## Otherwise, never to exceed one byte in the channel
            syswrite $_Q->{_qw_sock}, $LF if ($_Q->_has_data());
         }

         if ($_cnt) {
            if (defined $_items[0]) {
               $_buf = $_freeze->(\@_items);
               print {$_DAU_R_SOCK} length($_buf).'1'.$LF, $_buf;
            } else {
               print {$_DAU_R_SOCK} '-1'.$LF;
            }
         }
         else {
            if (defined $_buf) {
               if (!ref($_buf)) {
                  print {$_DAU_R_SOCK} length($_buf).'0'.$LF, $_buf;
               } else {
                  $_buf = $_freeze->([ $_buf ]);
                  print {$_DAU_R_SOCK} length($_buf).'1'.$LF, $_buf;
               }
            }
            else {
               print {$_DAU_R_SOCK} '-1'.$LF;
            }
         }

         if ($_Q->{_await} && $_Q->{_asem} && $_Q->pending() <= $_Q->{_tsem}) {
            syswrite $_Q->{_aw_sock}, $LF for (1 .. $_Q->{_asem});
            $_Q->{_asem} = 0;
         }

         $_Q->{_nb_flag} = 0;

         return;
      },

      SHR_O_QUN.$LF => sub {                      # Queue dequeue non-blocking
         chomp($_id  = <$_DAU_R_SOCK>),
         chomp($_cnt = <$_DAU_R_SOCK>);

         $_Q = $_obj{ $_id };

         if ($_cnt == 1) {
            my $_buf = $_Q->_dequeue();

            if (defined $_buf) {
               if (!ref($_buf)) {
                  print {$_DAU_R_SOCK} length($_buf).'0'.$LF, $_buf;
               } else {
                  $_buf = $_freeze->([ $_buf ]);
                  print {$_DAU_R_SOCK} length($_buf).'1'.$LF, $_buf;
               }
            }
            else {
               print {$_DAU_R_SOCK} '-1'.$LF;
            }
         }
         else {
            my @_items; push(@_items, $_Q->_dequeue()) for (1 .. $_cnt);

            if (defined $_items[0]) {
               my $_buf = $_freeze->(\@_items);
               print {$_DAU_R_SOCK} length($_buf).'1'.$LF, $_buf;
            } else {
               print {$_DAU_R_SOCK} '-1'.$LF;
            }
         }

         if ($_Q->{_await} && $_Q->{_asem} && $_Q->pending() <= $_Q->{_tsem}) {
            syswrite $_Q->{_aw_sock}, $LF for (1 .. $_Q->{_asem});
            $_Q->{_asem} = 0;
         }

         $_Q->{_nb_flag} = 1;

         return;
      },

      SHR_O_QUP.$LF => sub {                      # Queue pending
         chomp($_id = <$_DAU_R_SOCK>);

         print {$_DAU_R_SOCK} $_obj{ $_id }->pending().$LF;

         return;
      },

   );

   ## Call on hash function; exit loop when finished.

   if ($_is_MSWin32) {
      ## The normal loop hangs on Windows when processes/threads start/exit.
      ## Using ioctl() properly, http://www.perlmonks.org/?node_id=780083

      my $_val_bytes = "\x00\x00\x00\x00";
      my $_ptr_bytes = unpack('I', pack('P', $_val_bytes));
      my $_nbytes; my $_count = 0;

      while (1) {
         ioctl($_DAT_R_SOCK, 0x4004667f, $_ptr_bytes);  # MSWin32 FIONREAD

         unless ($_nbytes = unpack('I', $_val_bytes)) {
            # delay so not to consume a CPU for non-blocking ioctl
            $_count = 0, sleep 0.008 if ++$_count > 1618;
         }
         else {
            $_count = 0;
            do {
               sysread($_DAT_R_SOCK, $_func, 8);

               $_DAU_R_SOCK = $_channels->[ substr($_func, -2, 2, '') ];
               $_output_function{$_func}();

               last if $_done;

            } while ($_nbytes -= 8);
         }
      }
   }
   else {
      while (1) {
         $_func = <$_DAT_R_SOCK>;

         $_DAU_R_SOCK = $_channels->[ <$_DAT_R_SOCK> ];
         $_output_function{$_func}();

         last if $_done;
      }
   }

   ## Wait for the main thread to exit to not impact socket handles.
   ## Exiting via POSIX's _exit to avoid END blocks.

   sleep 3.0 if $_is_MSWin32;
   POSIX::_exit(0) if $_is_child;

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Object package.
##
###############################################################################

package MCE::Shared::Object;

no warnings qw( threads recursion uninitialized once );

use Time::HiRes qw( sleep );
use Scalar::Util qw( looks_like_number );
use MCE::Shared::Base;
use bytes;

use constant {
   WA_UNDEF => 0, WA_ARRAY => 1, WA_SCALAR => 2,
};

use overload (
   q("")    => \&MCE::Shared::Base::_stringify_s,
   q(0+)    => \&MCE::Shared::Base::_numify,
   q(@{})   => sub {
      $_aref{ ${ $_[0] } } || do {
         return $_[0] if $_[0]->blessed ne 'MCE::Shared::Array';
         tie my @a, 'MCE::Shared::Object', $_[0];
         $_aref{ ${ $_[0] } } = \@a;
      };
   },
   q(%{})   => sub {
      $_href{ ${ $_[0] } } || do {
         return $_[0] if $_[0]->blessed !~ /^MCE::Shared::(?:Hash|Ordhash)$/;
         tie my %h, 'MCE::Shared::Object', $_[0];
         $_href{ ${ $_[0] } } = \%h;
      };
   },
   fallback => 1
);

###############################################################################

my ($_DAT_LOCK, $_DAT_W_SOCK, $_DAU_W_SOCK, $_chn);
my ($_dat_ex, $_dat_un, %_iter, %_is_hash);

my $_blessed = \&Scalar::Util::blessed;
my $_ready   = \&MCE::Util::_sock_ready;

## Hook for non-MCE worker threads.

sub CLONE {
   %_new = (); &_init(threads->tid()) if $INC{'threads.pm'} && !$INC{'MCE.pm'};
}

## Private functions.

sub DESTROY {
   if (defined $_svr_pid && $_is_client && $_[0]) {
      my $_id = $_[0]->SHARED_ID();

      if (exists $_new{ $_id }) {
         my $_pid = $_has_threads ? $$ .'.'. $_tid : $$;

         if ($_new{ $_id } eq $_pid) {
            return if ($INC{'MCE/Signal.pm'} && $MCE::Signal::KILLED);
            return if ($MCE::Shared::Server::KILLED);

            delete($_new{ $_id }), _req1('M~DES', $_id.$LF);
         }
      }
   }

   return;
}

sub _croak {
   goto &MCE::Shared::Base::_croak;
}
sub SHARED_ID { ${ $_[0] } }
sub TIEARRAY  {    $_[1]   }
sub TIEHANDLE {    $_[1]   }
sub TIEHASH   {    $_[1]   }
sub TIESCALAR {    $_[1]   }

sub _server_init {
   $_chn        = 1;
   $_DAT_LOCK   = $_SVR->{'_mutex_'.$_chn};
   $_DAT_W_SOCK = $_SVR->{_dat_w_sock}->[0];
   $_DAU_W_SOCK = $_SVR->{_dat_w_sock}->[$_chn];

   $_dat_ex = sub { sysread(  $_DAT_LOCK->{_r_sock}, my $_b, 1 ) };
   $_dat_un = sub { syswrite( $_DAT_LOCK->{_w_sock}, '0' ) };

   return;
}

sub _get_client_id {
   my $_ret;

   local $\ = undef if (defined $\);
   local $/ = $LF if (!$/ || $/ ne $LF);

   $_dat_ex->();
   print {$_DAT_W_SOCK} 'M~CID'.$LF . $_chn.$LF;
   chomp($_ret = <$_DAU_W_SOCK>);
   $_dat_un->();

   return $_ret;
}

sub _init {
   return unless defined $_SVR;

   my $_wid = $_[0] || &_get_client_id();
      $_wid = $$ if ( $_wid !~ /\d+/ );

   $_chn        = abs($_wid) % $_SVR->{_data_channels} + 1;
   $_DAT_LOCK   = $_SVR->{'_mutex_'.$_chn};
   $_DAU_W_SOCK = $_SVR->{_dat_w_sock}->[$_chn];

   %_aref = (), %_href = (), %_new = (), %_iter = (), %_is_hash = ();

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Methods not defined below are handled via AUTOLOAD.
##
###############################################################################

sub AUTOLOAD {
   my ($_id, $_fn, $_wa, $_len, $_buf, $_tmp);

   ## $MCE::...::AUTOLOAD equals MCE::Shared::Object::<Method_Name>
   ## The method name begins at offset 21, so not to rindex below.

   $_id = ${ (shift) };
   $_fn = substr($MCE::Shared::Object::AUTOLOAD, 21);
   $_wa = (!defined wantarray) ? WA_UNDEF : (wantarray) ? WA_ARRAY : WA_SCALAR;

   local $\ = undef if (defined $\);

   if (@_) {
      if (@_ == 1 && !ref($_[0]) && defined $_[0]) {
         $_buf = $_id.$LF . $_fn.$LF . $_wa.$LF . length($_[0]).'0'.$LF;

         $_dat_ex->();
         print {$_DAT_W_SOCK} 'M~OBJ'.$LF . $_chn.$LF;
         print {$_DAU_W_SOCK} $_buf, $_[0];
      }
      else {
         $_tmp = $_freeze->([ @_ ]);
         $_buf = $_id.$LF . $_fn.$LF . $_wa.$LF . length($_tmp).'1'.$LF;

         $_dat_ex->();
         print {$_DAT_W_SOCK} 'M~OBJ'.$LF . $_chn.$LF;
         print {$_DAU_W_SOCK} $_buf, $_tmp;
      }
   }
   else {
      $_buf = $_id.$LF . $_fn.$LF . $_wa.$LF . '-1'.$LF;

      $_dat_ex->();
      print {$_DAT_W_SOCK} 'M~OBJ'.$LF . $_chn.$LF;
      print {$_DAU_W_SOCK} $_buf;
   }

   if ($_wa) {
      local $/ = $LF if (!$/ || $/ ne $LF);
      chomp($_len = <$_DAU_W_SOCK>);

      my $_frozen = chop($_len);
      read $_DAU_W_SOCK, $_buf, $_len;
      $_dat_un->();

      ($_wa != WA_ARRAY)
         ? ($_frozen) ? $_thaw->($_buf)[0] : $_buf
         : @{ $_thaw->($_buf) };
   }
   else {
      $_dat_un->();
   }
}

###############################################################################
## ----------------------------------------------------------------------------
## Common routines.
##
###############################################################################

## called by FETCHSIZE, EXISTS, broadcast, signal, timedwait, pending,
## blessed, destroy, and reset

sub _req1 {
   local $\ = undef if (defined $\);
   local $/ = $LF if (!$/ || $/ ne $LF);

   $_dat_ex->();
   print {$_DAT_W_SOCK} $_[0].$LF . $_chn.$LF;
   print {$_DAU_W_SOCK} $_[1];

   chomp(my $_ret = <$_DAU_W_SOCK>);
   $_dat_un->();

   $_ret;
}

## called by STORE, CLEAR, CLOSE, PRINT, PRINTF, timedwait, wait, await,
## and ins_inplace

sub _req2 {
   local $\ = undef if (defined $\);

   $_dat_ex->();
   print {$_DAT_W_SOCK} $_[0].$LF . $_chn.$LF;
   print {$_DAU_W_SOCK} $_[1], $_[2];
   $_dat_un->();

   1;
}

## called by FETCH and export

sub _req3 {
   local $\ = undef if (defined $\);
   local $/ = $LF if (!$/ || $/ ne $LF);

   $_dat_ex->();
   print {$_DAT_W_SOCK} $_[0].$LF . $_chn.$LF;
   print {$_DAU_W_SOCK} $_[1], $_[2];

   chomp(my $_len = <$_DAU_W_SOCK>);

   if ($_len < 0) { $_dat_un->(); return undef; }

   my $_frozen = chop($_len);
   read $_DAU_W_SOCK, my($_buf), $_len;
   $_dat_un->();

   ($_frozen) ? $_thaw->($_buf) : $_buf;
}

## called by dequeue and dequeue_nb

sub _req4 {
   local $\ = undef if (defined $\);
   local $/ = $LF if (!$/ || $/ ne $LF);

   $_dat_ex->();
   print {$_DAT_W_SOCK} $_[0].$LF . $_chn.$LF;
   print {$_DAU_W_SOCK} $_[1];

   chomp(my $_len = <$_DAU_W_SOCK>);

   if ($_len < 0) {
      $_dat_un->();
      return undef;  # do not change to return;
   }

   my $_frozen = chop($_len);
   read $_DAU_W_SOCK, my($_buf), $_len;
   $_dat_un->();

   ($_[2] == 1)
      ? ($_frozen) ? $_thaw->($_buf)[0] : $_buf
      : @{ $_thaw->($_buf) };
}

## called by mset, push, and unshift

sub _req5 {
   my ($_tag, $_shr) = (shift, shift);
   my ($_id , $_wa ) = (${ $_shr }, defined wantarray ? 1 : 0);
   my ($_len, $_buf);

   return unless @_;

   if (!exists $_is_hash{ $_id }) {
      $_is_hash{ $_id } = (
         $_shr->blessed() =~ /^MCE::Shared::(?:Hash|Ordhash)$/
      ) ? 1 : 0;
   }

   if ($_is_hash{ $_id } || $_tag eq 'O~MSE') {
      _croak("requires key-value pairs") unless ( @_ % 2 == 0 );
      my ($_key, @_pairs);
      for (my $i = 1; $i <= $#_; $i += 2) {
         $_[$i] = MCE::Shared::share({ _DEEPLY_ => 1 }, $_[$i]) if ref($_[$i]);
      }
      $_key = shift(), push(@_pairs, "$_key", shift()) while (@_);
      $_buf = $_freeze->(\@_pairs);
   }
   else {
      for my $i (0 .. $#_) {
         $_[$i] = MCE::Shared::share({ _DEEPLY_ => 1 }, $_[$i]) if ref($_[$i]);
      }
      $_buf = $_freeze->([ @_ ]);
   }

   local $\ = undef if (defined $\);

   $_dat_ex->();
   print {$_DAT_W_SOCK} $_tag.$LF . $_chn.$LF;
   print {$_DAU_W_SOCK} $_id.$LF . $_wa.$LF . length($_buf).$LF, $_buf;

   if ($_wa) {
      local $/ = $LF if (!$/ || $/ ne $LF);
      chomp($_len = <$_DAU_W_SOCK>);
   }

   $_dat_un->();
   $_len;
}

## called by POP and SHIFT

sub _req6 {
   my ($_tag, $_id) = (shift, shift);

   local $\ = undef if (defined $\);
   local $/ = $LF if (!$/ || $/ ne $LF);

   $_dat_ex->();
   print {$_DAT_W_SOCK} $_tag.$LF . $_chn.$LF;
   print {$_DAU_W_SOCK} $_id.$LF;

   chomp(my $_len = <$_DAU_W_SOCK>);
   read $_DAU_W_SOCK, my($_buf), $_len;
   $_dat_un->();

   my $_ret = $_thaw->($_buf);

   if (@{ $_ret } == 2) {
      $_ret->[1] = $_ret->[1]->destroy()
         if ($_blessed->($_ret->[1]) && $_ret->[1]->can('destroy'));

      return @{ $_ret };
   }
   else {
      $_ret->[0] = $_ret->[0]->destroy()
         if ($_blessed->($_ret->[0]) && $_ret->[0]->can('destroy'));

      return $_ret->[0];
   }
}

## called by next and prev

sub _req7 {
   local $\ = undef if (defined $\);
   local $/ = $LF if (!$/ || $/ ne $LF);

   $_dat_ex->();
   print {$_DAT_W_SOCK} $_[0].$LF . $_chn.$LF;
   print {$_DAU_W_SOCK} $_[1];

   chomp(my $_len = <$_DAU_W_SOCK>);

   if ($_len < 0) { $_dat_un->(); return; }
   read $_DAU_W_SOCK, my($_buf), $_len;
   $_dat_un->();

   ($_[2]) ? @{ $_thaw->($_buf) } : $_thaw->($_buf)[-1];
}

###############################################################################
## ----------------------------------------------------------------------------
## Methods optimized for Array, Hash, Ordhash, and Scalar.
##
###############################################################################

sub FETCHSIZE {
   _req1('O~FSZ', ${ $_[0] }.$LF);
}

sub STORE {
   my ($_id, $_buf, $_len) = (${ (shift) });

   if (@_ == 2) {
      my $_key = $_[0];
      $_[1] = MCE::Shared::share({ _DEEPLY_ => 1 }, $_[1]) if ref($_[1]);
      $_buf = $_freeze->([ "$_key", $_[1] ]);

      _req2('O~SET', $_id.$LF . length($_buf).'1'.$LF, $_buf);

      $_[1];
   }
   elsif (@_) {
      _croak('storing a reference for SCALAR is not supported') if ref($_[0]);

      if (defined $_[0]) {
         _req2('O~SET', $_id.$LF . length($_[0]).'0'.$LF, $_[0]);
      }
      else {
         $_buf = $_freeze->([ $_[0] ]);
         _req2('O~SET', $_id.$LF . length($_buf).'1'.$LF, $_buf);
      }

      $_[0]
   }
   else {
      ();
   }
}

sub FETCH {
   _req3('O~GET', ${ $_[0] }.$LF . length($_[1]).$LF, $_[1]);
}

sub DELETE {
   my $_id  = ${ $_[0] };
   my $_wa  = (defined wantarray) ? 1 : 0;
   my $_key = (defined $_[1]) ? $_[1] : return;

   local $\ = undef if (defined $\);

   $_dat_ex->();
   print {$_DAT_W_SOCK} 'O~DEL'.$LF . $_chn.$LF;
   print {$_DAU_W_SOCK} $_id.$LF . $_wa.$LF . length($_key).$LF, $_key;

   if ($_wa) {
      local $/ = $LF if (!$/ || $/ ne $LF);
      chomp(my $_len = <$_DAU_W_SOCK>);

      read $_DAU_W_SOCK, my($_buf), $_len;
      $_dat_un->();

      my $_ret = $_thaw->($_buf);

      if (@{ $_ret } == 2) {
         $_ret->[1] = $_ret->[1]->destroy()
            if ($_blessed->($_ret->[1]) && $_ret->[1]->can('destroy'));

         return @{ $_ret };
      }
      else {
         $_ret->[0] = $_ret->[0]->destroy()
            if ($_blessed->($_ret->[0]) && $_ret->[0]->can('destroy'));

         return $_ret->[0];
      }
   }
   else {
      $_dat_un->();
   }
}

sub EXISTS {
   (defined $_[1])
      ? _req1('O~EXI', ${ $_[0] }.$LF . length($_[1]).$LF . $_[1])
      : '';
}

sub CLEAR {
   _req2('O~CLR', ${ $_[0] }.$LF, '');
   return;
}

sub FIRSTKEY {
   my $_id   = ${ $_[0] };
   my @_keys = $_[0]->keys;

   $_iter{ $_id } = sub {
      return unless @_keys;
      return shift(@_keys);
   };

   $_iter{ $_id }->();
}

sub NEXTKEY {
   $_iter{ ${ $_[0] } }->();
}

sub mset    { _req5('O~MSE', @_) }
sub POP     { _req6('O~POP', ${ $_[0] }) }
sub PUSH    { _req5('O~PSH', @_) }
sub SHIFT   { _req6('O~SFT', ${ $_[0] }) }
sub UNSHIFT { _req5('O~UNS', @_) }

###############################################################################
## ----------------------------------------------------------------------------
## Methods optimized for Handle.
##
###############################################################################

sub CLOSE {
   _req2('O~CLO', ${ $_[0] }.$LF, '');
}

sub OPEN {
   my ($_id, $_fd, $_buf) = (${ (shift) });
   return unless defined $_[0];

   if (@_ == 2 && ref $_[1] && defined($_fd = fileno($_[1]))) {
      $_buf = $_freeze->([ $_[0]."&=$_fd" ]);
   }
   elsif (!ref $_[-1]) {
      $_fd  = ($_[-1] =~ /&=(\d+)$/) ? $1 : -1;
      $_buf = $_freeze->([ @_ ]);
   }
   else {
      _croak("open error: unsupported use-case");
   }

   if ($_fd > 2 && !$INC{'IO/FDPass.pm'}) {
      _croak(
         "\nSharing a handle object while the server is running\n",
         "requires the IO::FDPass module.\n\n"
      );
   }

   local $\ = undef if (defined $\);
   local $/ = $LF if (!$/ || $/ ne $LF);

   $_dat_ex->();
   print {$_DAT_W_SOCK} 'O~OPN'.$LF . $_chn.$LF;
   print {$_DAU_W_SOCK} $_id.$LF . $_fd.$LF . length($_buf).$LF . $_buf;
   <$_DAU_W_SOCK>;

   IO::FDPass::send( fileno $_DAU_W_SOCK, fileno $_fd ) if ($_fd > 2);

   <$_DAU_W_SOCK>;
   $_dat_un->();

   return;
}

sub READ {
   my $_id = ${ $_[0] };

   local $\ = undef if (defined $\);
   local $/ = $LF if (!$/ || $/ ne $LF);

   $_dat_ex->();
   print {$_DAT_W_SOCK} 'O~REA'.$LF . $_chn.$LF;
   print {$_DAU_W_SOCK} $_id.$LF . $_[2].$LF;

   chomp(my $_ret = <$_DAU_W_SOCK>);
   chomp(my $_len = <$_DAU_W_SOCK>);

   if ($_len) {
      (defined $_[3])
         ? read($_DAU_W_SOCK, $_[1], $_len, $_[3])
         : read($_DAU_W_SOCK, $_[1], $_len);
   }
   else {
      my $_ref = \$_[1];
      $$_ref = '';
   }

   $_dat_un->();
   $_ret;
}

sub READLINE {
   my $_id  = ${ $_[0] };
   local $\ = undef if (defined $\);

   $_dat_ex->();
   print {$_DAT_W_SOCK} 'O~RLN'.$LF . $_chn.$LF;
   print {$_DAU_W_SOCK} $_id.$LF . length($/).$LF . $/;

   local $/ = $LF if (!$/ || $/ ne $LF);
   chomp(my $_ret = <$_DAU_W_SOCK>);
   chomp(my $_len = <$_DAU_W_SOCK>);

   read($_DAU_W_SOCK, my ($_buf), $_len) if $_len;
   $_dat_un->();

   $. = $_ret;
   $_buf;
}

sub PRINT {
   my $_id  = ${ (shift) };
   my $_buf = join(defined $, ? $, : "", @_);

   $_buf .= $\ if defined $\;

   (length $_buf)
      ? _req2('O~PRI', $_id.$LF . length($_buf).$LF, $_buf)
      : 1;
}

sub PRINTF {
   my $_id  = ${ (shift) };
   my $_buf = sprintf(shift, @_);

   (length $_buf)
      ? _req2('O~PRI', $_id.$LF . length($_buf).$LF, $_buf)
      : 1;
}

sub WRITE {
   my $_id = ${ (shift) };

   local $\ = undef if (defined $\);
   local $/ = $LF if (!$/ || $/ ne $LF);

   if (@_ == 1 || (@_ == 2 && $_[1] == length($_[0]))) {
      $_dat_ex->();
      print {$_DAT_W_SOCK} 'O~WRI'.$LF . $_chn.$LF;
      print {$_DAU_W_SOCK} $_id.$LF . length($_[0]).$LF, $_[0];
   }
   else {
      my $_buf = substr($_[0], ($_[2] || 0), $_[1]);
      $_dat_ex->();
      print {$_DAT_W_SOCK} 'O~WRI'.$LF . $_chn.$LF;
      print {$_DAU_W_SOCK} $_id.$LF . length($_buf).$LF, $_buf;
   }

   chomp(my $_ret = <$_DAU_W_SOCK>);
   $_dat_un->();

   $_ret ? $_ret : undef;
}

###############################################################################
## ----------------------------------------------------------------------------
## Methods optimized for Condvar.
##
###############################################################################

sub lock {
   my $_id = ${ $_[0] };

   return unless ( my $_CV = $_obj{ $_id } );
   return unless ( exists $_CV->{_cr_sock} );

   $_CV->{_mutex}->lock;
}

sub unlock {
   my $_id = ${ $_[0] };

   return unless ( my $_CV = $_obj{ $_id } );
   return unless ( exists $_CV->{_cr_sock} );

   $_CV->{_mutex}->unlock;
}

sub broadcast {
   my $_id = ${ $_[0] };

   return unless ( my $_CV = $_obj{ $_id } );
   return unless ( exists $_CV->{_cr_sock} );

   sleep($_[1]) if defined $_[1];

   _req1('O~CVB', $_id.$LF);
   $_CV->{_mutex}->unlock;
}

sub signal {
   my $_id = ${ $_[0] };

   return unless ( my $_CV = $_obj{ $_id } );
   return unless ( exists $_CV->{_cr_sock} );

   sleep($_[1]) if defined $_[1];

   _req1('O~CVS', $_id.$LF);
   $_CV->{_mutex}->unlock;
}

sub timedwait {
   my $_id = ${ $_[0] };
   my $_timeout = $_[1];

   return unless ( my $_CV = $_obj{ $_id } );
   return unless ( exists $_CV->{_cr_sock} );

   return $_[0]->wait() unless $_timeout;

   _croak('Condvar: timedwait (timeout) is not an integer')
      if (!looks_like_number($_timeout) || int($_timeout) != $_timeout);

   _req2('O~CVW', $_id.$LF, '');
   $_CV->{_mutex}->unlock;

   local $@; eval {
      local $SIG{ALRM} = sub { die "alarm clock restart\n" };
      alarm $_timeout unless $_is_MSWin32;

      die "alarm clock restart\n"
         if $_is_MSWin32 && $_ready->($_CV->{_cr_sock}, $_timeout);

      sysread $_CV->{_cr_sock}, my($_next), 1;  # block

      alarm 0;
   };

   alarm 0;

   if ($@) {
      chomp($@), _croak($@) unless $@ eq "alarm clock restart\n";
      _req1('O~CVT', $_id.$LF);

      return 1;
   }

   return '';
}

sub wait {
   my $_id = ${ $_[0] };

   return unless ( my $_CV = $_obj{ $_id } );
   return unless ( exists $_CV->{_cr_sock} );

   _req2('O~CVW', $_id.$LF, '');
   $_CV->{_mutex}->unlock;

   $_ready->($_CV->{_cr_sock}) if $_is_MSWin32;
   sysread $_CV->{_cr_sock}, my($_next), 1;  # block

   return '';
}

###############################################################################
## ----------------------------------------------------------------------------
## Methods optimized for Queue.
##
###############################################################################

sub await {
   my $_id = ${ (shift) };

   return unless ( my $_Q = $_obj{ $_id } );
   return unless ( exists $_Q->{_ar_sock} );

   my $_t = shift || 0;

   _croak('Queue: (await) is not enabled for this queue')
      unless (exists $_Q->{_ar_sock});
   _croak('Queue: (await threshold) is not an integer')
      if (!looks_like_number($_t) || int($_t) != $_t);

   $_t = 0 if ($_t < 0);
   _req2('O~QUA', $_id.$LF . $_t.$LF, '');

   $_ready->($_Q->{_ar_sock}) if $_is_MSWin32;
   sysread $_Q->{_ar_sock}, my($_next), 1;  # block

   return;
}

sub dequeue {
   my $_id = ${ (shift) };

   return unless ( my $_Q = $_obj{ $_id } );
   return unless ( exists $_Q->{_qr_sock} );

   my $_buf; my $_cnt = shift;

   if (defined $_cnt && $_cnt ne '1') {
      _croak('Queue: (dequeue count argument) is not valid')
         if (!looks_like_number($_cnt) || int($_cnt) != $_cnt || $_cnt < 1);
   } else {
      $_cnt = 1;
   }

   $_ready->($_Q->{_qr_sock}) if $_is_MSWin32;
   sysread $_Q->{_qr_sock}, my($_next), 1;  # block

   _req4('O~QUD', $_id.$LF . $_cnt.$LF, $_cnt);
}

sub dequeue_nb {
   my $_id = ${ (shift) };

   return unless ( my $_Q = $_obj{ $_id } );
   return unless ( exists $_Q->{_qr_sock} );

   my $_buf; my $_cnt = shift;

   if ($_Q->{_fast}) {
      warn "Queue: (dequeue_nb) is not allowed for fast => 1\n";
      return;
   }
   if (defined $_cnt && $_cnt ne '1') {
      _croak('Queue: (dequeue_nb count argument) is not valid')
         if (!looks_like_number($_cnt) || int($_cnt) != $_cnt || $_cnt < 1);
   } else {
      $_cnt = 1;
   }

   _req4('O~QUN', $_id.$LF . $_cnt.$LF, $_cnt);
}

sub pending {
   _req1('O~QUP', ${ $_[0] }.$LF);
}

###############################################################################
## ----------------------------------------------------------------------------
## Common methods and aliases.
##
###############################################################################

sub blessed {
   _req1('M~BLE', ${ $_[0] }.$LF);
}

sub destroy {
   my $_id   = ${ $_[0] };
   my $_item = (defined wantarray) ? $_[0]->export() : undef;
   my $_pid  = $_has_threads ? $$ .'.'. $_tid : $$;

   delete $_all{ $_id }; delete $_obj{ $_id };
   %_aref = (), %_href = ();

   if (exists $_new{ $_id } && $_new{ $_id } eq $_pid) {
      _req1('M~DES', $_id.$LF);
   }

   $_[0] = undef;

   $_item;
}

sub export {
   my $_id   = ${ (shift) };
   my $_lkup = ref($_[0]) eq 'HASH' ? shift : {};

   ## safety for circular references to not loop endlessly
   return $_lkup->{ $_id } if exists $_lkup->{ $_id };

   my $_tmp   = @_ ? $_freeze->([ @_ ]) : '';
   my $_buf   = $_id.$LF . length($_tmp).$LF;
   my $_item  = $_lkup->{ $_id } = _req3('M~EXP', $_buf, $_tmp);
   my $_class = $_blessed->($_item);

   if ($_class =~ /^MCE::Shared::(?:Array|Hash|Ordhash)$/) {
      require MCE::Shared::Array   if $_class eq 'MCE::Shared::Array';
      require MCE::Shared::Hash    if $_class eq 'MCE::Shared::Hash';
      require MCE::Shared::Ordhash if $_class eq 'MCE::Shared::Ordhash';

      for my $k ($_item->keys) {
         if ($_blessed->($_item->get($k)) && $_item->get($k)->can('export')) {
            $_item->set($k, $_item->get($k)->export($_lkup));
         }
      }
   }
   elsif ($_class eq 'MCE::Shared::Scalar') {
      require MCE::Shared::Scalar;

      if ($_blessed->($_item->get()) && $_item->get()->can('export')) {
         $_item->set($_item->get()->export($_lkup));
      }
   }

   $_item;
}

sub iterator {
   my ( $self, @keys ) = @_;
   @keys = $self->keys unless @keys;

   return sub {
      return unless @keys;
      my $key = shift(@keys);
      return ( $key => $self->get($key) );
   };
}

sub next {
   my $_wa = (wantarray) ? 1 : 0;
   _req7('M~NXT', ${ $_[0] }.$LF . $_wa.$LF, $_wa);
}

sub prev {
   my $_wa = (wantarray) ? 1 : 0;
   _req7('M~PRE', ${ $_[0] }.$LF . $_wa.$LF, $_wa);
}

sub reset {
   _req1('M~RES', ${ $_[0] }.$LF);
   return;
}

if ($INC{'PDL.pm'}) {
   local $@; eval q{
      sub ins_inplace {
         my $_id = ${ (shift) };
         if (@_) {
            my $_tmp = $_freeze->([ @_ ]);
            my $_buf = $_id.$LF . length($_tmp).$LF;
            _req2('M~PDL', $_buf, $_tmp);
         }
         return;
      }
   };
}

{
   no strict 'refs';
   *{ __PACKAGE__.'::set'     } = \&STORE;
   *{ __PACKAGE__.'::get'     } = \&FETCH;
   *{ __PACKAGE__.'::delete'  } = \&DELETE;
   *{ __PACKAGE__.'::exists'  } = \&EXISTS;
   *{ __PACKAGE__.'::clear'   } = \&CLEAR;
   *{ __PACKAGE__.'::pop'     } = \&POP;
   *{ __PACKAGE__.'::push'    } = \&PUSH;
   *{ __PACKAGE__.'::shift'   } = \&SHIFT;
   *{ __PACKAGE__.'::unshift' } = \&UNSHIFT;
}

1;

__END__

###############################################################################
## ----------------------------------------------------------------------------
## Module usage.
##
###############################################################################

=head1 NAME

MCE::Shared::Server - Server/Object classes for MCE::Shared. 

=head1 VERSION

This document describes MCE::Shared::Server version 1.699_001

=head1 DESCRIPTION

Core class for L<MCE::Shared|MCE::Shared>. There is no public API.

=head1 INDEX

L<MCE|MCE>, L<MCE::Core|MCE::Core>, L<MCE::Shared|MCE::Shared>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

