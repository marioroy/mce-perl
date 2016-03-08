###############################################################################
## ----------------------------------------------------------------------------
## MCE extension for sharing objects and data between workers.
##
###############################################################################

package MCE::Shared;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized );

our $VERSION = '1.700';

## no critic (BuiltinFunctions::ProhibitStringyEval)

use Scalar::Util qw( blessed refaddr );
use MCE::Shared::Server;

our @CARP_NOT = qw(
   MCE::Shared::Array   MCE::Shared::Condvar  MCE::Shared::Handle
   MCE::Shared::Hash    MCE::Shared::Minidb   MCE::Shared::Ordhash
   MCE::Shared::Queue   MCE::Shared::Scalar   MCE::Shared::Sequence

   MCE::Shared::Server  MCE::Shared::Object
);

my $_imported;

sub import {
   my $_class = shift;
   return if $_imported++;

   while ( my $_argument = shift ) {
      if ( lc $_argument eq 'sereal' ) {
         MCE::Shared::Server::_use_sereal() if (shift eq '1');
         next;
      }
      _croak("Error: ($_argument) invalid module option");
   }

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Share function.
##
###############################################################################

my ($_count, %_lkup) = (0);

sub share {
   shift if (defined $_[0] && $_[0] eq 'MCE::Shared');

   my $_params = ref $_[0] eq 'HASH' && ref $_[1] ? shift : {};
   my ($_class, $_ra, $_item) = (blessed($_[0]), refaddr($_[0]));

   # safety for circular references to not loop endlessly
   return $_lkup{ $_ra } if defined $_ra && exists $_lkup{ $_ra };

   $_count++;

   # blessed object, \@array, \%hash, or \$scalar
   if ( $_class ) {
      _incr_count($_[0]), return $_[0] if $_[0]->can('SHARED_ID');

      _croak("Running MCE::Queue via MCE::Shared is not supported.\n",
             "A shared queue is possible via MCE::Shared->queue().\n\n")
         if ($_class eq 'MCE::Queue');

      $_params->{'class'} = $_class;
      $_item = MCE::Shared::Server::_new($_params, $_[0]);
   }
   elsif ( ref $_[0] eq 'ARRAY' ) {
      if ( tied(@{ $_[0] }) && tied(@{ $_[0] })->can('SHARED_ID') ) {
         _incr_count(tied(@{ $_[0] })), return tied(@{ $_[0] });
      }
      $_item = $_lkup{ $_ra } = MCE::Shared->array($_params, @{ $_[0] });
      @{ $_[0] } = ();  tie @{ $_[0] }, 'MCE::Shared::Object', $_item;
   }
   elsif ( ref $_[0] eq 'HASH' ) {
      if ( tied(%{ $_[0] }) && tied(%{ $_[0] })->can('SHARED_ID') ) {
         _incr_count(tied(%{ $_[0] })), return tied(%{ $_[0] });
      }
      $_item = $_lkup{ $_ra } = MCE::Shared->hash($_params, %{ $_[0] });
      %{ $_[0] } = ();  tie %{ $_[0] }, 'MCE::Shared::Object', $_item;
   }
   elsif ( ref $_[0] eq 'SCALAR' && !ref ${ $_[0] } ) {
      if ( tied(${ $_[0] }) && tied(${ $_[0] })->can('SHARED_ID') ) {
         _incr_count(tied(${ $_[0] })), return tied(${ $_[0] });
      }
      $_item = $_lkup{ $_ra } = MCE::Shared->scalar($_params, ${ $_[0] });
      undef ${ $_[0] }; tie ${ $_[0] }, 'MCE::Shared::Object', $_item;
   }

   # synopsis
   elsif ( ref $_[0] eq 'REF' ) {
      _croak('A "REF" type is not supported');
   }
   else {
      if ( ref $_[0] eq 'GLOB' ) {
         _incr_count(tied(*{ $_[0] })), return $_[0] if (
            tied(*{ $_[0] }) && tied(*{ $_[0] })->can('SHARED_ID')
         );
      }
      _croak('Synopsis: blessed object, \@array, \%hash, or \$scalar');
   }

   %_lkup = () unless --$_count;

   $_item;
}

###############################################################################
## ----------------------------------------------------------------------------
## Public functions.
##
###############################################################################

sub start { MCE::Shared::Server::_start() }
sub stop  { MCE::Shared::Server::_stop()  }
sub init  { MCE::Shared::Object::_init()  }

sub condvar {
   shift if ( defined $_[0] && $_[0] eq 'MCE::Shared' );
   require MCE::Shared::Condvar unless $INC{'MCE/Shared/Condvar.pm'};
   &share( MCE::Shared::Condvar->new(@_) );
}
sub minidb {
   shift if ( defined $_[0] && $_[0] eq 'MCE::Shared' );
   require MCE::Shared::Minidb unless $INC{'MCE/Shared/Minidb.pm'};
   &share( MCE::Shared::Minidb->new(@_) );
}
sub queue {
   shift if ( defined $_[0] && $_[0] eq 'MCE::Shared' );
   require MCE::Shared::Queue unless $INC{'MCE/Shared/Queue.pm'};
   &share( MCE::Shared::Queue->new(@_) );
}
sub scalar {
   shift if ( defined $_[0] && $_[0] eq 'MCE::Shared' );
   require MCE::Shared::Scalar unless $INC{'MCE/Shared/Scalar.pm'};
   &share( MCE::Shared::Scalar->new(@_) );
}
sub sequence {
   shift if ( defined $_[0] && $_[0] eq 'MCE::Shared' );
   require MCE::Shared::Sequence unless $INC{'MCE/Shared/Sequence.pm'};
   &share( MCE::Shared::Sequence->new(@_) );
}

## 'num_sequence' is an alias for 'sequence'
*num_sequence = \&sequence;

sub array {
   shift if ( defined $_[0] && $_[0] eq 'MCE::Shared' );
   require MCE::Shared::Array unless $INC{'MCE/Shared/Array.pm'};

   my $_params = ref $_[0] eq 'HASH' ? shift : {};
   my $_item   = &share($_params, MCE::Shared::Array->new());

   if ( scalar @_ ) {
      if ( $_params->{_DEEPLY_} ) {
         for ( my $i = 0; $i <= $#_; $i += 1 ) {
            &_share($_params, $_item, $_[$i]) if ref($_[$i]);
         }
      }
      $_item->push(@_);
   }

   $_item;
}

sub handle {
   shift if ( defined $_[0] && $_[0] eq 'MCE::Shared' );
   require MCE::Shared::Handle unless $INC{'MCE/Shared/Handle.pm'};

   my $_item = &share( MCE::Shared::Handle->TIEHANDLE([]) );
   my $_fh   = \do { local *HANDLE };

   tie *{ $_fh }, 'MCE::Shared::Object', $_item;
   $_item->OPEN(@_) if @_;

   $_fh;
}

sub hash {
   shift if ( defined $_[0] && $_[0] eq 'MCE::Shared' );
   require MCE::Shared::Hash unless $INC{'MCE/Shared/Hash.pm'};

   my $_params = ref $_[0] eq 'HASH' ? shift : {};
   my $_item   = &share($_params, MCE::Shared::Hash->new());

   &_deeply_share_h($_params, $_item, @_) if @_;

   $_item;
}

sub ordhash {
   shift if ( defined $_[0] && $_[0] eq 'MCE::Shared' );
   require MCE::Shared::Ordhash unless $INC{'MCE/Shared/Ordhash.pm'};

   my $_params = ref $_[0] eq 'HASH' ? shift : {};
   my $_item   = &share($_params, MCE::Shared::Ordhash->new());

   &_deeply_share_h($_params, $_item, @_) if @_;

   $_item;
}

###############################################################################
## ----------------------------------------------------------------------------
## PDL sharing -- construction takes place under the shared server-process.
##
###############################################################################

if ( $INC{'PDL.pm'} ) {
   local $@; eval q{

      sub pdl_byte     { push @_, 'byte';     goto &_pdl_share }
      sub pdl_short    { push @_, 'short';    goto &_pdl_share }
      sub pdl_ushort   { push @_, 'ushort';   goto &_pdl_share }
      sub pdl_long     { push @_, 'long';     goto &_pdl_share }
      sub pdl_longlong { push @_, 'longlong'; goto &_pdl_share }
      sub pdl_float    { push @_, 'float';    goto &_pdl_share }
      sub pdl_double   { push @_, 'double';   goto &_pdl_share }
      sub pdl_ones     { push @_, 'ones';     goto &_pdl_share }
      sub pdl_sequence { push @_, 'sequence'; goto &_pdl_share }
      sub pdl_zeroes   { push @_, 'zeroes';   goto &_pdl_share }
      sub pdl_indx     { push @_, 'indx';     goto &_pdl_share }
      sub pdl          { push @_, 'pdl';      goto &_pdl_share }

      sub _pdl_share {
         shift if ( defined $_[0] && $_[0] eq 'MCE::Shared' );
         MCE::Shared::Server::_new({ 'class' => ':construct_pdl:' }, [ @_ ]);
      }
   };
}

###############################################################################
## ----------------------------------------------------------------------------
## Private functions.
##
###############################################################################

sub TIEARRAY  { shift; MCE::Shared->array(@_) }
sub TIESCALAR { shift; MCE::Shared->scalar(@_) }

sub TIEHASH {
   shift;
   my $_ordered = ( ref $_[0] eq 'HASH' && exists $_[0]->{'ordered'} )
      ? shift()->{'ordered'}
      : 0;
   ( $_ordered )
      ? MCE::Shared->ordhash(@_)
      : MCE::Shared->hash(@_);
}

sub TIEHANDLE {
   require MCE::Shared::Handle unless $INC{'MCE/Shared/Handle.pm'};
   my $_item = &share( MCE::Shared::Handle->TIEHANDLE([]) ); shift;
   $_item->OPEN(@_) if @_;
   $_item;
}

sub _croak {
   $_count = 0, %_lkup = ();
   if ( defined $MCE::VERSION ) {
      goto &MCE::_croak;
   } else {
      require MCE::Shared::Base unless $INC{'MCE/Shared/Base.pm'};
      goto &MCE::Shared::Base::_croak;
   }
}

sub _deeply_share_h {
   my ( $_params, $_item ) = ( shift, shift );
   if ( $_params->{_DEEPLY_} ) {
      for ( my $i = 1; $i <= $#_; $i += 2 ) {
         &_share($_params, $_item, $_[$i]) if ref($_[$i]);
      }
   }
   $_item->mset(@_);
   return;
}

sub _incr_count {
   # increments counter for safety during destroy
   MCE::Shared::Server::_incr_count($_[0]->SHARED_ID);
}

sub _share {
   $_[2] = &share($_[0], $_[2]);
   MCE::Shared::Object::_req2(
      'M~DEE', $_[1]->SHARED_ID()."\n", $_[2]->SHARED_ID()."\n"
   );
}

1;

__END__

###############################################################################
## ----------------------------------------------------------------------------
## Module usage.
##
###############################################################################

=head1 NAME

MCE::Shared - MCE extension for sharing data between workers

=head1 VERSION

This document describes MCE::Shared version 1.700

=head1 SYNOPSIS

   # OO construction

   use MCE::Shared;

   my $ar = MCE::Shared->array( @list );
   my $cv = MCE::Shared->condvar( 0 );
   my $fh = MCE::Shared->handle( '>>', \*STDOUT );
   my $ha = MCE::Shared->hash( @pairs );
   my $oh = MCE::Shared->ordhash( @pairs );
   my $db = MCE::Shared->minidb();
   my $qu = MCE::Shared->queue( await => 1, fast => 0 );
   my $va = MCE::Shared->scalar( $value );
   my $se = MCE::Shared->sequence( $begin, $end, $step, $fmt );
   my $ob = MCE::Shared->share( $blessed_object );

   # Tie construction

   use feature 'say';

   use MCE::Flow;
   use MCE::Shared;

   tie my $var, 'MCE::Shared', 'initial value';
   tie my @ary, 'MCE::Shared', qw( a list of values );
   tie my %ha,  'MCE::Shared', ( key1 => 'value', key2 => 'value' );
   tie my %oh,  'MCE::Shared', { ordered => 1 }, ( key1 => 'value' );

   tie my $cnt, 'MCE::Shared', 0;
   tie my @foo, 'MCE::Shared';
   tie my %bar, 'MCE::Shared';

   my $m1 = MCE::Mutex->new;

   mce_flow {
      max_workers => 4
   },
   sub {
      my ( $mce ) = @_;
      my ( $pid, $wid ) = ( MCE->pid, MCE->wid );

      ## Locking is required when multiple workers update the same element.
      ## This requires 2 trips to the manager process (fetch and store).

      $m1->synchronize( sub {
         $cnt += 1;
      });

      ## Locking is not necessary when updating unique elements.

      $foo[ $wid - 1 ] = $pid;
      $bar{ $pid }     = $wid;

      return;
   };

   say "scalar : $cnt";
   say " array : $_" for (@foo);
   say "  hash : $_ => $bar{$_}" for (sort keys %bar);

   # Output

   scalar : 4
    array : 37847
    array : 37848
    array : 37849
    array : 37850
     hash : 37847 => 1
     hash : 37848 => 2
     hash : 37849 => 3
     hash : 37850 => 4

=head1 DESCRIPTION

This module provides data sharing for MCE supporting threads and processes.

C<MCE::Shared> enables extra functionality on systems with C<IO::FDPass>.
Without it, MCE::Shared is unable to send file descriptors to the
shared-manager process for C<queue>, C<condvar>, and possibly C<handle>.

As of this writing, the L<IO::FDPass> module is not a requirement for running
C<MCE::Shared> nor is the check made during installation. The reason is that
C<IO::FDPass> is not possible on Cygwin and not sure on AIX.

The following is a suggestion for systems without C<IO::FDPass>.
This restriction applies to C<queue>, C<condvar>, and C<handle> only.

   use MCE::Shared;

   # Construct shared queue(s) and condvar(s) first.
   # These contain GLOB handles - freezing not allowed.

   my $q1  = MCE::Shared->queue();
   my $q2  = MCE::Shared->queue();

   my $cv1 = MCE::Shared->condvar();
   my $cv2 = MCE::Shared->condvar();

   # Start the shared-manager manually.

   MCE::Shared->start();

   # The shared-manager process knows of STDOUT, STDERR, STDIN

   my $fh1 = MCE::Shared->handle(">>", \*STDOUT);  # ok
   my $fh2 = MCE::Shared->handle("<", "/path/to/sequence.fasta");  # ok
   my $h1  = MCE::Shared->hash();

Otherwise, sharing is immediate and not delayed with C<IO::FDPass>. It is not
necessary to share C<queue> and C<condvar> first or worry about starting the
shared-manager process.

   use MCE::Shared;

   my $h1 = MCE::Shared->hash();    # shares immediately
   my $q1 = MCE::Shared->queue();   # IO::FDPass sends file descriptors
   my $cv = MCE::Shared->condvar(); # IO::FDPass sends file descriptors
   my $h2 = MCE::Shared->ordhash();

=head1 DATA SHARING

=over 3

=item * array

=item * condvar

=item * handle

=item * hash

=item * minidb

=item * ordhash

=item * queue

=item * scalar

=item * sequence

=back

C<array>, C<condvar>, C<handle>, C<hash>, C<minidb>, C<ordhash>, C<queue>,
C<scalar>, and C<sequence> are sugar syntax for constructing a
shared object.

  # long form

  use MCE::Shared;

  use MCE::Shared::Array;
  use MCE::Shared::Hash;
  use MCE::Shared::OrdHash;
  use MCE::Shared::Minidb;
  use MCE::Shared::Queue;
  use MCE::Shared::Scalar;

  my $ar = MCE::Shared->share( MCE::Shared::Array->new() );
  my $ha = MCE::Shared->share( MCE::Shared::Hash->new() );
  my $oh = MCE::Shared->share( MCE::Shared::Ordhash->new() );
  my $db = MCE::Shared->share( MCE::Shared::Minidb->new() );
  my $qu = MCE::Shared->share( MCE::Shared::Queue->new() );
  my $va = MCE::Shared->share( MCE::Shared::Scalar->new() );

  # short form

  use MCE::Shared;

  my $ar = MCE::Shared->array( @list );
  my $cv = MCE::Shared->condvar( 0 );
  my $fh = MCE::Shared->handle( '>>', \*STDOUT );
  my $ha = MCE::Shared->hash( @pairs );
  my $oh = MCE::Shared->ordhash( @pairs );
  my $db = MCE::Shared->minidb();
  my $qu = MCE::Shared->queue( await => 1, fast => 0 );
  my $va = MCE::Shared->scalar( $value );
  my $se = MCE::Shared->sequence( $begin, $end, $step, $fmt );

=over 3

=item num_sequence

C<num_sequence> is an alias for C<sequence>.

=back

=head1 DEEPLY SHARING

The following is a demonstration for a shared tied-hash variable. Before
venturing into the actual code, notice the dump function making a call to
C<export> explicitly for objects of type C<MCE::Shared::Object>. This is
necessary in order to retrieve the data from the shared-manager process.

The C<export> method is described later on under the Common API section.

   sub _dump {
      require Data::Dumper unless $INC{'Data/Dumper.pm'};
      no warnings 'once';

      local $Data::Dumper::Varname  = 'VAR';
      local $Data::Dumper::Deepcopy = 1;
      local $Data::Dumper::Indent   = 1;
      local $Data::Dumper::Purity   = 1;
      local $Data::Dumper::Sortkeys = 0;
      local $Data::Dumper::Terse    = 0;

      ( ref $_[0] eq 'MCE::Shared::Object' )
         ? print Data::Dumper::Dumper( $_[0]->export ) . "\n"
         : print Data::Dumper::Dumper( $_[0] ) . "\n";
   }

   use MCE::Shared;

   tie my %abc, 'MCE::Shared';

   my @parents = qw( a b c );
   my @children = qw( 1 2 3 4 );

   for my $parent ( @parents ) {
      for my $child ( @children ) {
         $abc{ $parent }{ $child } = 1;
      }
   }

   _dump( tied( %abc ) );

   # Output

   $VAR1 = bless( {
     'c' => bless( {
       '1' => '1',
       '4' => '1',
       '3' => '1',
       '2' => '1'
     }, 'MCE::Shared::Hash' ),
     'a' => bless( {
       '1' => '1',
       '4' => '1',
       '3' => '1',
       '2' => '1'
     }, 'MCE::Shared::Hash' ),
     'b' => bless( {
       '1' => '1',
       '4' => '1',
       '3' => '1',
       '2' => '1'
     }, 'MCE::Shared::Hash' )
   }, 'MCE::Shared::Hash' );

Dereferencing provides hash-like behavior for C<hash> and C<ordhash>.
Array-like behavior is allowed for C<array>, not shown below.

   use MCE::Shared;

   my $abc = MCE::Shared->hash;

   my @parents = qw( a b c );
   my @children = qw( 1 2 3 4 );

   for my $parent ( @parents ) {
      for my $child ( @children ) {
         $abc->{ $parent }{ $child } = 1;
      }
   }

   _dump( $abc );

Each level in a deeply structure requires a separate trip to the shared-manager
process. The included C<MCE::Shared::Minidb> module provides optimized methods
for working with hash of hashes C<HoH> and/or hash of arrays C<HoA>. As such,
do the following when performance is desired.

   use MCE::Shared;

   my $abc = MCE::Shared->minidb;

   my @parents = qw( a b c );
   my @children = qw( 1 2 3 4 );

   for my $parent ( @parents ) {
      for my $child ( @children ) {
         $abc->hset( $parent, $child, 1 );
      }
   }

   _dump( $abc );

For further reading, see L<MCE::Shared::Minidb>.

=head1 OBJECT SHARING

=over 3

=item share

This class method transfers the blessed-object to the shared-manager
process and returns a C<MCE::Shared::Object> containing the C<SHARED_ID>.
The object must not contain any C<GLOB>'s or C<CODE_REF>'s or the transfer
will fail.

Unlike with C<threads::shared>, objects are not deeply shared. The shared
object is accessible only through the OO interface.

   use MCE::Shared;
   use Hash::Ordered;

   my ($ho_shared, $ho_nonshared);

   $ho_shared = MCE::Shared->share( Hash::Ordered->new() );

   $ho_shared->push( @pairs );             # OO interface only
   $ho_shared->mset( @pairs );

   $ho_nonshared = $ho_shared->export();   # back to non-shared
   $ho_nonshared = $ho_shared->destroy();  # including destruction

The following provides long and short forms for constructing a shared array,
hash, or scalar object.

   use MCE::Shared;

   use MCE::Shared::Array;    # Loading helper classes is not necessary
   use MCE::Shared::Hash;     # when using the shorter form.
   use MCE::Shared::Scalar;

   my $a1 = MCE::Shared->share( MCE::Shared::Array->new( @list ) );
   my $a3 = MCE::Shared->share( [ @list ] );  # sugar syntax
   my $a2 = MCE::Shared->array( @list );

   my $h1 = MCE::Shared->share( MCE::Shared::Hash->new( @pairs ) );
   my $h3 = MCE::Shared->share( { @pairs } ); # sugar syntax
   my $h2 = MCE::Shared->hash( @pairs );

   my $s1 = MCE::Shared->share( MCE::Shared::Scalar->new( 20 ) );
   my $s2 = MCE::Shared->share( \do{ my $o = 20 } );
   my $s4 = MCE::Shared->scalar( 20 );

=back

=head1 PDL SHARING

=over 3

=item * pdl_byte

=item * pdl_short

=item * pdl_ushort

=item * pdl_long

=item * pdl_longlong

=item * pdl_float

=item * pdl_double

=item * pdl_ones

=item * pdl_sequence

=item * pdl_zeroes

=item * pdl_indx

=item * pdl

=back

C<pdl_byte>, C<pdl_short>, C<pdl_ushort>, C<pdl_long>, C<pdl_longlong>,
C<pdl_float>, C<pdl_double>, C<pdl_ones>, C<pdl_sequence>, C<pdl_zeroes>,
C<pdl_indx>, and C<pdl> are sugar syntax for PDL construction take place
under the shared-manager process.

   use PDL;
   use PDL::IO::Storable;   # must load for freezing/thawing

   use MCE::Shared;         # must load MCE::Shared after PDL
   
   # not efficient from memory copy/transfer and unnecessary destruction
   my $ob1 = MCE::Shared->share( zeroes( 256, 256 ) );

   # efficient
   my $ob1 = MCE::Shared->zeroes( 256, 256 );

=over 3

=item ins_inplace

The C<ins_inplace> method applies to shared PDL objects. It supports two forms
for writing bits back into the PDL object residing under the shared-manager
process.

   # --- action taken by the shared-manager process
   # ins_inplace(  2 args ):   $this->slice( $arg1 ) .= $arg2;
   # ins_inplace( >2 args ):   ins( inplace( $this ), $what, @coords );

   # --- use case
   $o->ins_inplace( ":,$start:$stop", $result );  #  2 args
   $o->ins_inplace( $result, 0, $seq_n );         # >2 args

For further reading, the MCE-Cookbook on Github provides a couple PDL
demonstrations.

L<https://github.com/marioroy/mce-cookbook>

=back

=head1 COMMON API

=over 3

=item blessed

Returns the real C<blessed> name, provided by the shared-manager process.

   use Scalar::Util qw(blessed);
   use MCE::Shared;

   use MCE::Shared::Ordhash;
   use Hash::Ordered;

   my $oh1 = MCE::Shared->share( MCE::Shared::Ordhash->new() );
   my $oh2 = MCE::Shared->share( Hash::Ordered->new() );

   print blessed($oh1), "\n";    # MCE::Shared::Object
   print blessed($oh2), "\n";    # MCE::Shared::Object

   print $oh1->blessed(), "\n";  # MCE::Shared::Ordhash
   print $oh2->blessed(), "\n";  # Hash::Ordered

=item destroy

Exports optionally, but destroys the shared object entirely from the
shared-manager process.

   my $exported_ob = $shared_ob->destroy();

   $shared_ob; # becomes undef

=item export ( keys )

=item export

Exports the shared object as a non-shared object. One must export when passing
the object into any dump routine. Otherwise, the C<shared_id value> and
C<blessed name> is all one will see.

   use MCE::Shared;
   use MCE::Shared::Ordhash;

   sub _dump {
      require Data::Dumper unless $INC{'Data/Dumper.pm'};
      no warnings 'once';

      local $Data::Dumper::Varname  = 'VAR';
      local $Data::Dumper::Deepcopy = 1;
      local $Data::Dumper::Indent   = 1;
      local $Data::Dumper::Purity   = 1;
      local $Data::Dumper::Sortkeys = 0;
      local $Data::Dumper::Terse    = 0;

      print Data::Dumper::Dumper($_[0]) . "\n";
   }

   my $oh1 = MCE::Shared->share( MCE::Shared::Ordhash->new() );
   my $oh2 = MCE::Shared->ordhash();  # same thing

   _dump($oh1);
      # bless( [ 1, 'MCE::Shared::Ordhash' ], 'MCE::Shared::Object' )

   _dump($oh2);
      # bless( [ 2, 'MCE::Shared::Ordhash' ], 'MCE::Shared::Object' )

   _dump( $oh1->export );  # dumps object structure and content
   _dump( $oh2->export );

C<export> can optionally take a list of indices/keys for what to export.
This applies to shared array, hash, and ordhash.

   use MCE::Shared;

   my $h1 = MCE::Shared->hash(           # shared hash
      qw/ I Heard The Bluebirds Sing by Marty Robbins /
        # k v     k   v         k    v  k     v
   );

   my $h2 = $h1->export( qw/ I The / );  # non-shared hash

   _dump($h2);

   # Output

   $VAR1 = bless( {
     'I' => 'Heard',
     'The' => 'Bluebirds'
   }, 'MCE::Shared::Hash' );

=item next

The C<next> method provides parallel iteration between workers for shared
C<array>, C<hash>, C<minidb>, C<ordhash>, and C<sequence>. In list context,
returns the next key-value pair. This applies to C<array>, C<hash>, C<minidb>,
and C<ordhash>. In scalar context, returns the next item. The C<undef> value
is returned after iteration has completed.

Internally, the list of keys to return is set when the closure is constructed.
Later keys added to the shared array or hash are not included. Subsequently,
the C<undef> value is returned for deleted keys.

The following example iterates through a shared array in parallel.

   use MCE::Hobo;
   use MCE::Shared;

   my $ob = MCE::Shared->array( 'a' .. 'j' );

   sub demo1 {
      my ( $id ) = @_;
      while ( my ( $index, $value ) = $ob->next ) {
         print "$id: [ $index ] $value\n";
         sleep 1;
      }
   }

   sub demo2 {
      my ( $id ) = @_;
      while ( defined ( my $value = $ob->next ) ) {
         print "$id: $value\n";
         sleep 1;
      }
   }

   MCE::Hobo->new( \&demo2, $_ ) for 1 .. 3;

   # ... do other work ...

   $_->join() for MCE::Hobo->list();

   # Output

   1: a
   2: b
   3: c
   2: f
   1: d
   3: e
   2: g
   3: i
   1: h
   2: j

The form is similar for C<sequence>. For large sequences, the C<bounds_only>
option is recommended. Also, specify C<chunk_size> accordingly. This reduces
the amount of traffic to and from the shared-manager process.

   use MCE::Hobo;
   use MCE::Shared;

   my $N   = shift || 4_000_000;
   my $pi  = MCE::Shared->scalar( 0.0 );

   my $seq = MCE::Shared->sequence(
      { chunk_size => 200_000, bounds_only => 1 },
      0, $N - 1
   );

   sub compute_pi {
      my ( $wid ) = @_;

      while ( my ( $beg, $end ) = $seq->next ) {
         my ( $_pi, $t ) = ( 0.0 );
         for my $i ( $beg .. $end ) {
            $t = ( $i + 0.5 ) / $N;
            $_pi += 4.0 / ( 1.0 + $t * $t );
         }
         $pi->incrby( $_pi );
      }

      return;
   }

   MCE::Hobo->create( \&compute_pi, $_ ) for ( 1 .. 8 );

   # ... do other stuff ...

   $_->join() for MCE::Hobo->list();

   printf "pi = %0.13f\n", $pi->get / $N;

   # Output

   3.1415926535898

=item rewind ( index, [, index, ... ] )

=item rewind ( key, [, key, ... ] )

=item rewind ( "query string" )

Rewinds the parallel iterator for L<MCE::Shared::Array>, L<MCE::Shared::Hash>,
or L<MCE::Shared::Ordhash> when no arguments are given. Otherwise, resets the
iterator with given criteria. The syntax for C<query string> is described in
the shared module.

   # rewind
   $ar->rewind;
   $oh->rewind;

   # array
   $ar->rewind( 0, 1 );
   $ar->rewind( "val eq some_value" );
   $ar->rewind( "key >= 50 :AND val =~ /sun|moon|air|wind/" );
   $ar->rewind( "val eq sun :OR val eq moon :OR val eq foo" );
   $ar->rewind( "key =~ /$pattern/" );

   while ( my ( $index, $value ) = $ar->next ) {
      ...
   }

   # hash, ordhash
   $oh->rewind( "key1", "key2" );
   $oh->rewind( "val eq some_value" );
   $oh->rewind( "key eq some_key :AND val =~ /sun|moon|air|wind/" );
   $oh->rewind( "val eq sun :OR val eq moon :OR val eq foo" );
   $oh->rewind( "key =~ /$pattern/" );

   while ( my ( $key, $value ) = $oh->next ) {
      ...
   }

=item rewind ( ":hashes", key, "query string" )

=item rewind ( ":hashes", key [, key, ... ] )

=item rewind ( ":hashes", "query string" )

=item rewind ( ":hashes" )

=item rewind ( ":lists", key, "query string" )

=item rewind ( ":lists", key [, key, ... ] )

=item rewind ( ":lists", "query string" )

=item rewind ( ":lists" )

Rewinds the parallel iterator for L<MCE::Shared::Minidb> when no arguments
are given. Otherwise, resets the iterator with given criteria. The syntax
for C<query string> is described in the shared module.

The default parallel iterator for C<minidb> is C<":hashes">.

   # rewind
   $db->rewind;

   # hash of hashes
   $db->rewind( ":hashes", "some_key", "key eq some_value" );
   $db->rewind( ":hashes", "some_key", "val eq some_value" );

   while ( my ( $key, $value ) = $db->next ) {
      ...
   }

   $db->rewind( ":hashes", "key1", "key2", "key3" );
   $db->rewind( ":hashes", "some_field eq some_value" );
   $db->rewind( ":hashes", "key =~ user" );
   $db->rewind( ":hashes" );

   while ( my ( $key, $href ) = $db->next ) {
      ...
   }

   # hash of lists
   $db->rewind( ":lists", "some_key", "key eq some_value" );
   $db->rewind( ":lists", "some_key", "val eq some_value" );

   while ( my ( $key, $value ) = $db->next ) {
      ...
   }

   $db->rewind( ":lists", "key1", "key2", "key3" );
   $db->rewind( ":lists", "some_index eq some_value" );
   $db->rewind( ":lists", "key =~ user" );
   $db->rewind( ":lists" );

   while ( my ( $key, $aref ) = $db->next ) {
      ...
   }

=item rewind ( { options }, begin, end [, step, format ] )

=item rewind ( begin, end [, step, format ] )

Rewinds the parallel iterator for L<MCE::Shared::Sequence> when no arguments
are given. Otherwise, resets the iterator with given criteria.

   $seq->rewind;

   $seq->rewind( { chunk_size => 10, bounds_only => 1 }, 1, 100 );

   while ( my ( $beg, $end ) = $seq->next ) {
      for my $i ( $beg .. $end ) {
         ...
      }
   }

   $seq->rewind( 1, 100 );

   while ( defined ( my $num = $seq->next ) ) {
      ...
   }

=item store ( key, value )

Deep-sharing a non-blessed structure recursively is possible with C<store>,
an alias to C<STORE>.

   use MCE::Shared;

   my $h1 = MCE::Shared->hash();
   my $h2 = MCE::Shared->hash();

   # auto-shares deeply
   $h1->store( 'key', [ 0, 2, 5, { 'foo' => 'bar' } ] );
   $h2->{key}[3]{foo} = 'baz';   # via auto-vivification

   my $v1 = $h1->get('key')->get(3)->get('foo');  # bar
   my $v2 = $h2->get('key')->get(3)->get('foo');  # baz
   my $v3 = $h2->{key}[3]{foo};                   # baz

=back

=head1 SERVER API

=over 3

=item start

Starts the shared-manager process. This is done automatically.

   MCE::Shared->start();

=item stop

Stops the shared-manager process wiping all shared data content. This is not
typically done by the user, but rather by C<END> automatically when the script
terminates.

   MCE::Shared->stop();

=item init

This method is called automatically by each MCE or Hobo worker immediately
after being spawned. The effect is extra parallelism during inter-process
communication. The optional ID (an integer) is modded internally in a
round-robin fashion.

   MCE::Shared->init();
   MCE::Shared->init( ID );

=back

=head1 INDEX

L<MCE|MCE>, L<MCE::Core>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

