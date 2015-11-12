###############################################################################
## ----------------------------------------------------------------------------
## MCE::Shared::Server - Shared methods for the server process.
##
###############################################################################

package MCE::Shared::Server;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized once );

our $VERSION = '1.699_001';

## no critic (BuiltinFunctions::ProhibitStringyEval)
## no critic (InputOutput::ProhibitTwoArgOpen)

use Time::HiRes qw( sleep );
use Scalar::Util qw( blessed refaddr reftype );
use Socket qw( SOL_SOCKET SO_RCVBUF );
use Storable qw( freeze thaw );
use Symbol qw( gensym );
use bytes;

use MCE::Util qw( $LF );
use MCE::Mutex;

our @CARP_NOT = qw( MCE::Shared MCE );

use constant {
   DATA_CHANNELS => 8,     ## Max data channels
   WA_ARRAY      => 1,     ## Wants list

   SHR_M_TIE => 'M~TIE',   ## TIE request
   SHR_M_DNE => 'M~DNE',   ## Done, stop server
   SHR_M_CID => 'M~CID',   ## ClientID request
   SHR_M_DES => 'M~DES',   ## Destroy request
   SHR_M_EXP => 'M~EXP',   ## Export request
   SHR_M_OBJ => 'M~OBJ',   ## Object request
   SHR_M_FCH => 'M~FCH',   ## Object fetch

   SHR_A_FSZ => 'A~FSZ',   ## Array FETCHSIZE
   SHR_A_SSZ => 'A~SSZ',   ## Array STORESIZE
   SHR_A_STO => 'A~STO',   ## Array STORE
   SHR_A_FCH => 'A~FCH',   ## Array FETCH
   SHR_A_DEL => 'A~DEL',   ## Array DELETE
   SHR_A_CLR => 'A~CLR',   ## Array CLEAR
   SHR_A_POP => 'A~POP',   ## Array POP
   SHR_A_PSH => 'A~PSH',   ## Array PUSH
   SHR_A_SFT => 'A~SFT',   ## Array SHIFT
   SHR_A_UFT => 'A~UFT',   ## Array UNSHIFT
   SHR_A_EXI => 'A~EXI',   ## Array EXISTS
   SHR_A_SPL => 'A~SPL',   ## Array SPLICE
   SHR_A_CLO => 'A~CLO',   ## Array Clone
   SHR_A_KEY => 'A~KEY',   ## Array Keys
   SHR_A_VAL => 'A~VAL',   ## Array Values

   SHR_F_EOF => 'F~EOF',   ## File EOF
   SHR_F_TEL => 'F~TEL',   ## File TELL
   SHR_F_FNO => 'F~FNO',   ## File FILENO
   SHR_F_SEE => 'F~SEE',   ## File SEEK
   SHR_F_CLO => 'F~CLO',   ## File CLOSE
   SHR_F_BIN => 'F~BIN',   ## File BINMODE
   SHR_F_OPN => 'F~OPN',   ## File OPEN
   SHR_F_REA => 'F~REA',   ## File READ
   SHR_F_RLN => 'F~RLN',   ## File READLINE
   SHR_F_GET => 'F~GET',   ## File GETC
   SHR_F_PRI => 'F~PRI',   ## File PRINT
   SHR_F_WRI => 'F~WRI',   ## File WRITE

   SHR_H_STO => 'H~STO',   ## Hash STORE
   SHR_H_ST2 => 'H~ST2',   ## Hash STORE PAIRS
   SHR_H_FCH => 'H~FCH',   ## Hash FETCH
   SHR_H_DEL => 'H~DEL',   ## Hash DELETE
   SHR_H_FST => 'H~FST',   ## Hash FIRSTKEY/NEXTKEY
   SHR_H_EXI => 'H~EXI',   ## Hash EXISTS
   SHR_H_CLR => 'H~CLR',   ## Hash CLEAR
   SHR_H_SCA => 'H~SCA',   ## Hash SCALAR
   SHR_H_CLO => 'H~CLO',   ## Hash Clone
   SHR_H_KEY => 'H~KEY',   ## Hash Keys
   SHR_H_VAL => 'H~VAL',   ## Hash Values

   SHR_S_STO => 'S~STO',   ## Scalar STORE
   SHR_S_FCH => 'S~FCH',   ## Scalar FETCH
   SHR_S_LEN => 'S~LEN',   ## Scalar Length
};

###############################################################################
## ----------------------------------------------------------------------------
## Private functions.
##
###############################################################################

my ($_all, $_obj, $_untie, $_file, $_cache) = ({},{},{},{},{});
my ($_next_id, $_thr_cloned, $_is_client) = (0,0,1);
my ($_SVR, $_init_pid, $_svr_pid);

my $_is_older_perl = ($] lt '5.016000') ? 1 : 0;

END { _shutdown() }

sub _croak { goto &MCE::Shared::_croak }
sub  CLONE { $_thr_cloned++ }

sub _copy {
   my $_cloned = shift;
   my $_id = refaddr($_[0]);

   ## Return the item if not a ref.
   ## Return the cloned ref if already cloned.
   ## Make copies of hash, array, and scalar refs.

   return $_[0] unless reftype($_[0]);
   return $_cloned->{ $_id } if (exists $_cloned->{ $_id });
   return _share_r($_cloned, $_[0]);
}

sub _share_a {                                    ## Share array
   my ($_cloned, $_item) = (shift, shift);
   return $_item if (exists $_cloned->{ refaddr($_item) });

   my ($_id, $_class, $_copy) = (++$_next_id, delete $_cloned->{'class'});
   return _share_o($_class, $_id, $_item) if ($_class && !$_cloned->{'compat'});

   $_cloned->{ refaddr($_item) } = $_item;
   $_cloned->{'is_obj'} = $_class ? 1 : 0;
   $_all->{ $_id } = $_copy = [];

   if (scalar @_) {
      push @{ $_copy }, map { _copy($_cloned, $_) } @_; @_ = ();
   } else {
      push @{ $_copy }, map { _copy($_cloned, $_) } @{ $_item };
   }

   Internals::SvREADONLY($_item, 0) if ($] >= 5.008003);

   @{ $_item } = (); tie @{ $_item }, 'MCE::Shared::Array', $_id;
   bless $_item, $_class ? $_class : 'MCE::Shared::Array';
   $_cache->{ $_id } = freeze($_item);

   return wantarray ? ($_item, $_id) : $_item;
}

sub _share_f {                                    ## Share file
   my ($_cloned, $_fd) = (shift, shift);
   my $_id = ++$_next_id; local $!;

   $_file->{ $_id } = shift if ref($_[0]) eq 'HASH';
   $_file->{ $_id }->{'_chunk_id'} = 0;

   if (length $_[1]) {
      open($_all->{ $_id }, "$_[0]", $_[1])
         or _croak("open error ( '$_[0]', '$_[1]' ): $!");
   }
   elsif (length $_[0]) {
      open($_all->{ $_id }, $_[0])
         or _croak("open error ( '$_[0]' ): $!");
   }
   else {
      $_all->{ $_id } = gensym();
   }

   bless \$_id, 'MCE::Shared::File';
   $_cache->{ $_id } = freeze(\$_id);

   return wantarray ? (\$_id, $_id) : $_id;
}

sub _share_h {                                    ## Share hash
   my ($_cloned, $_item) = (shift, shift);
   return $_item if (exists $_cloned->{ refaddr($_item) });

   my ($_id, $_class, $_copy) = (++$_next_id, delete $_cloned->{'class'});
   return _share_o($_class, $_id, $_item) if ($_class && !$_cloned->{'compat'});

   $_cloned->{ refaddr($_item) } = $_item;
   $_cloned->{'is_obj'} = $_class ? 1 : 0;
   $_all->{ $_id } = $_copy = {};

   if (scalar @_) {
      my $_k;
      while (scalar @_) {
         $_k = shift; $_copy->{ $_k } = _copy($_cloned, shift);
      }
   }
   else {
      for my $_k (keys %{ $_item }) {
         $_copy->{ $_k } = _copy($_cloned, $_item->{ $_k });
      }
   }

   Internals::SvREADONLY($_item, 0) if ($] >= 5.008003);

   %{ $_item } = (); tie %{ $_item }, 'MCE::Shared::Hash', $_id;
   bless $_item, $_class ? $_class : 'MCE::Shared::Hash';
   $_cache->{ $_id } = freeze($_item);

   return wantarray ? ($_item, $_id) : $_item;
}

sub _share_s {                                    ## Share scalar
   my ($_cloned, $_item) = (shift, shift);
   return $_item if (exists $_cloned->{ refaddr($_item) });

   my ($_id, $_class) = (++$_next_id, delete $_cloned->{'class'});
   return _share_o($_class, $_id, $_item) if ($_class && !$_cloned->{'compat'});

   $_cloned->{ refaddr($_item) } = $_item;
   $_cloned->{'is_obj'} = $_class ? 1 : 0;

   if (scalar @_ > 0) {
      $_all->{ $_id } = \do{ my $scalar = $_[0] };
   }
   else {
      if (reftype($_item) eq 'SCALAR') {
         $_all->{ $_id } = \do{ my $scalar = ${ $_item } };
      } else {
         $_cloned->{ $_id } = $_item if (refaddr(${ $_item }) == $_id);
         $_all->{ $_id } = \do{ my $scalar = _copy($_cloned, ${ $_item }) };
      }
   }

   if ($] >= 5.008003) {
      Internals::SvREADONLY(${ $_item }, 0);
      Internals::SvREADONLY(   $_item  , 0);
   }

   tie ${ $_item }, 'MCE::Shared::Scalar', $_id;
   bless $_item, $_class ? $_class : 'MCE::Shared::Scalar';
   $_cache->{ $_id } = freeze($_item);

   return wantarray ? ($_item, $_id) : $_item;
}

sub _share_o {                                    ## Share object
   my ($_class, $_id, $_item) = @_;
   _use($_class);

   $_obj->{ $_id } = $_item;
   $_all->{ $_id } = \($_class);

   tie my $_var, 'MCE::Shared::Object::_fetch', $_id;
   bless \$_var, 'MCE::Shared::Object';
   $_cache->{ $_id } = freeze(\$_var);

   return wantarray ? (\$_var, $_id) : \$_var;
}

sub _share_r {                                    ## Share reference
   my $_rtype = reftype($_[1]);
   return $_[1] unless $_rtype;

   $_[0]->{'class'} = blessed($_[1]);

   if ($_rtype eq 'HASH') {
      return $_[1] if (tied(%{ $_[1] }) && tied(%{ $_[1] })->can('_id'));
      return scalar _share_h($_[0], $_[1]);
   }
   elsif ($_rtype eq 'ARRAY') {
      return $_[1] if (tied(@{ $_[1] }) && tied(@{ $_[1] })->can('_id'));
      return scalar _share_a($_[0], $_[1]);
   }
   elsif ($_rtype eq 'SCALAR' || $_rtype eq 'REF') {
      return $_[1] if (tied(${ $_[1] }) && tied(${ $_[1] })->can('_id'));
      return scalar _share_s($_[0], $_[1]);
   }
   else {
      _croak("Unsupported ref type: $_rtype");
   }
}

sub _use {
   unless ( exists $INC{ join('/',split(/::/,$_[0])).'.pm' } ) {
      local $@; local $SIG{__DIE__} = sub {};
      eval "use $_[0] ()";
   }
}

## ----------------------------------------------------------------------------

sub _export {
   my ($_class, $_copy, $_id);
   my $_rtype = reftype($_[1]);

   if ($_rtype eq 'HASH') {
      $_id   = tied(%{ $_[1] })->_id();
      $_copy = tied(%{ $_[1] })->_export($_[0]);
   }
   elsif ($_rtype eq 'ARRAY') {
      $_id   = tied(@{ $_[1] })->_id();
      $_copy = tied(@{ $_[1] })->_export($_[0]);
   }
   else {
      $_rtype = reftype(${ $_[1] });
      if ($_rtype eq 'HASH') {
         $_id   =    tied(%{ ${ $_[1] } })->_id();
         $_copy = \( tied(%{ ${ $_[1] } })->_export($_[0]) );
      }
      elsif ($_rtype eq 'ARRAY') {
         $_id   =    tied(@{ ${ $_[1] } })->_id();
         $_copy = \( tied(@{ ${ $_[1] } })->_export($_[0]) );
      }
      elsif ($_rtype) {
         $_id   =    tied(${ ${ $_[1] } })->_id();
         $_copy =  ( $_rtype ne 'REF' )
                ? \( tied(${ ${ $_[1] } })->_export($_[0]) ) : \$_copy;
      }
      else {
         $_id   = tied(${ $_[1] })->_id();
         $_copy = tied(${ $_[1] })->_export($_[0]);
      }
   }

   $_class = (exists $_obj->{ $_id })
      ? blessed($_obj->{ $_id })
      : blessed($_[1]);

   if ($_class !~ /^MCE::Shared::(?:Array|Hash|Scalar)$/) {
      return bless($_copy, $_class);
   } else {
      return $_copy;
   }
}

sub _send {
   _spawn() unless $_svr_pid;

   my ($_tag, $_buf, $_id, $_len) = (delete $_[0]->{tag});

   my $_chn        = 1;
   my $_DAT_LOCK   = $_SVR->{'_mutex_'.$_chn};
   my $_DAT_W_SOCK = $_SVR->{_dat_w_sock}->[0];
   my $_DAU_W_SOCK = $_SVR->{_dat_w_sock}->[$_chn];

   $_chn = '0'.$_chn if ($^O eq 'MSWin32' && $_chn < 10);

   local $\ = undef if (defined $\);
   local $/ = $LF if (!$/ || $/ ne $LF);

   $_DAT_LOCK->lock();
   print {$_DAT_W_SOCK} $_tag . $LF . $_chn . $LF;

   $_buf = freeze(shift);  print {$_DAU_W_SOCK} length($_buf) . $LF . $_buf;
   $_buf = freeze([ @_ ]); print {$_DAU_W_SOCK} length($_buf) . $LF . $_buf;
   undef $_buf, undef @_;

   chomp($_id  = <$_DAU_W_SOCK>);
   chomp($_len = <$_DAU_W_SOCK>);

   read $_DAU_W_SOCK, $_buf, $_len;
   $_DAT_LOCK->unlock();

   return thaw($_buf);
}

sub _spawn {
   return if $_svr_pid;

   ## Create socket pairs and locks for data channels. Internal optimizations
   ## assume channel locking only (do not change).

   $_SVR = { _data_channels => DATA_CHANNELS };
   $_init_pid = "$$.$_thr_cloned";
   local $_;

   MCE::Util::_socket_pair($_SVR, qw(_dat_r_sock _dat_w_sock), $_)
      for (0 .. DATA_CHANNELS);

   setsockopt($_SVR->{_dat_r_sock}->[0], SOL_SOCKET, SO_RCVBUF, 4096)
      if ($^O ne 'aix' && $^O ne 'linux');

   $_SVR->{'_mutex_'.$_} = MCE::Mutex->new()
      for (1 .. DATA_CHANNELS);

   MCE::Shared::Client::_import_init($_SVR, $_all, $_obj, $_untie);

   if ($INC{'threads.pm'} || $^O eq 'MSWin32') {
      require threads unless exists $INC{'threads.pm'};
      $_svr_pid = threads->create(\&_loop, 0);
      $_svr_pid->detach() if defined $_svr_pid;
   }
   else {
      $_svr_pid = fork();
      unless ($_svr_pid) {
         $SIG{CHLD} = 'IGNORE' unless ($^O eq 'MSWin32');
         _loop(1);
      }
   }

   _croak("MCE::Shared::import: Cannot spawn server process: $!")
      unless (defined $_svr_pid);

   return;
}

sub _shutdown {
   return unless ($_init_pid && $_init_pid eq "$$.$_thr_cloned");

   if ($_svr_pid) {
      my $_chn  = ($^O eq 'MSWin32') ? '01' : '1';
      $_svr_pid = undef; local $\ = undef if (defined $\);

      print {$_SVR->{_dat_w_sock}->[0]} SHR_M_DNE . $LF . $_chn . $LF;
      sleep($^O eq 'MSWin32' ? 0.1 : 0.05);

      MCE::Util::_destroy_sockets($_SVR, qw( _dat_w_sock _dat_r_sock ));

      for my $_i (1 .. DATA_CHANNELS) {
         $_SVR->{'_mutex_'.$_i}->DESTROY('shutdown');
      }
   }

   return;
}

## ----------------------------------------------------------------------------

sub _delete {
   my $_id = shift;

   delete $_cache->{ $_id };
   delete $_file->{ $_id };
   delete $_obj->{ $_id };
   delete $_all->{ $_id };

   return;
}

sub _destroy {
   my $_id = shift;

   if ($_is_client) {
      local $\ = undef if (defined $\);
      local $/ = $LF if (!$/ || $/ ne $LF);

      my $_chn        = 1;
      my $_DAT_LOCK   = $_SVR->{'_mutex_'.$_chn};
      my $_DAT_W_SOCK = $_SVR->{_dat_w_sock}->[0];
      my $_DAU_W_SOCK = $_SVR->{_dat_w_sock}->[$_chn];

      $_chn = '0'.$_chn if ($^O eq 'MSWin32' && $_chn < 10);

      $_DAT_LOCK->lock();
      print {$_DAT_W_SOCK} SHR_M_DES . $LF . $_chn . $LF;
      print {$_DAU_W_SOCK} $_id . $LF;
      <$_DAU_W_SOCK>;

      $_DAT_LOCK->unlock();
      %{ $_untie } = ();
   }
   else {
      _delete($_id);
   }

   return;
}

sub _untie {
   my $_rtype = reftype($_[0]);
   return unless $_rtype;

   if ($_rtype eq 'HASH') {
      untie %{ $_[0] };
   } elsif ($_rtype eq 'ARRAY') {
      untie @{ $_[0] };
   } else {
      untie ${ $_[0] };
   }

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Server loop.
##
###############################################################################

sub _loop {
   my ($_is_child) = @_;
   require POSIX if $_is_child;

   MCE::Shared::Client::_set_is_client(0);
   $| = 1, $_is_client = 0;

   local $\ = undef; local $/ = $LF;

   $SIG{__DIE__} = sub {
      print {*STDERR} $_[0]; $SIG{INT} = sub {};
      kill('INT', $^O eq 'MSWin32' ? -$$ : -getpgrp);
      POSIX::_exit($?) if $_is_child;
   };

   my ($_DAT_R_SOCK, $_DAU_R_SOCK); my ($_client_id, $_done) = (0, 0);
   my ($_id, $_fn, $_wa, $_oid, $_key, $_len, $_ret, $_rtype, $_cnt);

   my $_cb_ary = sub {
      chomp($_id  = <$_DAU_R_SOCK>);
      chomp($_len = <$_DAU_R_SOCK>);
      local $_; $_[0]->();
      print {$_DAU_R_SOCK} length($_) . $LF, $_;
   };

   my $_cb_fetch = sub {
      if ($_rtype = reftype($_[0])) {
         if ($_rtype eq 'HASH') {
            $_oid = tied(%{ $_[0] })->_id();
         } elsif ($_rtype eq 'ARRAY') {
            $_oid = tied(@{ $_[0] })->_id();
         } else {
            $_oid = tied(${ $_[0] })->_id();
         }
         $_ret = $_cache->{ $_oid } . '1';
         print {$_DAU_R_SOCK} length($_ret) . $LF . $_ret . $_oid . $LF;
      }
      elsif (defined $_[0]) {
         print {$_DAU_R_SOCK} (length($_[0])+1) . $LF, $_[0] . '0';
      }
      else {
         print {$_DAU_R_SOCK} -1 . $LF;
      }
   };

   my $_cb_ret = sub {
      if (reftype($_[0])) {
         my $_buf = freeze($_[0]) . '1';
         print {$_DAU_R_SOCK} length($_buf) . $LF, $_buf;
      } elsif (defined $_[0]) {
         print {$_DAU_R_SOCK} (length($_[0])+1) . $LF, $_[0] . '0';
      } else {
         print {$_DAU_R_SOCK} -1 . $LF;
      }
   };

   ## -------------------------------------------------------------------------

   my %_output_function = (

      SHR_M_TIE.$LF => sub {                      ## TIE request
         my ($_buf, $_cloned, $_type, $_item, $_id);

         chomp($_len = <$_DAU_R_SOCK>);
         read $_DAU_R_SOCK, $_buf, $_len;

         $_cloned = thaw($_buf); $_type = delete $_cloned->{type};

         chomp($_len = <$_DAU_R_SOCK>);
         read $_DAU_R_SOCK, $_buf, $_len;

         if ($_type eq 'ARRAY') {
            ($_item, $_id) = _share_a($_cloned, @{ thaw($_buf) });
         } elsif ($_type eq 'HASH') {
            ($_item, $_id) = _share_h($_cloned, @{ thaw($_buf) });
         } elsif ($_type eq 'SCALAR') {
            ($_item, $_id) = _share_s($_cloned, @{ thaw($_buf) });
         } elsif ($_type eq 'GLOB') {
            ($_item, $_id) = _share_f($_cloned, @{ thaw($_buf) });
         }

         undef $_buf; $_buf = freeze($_item);
         print {$_DAU_R_SOCK} $_id . $LF . length($_buf) . $LF . $_buf;

         return;
      },

      SHR_M_DNE.$LF => sub {                      ## Done, stop server
         $_done = 1;

         foreach (keys %{ $_all }) {
            close $_all->{ $_ } if ref($_all->{ $_ }) eq 'GLOB';
         }

         return;
      },

      SHR_M_CID.$LF => sub {                      ## ClientID request
         print {$_DAU_R_SOCK} (++$_client_id) . $LF;
         $_client_id = 0 if ($_client_id > 2_000_000_000);

         return;
      },

      ## ----------------------------------------------------------------------

      SHR_M_DES.$LF => sub {                      ## Destroy request
         chomp($_id = <$_DAU_R_SOCK>);

         my $_type = reftype($_all->{ $_id });

         if ($_type eq 'ARRAY') {
            for my $_k (0 .. @{ $_all->{ $_id } } - 1) {
               _untie($_all->{ $_id }->[ $_k ]);
            }
            @{ $_all->{ $_id } } = ();
         }
         elsif ($_type eq 'HASH') {
            for my $_k (keys %{ $_all->{ $_id } }) {
               _untie($_all->{ $_id }->{ $_k });
            }
            %{ $_all->{ $_id } } = ();
         }
         elsif ($_type eq 'SCALAR') {
            _untie(${ $_all->{ $_id } });
            undef ${ $_all->{ $_id } };
         }

         _delete($_id);

         print {$_DAU_R_SOCK} $LF;

         return;
      },

      ## ----------------------------------------------------------------------

      SHR_M_EXP.$LF => sub {                      ## Export request
         my ($_buf, $_class, $_copy, $_tobj);

         chomp($_len = <$_DAU_R_SOCK>);
         read $_DAU_R_SOCK, $_buf, $_len;

         my $_exported = thaw($_buf);

         my $_type = delete $_exported->{'type'};
         my $_id   = delete $_exported->{'id'};
         my @_keys = @{ delete $_exported->{'keys'} };

         chomp($_len = <$_DAU_R_SOCK>);
         read $_DAU_R_SOCK, $_buf, $_len;

         if ($_type eq 'OBJECT') {
            $_copy = $_obj->{ $_id };
         }
         else {
            if ($_type eq 'HASH') {
               $_tobj = tie my %_h, 'MCE::Shared::Hash', $_id;
            } elsif ($_type eq 'ARRAY') {
               $_tobj = tie my @_a, 'MCE::Shared::Array', $_id;
            } else {
               $_tobj = tie my $_s, 'MCE::Shared::Scalar', $_id;
            }

            $_copy  = $_tobj->_export($_exported, @_keys);
            $_class = blessed( thaw $_cache->{ $_id } );

            if ($_class !~ /^MCE::Shared::(?:Array|Hash|Scalar)$/) {
               bless $_copy, $_class;
            }
         }

         $_buf = freeze($_copy); undef $_copy;

         print {$_DAU_R_SOCK} $_id . $LF . length($_buf) . $LF . $_buf;
         undef $_buf;

         return;
      },

      ## ----------------------------------------------------------------------

      SHR_M_FCH.$LF => sub {                      ## Object Fetch
         chomp($_id = <$_DAU_R_SOCK>);
         my $_item;

         if (exists $_obj->{ $_id }) {
            $_item = $_obj->{ $_id };
         }

         $_cb_ret->($_item);

         return;
      },

      SHR_M_OBJ.$LF => sub {                      ## Object Request
         my ($_buf, $_var); local @_;

         chomp($_id  = <$_DAU_R_SOCK>);
         chomp($_fn  = <$_DAU_R_SOCK>);
         chomp($_wa  = <$_DAU_R_SOCK>);

         chomp($_len = <$_DAU_R_SOCK>);
         read($_DAU_R_SOCK, $_[0], $_len) if $_len;

         chomp($_len = <$_DAU_R_SOCK>);
         if ($_len) {
            read $_DAU_R_SOCK, $_buf, $_len;
            push @_, chop $_buf ? @{ thaw($_buf) } : $_buf;
            undef $_buf if (length $_buf > 65536);
         }

         ## Request for Perl Object via compat => 0
         if (exists $_obj->{ $_id }) {
            $_var = $_obj->{ $_id };
         }
         else {
            _croak(
               "Can't locate object method \"$_fn\" via shared object\n",
               "or maybe, the object has been destroyed or untied\n"
            );
         }

         ## Call object method
         if (my $_code = $_var->can( $_fn )) {
            if ($_wa == WA_ARRAY) {
               my @_ret = $_code->($_var, @_);
               $_buf = freeze(\@_ret) . '1';
               print {$_DAU_R_SOCK} length($_buf) . $LF, $_buf;
            }
            elsif ($_wa) {
               my $_ret = $_code->($_var, @_);
               if (ref($_ret)) {
                  $_buf = freeze($_ret) . '1';
               } elsif (defined($_ret)) {
                  $_buf = $_ret . '0';
               } else {
                  $_buf = '2';
               }
               print {$_DAU_R_SOCK} length($_buf) . $LF, $_buf;
            }
            else {
               $_code->($_var, @_);
            }
         }

         ## Not found
         else {
            my $_pkg = blessed($_obj->{ $_id });
            _croak("Can't locate object method \"$_fn\" via package \"$_pkg\"");
         }

         return;
      },

      ## ----------------------------------------------------------------------

      SHR_A_FSZ.$LF => sub {                      ## Array FETCHSIZE
         chomp($_id = <$_DAU_R_SOCK>);

         $_ret = scalar @{ $_all->{ $_id } };
         print {$_DAU_R_SOCK} $_ret . $LF;

         return;
      },

      SHR_A_SSZ.$LF => sub {                      ## Array STORESIZE
         chomp($_id  = <$_DAU_R_SOCK>);
         chomp($_len = <$_DAU_R_SOCK>);

         $#{ $_all->{ $_id } } = $_len - 1;

         return;
      },

      SHR_A_STO.$LF => sub {                      ## Array STORE
         chomp($_id  = <$_DAU_R_SOCK>);
         chomp($_key = <$_DAU_R_SOCK>);
         chomp($_len = <$_DAU_R_SOCK>);

         if ($_len > 0) {
            read $_DAU_R_SOCK, (my $_buf), $_len;
            if (chop $_buf) {
               my $_this_id;  $_this_id = $_next_id + 1 if $_is_older_perl;
               $_all->{ $_id }->[ $_key ] = _share_r({}, thaw($_buf));
               print {$_DAU_R_SOCK} $_this_id . $LF if $_this_id;
            } else {
               $_all->{ $_id }->[ $_key ] = $_buf;
            }
         }
         else {
            $_all->{ $_id }->[ $_key ] = undef;
         }

         return;
      },

      SHR_A_FCH.$LF => sub {                      ## Array FETCH
         chomp($_id  = <$_DAU_R_SOCK>);
         chomp($_key = <$_DAU_R_SOCK>);

         $_cb_fetch->($_all->{ $_id }->[ $_key ]);

         return;
      },

      SHR_A_DEL.$LF => sub {                      ## Array DELETE
         chomp($_id  = <$_DAU_R_SOCK>);
         chomp($_wa  = <$_DAU_R_SOCK>);
         chomp($_key = <$_DAU_R_SOCK>);

         if (reftype($_all->{ $_id }->[ $_key ])) {
            if ($_wa) {
               my $_buf = (delete $_all->{ $_id }->[ $_key ])->Destroy();
               $_cb_ret->($_buf);
            } else {
               (delete $_all->{ $_id }->[ $_key ])->Destroy();
            }
         }
         elsif ($_wa) {
            my $_buf = delete $_all->{ $_id }->[ $_key ];
            $_cb_ret->($_buf);
         }
         else {
            delete $_all->{ $_id }->[ $_key ];
         }

         return;
      },

      SHR_A_CLR.$LF => sub {                      ## Array CLEAR
         my $_id; chomp($_id = <$_DAU_R_SOCK>);

         for my $_k (0 .. @{ $_all->{ $_id } } - 1) {
            _untie($_all->{ $_id }->[ $_k ]);
         }
         @{ $_all->{ $_id } } = ();
         %{ $_untie } = ();

         return;
      },

      SHR_A_POP.$LF => sub {                      ## Array POP
         chomp($_id = <$_DAU_R_SOCK>);

         my $_buf = (@{ $_all->{ $_id } } && reftype($_all->{ $_id }->[ -1 ]))
            ? pop(@{ $_all->{ $_id } })->Destroy()
            : pop(@{ $_all->{ $_id } });

         $_cb_ret->($_buf);

         return;
      },

      SHR_A_PSH.$LF => sub {                      ## Array PUSH
         chomp($_id  = <$_DAU_R_SOCK>);
         chomp($_len = <$_DAU_R_SOCK>);

         read $_DAU_R_SOCK, (my $_buf), $_len;

         if (chop $_buf) {
            my $_a = thaw($_buf);
            for my $_k (0 .. @{ $_a } - 1) {
               push @{ $_all->{ $_id } }, (reftype($_a->[ $_k ]))
                  ? _share_r({}, $_a->[ $_k ]) : $_a->[ $_k ];
            }
            undef $_buf if (length $_buf > 65536);
         }
         else {
            push(@{ $_all->{ $_id } }, $_buf);
         }

         return;
      },

      SHR_A_SFT.$LF => sub {                      ## Array SHIFT
         chomp($_id = <$_DAU_R_SOCK>);

         my $_buf = (@{ $_all->{ $_id } } && reftype($_all->{ $_id }->[ 0 ]))
            ? shift(@{ $_all->{ $_id } })->Destroy()
            : shift(@{ $_all->{ $_id } });

         $_cb_ret->($_buf);

         return;
      },

      SHR_A_UFT.$LF => sub {                      ## Array UNSHIFT
         chomp($_id  = <$_DAU_R_SOCK>);
         chomp($_len = <$_DAU_R_SOCK>);

         read $_DAU_R_SOCK, (my $_buf), $_len;

         if (chop $_buf) {
            my $_a = thaw($_buf);
            for my $_k (reverse(0 .. @{ $_a } - 1)) {
               unshift @{ $_all->{ $_id } }, (reftype($_a->[ $_k ]))
                  ? _share_r({}, $_a->[ $_k ]) : $_a->[ $_k ];
            }
            undef $_buf if (length $_buf > 65536);
         }
         else {
            unshift(@{ $_all->{ $_id } }, $_buf);
         }

         return;
      },

      SHR_A_EXI.$LF => sub {                      ## Array EXISTS
         chomp($_id  = <$_DAU_R_SOCK>);
         chomp($_key = <$_DAU_R_SOCK>);

         $_ret = (exists $_all->{ $_id }->[ $_key ]) ? 1 : 0;
         print {$_DAU_R_SOCK} $_ret . $LF;

         return;
      },

      SHR_A_SPL.$LF => sub {                      ## Array SPLICE
         chomp($_id  = <$_DAU_R_SOCK>);
         chomp($_wa  = <$_DAU_R_SOCK>);
         chomp($_len = <$_DAU_R_SOCK>);

         read $_DAU_R_SOCK, (my $_buf), $_len;
         my @_a = @{ thaw($_buf) };

         my (@_dat, @_ret, @_tmp);
         my $_sz  = scalar @{ $_all->{ $_id } };
         my $_off = @_a ? shift(@_a) : 0;
         $_off   += $_sz if $_off < 0;
         $_len    = @_a ? shift(@_a) : $_sz - $_off;

         for my $_k (0 .. @_a - 1) {
            $_dat[ $_k ] = (reftype($_a[ $_k ]))
               ? _share_r({}, $_a[ $_k ]) : $_a[ $_k ];
         }

         @_tmp = splice(@{ $_all->{ $_id } }, $_off, $_len, @_dat);

         for my $_k (0 .. @_tmp - 1) {
            $_ret[ $_k ] = reftype($_tmp[ $_k ])
               ? $_tmp[ $_k ]->Destroy() : $_tmp[ $_k ];
         }

         $_buf = ($_wa == 1) ? freeze(\@_ret) : $_ret[ -1 ];
         $_cb_ret->($_buf) if ($_wa);

         return;
      },

      SHR_A_CLO.$LF => sub {                      ## Array Clone
         $_cb_ary->( sub {
            read($_DAU_R_SOCK, (my $_buf), $_len) if $_len;
            my ($_obj, $_cid) = _share_a({}, []);
            my ($_var, $_clo) = ( $_all->{ $_id }, $_all->{ $_cid } );
            if ($_len) {
               @{ $_clo } = map { $_var->[ $_ ] } @{ thaw($_buf) };
            } else {
               @{ $_clo } = @{ $_var };
            }
            $_ = freeze([ $_obj ]);
         });
      },

      SHR_A_KEY.$LF => sub {                      ## Array Keys
         $_cb_ary->( sub {
            read($_DAU_R_SOCK, (my $_buf), $_len) if $_len;
            my $_var = $_all->{ $_id };
            $_ = freeze([ $_len
               ? map { exists $_var->[ $_ ] ? $_ : () } @{ thaw($_buf) }
               : ( 0 .. @{ $_var } - 1 )
            ]);
         });
      },

      SHR_A_VAL.$LF => sub {                      ## Array Values
         $_cb_ary->( sub {
            read($_DAU_R_SOCK, (my $_buf), $_len) if $_len;
            my $_var = $_all->{ $_id };
            $_ = freeze([ $_len
               ? map { $_var->[ $_ ] } @{ thaw($_buf) }
               : @{ $_var }
            ]);
         });
      },

      ## ----------------------------------------------------------------------

      SHR_F_EOF.$LF => sub {                      ## File EOF
         chomp($_id = <$_DAU_R_SOCK>);

         $_ret = eof( $_all->{ $_id } );
         print {$_DAU_R_SOCK} $_ret . $LF;

         return;
      },

      SHR_F_TEL.$LF => sub {                      ## File TELL
         chomp($_id = <$_DAU_R_SOCK>);

         $_ret = tell( $_all->{ $_id } );
         print {$_DAU_R_SOCK} $_ret . $LF;

         return;
      },

      SHR_F_FNO.$LF => sub {                      ## File FILENO
         chomp($_id = <$_DAU_R_SOCK>);

         $_ret = fileno( $_all->{ $_id } );
         print {$_DAU_R_SOCK} $_ret . $LF;

         return;
      },

      SHR_F_SEE.$LF => sub {                      ## File SEEK
         my ($_pos, $_typ);

         chomp($_id  = <$_DAU_R_SOCK>);
         chomp($_pos = <$_DAU_R_SOCK>);
         chomp($_typ = <$_DAU_R_SOCK>);

         $_ret = seek( $_all->{ $_id }, $_pos, $_typ );
         print {$_DAU_R_SOCK} $_ret . $LF;

         return;
      },

      SHR_F_CLO.$LF => sub {                      ## File CLOSE
         chomp($_id = <$_DAU_R_SOCK>);

         $_ret = close( $_all->{ $_id } );
         print {$_DAU_R_SOCK} $_ret . $LF;

         return;
      },

      SHR_F_BIN.$LF => sub {                      ## File BINMODE
         chomp($_id = <$_DAU_R_SOCK>);

         binmode( $_all->{ $_id } );
         print {$_DAU_R_SOCK} '1' . $LF;

         return;
      },

      SHR_F_OPN.$LF => sub {                      ## File OPEN
         my $_buf; local $!;

         chomp($_id  = <$_DAU_R_SOCK>);
         chomp($_len = <$_DAU_R_SOCK>);

         read($_DAU_R_SOCK, $_buf, $_len);

         close($_all->{ $_id }) if fileno($_all->{ $_id });
         $_file->{ $_id }->{'_chunk_id'} = 0;
         delete $_file->{ $_id }->{'_ended'};

         my $_args = thaw($_buf);

         if (scalar @{ $_args } == 2) {
            open($_all->{ $_id }, $_args->[0], $_args->[1])
               or _croak("open error ( '$_args->[0]', '$_args->[1]' ): $!");
         }
         else {
            open($_all->{ $_id }, $_args->[0])
               or _croak("open error ( '$_args->[0]' ): $!");
         }

         print {$_DAU_R_SOCK} $LF;

         return;
      },

      SHR_F_REA.$LF => sub {                      ## File READ
         my ($_buf, $_a3); local $!;

         chomp($_id = <$_DAU_R_SOCK>);
         chomp($_a3 = <$_DAU_R_SOCK>);

         $_ret = read($_all->{ $_id }, $_buf, $_a3);
         print {$_DAU_R_SOCK} $_ret . $LF . length($_buf) . $LF . $_buf;

         return;
      },

      SHR_F_RLN.$LF => sub {                      ## File READLINE
         chomp($_id  = <$_DAU_R_SOCK>);
         chomp($_cnt = <$_DAU_R_SOCK>);

         local $/ = $_file->{ $_id }->{'RS'} if $_file->{ $_id }->{'RS'};
         my ($_chunk_id, $_buf) = (++$_file->{ $_id }->{'_chunk_id'});
         my ($_fh) = ($_all->{ $_id });

         if (exists $_file->{ $_id }->{'_ended'}) {
            print {$_DAU_R_SOCK} $_chunk_id.$LF . '0'.$LF;
            return;
         }

         if (length $/ > 1 && substr($/, 0, 1) eq "\n") {
            $_len = length($/) - 1;
            for my $_c (1 .. $_cnt) {
               last if eof $_fh;
               if ($_chunk_id > 1 || $_c > 1) {
                  $_buf .= substr($/, 1), $_buf .= readline $_fh ||
                     do { $_file->{ $_id }->{'_ended'} = 1, '' };
               } else {
                  $_buf .= readline $_fh ||
                     do { $_file->{ $_id }->{'_ended'} = 1, '' };
               }
               substr($_buf, -$_len, $_len, '')
                  if (substr($_buf, -$_len) eq substr($/, 1));
            }
         }
         else {
            for my $_c (1 .. $_cnt) {
               last if eof $_fh;
               $_buf .= readline $_fh ||
                  do { $_file->{ $_id }->{'_ended'} = 1, '' };
            }
         }

         print {$_DAU_R_SOCK} $_chunk_id.$LF . length($_buf).$LF, $_buf;

         return;
      },

      SHR_F_GET.$LF => sub {                      ## File GETC
         chomp($_id = <$_DAU_R_SOCK>);

         $_ret = getc( $_all->{ $_id } );
         print {$_DAU_R_SOCK} length($_ret).$LF, $_ret;

         return;
      },

      SHR_F_PRI.$LF => sub {                      ## File PRINT
         my $_buf;

         chomp($_id  = <$_DAU_R_SOCK>);
         chomp($_len = <$_DAU_R_SOCK>);

         read $_DAU_R_SOCK, $_buf, $_len;
         print {$_all->{ $_id }} $_buf;

         return;
      },

      SHR_F_WRI.$LF => sub {                      ## File WRITE
         my $_buf;

         chomp($_id  = <$_DAU_R_SOCK>);
         chomp($_len = <$_DAU_R_SOCK>);

         if (chop $_len) {
            read $_DAU_R_SOCK, $_buf, $_len;
            my $_ref = thaw($_buf);
            syswrite $_all->{ $_id }, $_ref->[0], $_ref->[1], $_ref->[2] || 0;
         }
         else {
            read $_DAU_R_SOCK, $_buf, $_len;
            syswrite $_all->{ $_id }, $_buf;
         }

         return;
      },

      ## ----------------------------------------------------------------------

      SHR_H_STO.$LF => sub {                      ## Hash STORE
         chomp($_id  = <$_DAU_R_SOCK>);
         chomp($_len = <$_DAU_R_SOCK>);

         read $_DAU_R_SOCK, $_key, $_len;
         chomp($_len = <$_DAU_R_SOCK>);

         if ($_len > 0) {
            read $_DAU_R_SOCK, (my $_buf), $_len;
            if (chop $_buf) {
               my $_this_id;  $_this_id = $_next_id + 1 if $_is_older_perl;
               $_all->{ $_id }->{ $_key } = _share_r({}, thaw($_buf));
               print {$_DAU_R_SOCK} $_this_id . $LF if $_this_id;
            } else {
               $_all->{ $_id }->{ $_key } = $_buf;
            }
         }
         else {
            $_all->{ $_id }->{ $_key } = undef;
         }

         return;
      },

      SHR_H_ST2.$LF => sub {                      ## Hash STORE PAIRS
         chomp($_id  = <$_DAU_R_SOCK>);
         chomp($_len = <$_DAU_R_SOCK>);

         read $_DAU_R_SOCK, (my $_buf), $_len;

         my $_pairs = thaw($_buf); undef $_buf;
         my ($_cloned, $_var) = ({}, $_all->{ $_id });

         while (@{ $_pairs }) {
            $_key = shift @{ $_pairs };
            $_var->{ $_key } = reftype($_pairs->[0])
               ? _share_r($_cloned, shift @{ $_pairs })
               : shift @{ $_pairs };
         }

         return;
      },

      SHR_H_FCH.$LF => sub {                      ## Hash FETCH
         chomp($_id  = <$_DAU_R_SOCK>);
         chomp($_len = <$_DAU_R_SOCK>);

         read $_DAU_R_SOCK, $_key, $_len;
         $_cb_fetch->($_all->{ $_id }->{ $_key });

         return;
      },

      SHR_H_DEL.$LF => sub {                      ## Hash DELETE
         chomp($_id  = <$_DAU_R_SOCK>);
         chomp($_wa  = <$_DAU_R_SOCK>);
         chomp($_len = <$_DAU_R_SOCK>);

         read $_DAU_R_SOCK, $_key, $_len;

         my $_buf = (reftype($_all->{ $_id }->{ $_key }))
            ? (delete $_all->{ $_id }->{ $_key })->Destroy()
            :  delete $_all->{ $_id }->{ $_key };

         $_cb_ret->($_buf) if $_wa;

         return;
      },

      SHR_H_FST.$LF => sub {                      ## Hash FIRSTKEY/NEXTKEY
         chomp($_id = <$_DAU_R_SOCK>);

         my @_a = keys %{ $_all->{ $_id } };

         if (scalar @_a) {
            my $_buf = freeze(\@_a);
            print {$_DAU_R_SOCK} length($_buf) . $LF . $_buf;
         } else {
            print {$_DAU_R_SOCK} -1 . $LF;
         }

         return;
      },

      SHR_H_EXI.$LF => sub {                      ## Hash EXISTS
         chomp($_id  = <$_DAU_R_SOCK>);
         chomp($_len = <$_DAU_R_SOCK>);

         read $_DAU_R_SOCK, $_key, $_len;

         $_ret = ( exists $_all->{ $_id }->{ $_key } ) ? 1 : 0;
         print {$_DAU_R_SOCK} $_ret . $LF;

         return;
      },

      SHR_H_CLR.$LF => sub {                      ## Hash CLEAR
         my $_id; chomp($_id = <$_DAU_R_SOCK>);

         for my $_k (keys %{ $_all->{ $_id } }) {
            _untie($_all->{ $_id }->{ $_k });
         }

         %{ $_all->{ $_id } } = ();
         %{ $_untie } = ();

         return;
      },

      SHR_H_SCA.$LF => sub {                      ## Hash SCALAR
         chomp($_id = <$_DAU_R_SOCK>);

         $_ret = keys %{ $_all->{ $_id } };
         print {$_DAU_R_SOCK} $_ret . $LF;

         return;
      },

      SHR_H_CLO.$LF => sub {                      ## Hash Clone
         $_cb_ary->( sub {
            read($_DAU_R_SOCK, (my $_buf), $_len) if $_len;
            my ($_obj, $_cid) = _share_h({}, {});
            my ($_var, $_clo) = ( $_all->{ $_id }, $_all->{ $_cid } );
            if ($_len) {
               %{ $_clo } = map { $_, $_var->{ $_ } } @{ thaw($_buf) };
            } else {
               %{ $_clo } = %{ $_var };
            }
            $_ = freeze([ $_obj ]);
         });
      },

      SHR_H_KEY.$LF => sub {                      ## Hash Keys
         $_cb_ary->( sub {
            read($_DAU_R_SOCK, (my $_buf), $_len) if $_len;
            my $_var = $_all->{ $_id };
            $_ = freeze([ $_len
               ? map { exists $_var->{ $_ } ? $_ : () } @{ thaw($_buf) }
               : keys %{ $_var }
            ]);
         });
      },

      SHR_H_VAL.$LF => sub {                      ## Hash Values
         $_cb_ary->( sub {
            read($_DAU_R_SOCK, (my $_buf), $_len) if $_len;
            my $_var = $_all->{ $_id };
            $_ = freeze([ $_len
               ? @{ $_var }{ @{ thaw($_buf) } }
               : values %{ $_var }
            ]);
         });
      },

      ## ----------------------------------------------------------------------

      SHR_S_STO.$LF => sub {                      ## Scalar STORE
         chomp($_id  = <$_DAU_R_SOCK>);
         chomp($_len = <$_DAU_R_SOCK>);

         if ($_len > 0) {
            read $_DAU_R_SOCK, (my $_buf), $_len;
            if (chop $_buf) {
               my $_this_id;  $_this_id = $_next_id + 1 if $_is_older_perl;
               ${ $_all->{ $_id } } = _share_r({}, thaw($_buf));
               print {$_DAU_R_SOCK} $_this_id . $LF if $_this_id;
            } else {
               ${ $_all->{ $_id } } = $_buf;
            }
         }
         else {
            ${ $_all->{ $_id } } = undef;
         }

         return;
      },

      SHR_S_FCH.$LF => sub {                      ## Scalar FETCH
         chomp($_id = <$_DAU_R_SOCK>);
         my $_item;

         if (exists $_all->{ $_id }) {
            $_item = ${ $_all->{ $_id } };
         }

         $_cb_ret->($_item);

         return;
      },

      SHR_S_LEN.$LF => sub {                      ## Scalar Length
         chomp($_id = <$_DAU_R_SOCK>);

         $_ret = (defined ${ $_all->{ $_id } })
            ? length ${ $_all->{ $_id } } : 0;

         print {$_DAU_R_SOCK} $_ret . $LF;

         return;
      },

   );

   ## -------------------------------------------------------------------------

   my $_func; my $_channels = $_SVR->{_dat_r_sock};

   $_DAT_R_SOCK = $_SVR->{_dat_r_sock}->[0];

   ## Call on hash function. Exit loop when finished.
   if ($^O eq 'MSWin32') {
      ## The normal loop hangs on Windows when spawning processes/threads.
      ## Using ioctl() properly, http://www.perlmonks.org/?node_id=780083

      my $_val_bytes = "\x00\x00\x00\x00";
      my $_ptr_bytes = unpack('I', pack('P', $_val_bytes));
      my $_count = 0; my $_nbytes;

      while (1) {
         ioctl($_DAT_R_SOCK, 0x4004667f, $_ptr_bytes); # FIONREAD

         unless ($_nbytes = unpack('I', $_val_bytes)) {
            # delay so not to consume a CPU for non-blocking ioctl
            if (++$_count > 1000) { $_count = 0; sleep 0.015 }
         }
         else {
            $_count = 0;
            do {
               sysread($_DAT_R_SOCK, $_func, 9);

               $_DAU_R_SOCK = $_channels->[ substr($_func, -3, 3, '') ];
               $_output_function{$_func}();

               last if $_done;

            } while ($_nbytes -= 9);
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

   sleep 3.0 if $^O eq 'MSWin32';
   POSIX::_exit(0) if $_is_child;

   return;
}

1;

