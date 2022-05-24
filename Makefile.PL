
# Module makefile for MCE (using ExtUtils::MakeMaker)

use strict;
use warnings;
use 5.008001;

use ExtUtils::MakeMaker;

my @exe_files;

if ($ENV{MCE_INSTALL_TOOLS}) {
   push @exe_files, 'bin/mce_grep';
}

WriteMakefile(
   ABSTRACT => 'Many-Core Engine for Perl providing parallel processing capabilities',
   AUTHOR   => 'Mario E. Roy <marioeroy AT gmail DOT com>',
   NAME     => 'MCE',
   VERSION  => '1.879',

   EXE_FILES => [ @exe_files ],

   NO_META  => 1,

   PREREQ_PM => {
      'base'         => 0,
      'bytes'        => 0,
      'constant'     => 0,
      'open'         => 0,
      'strict'       => 0,
      'warnings'     => 0,
      'Carp'         => 0,
      'Errno'        => 0,
      'Fcntl'        => 0,
      'File::Path'   => 0,
      'Getopt::Long' => 0,
      'IO::Handle'   => 0,
      'Scalar::Util' => 0,
      'Socket'       => 0,
      'Storable'     => 2.04,
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
            'Test::More'          => 0.88
         },
         'no_index' => {
            'file' => [
               'bin/mce_grep'
            ]
         },
         'resources' => {
            'bugtracker' => 'https://github.com/marioroy/mce-perl/issues',
            'homepage'   => 'https://github.com/marioroy/mce-perl',
            'license'    => 'https://dev.perl.org/licenses/',
            'repository' => 'https://github.com/marioroy/mce-perl.git'
         },
         'provides' => {
            'MCE' => {
               'file'    => 'lib/MCE.pm',
               'version' => '1.879'
            },
            'MCE::Candy' => {
               'file'    => 'lib/MCE/Candy.pm',
               'version' => '1.879'
            },
            'MCE::Channel' => {
               'file'    => 'lib/MCE/Channel.pm',
               'version' => '1.879'
            },
            'MCE::Channel::Mutex' => {
               'file'    => 'lib/MCE/Channel/Mutex.pm',
               'version' => '1.879'
            },
            'MCE::Channel::MutexFast' => {
               'file'    => 'lib/MCE/Channel/MutexFast.pm',
               'version' => '1.879'
            },
            'MCE::Channel::Simple' => {
               'file'    => 'lib/MCE/Channel/Simple.pm',
               'version' => '1.879'
            },
            'MCE::Channel::SimpleFast' => {
               'file'    => 'lib/MCE/Channel/SimpleFast.pm',
               'version' => '1.879'
            },
            'MCE::Channel::Threads' => {
               'file'    => 'lib/MCE/Channel/Threads.pm',
               'version' => '1.879'
            },
            'MCE::Channel::ThreadsFast' => {
               'file'    => 'lib/MCE/Channel/ThreadsFast.pm',
               'version' => '1.879'
            },
            'MCE::Child' => {
               'file'    => 'lib/MCE/Child.pm',
               'version' => '1.879'
            },
            'MCE::Core::Input::Generator' => {
               'file'    => 'lib/MCE/Core/Input/Generator.pm',
               'version' => '1.879'
            },
            'MCE::Core::Input::Handle' => {
               'file'    => 'lib/MCE/Core/Input/Handle.pm',
               'version' => '1.879'
            },
            'MCE::Core::Input::Iterator' => {
               'file'    => 'lib/MCE/Core/Input/Iterator.pm',
               'version' => '1.879'
            },
            'MCE::Core::Input::Request' => {
               'file'    => 'lib/MCE/Core/Input/Request.pm',
               'version' => '1.879'
            },
            'MCE::Core::Input::Sequence' => {
               'file'    => 'lib/MCE/Core/Input/Sequence.pm',
               'version' => '1.879'
            },
            'MCE::Core::Manager' => {
               'file'    => 'lib/MCE/Core/Manager.pm',
               'version' => '1.879'
            },
            'MCE::Core::Validation' => {
               'file'    => 'lib/MCE/Core/Validation.pm',
               'version' => '1.879'
            },
            'MCE::Core::Worker' => {
               'file'    => 'lib/MCE/Core/Worker.pm',
               'version' => '1.879'
            },
            'MCE::Flow' => {
               'file'    => 'lib/MCE/Flow.pm',
               'version' => '1.879'
            },
            'MCE::Grep' => {
               'file'    => 'lib/MCE/Grep.pm',
               'version' => '1.879'
            },
            'MCE::Loop' => {
               'file'    => 'lib/MCE/Loop.pm',
               'version' => '1.879'
            },
            'MCE::Map' => {
               'file'    => 'lib/MCE/Map.pm',
               'version' => '1.879'
            },
            'MCE::Mutex' => {
               'file'    => 'lib/MCE/Mutex.pm',
               'version' => '1.879'
            },
            'MCE::Mutex::Channel' => {
               'file'    => 'lib/MCE/Mutex/Channel.pm',
               'version' => '1.879'
            },
            'MCE::Mutex::Channel2' => {
               'file'    => 'lib/MCE/Mutex/Channel2.pm',
               'version' => '1.879'
            },
            'MCE::Mutex::Flock' => {
               'file'    => 'lib/MCE/Mutex/Flock.pm',
               'version' => '1.879'
            },
            'MCE::Queue' => {
               'file'    => 'lib/MCE/Queue.pm',
               'version' => '1.879'
            },
            'MCE::Relay' => {
               'file'    => 'lib/MCE/Relay.pm',
               'version' => '1.879'
            },
            'MCE::Signal' => {
               'file'    => 'lib/MCE/Signal.pm',
               'version' => '1.879'
            },
            'MCE::Step' => {
               'file'    => 'lib/MCE/Step.pm',
               'version' => '1.879'
            },
            'MCE::Stream' => {
               'file'    => 'lib/MCE/Stream.pm',
               'version' => '1.879'
            },
            'MCE::Subs' => {
               'file'    => 'lib/MCE/Subs.pm',
               'version' => '1.879'
            },
            'MCE::Util' => {
               'file'    => 'lib/MCE/Util.pm',
               'version' => '1.879'
            }
         },
         'prereqs' => {
            runtime => {
               recommends => {
                  'Sereal::Decoder' => '3.015',
                  'Sereal::Encoder' => '3.015'
               }
            }
         }
      } ) : () ),

   (( eval { ExtUtils::MakeMaker->VERSION(6.48) } ) ?
      ( MIN_PERL_VERSION => 5.008001 ) : () ),

   INSTALLDIRS => ( ($] < 5.011) ? 'perl' : 'site' )
);

