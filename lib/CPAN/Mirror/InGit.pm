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
   my $tree;
   if (my $branch= Git::Raw::Branch->lookup($self->repo, $branch_or_tag_or_id, 1)) {
      $tree= $branch->peel('tree');
   } elsif (my $tag= Git::Raw::Tag->lookup($self->repo, $branch_or_tag_or_id)) {
      $tree= $tag->peel('tree');
   } elsif (my $obj= $self->repo->lookup($branch_or_tag_or_id)) {
      $tree= $obj->type == Git::Raw::Object::COMMIT()? Git::Raw::Commit->lookup($self->repo, $branch_or_tag_or_id)->tree
         : $obj->type == Git::Raw::Object::TREE()? Git::Raw::Tree->lookup($self->repo, $branch_or_tag_or_id)
         : undef;
   }
   return $tree? $self->_snapshot_for_tree($tree) : undef;
}

sub _snapshot_for_tree($self, $tree) {
   $self->{snapshots}{$tree->id} //=
      CPAN::Mirror::InGit::Snapshot->new(
         repo => $self->repo,
         upstream_mirror => $self->upstream_mirror,
         tree => $tree
      );
}

package CPAN::Mirror::InGit::Snapshot {
   use Carp;
   use Moo;
   use PerlIO::gzip;
   use Mojo::IOLoop;
   use v5.36;

   has repo => ( is => 'ro', required => 1 );
   has upstream_mirror => ( is => 'ro', required => 1 );
   has tree => ( is => 'ro', required => 1 );
   has files => ( is => 'lazy' );
   has packages => ( is => 'lazy' );
   has useragent => ( is => 'lazy' );
   
   
   sub _build_files($self) {
      my $dirent= $self->tree->entry_bypath('modules/02packages.details.txt.gz')
         or croak "modules/02packages.details.txt.gz not found";
      $dirent->type == Git::Raw::Object::BLOB()
         or croak "modules/02packages.details.txt.gz is not a file";
      my $blob= Git::Raw::Blob->lookup($self->repo, $dirent->id);
      my %files;
      my $content= $blob->content;
      open my $fh, '<:gzip', \$content or die "open(<gzip): $!";
      while (<$fh>) {
         my ($pkg, $ver, $file)= split /\s+/;
         $files{$file}{$pkg}= $ver;
      }
      $fh->close;
      undef $content;
      \%files;
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
         my $blob= Git::Raw::Blob->lookup($self->repo, $dirent->id);
         my $content= $blob->content;
         return $content;
         #open my $fh, '<:raw', \$content or die "open(BLOB): $!";
         #return $fh;
      } elsif ($self->files->{$path}) {
         # Download from actual CPAN
         my $tx= $self->useragent->get($self->upstream_mirror . $path);
         my $content= $tx->result->body;
         return $content;
         # save into repo (TODO)
         #return open my $fh, '<:raw', \$content or die "open(BLOB): $!";
         #return $fh;
      } else {
         return undef;
      }
   }
}

1;
