## Many-Core Engine for Perl

This document describes MCE version 1.699.

Many-Core Engine (MCE) for Perl helps enable a new level of performance by
maximizing all available cores.

![ScreenShot](https://raw.githubusercontent.com/marioroy/mce-assets/master/images_README/MCE.gif)

### Description

MCE spawns a pool of workers and therefore does not fork a new process per
each element of data. Instead, MCE follows a bank queuing model. Imagine the
line being the data and bank-tellers the arallel workers. MCE enhances that
model by adding the ability to chunk the next n elements from the input
stream to the next available worker.

![ScreenShot](https://raw.githubusercontent.com/marioroy/mce-assets/master/images_README/Bank_Queuing_Model.gif)

### Installation and Dependencies

To install this module type the following:

    MCE_INSTALL_TOOLS=1 perl Makefile.PL   (e.g. bin/mce_grep)

    (or) perl Makefile.PL

    make
    make test
    make install

This module requires Perl 5.8.0 or later to run. By default, MCE spawns threads
on Windows and child processes otherwise for Cygwin and Unix platforms. The use
of threads requires that you include threads support prior to loading MCE.

    child processes          use threads;                  use forks;
                      (or)   use threads::shared;   (or)   use forks::shared;
    use MCE;                 use MCE;                      use MCE;

![ScreenShot](https://raw.githubusercontent.com/marioroy/mce-assets/master/images_README/Supported_OS.gif)

MCE utilizes the following modules, which are included with Perl normally:

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

Parsing a huge log file.

```perl
 use MCE::Loop;

 MCE::Loop::init { max_workers => 8, use_slurpio => 1 };

 my $pattern  = 'karl';
 my $hugefile = 'very_huge.file';

 my @result = mce_loop_f {
    my ($mce, $slurp_ref, $chunk_id) = @_;

    # Quickly determine if a match is found.
    # Process slurped chunk only if true.

    if ($$slurp_ref =~ /$pattern/m) {
       my @matches;

       open my $MEM_FH, '<', $slurp_ref;
       binmode $MEM_FH, ':raw';
       while (<$MEM_FH>) { push @matches, $_ if (/$pattern/); }
       close   $MEM_FH;

       MCE->gather(@matches);
    }

 } $hugefile;

 print join('', @result);
```

Looping through a sequence of numbers.

```perl

 use feature 'say';

 use MCE::Flow;
 use MCE::Number;
 use MCE::Shared;

 # Auto-shareable number when MCE::Shared is present

 my $g_count = MCE::Number->new(0);

 # PI calculation

 sub mcpi_3 {
    my ( $begin_seq, $end_seq ) = @_;
    my ( $count, $n, $m ) = ( 0 );

    foreach my $i ( $begin_seq .. $end_seq ){
       ( $n, $m ) = ( rand, rand );
       $count++ if (( $n * $n + $m * $m ) > 1 );
    }

    $g_count->Add( $count );
 }

 # Compute bounds only; workers receive [ begin, end ] values

 MCE::Flow::init { bounds_only => 1 };

 # Compute PI

 my $runs = shift || 1e6;

 mce_flow_s sub { mcpi_3( $_->[0], $_->[1] ) }, 1, $runs;

 say 4 * ( 1 - $g_count->Val / $runs );

```

### Further Reading

The Perl MCE documentation is best viewed at https://metacpan.org/pod/MCE.

MCE options are described in https://metacpan.org/pod/MCE::Core.

See https://metacpan.org/pod/MCE::Examples and
https://github.com/marioroy/mce-cookbook for other recipes.

### Copyright and Licensing

Copyright (C) 2012-2015 by Mario E. Roy <marioeroy AT gmail DOT com>

This program is free software; you can redistribute it and/or modify
it under the terms of either:

        a) the GNU General Public License as published by the Free
        Software Foundation; either version 1, or (at your option) any
        later version, or

        b) the "Artistic License" which comes with this Kit.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See either
the GNU General Public License or the Artistic License for more details.

You should have received a copy of the Artistic License with this
Kit, in the file named "Artistic".  If not, I'll be glad to provide one.

You should also have received a copy of the GNU General Public License
along with this program in the file named "Copying". If not, write to the
Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
Boston, MA 02110-1301, USA or visit their web page on the internet at
http://www.gnu.org/copyleft/gpl.html.

