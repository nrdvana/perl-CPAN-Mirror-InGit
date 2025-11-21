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

=method import_modules

  $snapshot->import_dist(\%module_version_spec);
  # {
  #   'Example::Module' => { version => '>=0.011' },
  #   'Some::Module'    => {},   # any version
  # }

This method processes a list of module requirements much like C<cpanm> would.  If the module is
not available in the mirror, it looks in the distribution cache to see if you are already using
a suitable version in another branch, and if so, uses that.  If not, it goes upstream to
cpan.org and fetches the latest version of the module, and runs L<Parse::LocalDistribution> on
that to generate a metadata file.

Once the module has been parsed, it recursively checks the version requirements of the module to
pull in any additional missing dependencies.

All changes will be pulled into this tree, but not committed.

=cut

sub import_modules($self, $reqs) {
   $self->load_module_manifest unless defined $self->module_manifest;
   my @todo= sort keys %$reqs;
   while (@todo) {
      my $mod= shift @todo;
      my $req_version= $reqs->{$mod}{version};
      my $details= $self->import_module($mod, $req_version);
      # Push things into the TODO list if they aren't already in %$reqs or if they have a higher
      # version requirement.
      ...
   }
}

sub import_module($self, $name, $req_version) {
   my $existing= $self->module_manifest->{$mod};
   # Is this requirement already satisfied?
   return $existing if $existing && $self->check_version($req_version, $existing->{version});
   # Can it be satisfied by any file we've downloaded?
   if (my $already_have= $self->parent->dist_cache->find_module($mod, $req_version)) {
      # find the Git object for this and link it into our tree
      ...
   }
   else {
      # Find list of available versions of this module from CPAN
      ...
      # download that version, and then extract metadata from it
      ...
   }
   # Update the module_manifest, and return it
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
