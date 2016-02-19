###############################################################################
## ----------------------------------------------------------------------------
## A pure-Perl in-memory data store.
##
###############################################################################

package MCE::Shared::Minidb;

use strict;
use warnings;

no warnings qw( threads recursion uninitialized numeric );

our $VERSION = '1.699_011';

use MCE::Shared::Base;
use MCE::Shared::Ordhash;
use MCE::Shared::Array;
use MCE::Shared::Hash;
use bytes;

use overload (
   q("")    => \&MCE::Shared::Base::_stringify,
   q(0+)    => \&MCE::Shared::Base::_numify,
   fallback => 1
);

sub new {
   # Parallel Hashes: [ HoH, HoA ]
   bless [
      MCE::Shared::Ordhash->new(),  # Hash of Hashes (HoH)
      MCE::Shared::Ordhash->new(),  # Hash of Arrays (HoA)
   ], shift;
}

###############################################################################
## ----------------------------------------------------------------------------
## Private methods.
##
###############################################################################

#  Query string:
#
#  Several methods receive a query string argument. The string is quoteless.
#  Basically, any quotes inside the string will be treated literally.
#
#  Search capability: =~ !~ eq ne lt le gt ge == != < <= > >=
#
#  "key =~ /pattern/i :AND field =~ /pattern/i"
#  "key =~ /pattern/i :AND index =~ /pattern/i"
#  "key =~ /pattern/i :AND field eq foo bar"     # address eq foo bar
#  "index eq foo baz :OR key !~ /pattern/i"      # 9 eq foo baz
#
#     key   means to match against keys in the hash (H)oH or (H)oA
#     field means to match against HoH->{key}->{field}; e.g. address
#     index means to match against HoA->{key}->[index]; e.g. 9
#
#  Keys in hash may have spaces, but not field names Ho(H).
#  :AND(s) and :OR(s) mixed together is not supported.

# _hfind ( { getkeys => 1 }, "query string" )
# _hfind ( { getvals => 1 }, "query string" )
# _hfind ( "query string" ) # pairs

sub _hfind {
   my $self   = shift;
   my $params = ref($_[0]) eq 'HASH' ? shift : {};

   if ( @_ == 2 ) {
      my $key = shift;
      return () unless exists($self->[0][0]{ $key });
      $self->[0][0]{ $key }->_find($params, @_);
   }
   else {
      my $query = shift;
      $params->{'hfind'} = 1;

      MCE::Shared::Base::_find_hash(
         $self->[0][0], $params, $query, $self->[0]
      );
   }
}

# _lfind ( { getkeys => 1 }, "query string" )
# _lfind ( { getvals => 1 }, "query string" )
# _lfind ( "query string" ) # pairs

sub _lfind {
   my $self   = shift;
   my $params = ref($_[0]) eq 'HASH' ? shift : {};

   if ( @_ == 2 ) {
      my $key = shift;
      return () unless exists($self->[1][0]{ $key });
      $self->[1][0]{ $key }->_find($params, @_);
   }
   else {
      my $query = shift;
      $params->{'lfind'} = 1;

      MCE::Shared::Base::_find_hash(
         $self->[1][0], $params, $query, $self->[1]
      );
   }
}

# _new_hash ( ) applies to HoH

sub _new_hash {
   MCE::Shared::Hash->new();
}

# _new_list ( ) applies to HoA

sub _new_list {
   MCE::Shared::Array->new();
}

# The select_aref and select_href methods receive a select string
# allowing one to specify field names and sort directives.
#
# "f1 f2 f3 :WHERE f4 > 20 :AND key =~ /foo/ :ORDER BY f5 DESC ALPHA"
# "f1 f2 f3 :where f4 > 20 :and key =~ /foo/ :order by f5 desc alpha"
#
# "f5 f1 f2 :WHERE fN > 40 :AND key =~ /bar/ :ORDER BY key ALPHA"
# "f5 f1 f2 :where fN > 40 :and key =~ /bar/ :order by key alpha"
#
# "f5 f1 f2 :WHERE fN > 40 :AND key =~ /bar/"
# "f5 f1 f2 :where fN > 40 :and key =~ /bar/"
#
# "f5 f1 f2"
#
# The shorter form without field names is allowed for HoA.
#
# "4 > 20 :and key =~ /baz/"  4 is the array index 

# _qparse ( "select string" )

sub _qparse {
   my ( $q ) = @_;
   my ( $f, $w, $o );

   if ( $q =~ /^([\S ]*):where[ ]+(.+):order by[ ]+(.+)/i ) {
      ( $f, $w, $o ) = ( $1, $2, $3 );
   }
   elsif ( $q =~ /^([\S ]*):where[ ]+(.+)/i ) {
      ( $f, $w ) = ( $1, $2 );
   }
   elsif ( $q =~ /^([\S ]*):order by[ ]+(.+)/i ) {
      ( $f, $o ) = ( $1, $2 );
   }
   elsif ( $q =~ /^((?:key|\S+)[ ]+(?:=|!|<|>|e|n|l|g)\S?[ ]+\S.*)/ ) {
      ( $w ) = ( $1 );
   }
   elsif ( $q =~ /^([\S ]*)/ ) {
      ( $f ) = ( $1 );
   }

   $f =~ s/[ ]+$//, $w =~ s/[ ]+$//, $o =~ s/[ ]+$//;

   return ( $f, $w, $o );
}

# _hselect_aref ( "select string" ) see _qparse
# this returns array containing [ key, aref ] pairs

sub _hselect_aref {
   my ( $self, $query ) = @_;
   my ( $f, $w, $o ) = _qparse($query);

   my @fields = split(' ', $f);
   my $data   = $self->[0][0];

   unless ( @fields ) {
      warn("_hselect_aref: must specify fieldname(s)");
      return ();
   }

   if ( length $w ) {
      my %match = map { $_ => 1 } ( $self->hkeys($w) );
      map { !exists $match{$_} ? () : do {
               my ( $k, @ret ) = ( $_ );
               push @ret, $data->{$k}{$_} for @fields;
               [ $k, \@ret ];
            };
          } ( length $o ? $self->hsort($o) : $self->hkeys() );
   }
   else {
      map { my ( $k, @ret ) = ( $_ );
            push @ret, $data->{$k}{$_} for @fields;
            [ $k, \@ret ];
          } ( length $o ? $self->hsort($o) : $self->hkeys() );
   }
}

# _hselect_href ( "select string" ) see _qparse
# this returns array containing [ key, href ] pairs

sub _hselect_href {
   my ( $self, $query ) = @_;
   my ( $f, $w, $o ) = _qparse($query);

   my @fields = split(' ', $f);
   my $data   = $self->[0][0];

   if ( length $w ) {
      my %match = map { $_ => 1 } ( $self->hkeys($w) );
      if ( @fields ) {
         map { !exists $match{$_} ? () : do {
                  my ( $k, %ret ) = ( $_ );
                  $ret{$_} = $data->{$k}{$_} for @fields;
                  [ $k, \%ret ];
               };
             } ( length $o ? $self->hsort($o) : $self->hkeys() );
      }
      else {
         map { !exists $match{$_} ? () : [ $_, { %{ $data->{$_} } } ];
             } ( length $o ? $self->hsort($o) : $self->hkeys() );
      }
   }
   else {
      if ( @fields ) {
         map { my ( $k, %ret ) = ( $_ );
               $ret{$_} = $data->{$k}{$_} for @fields;
               [ $k, \%ret ];
             } ( length $o ? $self->hsort($o) : $self->hkeys() );
      }
      else {
         map { [ $_, { %{ $data->{$_} } } ];
             } ( length $o ? $self->hsort($o) : $self->hkeys() );
      }
   }
}

# _lselect_aref ( "select string" ) see _qparse
# this returns array containing [ key, aref ] pairs

sub _lselect_aref {
   my ( $self, $query ) = @_;
   my ( $f, $w, $o ) = _qparse($query);

   my @fields = split(' ', $f);
   my $data   = $self->[1][0];

   if ( length $w ) {
      my %match = map { $_ => 1 } ( $self->lkeys($w) );
      if ( @fields ) {
         map { !exists $match{$_} ? () : do {
                  my ( $k, @ret ) = ( $_ );
                  push @ret, $data->{$k}[$_] for @fields;
                  [ $k, \@ret ];
               };
             } ( length $o ? $self->lsort($o) : $self->lkeys() );
      }
      else {
         map { !exists $match{$_} ? () : [ $_, [ @{ $data->{$_} } ] ];
             } ( length $o ? $self->lsort($o) : $self->lkeys() );
      }
   }
   else {
      if ( @fields ) {
         map { my ( $k, @ret ) = ( $_ );
               push @ret, $data->{$k}[$_] for @fields;
               [ $k, \@ret ];
             } ( length $o ? $self->lsort($o) : $self->lkeys() );
      }
      else {
         map { [ $_, [ @{ $data->{$_} } ] ];
             } ( length $o ? $self->lsort($o) : $self->lkeys() );
      }
   }
}

# _lselect_href ( "select string" ) see _qparse
# this returns array containing [ key, href ] pairs

sub _lselect_href {
   my ( $self, $query ) = @_;
   my ( $f, $w, $o ) = _qparse($query);

   my @fields = split(' ', $f);
   my $data = $self->[1][0];

   if ( length $w ) {
      my %match = map { $_ => 1 } ( $self->lkeys($w) );
      if ( @fields ) {
         map { !exists $match{$_} ? () : do {
                  my ( $k, %ret ) = ( $_ );
                  $ret{$_} = $data->{$k}[$_] foreach @fields;
                  [ $k, \%ret ];
               };
             } ( length $o ? $self->lsort($o) : $self->lkeys() );
      }
      else {
         map { !exists $match{$_} ? () : do {
                  my ( $k, %ret ) = ( $_ );
                  $ret{$_} = $data->{$k}[$_] for 0 .. $#{ $data->{$k} };
                  [ $k, \%ret ];
               };
             } ( length $o ? $self->lsort($o) : $self->lkeys() );
      }
   }
   else {
      if ( @fields ) {
         map { my ( $k, %ret ) = ( $_ );
               $ret{$_} = $data->{$k}[$_] foreach @fields;
               [ $k, \%ret ];
             } ( length $o ? $self->lsort($o) : $self->lkeys() );
      }
      else {
         map { my ( $k, %ret ) = ( $_ );
               $ret{$_} = $data->{$k}[$_] for 0 .. $#{ $data->{$k} };
               [ $k, \%ret ];
             } ( length $o ? $self->lsort($o) : $self->lkeys() );
      }
   }
}

# _sort ( HoH, 0, "BY key   [ ASC | DESC ] [ ALPHA ]" )
# _sort ( HoH, 0, "BY field [ ASC | DESC ] [ ALPHA ]" ) e.g. BY address
# _sort ( HoA, 1, "BY key   [ ASC | DESC ] [ ALPHA ]" )
# _sort ( HoA, 1, "BY index [ ASC | DESC ] [ ALPHA ]" ) e.g. BY 9

sub _sort {
   my ( $o, $is_list, $request ) = @_;

   return () unless ( length $request );
   $request =~ s/^[ ]*\bby\b[ ]*//i;

   if ( $request =~ /^[ ]*(\S+)[ ]*(.*)/ ) {
      my ( $f, $modifiers, $alpha, $desc ) = ( $1, $2, 0, 0 );

      $alpha = 1 if ( $modifiers =~ /\balpha\b/i );
      $desc  = 1 if ( $modifiers =~ /\bdesc\b/i );

      # Return sorted keys, leaving the data intact.

      if ( defined wantarray ) {
         if ( $f eq 'key' ) {                         # by key
            if ( $alpha ) { ( $desc )
             ? sort { $b cmp $a } $o->keys
             : sort { $a cmp $b } $o->keys;
            }
            else { ( $desc )
             ? sort { $b <=> $a } $o->keys
             : sort { $a <=> $b } $o->keys;
            }
         }
         else {                                       # by field
            my $d = $o->[0];
            if ( $is_list ) {
               if ( $alpha ) { ( $desc )
                ? sort { $d->{$b}[$f] cmp $d->{$a}[$f] } $o->keys
                : sort { $d->{$a}[$f] cmp $d->{$b}[$f] } $o->keys;
               }
               else { ( $desc )
                ? sort { $d->{$b}[$f] <=> $d->{$a}[$f] } $o->keys
                : sort { $d->{$a}[$f] <=> $d->{$b}[$f] } $o->keys;
               }
            }
            else {
               if ( $alpha ) { ( $desc )
                ? sort { $d->{$b}{$f} cmp $d->{$a}{$f} } $o->keys
                : sort { $d->{$a}{$f} cmp $d->{$b}{$f} } $o->keys;
               }
               else { ( $desc )
                ? sort { $d->{$b}{$f} <=> $d->{$a}{$f} } $o->keys
                : sort { $d->{$a}{$f} <=> $d->{$b}{$f} } $o->keys;
               }
            }
         }
      }

      # Sort in-place otherwise, in void context.

      elsif ( $f eq 'key' ) {                         # by key
         if ( $alpha ) { ( $desc )
          ? $o->_reorder( sort { $b cmp $a } $o->keys )
          : $o->_reorder( sort { $a cmp $b } $o->keys );
         }
         else { ( $desc )
          ? $o->_reorder( sort { $b <=> $a } $o->keys )
          : $o->_reorder( sort { $a <=> $b } $o->keys );
         }
      }
      else {                                          # by field
         my $d = $o->[0];
         if ( $is_list ) {
            if ( $alpha ) { ( $desc )
             ? $o->_reorder( sort { $d->{$b}[$f] cmp $d->{$a}[$f] } $o->keys )
             : $o->_reorder( sort { $d->{$a}[$f] cmp $d->{$b}[$f] } $o->keys );
            }
            else { ( $desc )
             ? $o->_reorder( sort { $d->{$b}[$f] <=> $d->{$a}[$f] } $o->keys )
             : $o->_reorder( sort { $d->{$a}[$f] <=> $d->{$b}[$f] } $o->keys );
            }
         }
         else {
            if ( $alpha ) { ( $desc )
             ? $o->_reorder( sort { $d->{$b}{$f} cmp $d->{$a}{$f} } $o->keys )
             : $o->_reorder( sort { $d->{$a}{$f} cmp $d->{$b}{$f} } $o->keys );
            }
            else { ( $desc )
             ? $o->_reorder( sort { $d->{$b}{$f} <=> $d->{$a}{$f} } $o->keys )
             : $o->_reorder( sort { $d->{$a}{$f} <=> $d->{$b}{$f} } $o->keys );
            }
         }
      }
   }
   else {
      ();
   }
}

###############################################################################
## ----------------------------------------------------------------------------
## Common methods.
##
###############################################################################

# dump ( "file.dat" )

sub dump {
   my ( $self, $file ) = @_;

   if ( length $file ) {
      require Storable unless $INC{'Storable.pm'};

      # purge tombstones
      $self->[0]->purge(), $self->[1]->purge();

      local ( $SIG{__DIE__}, $@ ) = ( sub { } );
      eval { Storable::nstore($self, $file) };

      warn($@), return if $@;
   }
   else {
      warn('Usage: $obj->dump("file.dat")');
      return;
   }

   1;
}

# restore ( "file.dat" )

sub restore {
   my ( $self, $file ) = @_;

   if ( length $file ) {
      require Storable unless $INC{'Storable.pm'};

      local ( $SIG{__DIE__}, $@ ) = ( sub { } );
      my $obj = eval { Storable::retrieve($file) };
      warn($@), return if $@;

      if ( ref($obj) ne 'MCE::Shared::Minidb' ) {
         warn("$file isn't serialized Minidb data: ".ref($obj));
         return;
      }
      $self->[1]->clear(), $self->[1] = delete $obj->[1];
      $self->[0]->clear(), $self->[0] = delete $obj->[0];
   }
   else {
      warn('Usage: $obj->restore("file.dat")');
      return;
   }

   1;
}

# iterator ( ":lists" )
# iterator ( ":lists", "query string" )
# iterator ( ":lists", key, "query string" )
# iterator ( ":lists", key [, key, ... ] )
#
# iterator ( ":hashes" )
# iterator ( ":hashes", "query string" )
# iterator ( ":hashes", key, "query string" )
# iterator ( ":hashes", key [, key, ... ] )
#
# iterator  same as ":hashes"

sub iterator {
   my ( $self, @keys ) = @_;
   my $data;

   if ( $keys[0] =~ /^:lists$/i ) {
      $data = $self->[1][0];
      shift @keys;
      if ( !scalar @keys ) {
         @keys = $self->lkeys();
      }
      elsif ( @keys == 1 && $keys[0] =~ /^(?:key|\S+)[ ]+\S\S?[ ]+\S/ ) {
         @keys = $self->lkeys(@keys);
      }
      elsif ( @keys == 2 && $keys[1] =~ /^(?:key|val)[ ]+\S\S?[ ]+\S/ ) {
         $data = $self->[1][0]->{ $keys[0] };
         @keys = $self->lkeys(@keys);
         return sub {
            return unless @keys;
            my $key = shift(@keys);
            return ( $key => $data->[ $key ] );
         };
      }
   }
   else {
      $data = $self->[0][0];
      shift @keys if ( $keys[0] =~ /^:hashes$/i );
      if ( !scalar @keys ) {
         @keys = $self->hkeys();
      }
      elsif ( @keys == 1 && $keys[0] =~ /^(?:key|\S+)[ ]+\S\S?[ ]+\S/ ) {
         @keys = $self->hkeys(@keys);
      }
      elsif ( @keys == 2 && $keys[1] =~ /^(?:key|val)[ ]+\S\S?[ ]+\S/ ) {
         $data = $self->[0][0]->{ $keys[0] };
         @keys = $self->hkeys(@keys);
      }
   }

   return sub {
      return unless @keys;
      my $key = shift(@keys);
      return ( $key => $data->{ $key } );
   };
}

# select_aref ( ":lists", "select string" )
# select_aref ( ":hashes", "select string" )
# select_aref ( "select string" )  same as ":hashes"

sub select_aref {
   my ( $self, @query ) = @_;

   if ( $query[0] =~ /^:lists$/i ) {
      shift @query;
      $self->_lselect_aref($query[0]);
   }
   else {
      shift @query if ( $query[0] =~ /^:hashes$/i );
      $self->_hselect_aref($query[0]);
   }
}

# select_href ( ":lists", "select string" )
# select_href ( ":hashes", "select string" )
# select_href ( "select string" )  same as ":hashes"

sub select_href {
   my ( $self, @query ) = @_;

   if ( $query[0] =~ /^:lists$/i ) {
      shift @query;
      $self->_lselect_href($query[0]);
   }
   else {
      shift @query if ( $query[0] =~ /^:hashes$/i );
      $self->_hselect_href($query[0]);
   }
}

###############################################################################
## ----------------------------------------------------------------------------
## Hash of Hashes (HoH).
##
###############################################################################

# hset ( key, field, value [, field, value, ... ] )

sub hset {
   my ( $self, $key ) = ( shift, shift );
   return unless length($key);
   if ( @_ ) {
      $self->[0]->set($key, _new_hash()) unless exists($self->[0][0]{ $key });
      if ( @_ == 2 ) {
         $self->[0][0]{ $key }{ $_[0] } = $_[1];
      } else {
         $self->[0][0]{ $key }->mset(@_);
      }
   }
   else {
      return;
   }
}

# hget ( key, field [, field, ... ] )
# hget ( key )

sub hget {
   my ( $self, $key ) = ( shift, shift );
   return unless length($key);
   if ( @_ ) {
      return unless exists($self->[0][0]{ $key });
      if ( @_ == 1 ) {
         $self->[0][0]{ $key }{ $_[0] };
      } else {
         $self->[0][0]{ $key }->mget(@_);
      }
   }
   else {
      $self->[0][0]{ $key };
   }
}

# hdel ( key, field [, field, ... ] )
# hdel ( key )

sub hdel {
   my ( $self, $key ) = ( shift, shift );
   return unless length($key);
   if ( @_ ) {
      return unless exists($self->[0][0]{ $key });
      if ( @_ == 1 ) {
         delete $self->[0][0]{ $key }{ $_[0] };
      } else {
         $self->[0][0]{ $key }->mdel(@_);
      }
   }
   else {
      $self->[0]->del($key);
   }
}

# hexists ( key, field [, field, ... ] )
# hexists ( key )

sub hexists {
   my ( $self, $key ) = ( shift, shift );
   return '' unless length($key);
   if ( @_ ) {
      return '' unless exists($self->[0][0]{ $key });
      if ( @_ == 1 ) {
         exists $self->[0][0]{ $key }{ $_[0] };
      } else {
         $self->[0][0]{ $key }->mexists(@_);
      }
   }
   else {
      exists $self->[0][0]{ $key };
   }
}

# hclear ( key )
# hclear ( )

sub hclear {
   my ( $self, $key ) = @_;
   if ( @_ > 1 ) {
      return unless exists($self->[0][0]{ $key });
      $self->[0][0]{ $key }->clear();
   }
   else {
      $self->[0]->clear();
   }
}

# hkeys ( key, field [, field, ... ] )
# hkeys ( "query string" )
# hkeys ( )

sub hkeys {
   my $self = shift;

   if ( @_ == 1 && $_[0] =~ /^(?:key|\S+)[ ]+\S\S?[ ]+\S/ ) {
      $self->_hfind({ getkeys => 1 }, @_);
   }
   elsif ( @_ ) {
      my $key = shift;
      return () unless exists($self->[0][0]{ $key });
      $self->[0][0]{ $key }->keys(@_);
   }
   else {
      $self->[0]->keys();
   }
}

# hvals ( key, field [, field, ... ] )
# hvals ( "query string" )
# hvals ( )

sub hvals {
   my $self = shift;

   if ( @_ == 1 && $_[0] =~ /^(?:key|\S+)[ ]+\S\S?[ ]+\S/ ) {
      $self->_hfind({ getvals => 1 }, @_);
   }
   elsif ( @_ ) {
      my $key = shift;
      return () unless exists($self->[0][0]{ $key });
      $self->[0][0]{ $key }->vals(@_);
   }
   else {
      $self->[0]->vals();
   }
}

# hpairs ( key, field [, field, ... ] )
# hpairs ( "query string" )
# hpairs ( )

sub hpairs {
   my $self = shift;

   if ( @_ == 1 && $_[0] =~ /^(?:key|\S+)[ ]+\S\S?[ ]+\S/ ) {
      $self->_hfind({}, @_);
   }
   elsif ( @_ ) {
      my $key = shift;
      return () unless exists($self->[0][0]{ $key });
      $self->[0][0]{ $key }->pairs(@_);
   }
   else {
      $self->[0]->pairs();
   }
}

# hshift ( )

sub hshift {
   $_[0]->[0]->shift();
}

# hsort ( "BY key   [ ASC | DESC ] [ ALPHA ]" )
# hsort ( "BY field [ ASC | DESC ] [ ALPHA ]" )

sub hsort {
   my ( $self, $request ) = @_;
   return () unless ( @_ == 2 );
   _sort($self->[0], 0, $request);
}

# happend ( key, field, string )

sub happend {
   my ( $self, $key ) = ( shift, shift );
   return unless length($key);
   $self->[0]->set($key, _new_hash()) unless exists($self->[0][0]{ $key });
   $self->[0][0]{ $key }->append(@_);
}

# hdecr ( key, field )

sub hdecr {
   my ( $self, $key ) = @_;
   return unless length($key);
   $self->[0]->set($key, _new_hash()) unless exists($self->[0][0]{ $key });
   --$self->[0][0]{ $key }{ $_[2] };
}

# hdecrby ( key, field, number )

sub hdecrby {
   my ( $self, $key ) = @_;
   return unless length($key);
   $self->[0]->set($key, _new_hash()) unless exists($self->[0][0]{ $key });
   $self->[0][0]{ $key }{ $_[2] } -= $_[3] || 0;
}

# hincr ( key, field )

sub hincr {
   my ( $self, $key ) = @_;
   return unless length($key);
   $self->[0]->set($key, _new_hash()) unless exists($self->[0][0]{ $key });
   ++$self->[0][0]{ $key }{ $_[2] };
}

# hincrby ( key, field, number )

sub hincrby {
   my ( $self, $key ) = @_;
   return unless length($key);
   $self->[0]->set($key, _new_hash()) unless exists($self->[0][0]{ $key });
   $self->[0][0]{ $key }{ $_[2] } += $_[3] || 0;
}

# hgetdecr ( key, field )

sub hgetdecr {
   my ( $self, $key ) = @_;
   return unless length($key);
   $self->[0]->set($key, _new_hash()) unless exists($self->[0][0]{ $key });
   $self->[0][0]{ $key }{ $_[2] }-- || 0;
}

# hgetincr ( key, field )

sub hgetincr {
   my ( $self, $key ) = @_;
   return unless length($key);
   $self->[0]->set($key, _new_hash()) unless exists($self->[0][0]{ $key });
   $self->[0][0]{ $key }{ $_[2] }++ || 0;
}

# hgetset ( key, field, value )

sub hgetset {
   my ( $self, $key ) = ( shift, shift );
   return unless length($key);
   $self->[0]->set($key, _new_hash()) unless exists($self->[0][0]{ $key });
   $self->[0][0]{ $key }->getset(@_);
}

# hlen ( key, field )
# hlen ( key )
# hlen ( )

sub hlen {
   my $self = shift;
   if ( @_ ) {
      my $key = shift;
      return 0 unless exists($self->[0][0]{ $key });
      $self->[0][0]{ $key }->len(@_);
   }
   else {
      $self->[0]->len();
   }
}

###############################################################################
## ----------------------------------------------------------------------------
## Hash of Arrays (HoA).
##
###############################################################################

# lset ( key, index, value [, index, value, ... ] )

sub lset {
   my ( $self, $key ) = ( shift, shift );
   return unless length($key);
   if ( @_ ) {
      $self->[1]->set($key, _new_list()) unless exists($self->[1][0]{ $key });
      if ( @_ == 2 ) {
         $self->[1][0]{ $key }[ $_[0] ] = $_[1];
      } else {
         $self->[1][0]{ $key }->mset(@_);
      }
   }
   else {
      return;
   }
}

# lget ( key, index [, index, ... ] )
# lget ( key )

sub lget {
   my ( $self, $key ) = ( shift, shift );
   return unless length($key);
   if ( @_ ) {
      return unless exists($self->[1][0]{ $key });
      if ( @_ == 1 ) {
         $self->[1][0]{ $key }[ $_[0] ];
      } else {
         $self->[1][0]{ $key }->mget(@_);
      }
   }
   else {
      $self->[1][0]{ $key };
   }
}

# ldel ( key, index [, index, ... ] )
# ldel ( key )

sub ldel {
   my ( $self, $key ) = ( shift, shift );
   return unless length($key);
   if ( @_ ) {
      return unless exists($self->[1][0]{ $key });
      if ( @_ == 1 ) {
         delete $self->[1][0]{ $key }[ $_[0] ];
      } else {
         $self->[1][0]{ $key }->mdel(@_);
      }
   }
   else {
      $self->[1]->del($key);
   }
}

# lexists ( key, index [, index, ... ] )
# lexists ( key )

sub lexists {
   my ( $self, $key ) = ( shift, shift );
   return '' unless length($key);
   if ( @_ ) {
      return '' unless exists($self->[1][0]{ $key });
      if ( @_ == 1 ) {
         exists $self->[1][0]{ $key }[ $_[0] ];
      } else {
         $self->[1][0]{ $key }->mexists(@_);
      }
   }
   else {
      exists $self->[1][0]{ $key };
   }
}

# lclear ( key )
# lclear ( )

sub lclear {
   my ( $self, $key ) = @_;
   if ( @_ > 1 ) {
      return unless exists($self->[1][0]{ $key });
      $self->[1][0]{ $key }->clear();
   }
   else {
      $self->[1]->clear();
   }
}

# lrange ( key, start, stop )

sub lrange {
   my ( $self, $key ) = ( shift, shift );
   return () unless length($key) && exists($self->[1][0]{ $key });
   $self->[1][0]{ $key }->range(@_);
}

# lsplice ( key, offset [, length [, list ] ] )

sub lsplice {
   my ( $self, $key ) = ( shift, shift );
   return unless length($key) && scalar(@_);
   $self->[1]->set($key, _new_list()) unless exists($self->[1][0]{ $key });
   $self->[1][0]{ $key }->splice(@_);
}

# lpop ( key )

sub lpop {
   my ( $self, $key ) = ( shift, shift );
   return unless length($key) && exists($self->[1][0]{ $key });
   shift @{ $self->[1][0]{ $key } };
}

# lpush ( key, value [, value, ... ] )

sub lpush {
   my ( $self, $key ) = ( shift, shift );
   return unless length($key) && scalar(@_);
   $self->[1]->set($key, _new_list()) unless exists($self->[1][0]{ $key });
   unshift @{ $self->[1][0]{ $key } }, @_;
}

# rpop ( key )

sub rpop {
   my ( $self, $key ) = ( shift, shift );
   return unless length($key) && exists($self->[1][0]{ $key });
   pop @{ $self->[1][0]{ $key } };
}

# rpush ( key, value [, value, ... ] )

sub rpush {
   my ( $self, $key ) = ( shift, shift );
   return unless length($key) && scalar(@_);
   $self->[1]->set($key, _new_list()) unless exists($self->[1][0]{ $key });
   push @{ $self->[1][0]{ $key } }, @_;
}

# lkeys ( key, index [, index, ... ] )
# lkeys ( "query string" )
# lkeys ( )

sub lkeys {
   my $self = shift;

   if ( @_ == 1 && $_[0] =~ /^(?:key|\S+)[ ]+\S\S?[ ]+\S/ ) {
      $self->_lfind({ getkeys => 1 }, @_);
   }
   elsif ( @_ ) {
      my $key = shift;
      return () unless exists($self->[1][0]{ $key });
      $self->[1][0]{ $key }->keys(@_);
   }
   else {
      $self->[1]->keys();
   }
}

# lvals ( key, index [, index, ... ] )
# lvals ( "query string" )
# lvals ( )

sub lvals {
   my $self = shift;

   if ( @_ == 1 && $_[0] =~ /^(?:key|\S+)[ ]+\S\S?[ ]+\S/ ) {
      $self->_lfind({ getvals => 1 }, @_);
   }
   elsif ( @_ ) {
      my $key = shift;
      return () unless exists($self->[1][0]{ $key });
      $self->[1][0]{ $key }->vals(@_);
   }
   else {
      $self->[1]->vals();
   }
}

# lpairs ( key, index [, index, ... ] )
# lpairs ( "query string" )
# lpairs ( )

sub lpairs {
   my $self = shift;

   if ( @_ == 1 && $_[0] =~ /^(?:key|\S+)[ ]+\S\S?[ ]+\S/ ) {
      $self->_lfind({}, @_);
   }
   elsif ( @_ ) {
      my $key = shift;
      return () unless exists($self->[1][0]{ $key });
      $self->[1][0]{ $key }->pairs(@_);
   }
   else {
      $self->[1]->pairs();
   }
}

# lshift ( )

sub lshift {
   $_[0]->[1]->shift();
}

# lsort ( "BY key   [ ASC | DESC ] [ ALPHA ]" )
# lsort ( "BY index [ ASC | DESC ] [ ALPHA ]" )
#
# lsort ( key, "BY key [ ASC | DESC ] [ ALPHA ]" )
# lsort ( key, "BY val [ ASC | DESC ] [ ALPHA ]" )

sub lsort {
   my ( $self, $arg1, $arg2 ) = @_;
   if ( @_ == 2 ) {
      _sort($self->[1], 1, $arg1);
   }
   else {
      return () unless ( @_ == 3 && exists($self->[1][0]{ $arg1 }) );
      $self->[1][0]{ $arg1 }->sort($arg2);
   }
}

# lappend ( key, index, string )

sub lappend {
   my ( $self, $key ) = ( shift, shift );
   return unless length($key);
   $self->[1]->set($key, _new_list()) unless exists($self->[1][0]{ $key });
   $self->[1][0]{ $key }->append(@_);
}

# ldecr ( key, index )

sub ldecr {
   my ( $self, $key ) = @_;
   return unless length($key);
   $self->[1]->set($key, _new_list()) unless exists($self->[1][0]{ $key });
   --$self->[1][0]{ $key }[ $_[2] ];
}

# ldecrby ( key, index, number )

sub ldecrby {
   my ( $self, $key ) = @_;
   return unless length($key);
   $self->[1]->set($key, _new_list()) unless exists($self->[1][0]{ $key });
   $self->[1][0]{ $key }[ $_[2] ] -= $_[3] || 0;
}

# lincr ( key, index )

sub lincr {
   my ( $self, $key ) = @_;
   return unless length($key);
   $self->[1]->set($key, _new_list()) unless exists($self->[1][0]{ $key });
   ++$self->[1][0]{ $key }[ $_[2] ];
}

# lincrby ( key, index, number )

sub lincrby {
   my ( $self, $key ) = @_;
   return unless length($key);
   $self->[1]->set($key, _new_list()) unless exists($self->[1][0]{ $key });
   $self->[1][0]{ $key }[ $_[2] ] += $_[3] || 0;
}

# lgetdecr ( key, index )

sub lgetdecr {
   my ( $self, $key ) = @_;
   return unless length($key);
   $self->[1]->set($key, _new_list()) unless exists($self->[1][0]{ $key });
   $self->[1][0]{ $key }[ $_[2] ]-- || 0;
}

# lgetincr ( key, index )

sub lgetincr {
   my ( $self, $key ) = @_;
   return unless length($key);
   $self->[1]->set($key, _new_list()) unless exists($self->[1][0]{ $key });
   $self->[1][0]{ $key }[ $_[2] ]++ || 0;
}

# lgetset ( key, index, value )

sub lgetset {
   my ( $self, $key ) = ( shift, shift );
   return unless length($key);
   $self->[1]->set($key, _new_list()) unless exists($self->[1][0]{ $key });
   $self->[1][0]{ $key }->getset(@_);
}

# llen ( key, index )
# llen ( key )
# llen ( )

sub llen {
   my $self = shift;
   if ( @_ ) {
      my $key = shift;
      return 0 unless exists($self->[1][0]{ $key });
      $self->[1][0]{ $key }->len(@_);
   }
   else {
      $self->[1]->len();
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

MCE::Shared::Minidb - A pure-Perl in-memory data store

=head1 VERSION

This document describes MCE::Shared::Minidb version 1.699_011

=head1 SYNOPSIS

   # non-shared
   use MCE::Shared::Minidb;

   my $db = MCE::Shared::Minidb->new();

   # shared
   use MCE::Shared;

   my $db = MCE::Shared->minidb();

   # HoH
   $db->hset('key1', 'f1', 'foo');
   $db->hset('key2', 'f1', 'bar', 'f2', 'baz');

   $val = $db->hget('key2', 'f2');  # 'baz'

   # HoA
   $db->lset('key1', 0, 'foo');
   $db->lset('key2', 0, 'bar', 1, 'baz');

   $val = $db->lget('key2', 1);     # 'baz'

=head1 DESCRIPTION

A tiny in-memory NoSQL-like database for use with L<MCE::Shared>. Although
several methods resemble the C<Redis> API, it is not the intent for this
module to become 100% compatible with it.

This module was created mainly for having an efficient manner in which to
manipulate hashes-of-hashes (HoH) and hashes-of-arrays (HoA) structures with
MCE::Shared. Both are supported simulatenously due to being unique objects
inside the C<$db> object.

   sub new {
      # Parallel Hashes: [ HoH, HoA ]
      bless [
         MCE::Shared::Ordhash->new(),  # Hash of Hashes (HoH)
         MCE::Shared::Ordhash->new(),  # Hash of Arrays (HoA)
      ], shift;
   }

   # (H)oH key => MCE::Shared::Hash->new();
   # (H)oA key => MCE::Shared::Array->new()

=head1 QUERY STRING

Several methods in C<MCE::Shared::Minidb> receive a query string argument.
The string is quoteless. Basically, any quotes inside the string will be
treated literally.

   Search capability: =~ !~ eq ne lt le gt ge == != < <= > >=
  
   "key =~ /pattern/i :AND field =~ /pattern/i"
   "key =~ /pattern/i :AND index =~ /pattern/i"
   "key =~ /pattern/i :AND field eq foo bar"     # address eq foo bar
   "index eq foo baz :OR key !~ /pattern/i"      # 9 eq foo baz

      key   means to match against keys in the hash (H)oH or (H)oA
      field means to match against HoH->{key}->{field}; e.g. address
      index means to match against HoA->{key}->[index]; e.g. 9

   Keys in hash may have spaces, but not in field names Ho(H).
   :AND(s) and :OR(s) mixed together is not supported.

The C<select_aref> and C<select_href> methods receive a select string
allowing one to specify field names and sort directives.

   "f1 f2 f3 :WHERE f4 > 20 :AND key =~ /foo/ :ORDER BY f5 DESC ALPHA"
   "f1 f2 f3 :where f4 > 20 :and key =~ /foo/ :order by f5 desc alpha"

   "f5 f1 f2 :WHERE fN > 40 :AND key =~ /bar/ :ORDER BY key ALPHA"
   "f5 f1 f2 :where fN > 40 :and key =~ /bar/ :order by key alpha"

   "f5 f1 f2 :WHERE fN > 40 :AND key =~ /bar/"
   "f5 f1 f2 :where fN > 40 :and key =~ /bar/"

   "f5 f1 f2"

The shorter form without field names is allowed for HoA.

   "4 > 20 :and key =~ /baz/"  4 is the array index
  
=head1 API DOCUMENTATION - DB

To be completed before the final 1.700 release.

=over 3

=item new

Constructs an empty in-memory C<HoH> and C<HoA> key-store database structure.

   # non-shared
   use MCE::Shared::Minidb;

   $db = MCE::Shared::Minidb->new();

   # shared
   use MCE::Shared;

   $db = MCE::Shared->minidb();

=item dump ( "file.dat" )

Dumps the in-memory content to a file.

=item restore ( "file.dat" )

Restores the in-memory content from a file.

=item iterator ( ":hashes", "query string" )

=item iterator ( ":hashes" )

Returns a code reference that returns a single key => href pair.

=item iterator ( ":hashes", key, "query string" )

=item iterator ( ":hashes", key [, key, ... ] )

Returns a code reference that returns a single key => value pair.

=item iterator ( ":lists", "query string" )

=item iterator ( ":lists" )

Returns a code reference that returns a single key => aref pair.

=item iterator ( ":lists", key, "query string" )

=item iterator ( ":lists", key [, key, ... ] )

Returns a code reference that returns a single key => value pair.

=item select_aref ( ":hashes", "select string" )

=item select_aref ( ":lists", "select string" )

Returns [ key, aref ] pairs.

=item select_href ( ":hashes", "select string" )

=item select_href ( ":lists", "select string" )

Returns [ key, href ] pairs.

=back

=head1 API DOCUMENTATION - HASHES ( HoH )

=over 3

=item hset ( key, field, value [, field, value, ... ] )

Sets the value of a hash field and returns its new value. Multiple field_value
pairs may be set at once. In that case, the number of fields stored at key is
returned.

   $val = $db->hset( "some key", "field", "value" );
   $len = $db->hset( "some key", "f1" => "val1", "f2" => "val2" );

=item hget ( key, field [, field, ... ] )

Gets the values of all given hash fields. The C<undef> value is retuned for
fields which do not exists in the hash stored at key. Likewise, the C<undef>
value is returned if the key does not exists in the first level hash (H)oH.

   $val = $db->hget( "some key", "field" );

   ( $val1, $val2 ) = $db->hget( "some key", "field1", "field2" );

=item hget ( key )

Gets the C<MCE::Shared::Hash> object for the hash stored at key or C<undef> if
the key does not exists in the first level hash (H)oH.

   $ha_obj = $db->hget( "some key" );

=item hdel ( key, field [, field, ... ] )

Deletes one or more hash fields. It returns the value associated with the field
if a single field is given. Otherwise, it returns the number of fields actually
removed from the hash stored at key. A field which does not exist in the hash
is not counted.

   $val = $db->hdel( "some key", "some field" );
   $cnt = $db->hdel( "some key", "field1", "field2" );

=item hdel ( key )

Deletes and returns the C<MCE::Shared::Hash> object stored at key or C<undef>
if the key does not exists in the first level hash (H)oH.

   $ha_obj = $db->hdel( "some key" );

=item hexists ( key, field [, field, ... ] )

Determines if a hash field exists. For multiple fields, a truth value is
returned only if all given fields exist in the hash stored at key.

   if ( $db->hexists( "some key", "some field" ) ) { ... }
   if ( $db->hexists( "some key", "f1", "f5" ) ) { ... }

=item hexists ( key )

Determines if a key exists in the first level hash (H)oH.

   if ( $db->hexists( "some key" ) ) { ... }

=item hclear ( key )

Removes all field-value pairs from the hash stored at key.

   $db->hclear( "some key" );

=item hclear

Removes all key-value pairs from the first level hash (H)oH.

   $db->hclear();

=item hkeys ( key, field [, field, ... ] )

=item hkeys ( "query string" )

=item hkeys

=item hvals ( key, field [, field, ... ] )

=item hvals ( "query string" )

=item hvals

=item hpairs ( key, field [, field, ... ] )

=item hpairs ( "query string" )

=item hpairs

=item hshift

Removes and returns the first key-value pair or value in scalar context from
the first-level hash (H)oH. If the C<HASH> is empty, returns the undefined
value.

   ( $key, $href ) = $db->hshift;

   $href = $db->hshift;

=item hsort ( "BY key [ ASC | DESC ] [ ALPHA ]" )

=item hsort ( "BY field [ ASC | DESC ] [ ALPHA ]" )

=item happend ( key, field, string )

Appends a value to key-field and returns its new length.

   $len = $db->happend( $key, $field, "foo" );

=item hdecr ( key, field )

Decrements the value of key-field by one and returns its new value.

   $num = $db->hdecr( $key, $field );

=item hdecrby ( key, field, number )

Decrements the value of key-field by the given number and returns its new value.

   $num = $db->hdecrby( $key, $field, 2 );

=item hincr ( key, field )

Increments the value of key-field by one and returns its new value.

   $num = $db->hincr( $key, $field );

=item hincrby ( key, field, number )

Increments the value of key-field by the given number and returns its new value.

   $num = $db->hincrby( $key, $field, 2 );

=item hgetdecr ( key, field )

Decrements the value of key-field by one and returns its old value.

   $old = $db->hgetdecr( $key, $field );

=item hgetincr ( key, field )

Increments the value of key-field by one and returns its old value.

   $old = $db->hgetincr( $key, $field );

=item hgetset ( key, field, value )

Sets the value of key-field and returns its old value.

   $old = $db->hgetset( $key, $field, "baz" );

=item hlen ( key, field )

Returns the length for the value stored at key-field.

   $len = $db->hlen( $key, $field );

=item hlen ( key )

Returns the number of fields stored at key.

   $len = $db->hlen( $key );

=item hlen

Returns the number of keys stored at the first-level hash (H)oH.

   $len = $db->hlen;

=back

=head1 API DOCUMENTATION - LISTS ( HoA )

=over 3

=item lset ( key, index, value [, index, value, ... ] )

Sets the value of an element in a list by its index and returns its new value.
Multiple index_value pairs may be set all at once. In that case, the length of
the list is returned.

   $val = $db->lset( "some key", 2, "value" );
   $len = $db->lset( "some key", 0 => "val1", 1 => "val2" );

=item lget ( key, index [, index, ... ] )

Gets the values of all given list indices. The C<undef> value is retuned for
indices which do not exists in the list stored at key. Likewise, the C<undef>
value is returned if the key does not exists in the first level hash (H)oA.

   $val = $db->lget( "some key", 20 );

   ( $val1, $val2 ) = $db->lget( "some key", 0, 1 );

=item lget ( key )

Gets the C<MCE::Shared::Array> object for the list stored at key or C<undef> if
the key does not exists in the first level hash (H)oA.

   $ar_obj = $db->lget( "some key" );

=item ldel ( key, index [, index, ... ] )

Deletes one or more elements by their indices. It returns the value associated
with the index if a single index is given. Otherwise, it returns the number of
elements actually removed from the list stored at key. An index which does not
exists in the list is not counted.

   $val = $db->ldel( "some key", 20 );
   $cnt = $db->ldel( "some key", 0, 1 );

=item ldel ( key )

Deletes and returns the C<MCE::Shared::Array> object stored at key or C<undef>
if the key does not exists in the first level hash (H)oA.

   $ar_obj = $db->ldel( "some key" );

=item lexists ( key, index [, index, ... ] )

Determines if elements by their indices exist in the list. For multiple indices,
a truth value is returned only if all given indices exist in the list stored at
key. The behavior is strongly tied to the use of delete on lists.

   $db->lset( "some key", 0, "value0" );
   $db->lset( "some key", 1, "value1" );
   $db->lset( "some key", 2, "value2" );
   $db->lset( "some key", 3, "value3" );

   $db->lexists( "some key", 2 );     # True
   $db->lexists( "some key", 2, 3 );  # True
   $db->ldel   ( "some key", 2 );     # value2

   $db->lexists( "some key", 2 );     # False
   $db->lexists( "some key", 2, 3 );  # False
   $db->lexists( "some key", 3 );     # True

=item lexists ( key )

Determines if a key exists in the first level hash (H)oA.

   if ( $db->lexists( "some key" ) ) { ... }

=item lclear ( key )

Removes all elements from the list stored at key.

   $db->lclear( "some key" );

=item lclear

Removes all key-value pairs from the first level hash (H)oA.

   $db->lclear();

=item lrange ( key, start, stop )

Returns the specified elements of the list stored at key. The offsets C<start>
and C<stop> can also be negative numbers indicating offsets starting at the
end of the list.

An empty list is returned if C<start> is larger than the end of the list.
C<stop> is set to the last index of the list if larger than the actual end
of the list.

   @list = $db->lrange( "some key", 20, 29 );
   @list = $db->lrange( "some key", -4, -1 );

=item lsplice ( key, offset [, length [, list ] ] )

Removes the elements designated by C<offset> and C<length> from the array
stored at key, and replaces them with the elements of C<list>, if any.
The behavior is similar to the Perl C<splice> function.

   @items = $db->lsplice( "some key", 20, 2, @list );
   @items = $db->lsplice( "some key", 20, 2 );
   @items = $db->lsplice( "some key", 20 );

=item lpop ( key )

Removes and returns the first value of the list stored at key. If there are
no elements in the list, returns the undefined value.

   $val = $db->lpop( $key );

=item lpush ( key, value [, value, ... ] )

Prepends one or multiple values to the head of the list stored at key and
returns the new length.

   $len = $db->lpush( "some key", "val1", "val2" );

=item rpop ( key )

Removes and returns the last value of the list stored at key. If there are
no elements in the list, returns the undefined value.

   $val = $db->rpop( $key );

=item rpush ( key, value [, value, ... ] )

Appends one or multiple values to the tail of the list stored at key and
returns the new length.

   $len = $db->rpush( "some key", "val1", "val2" );

=item lkeys ( key, index [, index, ... ] )

=item lkeys ( "query string" )

=item lkeys

=item lvals ( key, index [, index, ... ] )

=item lvals ( "query string" )

=item lvals

=item lpairs ( key, index [, index, ... ] )

=item lpairs ( "query string" )

=item lpairs

=item lshift

Removes and returns the first key-value pair or value in scalar context from
the first-level hash (H)oA. If the C<HASH> is empty, returns the undefined
value. See C<lpop> to shift the first value of the list stored at key.

   ( $key, $aref ) = $db->lshift;

   $aref = $db->lshift;

=item lsort ( "BY key [ ASC | DESC ] [ ALPHA ]" )

=item lsort ( "BY index [ ASC | DESC ] [ ALPHA ]" )

=item lsort ( key, "BY key [ ASC | DESC ] [ ALPHA ]" )

=item lsort ( key, "BY val [ ASC | DESC ] [ ALPHA ]" )

=item lappend ( key, index, string )

Appends a value to key-index and returns its new length.

   $len = $db->lappend( $key, 0, "foo" );

=item ldecr ( key, index )

Decrements the value of key-index by one and returns its new value.

   $num = $db->ldecr( $key, 0 );

=item ldecrby ( key, index, number )

Decrements the value of key-index by the given number and returns its new value.

   $num = $db->ldecrby( $key, 0, 2 );

=item lincr ( key, index )

Increments the value of key-index by one and returns its new value.

   $num = $db->lincr( $key, 0 );

=item lincrby ( key, index, number )

Increments the value of key-index by the given number and returns its new value.

   $num = $db->lincrby( $key, 0, 2 );

=item lgetdecr ( key, index )

Decrements the value of key-index by one and returns its old value.

   $old = $db->lgetdecr( $key, 0 );

=item lgetincr ( key, index )

Increments the value of key-index by one and returns its old value.

   $old = $db->lgetincr( $key, 0 );

=item lgetset ( key, index, value )

Sets the value of key-index and return its old value.

   $old = $db->lgetset( $key, 0, 'baz' );

=item llen ( key, index )

Returns the length for the value stored at key-index.

   $len = $db->llen( $key, $index );

=item llen ( key )

Returns the the size of the list stored at key.

   $len = $db->llen( $key );

=item llen

Returns the number of keys stored at the first-level hash (H)oA.

   $len = $db->llen;

=back

=head1 CREDITS

The implementation is inspired by various Redis Hash/List primitives at
L<http://redis.io/commands>.

=head1 INDEX

L<MCE|MCE>, L<MCE::Core>, L<MCE::Shared>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

