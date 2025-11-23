use FindBin;
use lib "$FindBin::Bin/lib";
use Test2AndUtils;
use File::Temp;
use Git::Raw;
use CPAN::Mirror::InGit;
use v5.36;

{ # Scope for orderly cleanup of variables

   my $repodir= $ENV{TEST_CPAN_INGIT_DIR} // File::Temp->newdir(CLEANUP => 1);
   my $git_repo= Git::Raw::Repository->init($repodir, 1); # new bare repo in tmpdir
   note "repo at $repodir";

   my $cpan_repo= CPAN::Mirror::InGit->new(repo => $git_repo);
   
   my $mirror= $cpan_repo->create_mirror('www_cpan_org', upstream_url => 'https://www.cpan.org');
   is $mirror,
      object {
         call upstream_url => 'https://www.cpan.org/';
      },
      'MirrorTree object';
}

done_testing;
