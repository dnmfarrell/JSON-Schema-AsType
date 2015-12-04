package JSON::Schema::AsType;

use strict;
use warnings;

use Type::Tiny;
use Type::Tiny::Class;
use Scalar::Util qw/ looks_like_number /;
use List::Util qw/ reduce pairmap pairs /;
use List::MoreUtils qw/ any all none uniq zip /;
use Types::Standard qw/InstanceOf HashRef StrictNum Any Str ArrayRef Int Object slurpy Dict Optional slurpy /; 
use Type::Utils;
use LWP::Simple;
use Clone 'clone';

use Moose::Util qw/ apply_all_roles /;

use JSON;

use Moose;

use MooseX::MungeHas 'is_ro';

our %EXTERNAL_SCHEMAS;

has type   => ( is => 'rwp', handles => [ qw/ check validate validate_explain / ], builder => 1, lazy => 1 );

has schema => ( isa => 'HashRef', lazy => 1, default => sub {
        my $self = shift;
        
        die "schema or uri required" unless $self->uri;
        from_json LWP::Simple::get($self->uri);
});

has parent_schema => ();

sub fetch {
    my( $self, $url ) = @_;

    unless ( $url =~ m#^\w+://# ) { # doesn't look like an uri
        $url = $self->schema->{id} . $url;
            # such that the 'id's can cascade
        if ( my $p = $self->parent_schema ) {
            return $p->fetch( $url );
        }
    }

    return $JSON::Schema::AsType::EXTERNAL_SCHEMAS{$url} ||= $self->new( uri => $url );
}

has uri => ();

has references => sub { 
    +{}
};

has specification => (
    is => 'ro',
    default => sub { 'draft4' },
);


sub root_schema {
    my $self = shift;
    eval { $self->parent_schema->root_schema } || $self;
}

sub is_root_schema {
    my $self = shift;
    return not $self->parent_schema;
}

sub sub_schema {
    my( $self, $subschema ) = @_;
    $self->new( schema => $subschema, parent_schema => $self );
}

sub _build_type {
    my $self = shift;
    
    $self->_set_type('');

    my $snippet = substr to_json( $self->schema, { pretty => 1, canonical => 1} ), 0, 20;

    #log_debug { "Building type for $snippet" };

    $self->_process_keyword($_) 
        for sort map { /^_keyword_(.*)/ } $self->meta->get_method_list;

    $self->_set_type(Any) unless $self->type;

    $self->references->{''} = $self->type;
}

sub _process_keyword {
    my( $self, $keyword ) = @_;

    my $value = $self->schema->{$keyword} // return;

    #log_debug{ "processing keyword '$keyword'" };

    my $method = "_keyword_$keyword";

    my $type = $self->$method($value) or return;

    $self->_add_to_type($type);
}


sub resolve_reference {
    my( $self, $ref ) = @_;

    $DB::single = 1;
    #log_debug{ "ref: $ref" };

    $ref = join '/', '#', map { $self->_escape_ref($_) } @$ref
        if ref $ref;
    
    if ( $ref =~ s/^([^#]+)// ) {
        return $self->fetch($1)->resolve_reference($ref);
    }


    return $self->root_schema->resolve_reference($ref) unless $self->is_root_schema;

    return $self if $ref eq '#';
    
    $ref =~ s/^#//;

    return $self->references->{$ref} if $self->references->{$ref};

    my $s = $self->schema;

    for ( map { $self->_unescape_ref($_) } grep { length $_ } split '/', $ref ) {
        $s = ref $s eq 'ARRAY' ? $s->[$_] : $s->{$_} or last;
    }

    my $x;
    if($s) {
        $x = $self->sub_schema($s);
    }

    $self->references->{$ref} = $x;

    $x or die "didn't find reference $ref";
}

sub _unescape_ref {
    my( $self, $ref ) = @_;

    $ref =~ s/~0/~/g;
    $ref =~ s!~1!/!g;
    $ref =~ s!%25!%!g;

    $ref;
}

sub _escape_ref {
    my( $self, $ref ) = @_;

    $ref =~ s/~/~0/g;
    $ref =~ s!/!~1!g;
    $ref =~ s!%!%25!g;

    $ref;
}

sub _add_reference {
    my( $self, $path, $schema ) = @_;

    $path = join '/', '#', map { $self->_escape_ref($_) } @$path
        if ref $path;

    $self->references->{$path} = $schema;
}

sub _add_to_type {
    my( $self, $t ) = @_;

    if( my $already = $self->type ) {
        $t = $already & $t;
    }

    $self->_set_type( $t );
}

sub BUILD {
    my $self = shift;
    apply_all_roles( $self, 'JSON::Schema::AsType::Draft4' );
}

1;
