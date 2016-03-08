###############################################################################
## ----------------------------------------------------------------------------
## Server/Object packages for MCE::Shared.
##
###############################################################################

package MCE::Shared::Server;

use 5.010001;
use strict;
use warnings;

no warnings qw( threads recursion uninitialized numeric once );

our $VERSION = '1.700';

## no critic (BuiltinFunctions::ProhibitStringyEval)
## no critic (Subroutines::ProhibitExplicitReturnUndef)
## no critic (TestingAndDebugging::ProhibitNoStrict)
## no critic (InputOutput::ProhibitTwoArgOpen)

use Carp ();
use Time::HiRes qw( sleep );
use Scalar::Util qw( blessed reftype weaken );
use Socket qw( SOL_SOCKET SO_RCVBUF );
use Storable ();
use bytes;

no overloading;

my ($_freeze, $_thaw, $_has_threads);

BEGIN {
   $_freeze = \&Storable::freeze;
   $_thaw   = \&Storable::thaw;

   local $@; local $SIG{__DIE__} = \&_NOOP;

   if ($^O eq 'MSWin32' && !defined $threads::VERSION) {
      eval 'use threads; use threads::shared';
   }
   elsif (defined $threads::VERSION) {
      unless (defined $threads::shared::VERSION) {
         eval 'use threads::shared';
      }
   }

   $_has_threads = $INC{'threads/shared.pm'} ? 1 : 0;

   eval 'use IO::FDPass' if !$INC{'IO/FDPass.pm'} && $^O ne 'cygwin';
   eval 'PDL::no_clone_skip_warning()' if $INC{'PDL.pm'};
}

use MCE::Util ();
use MCE::Mutex;

use constant {
   # Do not go higher than 8 on MSWin32 or it will fail.
   DATA_CHANNELS =>  ($^O eq 'MSWin32') ? 8 : 12,

   MAX_DQ_DEPTH  => 192,  # Maximum dequeue notifications
   WA_ARRAY      =>   1,  # Wants list

   SHR_M_NEW => 'M~NEW',  # New share
   SHR_M_CID => 'M~CID',  # ClientID request
   SHR_M_DEE => 'M~DEE',  # Deeply shared
   SHR_M_DNE => 'M~DNE',  # Done sharing
   SHR_M_INC => 'M~INC',  # Increment count
   SHR_M_OBJ => 'M~OBJ',  # Object request
   SHR_M_OB0 => 'M~OB0',  # Object request - thaw'less
   SHR_M_OB1 => 'M~OB1',  # Object request - thaw'less
   SHR_M_OB2 => 'M~OB2',  # Object request - thaw'less
   SHR_M_OB3 => 'M~OB3',  # Object request - thaw'less
   SHR_M_DES => 'M~DES',  # Destroy request
   SHR_M_EXP => 'M~EXP',  # Export request
   SHR_M_INX => 'M~INX',  # Iterator next
   SHR_M_IRW => 'M~IRW',  # Iterator rewind
   SHR_M_SZE => 'M~SZE',  # Size request

   SHR_O_CVB => 'O~CVB',  # Condvar broadcast
   SHR_O_CVS => 'O~CVS',  # Condvar signal
   SHR_O_CVT => 'O~CVT',  # Condvar timedwait
   SHR_O_CVW => 'O~CVW',  # Condvar wait
   SHR_O_CLO => 'O~CLO',  # Handle CLOSE
   SHR_O_OPN => 'O~OPN',  # Handle OPEN
   SHR_O_REA => 'O~REA',  # Handle READ
   SHR_O_RLN => 'O~RLN',  # Handle READLINE
   SHR_O_PRI => 'O~PRI',  # Handle PRINT
   SHR_O_WRI => 'O~WRI',  # Handle WRITE
   SHR_O_QUA => 'O~QUA',  # Queue await
   SHR_O_QUD => 'O~QUD',  # Queue dequeue
   SHR_O_QUN => 'O~QUN',  # Queue dequeue non-blocking
   SHR_O_PDL => 'O~PDL',  # PDL::ins inplace(this),what,coords
   SHR_O_FCH => 'O~FCH',  # A,H,OH,S FETCH
   SHR_O_CLR => 'O~CLR',  # A,H,OH CLEAR
};

###############################################################################
## ----------------------------------------------------------------------------
## Private functions.
##
###############################################################################

my ($_SVR, %_all, %_obj, %_ob2, %_ob3, %_itr, %_new) = (undef);
my ($_next_id, $_is_client, $_init_pid, $_svr_pid) = (0, 1);
my $LF = "\012"; Internals::SvREADONLY($LF, 1);

my $_is_MSWin32 = ($^O eq 'MSWin32') ? 1 : 0;
my $_tid = $_has_threads ? threads->tid() : 0;

sub _croak { goto &Carp::croak }
sub  CLONE { $_tid = threads->tid() }

sub _use_sereal {
   local $@; eval 'use Sereal qw( encode_sereal decode_sereal )';
   $_freeze = \&encode_sereal, $_thaw = \&decode_sereal unless $@;
}

END {
   return unless ($_init_pid && $_init_pid eq "$$.$_tid");
   _stop();
}

{
   my $_handler_cnt : shared = 0;

   sub _trap {
      my $_sig_name = $_[0];
      $MCE::Shared::Server::KILLED = 1;

      $SIG{INT} = $SIG{__DIE__} = $SIG{__WARN__} = $SIG{$_[0]} = sub {};
      lock $_handler_cnt if $_has_threads;

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

         CORE::kill('KILL', -$$, $$)
            if ($_sig_name ne 'PIPE' && $INC{'MCE/Hobo.pm'});
      }

      sleep 0.065 for (1..5);

      CORE::exit($?);
   }
}

sub _new {
   my ($_class, $_deeply, %_hndls) = ($_[0]->{class}, $_[0]->{_DEEPLY_});

   unless ($_svr_pid) {
      # Minimum support for environments without IO::FDPass.
      # Must share Condvar and Queue before others.
      return _share(@_)
         if (!$INC{'IO/FDPass.pm'} && $_class =~
               /^MCE::Shared::(?:Condvar|Queue)$/
         );
      _start();
   }

   if ($_class =~ /^MCE::Shared::(?:Condvar|Queue)$/) {
      if (!$INC{'IO/FDPass.pm'}) {
         _croak(
            "\nSharing a $_class object while the server is running\n" .
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
      # for auto-destroy
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
   print {$_DAT_W_SOCK} SHR_M_INC.$LF . $_chn.$LF;
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

   $_all{ $_id } = $_class; $_ob3{ "$_id:count" } = 1;

   if ($_class eq 'MCE::Shared::Handle') {
      require Symbol unless $INC{'Symbol.pm'};
      $_obj{ $_id } = Symbol::gensym();
      bless $_obj{ $_id }, 'MCE::Shared::Handle';
   }
   else {
      $_obj{ $_id } = $_item;
   }

   my $self = bless [ $_id, $_class ], 'MCE::Shared::Object';
   $_ob2{ $_id } = $_freeze->($self);

   return $self;
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

   _croak("cannot start the shared-manager process: $!")
      unless (defined $_svr_pid);

   return;
}

sub _stop {
   return unless ($_init_pid && $_init_pid eq "$$.$_tid");
   return if ($INC{'MCE/Signal.pm'} && $MCE::Signal::KILLED);
   return if ($MCE::Shared::Server::KILLED);

   %_all = (), %_obj = ();

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

   # safety for circular references to not destroy dangerously
   return if exists $_ob3{ "$_id:count" } && --$_ob3{ "$_id:count" } > 0;

   # safety for circular references to not loop endlessly
   return if exists $_lkup->{ $_id };

   $_lkup->{ $_id } = 1;

   if (exists $_ob3{ "$_id:deeply" }) {
      for my $_oid (keys %{ $_ob3{ "$_id:deeply" } }) {
         _destroy($_lkup, $_obj{ $_oid }, $_oid);
      }
      delete $_ob3{ "$_id:deeply" };
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

   weaken( delete $_obj{ $_id } ) if ( exists $_obj{ $_id } );
   weaken( delete $_itr{ $_id } ) if ( exists $_itr{ $_id } );

   delete($_ob2{ $_id }), delete($_ob3{ "$_id:count" }),
   delete($_all{ $_id }), delete($_itr{ "$_id:args"  });

   return;
}

sub _done {
   %_all = (), %_obj = (), %_ob2 = (), %_ob3 = (), %_itr = ();
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
      if (!defined $^S || $^S) {
         if ( ($INC{'threads.pm'} && threads->tid() != 0) ||
               $ENV{'PERL_IPERL_RUNNING'}
         ) {
            # thread env or running inside IPerl, check stack trace
            my $_t = Carp::longmess(); $_t =~ s/\teval [^\n]+\n$//;
            if ( $_t =~ /^(?:[^\n]+\n){1,7}\teval / ||
                 $_t =~ /\n\teval [^\n]+\n\t(?:eval|Try)/ )
            {
               CORE::die(@_);
            }
         }
         else {
            # normal env, trust $^S
            CORE::die(@_);
         }
      }

      $SIG{INT} = $SIG{__DIE__} = $SIG{__WARN__} = sub {};
      my $_die_msg = (defined $_[0]) ? $_[0] : '';
      print {*STDERR} $_die_msg;

      CORE::kill('INT', $_is_MSWin32 ? -$$ : -getpgrp);
      _done();

      $_is_child ? POSIX::_exit($?) : CORE::exit($?);
   };

   local $\ = undef; local $/ = $LF; $| = 1;

   my ($_id, $_fn, $_wa, $_key, $_len, $_le2, $_le3, $_ret, $_func);
   my ($_DAU_R_SOCK, $_CV, $_Q, $_cnt, $_pending, $_t, $_frozen);
   my ($_client_id, $_done) = (0, 0);

   my $_DAT_R_SOCK = $_SVR->{_dat_r_sock}->[0];
   my $_channels   = $_SVR->{_dat_r_sock};

   my $_warn1 = sub {
      warn "Can't locate object method \"$_[0]\" via package \"$_[1]\"\n";
      if ( $_wa ) {
         my $_buf = $_freeze->([ ]);
         print {$_DAU_R_SOCK} length($_buf).'1'.$LF, $_buf;
      }
   };

   my $_warn2 = sub {
      warn "Can't locate object method \"$_[0]\" via package \"$_[1]\"\n";
   };

   my $_fetch = sub {
      if ( ref($_[0]) ) {
         my $_buf = ( blessed($_[0]) && $_[0]->can('SHARED_ID') )
            ? $_ob2{ $_[0]->[0] } || $_freeze->($_[0])
            : $_freeze->($_[0]);
         print {$_DAU_R_SOCK} length($_buf).'1'.$LF, $_buf;
      }
      elsif ( defined $_[0] ) {
         print {$_DAU_R_SOCK} length($_[0]).'0'.$LF, $_[0];
      }
      else {
         print {$_DAU_R_SOCK} '-1'.$LF;
      }

      return;
   };

   my $_iterator = sub {
      if (!exists $_itr{ $_id }) {

         # MCE::Shared::{ Array, Hash, Ordhash }, Hash::Ordered
         if (
            $_all{ $_id } =~ /^MCE::Shared::(?:Array|Hash|Ordhash)$/ ||
            $_all{ $_id } eq 'Hash::Ordered'
         ) {
            my @_keys = ( exists $_itr{ "$_id:args" } )
               ? $_obj{ $_id }->keys( @{ $_itr{ "$_id:args" } } )
               : $_obj{ $_id }->keys;

            $_itr{ $_id } = sub {
               my $_key = shift @_keys;
               if ( !defined $_key ) {
                  print {$_DAU_R_SOCK} '-1'.$LF;
                  return;
               }
               my $_buf = $_freeze->([ $_key, $_obj{ $_id }->get($_key) ]);
               print {$_DAU_R_SOCK} length($_buf).$LF, $_buf;
            };
         }

         # MCE::Shared::{ Minidb }
         elsif ( $_all{ $_id } eq 'MCE::Shared::Minidb' ) {
            @{ $_itr{ "$_id:args" } } = () unless exists($_itr{ "$_id:args" });

            my @_a = @{ $_itr{ "$_id:args" } };
            my $_data; my $_ta = 0;

            if ( $_a[0] =~ /^:lists$/i ) {
               $_data = $_obj{ $_id }->[1][0];
               shift @_a;
               if ( ! @_a ) {
                  @_a = $_obj{ $_id }->lkeys();
               }
               elsif ( @_a == 1 && $_a[0] =~ /^(?:key|\S+)[ ]+\S\S?[ ]+\S/ ) {
                  @_a = $_obj{ $_id }->lkeys(@_a);
               }
               elsif ( @_a == 2 && $_a[1] =~ /^(?:key|val)[ ]+\S\S?[ ]+\S/ ) {
                  $_data = $_obj{ $_id }->[1][0]->{ $_a[0] };
                  $_ta = 1, @_a = $_obj{ $_id }->lkeys(@_a);
               }
            }
            else {
               $_data = $_obj{ $_id }->[0][0];
               shift @_a if ( $_a[0] =~ /^:hashes$/i );
               if ( ! @_a ) {
                  @_a = $_obj{ $_id }->hkeys();
               }
               elsif ( @_a == 1 && $_a[0] =~ /^(?:key|\S+)[ ]+\S\S?[ ]+\S/ ) {
                  @_a = $_obj{ $_id }->hkeys(@_a);
               }
               elsif ( @_a == 2 && $_a[1] =~ /^(?:key|val)[ ]+\S\S?[ ]+\S/ ) {
                  $_data = $_obj{ $_id }->[0][0]->{ $_a[0] };
                  @_a = $_obj{ $_id }->hkeys(@_a);
               }
            }

            $_itr{ $_id } = sub {
               my $_key = shift @_a;
               if ( !defined $_key ) {
                  print {$_DAU_R_SOCK} '-1'.$LF;
                  return;
               }
               my $_buf = $_freeze->([
                  $_key, $_ta ? $_data->[ $_key ] : $_data->{ $_key }
               ]);
               print {$_DAU_R_SOCK} length($_buf).$LF, $_buf;
            };
         }

         # Not supported
         else {
            print {$_DAU_R_SOCK} '-1'.$LF;
            return;
         }
      }

      $_itr{ $_id }->();

      return;
   };

   # --------------------------------------------------------------------------

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

      SHR_M_CID.$LF => sub {                      # ClientID request
         print {$_DAU_R_SOCK} (++$_client_id).$LF;
         $_client_id = 0 if ($_client_id > 2e6);

         return;
      },

      SHR_M_DEE.$LF => sub {                      # Deeply shared
         chomp(my $_id1 = <$_DAU_R_SOCK>),
         chomp(my $_id2 = <$_DAU_R_SOCK>);

         $_ob3{ "$_id1:deeply" }->{ $_id2 } = 1;

         return;
      },

      SHR_M_DNE.$LF => sub {                      # Done sharing
         _done(); $_done = 1;

         return;
      },

      SHR_M_INC.$LF => sub {                      # Increment count
         chomp($_id = <$_DAU_R_SOCK>);

         $_ob3{ "$_id:count" }++;
         print {$_DAU_R_SOCK} $LF;

         return;
      },

      SHR_M_OBJ.$LF => sub {                      # Object request
         my $_buf;

         chomp($_id  = <$_DAU_R_SOCK>),
         chomp($_fn  = <$_DAU_R_SOCK>),
         chomp($_wa  = <$_DAU_R_SOCK>),
         chomp($_len = <$_DAU_R_SOCK>);

         read($_DAU_R_SOCK, $_buf, $_len);

         my $_var  = $_obj{ $_id };
         my $_code = $_var->can($_fn);

         return $_warn1->($_fn, blessed($_obj{ $_id })) unless $_code;

         if ( $_wa == WA_ARRAY ) {
            my @_ret = $_code->($_var, @{ $_thaw->($_buf) });
            my $_buf = $_freeze->(\@_ret);
            print {$_DAU_R_SOCK} length($_buf).'1'.$LF, $_buf;
         }
         elsif ( $_wa ) {
            my $_ret = $_code->($_var, @{ $_thaw->($_buf) });
            if ( !ref($_ret) && defined $_ret ) {
               print {$_DAU_R_SOCK} length($_ret).'0'.$LF, $_ret;
            } else {
               my $_buf = $_freeze->([ $_ret ]);
               print {$_DAU_R_SOCK} length($_buf).'1'.$LF, $_buf;
            }
         }
         else {
            $_code->($_var, @{ $_thaw->($_buf) });
         }

         return;
      },

      SHR_M_OB0.$LF => sub {                      # Object request - thaw'less
         chomp($_id = <$_DAU_R_SOCK>),
         chomp($_fn = <$_DAU_R_SOCK>),
         chomp($_wa = <$_DAU_R_SOCK>);

         my $_var  = $_obj{ $_id };
         my $_code = $_var->can($_fn);

         return $_warn1->($_fn, blessed($_obj{ $_id })) unless $_code;

         if ( $_wa == WA_ARRAY ) {
            my @_ret = $_code->($_var);
            my $_buf = $_freeze->(\@_ret);
            print {$_DAU_R_SOCK} length($_buf).'1'.$LF, $_buf;
         }
         elsif ( $_wa ) {
            my $_ret = $_code->($_var);
            if ( !ref($_ret) && defined $_ret ) {
               print {$_DAU_R_SOCK} length($_ret).'0'.$LF, $_ret;
            } else {
               my $_buf = $_freeze->([ $_ret ]);
               print {$_DAU_R_SOCK} length($_buf).'1'.$LF, $_buf;
            }
         }
         else {
            $_code->($_var);
         }

         return;
      },

      SHR_M_OB1.$LF => sub {                      # Object request - thaw'less
         my $_arg1;

         chomp($_id  = <$_DAU_R_SOCK>),
         chomp($_fn  = <$_DAU_R_SOCK>),
         chomp($_wa  = <$_DAU_R_SOCK>),
         chomp($_len = <$_DAU_R_SOCK>);

         read($_DAU_R_SOCK, $_arg1, $_len);

         my $_var  = $_obj{ $_id };
         my $_code = $_var->can($_fn);

         return $_warn1->($_fn, blessed($_obj{ $_id })) unless $_code;

         if ( $_wa == WA_ARRAY ) {
            my @_ret = $_code->($_var, $_arg1);
            my $_buf = $_freeze->(\@_ret);
            print {$_DAU_R_SOCK} length($_buf).'1'.$LF, $_buf;
         }
         elsif ( $_wa ) {
            my $_ret = $_code->($_var, $_arg1);
            if ( !ref($_ret) && defined $_ret ) {
               print {$_DAU_R_SOCK} length($_ret).'0'.$LF, $_ret;
            } else {
               my $_buf = $_freeze->([ $_ret ]);
               print {$_DAU_R_SOCK} length($_buf).'1'.$LF, $_buf;
            }
         }
         else {
            $_code->($_var, $_arg1);
         }

         return;
      },

      SHR_M_OB2.$LF => sub {                      # Object request - thaw'less
         my ($_arg1, $_arg2);

         chomp($_id  = <$_DAU_R_SOCK>),
         chomp($_fn  = <$_DAU_R_SOCK>),
         chomp($_wa  = <$_DAU_R_SOCK>),
         chomp($_len = <$_DAU_R_SOCK>),
         chomp($_le2 = <$_DAU_R_SOCK>);

         read($_DAU_R_SOCK, $_arg1, $_len),
         read($_DAU_R_SOCK, $_arg2, $_le2);

         my $_var  = $_obj{ $_id };
         my $_code = $_var->can($_fn);

         return $_warn1->($_fn, blessed($_obj{ $_id })) unless $_code;

         if ( $_wa == WA_ARRAY ) {
            my @_ret = $_code->($_var, $_arg1, $_arg2);
            my $_buf = $_freeze->(\@_ret);
            print {$_DAU_R_SOCK} length($_buf).'1'.$LF, $_buf;
         }
         elsif ( $_wa ) {
            my $_ret = $_code->($_var, $_arg1, $_arg2);
            if ( !ref($_ret) && defined $_ret ) {
               print {$_DAU_R_SOCK} length($_ret).'0'.$LF, $_ret;
            } else {
               my $_buf = $_freeze->([ $_ret ]);
               print {$_DAU_R_SOCK} length($_buf).'1'.$LF, $_buf;
            }
         }
         else {
            $_code->($_var, $_arg1, $_arg2);
         }

         return;
      },

      SHR_M_OB3.$LF => sub {                      # Object request - thaw'less
         my ($_arg1, $_arg2, $_arg3);

         chomp($_id  = <$_DAU_R_SOCK>),
         chomp($_fn  = <$_DAU_R_SOCK>),
         chomp($_wa  = <$_DAU_R_SOCK>),
         chomp($_len = <$_DAU_R_SOCK>),
         chomp($_le2 = <$_DAU_R_SOCK>),
         chomp($_le3 = <$_DAU_R_SOCK>);

         read($_DAU_R_SOCK, $_arg1, $_len),
         read($_DAU_R_SOCK, $_arg2, $_le2),
         read($_DAU_R_SOCK, $_arg3, $_le3);

         my $_var  = $_obj{ $_id };
         my $_code = $_var->can($_fn);

         return $_warn1->($_fn, blessed($_obj{ $_id })) unless $_code;

         if ( $_wa == WA_ARRAY ) {
            my @_ret = $_code->($_var, $_arg1, $_arg2, $_arg3);
            my $_buf = $_freeze->(\@_ret);
            print {$_DAU_R_SOCK} length($_buf).'1'.$LF, $_buf;
         }
         elsif ( $_wa ) {
            my $_ret = $_code->($_var, $_arg1, $_arg2, $_arg3);
            if ( !ref($_ret) && defined $_ret ) {
               print {$_DAU_R_SOCK} length($_ret).'0'.$LF, $_ret;
            } else {
               my $_buf = $_freeze->([ $_ret ]);
               print {$_DAU_R_SOCK} length($_buf).'1'.$LF, $_buf;
            }
         }
         else {
            $_code->($_var, $_arg1, $_arg2, $_arg3);
         }

         return;
      },

      SHR_M_DES.$LF => sub {                      # Destroy request
         chomp($_id = <$_DAU_R_SOCK>);

         $_ret = (exists $_all{ $_id }) ? '1' : '0';
         _destroy({}, $_obj{ $_id }, $_id) if $_ret;

         return;
      },

      SHR_M_EXP.$LF => sub {                      # Export request
         chomp($_id  = <$_DAU_R_SOCK>),
         chomp($_len = <$_DAU_R_SOCK>);

         read($_DAU_R_SOCK, my($_keys), $_len) if $_len;

         if (exists $_obj{ $_id }) {
            my $_buf;

            # MCE::Shared::{ Array, Hash, Ordhash }, Hash::Ordered
            if (
               $_all{ $_id } =~ /^MCE::Shared::(?:Array|Hash|Ordhash)$/ ||
               $_all{ $_id } eq 'Hash::Ordered'
            ) {
               $_buf = ($_len)
                  ? $_freeze->($_obj{ $_id }->clone(@{ $_thaw->($_keys) }))
                  : $_freeze->($_obj{ $_id });
            }

            # MCE::Shared::{ Condvar, Queue }
            elsif ( $_all{ $_id } =~ /^MCE::Shared::(?:Condvar|Queue)$/ ) {
               my %_ret = %{ $_obj{ $_id } }; bless \%_ret, $_all{ $_id };
               delete @_ret{ qw(
                  _qw_sock _qr_sock _aw_sock _ar_sock
                  _cw_sock _cr_sock _mutex
               ) };
               $_buf = $_freeze->(\%_ret);
            }

            # Other
            else {
               $_buf = $_freeze->($_obj{ $_id });
            }

            print {$_DAU_R_SOCK} length($_buf).$LF, $_buf;
            undef $_buf;
         }
         else {
            print {$_DAU_R_SOCK} '-1'.$LF;
         }

         return;
      },

      SHR_M_INX.$LF => sub {                      # Iterator next
         chomp($_id = <$_DAU_R_SOCK>);

         my $_var = $_obj{ $_id };

         if ( my $_code = $_var->can('next') ) {
            my $_buf = $_freeze->([ $_code->( $_var ) ]);
            print {$_DAU_R_SOCK} length($_buf).$LF, $_buf;
         }
         else {
            $_iterator->();
         }

         return;
      },

      SHR_M_IRW.$LF => sub {                      # Iterator rewind
         chomp($_id  = <$_DAU_R_SOCK>),
         chomp($_len = <$_DAU_R_SOCK>);

         read $_DAU_R_SOCK, my($_buf), $_len;

         my $_var  = $_obj{ $_id };
         my @_args = @{ $_thaw->($_buf) };

         if (my $_code = $_var->can('rewind')) {
            $_code->( $_var, @_args );
         }
         else {
            weaken( delete $_itr{ $_id } ) if ( exists $_itr{ $_id } );
            if ( @_args ) {
               $_itr{ "$_id:args" } = \@_args;
            } else {
               delete $_itr{ "$_id:args" };
            }
         }

         print {$_DAU_R_SOCK} $LF;

         return;
      },

      SHR_M_SZE.$LF => sub {                      # Size request
         chomp($_id = <$_DAU_R_SOCK>),
         chomp($_fn = <$_DAU_R_SOCK>);

         my $_var = $_obj{ $_id };

         if ( my $_code = $_var->can($_fn) ) {
            $_ret = $_code->($_var) || 0;
            print {$_DAU_R_SOCK} $_ret.$LF;
         }
         else {
            $_warn2->($_fn, blessed($_obj{ $_id }));
            print {$_DAU_R_SOCK} $LF;
         }

         return;
      },

      # -----------------------------------------------------------------------

      SHR_O_CVB.$LF => sub {                      # Condvar broadcast
         chomp($_id = <$_DAU_R_SOCK>);

         $_CV = $_obj{ $_id };
         my $_hndl = $_CV->{_cw_sock};

         for (1 .. $_CV->{_count}) { 1 until syswrite $_hndl, $LF }
         $_CV->{_count} = 0;

         print {$_DAU_R_SOCK} $LF;

         return;
      },

      SHR_O_CVS.$LF => sub {                      # Condvar signal
         chomp($_id = <$_DAU_R_SOCK>);

         $_CV = $_obj{ $_id };

         if ( $_CV->{_count} >= 0 ) {
            1 until syswrite $_CV->{_cw_sock}, $LF;
            $_CV->{_count} -= 1;
         }

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

      SHR_O_CLO.$LF => sub {                      # Handle CLOSE
         chomp($_id = <$_DAU_R_SOCK>);

         close $_obj{ $_id } if defined fileno($_obj{ $_id });

         return;
      },

      SHR_O_OPN.$LF => sub {                      # Handle OPEN
         my ($_fd, $_buf); local $!;

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

         my $_fh = $_obj{ $_id };

         $_ret = read($_fh, $_buf, $_a3) unless eof($_fh);
         print {$_DAU_R_SOCK} $_ret.$LF . length($_buf).$LF, $_buf;

         return;
      },

      SHR_O_RLN.$LF => sub {                      # Handle READLINE
         chomp($_id  = <$_DAU_R_SOCK>),
         chomp($_len = <$_DAU_R_SOCK>);

         local $/; read($_DAU_R_SOCK, $/, $_len) if ($_len);
         my ($_fh, $_buf) = ($_obj{ $_id }); local $!;

         # support special case; e.g. $/ = "\n>" for bioinformatics
         # anchoring ">" at the start of line

         if (!eof($_fh)) {
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

      SHR_O_QUA.$LF => sub {                      # Queue await
         chomp($_id = <$_DAU_R_SOCK>),
         chomp($_t  = <$_DAU_R_SOCK>);

         $_Q = $_obj{ $_id };
         $_Q->{_tsem} = $_t;

         if ($_Q->pending() <= $_t) {
            1 until syswrite $_Q->{_aw_sock}, $LF;
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
            # The 'fast' option may reduce wait time, thus run faster
            if ($_Q->{_dsem} <= 1) {
               $_pending = $_Q->pending();
               $_pending = int($_pending / $_cnt) if ($_cnt);
               if ($_pending) {
                  $_pending = MAX_DQ_DEPTH if ($_pending > MAX_DQ_DEPTH);
                  for (1 .. $_pending) { 1 until syswrite $_Q->{_qw_sock}, $LF }
               }
               $_Q->{_dsem} = $_pending;
            }
            else {
               $_Q->{_dsem} -= 1;
            }
         }
         else {
            # Otherwise, never to exceed one byte in the channel
            if ($_Q->_has_data()) { 1 until syswrite $_Q->{_qw_sock}, $LF }
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
            for (1 .. $_Q->{_asem}) { 1 until syswrite $_Q->{_aw_sock}, $LF }
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
            for (1 .. $_Q->{_asem}) { 1 until syswrite $_Q->{_aw_sock}, $LF }
            $_Q->{_asem} = 0;
         }

         $_Q->{_nb_flag} = 1;

         return;
      },

      SHR_O_PDL.$LF => sub {                      # PDL::ins inplace(this),...
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

      SHR_O_FCH.$LF => sub {                      # A,H,OH,S FETCH
         chomp($_id  = <$_DAU_R_SOCK>),
         chomp($_fn  = <$_DAU_R_SOCK>),
         chomp($_len = <$_DAU_R_SOCK>);

         read($_DAU_R_SOCK, $_key, $_len) if $_len;

         my $_var = $_obj{ $_id };

         if ( my $_code = $_var->can($_fn) ) {
            $_len ? $_fetch->($_code->($_var, $_key))
                  : $_fetch->($_code->($_var));
         }
         else {
            $_warn2->($_fn, blessed($_obj{ $_id }));
            print {$_DAU_R_SOCK} '-1'.$LF;
         }

         return;
      },

      SHR_O_CLR.$LF => sub {                      # A,H,OH CLEAR
         chomp($_id = <$_DAU_R_SOCK>),
         chomp($_fn = <$_DAU_R_SOCK>);

         my $_var = $_obj{ $_id };

         if ( my $_code = $_var->can($_fn) ) {
            if (exists $_ob3{ "$_id:deeply" }) {
               my $_keep = { $_id => 1 };
               for my $_oid (keys %{ $_ob3{ "$_id:deeply" } }) {
                  _destroy($_keep, $_obj{ $_oid }, $_oid);
               }
               delete $_ob3{ "$_id:deeply" };
            }
            $_code->($_var);
         }
         else {
            $_warn2->($_fn, blessed($_obj{ $_id }));
         }

         print {$_DAU_R_SOCK} $LF;

         return;
      },

   );

   # --------------------------------------------------------------------------

   # Call on hash function; exit loop when finished.

   if ($_is_MSWin32) {
      # The normal loop hangs on Windows when processes/threads start/exit.
      # Using ioctl() properly, http://www.perlmonks.org/?node_id=780083

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

   # Wait for the main thread to exit to not impact socket handles.
   # Exiting via POSIX's _exit to avoid END blocks.

   sleep(3.0)      if $_is_MSWin32;
   POSIX::_exit(0) if $_is_child;

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Object package.
##
###############################################################################

package MCE::Shared::Object;

use 5.010001;
use strict;
use warnings;

no warnings qw( threads recursion uninitialized numeric once );

use Time::HiRes qw( sleep );
use Scalar::Util qw( looks_like_number );
use MCE::Shared::Base;
use bytes;

use constant {
   _UNDEF => 0, _ARRAY => 1, _SCALAR => 2,  # wantarray
   _CLASS => 1, _DREF  => 2, _ITER   => 3,  # shared object
};

my %_hash_support = (qw/
   MCE::Shared::Hash     1
   MCE::Shared::Ordhash  1
   Hash::Ordered         1
/);

use overload (
   q("")    => \&MCE::Shared::Base::_stringify,
   q(0+)    => \&MCE::Shared::Base::_numify,
   q(@{})   => sub {
      no overloading;
      $_[0]->[_DREF] || do {
         return $_[0] if $_[0]->[_CLASS] ne 'MCE::Shared::Array';
         tie my @a, __PACKAGE__, bless([ $_[0]->[0] ], __PACKAGE__);
         $_[0]->[_DREF] = \@a;
      };
   },
   q(%{})   => sub {
      $_[0]->[_DREF] || do {
         return $_[0] if !exists $_hash_support{ $_[0]->[_CLASS] };
         tie my %h, __PACKAGE__, bless([ $_[0]->[0] ], __PACKAGE__);
         $_[0]->[_DREF] = \%h;
      };
   },
   q(${})   => sub {
      $_[0]->[_DREF] || do {
         return $_[0] if $_[0]->[_CLASS] ne 'MCE::Shared::Scalar';
         tie my $s, __PACKAGE__, bless([ $_[0]->[0] ], __PACKAGE__);
         $_[0]->[_DREF] = \$s;
      };
   },
   fallback => 1
);

no overloading;

my ($_DAT_LOCK, $_DAT_W_SOCK, $_DAU_W_SOCK, $_chn);
my ($_dat_ex, $_dat_un);

my $_blessed = \&Scalar::Util::blessed;
my $_ready   = \&MCE::Util::_sock_ready;

# Hook for non-MCE worker threads.

sub CLONE {
   %_new = ();
   &_init(threads->tid()) if $INC{'threads.pm'} && !$INC{'MCE.pm'};
}

# Private functions.

sub DESTROY {
   if ($_is_client && defined $_svr_pid && defined $_[0]) {
      my $_id = $_[0]->[0];

      if (exists $_new{ $_id }) {
         my $_pid = $_has_threads ? $$ .'.'. $_tid : $$;

         if ($_new{ $_id } eq $_pid) {
            return if ($INC{'MCE/Signal.pm'} && $MCE::Signal::KILLED);
            return if ($MCE::Shared::Server::KILLED);

            delete($_new{ $_id }), _req2('M~DES', $_id.$LF, '');
         }
      }
   }

   return;
}

sub _croak {
   goto &MCE::Shared::Base::_croak;
}
sub SHARED_ID { $_[0]->[0] }

sub TIEARRAY  { $_[1] }
sub TIEHANDLE { $_[1] }
sub TIEHASH   { $_[1] }
sub TIESCALAR { $_[1] }

sub _server_init {
   $_chn        = 1;
   $_DAT_LOCK   = $_SVR->{'_mutex_'.$_chn};
   $_DAT_W_SOCK = $_SVR->{_dat_w_sock}->[0];
   $_DAU_W_SOCK = $_SVR->{_dat_w_sock}->[$_chn];

   $_dat_ex = sub { 1 until sysread(  $_DAT_LOCK->{_r_sock}, my $_b, 1 ) };
   $_dat_un = sub { 1 until syswrite( $_DAT_LOCK->{_w_sock}, '0' ) };

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

   %_new = ();

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Private routines.
##
###############################################################################

# Called by AUTOLOAD, enqueue, enqueuep, STORE, set, decr, incr, and len.

sub _auto {
   my ( $_fn, $_id, $_wa, $_len, $_buf ) = ( shift, shift()->[0] );

   $_wa  = !defined wantarray ? _UNDEF : wantarray ? _ARRAY : _SCALAR;
   $_len = @_;

   local $\ = undef if (defined $\);

   if ( $_len == 0 ) {
      $_buf = $_id.$LF . $_fn.$LF . $_wa.$LF;

      $_dat_ex->();  print {$_DAT_W_SOCK} 'M~OB0'.$LF . $_chn.$LF;
                     print {$_DAU_W_SOCK} $_buf;
   }
   elsif ( $_len == 1 && !ref($_[0]) && defined($_[0]) ) {
      $_buf = $_id.$LF . $_fn.$LF . $_wa.$LF . length($_[0]).$LF;

      $_dat_ex->();  print {$_DAT_W_SOCK} 'M~OB1'.$LF . $_chn.$LF;
                     print {$_DAU_W_SOCK} $_buf, $_[0];
   }
   elsif ( $_len == 2 && !ref($_[1]) && defined($_[1]) ) {
      $_buf = $_id.$LF . $_fn.$LF . $_wa.$LF . length($_[0]).$LF .
            length($_[1]).$LF . $_[0];

      $_dat_ex->();  print {$_DAT_W_SOCK} 'M~OB2'.$LF . $_chn.$LF;
                     print {$_DAU_W_SOCK} $_buf, $_[1];
   }
   elsif ( $_len == 3 && !ref($_[2]) && defined($_[2]) ) {
      $_buf = $_id.$LF . $_fn.$LF . $_wa.$LF . length($_[0]).$LF .
            length($_[1]).$LF . length($_[2]).$LF . $_[0] . $_[1];

      $_dat_ex->();  print {$_DAT_W_SOCK} 'M~OB3'.$LF . $_chn.$LF;
                     print {$_DAU_W_SOCK} $_buf, $_[2];
   }
   else {
      my $_tmp = $_freeze->([ @_ ]);
         $_buf = $_id.$LF . $_fn.$LF . $_wa.$LF . length($_tmp).$LF;

      $_dat_ex->();  print {$_DAT_W_SOCK} 'M~OBJ'.$LF . $_chn.$LF;
                     print {$_DAU_W_SOCK} $_buf, $_tmp;
   }

   if ( $_wa ) {
      local $/ = $LF if (!$/ || $/ ne $LF);
      chomp($_len = <$_DAU_W_SOCK>);

      my $_frozen = chop($_len);
      read $_DAU_W_SOCK, $_buf, $_len;
      $_dat_un->();

      ( $_wa != _ARRAY )
         ? $_frozen ? $_thaw->($_buf)[0] : $_buf
         : @{ $_thaw->($_buf) };
   }
   else {
      $_dat_un->();
   }
}

# Called by broadcast, signal, timedwait, and rewind.

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

# Called by DESTROY, STORE, CLOSE, PRINT, PRINTF, timedwait, wait, await,
# ins_inplace, and destroy.

sub _req2 {
   local $\ = undef if (defined $\);

   $_dat_ex->();
   print {$_DAT_W_SOCK} $_[0].$LF . $_chn.$LF;
   print {$_DAU_W_SOCK} $_[1], $_[2];
   $_dat_un->();

   1;
}

# Called by export.

sub _req3 {
   local $\ = undef if (defined $\);
   local $/ = $LF if (!$/ || $/ ne $LF);

   $_dat_ex->();
   print {$_DAT_W_SOCK} $_[0].$LF . $_chn.$LF;
   print {$_DAU_W_SOCK} $_[1], $_[2];

   chomp(my $_len = <$_DAU_W_SOCK>);

   if ($_len < 0) { $_dat_un->(); return undef; }
   read $_DAU_W_SOCK, my($_buf), $_len;
   $_dat_un->();

   $_thaw->($_buf);
}

# Called by dequeue and dequeue_nb.

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

# Called by FETCHSIZE, SCALAR, and pending.

sub _req5 {
   local $\ = undef if (defined $\);
   local $/ = $LF if (!$/ || $/ ne $LF);

   $_dat_ex->();
   print {$_DAT_W_SOCK} 'M~SZE'.$LF . $_chn.$LF;
   print {$_DAU_W_SOCK} $_[1]->[0].$LF . $_[0].$LF;

   chomp(my $_ret = <$_DAU_W_SOCK>);
   $_dat_un->();

   $_ret;
}

# Called by FETCH and get.

sub _req6 {
   local $\ = undef if (defined $\);
   local $/ = $LF if (!$/ || $/ ne $LF);

   $_dat_ex->();
   print {$_DAT_W_SOCK} 'O~FCH'.$LF . $_chn.$LF;
   print {$_DAU_W_SOCK} $_[1]->[0].$LF . $_[0].$LF . length($_[2]).$LF, $_[2];

   chomp(my $_len = <$_DAU_W_SOCK>);

   if ($_len < 0) { $_dat_un->(); return undef; }

   my $_frozen = chop($_len);
   read $_DAU_W_SOCK, my($_buf), $_len;
   $_dat_un->();

   $_frozen ? $_thaw->($_buf) : $_buf;
}

# Called by CLEAR and clear.

sub _req7 {
   my ( $_fn, $self ) = @_;
   local $\ = undef if (defined $\);
   local $/ = $LF if (!$/ || $/ ne $LF);

   delete $self->[_ITER] if defined $self->[_ITER];

   $_dat_ex->();
   print {$_DAT_W_SOCK} 'O~CLR'.$LF . $_chn.$LF;
   print {$_DAU_W_SOCK} $self->[0].$LF . $_fn.$LF;

   <$_DAU_W_SOCK>;
   $_dat_un->();

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Common methods.
##
###############################################################################

# Autoload handler. $MCE::Shared::Object::AUTOLOAD equals:
# MCE::Shared::Object::<method_name>

sub AUTOLOAD {
   _auto(substr($MCE::Shared::Object::AUTOLOAD, 21), @_);
}

# blessed ( )

sub blessed {
   $_[0]->[_CLASS];
}

# destroy ( )

sub destroy {
   my $_id   = $_[0]->[0];
   my $_item = (defined wantarray) ? $_[0]->export() : undef;
   my $_pid  = $_has_threads ? $$ .'.'. $_tid : $$;

   delete($_all{ $_id }), delete($_obj{ $_id });

   if (defined $_svr_pid && exists $_new{ $_id } && $_new{ $_id } eq $_pid) {
      delete($_new{ $_id }), _req2('M~DES', $_id.$LF, '');
   }

   $_[0] = undef;
   $_item;
}

# export ( key [, key, ... ] )
# export ( )

sub export {
   my $_id   = shift()->[0];
   my $_lkup = ref($_[0]) eq 'HASH' ? shift : {};

   # safety for circular references to not loop endlessly
   return $_lkup->{ $_id } if exists $_lkup->{ $_id };

   my $_tmp   = @_ ? $_freeze->([ @_ ]) : '';
   my $_buf   = $_id.$LF . length($_tmp).$LF;
   my $_item  = $_lkup->{ $_id } = _req3('M~EXP', $_buf, $_tmp);
   my $_class = $_blessed->($_item);

   # MCE::Shared::{ Array, Hash, Ordhash }, Hash::Ordered
   if (
      $_class =~ /^MCE::Shared::(?:Array|Hash|Ordhash)$/ ||
      $_class eq 'Hash::Ordered'
   ) {
      require MCE::Shared::Array   if $_class eq 'MCE::Shared::Array';
      require MCE::Shared::Hash    if $_class eq 'MCE::Shared::Hash';
      require MCE::Shared::Ordhash if $_class eq 'MCE::Shared::Ordhash';
      require Hash::Ordered        if $_class eq 'Hash::Ordered';

      for my $k ($_item->keys) {
         if ($_blessed->($_item->get($k)) && $_item->get($k)->can('export')) {
            $_item->set($k, $_item->get($k)->export($_lkup));
         }
      }
   }

   # MCE::Shared::{ Scalar }
   elsif ( $_class eq 'MCE::Shared::Scalar' ) {
      require MCE::Shared::Scalar;

      if ($_blessed->($_item->get()) && $_item->get()->can('export')) {
         $_item->set($_item->get()->export($_lkup));
      }
   }

   $_item;
}

# iterator ( ":hashes", key, "query string" )  # Minidb HoH
# iterator ( ":hashes", key [, key, ... ] )
# iterator ( ":hashes", "query string" )
# iterator ( ":hashes" )
#
# iterator ( ":lists", key, "query string" )   # Minidb HoA
# iterator ( ":lists", key [, key, ... ] )
# iterator ( ":lists", "query string" )
# iterator ( ":lists" )
#
# iterator ( index, [, index, ... ] )          # Array/Hash/Ordhash
# iterator ( key, [, key, ... ] )
# iterator ( "query string" )
# iterator ( )

sub iterator {
   my ( $self, @keys ) = @_;
   my $ref = $self->blessed();

   # MCE::Shared::{ Array, Hash, Ordhash }, Hash::Ordered
   if (
      $ref =~ /^MCE::Shared::(?:Array|Hash|Ordhash)$/ ||
      $ref eq 'Hash::Ordered'
   ) {
      if ( ! @keys ) {
         @keys = $self->keys;
      }
      elsif ( @keys == 1 && $keys[0] =~ /^(?:key|val)[ ]+\S\S?[ ]+\S/ ) {
         @keys = $self->keys($keys[0]);
      }
      return sub {
         return unless @keys;
         my $key = shift @keys;
         return ( $key => $self->get($key) );
      };
   }

   # MCE::Shared::{ Minidb }
   elsif ( $ref eq 'MCE::Shared::Minidb' ) {
      if ( $keys[0] =~ /^:lists$/i ) {
         shift @keys;
         if ( ! @keys ) {
            @keys = $self->lkeys;
         }
         elsif ( @keys == 1 && $keys[0] =~ /^(?:key|\S+)[ ]+\S\S?[ ]+\S/ ) {
            @keys = $self->lkeys(@keys);
         }
         elsif ( @keys == 2 && $keys[1] =~ /^(?:key|val)[ ]+\S\S?[ ]+\S/ ) {
            my $key = $keys[0];  @keys = $self->lkeys(@keys);
            return sub {
               return unless @keys;
               my $field = shift(@keys);
               return ( $field => $self->lget($key, $field) );
            };
         }
         return sub {
            return unless @keys;
            my $key = shift(@keys);
            return ( $key => $self->lget($key) );
         };
      }
      else {
         shift @keys if ( $keys[0] =~ /^:hashes$/i );
         if ( ! @keys ) {
            @keys = $self->hkeys;
         }
         elsif ( @keys == 1 && $keys[0] =~ /^(?:key|\S+)[ ]+\S\S?[ ]+\S/ ) {
            @keys = $self->hkeys(@keys);
         }
         elsif ( @keys == 2 && $keys[1] =~ /^(?:key|val)[ ]+\S\S?[ ]+\S/ ) {
            my $key = $keys[0];  @keys = $self->hkeys(@keys);
            return sub {
               return unless @keys;
               my $field = shift(@keys);
               return ( $field => $self->hget($key, $field) );
            };
         }
         return sub {
            return unless @keys;
            my $key = shift(@keys);
            return ( $key => $self->hget($key) );
         };
      }
   }

   # Not supported
   else {
      return sub {};
   }
}

# rewind ( begin, end, [ step, format ] )      # Sequence
#
# rewind ( ":hashes", key, "query string" )    # Minidb HoH
# rewind ( ":hashes", key [, key, ... ] )
# rewind ( ":hashes", "query string" )
# rewind ( ":hashes" )
#
# rewind ( ":lists", key, "query string" )     # Minidb HoA
# rewind ( ":lists", key [, key, ... ] )
# rewind ( ":lists", "query string" )
# rewind ( ":lists" )
#
# rewind ( index [, index, ... ] )             # Array/(Ord)Hash
# rewind ( key [, key, ... ] )
# rewind ( "query string" )
# rewind ( )

sub rewind {
   my $_id  = shift()->[0];
   my $_buf = $_freeze->([ @_ ]);
   _req1('M~IRW', $_id.$LF . length($_buf).$LF . $_buf);

   return;
}

# next ( )

sub next {
   local $\ = undef if (defined $\);
   local $/ = $LF if (!$/ || $/ ne $LF);

   $_dat_ex->();
   print {$_DAT_W_SOCK} 'M~INX'.$LF . $_chn.$LF;
   print {$_DAU_W_SOCK} $_[0]->[0].$LF;

   chomp(my $_len = <$_DAU_W_SOCK>);

   if ($_len < 0) { $_dat_un->(); return; }
   read $_DAU_W_SOCK, my($_buf), $_len;
   $_dat_un->();

   wantarray ? @{ $_thaw->($_buf) } : $_thaw->($_buf)[-1];
}

###############################################################################
## ----------------------------------------------------------------------------
## Methods optimized for Condvar.
##
###############################################################################

# lock ( )

sub lock {
   return unless ( my $_CV = $_obj{ $_[0]->[0] } );
   return unless ( exists $_CV->{_cr_sock} );

   $_CV->{_mutex}->lock;
}

# unlock ( )

sub unlock {
   return unless ( my $_CV = $_obj{ $_[0]->[0] } );
   return unless ( exists $_CV->{_cr_sock} );

   $_CV->{_mutex}->unlock;
}

# broadcast ( floating_seconds )
# broadcast ( )

sub broadcast {
   my $_id = $_[0]->[0];
   return unless ( my $_CV = $_obj{ $_id } );
   return unless ( exists $_CV->{_cr_sock} );

   sleep($_[1]) if defined $_[1];

   $_CV->{_mutex}->unlock();
   _req1('O~CVB', $_id.$LF);

   sleep(0);
}

# signal ( floating_seconds )
# signal ( )

sub signal {
   my $_id = $_[0]->[0];
   return unless ( my $_CV = $_obj{ $_id } );
   return unless ( exists $_CV->{_cr_sock} );

   sleep($_[1]) if defined $_[1];

   $_CV->{_mutex}->unlock();
   _req1('O~CVS', $_id.$LF);

   sleep(0);
}

# timedwait ( floating_seconds )

sub timedwait {
   my $_id = $_[0]->[0];
   my $_timeout = $_[1];

   return unless ( my $_CV = $_obj{ $_id } );
   return unless ( exists $_CV->{_cr_sock} );
   return $_[0]->wait() unless $_timeout;

   _croak('Condvar: timedwait (timeout) is not an integer')
      if (!looks_like_number($_timeout) || int($_timeout) != $_timeout);

   $_CV->{_mutex}->unlock();
   _req2('O~CVW', $_id.$LF, '');

   local $@; eval {
      local $SIG{ALRM} = sub { die "alarm clock restart\n" };
      alarm $_timeout unless $_is_MSWin32;

      die "alarm clock restart\n"
         if $_is_MSWin32 && $_ready->($_CV->{_cr_sock}, $_timeout);

      1 until sysread $_CV->{_cr_sock}, my($_next), 1;  # block

      alarm 0;
   };

   alarm 0;

   if ($@) {
      chomp($@), _croak($@) unless $@ eq "alarm clock restart\n";
      _req1('O~CVT', $_id.$LF);

      return '';
   }

   return 1;
}

# wait ( )

sub wait {
   my $_id = $_[0]->[0];
   return unless ( my $_CV = $_obj{ $_id } );
   return unless ( exists $_CV->{_cr_sock} );

   $_CV->{_mutex}->unlock();
   _req2('O~CVW', $_id.$LF, '');

   $_ready->($_CV->{_cr_sock}) if $_is_MSWin32;
   1 until sysread $_CV->{_cr_sock}, my($_next), 1;  # block

   return 1;
}

###############################################################################
## ----------------------------------------------------------------------------
## Methods optimized for Handle.
##
###############################################################################

sub CLOSE {
   _req2('O~CLO', $_[0]->[0].$LF, '');
}

sub OPEN {
   my ($_id, $_fd, $_buf) = (shift()->[0]);
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
   my $_id  = $_[0]->[0];
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
   my $_id  = $_[0]->[0];
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
   my $_id  = shift()->[0];
   my $_buf = join(defined $, ? $, : "", @_);

   $_buf .= $\ if defined $\;

   (length $_buf)
      ? _req2('O~PRI', $_id.$LF . length($_buf).$LF, $_buf)
      : 1;
}

sub PRINTF {
   my $_id  = shift()->[0];
   my $_buf = sprintf(shift, @_);

   (length $_buf)
      ? _req2('O~PRI', $_id.$LF . length($_buf).$LF, $_buf)
      : 1;
}

sub WRITE {
   my $_id  = shift()->[0];
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
## Methods optimized for Queue.
##
###############################################################################

sub await {
   my $_id = shift()->[0];
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
   1 until sysread $_Q->{_ar_sock}, my($_next), 1;  # block

   return;
}

sub dequeue {
   my $_id = shift()->[0];
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
   1 until sysread $_Q->{_qr_sock}, my($_next), 1;  # block

   _req4('O~QUD', $_id.$LF . $_cnt.$LF, $_cnt);
}

sub dequeue_nb {
   my $_id = shift()->[0];
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

sub enqueue  { _auto('enqueue',  @_) }
sub enqueuep { _auto('enqueuep', @_) }
sub pending  { _req5('pending',  @_) }

###############################################################################
## ----------------------------------------------------------------------------
## Methods optimized for
##  PDL, MCE::Shared::{ Array, Hash, Ordhash, Scalar }, and Hash::Ordered.
##
###############################################################################

if ($INC{'PDL.pm'}) {
   local $@; eval q{
      sub ins_inplace {
         my $_id = shift()->[0];
         if (@_) {
            my $_tmp = $_freeze->([ @_ ]);
            my $_buf = $_id.$LF . length($_tmp).$LF;
            _req2('O~PDL', $_buf, $_tmp);
         }
         return;
      }
   };
}

sub FETCHSIZE {
   _req5('FETCHSIZE', @_);
}

sub FIRSTKEY {
   my ( $self ) = @_;
   my @_keys = $self->keys;

   $self->[_ITER] = sub {
      return unless @_keys;
      return shift(@_keys);
   };

   $self->[_ITER]->();
}

sub NEXTKEY {
   $_[0]->[_ITER]->();
}

sub SCALAR {
   _req5('SCALAR', @_);
}

sub STORE {
   if (@_ == 2) {
      if (ref $_[1]) {
         # Storing a reference for SCALAR is not supported.
         _auto('STORE', $_[0], "$_[1]");
         "$_[1]";
      }
      else {
         _auto('STORE', @_);
         $_[1];
      }
   }
   else {
      if (ref $_[2]) {
         $_[2] = MCE::Shared::share({ _DEEPLY_ => 1 }, $_[2]);
         _req2('M~DEE', $_[0]->[0].$LF, $_[2]->SHARED_ID().$LF);
      }
      _auto('STORE', @_);
      $_[2];
   }
}

sub set {
   if (ref($_[2]) && $_blessed->($_[2]) && $_[2]->can('SHARED_ID')) {
      _req2('M~DEE', $_[0]->[0].$LF, $_[2]->SHARED_ID().$LF);
      delete $_new{ $_[2]->SHARED_ID() };
   }
   _auto('set', @_);
   $_[-1];
}

sub FETCH { _req6('FETCH', @_) }
sub get   { _req6('get'  , @_) }
sub CLEAR { _req7('CLEAR', @_) }
sub clear { _req7('clear', @_) }
sub decr  { _auto('decr' , @_) }
sub incr  { _auto('incr' , @_) }
sub len   { _auto('len'  , @_) }

{
   no strict 'refs';

   *{ __PACKAGE__.'::store' } = \&STORE;
}

1;

__END__

###############################################################################
## ----------------------------------------------------------------------------
## Module usage.
##
###############################################################################

=head1 NAME

MCE::Shared::Server - Server/Object packages for MCE::Shared

=head1 VERSION

This document describes MCE::Shared::Server version 1.700

=head1 DESCRIPTION

Core class for L<MCE::Shared>. See documentation there.

=head1 INDEX

L<MCE|MCE>, L<MCE::Core>, L<MCE::Shared>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

