# High-Level Design: macOS Archive Browser

**Status:** Draft\
**Platform:** macOS\
**Technology:** Swift, SwiftUI, Foundation, Compression\
**Initial archive format:** ZIP\
**Architecture goal:** Native macOS application with no third-party
runtime dependencies

## 1. Purpose

The Archive Browser will provide a Finder-like interface for inspecting
and interacting with compressed archive files without requiring the
complete archive to be extracted.

The initial release will support ZIP archives and allow users to browse
their directory structure, inspect metadata, preview supported files and
selectively extract files or folders.

The application should treat an archive conceptually as a read-only
filesystem while keeping the underlying archive implementation abstract
enough to support additional formats in future.

## 2. Design Principles

The application should:

-   Use Apple-native frameworks wherever practical.
-   Avoid third-party archive libraries.
-   Never extract an entire archive simply to browse it.
-   Read archive metadata independently from file contents.
-   Decompress individual entries only when required.
-   Present archives using familiar macOS conventions.
-   Safely handle malformed or potentially malicious archives.
-   Separate the UI from the ZIP implementation.
-   Allow future archive formats without redesigning the application.

## 3. High-Level Architecture

``` text
┌─────────────────────────────────────────────┐
│                 SwiftUI UI                  │
│                                             │
│ NavigationSplitView / Inspector / Search    │
└─────────────────────┬───────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────┐
│            Archive Browser Layer            │
│                                             │
│ ArchiveDocument                             │
│ ArchiveNavigator                            │
│ ArchiveEntry                                │
│ PreviewManager                              │
│ ExtractionManager                           │
└─────────────────────┬───────────────────────┘
                      │
              ArchiveProvider
                      │
                      ▼
┌─────────────────────────────────────────────┐
│              Archive Engine                 │
│                                             │
│              ZIPProvider                    │
│                                             │
│ Central Directory Parser                    │
│ Entry Reader                                │
│ Decompression                               │
│ CRC Validation                              │
└───────────────┬─────────────────────────────┘
                │
       ┌────────┴────────┐
       ▼                 ▼
┌──────────────┐   ┌──────────────┐
│ Foundation   │   │ Compression  │
│ FileHandle   │   │ Framework    │
└──────────────┘   └──────────────┘
```

The important architectural decision is that **SwiftUI never knows that
it is looking at a ZIP file**.

It knows that it is looking at an `ArchiveProvider`.

## 4. Archive Abstraction

Define a protocol representing an archive:

``` swift
protocol ArchiveProvider {
    var entries: [ArchiveEntry] { get }

    func contents(of entry: ArchiveEntry) async throws -> Data
    func extract(
        _ entry: ArchiveEntry,
        to destination: URL
    ) async throws
}
```

ZIP becomes the first implementation:

``` swift
final class ZIPArchiveProvider: ArchiveProvider {
    // ZIP-specific implementation
}
```

Future implementations could include:

``` text
ZIPArchiveProvider
TarArchiveProvider
GZipArchiveProvider
SevenZipArchiveProvider
```

The UI therefore remains unchanged when formats are added.

## 5. Archive Entry Model

Every file or directory inside an archive is represented by a common
model:

``` swift
struct ArchiveEntry: Identifiable {
    let id: UUID

    let path: String
    let name: String
    let type: EntryType

    let compressedSize: UInt64
    let uncompressedSize: UInt64

    let modificationDate: Date?
    let compressionMethod: CompressionMethod

    let crc32: UInt32?
}
```

Entries should additionally retain an internal reference to their
location within the archive so the engine can access their compressed
data without searching for the entry again.

## 6. ZIP Reading Strategy

Opening a ZIP should **not decompress anything**.

The ZIP provider will:

``` text
Open archive
    │
    ▼
Locate End of Central Directory
    │
    ▼
Read Central Directory
    │
    ▼
Parse entries
    │
    ▼
Construct ArchiveEntry hierarchy
    │
    ▼
Display UI
```

This should make even relatively large archives open quickly because
only the ZIP directory structure needs to be processed.

## 7. File Access

When the user requests a file:

``` text
ArchiveEntry
      │
      ▼
Locate Local File Header
      │
      ▼
Read compressed bytes
      │
      ▼
Determine compression method
      │
      ├── Stored ───────► Return data
      │
      └── Deflate
             │
             ▼
       Compression.framework
             │
             ▼
        Validate CRC
             │
             ▼
          Result
```

The engine should stream data where practical rather than loading
arbitrarily large files completely into memory.

## 8. User Interface

The primary window should follow familiar macOS file-management
conventions.

``` text
┌──────────────────────────────────────────────────────────┐
│ photos.zip                                   🔍 Search   │
├──────────────────┬───────────────────────────────────────┤
│                  │ Name          Size       Modified     │
│ ▾ photos.zip     │                                       │
│   ▾ Holiday      │ beach.jpg     4.2 MB     12 Aug      │
│     ▸ Photos     │ hotel.pdf     1.1 MB     11 Aug      │
│       Notes      │ notes.txt     14 KB      10 Aug      │
│                  │                                       │
├──────────────────┴───────────────────────────────────────┤
│  3 items                          5.3 MB uncompressed    │
└──────────────────────────────────────────────────────────┘
```

`NavigationSplitView` is a natural foundation, with a hierarchical
sidebar and file-list/detail presentation.

Native macOS features should include contextual menus, keyboard
navigation, drag and drop, toolbar actions and standard macOS selection
behaviour.

## 9. Preview

Quick Look should provide previews wherever macOS supports the file
type.

Selecting or invoking Quick Look on files such as `image.jpg`,
`document.pdf`, `video.mov`, or `document.docx` would cause the
application to:

``` text
Selected ArchiveEntry
        │
        ▼
Extract to application temp directory
        │
        ▼
QLPreviewView
        │
        ▼
Delete when no longer required
```

A cache can prevent repeatedly decompressing the same entry.

## 10. Extraction

Users should be able to extract:

-   Individual files
-   Multiple selected files
-   Folders
-   The complete archive

Extraction should run asynchronously with progress reporting and
cancellation.

The destination should be chosen through standard macOS file APIs.

## 11. Drag and Drop

Dragging an archive entry into Finder should behave similarly to
dragging a normal file.

Conceptually:

``` text
Drag begins
     │
     ▼
Promise file to macOS
     │
     ▼
User drops in Finder
     │
     ▼
Extract entry
     │
     ▼
Provide resulting file
```

Using file promises avoids having to extract every item when the user
merely starts dragging it.

## 12. Search

Because the central directory has already been indexed, filename search
should be effectively instantaneous.

Initial search should cover:

-   Filename
-   Path
-   Extension

Searching **inside** archived documents should explicitly remain outside
the initial scope.

## 13. Security

Archive processing must treat all archive contents as untrusted.

### Path Traversal

An entry such as:

``` text
../../Library/something
```

must never be allowed to escape the selected extraction directory.

### ZIP Bombs

The application should detect suspicious compression ratios and
extremely large declared uncompressed sizes.

### Malformed Archives

Every offset and length read from the ZIP structure must be
bounds-checked against the actual archive size.

### Symlinks

Symlink extraction requires explicit handling to prevent a symlink from
redirecting subsequent extraction outside the destination.

### Quarantine Propagation

If the archive carries the `com.apple.quarantine` extended attribute
(for example because it was downloaded from the internet), every file
extracted from it must receive the same attribute. This preserves
Gatekeeper checks on extracted content, matching Archive Utility.
Without it the application would become a way of bypassing Gatekeeper.

Quarantine must be applied to files written for preview, "Open" and
drag and drop, not only to explicit extractions.

## 14. ZIP Capabilities

  Feature                        Initial support
  ------------------------------ ----------------------------------
  Standard ZIP                   Yes
  Stored files                   Yes
  DEFLATE                        Yes
  ZIP64                          Yes
  Unicode filenames              Yes
  Legacy filename encodings      Yes (auto-detect + manual override)
  Directory entries              Yes
  CRC validation                 Yes
  macOS metadata (`__MACOSX`)    Yes (restored on extraction)
  Encryption detection           Yes
  ZipCrypto decryption           Early follow-up (see §18.1)
  AES decryption                 Early follow-up (see §18.1)
  LZMA (method 14)               Investigate
  Deflate64, bzip2, zstd         No (entry listed, clear error)
  Multi-volume ZIP               Later
  Adding and deleting items      Yes (rewrite, see §19)

ZIP64 should be included from the beginning. Retrofitting it after
assuming 32-bit offsets throughout the parser would add unnecessary
complexity.

## 15. Concurrency

Archive parsing and extraction must never block the main actor.

A sensible boundary would be an archive engine implemented using an
`actor`:

``` swift
actor ZIPArchive {
    func open() async throws
    func entries() async throws -> [ArchiveEntry]
    func extract(_ entry: ArchiveEntry, to url: URL) async throws
}
```

SwiftUI receives observable state from a separate view model running on
`@MainActor`.

## 16. Proposed Project Structure

``` text
ArchiveBrowser
│
├── App
│   └── ArchiveBrowserApp.swift
│
├── UI
│   ├── ArchiveView.swift
│   ├── SidebarView.swift
│   ├── FileListView.swift
│   ├── InspectorView.swift
│   └── PreviewView.swift
│
├── ArchiveKit
│   ├── ArchiveProvider.swift
│   ├── ArchiveEntry.swift
│   │
│   └── ZIP
│       ├── ZIPArchive.swift
│       ├── ZIPCentralDirectory.swift
│       ├── ZIPEntry.swift
│       ├── ZIPHeaderParser.swift
│       ├── ZIP64Parser.swift
│       ├── ZIPDecompressor.swift
│       └── CRC32.swift
│
├── Services
│   ├── ExtractionManager.swift
│   ├── PreviewManager.swift
│   └── TemporaryFileManager.swift
│
└── Utilities
    └── BinaryReader.swift
```

`ArchiveKit` should be considered as a separate Swift package from the
beginning. This creates a clean separation between the macOS application
and the archive engine and makes the ZIP parser independently testable.

## 17. MVP

The first milestone should remain deliberately small:

``` text
Open ZIP
   ↓
Parse central directory
   ↓
Display folders/files
   ↓
Select file
   ↓
Extract file
```

Once this works reliably, subsequent iterations can add Quick Look, drag
and drop, search, multi-selection and polished Finder-like behaviour.

The primary technical spike is proving that a small native `ArchiveKit`
can **open a ZIP, parse its central directory, enumerate entries and
selectively DEFLATE one entry using Apple's Compression framework**.
Once that works, the core technical risk of the application has been
substantially reduced.

## 18. Additional Requirements

The sections above focus on the archive engine. This section adds the
behaviour needed for the application to feel complete and safe as a
native macOS file browser. Items are marked **v1** (required for the
first public release) or **Later**.

### 18.1 Archive Handling

**v1 — Unsupported compression methods.** Real-world ZIPs frequently
use methods that Compression.framework cannot decode: Deflate64
(produced by Windows Explorer for large files), bzip2 and zstd
(7-Zip, WinZip). Such entries must still be listed and browsable. Any
attempt to read them must fail with a specific message, for example
"compressed with Deflate64, which is not supported", never a generic
or silent failure. Compression.framework does include an LZMA decoder,
but ZIP method 14 wraps the stream differently; support should be
investigated.

**v1 — Encryption detection.** Encrypted entries must be identified
when the central directory is read, shown with a lock indicator, and
refused with a clear explanation.

**Early follow-up — Decryption.** Password-protected archives are
common enough that decryption should follow shortly after v1 rather
than being deferred indefinitely. Traditional ZipCrypto is small to
implement; WinZip AES can be built on CommonCrypto. Both remain
native. Passwords must never be logged or persisted except, optionally,
in the Keychain.

**v1 — Archive verification.** A "Verify Archive" command decompresses
every entry, checks its CRC and reports any corruption, without writing
anything to disk.

**v1 — Filename encodings.** When the UTF-8 flag (bit 11) is not set,
names should be decoded as UTF-8 if valid, then fall back to CP437. The
Info-ZIP Unicode Path extra field (0x7075) takes priority when present.
Archives created on non-English Windows systems often use Shift-JIS,
GBK or CP866, so the application should attempt detection and provide
a **View → Text Encoding** menu to override it per archive.

**v1 — Damaged archives.** A corrupt or truncated archive should show
whichever entries could be recovered, with a clear warning, rather than
refusing to open.

**Later — Nested archives.** An archive inside an archive should open
in place (via a temporary copy) in a new window or tab.

### 18.2 Extraction Fidelity

**v1 — Quarantine propagation.** See §13.

**v1 — macOS metadata.** Archives created on macOS store extended
attributes, resource forks and Finder tags in `__MACOSX/._*`
AppleDouble entries. These entries are hidden from the browser by
default (with a View menu toggle), and on extraction their contents
are merged back into the corresponding files, as `ditto` does.

**v1 — Permissions and dates.** Unix permissions (in particular the
executable bit) and modification dates are restored from the archive.
Setuid, setgid and sticky bits are always stripped.

**v1 — Disk space and conflicts.** Before extracting, the total
uncompressed size is checked against free space on the destination
volume. Name collisions offer Keep Both, Replace or Skip, with an
"apply to all" option.

### 18.3 Finder Integration

| Feature | Priority |
|---|---|
| **Open** an entry in its default application (extract to temp, then `NSWorkspace.open`), read-only, warning that edits are not saved back | v1 |
| File icons from `UTType` / `NSWorkspace` in the list | v1 |
| Register as a viewer for ZIP, with an option to become the default app | v1 |
| Detect the archive changing on disk (`NSFilePresenter`) and offer to reload | v1 |
| Copy (⌘C) entries and paste (⌘V) them into Finder | Later |
| Image thumbnails in the list | Later |
| **Quick Look extension**: pressing Space on a `.zip` in Finder shows its file listing, reusing ArchiveKit | Later (high value) |
| Services / Share menu integration | Later |

### 18.4 Additional Formats

The `ArchiveProvider` abstraction should be validated against a second
format early. Natively achievable formats:

- **tar, .tar.gz, .tar.xz** — gzip is DEFLATE with a small header, and
  Compression.framework decodes xz (LZMA). No third-party code needed.
- **Apple Archive (.aar)** — public AppleArchive framework.

**7z and RAR** are not achievable without third-party code and are out
of scope under the design principles in §2. The application should
say so plainly rather than offering to open them.

Compressed tar has **no central directory**: listing it means
decompressing the whole stream once. The `ArchiveProvider` protocol
must therefore allow opening to be a slow, cancellable,
progress-reporting operation, and must not assume random access to
individual entries is cheap.

### 18.5 Non-Functional Requirements

**Performance targets** (on a baseline Apple silicon Mac):

| Scenario | Target |
|---|---|
| Open an archive with 100,000 entries | < 1 s to first display |
| Filename search over 100,000 entries | < 16 ms per keystroke |
| Extract a 10 GB single entry | Flat memory use (bounded buffers) |
| Open any archive | Main thread never blocked > 16 ms |

**Distribution.** Choose between the Mac App Store and Developer ID
with notarization. This affects sandboxing, update delivery (App Store
updates versus a self-hosted updater — the common choice, Sparkle, is a
third-party dependency) and pricing. Either way the app is sandboxed
and notarized.

**Accessibility.** VoiceOver labels for all list rows, sidebar items and
toolbar actions; full keyboard navigation; Dynamic Type and Increase
Contrast respected.

**Localization.** All user-facing strings in a String Catalog from the
start; dates and sizes formatted using the user's locale.

**Diagnostics.** `os.Logger` with separate categories for parsing,
extraction and preview. Archive contents and passwords are never logged.

**Testing.** ArchiveKit is covered by unit tests against checked-in
fixture archives (macOS `zip` and `ditto`, Windows Explorer, 7-Zip,
Python `zipfile` with forced ZIP64, data-descriptor entries) and
deliberately malicious archives (path traversal, overlapping entries,
truncated central directory, out-of-range offsets, huge declared
sizes). The central directory parser should have a fuzz target.

## 19. Non-Goals

The following are deliberately out of scope for the initial product:

- **Creating archives.** Archive Utility can create ZIPs. Existing
  archives *can* be modified, but only by adding and deleting items: the
  application never writes into an archive in place. `RewritableArchive`
  writes a complete new archive to a temporary file, copying kept entries
  byte for byte (so encrypted entries and unsupported methods survive),
  verifies it, then atomically swaps it for the original. Where the
  sandbox grants access to the archive alone and the swap is refused, the
  verified copy is written over the original instead. Damaged archives,
  and those with overlapping entries, are never rewritten.
- **Searching inside archived file contents** (see §12).
- **7z, RAR and other formats requiring third-party decoders** (see
  §18.4).
- **Multi-volume (split) ZIP archives.**
- **Editing extracted files in place and saving them back** into the
  archive.

## 20. Implementation Phases

This section orders the remaining work, including the v1 items above
and new feature ideas, into phases. Each phase leaves the application
shippable. Items carry a reference to the section that specifies them,
or **New** where this section is the first place they appear; new items
follow the same design principles (§2), so nothing here introduces a
third-party dependency.

Already complete: the ArchiveKit engine (§4–§7, §13, §14, most of
§18.1 and §18.2), the browser window, inline and panel Quick Look,
extraction with conflict handling, adding and deleting items, and
Phase 1.

### Phase 1 — Complete the v1 browser

Goal: every interaction a Finder user expects works.

**Status:** implemented. Search covers the folder being shown and
everything below it; a word containing `/` matches paths, and `*.ext` or
`ext:` matches extensions. Results beyond 5,000 are counted but not
listed, so sorting them never stalls typing. Double-click opens a file in
its default application, as in Finder; Space remains Quick Look.

| Item | Ref |
|---|---|
| Drag entries to Finder using file promises, extracting only on drop | §11 |
| Copy (⌘C) entries and paste (⌘V) them into Finder, built on the same promise mechanism | §18.3 |
| Filename, path and extension search over the indexed central directory, meeting the < 16 ms per keystroke target | §12, §18.5 |
| Open an entry in its default application, read-only, with a warning that edits are not saved back | §18.3 |
| File icons from `UTType` / `NSWorkspace` in the list | §18.3 |
| View → Text Encoding menu over the engine's existing override, plus auto-detection of Shift-JIS, GBK and CP866 | §18.1 |
| Verify Archive command and results sheet over the existing `ArchiveVerifier` | §18.1 |
| AppleDouble (`__MACOSX`) merge on extraction, with a View menu toggle to show the entries | §18.2 |
| Detect the archive changing on disk (`NSFilePresenter`) and offer to reload | §18.3 |
| Register as a ZIP viewer, with an option to become the default app | §18.3 |

### Phase 2 — Release readiness

Goal: the first public release. Nothing user-visible is added; this
phase makes Phase 1 trustworthy and distributable.

**Status:** implemented, except where noted. Distribution is **Developer
ID with notarization, not the Mac App Store**, and there is no in-app
updater, which would need Sparkle (a third-party dependency); the reasons
are in `docs/DISTRIBUTION.md`. `Scripts/release.sh` has not yet been run
against a real certificate. The landing page (`docs/index.html`) shows
`docs/demo.mp4` once that recording exists. macOS has no Dynamic Type, so
the application uses semantic text styles throughout and follows whatever
the system provides; Increase Contrast strengthens its custom surfaces.
Only the application's own text and ArchiveKit's error messages are in
String Catalogs; the technical reasons inside "The archive is damaged: …"
stay in English.

| Item | Ref |
|---|---|
| VoiceOver labels, full keyboard navigation, Dynamic Type and Increase Contrast | §18.5 |
| All strings in a String Catalog; locale-aware dates and sizes | §18.5 |
| `os.Logger` categories for parsing, extraction and preview | §18.5 |
| Fuzz target for the central directory parser, run in CI | §18.5 |
| Benchmark suite for the §18.5 performance targets, run in CI, with the results published in the README (for example "opens 100,000 entries in X ms") | §18.5, **New** |
| Decide Mac App Store or Developer ID; sandboxed, notarized builds | §18.5 |
| A landing page with a short demo recording | **New** |

### Phase 3 — Safety and insight

Goal: features that make the application visibly better than Archive
Utility, built almost entirely on data the engine already has.

**Status:** implemented. The safety report reads only the directory plus
the few bytes of each symbolic link (at most 2,000 links, 5,000 findings).
`.js`, `.py` and similar everyday scripts are deliberately not flagged as
programs. A click in the Size Map selects the item's top-level ancestor in
the folder being shown, so commands never act on rows that are not listed.
Moving the archive to the Trash may be refused by the sandbox when only
the file, not its folder, was granted; the user is told if so.

**New — Pre-extraction safety report.** When an archive opens, a banner
summarises anything suspicious: entries the extractor would refuse
(path traversal, symlinks escaping the destination), ZIP-bomb
indicators (declared size, compression ratio, overlapping entries),
executables and app bundles, and deceptive names such as
`invoice.pdf.app` or names containing right-to-left override
characters. Clicking the banner lists the affected entries. This
surfaces the checks in §13 as a feature rather than an error at
extraction time.

**New — Integrity information.** The inspector shows each entry's
CRC-32, and on request a SHA-256 computed by streaming the entry
through CryptoKit. Both can be copied. A command exports a checksum
list for the selection.

**New — Size visualisation.** A treemap of the archive (SwiftUI
`Canvas`) showing what takes up space, coloured by compression ratio.
The list gains a sortable Ratio column. Uses only central directory
sizes, so it costs nothing to compute.

**New — Smart extraction defaults.** When the archive has a single
top-level folder, extract it directly rather than nesting it inside a
folder of the same name. Optional preferences: reveal the destination
in Finder afterwards, and move the archive to the Trash after a
successful full extraction.

### Phase 4 — Finder reach

Goal: the application is useful without being opened first.

**Status:** implemented; the Quick Look extension has not yet been seen
working in Finder (see the README). Thumbnails decompress each image as its
row appears (16 MB limit, three at a time) and are optional in Settings. The
Share button shares the same file promises as drag and drop. While adding
this, the "changed by another application" banner was found to appear
whenever macOS wrote extended attributes to a just-opened archive; it now
requires a different size or modification date.

| Item | Ref |
|---|---|
| **Quick Look extension**: Space on a `.zip` in Finder shows its file listing, reusing ArchiveKit | §18.3 |
| Services and Share menu integration, including a "Browse with QuickZip" Finder service | §18.3, **New** |
| Image thumbnails in the list (`QLThumbnailGenerator`, generated lazily for visible rows, using the preview cache) | §18.3 |
| Tabs, an Open Recent menu, and restoring the last folder shown in each archive | **New** |

The Quick Look extension runs in its own sandboxed process, so it
should depend only on ArchiveKit and must respect the same limits
(§13) as the application.

### Phase 5 — Compatibility

Goal: open the archives people actually receive.

**Status:** implemented. LZMA is not available through Compression.framework:
`COMPRESSION_LZMA` decodes the `.xz` container, not the raw LZMA stream ZIP
stores, and a raw LZMA1 stream cannot be wrapped in `.xz` (which carries
LZMA2), so both LZMA and Deflate64 have native, streaming decoders in
ArchiveKit. WinZip AES counter mode is built on AES-ECB because
CommonCrypto's public counter modes cannot count in little-endian. Fixtures
come from Info-ZIP, pyzipper and Python's zipfile; Deflate64 has no
encoder available, so its tests build the streams bit by bit. Not yet
verified end to end: the Keychain round trip in the sandboxed app, and
drag-and-drop of encrypted items (which fails quietly until the archive is
unlocked).

| Item | Ref |
|---|---|
| ZipCrypto decryption | §18.1 |
| WinZip AES decryption on CommonCrypto; optional Keychain storage; passwords never logged | §18.1 |
| Deflate64: a native decoder alongside the existing `Inflater` (the format differs from DEFLATE only in window size, length codes and distance codes) | §18.1, **New** |
| Investigate ZIP method 14 (LZMA) via Compression.framework | §18.1 |
| Nested archives open in place, via a temporary copy, in a new tab | §18.1 |
| Compare two archives, or an archive against a folder: added, removed and changed entries, matched by path and CRC-32, without decompressing anything | **New** |

Encrypted entries must remain byte-for-byte copyable by
`RewritableArchive` (§19); decryption applies to reading only.

### Phase 6 — Additional formats

Goal: validate the `ArchiveProvider` abstraction against formats other
than ZIP.

**Status:** implemented. The abstraction needed three changes: the opener
reports progress and honours cancellation (`ArchiveOpener`); sequential
formats spool their data to a temporary file (`ArchiveSpool`); and
editing moved off the base protocol onto `RewritableArchive`, which only
ZIP adopts. `CompressionMethod` gained `.wholeArchive`, because entries of a
solid archive have no size of their own. Compression.framework could not
decode gzip with its trailer and members (see the README), so gzip uses
the DEFLATE decoder written for Deflate64.

| Item | Ref |
|---|---|
| tar, `.tar.gz`, `.tar.xz`, with slow, cancellable, progress-reporting open | §18.4 |
| Apple Archive (`.aar`) through the AppleArchive framework | §18.4 |
| ZIP-based documents opened read-only: `.ipa`, `.jar`, `.epub`, `.docx`, `.xlsx`, `.pptx`. Mostly a matter of declaring the document types; editing remains disabled because these formats have ordering and content requirements | **New** |
| A plain message for 7z and RAR saying they are not supported | §18.4 |

tar should come first: it is the format most likely to expose
assumptions in `ArchiveProvider` (no central directory, sequential
access).

### Phase 7 — Automation

Goal: the engine is usable outside the window.

**Status:** implemented. `ArchiveAutomation` in ArchiveKit holds the five
operations and their JSON-encodable results; the `quickzip` command
(`QuickZipCLI`, with a one-line `main.swift` in the package and in the
application's helper target) and the three App Intents are thin layers over
it, so they cannot drift apart. The tool is not sandboxed (it runs from
Terminal on the user's files) and the sandboxed application installs it by
creating a link in a folder the user picks. Documented in `docs/CLI.md`.

**New — Shortcuts.** App Intents for listing an archive's contents,
extracting all or matching entries to a folder, and verifying an
archive. Each intent goes through the same `ArchiveProvider`,
extractor and limits as the application.

**New — Command-line tool.** Grow `ArchiveKitCLI` into a supported
`quickzip` command (list, extract, verify, test-safety, checksum)
shipped inside the application bundle, with an option to install a
symlink into `/usr/local/bin`. Output has a machine-readable JSON mode.

### Phase ordering rationale

Phases 1 and 2 close the gap to the v1 definition in §18. Phase 3 comes
before the Finder integration in Phase 4 because it needs little new
engine work and makes the strongest case for the application.
Phase 5 precedes new formats because unsupported encryption and
Deflate64 are the most common reasons a real-world ZIP fails to open.
Phases 5–7 are largely independent and can be reordered by demand.
