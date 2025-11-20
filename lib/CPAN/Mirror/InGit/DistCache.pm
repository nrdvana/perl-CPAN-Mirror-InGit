package CPAN::Mirror::InGit::DistCache;
use Carp;
use Moo;
use Scalar::Util 'refaddr', 'blessed';
use v5.36;

has parent            => ( is => 'ro', required => 1 );
has branch            => ( is => 'ro', required => 1 );
has tree              => ( lazy => 1 );
sub _build_tree          { shift->peel('tree') }
sub upstream_mirror      { shift->parent->upstream_mirror }
sub repo                 { shift->parent->repo }

1;
