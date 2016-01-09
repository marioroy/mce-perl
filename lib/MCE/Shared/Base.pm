###############################################################################
## ----------------------------------------------------------------------------
## Base package for helper classes.
##
###############################################################################

package MCE::Shared::Base;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized );

our $VERSION = '1.699_007';

## no critic (BuiltinFunctions::ProhibitStringyEval)

use Scalar::Util qw( looks_like_number refaddr );

## 'overloading.pm' is not available until 5.10.1 so emulate with Scalar::Util
## tip borrowed from Hash::Ordered by David Golden

BEGIN {
   if ($] gt '5.010000') {
      local $@; eval q{
      sub _stringify_a { no overloading;    "$_[0]" }
      sub _stringify_h { no overloading;    "$_[0]" }
      sub _stringify_s { no overloading;    "$_[0]" }
      sub _numify      { no overloading; 0 + $_[0]  }
      }; 
      die $@ if $@;
   }
   else {
      local $@; eval q{
      sub _stringify_a { sprintf "%s=ARRAY(0x%x)",  ref($_[0]), refaddr($_[0]) }
      sub _stringify_h { sprintf "%s=HASH(0x%x)",   ref($_[0]), refaddr($_[0]) }
      sub _stringify_s { sprintf "%s=SCALAR(0x%x)", ref($_[0]), refaddr($_[0]) }
      sub _numify      { refaddr($_[0]) }
      };
      die $@ if $@;
   }
}

sub _croak {
   if (defined $MCE::VERSION) {
      goto &MCE::_croak;
   }
   else {
      require Carp unless $INC{'Carp.pm'};
      $SIG{__DIE__} = \&_die;
      local $\ = undef; goto &Carp::croak;
   }
}

sub _die {
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

   print {*STDERR} $_[0] if defined $_[0];

   ($^O eq 'MSWin32')
      ? CORE::kill('KILL', -$$, $$)
      : CORE::kill('INT', -getpgrp);

   CORE::exit($?);
}

###############################################################################
## ----------------------------------------------------------------------------
## find support for finding items in an array
##
###############################################################################

my %_find_vals_array = (

   # pattern

   '=~' => sub {
      my ( $array, $expr ) = ( shift, shift );
      local $@; my $re = eval "qr$expr";

      $@ ? () : map {
         ( !ref( $array->[ $_ ] ) && $array->[ $_ ] =~ $re )
            ? ( $_ => $array->[ $_ ] ) : () } @_;
   },
   '!~' => sub {
      my ( $array, $expr ) = ( shift, shift );
      local $@; my $re = eval "qr$expr";

      $@ ? () : map {
         ( !ref( $array->[ $_ ] ) && $array->[ $_ ] !~ $re )
            ? ( $_ => $array->[ $_ ] ) : () } @_;
   },

   # number

   '==' => sub {
      my ( $array, $expr ) = ( shift, shift );
      map { ( looks_like_number( $array->[ $_ ] ) && $array->[ $_ ] == $expr )
            ? ( $_ => $array->[ $_ ] ) : () } @_;
   },
   '!=' => sub {
      my ( $array, $expr ) = ( shift, shift );
      map { ( looks_like_number( $array->[ $_ ] ) && $array->[ $_ ] != $expr )
            ? ( $_ => $array->[ $_ ] ) : () } @_;
   },
   '<'  => sub {
      my ( $array, $expr ) = ( shift, shift );
      map { ( looks_like_number( $array->[ $_ ] ) && $array->[ $_ ] <  $expr )
            ? ( $_ => $array->[ $_ ] ) : () } @_;
   },
   '<=' => sub {
      my ( $array, $expr ) = ( shift, shift );
      map { ( looks_like_number( $array->[ $_ ] ) && $array->[ $_ ] <= $expr )
            ? ( $_ => $array->[ $_ ] ) : () } @_;
   },
   '>'  => sub {
      my ( $array, $expr ) = ( shift, shift );
      map { ( looks_like_number( $array->[ $_ ] ) && $array->[ $_ ] >  $expr )
            ? ( $_ => $array->[ $_ ] ) : () } @_;
   },
   '>=' => sub {
      my ( $array, $expr ) = ( shift, shift );
      map { ( looks_like_number( $array->[ $_ ] ) && $array->[ $_ ] >= $expr )
            ? ( $_ => $array->[ $_ ] ) : () } @_;
   },

   # string

   'eq' => sub {
      my ( $array, $expr ) = ( shift, shift );
      map { ( !ref( $array->[ $_ ] ) && $array->[ $_ ] eq $expr )
            ? ( $_ => $array->[ $_ ] ) : () } @_;
   },
   'ne' => sub {
      my ( $array, $expr ) = ( shift, shift );
      map { ( !ref( $array->[ $_ ] ) && $array->[ $_ ] ne $expr )
            ? ( $_ => $array->[ $_ ] ) : () } @_;
   },
   'lt' => sub {
      my ( $array, $expr ) = ( shift, shift );
      map { ( !ref( $array->[ $_ ] ) && $array->[ $_ ] lt $expr )
            ? ( $_ => $array->[ $_ ] ) : () } @_;
   },
   'le' => sub {
      my ( $array, $expr ) = ( shift, shift );
      map { ( !ref( $array->[ $_ ] ) && $array->[ $_ ] le $expr )
            ? ( $_ => $array->[ $_ ] ) : () } @_;
   },
   'gt' => sub {
      my ( $array, $expr ) = ( shift, shift );
      map { ( !ref( $array->[ $_ ] ) && $array->[ $_ ] gt $expr )
            ? ( $_ => $array->[ $_ ] ) : () } @_;
   },
   'ge' => sub {
      my ( $array, $expr ) = ( shift, shift );
      map { ( !ref( $array->[ $_ ] ) && $array->[ $_ ] ge $expr )
            ? ( $_ => $array->[ $_ ] ) : () } @_;
   },
);

sub _find_vals_array { \%_find_vals_array }

###############################################################################
## ----------------------------------------------------------------------------
## find support for finding items in a hash
##
###############################################################################

my %_find_keys_hash = (

   # pattern

   '=~' => sub {
      my ( $hash, $expr ) = ( shift, shift );
      local $@; my $re = eval "qr$expr";

      $@ ? () : map {
         ( !ref( $hash->{ $_ } ) && $_ =~ $re )
            ? ( $_ => $hash->{ $_ } ) : () } @_;
   },
   '!~' => sub {
      my ( $hash, $expr ) = ( shift, shift );
      local $@; my $re = eval "qr$expr";

      $@ ? () : map {
         ( !ref( $hash->{ $_ } ) && $_ !~ $re )
            ? ( $_ => $hash->{ $_ } ) : () } @_;
   },

   # number

   '==' => sub {
      my ( $hash, $expr ) = ( shift, shift );
      map { ( looks_like_number( $hash->{ $_ } ) && $_ == $expr )
            ? ( $_ => $hash->{ $_ } ) : () } @_;
   },
   '!=' => sub {
      my ( $hash, $expr ) = ( shift, shift );
      map { ( looks_like_number( $hash->{ $_ } ) && $_ != $expr )
            ? ( $_ => $hash->{ $_ } ) : () } @_;
   },
   '<'  => sub {
      my ( $hash, $expr ) = ( shift, shift );
      map { ( looks_like_number( $hash->{ $_ } ) && $_ <  $expr )
            ? ( $_ => $hash->{ $_ } ) : () } @_;
   },
   '<=' => sub {
      my ( $hash, $expr ) = ( shift, shift );
      map { ( looks_like_number( $hash->{ $_ } ) && $_ <= $expr )
            ? ( $_ => $hash->{ $_ } ) : () } @_;
   },
   '>'  => sub {
      my ( $hash, $expr ) = ( shift, shift );
      map { ( looks_like_number( $hash->{ $_ } ) && $_ >  $expr )
            ? ( $_ => $hash->{ $_ } ) : () } @_;
   },
   '>=' => sub {
      my ( $hash, $expr ) = ( shift, shift );
      map { ( looks_like_number( $hash->{ $_ } ) && $_ >= $expr )
            ? ( $_ => $hash->{ $_ } ) : () } @_;
   },

   # string

   'eq' => sub {
      my ( $hash, $expr ) = ( shift, shift );
      map { ( !ref( $hash->{ $_ } ) && $_ eq $expr )
            ? ( $_ => $hash->{ $_ } ) : () } @_;
   },
   'ne' => sub {
      my ( $hash, $expr ) = ( shift, shift );
      map { ( !ref( $hash->{ $_ } ) && $_ ne $expr )
            ? ( $_ => $hash->{ $_ } ) : () } @_;
   },
   'lt' => sub {
      my ( $hash, $expr ) = ( shift, shift );
      map { ( !ref( $hash->{ $_ } ) && $_ lt $expr )
            ? ( $_ => $hash->{ $_ } ) : () } @_;
   },
   'le' => sub {
      my ( $hash, $expr ) = ( shift, shift );
      map { ( !ref( $hash->{ $_ } ) && $_ le $expr )
            ? ( $_ => $hash->{ $_ } ) : () } @_;
   },
   'gt' => sub {
      my ( $hash, $expr ) = ( shift, shift );
      map { ( !ref( $hash->{ $_ } ) && $_ gt $expr )
            ? ( $_ => $hash->{ $_ } ) : () } @_;
   },
   'ge' => sub {
      my ( $hash, $expr ) = ( shift, shift );
      map { ( !ref( $hash->{ $_ } ) && $_ ge $expr )
            ? ( $_ => $hash->{ $_ } ) : () } @_;
   },
);

my %_find_vals_hash = (

   # pattern

   '=~' => sub {
      my ( $hash, $expr ) = ( shift, shift );
      local $@; my $re = eval "qr$expr";

      $@ ? () : map {
         ( !ref( $hash->{ $_ } ) && $hash->{ $_ } =~ $re )
            ? ( $_ => $hash->{ $_ } ) : () } @_;
   },
   '!~' => sub {
      my ( $hash, $expr ) = ( shift, shift );
      local $@; my $re = eval "qr$expr";

      $@ ? () : map {
         ( !ref( $hash->{ $_ } ) && $hash->{ $_ } !~ $re )
            ? ( $_ => $hash->{ $_ } ) : () } @_;
   },

   # number

   '==' => sub {
      my ( $hash, $expr ) = ( shift, shift );
      map { ( looks_like_number( $hash->{ $_ } ) && $hash->{ $_ } == $expr )
            ? ( $_ => $hash->{ $_ } ) : () } @_;
   },
   '!=' => sub {
      my ( $hash, $expr ) = ( shift, shift );
      map { ( looks_like_number( $hash->{ $_ } ) && $hash->{ $_ } != $expr )
            ? ( $_ => $hash->{ $_ } ) : () } @_;
   },
   '<'  => sub {
      my ( $hash, $expr ) = ( shift, shift );
      map { ( looks_like_number( $hash->{ $_ } ) && $hash->{ $_ } <  $expr )
            ? ( $_ => $hash->{ $_ } ) : () } @_;
   },
   '<=' => sub {
      my ( $hash, $expr ) = ( shift, shift );
      map { ( looks_like_number( $hash->{ $_ } ) && $hash->{ $_ } <= $expr )
            ? ( $_ => $hash->{ $_ } ) : () } @_;
   },
   '>'  => sub {
      my ( $hash, $expr ) = ( shift, shift );
      map { ( looks_like_number( $hash->{ $_ } ) && $hash->{ $_ } >  $expr )
            ? ( $_ => $hash->{ $_ } ) : () } @_;
   },
   '>=' => sub {
      my ( $hash, $expr ) = ( shift, shift );
      map { ( looks_like_number( $hash->{ $_ } ) && $hash->{ $_ } >= $expr )
            ? ( $_ => $hash->{ $_ } ) : () } @_;
   },

   # string

   'eq' => sub {
      my ( $hash, $expr ) = ( shift, shift );
      map { ( !ref( $hash->{ $_ } ) && $hash->{ $_ } eq $expr )
            ? ( $_ => $hash->{ $_ } ) : () } @_;
   },
   'ne' => sub {
      my ( $hash, $expr ) = ( shift, shift );
      map { ( !ref( $hash->{ $_ } ) && $hash->{ $_ } ne $expr )
            ? ( $_ => $hash->{ $_ } ) : () } @_;
   },
   'lt' => sub {
      my ( $hash, $expr ) = ( shift, shift );
      map { ( !ref( $hash->{ $_ } ) && $hash->{ $_ } lt $expr )
            ? ( $_ => $hash->{ $_ } ) : () } @_;
   },
   'le' => sub {
      my ( $hash, $expr ) = ( shift, shift );
      map { ( !ref( $hash->{ $_ } ) && $hash->{ $_ } le $expr )
            ? ( $_ => $hash->{ $_ } ) : () } @_;
   },
   'gt' => sub {
      my ( $hash, $expr ) = ( shift, shift );
      map { ( !ref( $hash->{ $_ } ) && $hash->{ $_ } gt $expr )
            ? ( $_ => $hash->{ $_ } ) : () } @_;
   },
   'ge' => sub {
      my ( $hash, $expr ) = ( shift, shift );
      map { ( !ref( $hash->{ $_ } ) && $hash->{ $_ } ge $expr )
            ? ( $_ => $hash->{ $_ } ) : () } @_;
   },
);

sub _find_keys_hash { \%_find_keys_hash }
sub _find_vals_hash { \%_find_vals_hash }

1;

__END__

###############################################################################
## ----------------------------------------------------------------------------
## Module usage.
##
###############################################################################

=head1 NAME

MCE::Shared::Base - Base package for helper classes

=head1 VERSION

This document describes MCE::Shared::Base version 1.699_007

=head1 DESCRIPTION

Common functions for L<MCE::Shared|MCE::Shared>. There is no public API.

=head1 INDEX

L<MCE|MCE>, L<MCE::Core|MCE::Core>, L<MCE::Shared|MCE::Shared>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

