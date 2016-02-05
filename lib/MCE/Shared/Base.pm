###############################################################################
## ----------------------------------------------------------------------------
## Base package for helper classes.
##
###############################################################################

package MCE::Shared::Base;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized numeric );

our $VERSION = '1.699_010';

## no critic (BuiltinFunctions::ProhibitStringyEval)

use Scalar::Util qw( looks_like_number );
use bytes;

###############################################################################
## ----------------------------------------------------------------------------
## Find support.
##
###############################################################################

my %rules = (                         ##
                                     #/\#
                                    #//\\#
                           #///////#///\\\#\\\\\\\#
                  #///P///#///E///#///  \\\#\\\R\\\#\\\L\\\#
         #///////#//// //#//// //#/////\\\\\#\\ \\\\#\\ \\\\#\\\\\\\#
        #//// //#///////#///////#//////\\\\\\#\\\\\\\#\\\\\\\#\\ \\\\#
         '==' => sub { looks_like_number ($_[0]) && $_[0] == $_[1] },
         '!=' => sub { looks_like_number ($_[0]) && $_[0] != $_[1] },
         '<'  => sub { looks_like_number ($_[0]) && $_[0] <  $_[1] },
         '<=' => sub { looks_like_number ($_[0]) && $_[0] <= $_[1] },
         '>'  => sub { looks_like_number ($_[0]) && $_[0] >  $_[1] },
         '>=' => sub { looks_like_number ($_[0]) && $_[0] >= $_[1] },
         'eq' => sub {              !ref ($_[0]) && $_[0] eq $_[1] },
         'ne' => sub {              !ref ($_[0]) && $_[0] ne $_[1] },
         'lt' => sub {              !ref ($_[0]) && $_[0] lt $_[1] },
         'le' => sub {              !ref ($_[0]) && $_[0] le $_[1] },
         'gt' => sub {              !ref ($_[0]) && $_[0] gt $_[1] },
         'ge' => sub {              !ref ($_[0]) && $_[0] ge $_[1] },
         '=~' => sub {              !ref ($_[0]) && $_[0] =~ $_[1] },
         '!~' => sub {              !ref ($_[0]) && $_[0] !~ $_[1] },
             ####   /    Welcome;    \   ####   ####   ####   ####
            ####   /                  \   ####   ####   ####   ####

);                                         # Perl Palace, MR 01/2016

sub _compile {
   my ( $query ) = @_;
   my ( @f,@c,@e, $aflg );

   # Search capability { =~ !~ eq ne lt le gt ge == != < <= > >= }
   #
   # Any quotes inside the string are treated literally
   # :AND(s) and :OR(s) mixed together is not supported
   #
   # "key =~ /$pattern/i :AND field =~ /$pattern/i"
   # "key =~ /$pattern/i :AND val eq foo bar"     # val eq 'foo bar'
   # "val eq foo bar :OR key !~ /$pattern/i"

   if ( length $query ) {
      local $@;  $aflg = ( $query =~ / :and /i );

      for ( split( / :(?:and|or) /i, $query ) ) {
         if ( /(.+)[ ]+(=~|!~)[ ]+(.+)/ ) {
            if ( length($2) && exists($rules{$2}) ) {
               push(@f,$1), push(@c,$rules{$2}), push(@e,eval("qr$3"));
               pop(@f), pop(@c), pop(@e) if $@;
            }
         }
         elsif ( /(.+)[ ]+(==|!=|<|<=|>|>=|eq|ne|lt|le|gt|ge)[ ]+(.+)/ ) {
            if ( length($2) && exists($rules{$2}) ) {
               push(@f,$1), push(@c,$rules{$2}), push(@e,$3);
            }
         }
      }

      for ( @e ) {
         $_ = undef if $_ eq 'undef';
      }
   }

   ( \@f,\@c,\@e, $aflg );
}

###############################################################################
## ----------------------------------------------------------------------------
## Find items in array.
##
###############################################################################

sub _find_array {
   my ( $data, $params, $query ) = ( shift, shift, shift );
   my ( $field, $code, $expr, $aflg ) = _compile( $query );

   # Single rule
   if ( scalar @{ $field } == 1 ) {
      my ( $f, $c, $e ) = ( $field->[0], $code->[0], $expr->[0] );

      if ( $f eq 'key' ) {
         if ( $params->{'getkeys'} ) {
            map { $c->( $_, $e ) ? ( $_ ) : () } @_;
         }
         elsif ( $params->{'getvals'} ) {
            map { $c->( $_, $e ) ? ( $data->[$_] ) : () } @_;
         }
         else {
            map { $c->( $_, $e ) ? ( $_ => $data->[$_] ) : () } @_;
         }
      }
      else {
         if ( $params->{'getkeys'} ) {
            map { $c->( $data->[$_], $e ) ? ( $_ ) : () } @_;
         }
         elsif ( $params->{'getvals'} ) {
            map { $c->( $data->[$_], $e ) ? ( $data->[$_] ) : () } @_;
         }
         else {
            map { $c->( $data->[$_], $e ) ? ( $_ => $data->[$_] ) : () } @_;
         }
      }
   }

   # Multiple rules
   elsif ( scalar @{ $field } > 1 ) {
      my $ok;

      my $is = $aflg ?
      sub {
         $ok = 1;
         for my $i ( 0 .. $#{ $field } ) {
            $ok = $field->[$i] eq 'key'
               ? $code->[$i]( $_, $expr->[$i] )
               : $code->[$i]( $data->[$_], $expr->[$i] );
            last unless $ok;
         }
         return;
      } :
      sub {
         $ok = 0;
         for my $i ( 0 .. $#{ $field } ) {
            $ok = $field->[$i] eq 'key'
               ? $code->[$i]( $_, $expr->[$i] )
               : $code->[$i]( $data->[$_], $expr->[$i] );
            last if $ok;
         }
         return;
      };

      if ( $params->{'getkeys'} ) {
         map { $is->(), $ok ? ( $_ ) : () } @_;
      }
      elsif ( $params->{'getvals'} ) {
         map { $is->(), $ok ? ( $data->[$_] ) : () } @_;
      }
      else {
         map { $is->(), $ok ? ( $_ => $data->[$_] ) : () } @_;
      }
   }

   # Not supported
   else {
      ();
   }
}

###############################################################################
## ----------------------------------------------------------------------------
## Find items in hash.
##
###############################################################################

sub _find_hash {
   my ( $data, $params, $query ) = ( shift, shift, shift );
   my ( $field, $code, $expr, $aflg ) = _compile( $query );

   # Single rule
   if ( scalar @{ $field } == 1 ) {
      my ( $f, $c, $e ) = ( $field->[0], $code->[0], $expr->[0] );

      if ( $f eq 'key' ) {
         if ( $params->{'getkeys'} ) {
            map { $c->( $_, $e ) ? ( $_ ) : () } @_;
         }
         elsif ( $params->{'getvals'} ) {
            map { $c->( $_, $e ) ? ( $data->{$_} ) : () } @_;
         }
         else {
            map { $c->( $_, $e ) ? ( $_ => $data->{$_} ) : () } @_;
         }
      }

      elsif ( $params->{'hfind'} ) {                  # Minidb HoH
         if ( $params->{'getkeys'} ) {
            map { $c->( $data->{$_}{$f}, $e ) ? ( $_ ) : () } @_;
         }
         elsif ( $params->{'getvals'} ) {
            map { $c->( $data->{$_}{$f}, $e ) ? ( $data->{$_} ) : () } @_;
         }
         else {
            map { $c->( $data->{$_}{$f}, $e ) ? ( $_ => $data->{$_} ) : () } @_;
         }
      }

      elsif ( $params->{'lfind'} ) {                  # Minidb HoA
         if ( $params->{'getkeys'} ) {
            map { $c->( $data->{$_}[$f], $e ) ? ( $_ ) : () } @_;
         }
         elsif ( $params->{'getvals'} ) {
            map { $c->( $data->{$_}[$f], $e ) ? ( $data->{$_} ) : () } @_;
         }
         else {
            map { $c->( $data->{$_}[$f], $e ) ? ( $_ => $data->{$_} ) : () } @_;
         }
      }

      else {                                          # Hash/Ordhash
         if ( $params->{'getkeys'} ) {
            map { $c->( $data->{$_}, $e ) ? ( $_ ) : () } @_;
         }
         elsif ( $params->{'getvals'} ) {
            map { $c->( $data->{$_}, $e ) ? ( $data->{$_} ) : () } @_;
         }
         else {
            map { $c->( $data->{$_}, $e ) ? ( $_ => $data->{$_} ) : () } @_;
         }
      }
   }

   # Multiple rules
   elsif ( scalar @{ $field } > 1 ) {
      my $ok;

      if ( $params->{'hfind'} ) {                     # Minidb HoH
         my $is = $aflg ?
         sub {
            $ok = 1;
            for my $i ( 0 .. $#{ $field } ) {
               $ok = $field->[$i] eq 'key'
                  ? $code->[$i]( $_, $expr->[$i] )
                  : $code->[$i]( $data->{$_}{ $field->[$i] }, $expr->[$i] );
               last unless $ok;
            }
            return;
         } :
         sub {
            $ok = 0;
            for my $i ( 0 .. $#{ $field } ) {
               $ok = $field->[$i] eq 'key'
                  ? $code->[$i]( $_, $expr->[$i] )
                  : $code->[$i]( $data->{$_}{ $field->[$i] }, $expr->[$i] );
               last if $ok;
            }
            return;
         };

         if ( $params->{'getkeys'} ) {
            map { $is->(), $ok ? ( $_ ) : () } @_;
         }
         elsif ( $params->{'getvals'} ) {
            map { $is->(), $ok ? ( $data->{$_} ) : () } @_;
         }
         else {
            map { $is->(), $ok ? ( $_ => $data->{$_} ) : () } @_;
         }
      }

      elsif ( $params->{'lfind'} ) {                  # Minidb HoA
         my $is = $aflg ?
         sub {
            $ok = 1;
            for my $i ( 0 .. $#{ $field } ) {
               $ok = $field->[$i] eq 'key'
                  ? $code->[$i]( $_, $expr->[$i] )
                  : $code->[$i]( $data->{$_}[ $field->[$i] ], $expr->[$i] );
               last unless $ok;
            }
            return;
         } :
         sub {
            $ok = 0;
            for my $i ( 0 .. $#{ $field } ) {
               $ok = $field->[$i] eq 'key'
                  ? $code->[$i]( $_, $expr->[$i] )
                  : $code->[$i]( $data->{$_}[ $field->[$i] ], $expr->[$i] );
               last if $ok;
            }
            return;
         };

         if ( $params->{'getkeys'} ) {
            map { $is->(), $ok ? ( $_ ) : () } @_;
         }
         elsif ( $params->{'getvals'} ) {
            map { $is->(), $ok ? ( $data->{$_} ) : () } @_;
         }
         else {
            map { $is->(), $ok ? ( $_ => $data->{$_} ) : () } @_;
         }
      }

      else {                                          # Hash/Ordhash
         my $is = $aflg ?
         sub {
            $ok = 1;
            for my $i ( 0 .. $#{ $field } ) {
               $ok = $field->[$i] eq 'key'
                  ? $code->[$i]( $_, $expr->[$i] )
                  : $code->[$i]( $data->{$_}, $expr->[$i] );
               last unless $ok;
            }
            return;
         } :
         sub {
            $ok = 0;
            for my $i ( 0 .. $#{ $field } ) {
               $ok = $field->[$i] eq 'key'
                  ? $code->[$i]( $_, $expr->[$i] )
                  : $code->[$i]( $data->{$_}, $expr->[$i] );
               last if $ok;
            }
            return;
         };

         if ( $params->{'getkeys'} ) {
            map { $is->(), $ok ? ( $_ ) : () } @_;
         }
         elsif ( $params->{'getvals'} ) {
            map { $is->(), $ok ? ( $data->{$_} ) : () } @_;
         }
         else {
            map { $is->(), $ok ? ( $_ => $data->{$_} ) : () } @_;
         }
      }
   }

   # Not supported
   else {
      ();
   }
}

###############################################################################
## ----------------------------------------------------------------------------
## Miscellaneous.
##
###############################################################################

sub _stringify { no overloading;    "$_[0]" }
sub _numify    { no overloading; 0 + $_[0]  }

# Croak and die handler.

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

This document describes MCE::Shared::Base version 1.699_010

=head1 DESCRIPTION

Common functions for L<MCE::Shared|MCE::Shared>. There is no public API.

=head1 INDEX

L<MCE|MCE>, L<MCE::Core|MCE::Core>, L<MCE::Shared|MCE::Shared>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

