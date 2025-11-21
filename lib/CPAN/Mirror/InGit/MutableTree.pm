package CPAN::Mirror::InGit::MutableTree;
# ABSTRACT: Utility object that represents a Git Tree and pending changes

=head1 SYNOPSIS

  my $t= CPAN::Mirror::InGit::MutableTree->new(
    parent   => $cpan_repo,
    tree     => $git_tree_obj,
    branch   => $name,
  );
  
  $t->set_path('path/to/file',  \$file_data);
  $t->set_path('path/to/file2', \$file_data);
  $t->set_path('other/path' => \$path, ( symlink => 1 ));
  $t->commit("Message");

=head1 DESCRIPTION

This object wraps a L<Git::Raw::Tree>, optionally tied to a L<Git::Raw::Branch>.
It can store changes to the tree which have not been committed yet, but which
are seen when querying the paths of the tree.  The changes can be serialized in
e.g. a web framework's session, and then you can then commit them when ready.

If C<workdir_path> is set, this will instead write changes to the working
directory and add them to the Git index, where the user can commit them.

=cut

use Moo;
use v5.36;

has parent            => ( is => 'ro', required => 1 );
has tree              => ( is => 'rw', required => 1 );
has branch            => ( is => 'rw' );
has workdir_path      => ( is => 'rw' );
has changes           => ( is => 'rw' );
sub repo                 { shift->parent->repo }

sub get_path($self, $path) {
   ...
}

sub set_path($self, $path, $git_obj_or_scalarref, %opts) {
   ...
}

sub commit($self, $message, %opts) {
   ...
}

1;
