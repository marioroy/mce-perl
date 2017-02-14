## Many-Core Engine for Perl

This document describes MCE version 1.811.

Many-Core Engine (MCE) for Perl helps enable a new level of performance by
maximizing all available cores.

![ScreenShot](https://raw.githubusercontent.com/marioroy/mce-assets/master/images_README/MCE.png)

### Description

MCE spawns a pool of workers and therefore does not fork a new process per
each element of data. Instead, MCE follows a bank queuing model. Imagine the
line being the data and bank-tellers the parallel workers. MCE enhances that
model by adding the ability to chunk the next n elements from the input
stream to the next available worker.

![ScreenShot](https://raw.githubusercontent.com/marioroy/mce-assets/master/images_README/Bank_Queuing_Model.png)

### Synopsis

This is a simplistic use case of MCE running with 5 workers.

```perl
 # Construction using the Core API

 use MCE;

 my $mce = MCE->new(
    max_workers => 5,
    user_func => sub {
       my ($mce) = @_;
       $mce->say("Hello from " . $mce->wid);
    }
 );

 $mce->run;

 # Construction using a MCE model

 use MCE::Flow max_workers => 5;

 mce_flow sub {
    my ($mce) = @_;
    MCE->say("Hello from " . MCE->wid);
 };
```

The following is a demonstration for parsing a huge log file in parallel.

```perl
 use MCE::Loop;

 MCE::Loop::init { max_workers => 8, use_slurpio => 1 };

 my $pattern  = 'something';
 my $hugefile = 'very_huge.file';

 my @result = mce_loop_f {
    my ($mce, $slurp_ref, $chunk_id) = @_;

    # Quickly determine if a match is found.
    # Process the slurped chunk only if true.

    if ($$slurp_ref =~ /$pattern/m) {
       my @matches;

       # The following is fast on Unix, but performance degrades
       # drastically on Windows beyond 4 workers.

       open my $MEM_FH, '<', $slurp_ref;
       binmode $MEM_FH, ':raw';
       while (<$MEM_FH>) { push @matches, $_ if (/$pattern/); }
       close   $MEM_FH;

       # Therefore, use the following construction on Windows.

       while ( $$slurp_ref =~ /([^\n]+\n)/mg ) {
          my $line = $1; # save $1 to not lose the value
          push @matches, $line if ($line =~ /$pattern/);
       }

       # Gather matched lines.

       MCE->gather(@matches);
    }

 } $hugefile;

 print join('', @result);
```

The next demonstration loops through a sequence of numbers with MCE::Flow.

```perl
 use MCE::Flow;

 my $N = shift || 4_000_000;

 sub compute_pi {
    my ( $beg_seq, $end_seq ) = @_;
    my ( $pi, $t ) = ( 0.0 );

    foreach my $i ( $beg_seq .. $end_seq ) {
       $t = ( $i + 0.5 ) / $N;
       $pi += 4.0 / ( 1.0 + $t * $t );
    }

    MCE->gather( $pi );
 }

 # Compute bounds only, workers receive [ begin, end ] values

 MCE::Flow::init(
    chunk_size  => 200_000,
    max_workers => 8,
    bounds_only => 1
 );

 my @ret = mce_flow_s sub {
    compute_pi( $_->[0], $_->[1] );
 }, 0, $N - 1;

 my $pi = 0.0;  $pi += $_ for @ret;

 printf "pi = %0.13f\n", $pi / $N;  # 3.1415926535898
```

### Installation and Dependencies

To install this module type the following:

    MCE_INSTALL_TOOLS=1 perl Makefile.PL   (for bin/mce_grep)

    (or) perl Makefile.PL

    make
    make test
    make install

This module requires Perl 5.8.0 or later to run. By default, MCE spawns threads
on Windows and child processes otherwise for Cygwin and Unix platforms. The use
of threads requires that you include threads support prior to loading MCE.

    processes          use threads;                  use forks;
                (or)   use threads::shared;   (or)   use forks::shared;
    use MCE;           use MCE;                      use MCE;

![ScreenShot](https://raw.githubusercontent.com/marioroy/mce-assets/master/images_README/Supported_OS.png)

MCE utilizes the following modules, which are typically installed with Perl:

    bytes
    constant
    Carp
    Fcntl
    File::Path
    IO::Handle
    Scalar::Util
    Socket
    Storable 2.04+
    Symbol
    Test::More 0.45+ (for make test only)
    Time::HiRes

### Further Reading

The Perl MCE module is described at https://metacpan.org/pod/MCE.

See [MCE::Examples](https://metacpan.org/pod/MCE::Examples)
and [MCE Cookbook](https://github.com/marioroy/mce-cookbook) for recipes.

### Copyright and Licensing

Copyright (C) 2012-2016 by Mario E. Roy <marioeroy AT gmail DOT com>

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself:

        a) the GNU General Public License as published by the Free
        Software Foundation; either version 1, or (at your option) any
        later version, or

        b) the "Artistic License" which comes with this Kit.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See either
the GNU General Public License or the Artistic License for more details.

You should have received a copy of the Artistic License with this
Kit, in the file named "LICENSE".  If not, I'll be glad to provide one.

You should also have received a copy of the GNU General Public License
along with this program in the file named "Copying". If not, write to the
Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
Boston, MA 02110-1301, USA or visit their web page on the internet at
http://www.gnu.org/copyleft/gpl.html.

