use FindBin;
use lib "$FindBin::Bin/lib";
use Test2AndUtils;
use File::Temp;
use Git::Raw;
use CPAN::Mirror::InGit;
use v5.36;

# TEST_CPAN_INGIT_DIR=repo1 prove -lv t/10-init-mirror-of-cpan.t
# TEST_CPAN_INGIT_DIR=repo1 TEST_CPAN_INGIT_FETCH_MODULE=Crypt::DES prove -lv t/11-fetch-dist.t

{ # Scope for orderly cleanup of variables

   my $repodir= $ENV{TEST_CPAN_INGIT_DIR} // File::Temp->newdir(CLEANUP => 1);
   my $cpan_repo;
   if (-d "$repodir/objects" || -d "$repodir/.git/objects") {
      $cpan_repo= CPAN::Mirror::InGit->new(repo => $repodir);
   }
   else {
      my $git_repo= Git::Raw::Repository->init($repodir, 0);
      note "repo at $repodir";
      $cpan_repo= CPAN::Mirror::InGit->new(repo => $git_repo);
      $cpan_repo->create_mirror('www_cpan_org', upstream_url => 'https://www.cpan.org');
   }

   my $mirror= $cpan_repo->mirror('www_cpan_org');
   $mirror->upstream_url('https://www.cpan.org'); # TODO: save this in a config file
   my $module= $ENV{TEST_CPAN_INGIT_FETCH_MODULE} // 'Crypt::DES';
   $mirror->parse_package_details;
   my $module_dist= $mirror->module_info->{$module}[1];
   my $basename= $module_dist =~ s,.*/,,r;
   like $module_dist, qr{\.tar\.gz\z}, "file $module_dist is in index";

   $mirror->fetch_upstream_module_dist($module);
   $mirror->update_tree;
   is $mirror->tree->entry_bypath("authors/id/$module_dist"),
      object {
         call name => $basename;
         call type => Git::Raw::Object::BLOB();
      },
      "blob for $module_dist";
   $mirror->commit("Added $module_dist") if $mirror->has_changes;
}

done_testing;
