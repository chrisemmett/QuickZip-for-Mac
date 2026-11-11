# Security policy

QuickZip opens archives that often come from untrusted sources, so security
reports are very welcome and are treated as the highest priority.

## Reporting a vulnerability

**Please don't report security problems in public issues, pull requests or
discussions.**

Report them privately through GitHub instead: open the repository's
**Security** tab and choose **Report a vulnerability**. Only the maintainer can
see the report.

Please include:

- what the problem is and what an attacker could do with it;
- the steps to reproduce it, and an archive that triggers it if you can share
  one (made for the purpose, not containing anyone's private files);
- the QuickZip version or commit, and your macOS version;
- whether it affects the app, the `quickzip` command, the Quick Look
  extension, or ArchiveKit used as a library.

## What happens next

QuickZip is maintained by one person in spare time, so these are aims rather
than guarantees:

- an acknowledgement within a week;
- an assessment, and a fix or plan, as soon as it can be worked out;
- a fix released before the details are made public, with a GitHub security
  advisory crediting you unless you would rather not be named.

Please keep the details private until a fix is available or we've agreed a
date to publish.

## Supported versions

Fixes go into `main` and the next release. Older releases are not patched;
please update to the latest one.

## Scope

In scope, for example:

- extraction writing outside the destination folder (path traversal, symlink
  or hard-link escapes, case or Unicode-normalisation tricks);
- getting round the ZIP-bomb or expansion limits, or exhausting memory or disk
  in a way the limits should prevent;
- crashes, hangs or out-of-bounds reads caused by a malformed archive;
- extracted, previewed or opened items not carrying the quarantine attribute,
  or setuid/setgid bits surviving extraction;
- passwords leaking (to logs, temporary files, other processes) or being stored
  anywhere other than the Keychain when the user asks to remember them;
- the safety report missing or misreporting a dangerous item it is meant to
  flag;
- temporary preview or spool files readable by other users or left behind;
- a sandbox escape, or the Quick Look extension doing more than reading the
  archive it was given.

Out of scope:

- the weakness of ZipCrypto itself, which the app already warns about;
- formats QuickZip deliberately doesn't read (7z, RAR, bzip2, Zstandard);
- problems that need an attacker who already controls your Mac or user
  account;
- issues in macOS, Quick Look or Compression.framework themselves (please
  report those to Apple), unless QuickZip makes them worse.

If you're unsure whether something counts, report it anyway.

## Research

Good-faith research is welcome. Test on your own machines and archives, don't
access or change other people's data, and give a reasonable time to fix a
problem before disclosing it.
