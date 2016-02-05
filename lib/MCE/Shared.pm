###############################################################################
## ----------------------------------------------------------------------------
## MCE extension for sharing objects and data between workers.
##
###############################################################################

package MCE::Shared;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized );

our $VERSION = '1.699_010';

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
   if ($_class) {
      _incr_count($_[0]), return $_[0] if $_[0]->can('SHARED_ID');

      _croak("Running MCE::Queue via MCE::Shared is not supported.\n",
             "A shared queue is possible via MCE::Shared->queue().\n\n")
         if ($_class eq 'MCE::Queue');

      $_params->{'class'} = $_class;
      $_item = MCE::Shared::Server::_new($_params, $_[0]);
   }
   elsif (ref $_[0] eq 'ARRAY') {
      if (tied(@{ $_[0] }) && tied(@{ $_[0] })->can('SHARED_ID')) {
         _incr_count(tied(@{ $_[0] })), return tied(@{ $_[0] });
      }
      $_item = $_lkup{ $_ra } = MCE::Shared->array($_params, @{ $_[0] });
      @{ $_[0] } = ();  tie @{ $_[0] }, 'MCE::Shared::Object', $_item;
   }
   elsif (ref $_[0] eq 'HASH') {
      if (tied(%{ $_[0] }) && tied(%{ $_[0] })->can('SHARED_ID')) {
         _incr_count(tied(%{ $_[0] })), return tied(%{ $_[0] });
      }
      $_item = $_lkup{ $_ra } = MCE::Shared->hash($_params, %{ $_[0] });
      %{ $_[0] } = ();  tie %{ $_[0] }, 'MCE::Shared::Object', $_item;
   }
   elsif (ref $_[0] eq 'SCALAR' && !ref ${ $_[0] }) {
      if (tied(${ $_[0] }) && tied(${ $_[0] })->can('SHARED_ID')) {
         _incr_count(tied(${ $_[0] })), return tied(${ $_[0] });
      }
      $_item = $_lkup{ $_ra } = MCE::Shared->scalar($_params, ${ $_[0] });
      undef ${ $_[0] }; tie ${ $_[0] }, 'MCE::Shared::Object', $_item;
   }

   # synopsis
   elsif (ref $_[0] eq 'REF') {
      _croak('A "REF" type is not supported');
   }
   else {
      if (ref $_[0] eq 'GLOB') {
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
   shift if (defined $_[0] && $_[0] eq 'MCE::Shared');
   require MCE::Shared::Condvar unless $INC{'MCE/Shared/Condvar.pm'};
   &share( MCE::Shared::Condvar->new(@_) );
}

sub minidb {
   shift if (defined $_[0] && $_[0] eq 'MCE::Shared');
   require MCE::Shared::Minidb unless $INC{'MCE/Shared/Minidb.pm'};
   &share( MCE::Shared::Minidb->new(@_) );
}

sub queue {
   shift if (defined $_[0] && $_[0] eq 'MCE::Shared');
   require MCE::Shared::Queue unless $INC{'MCE/Shared/Queue.pm'};
   &share( MCE::Shared::Queue->new(@_) );
}

sub scalar {
   shift if (defined $_[0] && $_[0] eq 'MCE::Shared');
   require MCE::Shared::Scalar unless $INC{'MCE/Shared/Scalar.pm'};
   &share( MCE::Shared::Scalar->new(@_) );
}

sub sequence {
   shift if (defined $_[0] && $_[0] eq 'MCE::Shared');
   require MCE::Shared::Sequence unless $INC{'MCE/Shared/Sequence.pm'};
   &share( MCE::Shared::Sequence->new(@_) );
}

## 'num_sequence' is an alias for 'sequence'
*num_sequence = \&sequence;

sub array {
   shift if (defined $_[0] && $_[0] eq 'MCE::Shared');
   require MCE::Shared::Array unless $INC{'MCE/Shared/Array.pm'};

   my $_params = ref $_[0] eq 'HASH' ? shift : {};
   my $_item   = &share( $_params, MCE::Shared::Array->new() );

   if (scalar @_) {
      if ($_params->{_DEEPLY_}) {
         for (my $i = 0; $i <= $#_; $i += 1) {
            &_share($_params, $_item, $_[$i]) if ref($_[$i]);
         }
      }
      $_item->push(@_);
   }

   $_item;
}

sub handle {
   shift if (defined $_[0] && $_[0] eq 'MCE::Shared');
   require MCE::Shared::Handle unless $INC{'MCE/Shared/Handle.pm'};

   my $_item = &share( MCE::Shared::Handle->TIEHANDLE([]) );
   my $_fh   = \do { local *HANDLE };

   tie *{ $_fh }, 'MCE::Shared::Object', $_item;
   $_item->OPEN(@_) if @_;

   $_fh;
}

sub hash {
   shift if (defined $_[0] && $_[0] eq 'MCE::Shared');
   require MCE::Shared::Hash unless $INC{'MCE/Shared/Hash.pm'};

   my $_params = ref $_[0] eq 'HASH' ? shift : {};
   my $_item   = &share( $_params, MCE::Shared::Hash->new() );

   if (scalar @_) {
      if ($_params->{_DEEPLY_}) {
         for (my $i = 1; $i <= $#_; $i += 2) {
            &_share($_params, $_item, $_[$i]) if ref($_[$i]);
         }
      }
      $_item->mset(@_);
   }

   $_item;
}

sub ordhash {
   shift if (defined $_[0] && $_[0] eq 'MCE::Shared');
   require MCE::Shared::Ordhash unless $INC{'MCE/Shared/Ordhash.pm'};

   my $_params = ref $_[0] eq 'HASH' ? shift : {};
   my $_item   = &share( $_params, MCE::Shared::Ordhash->new() );

   if (scalar @_) {
      if ($_params->{_DEEPLY_}) {
         for (my $i = 1; $i <= $#_; $i += 2) {
            &_share($_params, $_item, $_[$i]) if ref($_[$i]);
         }
      }
      $_item->mset(@_);
   }

   $_item;
}

###############################################################################
## ----------------------------------------------------------------------------
## PDL sharing -- construction takes place under the shared server-process.
##
###############################################################################

if ($INC{'PDL.pm'}) {
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
         shift if (defined $_[0] && $_[0] eq 'MCE::Shared');
         MCE::Shared::Server::_new({ 'class' => ':construct_pdl:' }, [ @_ ]);
      }
   };
}

###############################################################################
## ----------------------------------------------------------------------------
## Private functions.
##
###############################################################################

sub TIEARRAY {
   shift;
   MCE::Shared->array(@_);
}

sub TIEHANDLE {
   require MCE::Shared::Handle unless $INC{'MCE/Shared/Handle.pm'};
   my $_item = &share( MCE::Shared::Handle->TIEHANDLE([]) ); shift;
   $_item->OPEN(@_) if @_;
   $_item;
}

sub TIEHASH {
   shift;
   if ( ref $_[0] eq 'HASH' && exists $_[0]->{'ordered'} ) {
      shift()->{'ordered'}
         ? MCE::Shared->ordhash(@_)
         : MCE::Shared->hash(@_);
   }
   else {
      MCE::Shared->hash(@_);
   }
}

sub TIESCALAR {
   shift;
   MCE::Shared->scalar(@_);
}

sub _croak {
   $_count = 0, %_lkup = ();
   if (defined $MCE::VERSION) {
      goto &MCE::_croak;
   }
   else {
      require MCE::Shared::Base unless $INC{'MCE/Shared/Base.pm'};
      goto &MCE::Shared::Base::_croak;
   }
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

This document describes MCE::Shared version 1.699_010

=head1 SYNOPSIS

   # OO construction

   use MCE::Shared Sereal => 1;

   my $ar = MCE::Shared->array( @list );
   my $cv = MCE::Shared->condvar( 0 );
   my $fh = MCE::Shared->handle( '>>', \*STDOUT );
   my $ha = MCE::Shared->hash( @pairs );
   my $db = MCE::Shared->minidb();
   my $oh = MCE::Shared->ordhash( @pairs );
   my $qu = MCE::Shared->queue( await => 1, fast => 0 );
   my $va = MCE::Shared->scalar( $value );
   my $nu = MCE::Shared->sequence( $begin, $end, $step, $fmt );
   my $ob = MCE::Shared->share( $blessed_object );

   # Tie construction

   use MCE::Flow;
   use MCE::Shared Sereal => 1;
   use feature 'say';

   tie my $var, 'MCE::Shared', 'initial value';
   tie my @ary, 'MCE::Shared', qw( a list of values );
   tie my %has, 'MCE::Shared', ( key1 => 'value', key2 => 'value' );
   tie my %oha, 'MCE::Shared', { ordered => 1 }, ( key1 => 'value' );

   tie my $cnt, 'MCE::Shared', 0;
   tie my @foo, 'MCE::Shared';
   tie my %bar, 'MCE::Shared';

   my $m1 = MCE::Mutex->new;

   mce_flow {
      max_workers => 4
   },
   sub {
      my ($mce) = @_;
      my ($pid, $wid) = (MCE->pid, MCE->wid);

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

   -- Output

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

As of this writing, the L<IO::FDPass|IO::FDPass> module is not a requirement
for running MCE::Shared nor is the check made during installation. The reason
is that C<IO::FDPass> is not possible on Cygwin and not sure about AIX.

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

=item array

=item condvar

=item handle

=item hash

=item minidb

=item ordhash

=item queue

=item scalar

=item sequence

C<array>, C<condvar>, C<handle>, C<hash>, C<minidb>, C<ordhash>, C<queue>,
C<scalar>, and C<sequence> are sugar syntax for constructing a shared object.

  # long form

  use MCE::Shared;
  use MCE::Shared::Array;
  use MCE::Shared::Hash;

  my $ar = MCE::Shared->share( MCE::Shared::Array->new() );
  my $ha = MCE::Shared->share( MCE::Shared::Hash->new() );

  # short form

  use MCE::Shared;

  my $ar = MCE::Shared->array( @list );
  my $cv = MCE::Shared->condvar( 0 );
  my $fh = MCE::Shared->handle( '>>', \*STDOUT );
  my $ha = MCE::Shared->hash( @pairs );
  my $db = MCE::Shared->minidb();
  my $oh = MCE::Shared->ordhash( @pairs );
  my $qu = MCE::Shared->queue( await => 1, fast => 0 );
  my $va = MCE::Shared->scalar( $value );
  my $nu = MCE::Shared->sequence( $begin, $end, $step, $fmt );

=item num_sequence

C<num_sequence> is an alias for C<sequence>.

=back

=head1 OBJECT SHARING

=over 3

=item share

This class method transfers the blessed-object to the shared-manager
process and returns a C<MCE::Shared::Object> containing the C<SHARED_ID>.
The object must not contain any C<GLOB>'s or C<CODE_REF>'s or the transfer
will fail.

Unlike C<threads::shared>, objects are not deeply shared. The shared object
is accessable only through the underlying OO interface.

   use MCE::Shared;
   use Hash::Ordered;

   my ($ho_shared, $ho_unshared);

   $ho_shared = MCE::Shared->share( Hash::Ordered->new() );

   $ho_shared->push( @pairs );            # OO interface only
   $ho_shared->mset( @pairs );

   $ho_unshared = $ho_shared->export();   # back to unshared
   $ho_unshared = $ho_shared->destroy();  # including destruction

The following provide long and short forms for constructing a shared array,
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

=item pdl_byte

=item pdl_short

=item pdl_ushort

=item pdl_long

=item pdl_longlong

=item pdl_float

=item pdl_double

=item pdl_ones

=item pdl_sequence

=item pdl_zeroes

=item pdl_indx

=item pdl

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

The MCE-Cookbook on Github provides a couple working PDL demonstrations for
further reading.

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

Exports the shared object into a non-shared object. One must export when passing
the shared object into any dump routine. Otherwise, the data C<${ SHARED_ID }>
is all one will see.

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

   # these do the same thing
   my $oh1 = MCE::Shared->share( MCE::Shared::Ordhash->new() );
   my $oh2 = MCE::Shared->ordhash();

   _dump($oh1);  # ${ 1 }  # SHARED_ID value
   _dump($oh2);  # ${ 2 }

   _dump($oh1->export());  # actual structure and content
   _dump($oh2->export());

C<export> can optionally take a list of indices/keys for what to export.
This applies to shared array, hash, and ordhash.

   use MCE::Shared;

   my $h1 = MCE::Shared->hash(           # shared hash
      qw/ I Heard The Bluebirds Sing by Marty Robbins /
        # k v     k   v         k    v  k     v
   );

   my $h2 = $h1->export( qw/ I The / );  # non-shared hash

   _dump($h2);

   __END__

   $VAR1 = bless( {
     'I' => 'Heard',
     'The' => 'Bluebirds'
   }, 'MCE::Shared::Hash' );

=item rewind ( begin, end, [ step, format ] )

Resets the parallel iterator for C<MCE::Shared::Sequence>.

=item rewind ( ":hashes", key, "query string" )

=item rewind ( ":hashes", key [, key, ... ] )

=item rewind ( ":hashes", "query string" )

=item rewind ( ":hashes" )

Resets the parallel iterator for C<MCE::Shared::Minidb> Hashes (HoH).

=item rewind ( ":lists", key, "query string" )

=item rewind ( ":lists", key [, key, ... ] )

=item rewind ( ":lists", "query string" )

=item rewind ( ":lists" )

Resets the parallel iterator for C<MCE::Shared::Minidb> Lists (HoA).

=item rewind ( index, [, index, ... ] )

=item rewind ( key, [, key, ... ] )

=item rewind ( "query string" )

Resets the parallel iterator for C<Array or (Ord)Hash>.

=item rewind

=item next

C<rewind> and C<next> enable parallel iteration between workers for shared
array, hash, minidb, ordhash, and sequence. Calling C<rewind> without an
argument rewinds the iterator.

The syntax for C<query string> is described in respective class module.
For sequence, the construction for C<rewind> is the same as C<new>.

L<MCE::Shared::Array|MCE::Shared::Array>

L<MCE::Shared::Hash|MCE::Shared::Hash>

L<MCE::Shared::Minidb|MCE::Shared::Minidb>

L<MCE::Shared::Ordhash|MCE::Shared::Ordhash>

L<MCE::Shared::Sequence|MCE::Shared::Sequence>

Below is a demonstration for iterating through a shared list between workers.

   use MCE::Hobo;
   use MCE::Shared;

   my $ob = MCE::Shared->array( 'a' .. 'j' );

   sub parallel {
      my ($id) = @_;
      while (defined (my $item = $ob->next)) {
         print "$id: $item\n";
         sleep 1;
      }
   }

   MCE::Hobo->new( \&parallel, $_ ) for 1 .. 3;

   # ... do other work ...

   $_->join() for MCE::Hobo->list();

   -- Output

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

There are two forms for iterating through a shared hash or ordhash object.
The C<next> method is wantarray-aware providing key and value in list
context and value in scalar context.

   use MCE::Hobo;
   use MCE::Shared;

   my $ob = MCE::Shared->ordhash(
      map {( "key_$_" => "val_$_" )} "a" .. "j"
   );

   sub iter1 {
      my ($id) = @_;
      while ( my ($key, $val) = $ob->next ) {
         print "$id: $key => $val\n";
         sleep 1;
      }
   }

   sub iter2 {
      my ($id) = @_;
      while ( defined (my $val = $ob->next) ) {
         print "$id: $val\n";
         sleep 1;
      }
   }

   MCE::Hobo->new(\&iter1, $_) for 1 .. 3;
   $_->join() for MCE::Hobo->list();

   $ob->rewind();

   MCE::Hobo->new(\&iter2, $_) for 1 .. 3;
   $_->join() for MCE::Hobo->list();

Although the shared-manager process iterates orderly, there is no guarantee for
the amount of time required by workers. Basically, do not expect for output to
be ordered.

   -- Output

   1: key_a => val_a
   2: key_b => val_b
   3: key_c => val_c
   1: key_d => val_d
   3: key_f => val_f
   2: key_e => val_e
   1: key_g => val_g
   3: key_i => val_i
   2: key_h => val_h
   1: key_j => val_j
   1: val_a
   2: val_b
   3: val_c
   3: val_f
   1: val_d
   2: val_e
   3: val_h
   1: val_g
   2: val_i
   3: val_j

=item store ( key, value )

Deep-sharing non-blessed structure(s) is possible with C<store> only. C<store>,
an alias to C<STORE>, converts non-blessed deeply-structures to shared objects
recursively.

   use MCE::Shared;

   my $h1 = MCE::Shared->hash();
   my $h2 = MCE::Shared->hash();

   # auto-shares deeply
   $h1->store( 'key', [ 0, 2, 5, { 'foo' => 'bar' } ] );
   $h2->{key}[3]{foo} = 'baz';   # via auto-vivification

   my $v1 = $h1->get('key')->get(3)->get('foo');  # bar
   my $v2 = $h2->get('key')->get(3)->get('foo');  # baz
   my $v3 = $h2->{key}[3]{foo};                   # baz

Each level in a deeply structure requires a separate trip to the shared-manager
processs. There is a faster way if the app calls for just C<HoH> and/or C<HoA>.
The included C<MCE::Shared::Minidb> module provides optimized methods for
working with C<HoH> and C<HoA> structures.

See L<MCE::Shared::Minidb|MCE::Shared::Minidb>.

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

This is called automatically by each MCE/Hobo worker immediately after being
spawned. The effect is extra parallelism during inter-process communication.
The optional ID (an integer) is modded in a round-robin fashion.

   MCE::Shared->init( ID );
   MCE::Shared->init();

=back

=head1 INDEX

L<MCE|MCE>, L<MCE::Core|MCE::Core>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

