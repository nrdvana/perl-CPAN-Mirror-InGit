package CPAN::Mirror::InGit::ArchiveTree;
# VERSION
# ABSTRACT: An object managing a CPAN file structure in a Git Tree

=head1 DESCRIPTION

This object represents a tree of files matching the layout of CPAN.  It may be an actual mirror
of an upstream CPAN/DarkPAN, or it may be a local curated collection of modules intended to
provide pinned versions for an application.  Mirrors (meaning *every* package from upstream is
listed in the index and fetched on demand) are represented by the subclass
L<MirrorTree|CPAN::Mirror::InGit::MirrorTree> which implements the fetching of files from
upstream.  This class only contains methods to import distributions from other Git branches.

Distributions in C<authors/id/X/XX/XXXXX> should be kept identical to the public CPAN copy.
Local changes/patches to those files should be given a new distribution name under
C<authors/id/local>.  The "provides" list (of modules) of a public CPAN distribution will be kept
the same as reported by public CPAN (for security, so that a dist without permission to index a
module still can't claim that name) but the "provides" list of a local distribution will always
take precedence in the indexing.

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

=attribute config

A hashref of configuration stored in the tree, and lazily-loaded.

=method config_blob

Returns the Blob of the C<cpan_ingit.conf> file, or C<undef> if it doesn't exist.

=method load_config

  %attrs= $archive_tree->load_config();

Load the configuration of this ArchiveTree from the config file within the git tree.
(path C<< /cpan_ingit.json >>)

=method write_config

  $archive_tree->write_config($config);

Create a new /cpan_ingit.json from the L</config> attribute of this ArchiveTree.  By default
This stages the change (see L<CPAN::Mirror::InGit::MutableTree>) but does not commit it.

=cut

has config => ( is => 'rw', lazy => 1, builder => 'load_config' );

sub config_blob($self) {
   my $ent= $self->get_path('cpan_ingit.json')
      or return undef;
   return $ent->[0]->is_blob? $ent->[0] : undef;
}

sub load_config($self) {
   my $cfg_blob= $self->config_blob
      or die "Missing '/cpan_ingit.json'";
   my $attrs= JSON::PP->new->utf8->relaxed->decode($cfg_blob->content);
   ref $attrs eq 'HASH' or croak "Configuration file does not contain an object?";
   return $self->{config}= $attrs;
}

sub write_config($self) {
   my $json= JSON::PP->new->utf8->canonical->pretty->encode($self->config);
   $self->set_path('cpan_ingit.json', \$json)
      unless $self->config_blob->content eq $json;
   $self;
}

=attribute package_details

The parsed contents of C<modules/02package_details.txt>:

  {
    last_update => # Time::Piece of last-update
    by_module   => { $module_name => [ $mod, $ver, $path ] },
    by_dist     => { $author_path => [ [ $mod, $ver, $path ], ... ] },
  }

The C<by_module> and C<by_dist> hashres refer to the same row arrayrefs.

=method package_details_blob

Returns the Blob of the C<modules/02packages.details.txt> file, or C<undef> if it doesn't exist.

=cut

sub package_details_blob($self) {
   my $ent= $self->get_path('modules/02packages.details.txt')
      or return undef;
   return $ent->[0]->is_blob? $ent->[0] : undef;
}

has package_details => ( is => 'rw', lazy => 1 );
sub _build_package_details($self) {
   $self->parse_package_details($self->package_details_blob->content);
}

=method parse_package_details

Parse C<< modules/02packages.details.txt.gz >> into a structure matching the description in
attribute L</package_details>.

=cut

sub parse_package_details($self, $content) {
   my %attrs;
   while ($content =~ /\G([^:\n]+):\s+(.*)\n/gc) {
      $attrs{$1}= $2;
   }
   $content =~ /\G\n/gc or croak "missing blank line after headers";
   my %by_mod;
   my %by_dist;
   while ($content =~ /\G(\S+)\s+(\S+)\s+(\S+)\n/gc) {
      my $row= [ $1, ($2 eq 'undef'? undef : $2), $3 ];
      $by_mod{$1}= $row;
      push @{$by_dist{$3}}, $row;
   }
   pos $content == length $content
      or croak "Parse error at '".substr($content, pos($content), 10)."'";
   my $timestamp = $attrs{'Last-Updated'}? Time::Piece->strptime($attrs{'Last-Updated'}, "%a, %d %b %Y %H:%M:%S GMT")
                 : undef; # TODO: fall back to date from branch commit
   return {
      last_update => $timestamp,
      by_module   => \%by_mod,
      by_dist     => \%by_dist,
   };
}

=method write_package_details

Write C<< modules/02packages.details.txt >> from the current value of attribute L</package_details>.
This adds it to the pending changes to the tree, but does not commit it.

=cut

sub write_package_details($self) {
   my $url= $self->config->{canonical_url} // 'cpan_mirror_ingit.local';
   my @mod_list= values %{$self->package_details->{by_module}};
   my $line_count= 9 + @mod_list;
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
   # List can be huge, so try to be efficient about stringifying it
   @mod_list= sort { $a->[0] cmp $b->[0] } @mod_list;
   my @lines;
   for (@mod_list) {
      push @lines, sprintf("%s %s  %s\n", $_->[0], $_->[1] // 'undef', $_->[2]);
   }
   $self->set_path('modules/02packages.details.txt', \join('', $content, @lines));
}

sub meta_path_for_dist($self, $author_path) {
   # replace archive extension with '.meta.json'
   $author_path =~ s/\.(zip|tar\.gz|tgz|tar\.bz2|tbz2)\z//;
   return "authors/id/$author_path.meta";
}

=method import_dist

  $archive_tree->import_dist($peer_tree, $author_path, %options);

Fetch an C<$author_path> from another tree, and update the module index to assign ownership of
the same modules as this dist had in the other tree.  The tree is written, but not committed.
This can change ownership of modules to this dist from another dist that claimed them.

=cut

sub import_dist($self, $peer, $author_path, %options) {
   my $dist_path= "authors/id/$author_path";
   my $distfile_obj= $peer->get_path($dist_path)
      or croak "Other tree does not contain $dist_path";
   my $existing= $self->get_path($dist_path);
   # If exists, must be same gitobj as before or this is an error
   if ($existing) {
      croak "$dist_path already exists with different content"
         unless $existing->id eq $distfile_obj->id;
   }
   $self->set_path($dist_path, $distfile_obj);
   my $modules_registered= $peer->package_details->{by_dist}{$author_path};
   if ($modules_registered) {
      $self->package_details->{by_dist}{$author_path}= [ @$modules_registered ];
      $self->package_details->{by_module}{$_->[0]}= $_
         for @$modules_registered;
      $self->write_package_details;
   }
   my $meta_path= $self->meta_path_for_dist($author_path);
   my $meta_blob= $peer->get_path($meta_path);
   if ($meta_blob) {
      $self->set_path($meta_path, $meta_blob)
   } else {
      ... # TODO: parse module for META.json and dependnecies
   }
   return $self;
}

=method get_dist_prereqs

  $prereqs_hash= $archive_tree->get_dist_prereqs($author_path);

Return the requirements for 'configure', 'runtime', and 'test' merged into a single hash.
These are the module requirements needed for installation via CPAN with testing enabled.

=cut

sub get_dist_prereqs($self, $author_path, %options) {
   my $meta_path= $self->meta_path_for_dist($author_path);
   my $meta_blob= $peer->get_path($meta_path);
   if ($meta_blob) {
      my $meta= JSON::PP->new->decode($meta_blob->content);
      my %prereqs;
      # TODO: let %options configure this
      for (qw( configure runtime test )) {
         %prereqs= ( %prereqs, $meta->{prereqs}{$_}{requires}->%* );
            if $meta->{prereqs} && $meta->{prereqs}{$_} && $meta->{prereqs}{$_}{requires};
      }
      return \%prereqs;
   }
   else {
      warn "Unknown dependnencies for $author_path (no meta file)\n";
      return {};
   }
}

=method import_modules

  $snapshot->import_modules(\%module_version_spec);
  # {
  #   'Example::Module' => '>=0.011',
  #   'Some::Module'    => '',   # any version
  # }

This method processes a list of module requirements to pull in matching modules and only as many
dependencies as are required.  It starts by checking whether this branch contains a module that
meets the requirements.  If not, it checks the mirror branches listed in "import_sources".
If this or any "import_source" branch has an "upstream_url", it may pull from remote into that
branch.

The intended workflow is that you have one branch tracking www.cpan.org and pulling in packages
automatically as needed, and then perhaps a branch where you review the modules before importing
them, and maybe a branch where you upload private DarkPAN modules, and then any number of
application branches that import from the reviewed branch or the DarkPAN branch. This way you
separate the process of building an application's module collection from the process of
reviewing public modules.

All changes will be pulled into this MutableTree object, but not committed.  If this is the
working branch, the index also gets updated.

=cut

sub import_modules($self, $reqs, %options) {
   require Module::CoreList;
   # None of our projects use older than 5.24, so no need to pull in dual-life modules
   # if perl 5.24 had a sufficient version.  Set this to match your oldest production perl.
   my $corelist_perl_version= $options{corelist_perl_version} // '5.024';
   my $sources= $options{sources} // $self->config->{import_sources};
   $sources && @$sources
      or croak "No import sources specified";
   # coerce every source name to an ArchiveTree object
   for (@$sources) {
      unless (ref $_ and $_->can('package_details')) {
         my $t= $self->parent->archive_tree($_)
            or croak "No such archive tree $_";
         $_= $t;
      }
   }
   my @todo= sort keys %$reqs;
   while (@todo) {
      my $mod= shift @todo;
      my @req_version= @{ $self->parse_version_requirement($reqs->{$mod}) };
      # Is this requirement already satisfied?
      # CoreList can only really test '>=' operator.  Ignore the rest of the spec...
      next if $req_version[0] eq '>='
           && Module::CoreList::is_core($mod, $req_version[1], $corelist_perl_version);
      my $current= $self->package_details->{by_module}{$mod};
      next if $current && $self->check_version($req_version, $current->[1]);
      # Walk through the list of import sources looking for a version that works
      my $prereqs;
      for my $src (@$sources) {
         my $mod_in_peer= $peer->package_details->{by_module}{$mod};
         my (undef, $peer_ver, $peer_author_path)= @$mod_in_peer;
         if ($mod_in_peer && $self->check_version($req_version, $peer_ver)) {
            $self->import_dist($peer, $author_path);
            $prereqs= $self->get_dist_prereqs($author_path);
            last;
         }
      }
      croak("No sources had module $mod with version $req_version")
         unless $prereqs;
      # Push things into the TODO list if they aren't already in %$reqs or if they have a higher
      # version requirement.
      for (keys $prereqs) {
         my $prev= $reqs->{$_} || 0;
         my $new= $self->combine_version_requirements($prev, $prereqs->{$_});
         if (!exists $reqs->{$_} or $new ne $prev) {
            $reqs->{$_}= $new;
            push @todo, $_;
         }
      }
   }
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

# For requirements like ">=1.1" and ">=1.2", simplify that into just ">=1.2"
# There are lots of edge cases not handled here.  Hopefully I don't need to...
sub combine_version_requirements($self, @reqs) {
   my %per_op;
   my @ne;
   for my $req (@reqs) {
      my $pairs= $self->parse_version_requirement($req);
      for (my $i= 0; $i < $#pairs; $i += 2) {
         my ($op, $num)= @{$pairs}[$i,$i+1];
         if ($op eq '!=') {
            push @ne, $num unless grep $_ eq $num, @ne;
         }
         elsif (!defined $per_op{$op}) {
            $per_op{$op}= $num;
         }
         elsif ($op eq '==') {
            # There can be only one
            croak "Mutually exclusive '==' version tests: ==$num, $per_op{$op}"
               if $per_op{$op} ne $num;
         }
         else {
            $per_op{$op}= $num
               unless $self->check_version([ $op, $num ], $per_op{$op});
         }
      }
   }
   return join ',', map($_ . $per_op{$_}, sort keys %per_op), map("!=$_", @ne);
}

sub check_version($self, $requirement, $version) {
   $version= version->parse($version)
      unless ref $version eq 'version';
   $requirement= ref $requirement eq 'HASH'? [ %$requirement ]
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

1;
