# The `quickzip` command

`quickzip` is the application's engine without the window: the same
formats, the same safety rules and the same limits. It ships inside the
application, in `QuickZip.app/Contents/Helpers/quickzip`, and can be
installed on your PATH from QuickZip → Settings → Command line (a
symbolic link, so updating the application updates the command). It is also
built by the package: `swift run --package-path ArchiveKit quickzip …`.

```text
quickzip <command> [options] <archive>

  list          list the items in an archive
  extract       extract items into a folder (-d)
  verify        decompress every item and check its size and checksum
  test-safety   report items extraction would refuse, and ones to be careful with
  checksum      print SHA-256 checksums in `shasum -a 256 -c` format
```

| Option | |
|---|---|
| `-m`, `--match QUERY` | Only items matching `QUERY` (list, extract, checksum). Words match names; a word containing `/` matches paths; `*.pdf` or `ext:pdf` match extensions. A matching folder brings everything inside it. |
| `-d`, `--destination DIR` | Where `extract` writes. Default: a folder named after the archive, beside it. |
| `--conflict POLICY` | `extract` when something is already there: `keep-both` (default), `replace`, `skip`, `fail`. |
| `--json` | Print the result as JSON. |
| `--password-env NAME` | Read the password from environment variable `NAME`. `QUICKZIP_PASSWORD` is read if set. |
| `--password-file PATH` | Read the password from the first line of a file. |
| `--password-stdin` | Read the password from the first line of standard input. |

There is deliberately no `--password VALUE`: anything on a command line is
visible to other users in `ps`.

## Formats

ZIP (including ZipCrypto and WinZip AES encryption, Deflate64 and LZMA), tar,
`.tar.gz`/`.tgz`, `.tar.xz`/`.txz` and Apple Archive. Compressed tar and Apple
Archive are read from the start, so `list` on a large one takes a moment (a
progress percentage shows on a terminal). 7z, RAR, bzip2 and Zstandard are
recognised and refused with an explanation.

## Exit status

| Status | Meaning |
|---|---|
| 0 | Success. |
| 1 | The command failed: the archive could not be opened, an item is damaged (`verify`), items could not be extracted (`extract`), a checksum could not be made (`checksum`). |
| 64 | The command line was wrong. |
| 3 | `test-safety`: items that extraction would refuse were found. |
| 4 | `test-safety`: only items to be careful with were found. |

`extract` writes everything it safely can and then exits 1 if anything was
refused or failed, naming each item on standard error.

## JSON

With `--json` the result goes to standard output as one JSON document and
nothing else does; messages for people stay on standard error. Every
document has `"schema": 1`. Fields are only ever added within a schema
version.

```jsonc
// list
{ "schema": 1, "archive": "/path/a.zip", "warnings": [],
  "items": [ { "path": "docs/readme.md", "type": "file",      // file | directory | symlink
               "size": 1809, "compressedSize": 612,
               "modified": "2023-11-14T22:13:20Z", "method": "Deflate",
               "encrypted": false, "mode": "644" } ] }

// extract
{ "schema": 1, "archive": "...", "destination": "/path/out",
  "extracted": ["docs/readme.md"],             // relative to destination
  "skipped": [],
  "failures": [ { "path": "../evil", "kind": "unsafePath", "error": "…" } ],
  "warnings": [] }

// verify
{ "schema": 1, "archive": "...", "verified": 12, "intact": true,
  "damaged":    [ { "path": "…", "kind": "checksumMismatch", "error": "…" } ],
  "notChecked": [ { "path": "…", "kind": "passwordRequired", "error": "needs a password" } ],
  "warnings": [] }

// test-safety
{ "schema": 1, "archive": "...", "clean": false, "truncated": false,
  "blocked":  [ { "path": "../x", "kind": "unsafePath", "severity": "blocked", "detail": null } ],
  "cautions": [ { "path": "run.sh", "kind": "executable", "severity": "caution", "detail": "sh" } ] }

// checksum
{ "schema": 1, "archive": "...", "algorithm": "sha256",
  "items":   [ { "path": "hello.txt", "sha256": "…" } ],
  "skipped": [ { "path": "…", "kind": "passwordRequired", "error": "…" } ] }

// any command that fails
{ "schema": 1, "error": { "message": "…", "kind": "unsupportedFormat" } }
```

`kind` values are stable identifiers (`unsafePath`, `unsafeSymlink`,
`exceedsLimits`, `overlappingData`, `applicationBundle`, `executable`,
`doubleExtension`, `deceptiveCharacters` for findings; the engine's error
kinds, such as `checksumMismatch`, `passwordRequired`, `invalidPassword`,
`unsupportedFormat`, for failures). The `error` text is for people and may be
reworded or translated.

## Shortcuts

The application also provides three Shortcuts actions: **List Archive
Items**, **Extract Archive** and **Verify Archive**. They call the same
code. *Extract Archive* leaves its output in a temporary folder and returns
the extracted items for the next action to move or save. A password given to an
action is stored in the shortcut as plain text (Shortcuts has no secret
field for it); an archive whose password was saved with "Remember in
Keychain" needs none. For anything sensitive, run `quickzip` from a
*Run Shell Script* action with `--password-env` instead.
