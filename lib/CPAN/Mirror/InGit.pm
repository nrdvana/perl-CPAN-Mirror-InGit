package CPAN::Mirror::InGit;
use Git::Raw::Repository;
use Scalar::Util 'blessed';
use Carp;
use Moo;
use v5.36;

has repo => ( is => 'ro', required => 1, coerce => \&_open_repo );
has upstream_mirror => ( is => 'ro', required => 1, default => 'https://www.cpan.org/' );
has package_cache_branch_name => ( is => 'ro', default => 'package-cache' );
has snapshots => ( is => 'rw' );

sub signature {
   Git::Raw::Signature->now("CPAN::Mirror::InGit", 'CPAN::Mirror::InGit@localhost');
}

sub _open_repo($thing) {
   return $thing if blessed($thing) && $thing->isa('Git::Raw::Repository');
   return Git::Raw::Repository->open("$thing");
}

sub snapshot($self, $branch_or_tag_or_id) {
   my ($tree, $origin)= $self->lookup_tree($branch_or_tag_or_id);
   if (blessed($branch_or_tag_or_id) && $branch_or_tag_or_id->isa('Git::Raw::Branch') && !$origin) {
      Carp::confess();
   }
   if ($origin && ref $origin eq 'Git::Raw::Branch') {
      return $self->{snapshots}{$origin->name} //= 
         CPAN::Mirror::InGit::Snapshot->new(
            parent => $self,
            branch => $origin,
            tree => $tree,
         );
   } else {
      return CPAN::Mirror::InGit::Snapshot->new(
         parent => $self,
         tree => $tree,
      );
   }
}

sub package_cache($self) {
   my $branch= Git::Raw::Branch->lookup($self->repo, $self->package_cache_branch_name, 1);
   if (!$branch) {
      # Create an empty directory
      my $empty_dir= Git::Raw::Tree::Builder->new($self->repo)->write
         or croak;
      my $signature= $self->signature
         or croak;
      # Wrap it with an initial commit
      my $commit= Git::Raw::Commit->create($self->repo, "Initial empty tree", $signature, $signature,
         [], $empty_dir, 'refs/heads/'.$self->package_cache_branch_name)
         or croak;
      # Create the branch
      #$branch= Git::Raw::Branch->create($self->repo, $self->package_cache_branch_name, $commit)
      #   or croak;
   }
   return $self->snapshot($branch);
}

sub lookup_tree($self, $branch_or_tag_or_id) {
   my ($tree, $origin);
   defined $branch_or_tag_or_id or croak "missing argument";
   if (blessed($branch_or_tag_or_id) && (
         $branch_or_tag_or_id->isa('Git::Raw::Branch')
      || $branch_or_tag_or_id->isa('Git::Raw::Tag')
   )) {
      $origin= $branch_or_tag_or_id;
      $tree= $origin->peel('tree');
   }
   elsif ($origin= eval { Git::Raw::Branch->lookup($self->repo, $branch_or_tag_or_id, 1) }) {
      $tree= $origin->peel('tree');
   } elsif ($origin= eval { Git::Raw::Tag->lookup($self->repo, $branch_or_tag_or_id) }) {
      $tree= $origin->peel('tree');
   } elsif (my $obj= eval { $self->repo->lookup($branch_or_tag_or_id) }) {
      if ($obj->type == Git::Raw::Object::COMMIT()) {
         $origin= Git::Raw::Commit->lookup($self->repo, $obj->id);
         $tree= $origin->tree;
      } elsif ($obj->type == Git::Raw::Object::TREE()) {
         $tree= Git::Raw::Tree->lookup($self->repo, $obj->id);
      } elsif ($obj->type == Git::Raw::Object::TAG()) {
         $origin= Git::Raw::Tag->lookup($self->repo, $obj->id);
         $tree= $origin->target;
      }
   }
   return wantarray? ($tree, $origin) : $tree;
}

package CPAN::Mirror::InGit::Snapshot {
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
   has useragent         => ( is => 'lazy' );

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
   }
   
   sub _build_useragent($self) {
      return Mojo::UserAgent->new;
   }
   
   sub _build_uncommitted($self) {
      return {};
   }
   
   our %pending_commits;
   END {
      my @todo= values %pending_commits;
      _resolve_pending_commit($_->{snapshot}, $_->{timer_id}, 'Mojo::IOLoop')
         for @todo;
   }
   
   sub delayed_commit($self, $path, $blob, $delay=10) {
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
      my $sig= $self->parent->signature;
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
            $package_cache->delayed_commit($path => $blob)
               if $package_cache && $package_cache != $self;
         }
         # If this is a writable branch, save this ref to commit later
         $self->delayed_commit($path => $blob)
            if $self->branch;
         return $blob;
      } else {
         warn "No found, not supposed to be cached";
         return undef;
      }
   }
}

1;
