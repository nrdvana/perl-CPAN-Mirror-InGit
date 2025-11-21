package CPAN::Mirror::InGit::MirrorTree;
# VERSION
# ABSTRACT: An object managing a CPAN Mirror file structure in a Git Tree

=head1 SYNOPSIS

  my $mirror= CPAN::Mirror::InGit::MirrorTree->new($

=cut

use Carp;
use Moo;
use PerlIO::gzip;
use Scalar::Util 'refaddr', 'blessed';
use Mojo::IOLoop;
use v5.36;

has parent            => ( is => 'ro', weak_ref => 1, required => 1 );
has branch            => ( is => 'ro' );
has tree              => ( is => 'ro', required => 1 );
sub upstream_mirror      { shift->parent->upstream_mirror }
sub repo                 { shift->parent->repo }
has manifest_files    => ( is => 'lazy', clearer => 1, predicate => 1 );
has manifest_packages => ( is => 'lazy', clearer => 1, predicate => 1 );

sub _build_manifest_files($self) {
   my $dirent= $self->tree->entry_bypath('modules/02packages.details.txt.gz')
      or do { carp "modules/02packages.details.txt.gz not found"; return {} };
   $dirent->type == Git::Raw::Object::BLOB()
      or do { croak "modules/02packages.details.txt.gz is not a file"; return {} };
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

sub _build_manifest_packages($self) {
   my %pkg;
   my $files= $self->files;
   for my $fname (keys $files->%*) {
      $pkg{$_}= $fname for keys $files->{$fname}->%*;
   }
   \%pkg
}

sub _build_uncommitted($self) {
   return {};
}

=method import_dist

  $snapshot->import_dist($public_cpan_author_path);
  $snapshot->import_dist($darkpan_path, $tarball_abs_path_or_git_obj);

This either fetches a public cpan module from the specified author path, or installs a given
tarball at an author path exclusive to this DarkPAN.  When using a public path, this may pull
from cache within the Git repo, or download from a public mirror and cache the dist.  It then
indexes the dist, and updates the index for this branch.

=cut

sub import_dist {
   ...
}

=method patch_dist

  $snapshot->patch_dist($darkpan_author_path, @patches);

This applies one or more patch files to a dist, which generates a new dist with a custom
version.  It also records the status of this dist as being a patched version.

=cut

sub patch_dist {
   ...
}

=method get_blob

  $snapshot->get_blob($path);

Return any file in this snapshot by path.  This is simply a traversal of the directory tree
within the git repo.  It returns the Git::Raw::Blob object, or undef if not found or not a blob.

=cut

sub get_blob($self, $path) {
   my $dirent= $self->tree->entry_bypath($path);
   if ($dirent) {
      if ($dirent->type != Git::Raw::Object::BLOB()) {
         warn "'$path' is not a BLOB";
         return undef;
      }
      warn "found blob '".$dirent->id."'";
      return Git::Raw::Blob->lookup($self->repo, $dirent->id);
   } elsif ($path =~ m,^authors/id/(.*), and $self->manifest_files->{$1}) {
      warn "File '$path' should exist; not cached";
      # Check the 'cache' branch for authors/id/*
      my $package_cache= $self->parent->package_cache;
      my $blob;
      $blob= $package_cache->get_blob($path)
         if $package_cache && $package_cache != $self;
      if (!$blob) {
         # Download from upstream
         warn "Download from upstream";
         my $tx= $self->useragent->get($self->upstream_mirror . $path)
            or croak;
         if (!$tx->result->is_success) {
            warn "Failed to find file upstream: ".$tx->result->extract_start_line;
            return undef;
         }
         $blob= Git::Raw::Blob->create($self->repo, $tx->result->body)
            or croak;

         # Add to the package cache branch
         $package_cache->_delayed_commit($path => $blob)
            if $package_cache && $package_cache != $self;
      }
      # If this is a writable branch, save this ref to commit later
      $self->_delayed_commit($path => $blob)
         if $self->branch;
      return $blob;
   } else {
      warn "No found, not supposed to be cached";
      return undef;
   }
}

our %pending_commits;
END {
   my @todo= values %pending_commits;
   _resolve_pending_commit($_->{snapshot}, $_->{timer_id}, 'Mojo::IOLoop')
      for @todo;
}

sub _delayed_commit($self, $path, $blob, $delay=10) {
   $self->branch or croak "Can't commit without a branch";
   warn "Will commit changed path $path to branch ".$self->branch->name;
   my $pending_commit= $pending_commits{refaddr $self} //= {
         cpan_ingit => $self->parent,
         snapshot => $self,
         changes => {},
         packages_added => 0,
      };
   Mojo::IOLoop->remove($pending_commit->{timer_id})
      if defined $pending_commit->{timer_id};
   my @parts= split '/', $path;
   my $basename= pop @parts;
   my $node= $pending_commit->{changes};
   $node= $node->{$_} //= {} for @parts;
   $node->{$basename}= $blob;
   ++$pending_commit->{packages_added};
   push $pending_commit->{distfiles}->@*, $1
      if $path =~ m|author/id/(.*)|;
   my $id;
   $id= $pending_commit->{timer_id}= Mojo::IOLoop->timer($delay => sub($loop) {
      _resolve_pending_commit($self, $id, $loop);
   });
}

sub _resolve_pending_commit($self, $id, $loop) {
   my $pending_commit= $pending_commits{refaddr $self};
   $loop->remove($id);
   # Ignore this callback if it isn't the most recent
   return unless $id eq $pending_commit->{timer_id};
   # remove from global list
   delete $pending_commits{refaddr $self};
   my $tree= _assemble_tree($self->repo, $self->tree, $pending_commit->{changes});
   my $sig= $self->parent->new_signature;
   my $msg= join "\n",
      "Added $pending_commit->{packages_added} dists",
      "",
      map "  * $_", $pending_commit->{distfiles}->@*;
   my $parent= [ $self->branch->peel('commit') ];
   my $commit= Git::Raw::Commit->create($self->repo, $msg, $sig, $sig, $parent, $tree)
      or croak;
   # Update the branch
   $self->branch->target($commit);
   $self->branch->target->id eq $commit->id
      or croak "Branch object didn't update";
   $self->tree($tree);
}
sub _assemble_tree($repo, $tree, $changes) {
   my $treebuilder= Git::Raw::Tree::Builder->new($repo, ($tree? ($tree) : ()));
   for my $name (keys %$changes) {
      my $dirent= $treebuilder->get($name);
      if (ref $changes->{$name} eq 'HASH') {
         my $subdir= $dirent && $dirent->type == Git::Raw::Object::TREE()? Git::Raw::Tree->lookup($repo, $dirent->id) : undef;
         $changes->{$name}= _assemble_tree($repo, $subdir, $changes->{$name});
      }
      $treebuilder->insert($name, $changes->{$name}, $changes->{$name}->is_tree? 0040000 : 0100644);
   }
   return $treebuilder->write;
}

1;
