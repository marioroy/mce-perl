Name:           perl-MCE
Version:        1.699
Release:        1%{?dist}
Summary:        Many-Core Engine for Perl providing parallel processing capabilities
License:        GPL+ or Artistic
Group:          Development/Libraries
URL:            http://search.cpan.org/dist/MCE/
Source0:        http://www.cpan.org/authors/id/M/MA/MARIOROY/MCE-%{version}.tar.gz
BuildRoot:      %{_tmppath}/%{name}-%{version}-%{release}-root-%(%{__id_u} -n)
BuildArch:      noarch
# Build
BuildRequires:  perl
BuildRequires:  perl(ExtUtils::MakeMaker)
BuildRequires:  perl(Test::More) >= 0.45
# Runtime
Requires:       perl(:MODULE_COMPAT_%(eval "`%{__perl} -V:version`"; echo $version))
Requires:       perl(bytes)
Requires:       perl(constant)
Requires:       perl(Carp)
Requires:       perl(Fcntl)
Requires:       perl(File::Path)
Requires:       perl(IO::Handle)
Requires:       perl(Scalar::Util)
Requires:       perl(Socket)
Requires:       perl(Storable) >= 2.04
Requires:       perl(Symbol)
Requires:       perl(Time::HiRes)
Autoreq:        no

%description
Many-Core Engine (MCE) for Perl helps enable a new level of performance by
maximizing all available cores. MCE spawns a pool of workers and therefore
does not fork a new process per each element of data. Instead, MCE follows
a bank queuing model. Imagine the line being the data and bank-tellers the
parallel workers. MCE enhances that model by adding the ability to chunk
the next n elements from the input stream to the next available worker.

%prep
%setup -q -n MCE-%{version}

%build
MCE_INSTALL_TOOLS=1 %{__perl} Makefile.PL INSTALLDIRS=vendor
make %{?_smp_mflags}

%install
make pure_install PERL_INSTALL_ROOT=%{buildroot}
find %{buildroot} -type f -name .packlist -exec rm -f {} \;
%{_fixperms} %{buildroot}/*

%check
make test

%clean
rm -rf %{buildroot}

%files
%defattr(-,root,root,-)
%doc CHANGES CREDITS LICENSE README.md
%{perl_vendorlib}/*
%{_bindir}/mce_grep
%{_mandir}/man3/*

%changelog
* Wed Aug 12 2015 Mario Roy 1.699-1
- 1.699 Release.
