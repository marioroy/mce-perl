###############################################################################
## ----------------------------------------------------------------------------
## MCE extension for sharing objects and data between workers.
##
###############################################################################

package MCE::Shared;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized );

our $VERSION = '1.699_001';

## no critic (BuiltinFunctions::ProhibitStringyEval)

use Scalar::Util qw( blessed refaddr );
use MCE::Shared::Server;

our @CARP_NOT = qw(
   MCE::Shared::Array   MCE::Shared::Condvar   MCE::Shared::Handle
   MCE::Shared::Hash    MCE::Shared::Ordhash   MCE::Shared::Queue
   MCE::Shared::Scalar  MCE::Shared::Sequence  MCE::Shared::Server

   MCE::Shared::Object
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
   my ( $_item ) = (
      &share( ref $_[0] eq 'HASH' ? shift : {}, MCE::Shared::Array->new() )
   );
   $_item->push(@_) if @_;
   $_item;
}
sub hash {
   shift if (defined $_[0] && $_[0] eq 'MCE::Shared');
   require MCE::Shared::Hash unless $INC{'MCE/Shared/Hash.pm'};
   my ( $_item ) = (
      &share( ref $_[0] eq 'HASH' ? shift : {}, MCE::Shared::Hash->new() )
   );
   $_item->mset(@_) if @_;
   $_item;
}
sub ordhash {
   shift if (defined $_[0] && $_[0] eq 'MCE::Shared');
   require MCE::Shared::Ordhash unless $INC{'MCE/Shared/Ordhash.pm'};
   my ( $_item ) = (
      &share( ref $_[0] eq 'HASH' ? shift : {}, MCE::Shared::Ordhash->new() )
   );
   $_item->mset(@_) if @_;
   $_item;
}

sub handle {
   shift if (defined $_[0] && $_[0] eq 'MCE::Shared');
   require MCE::Shared::Handle unless $INC{'MCE/Shared/Handle.pm'};

   my $_item = &share( MCE::Shared::Handle->new([]) );
   tie local *HANDLE, 'MCE::Shared::Object', $_item;
   $_item->OPEN(@_) if @_;

   *HANDLE;
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

sub TIEARRAY  { shift; MCE::Shared->array(@_)  }
sub TIEHASH   { shift; MCE::Shared->hash(@_)   }
sub TIESCALAR { shift; MCE::Shared->scalar(@_) }

sub TIEHANDLE {
   require MCE::Shared::Handle unless $INC{'MCE/Shared/Handle.pm'};
   my $_item = &share( MCE::Shared::Handle->new([]) ); shift;
   $_item->OPEN(@_) if @_;
   $_item;
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

This document describes MCE::Shared version 1.699_001

=head1 SYNOPSIS

   # OO construction

   use MCE::Shared Sereal => 1;

   my $ar = MCE::Shared->array( @list );
   my $cv = MCE::Shared->condvar( 0 );
   my $fh = MCE::Shared->handle( '>>', \*STDOUT );
   my $ha = MCE::Shared->hash( @pairs );
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
   tie my @ary, 'MCE::Shared', qw(a list of values);
   tie my %has, 'MCE::Shared', (key1 => 'value', key2 => 'value');

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
MCE::Shared may run alongside threads::shared.

The documentation below will be completed before the final 1.700 release.

=head1 DATA SHARING

=over 3

=item array

=item condvar

=item handle

=item hash

=item ordhash

=item queue

=item scalar

=item sequence

=item num_sequence

C<num_sequence> is an alias for C<sequence>.

=back

=head1 OBJECT SHARING

=over 3

=item share

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

=item ins_inplace

=back

See MCE's Cookbook on github for PDL demonstrations.

=head1 COMMON API

=over 3

=item blessed

=item destroy

=item export

=item next

=item prev

=item reset

=back

=head1 SERVER API

=over 3

=item start

=item stop

=item init

=back

=head1 INDEX

L<MCE|MCE>, L<MCE::Core|MCE::Core>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

