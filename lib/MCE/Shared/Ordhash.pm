###############################################################################
## ----------------------------------------------------------------------------
## A shareable pure-Perl ordered hash class.
##
###############################################################################

package MCE::Shared::Ordhash;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized );

our $VERSION = '1.699_002';

## no critic (BuiltinFunctions::ProhibitStringyEval)
## no critic (Subroutines::ProhibitExplicitReturnUndef)
## no critic (TestingAndDebugging::ProhibitNoStrict)

## An optimized ordered-hash implementation inspired by Hash::Ordered v0.009.
##
## <> Keys garbage collection is done in-place for minimum memory consumption.
## <> Revised tombstone deletion to ensure safety with varied usage patterns.
## <> The indexed hash is filled on-demand to not impact subsequent stores.
## <> Provides support for hash-like dereferencing, also on-demand.
## <> Added SPLICE, sorting, plus extra capabilities for use with MCE::Hobo.
##

use MCE::Shared::Base;
use base 'MCE::Shared::Base';
use bytes;

use constant {
   _TOMBSTONE => \1,  # ref to arbitrary scalar
};

use constant {
   _DATA => 0,  # unordered data
   _KEYS => 1,  # ordered ids with keys
   _INDX => 2,  # index into _KEYS (on demand, no impact to STORE)
   _BEGI => 3,  # begin ordered id for optimized shift/unshift
   _GCNT => 4,  # garbage count
   _ITER => 5,  # for tied hash support
   _HREF => 6,  # for hash-like dereferencing
};

use overload (
   q("")    => \&MCE::Shared::Base::_stringify_a,
   q(0+)    => \&MCE::Shared::Base::_numify,
   q(%{})   => sub {
      $_[0]->[_HREF] || do {
         tie my %h, 'MCE::Shared::Ordhash::_href', $_[0];
         $_[0]->[_HREF] = \%h;
      };
   },
   fallback => 1
);

sub _croak {
   goto &MCE::Shared::Base::_croak;
}

###############################################################################
## ----------------------------------------------------------------------------
## TIEHASH, STORE, FETCH, DELETE, FIRSTKEY, NEXTKEY, EXISTS, CLEAR, SCALAR
##
###############################################################################

sub TIEHASH {
   my ( $class ) = ( shift );
   my ( $key, %data, @keys );

   _croak("requires key-value pairs") unless ( @_ % 2 == 0 );

   while ( @_ ) {
      $key = shift;
      push @keys, "$key" unless exists $data{ $key };
      $data{ $key } = shift;
   }

   bless [ \%data, \@keys, undef, 0, 0, undef ], $class;
}

sub STORE {
   my ( $self, $key ) = @_;  # $_[2] not copied in case it's large

   push @{ $self->[_KEYS] }, "$key" unless exists $self->[_DATA]{ $key };

   $self->[_DATA]{ $key } = $_[2];
}

sub FETCH {
   $_[0]->[_DATA]{ $_[1] };
}

sub DELETE {
   my ( $self, $key ) = @_;

   if ( exists $self->[_DATA]{ $key } ) {
      my $keys = $self->[_KEYS];

      ## check first key
      if ( $key eq $keys->[0] ) {
         $self->[_BEGI]++, delete $self->[_INDX]{ $key } if $self->[_INDX];
         shift @{ $keys };

         ## GC start of list
         if ( ref $keys->[0] ) {
            my $i = 0;
            $i++, shift @{ $keys } while ref( $keys->[0] );
            $self->[_BEGI] += $i, $self->[_GCNT] -= $i;
         }
      }

      ## check last key
      elsif ( $key eq $keys->[-1] ) {
         delete $self->[_INDX]{ $key } if $self->[_INDX];
         pop @{ $keys };

         ## GC end of list
         if ( ref $keys->[-1] ) {
            my $i = 0;
            $i++, pop @{ $keys } while ref( $keys->[-1] );
            $self->[_GCNT] -= $i;
         }
      }

      ## key is in the middle
      else {
         my $indx = $self->[_INDX] || $self->_make_indx();
         my $id   = delete $indx->{ $key };

         ## refresh index on-demand only
         $self->_fill_indx(), $id = delete $indx->{ $key } if !defined $id;

         ## tombstone deletion
         $keys->[ $id - $self->[_BEGI] ] = _TOMBSTONE;

         ## GC keys if more than half have been deleted
         $self->purge() if ++$self->[_GCNT] > ( @{ $keys } >> 1 );
      }

      $self->[_BEGI] = 0, $self->[_INDX] = undef unless @{ $keys };

      delete $self->[_DATA]{ $key };
   }
   else {
      undef;
   }
}

sub FIRSTKEY {
   my ( $self ) = @_;
   my @keys = grep !ref($_), @{ $self->[_KEYS] };

   $self->[_ITER] = sub {
      return unless @keys;
      return shift(@keys);
   };

   $self->[_ITER]->();
}

sub NEXTKEY {
   $_[0]->[_ITER]->();
}

sub EXISTS {
   exists $_[0]->[_DATA]{ $_[1] };
}

sub CLEAR {
   my ( $self ) = @_;

   %{ $self->[_DATA] } = @{ $self->[_KEYS] } = (   ),
      $self->[_BEGI]   =    $self->[_GCNT]   =   0  ,
      $self->[_INDX]   =    $self->[_ITER]   = undef;

   ();
}

sub SCALAR {
   @{ $_[0]->[_KEYS] } - $_[0]->[_GCNT];
}

###############################################################################
## ----------------------------------------------------------------------------
## POP, PUSH, SHIFT, UNSHIFT, SPLICE
##
###############################################################################

sub POP {
   my $self = shift;
   my $key  = pop @{ $self->[_KEYS] };

   if ( $self->[_GCNT] ) {
      my $keys = $self->[_KEYS];

      ## GC end of list
      if ( ref $keys->[-1] ) {
         my $i = 0;
         $i++, pop @{ $keys } while ref( $keys->[-1] );
         $self->[_GCNT] -= $i;
      }

      $self->[_BEGI] = 0, $self->[_INDX] = undef unless @{ $keys };
   }

   if ( defined $key ) {
      delete $self->[_INDX]{ $key } if $self->[_INDX];

      return $key, delete $self->[_DATA]{ $key };
   }

   return;
}

sub PUSH {                                        # ( @pairs ); reorder
   my $self = shift;
   my ( $data, $keys ) = @$self;

   while ( @_ ) {
      my ( $key, $val ) = splice( @_, 0, 2 );

      $self->DELETE($key) if exists $data->{ $key };
      push @{ $keys }, "$key";
      $data->{ $key } = $val;
   }

   @{ $keys } - $self->[_GCNT];
}

sub SHIFT {
   my $self = shift;
   my $key  = shift @{ $self->[_KEYS] };

   if ( $self->[_GCNT] ) {
      my $keys = $self->[_KEYS];

      ## GC start of list
      if ( ref $keys->[0] ) {
         my $i = 0;
         $i++, shift @{ $keys } while ref( $keys->[0] );
         $self->[_BEGI] += $i, $self->[_GCNT] -= $i;
      }

      $self->[_BEGI] = 0, $self->[_INDX] = undef unless @{ $keys };
   }

   if ( defined $key ) {
      $self->[_BEGI]++, delete $self->[_INDX]{ $key } if $self->[_INDX];

      return $key, delete $self->[_DATA]{ $key };
   }

   return;
}

sub UNSHIFT {                                     # ( @pairs ); reorder
   my $self = shift;
   my ( $data, $keys ) = @$self;

   while ( @_ ) {
      my ( $key, $val ) = splice( @_, -2, 2 );

      $self->DELETE($key) if exists $data->{ $key };
      $data->{ $key } = $val, unshift @{ $keys }, "$key";
      $self->[_BEGI]-- if $self->[_INDX];
   }

   @{ $keys } - $self->[_GCNT];
}

sub SPLICE {                                      # ( $off, $len, @pairs )
   my ( $self, $off ) = ( shift, shift );
   my ( $data, $keys, $indx ) = @$self;
   my ( $key, @ret );

   return @ret unless defined $off;

   $self->purge() if $indx;

   my $size = scalar @{ $keys };
   my $len  = @_ ? shift : $size - $off;

   if ( $off >= $size ) {
      $self->push(@_) if @_;
   }
   elsif ( abs($off) <= $size ) {
      if ( $len > 0 ) {
         $off = $off + @{ $keys } if $off < 0;
         my @k = splice @{ $keys }, $off, $len;
         push(@ret, $_, delete $data->{ $_ }) for @k;
      }
      if ( @_ ) {
         my @k = splice @{ $keys }, $off;
         $self->push(@_);
         push(@{ $keys }, "$_") for @k;
      }
   }

   return @ret;
}

###############################################################################
## ----------------------------------------------------------------------------
## Private methods.
##
###############################################################################

## Create / fill index with ( key => id ) pairs.

sub _make_indx {
   my ( $self, $i, %indx ) = ( shift, 0 );

   $indx{ $_ } = $i++ for @{ $self->[_KEYS] };

   $self->[_BEGI] = 0;
   $self->[_INDX] = \%indx;
}

sub _fill_indx {
   my ( $self ) = @_;
   my ( $keys, $indx ) = ( $self->[_KEYS], $self->[_INDX] );

   return $self->_make_indx() unless defined $indx;

   my ( $left, $right ) = @{ $indx }{ @{ $keys }[ 0, -1 ] };

   if ( !defined $left ) {
      my ( $pos, $id, $key ) = ( 0, $self->[_BEGI] );

      for ( 1 .. @{ $keys } ) {
         $key = $keys->[ $pos ];
         if ( !ref $key ) {
            last if exists $indx->{ $key };
            $indx->{ $key } = $id;
         }
         $pos++, $id++;
      }
   }

   if ( !defined $right ) {
      my ( $pos, $id, $key ) = ( -1, $self->[_BEGI] + $#{ $keys } );

      for ( 1 .. @{ $keys } ) {
         $key = $keys->[ $pos ];
         if ( !ref $key ) {
            last if exists $indx->{ $key };
            $indx->{ $key } = $id;
         }
         $pos--, $id--;
      }
   }

   $indx;
}

sub _reorder {
   my ( $self ) = ( shift );
   my ( $data, $keys ) = @$self;
   my ( %keep );

   return unless @_;

   $self->[_BEGI] = $self->[_GCNT] = 0,
   $self->[_INDX] = $self->[_ITER] = undef;

   @{ $keys } = ();

   for ( @_ ) {
      if ( exists $data->{ $_ } ) {
         $keep{ $_ } = $data->{ $_ };
         push(@{ $keys }, "$_");
      }
   }

   $self->[_DATA] = \%keep;

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## clone, flush, iterator, mget, mset, keys, values, pairs
##
###############################################################################

sub clone {
   my $self = shift;
   my $params = ref($_[0]) eq 'HASH' ? shift : {};
   my $DATA = $self->[_DATA];
   my ( $key, %data, @keys );

   if ( @_ ) {
      while ( @_ ) {
         $key = shift;
         push @keys, "$key" unless exists $data{ $key };
         $data{ $key } = $DATA->{ $key };
      }
   }
   else {
      for my $key ( @{ $self->[_KEYS] } ) {
         next if ref $key;
         push @keys, "$key" unless exists $data{ $key };
         $data{ $key } = $DATA->{ $key };
      }
   }

   $self->clear() if $params->{'flush'};
   bless [ \%data, \@keys, undef, 0, 0, undef ], ref $self;
}

sub flush {
   shift()->clone( { flush => 1 }, @_ );
}

sub iterator {
   my ( $self, @keys ) = @_;
   my $data = $self->[_DATA];
   @keys = grep !ref($_), @{ $self->[_KEYS] } unless @keys;

   return sub {
      return unless @keys;
      my $key = shift(@keys);
      return ( $key => $data->{ $key } );
   };
}

sub mget {
   my $self = shift;

   @_ ? @{ $self->[_DATA] }{ @_ }
      : ();
}

sub mset {
   my $self = shift;
   my ( $data, $keys, $key ) = ( $self->[_DATA], $self->[_KEYS] );
   _croak("requires key-value pairs") unless ( @_ % 2 == 0 );

   while ( @_ ) {
      $key = shift;
      push @{ $keys }, "$key" unless exists $data->{ $key };
      $data->{ $key } = shift;
   }

   @{ $keys } - $self->[_GCNT];
}

sub keys {
   my $self = shift;

   if ( wantarray ) {
      my $data = $self->[_DATA];
      @_ ? map { exists $data->{ $_ } ? $_ : undef } @_
         : grep !ref($_), @{ $self->[_KEYS] };
   }
   else {
      @{ $self->[_KEYS] } - $self->[_GCNT];
   }
}

sub values {
   my $self = shift;

   if ( wantarray ) {
      @_ ? @{ $self->[_DATA] }{ @_ }
         : @{ $self->[_DATA] }{ grep !ref($_), @{ $self->[_KEYS] } };
   }
   else {
      @{ $self->[_KEYS] } - $self->[_GCNT];
   }
}

sub pairs {
   my $self = shift;

   if ( wantarray ) {
      my $data = $self->[_DATA];
      @_ ? map { $_ => $data->{ $_ } } @_
         : map { $_ => $data->{ $_ } }
              grep !ref($_), @{ $self->[_KEYS] };
   }
   else {
      ( @{ $self->[_KEYS] } - $self->[_GCNT] ) << 1;
   }
}

###############################################################################
## ----------------------------------------------------------------------------
## purge, find, sort
##
###############################################################################

sub purge {
   my ( $self ) = @_;

   ## @{ $self->[_KEYS] } = grep !ref($_), @{ $self->[_KEYS] };

   ## Tombstone purging is done in-place for lesser memory consumption.

   if ( $self->[_GCNT] ) {
      my ( $i, $keys ) = ( 0, $self->[_KEYS] );

      if ( @{ $keys } ) {
         for ( 0 .. @{ $keys } - 1 ) {
            next if ref( $keys->[$_] );
            $keys->[ $i++ ] = $keys->[$_];
         }
         splice @{ $keys }, $i;
      }
   }

   $self->[_INDX] = undef, $self->[_BEGI] = $self->[_GCNT] = 0;

   return;
}

sub find {
   my ( $self, $search ) = @_;
   my ( $attr, $op, $expr ) = split( /\s+/, $search, 3 );
   my ( $data, $keys ) = @{ $self };

   ## Returns ( KEY, VALUE ) pairs where KEY matches expression.

   if ( $attr eq 'key' ) {
      my $_find = $self->_find_keys_hash();

      _croak('Find error: invalid OPCODE') unless length $op;
      _croak('Find error: invalid OPCODE') unless exists $_find->{ $op };
      _croak('Find error: invalid EXPR'  ) unless length $expr;

      $expr = undef if $expr eq 'undef';

      $_find->{ $op }->( $data, $expr, grep !ref($_), @{ $keys } );
   }

   ## Returns ( KEY, VALUE ) pairs where VALUE matches expression.

   elsif ( $attr eq 'val' || $attr eq 'value' ) {
      my $_find = $self->_find_vals_hash();

      _croak('Find error: invalid OPCODE') unless length $op;
      _croak('Find error: invalid OPCODE') unless exists $_find->{ $op };
      _croak('Find error: invalid EXPR'  ) unless length $expr;

      $expr = undef if $expr eq 'undef';

      $_find->{ $op }->( $data, $expr, grep !ref($_), @{ $keys } );
   }

   ## Error.

   else {
      _croak('Find error: invalid ATTR');
   }
}

sub sort {
   my ( $self, $request ) = @_;
   my ( $by_key, $alpha, $desc ) = ( 0, 0, 0 );

   if ( length $request ) {
      $by_key = 1 if $request =~ /key/i;
      $alpha  = 1 if $request =~ /alpha/i;
      $desc   = 1 if $request =~ /desc/i;
   }

   ## Sort by key.

   if ( $by_key ) {
      if ( $alpha ) { ( $desc )
         ? $self->_reorder( CORE::sort { $b cmp $a } $self->keys )
         : $self->_reorder( CORE::sort { $a cmp $b } $self->keys );
      }
      else { ( $desc )
         ? $self->_reorder( CORE::sort { $b <=> $a } $self->keys )
         : $self->_reorder( CORE::sort { $a <=> $b } $self->keys );
      }

      $self->values if defined wantarray;
   }

   ## Sort by value.

   else {
      my $d = $self->[_DATA];

      if ( $alpha ) { ( $desc )
         ? $self->_reorder( CORE::sort { $d->{$b} cmp $d->{$a} } $self->keys )
         : $self->_reorder( CORE::sort { $d->{$a} cmp $d->{$b} } $self->keys );
      }
      else { ( $desc )
         ? $self->_reorder( CORE::sort { $d->{$b} <=> $d->{$a} } $self->keys )
         : $self->_reorder( CORE::sort { $d->{$a} <=> $d->{$b} } $self->keys );
      }

      $self->values if defined wantarray;
   }
}

###############################################################################
## ----------------------------------------------------------------------------
## append, decr, decrby, incr, incrby, pdecr, pincr
##
###############################################################################

sub append {   $_[0]->[_DATA]{ $_[1] } .= $_[2] || '' ;
        length $_[0]->[_DATA]{ $_[1] }
}
sub decr   { --$_[0]->[_DATA]{ $_[1] }                }
sub decrby {   $_[0]->[_DATA]{ $_[1] } -= $_[2] || 0  }
sub incr   { ++$_[0]->[_DATA]{ $_[1] }                }
sub incrby {   $_[0]->[_DATA]{ $_[1] } += $_[2] || 0  }
sub pdecr  {   $_[0]->[_DATA]{ $_[1] }--              }
sub pincr  {   $_[0]->[_DATA]{ $_[1] }++              }

sub length {
   ( defined $_[1] )
      ? CORE::length( $_[0]->[_DATA]{ $_[1] } )
      : @{ $_[0]->[_KEYS] } - $_[0]->[_GCNT];
}

## Aliases.

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
}

## For on-demand hash-like dereferencing.

package MCE::Shared::Ordhash::_href;

sub TIEHASH { $_[1] }

1;

__END__

###############################################################################
## ----------------------------------------------------------------------------
## Module usage.
##
###############################################################################

=head1 NAME

MCE::Shared::Ordhash - Class for sharing ordered hashes via MCE::Shared

=head1 VERSION

This document describes MCE::Shared::Ordhash version 1.699_002

=head1 SYNOPSIS

   # non-shared
   use MCE::Shared::Ordhash;

   my $oh = MCE::Shared::Ordhash->new( @pairs );

   # shared
   use MCE::Shared;

   my $oh = MCE::Shared->ordhash( @pairs );

   # oo interface
   $val   = $oh->set( $key, $val );
   $val   = $oh->get( $key );
   $val   = $oh->delete( $key );
   $bool  = $oh->exists( $key );
   void   = $oh->clear();
   $len   = $oh->length();                    # scalar keys %{ $oh }
   $len   = $oh->length( $key );              # length $oh->{ $key }
   @pair  = $oh->pop();
   $len   = $oh->push( @pairs );
   @pair  = $oh->shift();
   $len   = $oh->unshift( @pairs );
   %pairs = $oh->splice( $offset, $length, @pairs );

   $oh2   = $oh->clone( @keys );              # @keys is optional
   $oh3   = $oh->flush( @keys );
   $iter  = $oh->iterator( @keys );           # ($key, $val) = $iter->()
   $len   = $oh->mset( $key/$val pairs );
   @vals  = $oh->mget( @keys );
   @keys  = $oh->keys( @keys );
   @vals  = $oh->values( @keys );
   %pairs = $oh->pairs( @keys );

   @vals  = $oh->sort();                      # by val $a <=> $b default
   @vals  = $oh->sort( "desc" );              # by val $b <=> $a
   @vals  = $oh->sort( "alpha" );             # by val $a cmp $b
   @vals  = $oh->sort( "alpha desc" );        # by val $b cmp $a

   @vals  = $oh->sort( "key" );               # by key $a <=> $b
   @vals  = $oh->sort( "key desc" );          # by key $b <=> $a
   @vals  = $oh->sort( "key alpha" );         # by key $a cmp $b
   @vals  = $oh->sort( "key alpha desc" );    # by key $b cmp $a

   %pairs = $oh->find( "val =~ /$pattern/i" );
   %pairs = $oh->find( "val !~ /$pattern/i" );
   %pairs = $oh->find( "key =~ /$pattern/i" );
   %pairs = $oh->find( "key !~ /$pattern/i" );

   %pairs = $oh->find( "val eq $string" );    # also, search key
   %pairs = $oh->find( "val ne $string" );
   %pairs = $oh->find( "val lt $string" );
   %pairs = $oh->find( "val le $string" );
   %pairs = $oh->find( "val gt $string" );
   %pairs = $oh->find( "val ge $string" );

   %pairs = $oh->find( "val == $number" );    # ditto, find( "key ..." )
   %pairs = $oh->find( "val != $number" );
   %pairs = $oh->find( "val <  $number" );
   %pairs = $oh->find( "val <= $number" );
   %pairs = $oh->find( "val >  $number" );
   %pairs = $oh->find( "val >= $number" );

   # sugar methods without having to call set/get explicitly
   $len   = $oh->append( $key, $string );     #   $val .= $string
   $val   = $oh->decr( $key );                # --$val
   $val   = $oh->decrby( $key, $number );     #   $val -= $number
   $val   = $oh->incr( $key );                # ++$val
   $val   = $oh->incrby( $key, $number );     #   $val += $number
   $val   = $oh->pdecr( $key );               #   $val--
   $val   = $oh->pincr( $key );               #   $val++

=head1 DESCRIPTION

Helper class for L<MCE::Shared|MCE::Shared>.

=head1 API DOCUMENTATION

To be completed before the final 1.700 release.

=over 3

=item new

=item set

=item get

=item delete

=item exists

=item clear

=item length

=item pop

=item push

=item shift

=item unshift

=item splice

=item purge

=item clone

=item flush

=item iterator

=item mget

=item mset

=item keys

=item values

=item pairs

=item find

=item sort

=item append

=item decr

=item decrby

=item incr

=item incrby

=item pdecr

=item pincr

=back

=head1 CREDITS

Implementation inspired by L<Hash::Ordered|Hash::Ordered>.

=head1 INDEX

L<MCE|MCE>, L<MCE::Core|MCE::Core>, L<MCE::Shared|MCE::Shared>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

