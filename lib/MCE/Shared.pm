###############################################################################
## ----------------------------------------------------------------------------
## MCE::Shared - MCE extension for sharing data structures between workers.
##
###############################################################################

package MCE::Shared;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized );

our $VERSION = '1.699_001';

## no critic (TestingAndDebugging::ProhibitNoStrict)

use Carp ();
use Scalar::Util qw( blessed reftype );
use Symbol qw( gensym );

use MCE::Shared::Client;
use MCE::Shared::Server;

our @CARP_NOT = qw(
   MCE::Shared::Object  MCE::Shared::Array  MCE::Shared::File
   MCE::Shared::Hash    MCE::Shared::Scalar
);

sub _croak {
   $SIG{__DIE__} = sub {
      print {*STDERR} $_[0]; $SIG{INT} = sub {};
      kill('INT', $^O eq 'MSWin32' ? -$$ : -getpgrp);
      CORE::exit($?);
   };
   $\ = undef; goto &Carp::croak;
}

###############################################################################
## ----------------------------------------------------------------------------
## Import function; plus TIE support.
##
###############################################################################

sub import {
   my $_class = shift;

   no strict 'refs'; no warnings 'redefine';
   *{ caller().'::mce_share' } = \&share;
   *{ caller().'::mce_open' } = \&open;

   return;
}

{
   no warnings 'prototype'; no warnings 'redefine';
   use Attribute::Handlers ();

   sub UNIVERSAL::Shared :ATTR(ARRAY)  { tie @{ $_[2] }, 'MCE::Shared' }
   sub UNIVERSAL::Shared :ATTR(HASH)   { tie %{ $_[2] }, 'MCE::Shared' }
   sub UNIVERSAL::Shared :ATTR(SCALAR) { tie ${ $_[2] }, 'MCE::Shared' }
}

sub TIEARRAY  {    my @_a; shift; &share(\@_a, @_) }
sub TIEHANDLE { local *_f; shift; &share(\*_f, @_) }
sub TIEHASH   {    my %_h; shift; &share(\%_h, @_) }
sub TIESCALAR {    my $_s; shift; &share(\$_s, @_) }

###############################################################################
## ----------------------------------------------------------------------------
## Public functions.
##
###############################################################################

sub spawn    { MCE::Shared::Server::_spawn()    }
sub shutdown { MCE::Shared::Server::_shutdown() }

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

   if ($_rtype eq 'ARRAY') {
      return $_[0] if (tied(@{ $_[0] }) && tied(@{ $_[0] })->can('_id'));
      $_item = MCE::Shared::Server::_send($_params, @_);
   }
   elsif ($_rtype eq 'GLOB') {
      return $_[0] if (tied(*{ $_[0] }) && tied(*{ $_[0] })->can('_id'));
      $_item = MCE::Shared::Server::_send($_params, fileno *{ (shift) }, @_);
   }
   elsif ($_rtype eq 'HASH') {
      return $_[0] if (tied(%{ $_[0] }) && tied(%{ $_[0] })->can('_id'));
      Carp::carp('Odd number of elements in hash assignment')
         if (!$_params->{'class'} && scalar @_ > 1 && (scalar @_ - 1) % 2);
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

sub open {
   my $_fh = gensym();

   if (ref $_[-1] && defined (my $_fd = fileno($_[-1]))) {
      my @_args = @_; pop @_args; $_args[-1] .= "&=$_fd";
      tie *{ $_fh }, 'MCE::Shared', @_args;
   }
   else {
      tie *{ $_fh }, 'MCE::Shared', @_;
   }

   return bless($_fh, 'MCE::Shared::File');
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
The intention is not for 100% compatibility with threads::shared. It lacks
support for cond_wait, cond_timedwait, cond_signal, and cond_broadcast.

This module supports the sharing of the following data types:
arrays and array refs, hashes and hash refs, and scalars and scalar refs.

MCE::Shared may run alongside threads::shared.

=head1 EXPORT

The following function is exported by this module: C<mce_share>.

   use MCE::Shared;

   ## Array Ref

   my $ar1 = mce_share [];
   my $ar2 = mce_share [] = ( @list );
   my $ar3 = mce_share \@ary;

   $ar1->[ 0 ] = 'kind';
   $ar1->Store( $index => $value );
   $ar1->Push( @list );

   ## Hash Ref

   my $ha1 = mce_share {};
   my $ha2 = mce_share {} = ( @pairs );
   my $ha3 = mce_share \%has;

   $has->{ key } = $value;
   $has->Store( $key => $value );
   $has->Store( @pairs );

   ## Scalar Ref

   my $va1 = mce_share \do { my $var = 0 };
   my $va2 = mce_share \( 0 );
   my $va3 = mce_share \$var;

   ## Object

   my $ob1 = mce_share( new $object );   # same as compat => 0

   my $ob2 = mce_share( { compat => 0 }, new $object );
   my $ob3 = mce_share( { compat => 1 }, new $object );

=head1 API DOCUMENTATION

   TODO, coming soon...

=head1 SEE ALSO

L<threads::shared>

=head1 INDEX

L<MCE|MCE>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

