package CPAN::Mirror::InGit::MirrorTree;
# VERSION
# ABSTRACT: An object managing a CPAN Mirror file structure in a Git Tree

=head1 SYNOPSIS

  my $mirror= CPAN::Mirror::InGit::MirrorTree->new($

=cut

use Carp;
use Moo;
use Scalar::Util 'refaddr', 'blessed';
use POSIX 'strftime';
use v5.36;

sub _json {
   state $json_class= eval { require Cpanel::JSON::XS; 'Cpanel::JSON::XS' }
                   // eval { require JSON::XS; 'JSON::XS' }
                   // do { require JSON::PP; 'JSON::PP' };
   $json_class->new
}

extends 'CPAN::Mirror::InGit::MutableTree';

has dist_meta       => ( is => 'lazy', clearer => 1, predicate => 1 );
has module_manifest => ( is => 'rw' );

sub _build_dist_meta($self) {
   # Walk the tree looking for every author dist .json
   ...
}

=method build_module_manifest

Build attribute L</module_manifest> from the module/version data in each C<$DIST.json> file
from attribute L</dist_meta>.

=cut

sub build_module_manifest {
   ...
}

=method module_manifest_blob

Returns the Blob of the C<modules/02packages.details.txt> file, or C<undef> if it doesn't exist.

=cut

sub module_manifest_blob($self) {
   my $ent= $self->get_path('modules/02packages.details.txt')
      or return undef;
   return $ent->[0]->is_blob? $ent->[0] : undef;
}

=method load_module_manifest

Parse C<< modules/02packages.details.txt.gz >> into attribute L</module_manifest>.

=cut

sub load_module_manifest($self) {
   my $blob= $self->module_manifest_blob
      or croak "Can't read modules/02packages.details.txt";
   my $content= $blob->content;
   my %manifest;
   my %attrs;
   while ($content =~ /\G([^:]+):\s+(.*)\n/gc) {
      $attrs{$1}= $2;
   }
   $content =~ /\G\n/gc or croak "missing blank line after headers";
   while ($content =~ /\G(\S+)\s+(\S+)\s+(\S+)\n/gc) {
      my $ver= $2 eq 'undef'? undef : $2;
      $manifest{$1}= { version => $ver, file => $3 };
   }
   pos $content == length $content
      or croak "Parse error at '".substr($content, pos($content), 10)."'";
   $self->module_manifest(\%manifest);
   \%manifest;
}

=method save_module_manifest

Write C<< modules/02packages.details.txt.gz >> from attribute L</module_manifest>.

=cut

sub save_module_manifest($self) {
   my $url= 'http://www.cpan.org/modules/02packages.details.txt';
   my $line_count= 9 + keys $self->module_manifest->%*;
   my $date= strftime("%a, %d %b %Y %H:%M:%S GMT", gmtime);
   my $content= <<~END;
      File:         02packages.details.txt
      URL:          $url
      Description:  Package names found in directory \$CPAN/authors/id/
      Columns:      package name, version, path
      Intended-For: Automated fetch routines, namespace documentation.
      Written-By:   PAUSE version 1.005
      Line-Count:   $line_count
      Last-Updated: $date
      
      END
   for (sort keys $self->module_files->%*) {
      $content .= sprintf("%s %s  %s\n", $_, $_->{version}, $_->{file});
   }
   $self->set_path('modules/02packages.details.txt', \$content);
}

=method import_dist

  $snapshot->import_dist($public_cpan_author_path);
  $snapshot->import_dist($local_path, $tarball_abs_path_or_git_obj);

This either fetches a public cpan module from the specified author path, or installs a given
tarball at an author path exclusive to this DarkPAN.  When using a public path, this may pull
from cache within the Git repo, or download from a public mirror and cache the dist.  It then
indexes the dist, and updates the index for this branch.

=cut

sub import_dist {
   ...
}

=method patch_dist

  $snapshot->patch_dist($local_path, @patches);

This applies one or more patch files to a dist, which generates a new dist with a custom
version.  It also records the status of this dist as being a patched version.

=cut

sub patch_dist {
   ...
}

1;
