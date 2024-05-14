package CPAN::Mirror::InGit;
use Git::Raw::Repository;
use Scalar::Util 'blessed';
use Carp;
use Moo;
use v5.36;

has repo => ( is => 'ro', required => 1, coerce => \&_open_repo );
has upstream_mirror => ( is => 'ro', required => 1, default => 'https://www.cpan.org/' );
has snapshots => ( is => 'rw' );

sub _open_repo($thing) {
   return $thing if blessed($thing) && $thing->isa('Git::Raw::Repository');
   return Git::Raw::Repository->open("$thing");
}

sub snapshot($self, $branch_or_tag_or_id) {
   my $tree= $self->lookup_path($branch_or_tag_or_id);
   return !$tree? undef
      : $self->_snapshot_for_tree($tree, Git::Raw::Branch->lookup($self->repo, $branch_or_tag_or_id, 1));
}

sub lookup_path($self, $branch_or_tag_or_id, $path= undef) {
   my $tree;
   if (my $branch= Git::Raw::Branch->lookup($self->repo, $branch_or_tag_or_id, 1)) {
      $tree= $branch->peel('tree');
   } elsif (my $tag= eval { Git::Raw::Tag->lookup($self->repo, $branch_or_tag_or_id) }) {
      $tree= $tag->peel('tree');
   } elsif (my $obj= eval { $self->repo->lookup($branch_or_tag_or_id) }) {
      $tree= $obj->type == Git::Raw::Object::COMMIT()? Git::Raw::Commit->lookup($self->repo, $branch_or_tag_or_id)->tree
         : $obj->type == Git::Raw::Object::TREE()? Git::Raw::Tree->lookup($self->repo, $branch_or_tag_or_id)
         : $obj->type == Git::Raw::Object::TAG()? Git::Raw::Tag->lookup($self->repo, $branch_or_tag_or_id)->target
         : undef;
   }
   return undef unless defined $tree;
   return $tree unless defined $path && length $path;
   my $dirent= $tree->entry_bypath($path);
   return !$dirent? undef
      : $dirent->type == Git::Raw::Object::TREE()? Git::Raw::Tree->lookup($self->repo, $dirent->id)
      : $dirent->type == Git::Raw::Object::BLOB()? Git::Raw::Blob->lookup($self->repo, $dirent->id)
      : undef;
}

sub _snapshot_for_tree($self, $tree, $branch) {
   $self->{snapshots}{$tree->id} //=
      CPAN::Mirror::InGit::Snapshot->new(
         parent => $self,
         branch => $branch,
         tree => $tree,
      );
}

sub commit($self, $snapshot) {
   ...
}

package CPAN::Mirror::InGit::Snapshot {
   use Carp;
   use Moo;
   use PerlIO::gzip;
   use Mojo::IOLoop;
   use v5.36;

   has parent => ( is => 'ro', weak_ref => 1, required => 1 );
   has branch => ( is => 'ro' );
   sub upstream_mirror($self) { $self->parent->upstream_mirror }
   sub repo($self) { $self->parent->repo }
   has tree => ( is => 'ro', required => 1 );
   has files => ( is => 'lazy' );
   has packages => ( is => 'lazy' );
   has useragent => ( is => 'lazy' );
   has uncommitted => ( is => 'lazy', predicate => 1 );

   sub _build_files($self) {
      my $dirent= $self->tree->entry_bypath('modules/02packages.details.txt.gz')
         or croak "modules/02packages.details.txt.gz not found";
      $dirent->type == Git::Raw::Object::BLOB()
         or croak "modules/02packages.details.txt.gz is not a file";
      my $blob= Git::Raw::Blob->lookup($self->repo, $dirent->id);
      my %files;
      my $content= $blob->content;
      open my $fh, '<:gzip', \$content or die "open(<gzip): $!";
      my %meta;
      local $_;
      while (defined($_= <$fh>) && /^([^:]+):\s+(.*)$/) {
         $meta{$1}= $2;
      }
      while (<$fh>) {
         my ($pkg, $ver, $file)= split /\s+/;
         $files{$file}{$pkg}= $ver if defined $file && defined $pkg;
      }
      $fh->close;
      undef $content;
      \%files;
   }
   
   sub _build_uncommitted($self) {
      return {};
   }
   
   sub _build_packages($self) {
      my %pkg;
      my $files= $self->files;
      for my $fname (keys $files->%*) {
         $pkg{$_}= $fname for keys $files->{$fname}->%*;
      }
   }
   
   sub _build_useragent($self) {
      return Mojo::UserAgent->new;
   }
   
   sub open_file($self, $path) {
      my $dirent= $self->tree->entry_bypath($path);
      if ($dirent) {
         if ($dirent->type != Git::Raw::Object::BLOB()) {
            warn "'$path' is not a BLOB";
            return undef;
         }
         warn "found blob '".$dirent->id."'";
         my $blob= Git::Raw::Blob->lookup($self->repo, $dirent->id);
         my $content= $blob->content;
         return $content;
         #open my $fh, '<:raw', \$content or die "open(BLOB): $!";
         #return $fh;
      } elsif ($path =~ m,^authors/id/(.*), and $self->files->{$1}) {
         warn "File '$path' should exist; not cached";
         # Check the 'cache' branch for authors/id/*
         my $content;
         warn "Check master cache";
         my $obj= $self->parent->lookup_path('cache', $path);
         if ($obj && $obj->is_blob) {
            warn "Found in master cache";
            $content= $obj->content;
         } else {
            # Download from upstream
            warn "Download from upstream";
            my $tx= $self->useragent->get($self->upstream_mirror . $path);
            $content= $tx->result->body;
         }
         # save into repo
         warn "Save into index";
         $self->uncommitted->{$path}= $content;
         # TODO: save into 'cache' repo if authors/id/
         
         return $content;
      } else {
         warn "No found, not supposed to be cached";
         return undef;
      }
   }
}

1;
