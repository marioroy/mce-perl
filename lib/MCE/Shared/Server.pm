###############################################################################
## ----------------------------------------------------------------------------
## MCE::Shared::Server - Shared methods for the server process.
##
###############################################################################

package MCE::Shared::Server;

use strict;
use warnings;

no warnings 'threads';
no warnings 'recursion';
no warnings 'uninitialized';
no warnings 'once';

our $VERSION = '1.699';

## no critic (BuiltinFunctions::ProhibitStringyEval)

use Time::HiRes qw( sleep );
use Scalar::Util qw( blessed refaddr reftype );
use Socket qw( SOL_SOCKET SO_RCVBUF );
use Storable qw( freeze thaw );
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
   SHR_A_KEY => 'A~KEY',   ## Array Keys
   SHR_A_VAL => 'A~VAL',   ## Array Values
   SHR_A_PAI => 'A~PAI',   ## Array Pairs

   SHR_H_STO => 'H~STO',   ## Hash STORE
   SHR_H_FCH => 'H~FCH',   ## Hash FETCH
   SHR_H_DEL => 'H~DEL',   ## Hash DELETE
   SHR_H_FST => 'H~FST',   ## Hash FIRSTKEY / NEXTKEY
   SHR_H_EXI => 'H~EXI',   ## Hash EXISTS
   SHR_H_CLR => 'H~CLR',   ## Hash CLEAR
   SHR_H_SCA => 'H~SCA',   ## Hash SCALAR
   SHR_H_KEY => 'H~KEY',   ## Hash Keys
   SHR_H_VAL => 'H~VAL',   ## Hash Values
   SHR_H_PAI => 'H~PAI',   ## Hash Pairs

   SHR_S_STO => 'S~STO',   ## Scalar STORE
   SHR_S_FCH => 'S~FCH',   ## Scalar FETCH
   SHR_S_LEN => 'S~LEN',   ## Scalar Length
};

###############################################################################
## ----------------------------------------------------------------------------
## Private functions.
##
###############################################################################

my ($_all, $_oh, $_obj, $_untie, $_cache) = ({},{},{},{},{});
my ($_next_id, $_thr_cloned, $_is_client) = (0,0,1);
my ($_SVR, $_init_pid, $_svr_pid);

my %_is_oh = ( 'MCE::OrdHash' => 1 );
my $_is_older_perl = ($] lt '5.016000') ? 1 : 0;

END { _shutdown() if $_init_pid && $_init_pid eq "$$.$_thr_cloned" }

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

   ## Cache item; freezes the blessed name and refaddr only, not data
   $_cache->{ $_id } = freeze($_item);

   return wantarray ? ($_item, $_id) : $_item;
}

sub _share_h {                                    ## Share hash
   my ($_cloned, $_item) = (shift, shift);
   return $_item if (exists $_cloned->{ refaddr($_item) });

   my ($_id, $_class, $_copy) = (++$_next_id, delete $_cloned->{'class'});

   if ($_class && !$_cloned->{'compat'} && !$_is_oh{ $_class }) {
      return _share_o($_class, $_id, $_item);
   }

   $_cloned->{ refaddr($_item) } = $_item;
   $_cloned->{'is_obj'} = $_class ? 1 : 0;
   $_all->{ $_id } = $_copy = {};

   if ($_class && $_is_oh{ $_class }) {
      tie %{ $_all->{ $_id } }, $_class;
      $_oh->{ $_id } = $_class;
      $_class = undef;
   }
   elsif (!$_cloned->{'is_obj'}) {
      if ($INC{'MCE/OrdHash.pm'}) {
         tie %{ $_all->{ $_id } }, 'MCE::OrdHash';
         $_oh->{ $_id } = 'MCE::OrdHash';
      }
   }

   if (scalar @_) {
      my $_k;
      if (exists $_oh->{ $_id }) {
         my $_tobj = tied(%{ $_copy });
         while (scalar @_) {
            $_k = shift; $_tobj->STORE($_k, _copy($_cloned, shift));
         }
      } else {
         while (scalar @_) {
            $_k = shift; $_copy->{ $_k } = _copy($_cloned, shift);
         }
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

   ## Cache item; freezes the blessed name and refaddr only, not data
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

   ## Cache item; freezes the blessed name and refaddr only, not data
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

   return $_[1]
      if $_[0]->{'class'} =~ /^MCE::Shared::(?:Object|Array|Hash|Scalar)$/;

   if ($_is_oh{ $_[0]->{'class'} }) {
      $_[0]->{'type'} = 'HASH';
      scalar _share_h($_[0], {}, $_[1]->Pairs);
   }
   elsif ($_rtype eq 'HASH') {
      scalar _share_h($_[0], $_[1]);
   }
   elsif ($_rtype eq 'ARRAY') {
      scalar _share_a($_[0], $_[1]);
   }
   elsif ($_rtype eq 'SCALAR' || $_rtype eq 'REF') {
      scalar _share_s($_[0], $_[1]);
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

   if (exists $_obj->{ $_id }) {
      $_class = blessed($_obj->{ $_id });
   } else {
      $_class = blessed($_[1]);
   }

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

   local $\ = undef if (defined $\);
   local $/ = $LF if (!$/ || $/ ne $LF);

   $_DAT_LOCK->lock();
   print {$_DAT_W_SOCK} $_tag . $LF . $_chn . $LF;

   $_buf = freeze(shift); print {$_DAU_W_SOCK} length($_buf) . $LF . $_buf;
   $_buf = freeze( \@_ ); print {$_DAU_W_SOCK} length($_buf) . $LF . $_buf;
   undef $_buf;

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
      for (0 .. DATA_CHANNELS + ($INC{'MCE.pm'} ? 1 : 0));
   $_SVR->{'_mutex_'.$_} = MCE::Mutex->new(type => 'channel')
      for (1 .. DATA_CHANNELS);

   setsockopt($_SVR->{_dat_r_sock}->[0], SOL_SOCKET, SO_RCVBUF, 4096)
      if ($^O ne 'aix' && $^O ne 'linux');

   MCE::Shared::Client::_import_init($_SVR, $_all, $_oh, $_obj, $_untie);

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
   if ($_svr_pid) {
      $_svr_pid = undef; local $\ = undef if (defined $\);

      print {$_SVR->{_dat_w_sock}->[0]} SHR_M_DNE . $LF . '1' . $LF;
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
   delete $_obj->{ $_id };
   delete $_oh->{ $_id };
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
   close STDIN; $| = 1; $_is_client = 0;

   local $\ = undef; local $/ = $LF;

   $SIG{__DIE__} = sub {
      print {*STDERR} $_[0]; $SIG{INT} = sub {};
      kill('INT', $^O eq 'MSWin32' ? -$$ : -getpgrp);
      POSIX::_exit($?) if $_is_child;
   };

   my ($_DAT_R_SOCK, $_DAU_R_SOCK); my ($_client_id, $_done) = (0, 0);
   my ($_id, $_fn, $_wa, $_oid, $_key, $_len, $_ret, $_rtype);

   my %_oh_list1 = map { $_ => 1 } qw( Push PushNew Unshift UnshiftNew Splice );
   my %_oh_list2 = map { $_ => 1 } qw( Pop Shift Pairs pairs );

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
         }

         undef $_buf; $_buf = freeze($_item);
         print {$_DAU_R_SOCK} $_id . $LF . length($_buf) . $LF . $_buf;

         return;
      },

      SHR_M_DNE.$LF => sub {                      ## Done, stop server
         $_done = 1;

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
            if (exists $_oh->{ $_id }) {
               my $_tobj = tied(%{ $_all->{ $_id } });
               for my $_k ($_tobj->Keys()) {
                  _untie($_tobj->FETCH($_k));
               }
               $_tobj->CLEAR();
            }
            else {
               for my $_k (keys %{ $_all->{ $_id } }) {
                  _untie($_all->{ $_id }->{ $_k });
               }
               %{ $_all->{ $_id } } = ();
            }
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
         }

         ## Request for Perl Object via compat => 0 or Ordered Hash class
         if (exists $_obj->{ $_id }) {
            $_var = $_obj->{ $_id };
         }
         elsif (exists $_oh->{ $_id }) {
            $_var = tied(%{ $_all->{ $_id } });
            if (@_ && exists $_oh_list1{ $_fn }) {
               my ($_k, $_cloned) = (1, {});
               for ( 1 .. int(@_ / 2) ) {
                  $_[ $_k ] = _share_r($_cloned, $_[ $_k ]) if reftype($_[ $_k ]);
                  $_k += 2;
               }
            }
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
               if (@_ret && exists $_oh->{ $_id }) {
                  if (exists $_oh_list2{ $_fn }) {
                     my $_k = 1;
                     for ( 1 .. int(@_ret / 2) ) {
                        if (reftype($_ret[ $_k ])) {
                           $_ret[ $_k ] = $_ret[ $_k ]->Destroy();
                        }
                        $_k += 2;
                     }
                  }
               }
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
            my $_pkg = (exists $_oh->{ $_id })
               ? $_oh->{ $_id } : blessed($_obj->{ $_id });

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

      SHR_A_PAI.$LF => sub {                      ## Array Pairs
         $_cb_ary->( sub {
            read($_DAU_R_SOCK, (my $_buf), $_len) if $_len;
            my $_var = $_all->{ $_id };
            $_ = freeze([ $_len
               ? map { $_ => $_var->[ $_ ] } @{ thaw($_buf) }
               : map { $_ => $_var->[ $_ ] } 0 .. @{ $_var } - 1
            ]);
         });
      },

      ## ----------------------------------------------------------------------

      SHR_H_STO.$LF => sub {                      ## Hash STORE
         chomp($_id  = <$_DAU_R_SOCK>);
         chomp($_len = <$_DAU_R_SOCK>);

         read $_DAU_R_SOCK, $_key, $_len;
         chomp($_len = <$_DAU_R_SOCK>);

         if (exists $_oh->{ $_id }) {
            if ($_len > 0) {
               read $_DAU_R_SOCK, (my $_buf), $_len;
               if (chop $_buf) {
                  my $_this_id;  $_this_id = $_next_id + 1 if $_is_older_perl;
                  tied(%{ $_all->{$_id} })->STORE($_key, _share_r({}, thaw($_buf)));
                  print {$_DAU_R_SOCK} $_this_id . $LF if $_this_id;
               } else {
                  tied(%{ $_all->{ $_id } })->STORE($_key, $_buf);
               }
            }
            else {
               tied(%{ $_all->{ $_id } })->STORE($_key, undef);
            }
         }
         else {
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
         }

         return;
      },

      SHR_H_FCH.$LF => sub {                      ## Hash FETCH
         chomp($_id  = <$_DAU_R_SOCK>);
         chomp($_len = <$_DAU_R_SOCK>);

         read $_DAU_R_SOCK, $_key, $_len;

         (exists $_oh->{ $_id })
            ? $_cb_fetch->(tied(%{ $_all->{ $_id } })->FETCH($_key))
            : $_cb_fetch->($_all->{ $_id }->{ $_key });

         return;
      },

      SHR_H_DEL.$LF => sub {                      ## Hash DELETE
         chomp($_id  = <$_DAU_R_SOCK>);
         chomp($_wa  = <$_DAU_R_SOCK>);
         chomp($_len = <$_DAU_R_SOCK>);

         my $_buf; read $_DAU_R_SOCK, $_key, $_len;

         if (exists $_oh->{ $_id }) {
            $_buf = (reftype(tied(%{ $_all->{ $_id } })->FETCH($_key)))
               ? tied(%{ $_all->{ $_id } })->DELETE($_key)->Destroy()
               : tied(%{ $_all->{ $_id } })->DELETE($_key);
         }
         else {
            $_buf = (reftype($_all->{ $_id }->{ $_key }))
               ? (delete $_all->{ $_id }->{ $_key })->Destroy()
               :  delete $_all->{ $_id }->{ $_key };
         }

         $_cb_ret->($_buf) if $_wa;

         return;
      },

      SHR_H_FST.$LF => sub {                      ## Hash FIRSTKEY / NEXTKEY
         chomp($_id = <$_DAU_R_SOCK>);

         my @_a = (exists $_oh->{ $_id })
            ? tied(%{ $_all->{ $_id } })->Keys()
            : keys %{ $_all->{ $_id } };

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

         $_ret = ( (exists $_oh->{ $_id })
            ? tied(%{ $_all->{ $_id } })->EXISTS($_key)
            : exists $_all->{ $_id }->{ $_key } ) ? 1 : 0;

         print {$_DAU_R_SOCK} $_ret . $LF;

         return;
      },

      SHR_H_CLR.$LF => sub {                      ## Hash CLEAR
         my $_id; chomp($_id = <$_DAU_R_SOCK>);

         if (exists $_oh->{ $_id }) {
            my $_tobj = tied(%{ $_all->{ $_id } });
            for my $_k ($_tobj->Keys()) {
               _untie($_tobj->FETCH($_k));
            }
            $_tobj->CLEAR();
         }
         else {
            for my $_k (keys %{ $_all->{ $_id } }) {
               _untie($_all->{ $_id }->{ $_k });
            }
            %{ $_all->{ $_id } } = ();
         }

         %{ $_untie } = ();

         return;
      },

      SHR_H_SCA.$LF => sub {                      ## Hash SCALAR
         chomp($_id = <$_DAU_R_SOCK>);

         $_ret = (exists $_oh->{ $_id })
            ? tied(%{ $_all->{ $_id } })->Keys()
            : keys %{ $_all->{ $_id } };

         print {$_DAU_R_SOCK} $_ret . $LF;

         return;
      },

      SHR_H_KEY.$LF => sub {                      ## Hash Keys
         $_cb_ary->( sub {
            read($_DAU_R_SOCK, (my $_buf), $_len) if $_len;
            if (exists $_oh->{ $_id }) {
               $_ = freeze([ $_len
                  ? tied(%{ $_all->{ $_id } })->Keys(@{ thaw($_buf) })
                  : tied(%{ $_all->{ $_id } })->Keys()
               ]);
            } else {
               my $_var = $_all->{ $_id };
               $_ = freeze([ $_len
                  ? map { exists $_var->{ $_ } ? $_ : () } @{ thaw($_buf) }
                  : keys %{ $_var }
               ]);
            }
         });
      },

      SHR_H_VAL.$LF => sub {                      ## Hash Values
         $_cb_ary->( sub {
            read($_DAU_R_SOCK, (my $_buf), $_len) if $_len;
            if (exists $_oh->{ $_id }) {
               $_ = freeze([ $_len
                  ? tied(%{ $_all->{ $_id } })->Values(@{ thaw($_buf) })
                  : tied(%{ $_all->{ $_id } })->Values()
               ]);
            } else {
               my $_var = $_all->{ $_id };
               $_ = freeze([ $_len
                  ? map { $_var->{ $_ } } @{ thaw($_buf) }
                  : values %{ $_var }
               ]);
            }
         });
      },

      SHR_H_PAI.$LF => sub {                      ## Hash Pairs
         $_cb_ary->( sub {
            read($_DAU_R_SOCK, (my $_buf), $_len) if $_len;
            if (exists $_oh->{ $_id }) {
               $_ = freeze([ $_len
                  ? tied(%{ $_all->{ $_id } })->Pairs(@{ thaw($_buf) })
                  : tied(%{ $_all->{ $_id } })->Pairs()
               ]);
            } else {
               my $_var = $_all->{ $_id };
               $_ = freeze([ $_len
                  ? map { $_ => $_var->{ $_ } } @{ thaw($_buf) }
                  : %{ $_var }
               ]);
            }
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

   sleep 3.0 if $^O eq 'MSWin32';
   POSIX::_exit(0) if $_is_child;

   return;
}

1;

