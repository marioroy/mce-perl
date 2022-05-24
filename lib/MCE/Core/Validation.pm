###############################################################################
## ----------------------------------------------------------------------------
## Core validation methods for Many-Core Engine.
##
## This package provides validation methods used internally by the manager
## process.
##
## There is no public API.
##
###############################################################################

package MCE::Core::Validation;

use strict;
use warnings;

our $VERSION = '1.879';

## Items below are folded into MCE.

package # hide from rpm
   MCE;

no warnings qw( threads recursion uninitialized );

###############################################################################
## ----------------------------------------------------------------------------
## Validation method (attributes allowed for top-level).
##
###############################################################################

sub _validate_args {

   my $_s = $_[0];

   @_ = ();

   my $_tag = 'MCE::_validate_args';

   if (defined $_s->{input_data} && ref $_s->{input_data} eq '') {
      _croak("$_tag: ($_s->{input_data}) does not exist")
         unless (-e $_s->{input_data});
   }

   for my $_k (qw(job_delay spawn_delay submit_delay loop_timeout)) {
      _croak("$_tag: ($_k) is not valid")
         if ($_s->{$_k} && (!looks_like_number($_s->{$_k}) || $_s->{$_k} < 0));
   }
   for my $_k (qw(freeze thaw on_post_exit on_post_run user_error user_output)) {
      _croak("$_tag: ($_k) is not a CODE reference")
         if ($_s->{$_k} && ref $_s->{$_k} ne 'CODE');
   }

   _validate_args_s($_s);

   if (defined $_s->{user_tasks}) {
      for my $_t (@{ $_s->{user_tasks} }) {
         _validate_args_s($_s, $_t);
      }
   }

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Validation method (top-level and sub-tasks).
##
###############################################################################

sub _validate_args_s {

   my $self = $_[0]; my $_s = $_[1] || $self;

   @_ = ();

   my $_tag = 'MCE::_validate_args_s';

   if (defined $_s->{max_workers}) {
      $_s->{max_workers} = _parse_max_workers($_s->{max_workers});

      _croak("$_tag: (max_workers) is not valid")
         if ($_s->{max_workers} !~ /\A\d+\z/);
   }

   if (defined $_s->{chunk_size}) {
      if ($_s->{chunk_size} =~ /([0-9\.]+)K\z/i) {
         $_s->{chunk_size} = int($1 * 1024 + 0.5);
      }
      elsif ($_s->{chunk_size} =~ /([0-9\.]+)M\z/i) {
         $_s->{chunk_size} = int($1 * 1024 * 1024 + 0.5);
      }

      _croak("$_tag: (chunk_size) is not valid")
         if ($_s->{chunk_size} !~ /\A[0-9e\+]+\z/ or $_s->{chunk_size} == 0);

      $_s->{chunk_size} = int($_s->{chunk_size});
   }

   _croak("$_tag: (RS) is not valid")
      if ($_s->{RS} && ref $_s->{RS} ne '');
   _croak("$_tag: (max_retries) is not valid")
      if ($_s->{max_retries} && $_s->{max_retries} !~ /\A\d+\z/);

   for my $_k (qw(progress user_begin user_end user_func task_end)) {
      _croak("$_tag: ($_k) is not a CODE reference")
         if ($_s->{$_k} && ref $_s->{$_k} ne 'CODE');
   }

   if (defined $_s->{gather}) {
      my $_ref = ref $_s->{gather};

      _croak("$_tag: (gather) is not a valid reference")
         if ( $_ref ne 'MCE::Queue' && $_ref ne 'Thread::Queue' &&
              $_ref ne 'ARRAY' && $_ref ne 'HASH' && $_ref ne 'CODE' );
   }

   if (defined $_s->{sequence}) {
      my $_seq = $_s->{sequence};

      if (ref $_seq eq 'ARRAY') {
         my ($_begin, $_end, $_step, $_fmt) = @{ $_seq };
         $_seq = {
            begin => $_begin, end => $_end, step => $_step, format => $_fmt
         };
      }
      else {
         _croak("$_tag: (sequence) is not a HASH or ARRAY reference")
            if (ref $_seq ne 'HASH');
      }

      for my $_k (qw(begin end)) {
         _croak("$_tag: ($_k) is not defined for sequence")
            unless (defined $_seq->{$_k});
      }

      for my $_p (qw(begin end step)) {
         _croak("$_tag: ($_p) is not valid for sequence")
            if (defined $_seq->{$_p} && !looks_like_number($_seq->{$_p}));
      }

      unless (defined $_seq->{step}) {
         $_seq->{step} = ($_seq->{begin} <= $_seq->{end}) ? 1 : -1;
         if (ref $_s->{sequence} eq 'ARRAY') {
            $_s->{sequence}->[2] = $_seq->{step};
         }
      }

      if (ref $_s->{sequence} eq 'HASH') {
         for my $_k ('begin', 'end', 'step') {
            $_s->{sequence}{$_k} = int($_s->{sequence}{$_k})
               unless ($_s->{sequence}{$_k} =~ /\./);
         }
      }
      else {
         for my $_i (0, 1, 2) {
            $_s->{sequence}[$_i] = int($_s->{sequence}[$_i])
               unless ($_s->{sequence}[$_i] =~ /\./);
         }
      }

      if ( ($_seq->{step} < 0 && $_seq->{begin} < $_seq->{end}) ||
           ($_seq->{step} > 0 && $_seq->{begin} > $_seq->{end}) ||
           ($_seq->{step} == 0)
      ) {
         _croak("$_tag: impossible (step size) for sequence");
      }
   }

   if (defined $_s->{interval}) {
      if (ref $_s->{interval} eq '') {
         $_s->{interval} = { delay => $_s->{interval} };
      }

      my $_i = $_s->{interval};

      _croak("$_tag: (interval) is not a HASH reference")
         if (ref $_i ne 'HASH');
      _croak("$_tag: (delay) is not defined for interval")
         unless (defined $_i->{delay});
      _croak("$_tag: (delay) is not valid for interval")
         if (!looks_like_number($_i->{delay}) || $_i->{delay} < 0);

      for my $_p (qw(max_nodes node_id)) {
         _croak("$_tag: ($_p) is not valid for interval")
            if (defined $_i->{$_p} && (
               !looks_like_number($_i->{$_p}) ||
               int($_i->{$_p}) != $_i->{$_p}  ||
               $_i->{$_p} < 1
            ));
      }

      $_i->{max_nodes} = 1 unless (exists $_i->{max_nodes});
      $_i->{node_id}   = 1 unless (exists $_i->{node_id});
      $_i->{_time}     = MCE::Util::_time();
   }

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Validation method (run state).
##
###############################################################################

sub _validate_runstate {

   my $self = $_[0]; my $_tag = $_[1];

   @_ = ();

   _croak("$_tag: method is not allowed by the worker process")
      if ($self->{_wid});
   _croak("$_tag: method is not allowed while processing")
      if ($self->{_send_cnt});
   _croak("$_tag: method is not allowed while running")
      if ($self->{_total_running});

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Private functions for MCE Models { Flow, Grep, Loop, Map, Step, Stream }.
##
###############################################################################

sub _parse_chunk_size {

   my ($_chunk_size, $_max_workers, $_params, $_input_data, $_array_size) = @_;

   @_ = ();

   return $_chunk_size if (!defined $_chunk_size || !defined $_max_workers);

   if (defined $_params && exists $_params->{chunk_size}) {
      $_chunk_size = $_params->{chunk_size};
   }

   if ($_chunk_size =~ /([0-9\.]+)K\z/i) {
      $_chunk_size = int($1 * 1024 + 0.5);
   }
   elsif ($_chunk_size =~ /([0-9\.]+)M\z/i) {
      $_chunk_size = int($1 * 1024 * 1024 + 0.5);
   }

   if ($_chunk_size eq 'auto') {

      if ( (defined $_params && ref $_params->{input_data} eq 'CODE') ||
           (defined $_input_data && ref $_input_data eq 'CODE')
      ) {
         # Iterators may optionally use chunk_size to determine how much
         # to return per iteration. The default is 1 for MCE Models, same
         # as for the Core API. The user_func receives an array_ref
         # regardless if 1 or greater.
         #
         # sub make_iter {
         #    ...
         #    return sub {
         #       my ($chunk_size) = @_;
         #       ...
         #    };
         # }
         return 1;
      }

      my $_is_file;
      my $_size = $_array_size;

      if (defined $_input_data) {
         if (ref $_input_data eq 'ARRAY') {
            $_size = scalar @{ $_input_data };
         } elsif (ref $_input_data eq 'HASH') {
            $_size = scalar keys %{ $_input_data };
         }
      }

      if (defined $_params && exists $_params->{sequence}) {
         my ($_begin, $_end, $_step);

         if (ref $_params->{sequence} eq 'HASH') {
            $_begin = $_params->{sequence}->{begin};
            $_end   = $_params->{sequence}->{end};
            $_step  = $_params->{sequence}->{step} || 1;
         }
         else {
            $_begin = $_params->{sequence}[0];
            $_end   = $_params->{sequence}[1];
            $_step  = $_params->{sequence}[2] || 1;
         }

         if (!defined $_input_data && !$_array_size) {
            $_size = abs($_end - $_begin) / $_step + 1;
         }
      }
      elsif (defined $_params && exists $_params->{_file}) {
         my $_ref = ref $_params->{_file};

         if ($_ref eq 'SCALAR') {
            $_size = length ${ $_params->{_file} };
         } elsif ($_ref eq '') {
            $_size = -s $_params->{_file};
         } else {
            $_size = 0; $_chunk_size = 393_216;  # 384K
         }

         $_is_file = 1;
      }
      elsif (defined $_input_data) {
         if (ref($_input_data) =~ /^(?:GLOB|FileHandle|IO::)/) {
            $_is_file = 1; $_size = 0; $_chunk_size = 393_216;  # 384K
         }
         elsif (ref $_input_data eq 'SCALAR') {
            $_is_file = 1; $_size = length ${ $_input_data };
         }
      }

      if (defined $_is_file) {
         if ($_size) {
            $_chunk_size = int($_size / $_max_workers / 24 + 0.5);
            $_chunk_size = 5_242_880 if $_chunk_size > 5_242_880;  # 5M
            $_chunk_size = 2 if $_chunk_size <= 8192;
         }
      }
      else {
         $_chunk_size = int($_size / $_max_workers / 24 + 0.5);
         $_chunk_size = 8000 if $_chunk_size > 8000;
         $_chunk_size = 2 if $_chunk_size < 2;
      }
   }

   return $_chunk_size;
}

sub _parse_max_workers {

   my ($_max_workers) = @_;

   @_ = ();

   return $_max_workers unless (defined $_max_workers);

   if ($_max_workers =~ /^auto(?:$|\s*([\-\+\/\*])\s*(.+)$)/i) {
      my ($_ncpu_ul, $_ncpu);

      $_ncpu_ul = $_ncpu = MCE::Util::get_ncpu();
      $_ncpu_ul = 8 if ($_ncpu_ul > 8);

      if (defined($1) && defined($2)) {
         local $@; $_max_workers = eval "int($_ncpu_ul $1 $2 + 0.5)"; ## no critic
         $_max_workers = 1 if (!$_max_workers || $_max_workers < 1);
         $_max_workers = $_ncpu if ($_max_workers > $_ncpu);
      }
      else {
         $_max_workers = $_ncpu_ul;
      }
   }
   elsif ($_max_workers =~ /^([0-9.]+)%$/) {
      my $_percent = $1 / 100;
      my $_ncpu = MCE::Util::get_ncpu();

      $_max_workers = int($_ncpu * $_percent + 0.5);
      $_max_workers = 1 if ($_max_workers < 1);
   }

   return $_max_workers;
}

sub _validate_number {

   my ($_n, $_key, $_tag) = @_;

   _croak("$_tag: ($_key) is not valid") if (!defined $_n);

   $_n =~ s/K\z//i; $_n =~ s/M\z//i;

   if (!looks_like_number($_n) || int($_n) != $_n || $_n < 1) {
      _croak("$_tag: ($_key) is not valid");
   }

   return;
}

1;

__END__

###############################################################################
## ----------------------------------------------------------------------------
## Module usage.
##
###############################################################################

=head1 NAME

MCE::Core::Validation - Core validation methods for Many-Core Engine

=head1 VERSION

This document describes MCE::Core::Validation version 1.879

=head1 DESCRIPTION

This package provides validation methods used internally by the manager
process.

There is no public API.

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

