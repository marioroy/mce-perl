###############################################################################
## ----------------------------------------------------------------------------
## Sugar methods and output iterators.
##
###############################################################################

package MCE::Candy;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized );

our $VERSION = '1.879';

our @CARP_NOT = qw( MCE );

###############################################################################
## ----------------------------------------------------------------------------
## Import routine.
##
###############################################################################

my $_imported;

sub import {

   return if ($_imported++);

   unless ($INC{'MCE.pm'}) {
      $\ = undef; require Carp;
      Carp::croak(
         "MCE::Candy requires MCE. Please see the MCE::Candy documentation\n".
         "for more information.\n\n"
      );
   }

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Forchunk, foreach, and forseq sugar methods.
##
###############################################################################

sub forchunk {

   my $x = shift; my $self = ref($x) ? $x : $MCE::MCE;
   my $_input_data = $_[0];

   MCE::_validate_runstate($self, 'MCE::forchunk');

   my ($_user_func, $_params_ref);

   if (ref $_[1] eq 'HASH') {
      $_user_func = $_[2]; $_params_ref = $_[1];
   } else {
      $_user_func = $_[1]; $_params_ref = {};
   }

   @_ = ();

   MCE::_croak('MCE::forchunk: (input_data) is not specified')
      unless (defined $_input_data);
   MCE::_croak('MCE::forchunk: (code_block) is not specified')
      unless (defined $_user_func);

   $_params_ref->{input_data} = $_input_data;
   $_params_ref->{user_func}  = $_user_func;

   $self->run(1, $_params_ref);

   return $self;
}

sub foreach {

   my $x = shift; my $self = ref($x) ? $x : $MCE::MCE;
   my $_input_data = $_[0];

   MCE::_validate_runstate($self, 'MCE::foreach');

   my ($_user_func, $_params_ref);

   if (ref $_[1] eq 'HASH') {
      $_user_func = $_[2]; $_params_ref = $_[1];
   } else {
      $_user_func = $_[1]; $_params_ref = {};
   }

   @_ = ();

   MCE::_croak('MCE::foreach: (HASH) not allowed as input by this method')
      if (ref $_input_data eq 'HASH');
   MCE::_croak('MCE::foreach: (input_data) is not specified')
      unless (defined $_input_data);
   MCE::_croak('MCE::foreach: (code_block) is not specified')
      unless (defined $_user_func);

   $_params_ref->{chunk_size} = 1;
   $_params_ref->{input_data} = $_input_data;
   $_params_ref->{user_func}  = $_user_func;

   $self->run(1, $_params_ref);

   return $self;
}

sub forseq {

   my $x = shift; my $self = ref($x) ? $x : $MCE::MCE;
   my $_sequence = $_[0];

   MCE::_validate_runstate($self, 'MCE::forseq');

   my ($_user_func, $_params_ref);

   if (ref $_[1] eq 'HASH') {
      $_user_func = $_[2]; $_params_ref = $_[1];
   } else {
      $_user_func = $_[1]; $_params_ref = {};
   }

   @_ = ();

   MCE::_croak('MCE::forseq: (sequence) is not specified')
      unless (defined $_sequence);
   MCE::_croak('MCE::forseq: (code_block) is not specified')
      unless (defined $_user_func);

   $_params_ref->{sequence}   = $_sequence;
   $_params_ref->{user_func}  = $_user_func;

   $self->run(1, $_params_ref);

   return $self;
}

###############################################################################
## ----------------------------------------------------------------------------
## Output iterators for preserving output order.
##
###############################################################################

sub out_iter_array {

   my $_aref = shift; my %_tmp; my $_order_id = 1;

   if (ref $_aref eq 'MCE::Shared::Object') {
      my $_pkg = $_aref->blessed;
      MCE::_croak('The argument to (out_iter_array) is not valid.')
         unless $_pkg->can('TIEARRAY');
   }
   else {
      MCE::_croak('The argument to (out_iter_array) is not an array ref.')
         unless (ref $_aref eq 'ARRAY');
   }

   return sub {
      my $_chunk_id = shift;

      if ($_chunk_id == $_order_id && keys %_tmp == 0) {
         ## already orderly
         $_order_id++, push @{ $_aref }, @_;
      }
      else {
         ## hold temporarily otherwise until orderly
         @{ $_tmp{ $_chunk_id } } = @_;

         while (1) {
            last unless exists $_tmp{ $_order_id };
            push @{ $_aref }, @{ delete $_tmp{ $_order_id++ } };
         }
      }
   };
}

sub out_iter_fh {

   my $_fh =  $_[0]; my %_tmp; my $_order_id = 1;
      $_fh = \$_[0] if (!ref $_fh && ref \$_[0]);

   MCE::_croak('The argument to (out_iter_fh) is not a supported file handle.')
      unless (ref($_fh) =~ /^(?:GLOB|FileHandle|IO::)/);

   if ($_fh->can('print')) {
      return sub {
         my $_chunk_id = shift;

         if ($_chunk_id == $_order_id && keys %_tmp == 0) {
            ## already orderly
            $_order_id++, $_fh->print(@_);
         }
         else {
            ## hold temporarily otherwise until orderly
            @{ $_tmp{ $_chunk_id } } = @_;

            while (1) {
               last unless exists $_tmp{ $_order_id };
               $_fh->print(@{ delete $_tmp{ $_order_id++ } });
            }
         }
      };
   }
   else {
      return sub {
         my $_chunk_id = shift;

         if ($_chunk_id == $_order_id && keys %_tmp == 0) {
            ## already orderly
            $_order_id++, print {$_fh} @_;
         }
         else {
            ## hold temporarily otherwise until orderly
            @{ $_tmp{ $_chunk_id } } = @_;

            while (1) {
               last unless exists $_tmp{ $_order_id };
               print {$_fh} @{ delete $_tmp{ $_order_id++ } };
            }
         }
      };
   }
}

1;

__END__

###############################################################################
## ----------------------------------------------------------------------------
## Module usage.
##
###############################################################################

=head1 NAME

MCE::Candy - Sugar methods and output iterators

=head1 VERSION

This document describes MCE::Candy version 1.879

=head1 DESCRIPTION

This module provides a collection of sugar methods and helpful output iterators
for preserving output order.

=head1 "FOR" SUGAR METHODS

The sugar methods described below were created prior to the 1.5 release which
added MCE Models. This module is loaded automatically upon calling a "for"
method.

=head2 $mce->forchunk ( $input_data [, { options } ], sub { ... } )

Forchunk, foreach, and forseq are sugar methods in MCE. Workers are
spawned automatically, the code block is executed in parallel, and shutdown
is called. Do not call these methods if workers must persist afterwards.

Specifying options is optional. Valid options are the same as for the
process method.

 ## Declare a MCE instance.

 my $mce = MCE->new(
    max_workers => $max_workers,
    chunk_size  => 20
 );

 ## Arguments inside the code block are the same as passed to user_func.

 $mce->forchunk(\@input_array, sub {
    my ($mce, $chunk_ref, $chunk_id) = @_;
    foreach ( @{ $chunk_ref } ) {
       MCE->print("$chunk_id: $_\n");
    }
 });

 ## Input hash, current API available since 1.828.

 $mce->forchunk(\%input_hash, sub {
    my ($mce, $chunk_ref, $chunk_id) = @_;
    for my $key ( keys %{ $chunk_ref } ) {
       MCE->print("$chunk_id: [ $key ] ", $chunk_ref->{$key}, "\n");
    }
 });

 ## Passing chunk_size as an option.

 $mce->forchunk(\@input_array, { chunk_size => 30 }, sub { ... });
 $mce->forchunk(\%input_hash, { chunk_size => 30 }, sub { ... });

=head2 $mce->foreach ( $input_data [, { options } ], sub { ... } )

Foreach implies chunk_size => 1 and cannot be overwritten. Thus, looping is
not necessary inside the block. Unlike forchunk above, a hash reference as
input data isn't allowed.

 my $mce = MCE->new(
    max_workers => $max_workers
 );

 $mce->foreach(\@input_data, sub {
    my ($mce, $chunk_ref, $chunk_id) = @_;
    my $row = $chunk_ref->[0];
    MCE->print("$chunk_id: $row\n");
 });

=head2 $mce->forseq ( $sequence_spec [, { options } ], sub { ... } )

Sequence may be defined using an array or hash reference.

 my $mce = MCE->new(
    max_workers => 3
 );

 $mce->forseq([ 20, 40 ], sub {
    my ($mce, $n, $chunk_id) = @_;
    my $result = `ping 192.168.1.${n}`;
    ...
 });

 $mce->forseq({ begin => 15, end => 10, step => -1 }, sub {
    my ($mce, $n, $chunk_id) = @_;
    print $n, " from ", MCE->wid, "\n";
 });

The $n_seq variable points to an array_ref of sequences. Chunk size defaults
to 1 when not specified.

 $mce->forseq([ 20, 80 ], { chunk_size => 10 }, sub {
    my ($mce, $n_seq, $chunk_id) = @_;
    for my $n ( @{ $n_seq } ) {
       my $result = `ping 192.168.1.${n}`;
       ...
    }
 });

=head1 OUTPUT ITERATORS WITH INPUT

This module includes 2 output iterators which are useful for preserving output
order while gathering data. These cover the 2 general use cases. The chunk_id
value must be the first argument to gather. Gather must also not be called
more than once inside the block.

=head2 gather => MCE::Candy::out_iter_array( \@array )

The example utilizes the Core API with chunking disabled. Basically, setting
chunk_size to 1.

 use MCE;
 use MCE::Candy;

 my @results;

 my $mce = MCE->new(
    chunk_size => 1, max_workers => 4,
    gather => MCE::Candy::out_iter_array(\@results),
    user_func => sub {
       my ($mce, $chunk_ref, $chunk_id) = @_;
       $mce->gather($chunk_id, $chunk_ref->[0] * 2);
    }
 );

 $mce->process([ 100 .. 109 ]);

 print "@results", "\n";

 -- Output

 200 202 204 206 208 210 212 214 216 218

Chunking may be desired for thousands or more items. In other words, wanting
to reduce the overhead placed on IPC.

 use MCE;
 use MCE::Candy;

 my @results;

 my $mce = MCE->new(
    chunk_size => 100, max_workers => 4,
    gather => MCE::Candy::out_iter_array(\@results),
    user_func => sub {
       my ($mce, $chunk_ref, $chunk_id) = @_;
       my @output;
       foreach my $item (@{ $chunk_ref }) {
          push @output, $item * 2;
       }
       $mce->gather($chunk_id, @output);
    }
 );

 $mce->process([ 100_000 .. 200_000 - 1 ]);

 print scalar @results, "\n";

 -- Output

 100000

=head2 gather => MCE::Candy::out_iter_fh( $fh )

Let's change things a bit and use MCE::Flow for the next 2 examples. Chunking
is not desired for the first example.

 use MCE::Flow;
 use MCE::Candy;

 open my $fh, '>', '/tmp/foo.txt';

 mce_flow {
    chunk_size => 1, max_workers => 4,
    gather => MCE::Candy::out_iter_fh($fh)
 },
 sub {
    my ($mce, $chunk_ref, $chunk_id) = @_;
    $mce->gather($chunk_id, $chunk_ref->[0] * 2, "\n");

 }, (100 .. 109);

 close $fh;

 -- Output sent to '/tmp/foo.txt'

 200
 202
 204
 206
 208
 210
 212
 214
 216
 218

=head2 gather => MCE::Candy::out_iter_fh( $io )

Same thing, an C<IO::*> object that can C<print> is supported since MCE 1.845.

 use IO::All;
 use MCE::Flow;
 use MCE::Candy;

 my $io = io('/tmp/foo.txt');  # i.e. $io->can('print')

 mce_flow {
    chunk_size => 1, max_workers => 4,
    gather => MCE::Candy::out_iter_fh($io)
 },
 sub {
    my ($mce, $chunk_ref, $chunk_id) = @_;
    $mce->gather($chunk_id, $chunk_ref->[0] * 2, "\n");

 }, (100 .. 109);

 $io->close;

 -- Output sent to '/tmp/foo.txt'

 200
 202
 204
 206
 208
 210
 212
 214
 216
 218

Chunking is desired for the next example due to processing many thousands.

 use MCE::Flow;
 use MCE::Candy;

 open my $fh, '>', '/tmp/foo.txt';

 mce_flow {
    chunk_size => 100, max_workers => 4,
    gather => MCE::Candy::out_iter_fh( $fh )
 },
 sub {
    my ($mce, $chunk_ref, $chunk_id) = @_;
    my @output;
    foreach my $item (@{ $chunk_ref }) {
       push @output, ($item * 2) . "\n";
    }
    $mce->gather($chunk_id, @output);

 }, (100_000 .. 200_000 - 1);

 close $fh;

 print -s '/tmp/foo.txt', "\n";

 -- Output

 700000

=head1 OUTPUT ITERATORS WITHOUT INPUT

Input data is not a requirement for using the output iterators included in this
module. The 'chunk_id' value is set uniquely and the same as 'wid' when not
processing input data.

=head2 gather => MCE::Candy::out_iter_array( \@array )

 use MCE::Flow;
 use MCE::Candy;

 my @results;

 mce_flow {
    max_workers => 'auto', ## Note that 'auto' is never greater than 8
    gather => MCE::Candy::out_iter_array(\@results)
 },
 sub {
    my ($mce) = @_;        ## This line is not necessary
                           ## Calling via module okay; e.g: MCE->method
    ## Do work
    ## Sending a complex data structure is allowed

    ## Output will become orderly by iterator
    $mce->gather( $mce->chunk_id, {
       wid => $mce->wid, result => $mce->wid * 2
    });
 };

 foreach my $href (@results) {
    print $href->{wid} .": ". $href->{result} ."\n";
 }

 -- Output

 1: 2
 2: 4
 3: 6
 4: 8
 5: 10
 6: 12
 7: 14
 8: 16

=head2 gather => MCE::Candy::out_iter_fh( $fh )

 use MCE::Flow;
 use MCE::Candy;

 open my $fh, '>', '/tmp/out.txt';

 mce_flow {
    max_workers => 'auto', ## See get_ncpu in <MCE::Util|MCE::Util> 
    gather => MCE::Candy::out_iter_fh($fh)
 },
 sub {
    my $output = "# Worker ID: " . MCE->wid . "\n";

    ## Append results to $output string
    $output .= (MCE->wid * 2) . "\n\n";

    ## Output will become orderly by iterator
    MCE->gather( MCE->wid, $output );
 };

 close $fh;

 -- Output

 # Worker ID: 1
 2

 # Worker ID: 2
 4

 # Worker ID: 3
 6

 # Worker ID: 4
 8

 # Worker ID: 5
 10

 # Worker ID: 6
 12

 # Worker ID: 7
 14

 # Worker ID: 8
 16

=head1 INDEX

L<MCE|MCE>, L<MCE::Core>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

