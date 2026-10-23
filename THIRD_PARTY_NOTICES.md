# Third-party software

Camp's stack installer downloads the following pinned upstream releases and
builds them locally. These projects retain their own copyright and license
terms. License and notice files are included in the app bundle under
`Contents/Resources/THIRD_PARTY_LICENSES`. The matching MariaDB, ProFTPD, and
phpMyAdmin source archives are also included under `Contents/Resources` so the
installer carries corresponding source for its redistributed GPL components.
phpMyAdmin retains its `LICENSE` file in the installed web root.

| Component | Version source | License |
| --- | --- | --- |
| Apache HTTP Server | `stack/versions.env` | Apache-2.0 |
| APR and APR-util | `stack/versions.env` | Apache-2.0 |
| OpenSSL | `stack/versions.env` | Apache-2.0 |
| PCRE2 | `stack/versions.env` | BSD-3-Clause |
| PHP | `stack/versions.env` | PHP-3.01 |
| MariaDB Server | `stack/versions.env` | GPL-2.0-only (server); bundled components may have separate terms |
| Perl | `stack/versions.env` | Artistic-1.0-Perl OR GPL-1.0-or-later |
| ProFTPD | `stack/versions.env` | GPL-2.0-or-later |
| phpMyAdmin | `stack/versions.env` | GPL-2.0-or-later |
| libpng | `stack/versions.env` | libpng-2.0 |
| libjpeg-turbo | `stack/versions.env` | BSD-3-Clause and IJG terms |
| FreeType | `stack/versions.env` | FTL OR GPL-2.0-or-later |
| libzip | `stack/versions.env` | BSD-3-Clause |
| Oniguruma | `stack/versions.env` | BSD-2-Clause |
| ICU | `stack/versions.env` | Unicode-3.0 |
| GNU Bison | `stack/versions.env` | GPL-3.0-or-later WITH Bison-exception-2.2 |

The exact pinned version numbers and upstream download locations are maintained
in [`stack/versions.env`](stack/versions.env) and `scripts/build-stack.sh`.
