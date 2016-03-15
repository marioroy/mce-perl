
# Module makefile for MCE (using ExtUtils::MakeMaker)

use 5.008;

use strict;
use warnings;

use ExtUtils::MakeMaker;

my @exe_files;

if ($ENV{MCE_INSTALL_TOOLS}) {
   push @exe_files, 'bin/mce_grep';
}

WriteMakefile(
   ABSTRACT => 'Many-Core Engine for Perl providing parallel processing capabilities',
   AUTHOR   => 'Mario E. Roy <marioeroy AT gmail DOT com>',
   NAME     => 'MCE',
   VERSION  => '1.702',

   EXE_FILES => [ @exe_files ],

   PREREQ_PM => {
      'base'         => 0,
      'bytes'        => 0,
      'constant'     => 0,
      'strict'       => 0,
      'warnings'     => 0,
      'Carp'         => 0,
      'Fcntl'        => 0,
      'File::Path'   => 0,
      'Getopt::Long' => 0,
      'IO::Handle'   => 0,
      'POSIX'        => 0,
      'Scalar::Util' => 0,
      'Socket'       => 0,
      'Storable'     => 2.04,
      'Symbol'       => 0,
      'Time::HiRes'  => 0
   },

   ((!eval { ExtUtils::MakeMaker->VERSION(6.25) } ) ?
      ( PL_FILES => {} ) : () ),

   (( eval { ExtUtils::MakeMaker->VERSION(6.31) } ) ?
      ( LICENSE => 'perl' ) : () ),

   (( eval { ExtUtils::MakeMaker->VERSION(6.46) } ) ?
      ( META_MERGE => {
         'build_requires' => {
            'ExtUtils::MakeMaker' => 0,
            'Test::More'          => 0.45
         },
         'no_index' => {
            'file' => [
               'bin/mce_grep'
            ]
         },
         'resources' => {
            'homepage'   => 'https://github.com/marioroy/mce-perl',
            'repository' => 'https://github.com/marioroy/mce-perl',
            'license'    => 'http://dev.perl.org/licenses/'
         },
         'provides' => {
            'MCE' => {
               'file'    => 'lib/MCE.pm',
               'version' => '1.702'
            },
            'MCE::Candy' => {
               'file'    => 'lib/MCE/Candy.pm',
               'version' => '1.702'
            },
            'MCE::Core::Input::Generator' => {
               'file'    => 'lib/MCE/Core/Input/Generator.pm',
               'version' => '1.702'
            },
            'MCE::Core::Input::Handle' => {
               'file'    => 'lib/MCE/Core/Input/Handle.pm',
               'version' => '1.702'
            },
            'MCE::Core::Input::Iterator' => {
               'file'    => 'lib/MCE/Core/Input/Iterator.pm',
               'version' => '1.702'
            },
            'MCE::Core::Input::Request' => {
               'file'    => 'lib/MCE/Core/Input/Request.pm',
               'version' => '1.702'
            },
            'MCE::Core::Input::Sequence' => {
               'file'    => 'lib/MCE/Core/Input/Sequence.pm',
               'version' => '1.702'
            },
            'MCE::Core::Manager' => {
               'file'    => 'lib/MCE/Core/Manager.pm',
               'version' => '1.702'
            },
            'MCE::Core::Validation' => {
               'file'    => 'lib/MCE/Core/Validation.pm',
               'version' => '1.702'
            },
            'MCE::Core::Worker' => {
               'file'    => 'lib/MCE/Core/Worker.pm',
               'version' => '1.702'
            },
            'MCE::Flow' => {
               'file'    => 'lib/MCE/Flow.pm',
               'version' => '1.702'
            },
            'MCE::Grep' => {
               'file'    => 'lib/MCE/Grep.pm',
               'version' => '1.702'
            },
            'MCE::Loop' => {
               'file'    => 'lib/MCE/Loop.pm',
               'version' => '1.702'
            },
            'MCE::Map' => {
               'file'    => 'lib/MCE/Map.pm',
               'version' => '1.702'
            },
            'MCE::Mutex' => {
               'file'    => 'lib/MCE/Mutex.pm',
               'version' => '1.702'
            },
            'MCE::Queue' => {
               'file'    => 'lib/MCE/Queue.pm',
               'version' => '1.702'
            },
            'MCE::Relay' => {
               'file'    => 'lib/MCE/Relay.pm',
               'version' => '1.702'
            },
            'MCE::Signal' => {
               'file'    => 'lib/MCE/Signal.pm',
               'version' => '1.702'
            },
            'MCE::Step' => {
               'file'    => 'lib/MCE/Step.pm',
               'version' => '1.702'
            },
            'MCE::Stream' => {
               'file'    => 'lib/MCE/Stream.pm',
               'version' => '1.702'
            },
            'MCE::Subs' => {
               'file'    => 'lib/MCE/Subs.pm',
               'version' => '1.702'
            },
            'MCE::Util' => {
               'file'    => 'lib/MCE/Util.pm',
               'version' => '1.702'
            }
         }
      } ) : () ),

   (( eval { ExtUtils::MakeMaker->VERSION(6.48) } ) ?
      ( MIN_PERL_VERSION => 5.008 ) : () ),

   INSTALLDIRS => ( ($] < 5.011) ? 'perl' : 'site' )
);

