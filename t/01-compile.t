#! /usr/bin/perl
use FindBin;
use lib "$FindBin::Bin/lib";
use Test2AndUtils;
use v5.36;
my @pkgs= qw(
   CPAN::Mirror::InGit
   CPAN::Mirror::InGit::MirrorTree
);

ok( eval "require $_", $_ )
   or diag $@ and BAIL_OUT("use $_")
   for @pkgs;

diag "Testing on Perl $], $^X\n"
	.join('', map { sprintf("%-40s  %s\n", $_, $_->VERSION) } @pkgs);

done_testing;
