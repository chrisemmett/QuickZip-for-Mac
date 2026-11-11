# QuickZip

A native macOS archive browser: open a ZIP, browse it like a Finder folder,
preview and extract individual items without unpacking the whole archive.
See the [high-level design](macos-archive-browser-hld.md).

## Status

**ArchiveKit**, the archive engine, is a standalone Swift package (HLD §16)
covering the MVP technical spike (§17) plus the engine-side v1 requirements.
The SwiftUI app has its main browser window, with preview and extraction.

| Area | HLD | State |
|---|---|---|
| `ArchiveProvider` / `ArchiveEntry` abstraction | §4, §5 | Done |
| Central directory parsing, nothing decompressed on open | §6 | Done |
| Stored + DEFLATE (Compression.framework), streamed in bounded chunks, CRC-checked | §7 | Done |
| ZIP64, data descriptors, self-extracting prefixes | §14 | Done |
| UTF-8 / CP437 / Info-ZIP Unicode Path names, encoding override | §18.1 | Done |
| Auto-detection of Shift-JIS, GBK and CP866 names; View → Text Encoding menu | §18.1 | Done |
| Encryption detection, clear errors for bzip2/zstd/PPMd/… | §18.1 | Done |
| ZipCrypto and WinZip AES (128/192/256, AE-1 and AE-2) decryption, streamed; encrypted entries still copy byte for byte when the archive is edited | §18.1, Phase 5 | Done |
| Deflate64 (native decoder) and LZMA (native decoder; Compression.framework cannot read raw LZMA) | §18.1, Phase 5 | Done |
| Damaged archives: partial directory and truncated-file recovery | §18.1 | Done |
| Verify Archive | §18.1 | Done |
| Path traversal, symlink escapes, ZIP bombs (declared size, ratio, overlapping entries), bounds checks | §13 | Done |
| Quarantine propagation | §13 | Done (extractor applies the archive's attribute to every item) |
| Permissions (setuid/setgid/sticky stripped), dates, conflict policies, free-space check | §18.2 | Done |
| Folder hierarchy with synthesised folders, `__MACOSX` hidden | §8, §18.2 | Done |
| AppleDouble (`__MACOSX`) merge on extraction (Finder info, resource fork, extended attributes; never quarantine), View menu toggle to show the entries | §18.2 | Done |
| Browser window: folder sidebar, sortable file list, inspector, status bar, damaged-archive warnings | §8 | Done |
| Preview without extracting: inline Quick Look in the inspector, Space for the Quick Look panel, temp files quarantined and deleted on close | §9 | Done |
| Extract selection / folder / whole archive, progress, Stop, Keep Both / Replace / Skip | §10, §18.2 | Done |
| Add files and folders (Add Files…, ⌘⇧A, or drag from Finder) and delete items (⌘⌫), rewriting the archive safely | §19 | Done |
| Drag to Finder and ⌘C / paste into Finder, as file promises extracted only on drop | §11, §18.3 | Done |
| Filename, path and extension search over the whole archive (`ArchiveSearchIndex`) | §12 | Done |
| Open an item in its default application (read-only copy, with a warning) | §18.3 | Done |
| Verify Archive command and results sheet | §18.1 | Done |
| Detect the archive changing on disk (`NSFilePresenter`) and offer to reload | §18.3 | Done |
| Registered as a ZIP viewer; Settings can make QuickZip the default app | §18.3 | Done |
| VoiceOver labels, keyboard access, Increase Contrast | §18.5 | Done |
| String Catalogs for the app and for ArchiveKit's messages; locale-aware dates, sizes and plurals | §18.5 | Done |
| `os.Logger` categories: parsing, extraction, preview (never item names or contents) | §18.5 | Done |
| Fuzz target for the directory parser, run in CI | §18.5 | Done |
| Benchmarks for the performance targets, run in CI | §18.5 | Done |
| Safety report banner and sheet: unsafe paths and links, ZIP-bomb indicators, programs, `invoice.pdf.app`-style and right-to-left-override names | §13, Phase 3 | Done |
| SHA-256 on request in the inspector, and Export Checksums (`shasum -a 256 -c` format) | Phase 3 | Done |
| Size Map (treemap, coloured by compression) and a sortable Saved column | Phase 3 | Done |
| Single top-level folder extracted directly; Settings to reveal in Finder and to Trash the archive after extracting all of it | Phase 3 | Done |
| Quick Look extension: Space on a ZIP in Finder lists its contents, with a warning for flagged items | §18.3 | Written, [not yet seen in Finder](#finder-integration) |
| "Browse with QuickZip" in Finder's Services menu; Share button for selected items | §18.3 | Done (Services registration checked; Share not exercised) |
| "Uncompress All" in Finder's context menu: each selected archive extracted into a folder named after it, beside it | New | Written, not yet seen in Finder |
| Image thumbnails in the list, made lazily and optional in Settings | §18.3 | Done |
| New Tab (⌘T), Open Recent, and the last folder shown restored per archive | Phase 4 | Done |
| Password prompt, banner and Archive → Enter Password…; optional Keychain storage | Phase 5 | Done (Keychain not yet exercised end to end) |
| ZIPs inside ZIPs open in a new tab from a temporary copy | Phase 5 | Done |
| Archive → Compare With… an archive or a folder, by path and CRC-32 | Phase 5 | Done |
| tar, `.tar.gz`/`.tgz` and `.tar.xz`/`.txz`: pax, GNU and ustar headers, long names, links; slow opens show progress and can be stopped | §18.4, Phase 6 | Done |
| Apple Archive (`.aar`, raw or compressed) through the AppleArchive framework | §18.4, Phase 6 | Done |
| `.ipa`, `.jar`, `.epub`, `.docx`, `.xlsx`, `.pptx` open read-only | Phase 6 | Done |
| A plain message for 7z, RAR, bzip2 and Zstandard, which need software QuickZip does not include | §18.4 | Done |
| `quickzip` command (list, extract, verify, test-safety, checksum; `--json`), shipped in the app and installable from Settings; [documented](docs/CLI.md) | Phase 7 | Done |
| Shortcuts actions: List Archive Items, Extract Archive, Verify Archive | Phase 7 | Done (compiled and registered; not run from Shortcuts) |
| Developer ID distribution: sandbox, hardened runtime, notarization script | §18.5 | Written, [not yet run](docs/DISTRIBUTION.md) |
| [Landing page](docs/index.html) | New | Done, demo recording still to add |

## Performance

`archivekit-bench` builds its own archives and checks the HLD §18.5 targets
(CI fails if one is missed). On an Apple silicon Mac:

| Scenario | Result | Target |
|---|---|---|
| Open 100,000 entries, to first display (directory, folder tree and search index) | 0.49 s | < 1 s |
| Search 100,000 entries, per keystroke (p99) | 1.1 ms | < 16 ms |
| Read a 10 GiB entry (DEFLATE, CRC-checked), memory growth | 8.8 MiB, at 508 MiB/s | flat |

"First display" is measured in the engine. In the app the same work runs off
the main actor, so the window is never blocked while it happens. The one
exception is an archive with tens of thousands of items in a single folder,
whose table rows are built on the main actor.

```bash
cd ArchiveKit
swift run -c release archivekit-bench --large-gib 10
```

## Opening in Xcode

A fresh clone builds as it is: the bundle identifier is the placeholder
`com.example.QuickZip` and Xcode signs to run locally. To sign with your own
Apple Developer account, copy `Config/Local.xcconfig.example` to
`Config/Local.xcconfig` (ignored by git) and set `BUNDLE_ID_PREFIX` and
`DEVELOPMENT_TEAM`; they override the placeholders in `Config/Base.xcconfig`.
Set your own prefix before distributing a build.

Open `QuickZip.xcodeproj` (Xcode 16 or later). It contains the `QuickZip`
macOS app target and references the local `ArchiveKit` package, so the
engine's sources, its tests (⌘U in the `QuickZip` scheme) and the
`quickzip` command-line tool target all appear in the same window.

The app (`QuickZip/`):

- `BrowserView.swift`: the window, sidebar, file list and status bar
- `InspectorView.swift`: preview pane and item info
- `ArchiveBrowserModel.swift`: per-window state on the main actor; talks only
  to `ArchiveProvider`
- `PreviewCache.swift`: temporary copies of entries for Quick Look
- `QuickLookView.swift`: `QLPreviewView` wrapper
- `ItemExporter.swift`: files for drags, copies and Open, written on demand
- `VerificationSheet.swift`: Verify Archive progress and results
- `SettingsView.swift`: making QuickZip the default app for ZIPs
- `Localizable.xcstrings`, `PrivacyInfo.xcprivacy`
- `../QuickZip-Info.plist`: the ZIP document type, merged into the generated
  Info.plist

Open a ZIP with ⌘O, by dropping it on the window, or from Finder's Open With
menu. Double-click a folder to open it (⌘↑ goes back); double-click a file,
or press ⌘↓, to open a read-only copy in its default application. Selecting
a file previews it in the inspector, and Space opens Quick Look. Drag items
to Finder, or copy them (⌘C) and paste them there; nothing is extracted
until they are dropped or pasted. ⌘E extracts the selection (or the current
folder when nothing is selected) and ⌘⇧E extracts the whole archive into a
new folder. Drop files on the window, or use Add Files… (⌘⇧A), to add them
to the folder being shown; ⌘⌫ deletes the selection from the archive.

The search field searches the folder being shown and everything below it:
words match names, a word containing `/` matches paths, and `*.pdf` or
`ext:pdf` matches extensions. Archive → Verify Archive checks every item
without writing anything. View → Text Encoding changes how names not marked
as UTF-8 are read, and View → Show macOS Metadata Files lists the
`__MACOSX` entries that are otherwise merged into the items they describe.

## Formats

The format is found from the file's first bytes, not its name
(`ArchiveFormat.detect`), then opened by `ArchiveOpener`.

- **Plain tar** is indexed by reading its headers and skipping the data, so it
  opens quickly and nothing is decompressed.
- **Compressed tar and Apple Archive have no directory**, so opening reads the
  whole stream once, in bounded chunks, with progress and a Stop button, and
  spools each item's data to a private temporary file that previews and
  extractions then read directly. The spool never holds more than the archive's
  own contents, is deleted when the window closes, and anything left behind by a
  crash is removed at the next launch. A stream that expands past what
  real compressors produce is refused as it unpacks, before it fills the disk
  (gzip cannot exceed about 1000:1, so only xz and Apple Archive can trip this).
- gzip is decoded by ArchiveKit's own DEFLATE decoder (about 85 MB/s), because
  Compression.framework consumes all its input even after the stream ends and so
  cannot find a gzip trailer or the next member. xz uses the framework.
- Not read: sparse tar files (listed, refused when read), devices and pipes
  (not listed, counted), bzip2 and Zstandard tars, encrypted Apple Archives.
- Only ZIP can be edited. ZIP-based documents open read-only.

## Compatibility

- **Passwords.** One password per archive, checked against the smallest
  encrypted item before it is accepted (AES has a two-byte verifier; ZipCrypto
  a check byte, and small items are read in full, so a checksum settles it).
  The password is held in memory while the archive is open and is never
  logged. "Remember in Keychain" stores it in the login keychain under the
  archive's path; Archive → Forget Saved Password removes it. ZipCrypto is
  weak, and the inspector says so.
- **Formats.** Stored, Deflate, Deflate64 and LZMA. bzip2, zstd, XZ and PPMd are
  still listed with a clear message. `quickzip` takes a password from
  `QUICKZIP_PASSWORD` (or `--password-env`, `--password-file`, `--password-stdin`), so it never appears in `ps`.
- **Nested archives.** Double-click a `.zip` inside an archive. It is extracted
  to a temporary, quarantined, read-only copy and opened as a tab; the copy is
  deleted at the next launch.
- **Compare.** Items match by path (ignoring Unicode normalisation, `__MACOSX`
  and `.DS_Store`) and compare by size and CRC-32 from the directory. Against a
  folder, only files whose size already matches are read. A lone top-level
  folder is ignored on either side when that makes more paths match.

## Finder integration

- **Quick Look** (`QuickZipQuickLook/`) is a data-based preview extension that
  shows `ArchiveListing`'s HTML: a table of up to 3,000 items, with a warning
  count from the safety analysis. It runs in its own sandbox and depends only
  on ArchiveKit. Its code and the listing's escaping are tested, and it
  registers with `pluginkit`, but I could not drive Finder's preview from the
  command line, so look at it once yourself: install the app in /Applications,
  open it once, then press Space on a ZIP. If Finder keeps its own preview,
  run `qlmanage -r` and check System Settings → Login Items & Extensions →
  Quick Look. If that list shows QuickZip more than once (every Xcode build
  and copies in the Trash all register), run `Scripts/unregister.sh --keep /Applications/QuickZip.app`,
  or without `--keep` to remove them all before installing again.
  `--dry-run` lists the copies; `--purge` also deletes settings and saved
  passwords.
- **Services**: select a ZIP in Finder → Services → Browse with QuickZip.
- **Uncompress All**: select one or more archives in Finder, Control-click →
  Quick Actions (or Services) → Uncompress All. `archive.zip` is extracted
  into a new folder `archive` beside it (`archive 2` if that exists), with no
  window. The sandbox does not let QuickZip write beside an archive it was only
  handed, so the first time in each folder it asks for that folder (or one
  above it, such as Downloads or your home folder) and remembers it as a
  security-scoped bookmark. The Settings for revealing the result and
  trashing the archive apply; an archive needing a password not saved in the
  Keychain is offered for opening in the browser instead. If the item is
  missing, enable it in System Settings → Keyboard → Keyboard Shortcuts →
  Services → Files and Folders.
- **Open Recent** is kept by the system. The folder last shown in each of the
  200 most recent archives is remembered in the app's preferences (archive
  path and folder path, nothing else); Open Recent → Clear Menu forgets it.
- **Tabs**: ⌘T opens a new tab. Settings can make every archive open as a tab.

## Engineering

- `swift test` in `ArchiveKit` runs the unit tests, including a short
  deterministic fuzz run. `archivekit-fuzz` runs it for longer:
  `swift run -c release archivekit-fuzz --iterations 1000000 Tests/ArchiveKitTests/Fixtures/*.zip`.
  A crash prints nothing but is repeatable with the seed printed first.
- Logs: `log stream --predicate 'subsystem == "QuickZip.ArchiveKit"' --level debug`.
  Messages hold counts, sizes and error kinds only.
- Strings: Xcode keeps the catalogs up to date as you build. From the command
  line, run `python3 Scripts/sync_strings.py <DerivedData>` afterwards.
  ArchiveKit's technical error details (the reason inside "The archive is
  damaged: …") are English only.
- Building from an iCloud Drive folder can fail code signing with "resource
  fork, Finder information, or similar detritus"; build with
  `--scratch-path` / `-derivedDataPath` outside iCloud.
- Releasing: see [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md).

To run the app on your Mac, pick your team under *Signing & Capabilities*
the first time (or leave it unset to sign to run locally). New files added
to the `QuickZip/` folder are picked up automatically.

## ArchiveKit

```
ArchiveKit/
├── Package.swift
├── Sources/ArchiveKit/
│   ├── ArchiveProvider.swift      format-independent protocol
│   ├── ArchiveEditing.swift       RewritableArchive: add and delete items
│   ├── ArchiveEntry.swift         entry model, CompressionMethod
│   ├── ArchiveTree.swift          folder hierarchy for the UI
│   ├── ArchiveSearchIndex.swift   filename, path and extension search
│   ├── ArchiveVerifier.swift      Verify Archive
│   ├── ArchiveLimits.swift        ZIP-bomb limits
│   ├── ArchiveError.swift         specific, user-facing errors
│   ├── ZIP/                       ZIPArchive actor, ZIP parsing and rewriting
│   ├── Extraction/                ArchiveExtractor, PathSanitizer, Quarantine, AppleDouble
│   └── Utilities/                 bounds-checked BinaryReader, RandomAccessFile
├── Sources/ArchiveKitCLI/         `archivekit` command for exercising the engine
├── Tests/ArchiveKitTests/         unit tests + checked-in fixture archives
└── Scripts/make_fixtures.py       regenerates the fixtures
```

Usage:

```swift
import ArchiveKit

let archive = try await ZIPArchive.open(url)          // reads the directory only
let tree = ArchiveTree(entries: archive.entries)       // folders for the sidebar
let data = try await archive.contents(of: entry)       // one entry, CRC-checked
try await archive.extract(entry, to: destinationURL)   // safe extraction

// A modified copy; the original is never written to.
try await archive.rewrite(
    to: newURL,
    removing: [entry.id],
    adding: [ArchiveAddition(source: fileURL, path: "Folder/file.txt")]
)
```

Build and test (macOS 14+ or Linux with Swift 5.9+):

```sh
swift test --package-path ArchiveKit
swift run --package-path ArchiveKit quickzip list some.zip
```

On Apple platforms DEFLATE goes through Compression.framework. Linux has no
Compression.framework, so there a small built-in inflater is compiled
instead. It exists only so that CI can run the tests on Linux; the app never
uses it. With no encoder there, items added on Linux are stored rather than
deflated. CI runs the tests on both platforms.

### Departures from the HLD sketches

- `ArchiveEntry.id` is the entry's index in the archive, not a `UUID`, so
  it is stable when the same archive is reopened.
- Providers expose a streaming `read(_:into:)`. Extraction is implemented
  once, in `ArchiveExtractor`, for every format, so each new format does not
  need its own path-safety code. `extract(_:to:)` is still available on every
  provider.

## License

QuickZip is released under the [MIT License](LICENSE).
