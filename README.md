CPAN::InGit
-----------

### About

This module creates git branches with the file structure of a CPAN mirror.
It facilitates pulling them from the public CPAN, pulling dependencies, and
and serving the trees as if they were a CPAN mirror.  It operates directly
on Git object storage (using Git::Raw) and can also optionally make its
changes to a Git working directory for manual commits.

### Installing

When distributed, all you should need to do is run

    perl Makefile.PL
    make install

or better,

    cpanm CPAN-InGit-0.001.tar.gz

or from CPAN:

    cpanm CPAN::InGit

### Developing

However if you're trying to build from a fresh Git checkout, you'll need
the Dist::Zilla tool (and many plugins) to create the Makefile.PL

    cpanm Dist::Zilla
    dzil authordeps | cpanm
    dzil build

### Copyright

This software is copyright (c) 2024-2025 by Michael Conrad and IntelliTree Solutions

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.
