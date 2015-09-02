###############################################################################
## ----------------------------------------------------------------------------
## MCE::OrdHash -- A shareable pure-Perl ordered hash class.
##
###############################################################################

package MCE::OrdHash;

use strict;
use warnings;

no warnings 'threads';
no warnings 'recursion';
no warnings 'uninitialized';
no warnings 'numeric';

our $VERSION = '1.699_001';

## no critic (BuiltinFunctions::ProhibitStringyEval)
## no critic (Subroutines::ProhibitExplicitReturnUndef)
## no critic (TestingAndDebugging::ProhibitNoStrict)

use Scalar::Util qw( refaddr );

use constant {
    ERROR_DUPLICATE_KEYS      => 'found duplicate keys',
    ERROR_KEY_LENGTH_MISMATCH => 'incorrect number of keys',
    ERROR_KEY_VALUE_PAIRS     => 'requires key-value pairs',
};

use constant {
    _TOMBSTONE => \1, # ref to arbitrary scalar
};

use constant {
    _DATA => 0,  # unordered data
    _KEYS => 1,  # ordered ids with keys
    _INDX => 2,  # index into _KEYS (on demand)
    _BEGI => 3,  # next ordered id for optimized shift/unshift
    _GCNT => 4,  # garbage count
    _ITER => 5,  # for tied hash support
    _CURS => 6,  # for next, prev, reset
    _TIED => 7,  # is hash constructed via tie
    _HREF => 8,  # for dereferencing support
};

## overloading.pm is not available until 5.10.1 so emulate with refaddr
## tip found in Hash::Ordered by David Golden

my ($_numify, $_strify);

BEGIN {
  local $@;
  if ($] le '5.010000') {
    eval q{
      $_numify = sub { refaddr($_[0]) };
      $_strify = sub { sprintf "%s=ARRAY(0x%x)",ref($_[0]),refaddr($_[0]) };
    }; die $@ if $@;
  }
  else {
    eval q{
      $_numify = sub { no overloading; 0 + $_[0]  };
      $_strify = sub { no overloading;    "$_[0]" };
    }; die $@ if $@;
  }
}

use overload
    q("")    => $_strify,
    q(0+)    => $_numify,
    q(%{})   => sub {
        $_[0]->[_HREF] || do {
            my %h; tie %h, 'MCE::OrdHash::_href', $_[0];
            $_[0]->[_HREF] = \%h;
        };
    },
    fallback => 1;

###############################################################################
## ----------------------------------------------------------------------------
## _new, STORE, FETCH, DELETE, FIRSTKEY, NEXTKEY, EXISTS, CLEAR, SCALAR
##
###############################################################################

sub _new {
    my ( $tied, $class ) = ( shift, shift );
    my ( $key, %data, @keys );

    die ERROR_KEY_VALUE_PAIRS unless ( @_ % 2 == 0 );

    while ( @_ ) {
        $key = shift;
        push(@keys, "$key") unless exists $data{ $key };

        $data{ $key } = shift;
    }

    bless [ \%data, \@keys, undef, 0, 0, undef, undef, $tied ], $class;
}

sub STORE {
    my ( $self, $key ) = @_; # don't copy $_[2] in case it's large
    push(@{ $self->[_KEYS] }, "$key") unless exists $self->[_DATA]{ $key };

    $self->[_DATA]{ $key } = (ref $_[2] eq 'HASH')
        ? do {
              if ($self->[_TIED]) {
                  tie my( %hash ), 'MCE::OrdHash', %{ $_[2] };
                  \%hash;
              }
              else {
                  MCE::OrdHash->new(%{ $_[2] });
              }
          }
        : $_[2];
}

sub FETCH {
    $_[0]->[_DATA]{ $_[1] };
}

sub DELETE {
    my ( $self, $key ) = @_;

    if ( @_ == 2 ) {
        ## tombstone deletion, inspired by Hash::Ordered v0.009
        if ( exists $self->[_DATA]{ $key } ) {
            my $keys = $self->[_KEYS];

            ## check if deleting the first key
            if ( $key eq $keys->[0] ) {
                delete $self->[_INDX]{ $key } if $self->[_INDX];
                $self->[_BEGI]++, shift @{ $keys };

                $self->[_ITER]-- if $self->[_ITER]  > 0;
                $self->[_CURS]-- if $self->[_CURS] == 0;

                ## garbage collect start of list
                if ( @{ $keys } && ref $keys->[0] ) {
                    my ( $gcnt, $i ) = ( $self->[_GCNT], 0 );
                    while ( $gcnt ) {
                        $gcnt--, $i++, shift @{ $keys };
                        last if !ref $keys->[0];
                    }
                    $self->[_BEGI] += $i, $self->[_GCNT] = $gcnt;
                }
            }

            ## or maybe the last key
            elsif ( $key eq $keys->[-1] ) {
                delete $self->[_INDX]{ $key } if $self->[_INDX];
                pop @{ $keys };

                ## garbage collect end of list
                if ( @{ $keys } && ref $keys->[-1] ) {
                    my $gcnt = $self->[_GCNT];
                    while ( $gcnt ) {
                        $gcnt--, pop @{ $keys };
                        last if !ref $keys->[-1];
                    }
                    $self->[_GCNT] = $gcnt;
                }
            }

            ## otherwise, deletion is from the middle
            else {
                my $indx = $self->[_INDX] || $self->_make_indx;
                my $id   = delete $indx->{ $key };

                $self->_fill_indx, $id = delete $indx->{ $key } if !defined $id;
                $keys->[ $id - $self->[_BEGI] ] = _TOMBSTONE;

                ## GC keys if more than half have been deleted
                $self->Reindex if ++$self->[_GCNT] > ( @{ $keys } >> 1 );
            }

            delete $self->[_DATA]{ $key };
        }
        else {
            undef;
        }
    }
    else {
        ## for Tie::IxHash::Delete compatibility
        shift;
        $self->DELETE( $_ ) for ( @_ );
    }
}

sub FIRSTKEY {
    $_[0]->[_ITER] = 0;
    $_[0]->NEXTKEY();
}

sub NEXTKEY {
    my ( $self ) = @_;
    my ( $keys, $iter, $flg ) = ( $self->[_KEYS], $self->[_ITER], 0 );

    $flg = 1, $iter++ while ref($keys->[ $iter ]) && $iter < @{ $keys };
    $self->[_ITER] = $iter if $flg;

    ( $iter < @{ $keys } ) ? $keys->[ $self->[_ITER]++ ] : ();
}

sub EXISTS {
    exists $_[0]->[_DATA]{ $_[1] };
}

sub CLEAR {
    my ( $self ) = @_;

    %{ $self->[_DATA] } = ();
    @{ $self->[_KEYS] } = ();

    splice( @{ $self }, 2, 5, undef, 0, 0, undef, undef );

    return;
}

sub SCALAR {
    @{ $_[0]->[_KEYS] } - $_[0]->[_GCNT];
}

###############################################################################
## ----------------------------------------------------------------------------
## KeysInd (indices), ValuesInd (indices), PairsInd (indices)
## Keys    (keys   ), Values    (keys   ), Pairs    (keys   )
##
###############################################################################

sub KeysInd {                                     ## ( @indices )
    my $self = CORE::shift;
    return $self->Keys unless @_;

    $self->Reindex if $self->[_GCNT];

    if (@_ == 1) {
        my $key = $self->[_KEYS][ $_[0] ];
        defined $key ? $key : undef;
    }
    else {
        CORE::map { defined $_ ? $_ : undef } @{ $self->[_KEYS] }[ @_ ];
    }
}

sub Keys {                                        ## ( @keys )
    my $self = CORE::shift;

    if (wantarray) {
        my $data = $self->[_DATA];
        @_ ? CORE::map { CORE::exists $data->{ $_ } ? $_ : undef } @_
           : CORE::grep !ref($_), @{ $self->[_KEYS] };
    }
    else {
        @{ $self->[_KEYS] } - $self->[_GCNT];
    }
}

sub ValuesInd {                                   ## ( @indices )
    my $self = CORE::shift;
    return $self->Values unless @_;

    $self->Reindex if $self->[_GCNT];

    if (@_ == 1) {
        my $key = $self->[_KEYS][ $_[0] ];
        defined $key ? $self->[_DATA]{ $key } : undef;
    }
    else {
        @{ $self->[_DATA] }{ @{ $self->[_KEYS] }[ @_ ] };
    }
}

sub Values {                                      ## ( @keys )
    my $self = CORE::shift;

    if (wantarray) {
        @_ ? @{ $self->[_DATA] }{ @_ }
           : @{ $self->[_DATA] }{ CORE::grep !ref($_), @{ $self->[_KEYS] } };
    }
    else {
        @{ $self->[_KEYS] } - $self->[_GCNT];
    }
}

sub PairsInd {                                    ## ( @indices )
    my $self = CORE::shift;
    return $self->Pairs unless @_;

    $self->Reindex if $self->[_GCNT];

    my $data = $self->[_DATA];

    if (@_ == 1) {
        my $key = $self->[_KEYS][ $_[0] ];
        defined $key ? ( $key, $data->{ $key } ) : ( undef, undef );
    }
    else {
        CORE::map { $_, $data->{ $_ } } @{ $self->[_KEYS] }[ @_ ];
    }
}

sub Pairs {                                       ## ( @keys )
    my $self = CORE::shift;

    if (wantarray) {
        my $data = $self->[_DATA];
        @_ ? CORE::map { $_ => $data->{ $_ } } @_
           : CORE::map { $_ => $data->{ $_ } }
                 CORE::grep !ref($_), @{ $self->[_KEYS] };
    }
    else {
        ( @{ $self->[_KEYS] } - $self->[_GCNT] ) << 1;
    }
}

###############################################################################
## ----------------------------------------------------------------------------
## Pop, Push    (merge  ), Shift, Unshift    (merge  ), Splice
##      PushNew (reorder),        UnshiftNew (reorder),
##
###############################################################################

sub Pop {
    my $self = CORE::shift;
    my $key  = CORE::pop @{ $self->[_KEYS] };

    ## garbage collect end of list
    if ( $self->[_GCNT] ) {
        my $keys = $self->[_KEYS];
        if ( @{ $keys } && ref $keys->[-1] ) {
            my $gcnt = $self->[_GCNT];
            while ( $gcnt ) {
                $gcnt--, pop @{ $keys };
                last if !ref $keys->[-1];
            }
            $self->[_GCNT] = $gcnt;
        }
    }

    if ( defined $key ) {
        CORE::delete $self->[_INDX]{ $key } if $self->[_INDX];

        return $key, CORE::delete $self->[_DATA]{ $key };
    }

    return;
}

sub Push {                                        ## ( @pairs ); merge
    my $self = CORE::shift;
    my ($data, $keys) = @$self;

    while (@_) {
        my ($key, $val) = CORE::splice(@_, 0, 2);

        CORE::push(@{ $keys }, "$key")
            unless CORE::exists $data->{ $key };

        $data->{ $key } = $val;
    }

    @{ $keys } - $self->[_GCNT];
}

sub PushNew {                                     ## ( @pairs ); reorder
    my $self = CORE::shift;
    my ($data, $keys) = @$self;

    while (@_) {
        my ($key, $val) = CORE::splice(@_, 0, 2);

        $self->DELETE($key) if CORE::exists $data->{ $key };
        CORE::push(@{ $keys }, "$key");

        $data->{ $key } = $val;
    }

    @{ $keys } - $self->[_GCNT];
}

sub Shift {
    my $self = CORE::shift;
    my $key  = CORE::shift @{ $self->[_KEYS] };

    ## garbage collect start of list
    if ( $self->[_GCNT] ) {
        my $keys = $self->[_KEYS];
        if ( @{ $keys } && ref $keys->[0] ) {
            my ( $gcnt, $i ) = ( $self->[_GCNT], 0 );
            while ( $gcnt ) {
                $gcnt--, $i++, shift @{ $keys };
                last if !ref $keys->[0];
            }
            $self->[_BEGI] += $i, $self->[_GCNT] = $gcnt;
        }
    }

    if ( defined $key ) {
        CORE::delete $self->[_INDX]{ $key } if $self->[_INDX];
        $self->[_BEGI]++;

        $self->[_ITER]-- if $self->[_ITER]  > 0;
        $self->[_CURS]-- if $self->[_CURS] == 0;

        return $key, CORE::delete $self->[_DATA]{ $key };
    }

    return;
}

sub Unshift {                                     ## ( @pairs ); merge
    my $self = CORE::shift;
    my ($data, $keys) = @$self;

    while (@_) {
        my ($key, $val) = CORE::splice(@_, -2, 2);

        $self->[_BEGI]--, CORE::unshift(@{ $keys }, "$key")
            unless CORE::exists $data->{ $key };

        $data->{ $key } = $val;
    }

    @{ $keys } - $self->[_GCNT];
}

sub UnshiftNew {                                  ## ( @pairs ); reorder
    my $self = CORE::shift;
    my ($data, $keys) = @$self;

    while (@_) {
        my ($key, $val) = CORE::splice(@_, -2, 2);

        $self->DELETE($key) if CORE::exists $data->{ $key };
        $self->[_BEGI]--, CORE::unshift(@{ $keys }, "$key");

        $data->{ $key } = $val;
    }

    @{ $keys } - $self->[_GCNT];
}

sub Splice {                                      ## ( $off, $len, @pairs )
    my ($self, $off) = (CORE::shift, CORE::shift);
    my ($data, $keys, $indx) = @$self;
    my ($key, @ret);

    return @ret unless defined $off;
    $self->Reindex if $self->[_GCNT] || $indx;

    my $size = CORE::scalar @{ $keys };
    my $len  = @_ ? CORE::shift : $size - $off;

    if ($off >= $size) {
        $self->Push(@_) if @_;
    }
    elsif (abs($off) <= $size) {
        if ($len > 0) {
            $off = $off + @{ $keys } if $off < 0;
            my @k = CORE::splice @{ $keys }, $off, $len;
            CORE::push(@ret, $_, CORE::delete $data->{ $_ }) for @k;
        }
        if (@_) {
            my @k = CORE::splice @{ $keys }, $off;
            $self->Push(@_);
            CORE::push(@{ $keys }, "$_") for @k;
        }
    }

    return @ret;
}

###############################################################################
## ----------------------------------------------------------------------------
## Indices, Length, RenameKeys, Reorder, Replace, SortByKey, SortByValue
##
###############################################################################

sub Indices {                                     ## ( @keys )
    my $self = CORE::shift;
    return unless @_;

    if ($self->[_GCNT]) {
        $self->Reindex;       # <-- [_KEYS] key
        $self->_make_indx;    # <-- [_INDX] key => id
    }
    else {
        $self->_fill_indx;    # <-- [_INDX] fill on demand
    }

    (@_ == 1) ? $self->[_INDX]{ $_[0] } : @{ $self->[_INDX] }{ @_ };
}

sub Length {
    @{ $_[0]->[_KEYS] } - $_[0]->[_GCNT];
}

sub RenameKeys {                                  ## ( @keys )
    my $self = CORE::shift;
    my ($data, $keys) = @$self;
    my ($key, @vals);
    CORE::die ERROR_KEY_LENGTH_MISMATCH if (@_ != $self->Keys);

    my %tmp = CORE::map { $_ => 1 } @_;
    CORE::die ERROR_DUPLICATE_KEYS if (CORE::keys %tmp != $self->Keys);

    %tmp  = ();
    @vals = $self->Values;
    $self->CLEAR;

    while (@_) {
        $key = CORE::shift;
        CORE::push(@{ $keys }, "$key");
        $data->{ $key } = CORE::shift @vals;
    }

    return $self;
}

sub Reorder {                                     ## ( @keys )
    my $self = CORE::shift;
    my ($data, $keys) = @$self;
    my (%keep);

    return unless @_;

    CORE::splice( @{ $self }, 2, 5, undef, 0, 0, undef, undef );

    @{ $keys } = ();

    for (@_) {
        if (CORE::exists $data->{ $_ }) {
            $keep{ $_ } = $data->{ $_ };
            CORE::push(@{ $keys }, "$_");
        }
    }

    $self->[_DATA] = \%keep;

    return $self;
}

sub Replace {                                     ## ( $off, $val, $key )
    my ($self, $i, $val, $key) = @_;
    my ($data, $keys, $indx) = @$self;

    if (defined $i && $i >= 0 && $i < @{ $keys } - $self->[_GCNT]) {
        $self->DELETE($key) if defined $key;
        $self->Reindex if $self->[_GCNT];

        if (defined $key) {
            my ($old_key, $indx_id) = ($keys->[ $i ]);
            $indx_id = CORE::delete $indx->{ $old_key } if $indx;
            CORE::delete $data->{ $old_key };
            $keys->[ $i ]   = "$key";
            $data->{ $key } = $val;
            $indx->{ $key } = $indx_id if defined $indx_id;
            return $key;
        }
        else {
            $data->{ $keys->[ $i ] } = $val;
            return $keys->[ $i ];
        }
    }

    return undef;
}

sub SortByKey {
    my ($s, $sort_numerically) = (CORE::shift, CORE::shift || 0);

    ($sort_numerically)
        ? $s->Reorder( sort { $a <=> $b } $s->Keys )
        : $s->Reorder( sort { $a cmp $b } $s->Keys );
}

sub SortByValue {
    my ($s, $sort_numerically) = (CORE::shift, CORE::shift || 0);

    ($sort_numerically)
        ? $s->Reorder( sort { $s->FETCH($a) <=> $s->FETCH($b) } $s->Keys )
        : $s->Reorder( sort { $s->FETCH($a) cmp $s->FETCH($b) } $s->Keys );
}

###############################################################################
## ----------------------------------------------------------------------------
## Clone, Reindex, Next, Prev, Reset
##
###############################################################################

sub Clone {                                       ## ( @keys )
    my $self = CORE::shift;
    my $tied = $self->[_TIED];
    my $DATA = $self->[_DATA];
    my ( $key, %data, @keys );

    if ( @_ ) {
        while ( @_ ) {
            $key = CORE::shift;
            CORE::push(@keys, "$key") unless exists $data{ $key };

            $data{ $key } = $DATA->{ $key };
        }
    }
    else {
        for my $key ( @{ $self->[_KEYS] } ) {
            CORE::next if ref $key;
            CORE::push(@keys, "$key") unless exists $data{ $key };

            $data{ $key } = $DATA->{ $key };
        }
    }

    bless [ \%data, \@keys, undef, 0, 0, undef, undef, $tied ], ref $self;
}

sub Reindex {
    my ($self) = @_;

    ## This isn't necessary, but added for long running apps wanting to
    ## reset BEGI so not to overflow.

    my ( $keys, $curs, $iter ) = @{ $self }[ _KEYS, _CURS, _ITER ];

    if ( defined $curs || defined $iter ) {
        my ( $i, $curs_adj, $iter_adj ) = ( 0, 0, 0 );

        if ( @{ $keys } ) {
            for ( 0 .. @{ $keys } - 1 ) {
                if ( ref $keys->[$_] ) {
                    $curs_adj++ if defined $curs && $_ <= $curs;
                    $iter_adj++ if defined $iter && $_ <= $iter;

                    CORE::next;
                }
                $keys->[ $i++ ] = $keys->[$_];
            }
            $curs -= $curs_adj if defined $curs;
            $iter -= $iter_adj if defined $iter;

            CORE::splice @{ $keys }, $i;
        }
        else {
            $curs = $iter = undef;
        }

        CORE::splice @{ $self }, 2, 5, undef, 0, 0, $iter, $curs;
    }
    else {
        my $i = 0;

        if ( @{ $keys } ) {
            for ( 0 .. @{ $keys } - 1 ) {
                CORE::next if ref $keys->[$_];
                $keys->[ $i++ ] = $keys->[$_];
            }

            CORE::splice @{ $keys }, $i;
        }

        CORE::splice @{ $self }, 2, 3, undef, 0, 0;
    }

    return;
}

sub Next {
    my ($self) = @_;
    my ($keys, $curs, $flg) = ($self->[_KEYS], $self->[_CURS], 0);

    if (!defined $curs) {
        return unless @{ $keys };
        $self->[_CURS] = 0;
    }
    elsif ($curs < $#{ $keys }) {
        $curs = ++$self->[_CURS];
        $flg = 1, $curs++ while ref($keys->[ $curs ]) && $curs < $#{ $keys };
        $self->[_CURS] = $curs if $flg;
    }
    else {
        return;
    }

    if (wantarray) {
        my $key = $keys->[ $self->[_CURS] ];
        return $key, $self->[_DATA]{ $key };
    }
    else {
        return $keys->[ $self->[_CURS] ];
    }
}

sub Prev {
    my ($self) = @_;
    my ($keys, $curs, $flg) = ($self->[_KEYS], $self->[_CURS], 0);

    if (!defined $curs) {
        return unless @{ $keys };
        $self->[_CURS] = $#{ $keys };
    }
    elsif ($curs > 0) {
        $curs = --$self->[_CURS];
        $flg = 1, $curs-- while ref($keys->[ $curs ]) && $curs > 0;
        $self->[_CURS] = $curs if $flg;
    }
    else {
        return;
    }

    if (wantarray) {
        my $key = $keys->[ $self->[_CURS] ];
        return $key, $self->[_DATA]{ $key };
    }
    else {
        return $keys->[ $self->[_CURS] ];
    }
}

sub Reset {
    $_[0]->[_CURS] = undef;
}

###############################################################################
## ----------------------------------------------------------------------------
## Private methods and aliases.
##
###############################################################################

## Create / fill index with ( key => id ) pairs.

sub _make_indx {
    my ( $self, $i, %indx ) = ( CORE::shift, 0 );
    $indx{ $_ } = $i++ for @{ $self->[_KEYS] };

    $self->[_BEGI] = 0;
    $self->[_INDX] = \%indx;
}

sub _fill_indx {
    my ( $self ) = @_;
    my ( $keys, $indx ) = ( $self->[_KEYS], $self->[_INDX] );
    return $self->_make_indx unless defined $indx;

    my ( $left, $right ) = @{ $indx }{ @{ $keys }[ 0, -1 ] };

    if ( !defined $left ) {
        my ( $pos, $id, $key ) = ( 0, $self->[_BEGI] );
        for ( 1 .. @{ $keys } ) {
            $key = $keys->[ $pos ];
            if ( !ref $key ) {
                CORE::last if CORE::exists $indx->{ $key };
                $indx->{ $key } = $id;
            }
            $pos++; $id++;
        }
    }

    if ( !defined $right ) {
        my ( $pos, $id, $key ) = ( -1, $self->[_BEGI] + $#{ $keys } );
        for ( 1 .. @{ $keys } ) {
            $key = $keys->[ $pos ];
            if ( !ref $key ) {
                CORE::last if CORE::exists $indx->{ $key };
                $indx->{ $key } = $id;
            }
            $pos--; $id--;
        }
    }

    $indx;
}

## Aliases.

{
    no strict 'refs';

    sub new     { _new( 0, @_ ) }
    sub TIEHASH { _new( 1, @_ ) }

    *{ __PACKAGE__.'::Store'    } = \&STORE;
    *{ __PACKAGE__.'::Set'      } = \&STORE;
    *{ __PACKAGE__.'::Fetch'    } = \&FETCH;
    *{ __PACKAGE__.'::Get'      } = \&FETCH;
    *{ __PACKAGE__.'::Delete'   } = \&DELETE;
    *{ __PACKAGE__.'::Del'      } = \&DELETE;
    *{ __PACKAGE__.'::FirstKey' } = \&FIRSTKEY;
    *{ __PACKAGE__.'::NextKey'  } = \&NEXTKEY;
    *{ __PACKAGE__.'::Exists'   } = \&EXISTS;
    *{ __PACKAGE__.'::Clear'    } = \&CLEAR;
}

## For dereferencing support.

package MCE::OrdHash::_href;

sub TIEHASH { $_[1] }

1;

__END__

###############################################################################
## ----------------------------------------------------------------------------
## Module usage.
##
###############################################################################

=head1 NAME

MCE::OrdHash - A shareable pure-Perl ordered hash class

=head1 VERSION

This document describes MCE::OrdHash version 1.699_001

=head1 SYNOPSIS

   use MCE::Shared;
   use MCE::OrdHash;

   # Non-shared ordered hash
   tie %oh, 'MCE::OrdHash', @pairs;
   $oh = MCE::OrdHash->new( @pairs );

   # MCE::Shared ordered hash
   $oh = mce_share( MCE::OrdHash->new( @pairs ) );
   $oh = mce_share( {}, @pairs ); # same thing

   # OO interface and hash-like dereferencing
   $oh->Store( 'foo' => 'bar' );
   $oh->{'foo'} = 'bar';

   TODO, coming soon...


=head1 DESCRIPTION

This module provides ordered hash capabilities for L<MCE::Shared|MCE::Shared>.
It is mostly compatible with L<Tie::IxHash|Tie::IxHash> and overlays tombstone
deletion, inspired by L<Hash::Ordered|Hash::Ordered>.

=head1 API DOCUMENTATION

   TODO, coming soon...


=head1 ACKNOWLEDGEMENTS

=over 3

=item L<Hash::Ordered|Hash::Ordered>

David Golden, enlighten us that faster is possible. The tombstone deletion
in MCE::OrdHash is based on this module.

=item L<Tie::IxHash|Tie::IxHash>

Gurusamy Sarathy, provides Perl a feature rich ordered hash class. MCE::OrdHash
is mostly compatible with Tie::IxHash except Keys and Values which take keys
as arguments, not indices. KeysInd and ValuesInd come included receiving
indices for compatibility.

=back

=head1 INDEX

L<MCE|MCE>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

