package CPAN::Mirror::InGit::MirrorTree;
# VERSION
# ABSTRACT: An object managing a CPAN Mirror file structure in a Git Tree

=head1 DESCRIPTION

This object represents a tree of files in the structure of a CPAN mirror.  It may be an actual
(partial) mirror of an upstream CPAN mirror, or it may be a local DarkPAN with only the modules
that have been intentionally added to it.  It could also be some mixture of the two, but that
seems like a bad idea, so I recommend sticking to "mirror" or "DarkPAN" patterns.

Attribute L</upstream_url> indicates that there is a remote server and this branch is holding a
cache of files from that server.  It enables the L</fetch_upstream_package_details> and
L</fetch_upstream_dist> methods.  It also means that the C<02package.details.txt> file will
list packages that don't exist locally on the assumption that they can be downloaded as needed.
Meanwhile, the C<02package.details.txt> will frequently be replaced by the upstream copy.

For the trees which are curated collections of perl distributions, the C<02package.details.txt>
lists only the modules/versions that have been added to this collection.  Further, there should
only ever be one dist providing a module per collection.

Distributions in C<authors/id/X/XX/XXXXX> should be identical to the public distributions of the
official CPAN, but they may be paired with a json file (the dist extension replaced with
C<".json"> which is a local cache of information about the archive, but the archive should
remain untouched.  Distributions in C<authors/id/local> are considered locally authored, and
may be modified versions of the public modules.  You may even choose to give them the same
version number as public packages, and have the package.details file reference the local instead
of the original author.

=cut

use Carp;
use Scalar::Util 'refaddr', 'blessed';
use POSIX 'strftime';
use IO::Uncompress::Gunzip qw( gunzip $GunzipError );
use JSON::PP;
use Time::Piece;
use Moo;
use v5.36;

extends 'CPAN::Mirror::InGit::MutableTree';

=attribute upstream_url

If this is truly a mirror of a remote CPAN, this is the base URL.  Some MirrorTree objects will
be locally managed, and not have an upstream.

=attribute source_branches

If this MirrorTree is more like a curated collection than an automatic mirror of an upstream,
specify a list of other branches (an arrayref of branch names) from which it can pull packages.
These will be used by default in L</import_module>, but you can override them when calling that
method.

=attribute package_details_date

Returns L<Time::Piece> of the last-update date from the modules/02package_details.txt file.

=attribute module_info

A hashref of C<< { $module_name => [ $version, $dist_path ] } >>. This can be built from
L</parse_package_details>.

=cut

has upstream_url           => ( is => 'rw', coerce => \&_add_trailing_slash );
has source_branches        => ( is => 'rw' );
has package_details_date   => ( is => 'rw' );
has module_info            => ( is => 'rw', lazy => 1 );
sub _build_module_info {
   my ($attrs, $by_mod)= shift->parse_package_details;
   return $by_mod;
}

sub load_config($self) {
   my $cfg_blob= $self->config_blob
      or die "Missing '/cpan_ingit.json'";
   my $cfg_data= JSON::PP->new->utf8->relaxed->decode($cfg_blob->content);
   $self->upstream_url($cfg_data->{upstream_url});
   $self->source_branches($cfg_data->{source_branches});
}

sub write_config($self) {
   my $cfg_blob= $self->config_blob;
   my $cfg_data= $cfg_blob? JSON::PP->new->utf8->relaxed->decode($cfg_blob->content) : {};
   $cfg_data->{upstream_url}= $self->upstream_url;
   $cfg_data->{source_branches}= $self->source_branches;
   $self->set_path('cpan_ingit.json', \JSON::PP->new->utf8->canonical->pretty->encode($cfg_data));
   $self;
}

sub _add_trailing_slash { !defined $_[0] || $_[0] =~ m,/\z,? $_[0] : $_[0].'/' }

=method build_module_manifest

Build attribute L</module_manifest> from the module/version data in each C<$DIST.json> file
from attribute L</dist_meta>.

=cut

sub build_module_manifest {
   ...
}

=method config_blob

Returns the Blob of the C<cpan_ingit.conf> file, or C<undef> if it doesn't exist.

=method package_details_blob

Returns the Blob of the C<modules/02packages.details.txt> file, or C<undef> if it doesn't exist.

=cut

sub config_blob($self) {
   my $ent= $self->get_path('cpan_ingit.json')
      or return undef;
   return $ent->[0]->is_blob? $ent->[0] : undef;
}

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

=method write_package_details

Write C<< modules/02packages.details.txt >> from L</module_info> and data in the attributes.
This adds it to the pending changes to the tree, but does not commit it.

=cut

sub write_package_details($self) {
   my $url= 'cpan_mirror_ingit.local'; # TODO: store the canonical URL for this branch somewhere
   my $mod_info= $self->module_info // {};
   my $line_count= 9 + keys %$mod_info;
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
   for (sort keys %$mod_info) {
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

This method processes a list of module requirements to pull in matching modules and only as many
dependencies as are required.  It starts by checking whether this branch contains a module that
meets the requirements.  If not, it checks the mirror branches listed in "import_sources".
If this or any "import_source" branch has an "upstream_url", it may pull from remote into that
branch.

The intended workflow is that you have one branch tracking www.cpan.org and pulling in packages
automatically as needed, and then perhaps a branch where you review the modules before importing
them, and maybe a branch where you upload private DarkPAN modules, and then any number of
application branches that import from the reviewed branch of the DarkPAN branch. This way you
separate the process of building an application's module collection from the process of
reviewing public modules.

All changes will be pulled into this MutableTree object, but not committed.  If this is the
working branch, the index also gets updated.

=cut

sub import_modules($self, $reqs) {
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
   my $existing= $self->module_info->{$module_name};
   # Is this requirement already satisfied?
   return $existing if $existing && $self->check_version($req_version, $existing->{version});
   # Walk through the list of import sources looking for a version that works
   for my $src ($self->import_sources->@*) {
      my $branch= $self->mirror($src);
      if (my $from_branch= $branch->module_info->{$module_name}) {
         if ($self->check_version($req_version, $from_branch->{version})) {
            $self->import_dist($from_branch->{distfile});
            return $from_branch;
         }
      }
   }
   # TODO: consider backpan
   croak "No source has a version of $module_name matching $req_version";
}

sub parse_version_requirement($self, $spec) {
   my @requirements;
   for (split ',', $spec) {
      /^\s*(?:(<|<=|>|>=|==|!=)\s*)?(v?[0-9]\.[0-9_\.]*)\s*\z/
         or croak "Invalid version requirement '$spec'";
      my $op= $1 // '>=';
      my $ver= version->parse($2);
      push @requirements, $op, $ver;
   }
   return \@requirements;
}

sub check_version($self, $requirement, $version) {
   $version= version->parse($version)
      unless ref $version eq 'version';
   $requirement= ref $requirement eq 'HASH'? %$requirement
               : $self->parse_version_requirement($requirement)
      unless ref $requirement eq 'ARRAY';
   for (my $i= 0; $i < @$requirement; $i += 2) {
      my ($op, $rq_ver)= @{$requirement}[$i,$i+1];
      return !!0 unless $op eq '>='? $version >= $rq_ver
                      : $op eq '<='? $version <= $rq_ver
                      : $op eq '=='? $version == $rq_ver
                      : $op eq '!='? $version != $rq_ver
                      : $op eq '<'?  $version < $rq_ver
                      : $op eq '>'?  $version > $rq_ver
                      : croak("Unhandled comparison op '$op'");
   }
   return !!1;
}

sub import_dist_from_archive($self, $pan, $author_path) {
   my $dist_path= "authors/id/$author_path";
   my $gitobj= $pan->get_path($dist_path)
      or croak "No such file $dist_path in branch $pan";
   my $existing= $self->get_path($dist_path);
   # If exists, must be same gitobj as before or this is an error
   if ($existing) {
      croak "$dist_path already exists with different content"
         unless $existing->id eq $gitobj->id;
   }
   # also copy the metadata file
   my $meta_path= $pan->get_dist_metadata_path($author_path);
   my $meta_blob= $pan->get_dist_metadata_blob($author_path);
   $self->set_path($dist_path, $gitobj);
   $self->set_path($meta_path, $meta_blob);
   return 1;
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
