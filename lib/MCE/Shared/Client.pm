###############################################################################
## ----------------------------------------------------------------------------
## MCE::Shared::Client -- Shared methods for the client process.
##
###############################################################################

package MCE::Shared::Client;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized once );

our $VERSION = '1.699_001';

## no critic (BuiltinFunctions::ProhibitStringyEval)
## no critic (Subroutines::ProhibitExplicitReturnUndef)
## no critic (TestingAndDebugging::ProhibitNoStrict)

use Storable qw( freeze thaw );
use bytes;

our @CARP_NOT = qw( MCE::Shared MCE );

use constant {
   SHR_M_CID => 'M~CID',   ## ClientID request
};

my %_supp = map { $_ => 1 } qw( ARRAY HASH SCALAR );
my $LF = "\012"; Internals::SvREADONLY($LF, 1);

my ($_DAT_LOCK, $_DAT_W_SOCK, $_DAU_W_SOCK, $_chn);
my ($_dat_ex, $_dat_un, $_is_client, $_len, $_oid, $_ret, $_wa, $_r);
my ($_cache, $_flk) = ({}, {});

## Init function called by MCE::Shared::Server.

my ($_SVR, $_all, $_obj, $_untie);

sub _import_init {
   ($_SVR, $_all, $_obj, $_untie) = @_;

   $_chn        = 1;
   $_DAT_LOCK   = $_SVR->{'_mutex_'.$_chn};
   $_DAT_W_SOCK = $_SVR->{_dat_w_sock}->[0];
   $_DAU_W_SOCK = $_SVR->{_dat_w_sock}->[$_chn];

   $_dat_ex     = sub { sysread(  $_DAT_LOCK->{_r_sock}, my $_b, 1 ) };
   $_dat_un     = sub { syswrite( $_DAT_LOCK->{_w_sock}, '0' ) };
   $_is_client  = 1;

   $_chn = '0'.$_chn if ($^O eq 'MSWin32' && $_chn < 10);

   return;
}

sub _set_is_client {
   $_is_client = $_[0];
}

## Public init function for non-threaded clients.

sub init {
   return unless defined $_SVR;

   my $_wid = $_[0] || _get_client_id();
      $_wid = $$ if ( $_wid !~ /\d+/ );

   $_chn        = abs($_wid) % $_SVR->{_data_channels} + 1;
   $_DAT_LOCK   = $_SVR->{'_mutex_'.$_chn};
   $_DAU_W_SOCK = $_SVR->{_dat_w_sock}->[$_chn];

   $_chn = '0'.$_chn if ($^O eq 'MSWin32' && $_chn < 10);
   ($_all, $_obj, $_cache, $_flk) = ({},{},{},{});

   return;
}

sub _get_client_id {
   local $\ = undef if (defined $\);
   local $/ = $LF if (!$/ || $/ ne $LF);

   $_dat_ex->();
   print {$_DAT_W_SOCK} SHR_M_CID.$LF . $_chn.$LF;
   chomp($_ret = <$_DAU_W_SOCK>);
   $_dat_un->();

   return $_ret;
}

## Hook for non-MCE worker threads.

sub CLONE {
   init(threads->tid()) if ($INC{'threads.pm'} && !$INC{'MCE.pm'});
}

###############################################################################
## ----------------------------------------------------------------------------
## Common routines.
##
###############################################################################

## overloading.pm is not available until 5.10.1 so emulate with refaddr
## tip found in Hash::Ordered by David Golden

my ($_numify, $_strify_a, $_strify_h, $_strify_s);

BEGIN {
  local $@;
  if ($] le '5.010000') {
    require Scalar::Util; Scalar::Util->import('refaddr');
    eval q{
      $_numify   = sub { refaddr($_[0]) };
      $_strify_a = sub { sprintf "%s=ARRAY(0x%x)" ,ref($_[0]),refaddr($_[0]) };
      $_strify_h = sub { sprintf "%s=HASH(0x%x)"  ,ref($_[0]),refaddr($_[0]) };
      $_strify_s = sub { sprintf "%s=SCALAR(0x%x)",ref($_[0]),refaddr($_[0]) };
    }; die $@ if $@;
  }
  else {
    eval q{
      $_numify   = sub { no overloading; 0 + $_[0]  };
      $_strify_a = sub { no overloading;    "$_[0]" };
      $_strify_h = sub { no overloading;    "$_[0]" };
      $_strify_s = sub { no overloading;    "$_[0]" };
    }; die $@ if $@;
  }
}

## ----------------------------------------------------------------------------

my $_croak = sub {
   goto &MCE::Shared::_croak;
};

my $_send_ary = sub {
   my ($_tag, $_id) = (shift, shift);
   my ($_buf, $_tmp);

   if (scalar @_ > 1 || ref $_[0] || !defined $_[0]) {
      $_tmp = freeze([ @_ ]);
      $_buf = $_id.$LF . (length($_tmp)+1).$LF . $_tmp.'1';
   } else {
      $_buf = $_id.$LF . (length($_[0])+1).$LF . $_[0].'0';
   }

   local $\ = undef if (defined $\);

   $_dat_ex->();
   print {$_DAT_W_SOCK} $_tag.$LF . $_chn.$LF;
   print {$_DAU_W_SOCK} $_buf;
   $_dat_un->();

   if (length $_buf > 65536) {
      undef $_buf, undef $_tmp, undef @_;
      return 1;
   }

   return;
};

my $_send_buf = sub {
   local $\ = undef if (defined $\);

   $_dat_ex->();
   print {$_DAT_W_SOCK} $_[0].$LF . $_chn.$LF;
   print {$_DAU_W_SOCK} $_[1];
   $_dat_un->();

   return 1;
};

## ----------------------------------------------------------------------------

my $_recv_ary = sub {
   my ($_tag, $_id) = (shift, shift);
   my ($_buf, $_tmp);

   if (scalar @_) {
      $_tmp = freeze([ @_ ]);
      $_buf = $_id.$LF . length($_tmp).$LF . $_tmp;
      undef $_tmp, undef @_ if (length $_tmp > 65536);
   } else {
      $_buf = $_id.$LF . '0'.$LF;
   }

   local $\ = undef if (defined $\);
   local $/ = $LF if (!$/ || $/ ne $LF);

   $_dat_ex->();
   print {$_DAT_W_SOCK} $_tag.$LF . $_chn.$LF;
   print {$_DAU_W_SOCK} $_buf;

   chomp($_len = <$_DAU_W_SOCK>);
   read $_DAU_W_SOCK, $_buf, $_len;
   $_dat_un->();

   return @{ thaw($_buf) };
};

my $_recv_sca = sub {
   local $\ = undef if (defined $\);
   local $/ = $LF if (!$/ || $/ ne $LF);

   $_dat_ex->();
   print {$_DAT_W_SOCK} $_[0].$LF . $_chn.$LF;
   print {$_DAU_W_SOCK} $_[1];

   chomp($_ret = <$_DAU_W_SOCK>);
   $_dat_un->();

   return $_ret;
};

## ----------------------------------------------------------------------------

my $_do_fetch = sub {
   local $\ = undef if (defined $\);
   local $/ = $LF if (!$/ || $/ ne $LF);

   $_dat_ex->();
   print {$_DAT_W_SOCK} $_[0].$LF . $_chn.$LF;
   print {$_DAU_W_SOCK} $_[1];

   chomp($_len = <$_DAU_W_SOCK>);

   if ($_len < 0) {
      $_dat_un->();
      return undef;
   }

   read $_DAU_W_SOCK, (my $_buf), $_len;

   if (chop $_buf) {
      chomp($_oid = <$_DAU_W_SOCK>);
      $_dat_un->();
      return (!exists $_flk->{ $_oid })
         ? $_flk->{ $_oid } = thaw($_buf) : $_flk->{ $_oid };
   }
   else {
      $_dat_un->();
      return $_buf;
   }
};

my $_do_ret = sub {
   local $/ = $LF if (!$/ || $/ ne $LF);

   if (scalar @_) {
      local $\ = undef if (defined $\);
      $_dat_ex->();
      print {$_DAT_W_SOCK} $_[0].$LF . $_chn.$LF;
      print {$_DAU_W_SOCK} $_[1];
   }

   chomp($_len = <$_DAU_W_SOCK>);

   if ($_len < 0) {
      $_dat_un->();
      return undef;
   }

   read $_DAU_W_SOCK, (my $_buf), $_len;
   $_dat_un->();

   return (chop $_buf) ? thaw($_buf) : $_buf;
};

## ----------------------------------------------------------------------------

## Hack for older Perl versions (v5.14 and lower) for autovivification to work
## when storing a deep reference.

my $_is_older_perl = ($] lt '5.016000') ? 1 : 0;

my $_autovivify_hack = sub {
   my $_id = $_[0];

   if ($_[1] eq 'HASH') {
      tie %{ $_[2] }, 'MCE::Shared::Hash', $_id;
   } elsif ($_[1] eq 'ARRAY') {
      tie @{ $_[2] }, 'MCE::Shared::Array', $_id;
   } else {
      Internals::SvREADONLY(${ $_[2] }, 0) if ($] >= 5.008003);
      tie ${ $_[2] }, 'MCE::Shared::Scalar', $_id;
   }

   return 1;
};

###############################################################################
## ----------------------------------------------------------------------------
## Object package for Perl Objects via compat => 0 (default for objects).
##
###############################################################################

package MCE::Shared::Object;

no warnings 'threads';
no warnings 'recursion';
no warnings 'uninitialized';

use Storable qw( freeze thaw );
use bytes;

our @CARP_NOT = qw( MCE::Shared MCE );

use constant {
   SHR_M_EXP => 'M~EXP',   ## Export request
   SHR_M_OBJ => 'M~OBJ',   ## Object request
   WA_UNDEF  => 0,         ## Wants nothing
   WA_ARRAY  => 1,         ## Wants list
   WA_SCALAR => 2,         ## Wants scalar
};

use overload q("") => $_strify_s, q(0+) => $_numify, fallback => 1;

sub DESTROY {}

## ----------------------------------------------------------------------------
## Object methods are handled via AUTOLOAD handling.

sub AUTOLOAD {                                    ## Object Request

   ## MCE::Shared::Object::Method  # hard-coded offset 21, to not rindex

   my $_id = ${ tied ${ (shift) } };
   my $_fn = substr($MCE::Shared::Object::AUTOLOAD, 21);
   my $_wa = !defined wantarray ? WA_UNDEF : wantarray ? WA_ARRAY : WA_SCALAR;

   ## Attempts to not freeze for 2 arguments or less to minimize overhead.

   my $_buf  = $_id.$LF . $_fn.$LF . $_wa.$LF;
      $_buf .= (defined($_[0]) && !ref($_[0]))
         ? length($_[0]).$LF . shift() : '0'.$LF;

   my $_tmp  = (@_)
      ? (@_ > 1 || !defined($_[0]) || ref($_[0]))
           ? freeze([ @_ ]).'1' : $_[0].'0'
      : '';

   local $\ = undef if (defined $\);
   $_dat_ex->();

   print {$_DAT_W_SOCK} SHR_M_OBJ.$LF . $_chn.$LF;
   print {$_DAU_W_SOCK} $_buf.length($_tmp).$LF, $_tmp;

   undef $_tmp, undef @_ if (length $_tmp > 65536);

   if ($_wa) {
      local $/ = $LF if (!$/ || $/ ne $LF);

      chomp($_len = <$_DAU_W_SOCK>);
      read $_DAU_W_SOCK, $_buf, $_len;
      $_dat_un->();

      my $_rc = chop $_buf;
      if ($_wa == WA_ARRAY) {
         @{ thaw($_buf) };
      } elsif ($_rc == 2) {
         ();
      } else {
         $_rc ? thaw($_buf) : $_buf;
      }
   }
   else {
      $_dat_un->();
   }
}

## ----------------------------------------------------------------------------
## Object public methods and fetch support.

sub Destroy {                                     ## Object Destroy
   my $_id = ${ tied ${ $_[0] } || $_[0] };
   my ($_data, $_wa);  ($_cache, $_flk) = ({}, {});

   $_data = Export(@_) if ($_wa = (defined wantarray));
   MCE::Shared::Server::_destroy($_id);

   return $_wa ? $_data : ();
}

sub Export {                                      ## Object Export
   my $_id = ${ tied ${ $_[0] } || $_[0] };

   MCE::Shared::Server::_send({
      id => $_id, tag => SHR_M_EXP, type => 'OBJECT', keys => []
   });
}

package MCE::Shared::Object::_fetch;

sub _id { ${ $_[0] } }

sub TIESCALAR { bless \$_[1] => $_[0] }
sub DESTROY {}
sub STORE {}

sub FETCH {
   my $_id = ${ tied ${ $_[0] } || $_[0] };

   if ($_is_client) {
      $_do_ret->('M~FCH', $_id.$LF);
   } else {
      ${ $_all->{ $_id } };
   }
}

###############################################################################
## ----------------------------------------------------------------------------
## Array tie package.
##
###############################################################################

package MCE::Shared::Array;

no warnings 'threads';
no warnings 'recursion';
no warnings 'uninitialized';

use Scalar::Util qw( reftype );
use Storable qw( freeze thaw );
use bytes;

our @CARP_NOT = qw( MCE::Shared MCE );

use constant {
   SHR_M_EXP => 'M~EXP',   ## Export request
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
   WA_UNDEF  => 0,         ## Wants nothing
   WA_ARRAY  => 1,         ## Wants list
   WA_SCALAR => 2,         ## Wants scalar
};

use overload q("") => $_strify_a, q(0+) => $_numify, fallback => 1;

sub _id { ${ $_[0] } }

sub TIEARRAY { bless \$_[1] => $_[0] }
sub DESTROY {}
sub EXTEND {}

sub UNTIE {                                       ## Array UNTIE
   my $_id = ${ reftype($_[0]) eq 'ARRAY' ? tied @{ $_[0] } : $_[0] };

   return if (exists $_untie->{ $_id });
   $_untie->{ $_id } = 1;

   $_croak->("Method (UNTIE) is not allowed by the worker process")
      if ($INC{'MCE.pm'} && MCE->wid);

   if (exists $_all->{ $_id }) {
      for my $_k (0 .. @{ $_all->{ $_id } } - 1) {
         MCE::Shared::Server::_untie($_all->{ $_id }->[ $_k ]);
      }
      @{ $_all->{ $_id } } = ();
   }

   MCE::Shared::Server::_destroy($_id);

   return;
}

## ----------------------------------------------------------------------------
## Array tie methods.

sub FETCHSIZE {                                   ## Array FETCHSIZE
   my $_id = ${ reftype($_[0]) eq 'ARRAY' ? tied @{ $_[0] } : $_[0] };

   if ($_is_client) {
      $_recv_sca->(SHR_A_FSZ, $_id.$LF);
   } else {
      scalar @{ $_all->{ $_id } };
   }
}

sub STORESIZE {                                   ## Array STORESIZE
   my $_id = ${ reftype($_[0]) eq 'ARRAY' ? tied @{ $_[0] } : $_[0] };
   $_send_buf->(SHR_A_SSZ, $_id.$LF . $_[1].$LF);
}

sub STORE {                                       ## Array STORE
   my $_id = ${ reftype($_[0]) eq 'ARRAY' ? tied @{ $_[0] } : $_[0] };
   my ($_buf, $_tmp);

   if (!defined $_[2]) {
      $_buf = $_id.$LF . $_[1].$LF . '-1'.$LF;
   }
   elsif ($_r = reftype($_[2])) {
      $_croak->("Unsupported ref type: $_r") unless (exists $_supp{ $_r });

      $_tmp = freeze($_[2]);
      $_buf = $_id.$LF . $_[1].$LF . (length($_tmp)+1).$LF . $_tmp.'1';

      if ($_is_older_perl) {
         my $_id = $_recv_sca->(SHR_A_STO, $_buf);
         return $_autovivify_hack->($_id, $_r, $_[2]);
      }
   }
   else {
      $_buf = $_id.$LF . $_[1].$LF . (length($_[2])+1).$LF . $_[2].'0';
   }

   $_send_buf->(SHR_A_STO, $_buf);
}

sub FETCH {                                       ## Array FETCH
   my $_id = ${ reftype($_[0]) eq 'ARRAY' ? tied @{ $_[0] } : $_[0] };

   if ($_is_client) {
      $_do_fetch->(SHR_A_FCH, $_id.$LF . $_[1].$LF);
   } else {
      $_all->{ $_id }->[ $_[1] ];
   }
}

sub DELETE {                                      ## Array DELETE
   my $_so = shift;
   my $_id = ${ reftype($_so) eq 'ARRAY' ? tied @{ $_so } : $_so; };

   if (@_ > 1) {
      DELETE->($_so, $_) for (@_);
   }
   else {
      $_wa = (!defined wantarray) ? WA_UNDEF : WA_SCALAR;
      local $\ = undef if (defined $\);

      $_dat_ex->();
      print {$_DAT_W_SOCK} SHR_A_DEL.$LF . $_chn.$LF;
      print {$_DAU_W_SOCK} $_id.$LF . $_wa.$LF . $_[0].$LF;

      return $_do_ret->() if $_wa;
      $_dat_un->();
   }
}

sub CLEAR {                                       ## Array CLEAR
   my $_id = ${ reftype($_[0]) eq 'ARRAY' ? tied @{ $_[0] } : $_[0] };
   $_send_buf->(SHR_A_CLR, $_id.$LF);
}

sub POP {                                         ## Array POP
   my $_id = ${ reftype($_[0]) eq 'ARRAY' ? tied @{ $_[0] } : $_[0] };
   $_do_ret->(SHR_A_POP, $_id.$LF);
}

sub PUSH {                                        ## Array PUSH
   my $_id = ${ reftype($_[0]) eq 'ARRAY' ? tied @{ (shift) } : shift };

   if (scalar @_) {
      undef @_ if ($_send_ary->(SHR_A_PSH, $_id, @_));
   } else {
      Carp::carp('Useless use of push with no values');
   }
}

sub SHIFT {                                       ## Array SHIFT
   my $_id = ${ reftype($_[0]) eq 'ARRAY' ? tied @{ $_[0] } : $_[0] };
   $_do_ret->(SHR_A_SFT, $_id.$LF);
}

sub UNSHIFT {                                     ## Array UNSHIFT
   my $_id = ${ reftype($_[0]) eq 'ARRAY' ? tied @{ (shift) } : shift };

   if (scalar @_) {
      undef @_ if ($_send_ary->(SHR_A_UFT, $_id, @_));
   } else {
      Carp::carp('Useless use of unshift with no values');
   }
}

sub EXISTS {                                      ## Array EXISTS
   my $_id = ${ reftype($_[0]) eq 'ARRAY' ? tied @{ $_[0] } : $_[0] };
   $_recv_sca->(SHR_A_EXI, $_id.$LF . $_[1].$LF);
}

sub SPLICE {                                      ## Array SPLICE
   my $_id = ${ reftype($_[0]) eq 'ARRAY' ? tied @{ (shift) } : shift };

   $_wa = !defined wantarray ? WA_UNDEF : wantarray ? WA_ARRAY : WA_SCALAR;
   local $\ = undef if (defined $\);

   my $_tmp = freeze([ @_ ]);
   my $_buf = $_id.$LF . $_wa.$LF . length($_tmp).$LF . $_tmp;

   undef $_tmp, undef @_ if (length $_tmp > 65536);

   $_dat_ex->();
   print {$_DAT_W_SOCK} SHR_A_SPL.$LF . $_chn.$LF;
   print {$_DAU_W_SOCK} $_buf;

   unless ($_wa) {
      $_dat_un->();
   }
   elsif ($_wa == 1) {
      local $/ = $LF if (!$/ || $/ ne $LF);
      chomp($_len = <$_DAU_W_SOCK>);

      read $_DAU_W_SOCK, (my $_buf), $_len;
      $_dat_un->();

      chop $_buf; return @{ thaw($_buf) };
   }
   else {
      $_do_ret->();
   }
}

## ----------------------------------------------------------------------------
## Array private/public methods and aliases.

sub _export {
   my $_id = ${ reftype($_[0]) eq 'ARRAY' ? tied @{ (shift) } : shift };
   my $_exported = reftype($_[0]) eq 'HASH' ? shift : {};
   my $_copy; my @_keys = @_;

   return $_exported->{ $_id } if (exists $_exported->{ $_id });

   $_exported->{ $_id } = $_copy = [];
   @_keys = (0 .. @{ $_all->{ $_id } } - 1) unless @_keys;

   for my $_k (@_keys) {
      $_copy->[ $_k ] = (reftype($_all->{ $_id }->[ $_k ]))
         ? MCE::Shared::Server::_export($_exported, $_all->{ $_id }->[ $_k ])
         : $_all->{ $_id }->[ $_k ];
   }

   return $_copy;
}

sub Destroy {                                     ## Array Destroy/Export
   my $_id = ${ reftype($_[0]) eq 'ARRAY' ? tied @{ $_[0] } : $_[0] };
   my ($_data, $_wa);  ($_cache, $_flk) = ({}, {}) if $_is_client;

   if ($_wa = (defined wantarray)) {
      $_data = $_is_client ? Export(@_) : _export($_[0]);
   }

   MCE::Shared::Server::_destroy($_id);

   return $_wa ? $_data : ();
}
sub Export {
   my $_id = ${ reftype($_[0]) eq 'ARRAY' ? tied @{ (shift) } : shift };

   MCE::Shared::Server::_send({
      id => $_id, tag => SHR_M_EXP, type => 'ARRAY', keys => [ @_ ]
   });
}

sub Clone {                                       ## Array Clone
   my $_id = ${ reftype($_[0]) eq 'ARRAY' ? tied @{ (shift) } : shift };
   ($_recv_ary->(SHR_A_CLO, $_id, @_))[0];
}

sub Keys {                                        ## Array Keys/Values
   my $_id = ${ reftype($_[0]) eq 'ARRAY' ? tied @{ (shift) } : shift };
   wantarray
      ? $_recv_ary->(SHR_A_KEY, $_id, @_)
      : $_recv_sca->(SHR_A_FSZ, $_id.$LF);
}
sub Values {
   my $_id = ${ reftype($_[0]) eq 'ARRAY' ? tied @{ (shift) } : shift };
   wantarray
      ? $_recv_ary->(SHR_A_VAL, $_id, @_)
      : $_recv_sca->(SHR_A_FSZ, $_id.$LF);
}

{                                                 ## Array Aliases
   no strict 'refs';

   *{ __PACKAGE__.'::Store'   } = \&STORE;
   *{ __PACKAGE__.'::Set'     } = \&STORE;
   *{ __PACKAGE__.'::Fetch'   } = \&FETCH;
   *{ __PACKAGE__.'::Get'     } = \&FETCH;
   *{ __PACKAGE__.'::Delete'  } = \&DELETE;
   *{ __PACKAGE__.'::Del'     } = \&DELETE;
   *{ __PACKAGE__.'::Exists'  } = \&EXISTS;
   *{ __PACKAGE__.'::Clear'   } = \&CLEAR;
   *{ __PACKAGE__.'::Length'  } = \&FETCHSIZE;
   *{ __PACKAGE__.'::Pop'     } = \&POP;
   *{ __PACKAGE__.'::Push'    } = \&PUSH;
   *{ __PACKAGE__.'::Unshift' } = \&UNSHIFT;
   *{ __PACKAGE__.'::Splice'  } = \&SPLICE;
   *{ __PACKAGE__.'::Shift'   } = \&SHIFT;
}

###############################################################################
## ----------------------------------------------------------------------------
## File tie package.
##
###############################################################################

package MCE::Shared::File;

no warnings 'threads';
no warnings 'recursion';
no warnings 'uninitialized';

use Storable qw( freeze thaw );
use bytes;

our @CARP_NOT = qw( MCE::Shared MCE );

use constant {
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
};

sub _id { ${ $_[0] } }

sub TIEHANDLE { bless \$_[1] => $_[0] }
sub DESTROY {}

sub UNTIE {                                       ## File UNTIE
   my $_id = ${ tied ${ $_[0] } || $_[0] };

   return if (exists $_untie->{ $_id });
   $_untie->{ $_id } = 1;

   $_croak->("Method (UNTIE) is not allowed by the worker process")
      if ($INC{'MCE.pm'} && MCE->wid);

   undef $_all->{ $_id } if exists $_all->{ $_id };

   MCE::Shared::Server::_destroy($_id);

   return;
}

## ----------------------------------------------------------------------------
## File tie methods.

sub EOF {                                         ## File EOF/TELL/FILENO
   my $_id = ${ tied ${ $_[0] } || $_[0] };
   $_recv_sca->(SHR_F_EOF, $_id.$LF);
}
sub TELL {
   my $_id = ${ tied ${ $_[0] } || $_[0] };
   $_recv_sca->(SHR_F_TEL, $_id.$LF);
}
sub FILENO {
   my $_id = ${ tied ${ $_[0] } || $_[0] };
   $_recv_sca->(SHR_F_FNO, $_id.$LF);
}

sub SEEK {                                        ## File SEEK/CLOSE/BINMODE
   my $_id = ${ tied ${ $_[0] } || $_[0] };
   $_recv_sca->(SHR_F_SEE, $_id.$LF . $_[1].$LF . $_[2].$LF);
}
sub CLOSE {
   my $_id = ${ tied ${ $_[0] } || $_[0] };
   $_recv_sca->(SHR_F_CLO, $_id.$LF);
}
sub BINMODE {
   my $_id = ${ tied ${ $_[0] } || $_[0] };
   $_recv_sca->(SHR_F_BIN, $_id.$LF);
}

sub OPEN {                                        ## File OPEN
   my $_id = ${ tied ${ $_[0] } || $_[0] }; shift;
   my $_buf;

   local $\ = undef if (defined $\);
   local $/ = $LF if (!$/ || $/ ne $LF);

   if (ref $_[-1] && defined (my $_fd = fileno($_[-1]))) {
      my @_args = @_; pop @_args; $_args[-1] .= "&=$_fd";
      $_buf = freeze(\@_args);
   }
   else {
      $_buf = freeze(\@_);
   }

   $_dat_ex->();
   print {$_DAT_W_SOCK} SHR_F_OPN.$LF . $_chn.$LF;
   print {$_DAU_W_SOCK} $_id.$LF . length($_buf).$LF, $_buf;
   <$_DAU_W_SOCK>;

   $_dat_un->();

   return 1;
}

sub READ {                                        ## File READ
   my $_id = ${ tied ${ $_[0] } || $_[0] };

   local $\ = undef if (defined $\);
   local $/ = $LF if (!$/ || $/ ne $LF);

   $_dat_ex->();
   print {$_DAT_W_SOCK} SHR_F_REA.$LF . $_chn.$LF;
   print {$_DAU_W_SOCK} $_id.$LF . $_[2].$LF;

   chomp($_ret = <$_DAU_W_SOCK>);
   chomp($_len = <$_DAU_W_SOCK>);

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

   return $_ret;
}

sub READLINE {                                    ## File READLINE
   my $_id = ${ tied ${ $_[0] } || $_[0] };

   local $\ = undef if (defined $\);
   local $/ = $LF if (!$/ || $/ ne $LF);

   $_dat_ex->();
   print {$_DAT_W_SOCK} SHR_F_RLN.$LF . $_chn.$LF;
   print {$_DAU_W_SOCK} $_id.$LF . ($_[1] || 1).$LF;

   chomp($_ret = <$_DAU_W_SOCK>);
   chomp($_len = <$_DAU_W_SOCK>);
   read($_DAU_W_SOCK, my ($_buf), $_len) if $_len;
   $_dat_un->();

   $. = $_ret;
   return $_buf;
}

sub GETC {                                        ## File GETC
   my $_id = ${ tied ${ $_[0] } || $_[0] };

   local $\ = undef if (defined $\);
   local $/ = $LF if (!$/ || $/ ne $LF);

   $_dat_ex->();
   print {$_DAT_W_SOCK} SHR_F_GET.$LF . $_chn.$LF;
   print {$_DAU_W_SOCK} $_id.$LF;

   chomp($_len = <$_DAU_W_SOCK>);
   read($_DAU_W_SOCK, my ($_buf), $_len) if $_len;
   $_dat_un->();

   return $_buf;
}

sub PRINT {                                       ## File PRINT
   my $_id = ${ tied ${ $_[0] } || $_[0] }; shift;
   my $_ref;

   if (scalar @_ == 1  ) {
      $_ref = \$_[0];
   } elsif (scalar @_ > 1) {
      $_ref = \join('', @_);
   } else {
      $_ref = \$_;
   }

   if (length $$_ref) {
      $_dat_ex->();
      print {$_DAT_W_SOCK} SHR_F_PRI.$LF . $_chn.$LF;
      print {$_DAU_W_SOCK} $_id.$LF . length($$_ref).$LF, $$_ref;
      $_dat_un->();
   }

   return;
}

sub PRINTF {                                      ## File PRINTF
   my $_id = ${ tied ${ $_[0] } || $_[0] }; shift;

   my $_fmt = shift || '%s';
   my $_buf = (scalar @_) ? sprintf($_fmt, @_) : sprintf($_fmt, $_);

   if (length $_buf) {
      $_dat_ex->();
      print {$_DAT_W_SOCK} SHR_F_PRI.$LF . $_chn.$LF;
      print {$_DAU_W_SOCK} $_id.$LF . length($_buf).$LF, $_buf;
      $_dat_un->();
   }

   return;
}

sub WRITE {                                       ## File WRITE
   my $_id = ${ tied ${ $_[0] } || $_[0] }; shift;

   local $\ = undef if (defined $\);
   $_len = length $_[0];

   if (scalar @_ > 2 || ($_[1] && $_[1] != $_len)) {
      my $_buf = freeze(\@_);
      $_dat_ex->();
      print {$_DAT_W_SOCK} SHR_F_WRI.$LF . $_chn.$LF;
      print {$_DAU_W_SOCK} $_id.$LF . length($_buf).'1'.$LF, $_buf;
      $_dat_un->();
   }
   elsif ($_len) {
      $_dat_ex->();
      print {$_DAT_W_SOCK} SHR_F_WRI.$LF . $_chn.$LF;
      print {$_DAU_W_SOCK} $_id.$LF . $_len.'0'.$LF, $_[0];
      $_dat_un->();
   }

   return;
}

## ----------------------------------------------------------------------------
## File aliases.

{
   no strict 'refs';

   *{ __PACKAGE__.'::Tell'     } = \&TELL;
   *{ __PACKAGE__.'::Fileno'   } = \&FILENO;
   *{ __PACKAGE__.'::Seek'     } = \&SEEK;
   *{ __PACKAGE__.'::Close'    } = \&CLOSE;
   *{ __PACKAGE__.'::Binmode'  } = \&BINMODE;
   *{ __PACKAGE__.'::Open'     } = \&OPEN;
   *{ __PACKAGE__.'::Read'     } = \&READ;
   *{ __PACKAGE__.'::ReadLine' } = \&READLINE;
   *{ __PACKAGE__.'::Getc'     } = \&GETC;
   *{ __PACKAGE__.'::Print'    } = \&PRINT;
   *{ __PACKAGE__.'::Printf'   } = \&PRINTF;
   *{ __PACKAGE__.'::Write'    } = \&WRITE;
}

###############################################################################
## ----------------------------------------------------------------------------
## Hash tie package.
##
###############################################################################

package MCE::Shared::Hash;

no warnings 'threads';
no warnings 'recursion';
no warnings 'uninitialized';

use Scalar::Util qw( reftype );
use Storable qw( freeze thaw );
use bytes;

our @CARP_NOT = qw( MCE::Shared MCE );

use constant {
   SHR_M_EXP => 'M~EXP',   ## Export request
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
   WA_UNDEF  => 0,         ## Wants nothing
   WA_SCALAR => 2,         ## Wants scalar
};

use overload q("") => $_strify_h, q(0+) => $_numify, fallback => 1;

sub _id { ${ $_[0] } }

sub TIEHASH { bless \$_[1] => $_[0] }
sub DESTROY {}

sub UNTIE {                                       ## Hash UNTIE
   my $_id = ${ reftype($_[0]) eq 'HASH' ? tied %{ $_[0] } : $_[0] };

   return if (exists $_untie->{ $_id });
   $_untie->{ $_id } = 1;

   $_croak->("Method (UNTIE) is not allowed by the worker process")
      if ($INC{'MCE.pm'} && MCE->wid);

   if (exists $_all->{ $_id }) {
      for my $_k (keys %{ $_all->{ $_id } }) {
         MCE::Shared::Server::_untie($_all->{ $_id }->{ $_k });
      }
      %{ $_all->{ $_id } } = ();
   }

   MCE::Shared::Server::_destroy($_id);

   return;
}

## ----------------------------------------------------------------------------
## Hash tie methods.

sub STORE {                                       ## Hash STORE
   my $_id = ${ reftype($_[0]) eq 'HASH' ? tied %{ (shift) } : shift };
   my ($_tag, $_buf, $_tmp) = (SHR_H_STO);

   if (@_ > 2) {
      $_tag = SHR_H_ST2;
      $_tmp = freeze(\@_);
      $_buf = $_id.$LF . length($_tmp).$LF . $_tmp;
   }
   elsif (!defined $_[1]) {
      $_buf = $_id.$LF . length($_[0]).$LF . $_[0] . '-1'.$LF;
   }
   elsif ($_r = reftype($_[1])) {
      $_croak->("Unsupported ref type: $_r") unless (exists $_supp{ $_r });

      $_tmp = freeze($_[1]);
      $_buf = $_id.$LF . length($_[0]).$LF . $_[0] .
         (length($_tmp)+1).$LF . $_tmp.'1';

      if ($_is_older_perl) {
         my $_id = $_recv_sca->(SHR_H_STO, $_buf);
         return $_autovivify_hack->($_id, $_r, $_[1]);
      }
   }
   else {
      $_buf = $_id.$LF . length($_[0]).$LF . $_[0] .
         (length($_[1])+1).$LF . $_[1].'0';
   }

   $_send_buf->($_tag, $_buf);
}

sub FETCH {                                       ## Hash FETCH
   my $_id = ${ reftype($_[0]) eq 'HASH' ? tied %{ $_[0] } : $_[0] };

   if ($_is_client) {
      $_do_fetch->(SHR_H_FCH, $_id.$LF . length($_[1]).$LF . $_[1]);
   }
   else {
      $_all->{ $_id }->{ $_[1] };
   }
}

sub DELETE {                                      ## Hash DELETE
   my $_so = shift;
   my $_id = ${ reftype($_so) eq 'HASH' ? tied %{ $_so } : $_so };

   if (@_ > 1) {
      DELETE->($_so, $_) for (@_);
   }
   else {
      $_wa = (!defined wantarray) ? WA_UNDEF : WA_SCALAR;
      local $\ = undef if (defined $\);

      $_dat_ex->();
      print {$_DAT_W_SOCK} SHR_H_DEL.$LF . $_chn.$LF;
      print {$_DAU_W_SOCK} $_id.$LF . $_wa.$LF . length($_[0]).$LF . $_[0];

      return $_do_ret->() if $_wa;
      $_dat_un->();
   }
}

sub FIRSTKEY {                                    ## Hash FIRSTKEY
   my $_id = ${ reftype($_[0]) eq 'HASH' ? tied %{ $_[0] } : $_[0] };

   if ($_is_client) {
      local $\ = undef if (defined $\);
      local $/ = $LF if (!$/ || $/ ne $LF);

      $_dat_ex->();
      print {$_DAT_W_SOCK} SHR_H_FST.$LF . $_chn.$LF;
      print {$_DAU_W_SOCK} $_id.$LF;

      chomp($_len = <$_DAU_W_SOCK>);

      if ($_len < 0) {
         $_dat_un->();
         return undef;
      }

      read $_DAU_W_SOCK, (my $_buf), $_len;
      $_dat_un->();

      @{ $_cache->{ $_id } } = @{ thaw($_buf) };  ## Cache keys locally

      shift @{ $_cache->{ $_id } };
   }
   else {
      my $_a = keys %{ $_all->{ $_id } };
      each %{ $_all->{ $_id } };
   }
}

sub NEXTKEY {                                     ## Hash NEXTKEY
   my $_id = ${ reftype($_[0]) eq 'HASH' ? tied %{ $_[0] } : $_[0] };

   if ($_is_client) {
      my $_ret = shift @{ $_cache->{ $_id } };
      delete $_cache->{ $_id } unless (defined $_ret);
      $_ret;
   }
   else {
      each %{ $_all->{ $_id } };
   }
}

sub EXISTS {                                      ## Hash EXISTS
   my $_id = ${ reftype($_[0]) eq 'HASH' ? tied %{ $_[0] } : $_[0] };

   local $\ = undef if (defined $\);
   local $/ = $LF if (!$/ || $/ ne $LF);

   $_dat_ex->();
   print {$_DAT_W_SOCK} SHR_H_EXI.$LF . $_chn.$LF;
   print {$_DAU_W_SOCK} $_id.$LF . length($_[1]).$LF . $_[1];

   chomp($_ret = <$_DAU_W_SOCK>);
   $_dat_un->();

   $_ret;
}

sub CLEAR {                                       ## Hash CLEAR
   my $_id = ${ reftype($_[0]) eq 'HASH' ? tied %{ $_[0] } : $_[0] };
   $_send_buf->(SHR_H_CLR, $_id.$LF);
}

sub SCALAR {                                      ## Hash SCALAR
   my $_id = ${ reftype($_[0]) eq 'HASH' ? tied %{ $_[0] } : $_[0] };
   $_recv_sca->(SHR_H_SCA, $_id.$LF);
}

## ----------------------------------------------------------------------------
## Hash private/public methods and aliases.

sub _export {
   my $_id = ${ reftype($_[0]) eq 'HASH' ? tied %{ (shift) } : shift };
   my $_exported = reftype($_[0]) eq 'HASH' ? shift : {};
   my $_copy; my @_keys = @_;

   return $_exported->{ $_id } if (exists $_exported->{ $_id });

   $_exported->{ $_id } = $_copy = {};
   @_keys = keys %{ $_all->{ $_id } } unless @_keys;

   for my $_k (@_keys) {
      $_copy->{ $_k } = (reftype($_all->{ $_id }->{ $_k }))
         ? MCE::Shared::Server::_export($_exported, $_all->{ $_id }->{ $_k })
         : $_all->{ $_id }->{ $_k };
   }

   return $_copy;
}

sub Destroy {                                     ## Hash Destroy/Export
   my $_id = ${ reftype($_[0]) eq 'HASH' ? tied %{ $_[0] } : $_[0] };
   my ($_data, $_wa);  ($_cache, $_flk) = ({}, {}) if $_is_client;

   if ($_wa = (defined wantarray)) {
      $_data = $_is_client ? Export(@_) : _export($_[0]);
   }

   MCE::Shared::Server::_destroy($_id);

   return $_wa ? $_data : ();
}
sub Export {
   my $_id = ${ reftype($_[0]) eq 'HASH' ? tied %{ (shift) } : shift };

   MCE::Shared::Server::_send({
      id => $_id, tag => SHR_M_EXP, type => 'HASH', keys => [ @_ ]
   });
}

sub Clone {                                       ## Hash Clone
   my $_id = ${ reftype($_[0]) eq 'HASH' ? tied %{ (shift) } : shift };
   ($_recv_ary->(SHR_H_CLO, $_id, @_))[0];
}

sub Keys {                                        ## Hash Keys/Values
   my $_id = ${ reftype($_[0]) eq 'HASH' ? tied %{ (shift) } : shift };
   wantarray
      ? $_recv_ary->(SHR_H_KEY, $_id, @_)
      : $_recv_sca->(SHR_H_SCA, $_id.$LF);
}
sub Values {
   my $_id = ${ reftype($_[0]) eq 'HASH' ? tied %{ (shift) } : shift };
   wantarray
      ? $_recv_ary->(SHR_H_VAL, $_id, @_)
      : $_recv_sca->(SHR_H_SCA, $_id.$LF);
}

{                                                 ## Hash Aliases
   no strict 'refs';

   *{ __PACKAGE__.'::Store'    } = \&STORE;
   *{ __PACKAGE__.'::Set'      } = \&STORE;
   *{ __PACKAGE__.'::Fetch'    } = \&FETCH;
   *{ __PACKAGE__.'::Get'      } = \&FETCH;
   *{ __PACKAGE__.'::Delete'   } = \&DELETE;
   *{ __PACKAGE__.'::Del'      } = \&DELETE;
   *{ __PACKAGE__.'::FirstKey' } = \&FIRSTKEY;
   *{ __PACKAGE__.'::NextKey'  } = \&NEXTKEY;
   *{ __PACKAGE__.'::Exists'   } = \&EXISTS;
   *{ __PACKAGE__.'::Clear'    } = \&CLEAR;
   *{ __PACKAGE__.'::Length'   } = \&SCALAR;
}

###############################################################################
## ----------------------------------------------------------------------------
## Scalar tie package.
##
###############################################################################

package MCE::Shared::Scalar;

no warnings 'threads';
no warnings 'recursion';
no warnings 'uninitialized';

use Scalar::Util qw( reftype );
use Storable qw( freeze thaw );
use bytes;

our @CARP_NOT = qw( MCE::Shared MCE );

use constant {
   SHR_M_EXP => 'M~EXP',   ## Export request
   SHR_S_STO => 'S~STO',   ## Scalar STORE
   SHR_S_FCH => 'S~FCH',   ## Scalar FETCH
   SHR_S_LEN => 'S~LEN',   ## Scalar Length
};

use overload q("") => $_strify_s, q(0+) => $_numify, fallback => 1;

sub _id { ${ $_[0] } }

sub TIESCALAR { bless \$_[1] => $_[0] }
sub DESTROY {}

sub UNTIE {                                       ## Scalar UNTIE
   my $_id = ${ tied ${ $_[0] } || $_[0] };

   return if (exists $_untie->{ $_id });
   $_untie->{ $_id } = 1;

   $_croak->("Method (UNTIE) is not allowed by the worker process")
      if ($INC{'MCE.pm'} && MCE->wid);

   if (exists $_all->{ $_id }) {
      MCE::Shared::Server::_untie(${ $_all->{ $_id } });
      undef ${ $_all->{ $_id } };
   }

   MCE::Shared::Server::_destroy($_id);

   return;
}

## ----------------------------------------------------------------------------
## Scalar tie methods.

sub STORE {                                       ## Scalar STORE
   my $_id = ${ tied ${ $_[0] } || $_[0] };
   my ($_buf, $_tmp);

   if (!defined $_[1]) {
      $_buf = $_id.$LF . '-1'.$LF;
   }
   elsif ($_r = reftype($_[1])) {
      $_croak->("Unsupported ref type: $_r") unless (exists $_supp{ $_r });

      $_tmp = freeze($_[1]);
      $_buf = $_id.$LF . (length($_tmp)+1).$LF . $_tmp.'1';

      if ($_is_older_perl) {
         my $_id = $_recv_sca->(SHR_S_STO, $_buf);
         return $_autovivify_hack->($_id, $_r, $_[1]);
      }
   }
   else {
      $_buf = $_id.$LF . (length($_[1])+1).$LF . $_[1].'0';
   }

   $_send_buf->(SHR_S_STO, $_buf);
}

sub FETCH {                                       ## Scalar FETCH
   my $_id = ${ tied ${ $_[0] } || $_[0] };

   if ($_is_client) {
      $_do_ret->(SHR_S_FCH, $_id.$LF);
   } else {
      ${ $_all->{ $_id } };
   }
}

## ----------------------------------------------------------------------------
## Scalar private/public methods and aliases.

sub _export {
   my $_id = ${ tied ${ $_[0] } || $_[0] }; shift;
   my $_copy; my $_exported = reftype($_[0]) eq 'HASH' ? shift : {};

   return $_exported->{ $_id } if (exists $_exported->{ $_id });

   if (exists $_obj->{ $_id }) {
      $_copy = $_obj->{ $_id };
   }
   elsif (my $_rtype = reftype(${ $_all->{ $_id } })) {
      $_copy = ($_rtype ne 'REF')
         ? MCE::Shared::Server::_export($_exported, ${ $_all->{ $_id } })
         : \$_copy;
   }
   else {
      $_copy = \do{ my $scalar = undef };
      ${ $_copy } = ${ $_all->{ $_id } };
   }

   return $_exported->{ $_id } = $_copy;
}

sub Destroy {                                     ## Scalar Destroy/Export
   my $_id = ${ tied ${ $_[0] } || $_[0] };
   my ($_data, $_wa);  ($_cache, $_flk) = ({}, {}) if $_is_client;

   if ($_wa = (defined wantarray)) {
      $_data = $_is_client ? Export(@_) : _export($_[0]);
   }

   MCE::Shared::Server::_destroy($_id);

   return $_wa ? $_data : ();
}
sub Export {
   my $_id = ${ tied ${ $_[0] } || $_[0] }; shift;

   MCE::Shared::Server::_send({
      id => $_id, tag => SHR_M_EXP, type => 'SCALAR', keys => [ @_ ]
   });
}

sub Length {                                      ## Scalar Length
   my $_id = ${ tied ${ $_[0] } || $_[0] };
   $_recv_sca->(SHR_S_LEN, $_id.$LF);
}

{                                                 ## Scalar Aliases
   no strict 'refs';

   *{ __PACKAGE__.'::Store' } = \&STORE;
   *{ __PACKAGE__.'::Set'   } = \&STORE;
   *{ __PACKAGE__.'::Fetch' } = \&FETCH;
   *{ __PACKAGE__.'::Get'   } = \&FETCH;
}

1;

