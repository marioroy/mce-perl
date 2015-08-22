## Many-Core Engine for Perl

This document describes MCE version 1.699.

Many-Core Engine (MCE) for Perl helps enable a new level of performance by
maximizing all available cores. MCE spawns a pool of workers and therefore
does not fork a new process per each element of data. Instead, MCE follows
a bank queuing model. Imagine the line being the data and bank-tellers the
arallel workers. MCE enhances that model by adding the ability to chunk
the next n elements from the input stream to the next available worker.

### Installation

To install this module type the following:

    MCE_INSTALL_TOOLS=1 perl Makefile.PL   (e.g. bin/mce_grep)

    (or) perl Makefile.PL

    make
    make test
    make install

### Dependencies

This module requires Perl 5.8.0 or later to run. MCE spawns child processes
by default, not threads. However, MCE supports threads via 2 threading
libraries when threads is desired. The use of threads in MCE requires that
you include threads support prior to loading MCE.

Threads is loaded by default on Windows excluding Cygwin.

    use threads;                use forks;
    use threads::shared;  (or)  use forks::shared;  (or)
    use MCE;                    use MCE;                  use MCE;

MCE utilizes the following modules:

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

    -- Output

    Hello from 2
    Hello from 4
    Hello from 5
    Hello from 1
    Hello from 3

Parsing a huge log file.

    use MCE::Loop;

    MCE::Loop::init {
       max_workers => 8, use_slurpio => 1
    };

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

Talking to a DB.

    use DBI;
    use MCE;

    # Define user functions for MCE.

    sub myBegin {
        my ($mce) = @_;
        $mce->{db} = DBI->connect(
           "dbi:Oracle:<SERVER_NAME>", "<USERID>", "<PASSWORD>"
        ) || die($DBI::errstr . "\n");
        return;
    }
    sub myFunc {
        my ($mce, $chunk_ref, $chunk_id) = @_;
        my $db  = $mce->{db};
        my $row = $chunk_ref->[0];
    }
    sub myEnd {
        my ($mce) = @_;
        $mce->{db}->disconnect;
    }

    # Do some work with the database in order to fill up
    # the @array variable.

    my (@array, $db);

    $db = DBI->connect(
       "dbi:Oracle:<SERVER_NAME>", "<USERID>", "<PASSWORD>"
    ) || die($DBI::errstr . "\n");

    $db->disconnect;

    # Process the array one row at a time.

    my $mce = MCE->new(
       chunk_size => 1,
       max_workers => 4,
       input_data => \@array,
       user_begin => \&myBegin,
       user_func => \&myFunc,
       user_end => \&myEnd
    );

    $mce->run;

### Documentation

The documentation is best viewed at https://metacpan.org/pod/MCE.
MCE options are described in https://metacpan.org/pod/MCE::Core.

Also see https://metacpan.org/pod/MCE::Examples.

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

