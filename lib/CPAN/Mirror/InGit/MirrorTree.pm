package CPAN::Mirror::InGit::MirrorTree;
# VERSION
# ABSTRACT: An object managing a CPAN Mirror file structure in a Git Tree

=head1 DESCRIPTION

This object represents a tree of files in the structure of a CPAN mirror.  It may be an actual
(partial) mirror of an upstream CPAN mirror, or it may be a local DarkPAN with only the modules
that have been intentionally added to it.  Attribute L</upstream_url> determines this.  Setting
C<upstream_utl> inddicates an intention that any file needed from upstream can be automatically
pulled and added to the local mirror.  Without that attribute, the file tree should only include
distributions that have intentionally been added.

=cut

use Carp;
use Scalar::Util 'refaddr', 'blessed';
use POSIX 'strftime';
use IO::Uncompress::Gunzip qw( gunzip $GunzipError );
use Time::Piece;
use Moo;
use v5.36;

extends 'CPAN::Mirror::InGit::MutableTree';

=attribute upstream_url

If this is truly a mirror of a remote CPAN, this is the base URL.  Some MirrorTree objects will
be locally managed, and not have an upstream.

=attribute package_details_date

Returns Time::Piece of date from the modules/02package_details.txt file.

=attribute module_info

A hashref of C<< { $module_name => [ $version, $dist_name ] } >>. This can be built from
L</parse_package_details>.

=cut

has upstream_url           => ( is => 'rw', coerce => \&_add_trailing_slash );
has package_details_date   => ( is => 'rw' );
has module_info            => ( is => 'rw', lazy => 1 );
sub _build_module_info {
   my ($attrs, $by_mod)= shift->parse_package_details;
   return $by_mod;
}

sub _add_trailing_slash { $_[0] =~ m,/\z,? $_[0] : $_[0].'/' }

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

=method package_details_blob

Returns the Blob of the C<modules/02packages.details.txt> file, or C<undef> if it doesn't exist.

=cut

sub package_details_blob($self) {
   my $ent= $self->get_path('modules/02packages.details.txt')
      or return undef;
   return $ent->[0]->is_blob? $ent->[0] : undef;
}

sub fetch_upstream_package_details($self) {
   croak "No upstream URL for this tree"
      unless defined $self->upstream_url;
   my $url= $self->upstream_url . 'modules/02packages.details.txt.gz';
   my $tx= $self->parent->useragent->get($url);
   if ($tx->result->is_success) {
      # Unzip the file and store uncompressed, so that 'git diff' works nicely on it.
      my $txt;
      gunzip \$tx->result->body => \$txt
         or croak "gunzip failed: $GunzipError";
      $self->set_path('modules/02packages.details.txt', \$txt);
   }
   else {
      croak "Failed to find file upstream: ".$tx->result->extract_start_line;
   }
}

=method parse_package_details

Parse C<< modules/02packages.details.txt.gz >> into attributes L</package_details_date> and
L</module_info>.

=cut

sub parse_package_details($self) {
   my $blob= $self->package_details_blob;
   if (!$blob && $self->upstream_url) {
      # Download from upstream
      $self->fetch_upstream_package_details;
      $blob= $self->package_details_blob
         or croak "BUG: still can't find package.details blob after downloading it";
   }
   my $content= $blob->content;
   my %by_mod;
   my %attrs;
   while ($content =~ /\G([^:\n]+):\s+(.*)\n/gc) {
      $attrs{$1}= $2;
   }
   $content =~ /\G\n/gc or croak "missing blank line after headers";
   while ($content =~ /\G(\S+)\s+(\S+)\s+(\S+)\n/gc) {
      my $ver= $2 eq 'undef'? undef : $2;
      $by_mod{$1}= [ $ver, $3 ];
   }
   pos $content == length $content
      or croak "Parse error at '".substr($content, pos($content), 10)."'";
   my $timestamp = $attrs{'Last-Updated'}? Time::Piece->strptime($attrs{'Last-Updated'}, "%a, %d %b %Y %H:%M:%S GMT")
                 : undef; # TODO: fall back to date from branch commit
   $self->package_details_date($timestamp);
   $self->module_info(\%by_mod);
   return (\%attrs, \%by_mod);
}

=method save_package_details

Write C<< modules/02packages.details.txt >> from L</module_info> and data in the attributes.

=cut

sub save_package_details($self) {
   my $url= 'cpan_mirror_ingit.local'; # TODO: store the canonical URL for this branch somewhere
   my $line_count= 9 + keys $self->module_info->%*;
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
   for (sort keys $self->module_info->%*) {
      $content .= sprintf("%s %s  %s\n", $_, $_->[1] // 'undef', $_->[1]);
   }
   $self->set_path('modules/02packages.details.txt', \$content);
}

=method fetch_upstream_dist

  $mirror->fetch_upstream_dist($path_name, %options);

Fetch the .tar.gz from upstream and add it to this tree.  This only works when upstream_url is
set; i.e. this Mirror is an actual mirror of an upstream CPAN.

=cut

sub fetch_upstream_dist($self, $author_path, %options) {
   croak "No upstream URL for this tree"
      unless defined $self->upstream_url;
   my $path= "authors/id/$author_path";
   my $url= $self->upstream_url . $path;
   my $tx= $self->parent->useragent->get($url);
   croak "Failed to find file upstream: ".$tx->result->extract_start_line
      unless $tx->result->is_success;
   my $data= $tx->result->body;
   $self->parent->process_distfile(
      tree => $self,
      file_path => $path,
      file_data => \$data,
      (extract => 1)x!!$options{extract},
   );
}

sub fetch_upstream_module_dist($self, $mod_name, %options) {
   my $info= $self->module_info->{$mod_name}
      or croak "Module '$mod_name' not found in package list";
   $self->fetch_upstream_dist($info->[1], %options);
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

sub import_module($self, $module_name, $req_version) {
   my $existing= $self->module_manifest->{$module_name};
   # Is this requirement already satisfied?
   return $existing if $existing && $self->check_version($req_version, $existing->{version});
   # Can it be satisfied by any file we've downloaded?
   if (my $already_have= $self->parent->dist_cache->find_module($module_name, $req_version)) {
      # find the Git object for this and link it into our tree
      ...
   }
   else {
      # Find list of available versions of this module from CPAN
      ...;
      # download that version, and then extract metadata from it
      ...;
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
