use FindBin;
use lib "$FindBin::Bin/lib";
use Test2AndUtils;
use File::Temp;
use Git::Raw;
use CPAN::Mirror::InGit;
use v5.36;

{ # Scope for orderly cleanup of variables

   my $repodir= File::Temp->newdir(CLEANUP => 1);
   my $git_repo= Git::Raw::Repository->init($repodir, 1); # new bare repo in tmpdir
   note "repo at $repodir";

   my $cpan_repo= CPAN::Mirror::InGit->new(repo => $git_repo);
   
   my $mirror= $cpan_repo->create_mirror('www_cpan_org', upstream_url => 'https://www.cpan.org');

   my $module= 'Crypt::DES';
   $mirror->parse_package_details;
   my $module_dist= $mirror->module_info->{$module}[1];
   my $basename= $module_dist =~ s,.*/,,r;
   like $module_dist, qr{\.tar\.gz\z}, "file $module_dist is in index";

   $mirror->fetch_upstream_module_dist('Crypt::DES');
   $mirror->update_tree;
   is $mirror->tree->entry_bypath("authors/id/$module_dist"),
      object {
         call name => $basename;
         call type => Git::Raw::Object::BLOB();
      },
      "blob for $module_dist";
}

done_testing;
