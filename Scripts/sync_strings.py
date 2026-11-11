#!/usr/bin/env python3
"""Merges the strings the compiler extracted into the String Catalogs.

Xcode's IDE does this on every build; `xcodebuild` and `swift build` do
not, so run this after building from the command line:

    xcodebuild -scheme QuickZip -derivedDataPath /tmp/dd build
    python3 Scripts/sync_strings.py /tmp/dd

New keys are added with their source text; keys no longer in the source
are marked stale (Xcode offers to delete them). Translations already in a
catalog are never touched. Strings that need English plural forms are
listed in PLURALS below.
"""

import glob
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

CATALOGS = {
    os.path.join(ROOT, "QuickZip") + os.sep: os.path.join(ROOT, "QuickZip", "Localizable.xcstrings"),
    os.path.join(ROOT, "QuickZipQuickLook") + os.sep: os.path.join(ROOT, "QuickZipQuickLook", "Localizable.xcstrings"),
    os.path.join(ROOT, "ArchiveKit", "Sources", "ArchiveKit") + os.sep:
        os.path.join(ROOT, "ArchiveKit", "Sources", "ArchiveKit", "Resources", "Localizable.xcstrings"),
}

# English plural forms, keyed on the first number in the string.
PLURALS = {
    "%lld items": ("%lld item", "%lld items"),
    "%lld matches": ("%lld match", "%lld matches"),
    "%lld files": ("%lld file", "%lld files"),
    "%lld files decompressed with the expected size and checksum.":
        ("%lld file decompressed with the expected size and checksum.",
         "%lld files decompressed with the expected size and checksum."),
    "%lld items are damaged.": ("%lld item is damaged.", "%lld items are damaged."),
    "%lld items couldn’t be checked.": ("%lld item couldn’t be checked.", "%lld items couldn’t be checked."),
    "%lld items won’t be extracted because they’re unsafe.":
        ("%lld item won’t be extracted because it’s unsafe.", "%lld items won’t be extracted because they’re unsafe."),
    "%lld items are programs or have misleading names.":
        ("%lld item is a program or has a misleading name.", "%lld items are programs or have misleading names."),
    "Extracted %lld items": ("Extracted %lld item", "Extracted %lld items"),
    "%lld items to be careful with": ("%lld item to be careful with", "%lld items to be careful with"),
    "…and %lld more items": ("…and %lld more item", "…and %lld more items"),
    "%lld items are password-protected.": ("%lld item is password-protected.", "%lld items are password-protected."),
    "%lld items are the same.": ("%lld item is the same.", "%lld items are the same."),
    "%lld devices, pipes or other special files are not shown.": ("%lld device, pipe or other special file is not shown.", "%lld devices, pipes or other special files are not shown."),
    "The archive is damaged after %lld items; the rest cannot be listed.": ("The archive is damaged after %lld item; the rest cannot be listed.", "The archive is damaged after %lld items; the rest cannot be listed."),
    "The compressed data is damaged after %lld items; the rest cannot be listed.": ("The compressed data is damaged after %lld item; the rest cannot be listed.", "The compressed data is damaged after %lld items; the rest cannot be listed."),
    "Found %lld items.": ("Found %lld item.", "Found %lld items."),
    "Extracted %lld items.": ("Extracted %lld item.", "Extracted %lld items."),
    "Nothing is damaged: %lld items checked.": ("Nothing is damaged: %lld item checked.", "Nothing is damaged: %lld items checked."),
    "%lld items are not in the list": ("%lld item is not in the list", "%lld items are not in the list"),
}


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def main(derived_data):
    found = {path: {} for path in CATALOGS.values()}
    for data_file in glob.glob(os.path.join(derived_data, "**", "*.stringsdata"), recursive=True):
        with open(data_file) as handle:
            data = json.load(handle)
        source = data.get("source", "")
        catalog = next((c for prefix, c in CATALOGS.items() if source.startswith(prefix)), None)
        if catalog is None:
            continue
        for entry in data.get("tables", {}).get("Localizable", []):
            found[catalog].setdefault(entry["key"], entry.get("comment", ""))

    for path, keys in found.items():
        with open(path) as handle:
            catalog = json.load(handle)
        strings = catalog.setdefault("strings", {})
        added = 0
        for key, comment in keys.items():
            if key not in strings:
                strings[key] = {"extractionState": "extracted_with_value"}
                added += 1
            entry = strings[key]
            if entry.get("extractionState") == "stale":
                entry["extractionState"] = "extracted_with_value"
            if comment and "comment" not in entry:
                entry["comment"] = comment
            if key in PLURALS and "localizations" not in entry:
                one, other = PLURALS[key]
                entry["localizations"] = {"en": {"variations": {"plural": {"one": unit(one), "other": unit(other)}}}}
        stale = 0
        for key, entry in strings.items():
            if key not in keys and entry.get("extractionState") != "manual":
                entry["extractionState"] = "stale"
                stale += 1
        catalog["strings"] = dict(sorted(strings.items()))
        with open(path, "w") as handle:
            json.dump(catalog, handle, indent=2, ensure_ascii=False, sort_keys=False)
            handle.write("\n")
        print(f"{os.path.relpath(path, ROOT)}: {len(keys)} strings, {added} added, {stale} stale")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
