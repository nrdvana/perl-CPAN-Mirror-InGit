package CPAN::Mirror::InGit::MirrorTree;
# VERSION
# ABSTRACT: Subclass of ArchiveTree which automatically mirrors files from upstream

=head1 DESCRIPTION

This is a subclass of L<CPAN::Mirror::InGit::ArchiveTree> which behaves as a pure mirror of an
upstream CPAN or DarkPAN.  The attribute L</autofetch> allows it to import files from the public
CPAN on demand.

=cut

use Carp;
use Scalar::Util 'refaddr', 'blessed';
use POSIX 'strftime';
use IO::Uncompress::Gunzip qw( gunzip $GunzipError );
use JSON::PP;
use Time::Piece;
use Log::Any '$log';
use Moo;
use v5.36;

extends 'CPAN::Mirror::InGit::ArchiveTree';

=attribute upstream_url

This is the base URL from which files will be fetched.

=attribute autofetch

If enabled, attempts to access author files which exist on the L</upstream_url> and not locally
will immediately go download the file and return it as if it had existed all along.  These
changes are not automatically committed.  Use C<has_changes> to see if anything needs committed.

=attribute package_details_max_age

Number of seconds to cache the package_details file before attempting to re-fetch it.
Defaults to one day (86400).  This only has an effect when C<autofetch> is enabled.

=cut

has upstream_url            => ( is => 'rw', coerce => \&_add_trailing_slash );
has autofetch               => ( is => 'rw' );
has package_details_max_age => ( is => 'rw', default => 86400 );

sub _pack_config($self, $config) {
   $config->{upstream_url}= $self->upstream_url;
   $config->{autofetch}= $self->autofetch;
   $config->{package_details_max_age}= $self->package_details_max_age;
   $self->next::method($config);
}
sub _unpack_config($self, $config) {
   $self->next::method($config);
   $self->upstream_url($config->{upstream_url});
   $self->autofetch($config->{autofetch});
   $self->package_details_max_age($config->{package_details_max_age});
}

sub get_path($self, $path) {
   my $ent= $self->next::method($path);
   if ($self->autofetch) {
      # Special case for 02packages.details.txt, load it if missing or if cache is stale
      if ($path eq 'modules/02packages.details.txt') {
         my $blob_last_update;
         if ($ent) {
            $blob_last_update= $self->{_blob_last_update}{$ent->[0]->id} // do {
               # parse it out of the file
               my $head= substr($ent->content, 0, 10000);
               $head =~ /^Last-Updated:\s*(.*)$/m or die "Can't parse 02packages.details.txt";
               (my $date= $1) =~ s/\s+\z//;
               $log->debug("Date in modules/02packages.details.txt is '$date'");
               Time::Piece->strptime($date, "%a, %d %b %Y %H:%M:%S GMT")->epoch
            };
         }
         my $cutoff= time - $self->package_details_max_age;
         unless ($blob_last_update && $blob_last_update >= $cutoff) {
            my $blob= $self->add_upstream_package_details;
            $self->clear_package_details; # will lazily rebuild
            $ent= [ $blob, 0100644 ];
         }
      }
      elsif ($path =~ m{^authors/id/(.*)} and !$ent) {
         my $author_path= $1;
         my $blob= $self->add_upstream_author_file($author_path, undef_if_404 => 1);
         $ent= [ $blob, 0100644 ] if $blob;
      }
   }
   return $ent;
}

=method fetch_upstream_file

  $content= $mirror->fetch_upstream_file($path, %options);
  
  # %options:
  #   undef_if_404 - boolean, return undef instead of croaking on a 404 error

=cut

sub fetch_upstream_file($self, $path, %options) {
   croak "No upstream URL for this tree"
      unless defined $self->upstream_url;
   my $url= $self->upstream_url . $path;
   my $tx= $self->parent->useragent->get($url);
   unless ($tx->result->is_success) {
      return undef if $options{undef_if_404} && $tx->result->code == 404;
      croak "Failed to find file upstream: ".$tx->result->extract_start_line;
   }
   return \$tx->result->body;
}

=method add_upstream_package_details

  $blob= $mirror->add_upstream_package_details;

Fetches C<modules/02packages.details.txt.gz> from upstream, unzips it, adds it to the tree,
and returns the C<Git::Raw::BLOB>.

=cut

sub add_upstream_package_details($self, %options) {
   my $content_ref= $self->fetch_upstream_file('modules/02packages.details.txt.gz', %options)
      or return undef;
   # Unzip the file and store uncompressed, so that 'git diff' works nicely on it.
   my $txt;
   gunzip $content_ref => \$txt
      or croak "gunzip failed: $GunzipError";
   my $blob= Git::Raw::Blob->create($self->parent->repo, $txt);
   $self->set_path('modules/02packages.details.txt', $blob);
   $self->{_blob_last_update}{$blob->id}= time;
   return $blob;
}

=method add_upstream_author_file

  $blob= $mirror->add_upstream_author_file($author_path, %options);

Fetch the file (relative to C<authors/id/>) from upstream and add it to this tree.
Also return the C<Git::Raw::BLOB>.

=cut

sub add_upstream_author_file($self, $author_path, %options) {
   my $path= "authors/id/$author_path";
   my $content_ref= $self->fetch_upstream_file($path, %options)
      or return undef;
   my $blob= Git::Raw::Blob->create($self->parent->repo, $$content_ref);
   $self->set_path($path, $blob);
   return $blob;
}

1;
