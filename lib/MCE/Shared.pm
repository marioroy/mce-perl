###############################################################################
## ----------------------------------------------------------------------------
## MCE::Shared - MCE extension for sharing data structures between workers.
##
###############################################################################

package MCE::Shared;

use strict;
use warnings;

no warnings 'threads';
no warnings 'recursion';
no warnings 'uninitialized';

our $VERSION = '1.699_001';

## no critic (BuiltinFunctions::ProhibitStringyEval)
## no critic (Subroutines::ProhibitSubroutinePrototypes)
## no critic (TestingAndDebugging::ProhibitNoStrict)

use Carp ();
use Scalar::Util qw( blessed reftype );
use bytes;

use MCE::Shared::Client;
use MCE::Shared::Server;

our @CARP_NOT = qw(
   MCE::Shared::Object
   MCE::Shared::Array
   MCE::Shared::Hash
   MCE::Shared::Scalar
);

###############################################################################
## ----------------------------------------------------------------------------
## Import function; plus TIE support.
##
###############################################################################

sub import {
   no strict 'refs'; no warnings 'redefine';
   *{ caller().'::mce_share' } = \&share;
}

{
   no warnings 'prototype'; no warnings 'redefine';
   use Attribute::Handlers autotie => { 'Shared' => __PACKAGE__ };

   sub UNIVERSAL::Shared :ATTR(HASH)   { tie %{ $_[2] }, 'MCE::Shared' }
   sub UNIVERSAL::Shared :ATTR(ARRAY)  { tie @{ $_[2] }, 'MCE::Shared' }
   sub UNIVERSAL::Shared :ATTR(SCALAR) { tie ${ $_[2] }, 'MCE::Shared' }

   sub TIEHASH   { my %_h; shift; &share(\%_h, @_) }
   sub TIEARRAY  { my @_a; shift; &share(\@_a, @_) }
   sub TIESCALAR { my $_s; shift; &share(\$_s, @_) }
}

###############################################################################
## ----------------------------------------------------------------------------
## Share function.
##
###############################################################################

sub share {
   my $_params = (@_ == 2 && ref $_[0] eq 'HASH' && blessed $_[1]) ? shift : {};
   my $_rtype  = reftype($_[0]);
   my $_item;

   _croak("Usage: mce_share( object or array/hash/scalar ref )\n\n")
      unless $_rtype;

   for (keys %{ $_params }) {
      _croak("The ($_) option to share is not valid") unless $_ eq 'compat';
   }

   $_params->{'class'} = blessed($_[0]);
   $_params->{'type'}  = $_rtype;
   $_params->{'tag'}   = 'M~TIE';

   if ($_rtype eq 'HASH') {
      return $_[0] if (tied(%{ $_[0] }) && tied(%{ $_[0] })->can('_id'));
      Carp::carp('Odd number of elements in hash assignment')
         if (!$_params->{'class'} && scalar @_ > 1 && (scalar @_ - 1) % 2);
      $_item = MCE::Shared::Server::_send($_params, @_);
   }
   elsif ($_rtype eq 'ARRAY') {
      return $_[0] if (tied(@{ $_[0] }) && tied(@{ $_[0] })->can('_id'));
      $_item = MCE::Shared::Server::_send($_params, @_);
   }
   elsif ($_rtype eq 'SCALAR') {
      return $_[0] if (tied(${ $_[0] }) && tied(${ $_[0] })->can('_id'));
      _croak('Too many arguments in scalar assignment') if (scalar @_ > 2);
      $_item = MCE::Shared::Server::_send($_params, @_);
   }
   else {
      _croak("Unsupported ref type: $_rtype");
   }

   return (defined wantarray) ? $_item : ();
}

sub _croak {
   $SIG{__DIE__} = sub {
      print {*STDERR} $_[0]; $SIG{INT} = sub {};
      kill('INT', $^O eq 'MSWin32' ? -$$ : -getpgrp);
      CORE::exit($?);
   };
   $\ = undef; goto &Carp::croak;
}

1;

__END__

###############################################################################
## ----------------------------------------------------------------------------
## Module usage.
##
###############################################################################

=head1 NAME

MCE::Shared - MCE extension for sharing data structures between workers

=head1 VERSION

This document describes MCE::Shared version 1.699_001

=head1 SYNOPSIS

   use feature 'say';

   use MCE::Flow;
   use MCE::Shared;

   my $var : Shared = 'initial value';
   my @ary : Shared = qw(a list of values);
   my %has : Shared = (key1 => 'value', key2 => 'value');

   my $cnt : Shared = 0;
   my @foo : Shared;
   my %bar : Shared;

   my $m1 = MCE::Mutex->new;

   mce_flow {
      max_workers => 4
   },
   sub {
      my ($mce) = @_;
      my ($pid, $wid) = (MCE->pid, MCE->wid);

      ## Locking is required when many workers update the same element.
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

=head1 API DOCUMENTATION

   TODO, coming soon...


=head1 INDEX

L<MCE|MCE>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

