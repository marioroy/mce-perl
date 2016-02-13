###############################################################################
## ----------------------------------------------------------------------------
## Indexed-hash helper class.
##
## A doubly-linked list, pure-Perl ordered hash implementation, inspired by
## the Tie::Hash::Indexed (XS) module.
##
## It is fully compatible with MCE::Shared::Ordhash, which features tombstone
## deletion. Both modules may be used interchangeably.
##
###############################################################################

package MCE::Shared::Indhash;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized numeric );

our $VERSION = '1.699_011';

## no critic (Subroutines::ProhibitExplicitReturnUndef)
## no critic (TestingAndDebugging::ProhibitNoStrict)

use MCE::Shared::Base;
use bytes;

use constant { _DATA => 0, _ROOT => 1, _ITER => 2            };  # self
use constant { _PREV => 0, _NEXT => 1, _KEY  => 2, _VAL => 3 };  # link

use overload (
    q("")    => \&MCE::Shared::Base::_stringify,
    q(0+)    => \&MCE::Shared::Base::_numify,
    q(%{})   => sub {
        tie my %h, 'MCE::Shared::Indhash::_href', $_[0];
        \%h;
    },
    fallback => 1
);

###############################################################################
## ----------------------------------------------------------------------------
## TIEHASH, STORE, FETCH, DELETE, FIRSTKEY, NEXTKEY, EXISTS, CLEAR, SCALAR
##
###############################################################################

# TIEHASH ( key, value [, key, value, ... ] )
# TIEHASH ( )

sub TIEHASH {
    my $class = shift;
    my ( %data, @root, $key );

    $root[_PREV] = $root[_NEXT] = \@root;
    $root[_KEY ] = $root[_VAL ] = undef;

    while ( @_ ) {
        $key = shift;
        if ( !exists $data{ $key } ) {
            $root[_PREV] = $root[_PREV][_NEXT] = $data{ $key } = [
                $root[_PREV], \@root, "$key", shift
            ];
        }
        else {
            $data{ $key }[_VAL] = shift;
        }
    }

    bless [ \%data, \@root ], $class;
}

# STORE ( key, value )

sub STORE {
    my ( $self, $key ) = @_;  # $_[2] is not copied in case it's large

    if ( my $link = $self->[_DATA]{ $key } ) {
        $link->[_VAL] = $_[2];
    }
    else {
        my $root = $self->[_ROOT];
        $root->[_PREV] = $root->[_PREV][_NEXT] = $self->[_DATA]{ $key } = [
            $root->[_PREV], $root, "$key", $_[2]
        ];
        $_[2];
    }
}

# FETCH ( key )

sub FETCH {
    if ( my $link = $_[0]->[_DATA]{ $_[1] } ) {
        $link->[_VAL];
    }
    else {
        undef;
    }
}

# DELETE ( key )

sub DELETE {
    if ( my $link = delete $_[0]->[_DATA]{ $_[1] } ) {
        $link->[_PREV][_NEXT] = $link->[_NEXT];
        $link->[_NEXT][_PREV] = $link->[_PREV];

        $link->[_VAL];
    }
    else {
        undef;
    }
}

# FIRSTKEY ( )

sub FIRSTKEY {
    my ( $self ) = @_;
    my @keys = $self->keys;

    $self->[_ITER] = sub {
        return unless @keys;
        return shift(@keys);
    };

    $self->[_ITER]->();
}

# NEXTKEY ( )

sub NEXTKEY {
    $_[0]->[_ITER]->();
}

# EXISTS ( key )

sub EXISTS {
    exists $_[0]->[_DATA]{ $_[1] };
}

# CLEAR ( )

sub CLEAR {
    my ( $self ) = @_;
    my $root = $self->[_ROOT];

    $root->[_PREV] = $root->[_NEXT] = $root;
    delete $self->[_ITER];

    %{ $self->[_DATA] } = ();

    return;
}

# SCALAR ( )

sub SCALAR {
    scalar( keys %{ $_[0]->[_DATA] } );
}

###############################################################################
## ----------------------------------------------------------------------------
## Custom non-recursion freezing/thawing necessary for large hashes.
##
###############################################################################

sub STORABLE_freeze {
    my ( $self, $cloning ) = @_;
    return if $cloning;

    my $cur = $self->[_ROOT][_NEXT];
    my @pairs;

    for ( 1 .. scalar( keys %{ $self->[_DATA] } ) ) {
        push @pairs, @{ $cur }[ _KEY, _VAL ];
        $cur = $cur->[_NEXT];
    }

    return ( '', \@pairs );
}

sub STORABLE_thaw {
    my ( $self, $cloning, $serialized, $pairs ) = @_;
    return if $cloning;

    my ( %data, @root, $key );

    $root[_PREV] = $root[_NEXT] = \@root;
    $root[_KEY ] = $root[_VAL ] = undef;

    while ( @{ $pairs } ) {
        $key = shift @{ $pairs };
        $root[_PREV] = $root[_PREV][_NEXT] = $data{ $key } = [
            $root[_PREV], \@root, $key, shift @{ $pairs }
        ];
    }

    $self->[_DATA] = \%data;
    $self->[_ROOT] = \@root;

    delete $self->[_ITER];

    return;
}

###############################################################################
## ----------------------------------------------------------------------------
## POP, PUSH, SHIFT, UNSHIFT, SPLICE
##
###############################################################################

# POP ( )

sub POP {
    my $self = shift;

    if ( defined ( my $key = $self->[_ROOT][_PREV][_KEY] ) ) {
        my $link = delete $self->[_DATA]{ $key };

        $link->[_PREV][_NEXT] = $link->[_NEXT];
        $link->[_NEXT][_PREV] = $link->[_PREV];

        return $key, $link->[_VAL];
    }

    return;
}

# PUSH ( key, value [, key, value, ... ] )

sub PUSH {
    my $self = shift;
    my ( $data, $root ) = @{ $self };

    while ( @_ ) {
        my ( $key, $val ) = splice(@_, 0, 2);
        $self->DELETE($key) if exists $data->{ $key };

        $root->[_PREV] = $root->[_PREV][_NEXT] = $data->{ $key } = [
            $root->[_PREV], $root, "$key", $val
        ];
    }

    scalar( keys %{ $data } );
}

# SHIFT ( )

sub SHIFT {
    my $self = shift;

    if ( defined ( my $key = $self->[_ROOT][_NEXT][_KEY] ) ) {
        my $link = delete $self->[_DATA]{ $key };

        $link->[_PREV][_NEXT] = $link->[_NEXT];
        $link->[_NEXT][_PREV] = $link->[_PREV];

        return $key, $link->[_VAL];
    }

    return;
}

# UNSHIFT ( key, value [, key, value, ... ] )

sub UNSHIFT {
    my $self = shift;
    my ( $data, $root ) = @{ $self };

    while ( @_ ) {
        my ( $key, $val ) = splice(@_, -2, 2);
        $self->DELETE($key) if exists $data->{ $key };

        $root->[_NEXT] = $root->[_NEXT][_PREV] = $data->{ $key } = [
            $root, $root->[_NEXT], "$key", $val
        ];
    }

    scalar( keys %{ $data } );
}

# SPLICE ( offset, length [, key, value, ... ] )

sub SPLICE {
    my ( $self, $off ) = ( shift, shift );
    my ( $data, $root ) = @{ $self };
    my ( $cur, $key, @ret );

    return @ret unless ( defined $off );

    my $size = keys %{ $data };
    my $len  = @_ ? shift : $size - $off;

    if ( $off >= $size ) {
        $self->PUSH( @_ ) if @_;
    }
    elsif ( abs($off) <= $size ) {
        $off = -($size - $off) if ( $off > int($size / 2) );

        if ( $off < 0 ) {
            $cur = $root->[_PREV];
            while ( ++$off ) { $cur = $cur->[_PREV]; }
        }
        else {
            $cur = $root->[_NEXT];
            while ( $off-- ) { $cur = $cur->[_NEXT]; }
        }

        if ( $len > 0 ) {
            $cur = $cur->[_PREV];
            while ( $len-- ) {
                $key = $cur->[_NEXT][_KEY];
                last unless defined $key;
                push @ret, $key, $self->DELETE($key);
            }
            $cur = $cur->[_NEXT];
        }

        while ( @_ ) {
            $key = shift;
            if ( my $link = $data->{ $key } ) {
                $link->[_VAL] = shift;
            }
            else {
                $cur->[_PREV] = $cur->[_PREV][_NEXT] = $data->{ $key } = [
                    $cur->[_PREV], $cur, "$key", shift
                ];
            }
        }
    }

    return @ret;
}

###############################################################################
## ----------------------------------------------------------------------------
## _find, clone, flush, iterator, keys, pairs, values
##
###############################################################################

#  Query string:
#
#  Several methods receive a query string argument. The string is quoteless.
#  Basically, any quotes inside the string will be treated literally.
#
#  Search capability { =~ !~ eq ne lt le gt ge == != < <= > >= }
#
#  "key =~ /pattern/i :AND val =~ /pattern/i"
#  "key =~ /pattern/i :AND val eq foo bar"     # val eq foo bar
#  "val eq foo baz :OR key !~ /pattern/i"
#
#     key means to match against keys in the hash
#     likewise, val means to match against values
#
#  :AND(s) and :OR(s) mixed together is not supported

# _find ( { getkeys => 1 }, "query string" )
# _find ( { getvals => 1 }, "query string" )
# _find ( "query string" ) # pairs

sub _find {
    my $self   = shift;
    my $params = ref($_[0]) eq 'HASH' ? shift : {};
    my $query  = shift;

    MCE::Shared::Base::_find_indhash(
        $self->[_DATA], $params, $query, $self
    );
}

# clone ( key [, key, ... ] )
# clone ( )

sub clone {
    my $self = shift;
    my $params = ref($_[0]) eq 'HASH' ? shift : {};
    my ( %data, @root, $key );

    $root[_PREV] = $root[_NEXT] = \@root;
    $root[_KEY ] = $root[_VAL ] = undef;

    if ( @_ ) {
        while ( @_ ) {
            $key = shift;
            $root[_PREV] = $root[_PREV][_NEXT] = $data{ $key } = [
                $root[_PREV], \@root, "$key", $self->FETCH($key)
            ];
        }
    }
    else {
        my $cur = $self->[_ROOT][_NEXT];

        for ( 1 .. scalar( keys %{ $self->[_DATA] } ) ) {
            $key = $cur->[_KEY];
            $root[_PREV] = $root[_PREV][_NEXT] = $data{ $key } = [
                $root[_PREV], \@root, $key, $cur->[_VAL]
            ];
            $cur = $cur->[_NEXT];
        }
    }

    $self->clear() if $params->{'flush'};

    bless [ \%data, \@root ], ref $self;
}

# flush ( key [, key, ... ] )
# flush ( )

sub flush {
    shift()->clone( { flush => 1 }, @_ );
}

# iterator ( key [, key, ... ] )
# iterator ( "query string" )
# iterator ( )

sub iterator {
    my ( $self, @keys ) = @_;
    my $data = $self->[_DATA];

    if ( !scalar @keys ) {
        @keys = $self->keys();
    }
    elsif ( @keys == 1 && $keys[0] =~ /^(?:key|val)[ ]+\S\S?[ ]+\S/ ) {
        @keys = $self->keys($keys[0]);
    }

    return sub {
        return unless @keys;
        my $key = shift(@keys);

        return ( exists $data->{ $key } )
           ? ( $key => $data->{ $key }[_VAL] )
           : ( $key => undef )
    };
}

# keys ( key [, key, ... ] )
# keys ( "query string" )
# keys ( )

sub keys {
    my $self = shift;

    if ( @_ == 1 && $_[0] =~ /^(?:key|val)[ ]+\S\S?[ ]+\S/ ) {
        $self->_find({ getkeys => 1 }, @_);
    }
    else {
        if ( wantarray ) {
            my $cur = $self->[_ROOT][_NEXT];
            @_ ? map { exists $self->[_DATA]{ $_ } ? $_ : undef } @_
               : map { ( $cur = $cur->[_NEXT] )->[_PREV][_KEY] }
                    1 .. scalar( CORE::keys %{ $self->[_DATA] } );
        }
        else {
            scalar( CORE::keys %{ $self->[_DATA] } );
        }
    }
}

# pairs ( key [, key, ... ] )
# pairs ( "query string" )
# pairs ( )

sub pairs {
    my $self = shift;

    if ( @_ == 1 && $_[0] =~ /^(?:key|val)[ ]+\S\S?[ ]+\S/ ) {
        $self->_find(@_);
    }
    else {
        if ( wantarray ) {
            my $cur = $self->[_ROOT][_NEXT];
            @_ ? map { $_ => $self->FETCH($_) } @_
               : map { @{ ( $cur = $cur->[_NEXT] )->[_PREV] }[ _KEY, _VAL ] }
                    1 .. scalar( CORE::keys %{ $self->[_DATA] } );
        }
        else {
            scalar( CORE::keys %{ $self->[_DATA] } ) << 1;
        }
    }
}

# values ( key [, key, ... ] )
# values ( "query string" )
# values ( )

sub values {
    my $self = shift;

    if ( @_ == 1 && $_[0] =~ /^(?:key|val)[ ]+\S\S?[ ]+\S/ ) {
        $self->_find({ getvals => 1 }, @_);
    }
    else {
        if ( wantarray ) {
            my $cur = $self->[_ROOT][_NEXT];
            @_ ? map { $self->FETCH($_) } @_
               : map { ( $cur = $cur->[_NEXT] )->[_PREV][_VAL] }
                    1 .. scalar( CORE::keys %{ $self->[_DATA] } );
        }
        else {
            scalar( CORE::keys %{ $self->[_DATA] } );
        }
    }
}

###############################################################################
## ----------------------------------------------------------------------------
## mdel, mexists, mget, mset, sort
##
###############################################################################

# mdel ( key [, key, ... ] )

sub mdel {
    my $self = shift;
    my ( $data, $cnt, $key ) = ( $self->[_DATA], 0 );

    while ( @_ ) {
        $key = shift;
        $cnt++, $self->DELETE($key) if exists($data->{ $key });
    }

    $cnt;
}

# mexists ( key [, key, ... ] )

sub mexists {
    my $self = shift;
    my $data = $self->[_DATA];
    my $key;

    while ( @_ ) {
        $key = shift;
        return '' if ( !exists $data->{ $key } );
    }

    1;
}

# mget ( key [, key, ... ] )

sub mget {
    my $self = shift;

    @_ ? map { defined $_ ? $_->[_VAL] : undef } @{ $self->[_DATA] }{ @_ }
       : ();
}

# mset ( key, value [, key, value, ... ] )

sub mset {
    my $self = shift;
    my ( $data, $root ) = @{ $self };

    while ( @_ ) {
        my ( $key, $val ) = splice(@_, 0, 2);
        if ( my $link = $data->{ $key } ) {
            $link->[_VAL] = $val;
        }
        else {
            $root->[_PREV] = $root->[_PREV][_NEXT] = $data->{ $key } = [
                $root->[_PREV], $root, "$key", $val
            ];
        }
    }

    scalar( CORE::keys %{ $data } );
}

# sort ( "BY key [ ASC | DESC ] [ ALPHA ]" )
# sort ( "BY val [ ASC | DESC ] [ ALPHA ]" )
# sort ( "[ ASC | DESC ] [ ALPHA ]" ) # same as "BY val ..."

sub sort {
    my ( $self, $request ) = @_;
    my ( $by_key, $alpha, $desc ) = ( 0, 0, 0 );

    if ( length $request ) {
        $by_key = 1 if $request =~ /\bkey\b/i;
        $alpha  = 1 if $request =~ /\balpha\b/i;
        $desc   = 1 if $request =~ /\bdesc\b/i;
    }

    # Return sorted keys, leaving the data intact.

    if ( defined wantarray ) {
        if ( $by_key ) {                              # by key
            if ( $alpha ) { ( $desc )
              ? CORE::sort { $b cmp $a } $self->keys
              : CORE::sort { $a cmp $b } $self->keys;
            }
            else { ( $desc )
              ? CORE::sort { $b <=> $a } $self->keys
              : CORE::sort { $a <=> $b } $self->keys;
            }
        }
        else {                                        # by value
            my $d = $self->[_DATA];
            if ( $alpha ) { ( $desc )
              ? CORE::sort { $d->{$b}[_VAL] cmp $d->{$a}[_VAL] } $self->keys
              : CORE::sort { $d->{$a}[_VAL] cmp $d->{$b}[_VAL] } $self->keys;
            }
            else { ( $desc )
              ? CORE::sort { $d->{$b}[_VAL] <=> $d->{$a}[_VAL] } $self->keys
              : CORE::sort { $d->{$a}[_VAL] <=> $d->{$b}[_VAL] } $self->keys;
            }
        }
    }

    # Sort keys in-place otherwise, in void context.

    elsif ( $by_key ) {                               # by key
        if ( $alpha ) { ( $desc )
          ? $self->_reorder( CORE::sort { $b cmp $a } $self->keys )
          : $self->_reorder( CORE::sort { $a cmp $b } $self->keys );
        }
        else { ( $desc )
          ? $self->_reorder( CORE::sort { $b <=> $a } $self->keys )
          : $self->_reorder( CORE::sort { $a <=> $b } $self->keys );
        }
    }
    else {                                            # by value
        my $d = $self->[_DATA];
        if ( $alpha ) { ( $desc )
          ? $self->_reorder(
              CORE::sort { $d->{$b}[_VAL] cmp $d->{$a}[_VAL] } $self->keys
            )
          : $self->_reorder(
              CORE::sort { $d->{$a}[_VAL] cmp $d->{$b}[_VAL] } $self->keys
            );
        }
        else { ( $desc )
          ? $self->_reorder(
              CORE::sort { $d->{$b}[_VAL] <=> $d->{$a}[_VAL] } $self->keys
            )
          : $self->_reorder(
              CORE::sort { $d->{$a}[_VAL] <=> $d->{$b}[_VAL] } $self->keys
            );
        }
    }
}

sub _reorder {
    my $self = shift;
    my ( $data, $root ) = @{ $self };
    my ( $link );

    return unless @_;

    $root->[_PREV] = $root->[_NEXT] = $root;

    for ( @_ ) {
        if ( $link = $data->{$_} ) {
            $link->[_PREV] = $root->[_PREV];
            $link->[_NEXT] = $root;

            $root->[_PREV] = $root->[_PREV][_NEXT] = $link;
        }
    }

    return $self;
}

###############################################################################
## ----------------------------------------------------------------------------
## Sugar API, mostly resembles http://redis.io/commands#string primitives.
##
###############################################################################

# append ( key, string )

sub append {
    my ( $self, $key ) = @_;
    $self->set( $key, '' ) unless exists $self->[_DATA]{ $key };

    $self->[_DATA]{ $key }[_VAL] .= $_[2] || '';

    length $self->[_DATA]{ $key }[_VAL];
}

# decr ( key )

sub decr {
    my ( $self, $key ) = @_;
    $self->set( $key, 0 ) unless exists $self->[_DATA]{ $key };

    --$self->[_DATA]{ $key }[_VAL];
}

# decrby ( key, number )

sub decrby {
    my ( $self, $key ) = @_;
    $self->set( $key, 0 ) unless exists $self->[_DATA]{ $key };

    $self->[_DATA]{ $key }[_VAL] -= $_[2] || 0;
}

# incr ( key )

sub incr {
    my ( $self, $key ) = @_;
    $self->set( $key, 0 ) unless exists $self->[_DATA]{ $key };

    ++$self->[_DATA]{ $key }[_VAL];
}

# incrby ( key, number )

sub incrby {
    my ( $self, $key ) = @_;
    $self->set( $key, 0 ) unless exists $self->[_DATA]{ $key };

    $self->[_DATA]{ $key }[_VAL] += $_[2] || 0;
}

# getdecr ( key )

sub getdecr {
    my ( $self, $key ) = @_;
    $self->set( $key, 0 ) unless exists $self->[_DATA]{ $key };

    $self->[_DATA]{ $key }[_VAL]-- || 0;
}

# getincr ( key )

sub getincr {
    my ( $self, $key ) = @_;
    $self->set( $key, 0 ) unless exists $self->[_DATA]{ $key };

    $self->[_DATA]{ $key }[_VAL]++ || 0;
}

# getset ( key, value )

sub getset {
    my ( $self, $key ) = @_;
    $self->set( $key, undef ) unless exists $self->[_DATA]{ $key };

    my $old = $self->[_DATA]{ $key }[_VAL];
    $self->[_DATA]{ $key }[_VAL] = $_[2];

    $old;
}

# len ( key )
# len ( )

sub len {
    if ( defined $_[1] ) {
        ( exists $_[0]->[_DATA]{ $_[1] } )
          ? length $_[0]->[_DATA]{ $_[1] }[_VAL] || 0
          : 0;
    }
    else {
        scalar( CORE::keys %{ $_[0]->[_DATA] } );
    }
}

{
   no strict 'refs';

   *{ __PACKAGE__.'::new'     } = \&TIEHASH;
   *{ __PACKAGE__.'::set'     } = \&STORE;
   *{ __PACKAGE__.'::get'     } = \&FETCH;
   *{ __PACKAGE__.'::delete'  } = \&DELETE;
   *{ __PACKAGE__.'::exists'  } = \&EXISTS;
   *{ __PACKAGE__.'::clear'   } = \&CLEAR;
   *{ __PACKAGE__.'::pop'     } = \&POP;
   *{ __PACKAGE__.'::push'    } = \&PUSH;
   *{ __PACKAGE__.'::shift'   } = \&SHIFT;
   *{ __PACKAGE__.'::unshift' } = \&UNSHIFT;
   *{ __PACKAGE__.'::splice'  } = \&SPLICE;

   *{ __PACKAGE__.'::del'     } = \&delete;
   *{ __PACKAGE__.'::merge'   } = \&mset;
   *{ __PACKAGE__.'::vals'    } = \&values;
}

# For on-demand hash-like dereferencing.

package MCE::Shared::Indhash::_href;

sub TIEHASH { $_[1] }

1;

__END__

###############################################################################
## ----------------------------------------------------------------------------
## Module usage.
##
###############################################################################

=head1 NAME

MCE::Shared::Indhash - An ordered hash class featuring doubly-linked list

=head1 VERSION

This document describes MCE::Shared::Indhash version 1.699_011

=head1 SYNOPSIS

   # non-shared
   use MCE::Shared::Indhash;

   my $oh = MCE::Shared::Indhash->new( @pairs );

   # shared
   use MCE::Shared;

   my $oh = MCE::Shared->indhash( @pairs );

   # oo interface
   $val   = $oh->set( $key, $val );
   $val   = $oh->get( $key );
   $val   = $oh->delete( $key );              # del is an alias for delete
   $bool  = $oh->exists( $key );
   void   = $oh->clear();
   $len   = $oh->len();                       # scalar keys %{ $oh }
   $len   = $oh->len( $key );                 # length $oh->{ $key }
   @pair  = $oh->pop();
   $len   = $oh->push( @pairs );
   @pair  = $oh->shift();
   $len   = $oh->unshift( @pairs );
   %pairs = $oh->splice( $offset, $length, @pairs );

   $oh2   = $oh->clone( @keys );              # @keys is optional
   $oh3   = $oh->flush( @keys );
   $iter  = $oh->iterator( @keys );           # ($key, $val) = $iter->()
   @keys  = $oh->keys( @keys );
   %pairs = $oh->pairs( @keys );
   @vals  = $oh->values( @keys );             # vals is an alias for values

   $cnt   = $oh->mdel( @keys );
   @vals  = $oh->mget( @keys );
   $bool  = $oh->mexists( @keys );            # true if all keys exists
   $len   = $oh->mset( $key/$val pairs );     # merge is an alias for mset

   @vals  = $oh->sort();                      # by val $a <=> $b default
   @vals  = $oh->sort( "desc" );              # by val $b <=> $a
   @vals  = $oh->sort( "alpha" );             # by val $a cmp $b
   @vals  = $oh->sort( "alpha desc" );        # by val $b cmp $a

   @vals  = $oh->sort( "key" );               # by key $a <=> $b
   @vals  = $oh->sort( "key desc" );          # by key $b <=> $a
   @vals  = $oh->sort( "key alpha" );         # by key $a cmp $b
   @vals  = $oh->sort( "key alpha desc" );    # by key $b cmp $a

   # search capability key/val { =~ !~ eq ne lt le gt ge == != < <= > >= }
   # query string is quoteless, otherwise quote(s) are treated literally
   # key/val means to match against actual key/val respectively
   # do not mix :AND(s) and :OR(s) together

   @keys  = $oh->keys( "key =~ /$pattern/i" );
   @keys  = $oh->keys( "key !~ /$pattern/i" );
   @keys  = $oh->keys( "val =~ /$pattern/i" );
   @keys  = $oh->keys( "val !~ /$pattern/i" );

   %pairs = $oh->pairs( "key == $number" );
   %pairs = $oh->pairs( "key != $number :AND val > 100" );
   %pairs = $oh->pairs( "key <  $number :OR key > $number" );
   %pairs = $oh->pairs( "val <= $number" );
   %pairs = $oh->pairs( "val >  $number" );
   %pairs = $oh->pairs( "val >= $number" );

   @vals  = $oh->values( "key eq $string" );
   @vals  = $oh->values( "key ne $string with space" );
   @vals  = $oh->values( "key lt $string :OR val =~ /$pat1|$pat2/" );
   @vals  = $oh->values( "val le $string :AND val eq foo bar" );
   @vals  = $oh->values( "val gt $string" );
   @vals  = $oh->values( "val ge $string" );

   # sugar methods without having to call set/get explicitly

   $len   = $oh->append( $key, $string );     #   $val .= $string
   $val   = $oh->decr( $key );                # --$val
   $val   = $oh->decrby( $key, $number );     #   $val -= $number
   $val   = $oh->getdecr( $key );             #   $val--
   $val   = $oh->getincr( $key );             #   $val++
   $val   = $oh->incr( $key );                # ++$val
   $val   = $oh->incrby( $key, $number );     #   $val += $number
   $old   = $oh->getset( $key, $new );        #   $o = $v, $v = $n, $o

=head1 DESCRIPTION

MCE::Shared provides two ordered hash implementations.

This module implements an ordered hash featuring a doubly-linked list,
inspired by the L<Tie::Hash::Indexed> (XS) module. An ordered hash means
that the key insertion order is preserved.

An ordered hash sensitive to hash deletion will likely run faster from a
doubly-linked list implementation. That is the case seen with L<MCE::Hobo>.

The nature of maintaining a circular list means extra memory consumption
by Perl itself. Typically, this is not a problem for thousands of key-value
pairs. See L<MCE::Shared::Ordhash> if lesser memory consumption is desired.

Both this module and C<MCE::Shared::Ordhash> may be used interchangeably.
Only the underlying implementation differs between the two.

=head1 QUERY STRING

Several methods in C<MCE::Shared::Indhash> receive a query string argument.
The string is quoteless. Basically, any quotes inside the string will be
treated literally.

   Search capability: =~ !~ eq ne lt le gt ge == != < <= > >=

   "key =~ /pattern/i :AND val =~ /pattern/i"
   "key =~ /pattern/i :AND val eq foo bar"     # val eq foo bar
   "val eq foo baz :OR key !~ /pattern/i"

      key means to match against keys in the hash
      likewise, val means to match against values

   :AND(s) and :OR(s) mixed together is not supported

=head1 API DOCUMENTATION

To be completed before the final 1.700 release.

=over 3

=item new ( key, value [, key, value, ... ] )

Constructs a new object, with an optional list of key-value pairs.

   # non-shared
   use MCE::Shared::Indhash;

   $ha = MCE::Shared::Indhash->new( @pairs );
   $ha = MCE::Shared::Indhash->new( );

   # shared
   use MCE::Shared;

   $ha = MCE::Shared->indhash( @pairs );
   $ha = MCE::Shared->indhash( );

=item clear

=item clone ( key [, key, ... ] )

=item clone

=item delete ( key )

=item del

C<del> is an alias for C<delete>.

=item exists ( key )

=item flush ( key [, key, ... ] )

=item flush

Same as C<clone>. Though, clears all existing items before returning.

=item get ( key )

=item iterator ( key [, key, ... ] )

=item iterator ( "query string" )

=item iterator

=item keys ( key [, key, ...] )

=item keys ( "query string" )

=item keys

=item len ( key )

Returns the length of the value stored at key.

   $len = $oh->len( $key );

=item len

Returns the number of keys stored in the hash.

   $len = $oh->len;

=item mdel ( key [, key, ... ] )

=item mexists ( key [, key, ... ] )

=item mget ( key [, key, ... ] )

=item mset ( key, value [, key, value, ... ] )

=item merge

C<merge> is an alias for C<mset>.

=item pairs ( key [, key, ... ] )

=item pairs ( "query string" )

=item pairs

=item pop

=item purge

=item push ( key/value pairs )

=item set ( key, value )

=item shift

=item sort ( "BY key [ ASC | DESC ] [ ALPHA ]" )

=item sort ( "BY val [ ASC | DESC ] [ ALPHA ]" )

=item sort ( "[ ASC | DESC ] [ ALPHA ]" )

=item splice ( offset, length, key/value pairs )

=item unshift ( key/value pairs )

=item values ( key [, key, ... ] )

=item values ( "query string" )

=item values

=item vals

C<vals> is an alias for C<values>.

=back

=head1 SUGAR METHODS

This module is equipped with sugar methods to not have to call C<set>
and C<get> explicitly. The API resembles a subset of the Redis primitives
L<http://redis.io/commands#strings> with key representing the hash key.

=over 3

=item append ( key, string )

Appends a value to a key and returns its new length.

   $len = $oh->append( $key, 'foo' );

=item decr ( key )

Decrements the value of a key by one and returns its new value.

   $num = $oh->decr( $key );

=item decrby ( key, number )

Decrements the value of a key by the given number and returns its new value.

   $num = $oh->decrby( $key, 2 );

=item getdecr ( key )

Decrements the value of a key by one and returns its old value.

   $old = $oh->getdecr( $key );

=item getincr ( key )

Increments the value of a key by one and returns its old value.

   $old = $oh->getincr( $key );

=item getset ( key, value )

Sets the value of a key and returns its old value.

   $old = $oh->getset( $key, 'baz' );

=item incr ( key )

Increments the value of a key by one and returns its new value.

   $num = $oh->incr( $key );

=item incrby ( key, number )

Increments the value of a key by the given number and returns its new value.

   $num = $oh->incrby( $key, 2 );

=back

=head1 CREDITS

The implementation is inspired by L<Tie::Hash::Indexed>.

=head1 INDEX

L<MCE|MCE>, L<MCE::Core>, L<MCE::Shared>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

