#!/usr/bin/env python3
"""Generates the ZIP fixtures used by ArchiveKitTests.

The fixtures are checked in; rerun this only to change them:

    python3 Scripts/make_fixtures.py

Most archives are built with a small hand-written ZIP writer so that each
structure (ZIP64 records, flags, extra fields, deliberately broken offsets)
is exactly what the test expects. A few are written with Python's zipfile and
Info-ZIP `zip`, as real-world producers.
"""

import io
import os
import random
import shutil
import struct
import subprocess
import tempfile
import zipfile
import zlib

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Tests", "ArchiveKitTests", "Fixtures")

# 2024-03-15 10:30:00 as MS-DOS date/time.
DOS_TIME = (10 << 11) | (30 << 5) | 0
DOS_DATE = ((2024 - 1980) << 9) | (3 << 5) | 15

UNIX_HOST = 3 << 8


def deflate(data, level=6):
    c = zlib.compressobj(level, zlib.DEFLATED, -15)
    return c.compress(data) + c.flush()


class Entry:
    def __init__(self, name, data=b"", method=8, mode=None, flags=0, is_dir=False,
                 extra=b"", crc=None, usize=None, csize=None, payload=None,
                 raw_method=None, offset=None, made_by=None, zip64=False):
        self.name = name if isinstance(name, bytes) else name.encode("utf-8")
        self.data = data
        self.method = 0 if is_dir else method
        self.mode = mode
        self.flags = flags
        self.is_dir = is_dir
        self.extra = extra
        self.crc = zlib.crc32(data) if crc is None else crc
        self.usize = len(data) if usize is None else usize
        if payload is None:
            payload = deflate(data) if self.method == 8 else data
        self.payload = payload
        self.csize = len(payload) if csize is None else csize
        self.raw_method = self.method if raw_method is None else raw_method
        self.offset_override = offset
        self.made_by = made_by
        self.zip64 = zip64


def build(entries, prefix=b"", force_zip64_eocd=False, cd_override=None, truncate_cd_after=None):
    out = bytearray(prefix)
    # Offsets are relative to the start of the archive proper, so a prefix
    # mimics a self-extracting stub that did not adjust them.
    base = len(prefix)
    records = []
    for e in entries:
        offset = len(out) - base
        local_extra = e.extra
        csize32, usize32 = e.csize, e.usize
        if e.zip64:
            local_extra = struct.pack("<HHQQ", 1, 16, e.usize, e.csize) + local_extra
            csize32 = usize32 = 0xFFFFFFFF
        out += struct.pack("<IHHHHHIIIHH", 0x04034B50, 45 if e.zip64 else 20, e.flags, e.raw_method,
                           DOS_TIME, DOS_DATE, e.crc, csize32, usize32, len(e.name), len(local_extra))
        out += e.name + local_extra + e.payload
        records.append((e, offset if e.offset_override is None else e.offset_override))

    cd = bytearray()
    for e, offset in records:
        if e.mode is not None:
            external = e.mode << 16
            made_by = UNIX_HOST | 30
        else:
            external = 0x10 if e.is_dir else 0
            made_by = 20
        if e.made_by is not None:
            made_by = e.made_by
        extra = e.extra
        usize, csize, off = e.usize, e.csize, offset
        if e.zip64:
            extra = struct.pack("<HHQQQ", 1, 24, e.usize, e.csize, offset) + extra
            usize = csize = off = 0xFFFFFFFF
        cd += struct.pack("<IHHHHHHIIIHHHHHII", 0x02014B50, made_by, 45 if e.zip64 else 20, e.flags,
                          e.raw_method, DOS_TIME, DOS_DATE, e.crc, csize, usize, len(e.name), len(extra),
                          0, 0, 0, external, off)
        cd += e.name + extra
    if cd_override is not None:
        cd = cd_override(cd)

    cd_offset = len(out) - base
    out += cd
    count = len(entries)
    if force_zip64_eocd:
        zip64_offset = len(out) - base
        out += struct.pack("<IQHHIIQQQQ", 0x06064B50, 44, 45, 45, 0, 0, count, count, len(cd), cd_offset)
        out += struct.pack("<IIQI", 0x07064B50, 0, zip64_offset, 1)
        out += struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, 0xFFFF, 0xFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0)
    else:
        out += struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, count, count, len(cd), cd_offset, 0)
    return bytes(out)


def write(name, data):
    with open(os.path.join(OUT, name), "wb") as f:
        f.write(data)


def lorem(n, seed=1):
    rng = random.Random(seed)
    words = ("archive browser finder folder zip deflate central directory entry "
             "compression swift actor quarantine preview extract").split()
    out = []
    size = 0
    while size < n:
        w = rng.choice(words)
        out.append(w)
        size += len(w) + 1
    return (" ".join(out))[:n].encode()


def apple_double(finder_info=b"", attributes=(), resource_fork=b""):
    """An AppleDouble file laid out as macOS copyfile writes it: Finder info
    followed by an extended attribute header, then the resource fork."""
    header_size = 26 + 2 * 12
    attr_header = (header_size + 32 + 3) & ~3
    entries_size = sum((11 + len(name) + 1 + 3) & ~3 for name, _ in attributes)
    data_start = attr_header + 36 + entries_size
    entries, data = bytearray(), bytearray()
    for name, value in attributes:
        raw = name.encode() + b"\0"
        entry = struct.pack(">IIHB", data_start + len(data), len(value), 0, len(raw)) + raw
        entries += entry + b"\0" * (((len(entry) + 3) & ~3) - len(entry))
        data += value
    fork_offset = data_start + len(data)
    total = fork_offset + len(resource_fork)
    out = bytearray(struct.pack(">II16sH", 0x00051607, 0x00020000, b"Mac OS X        ", 2))
    out += struct.pack(">III", 9, header_size, fork_offset - header_size)
    out += struct.pack(">III", 2, fork_offset, len(resource_fork))
    out += finder_info.ljust(32, b"\0") + b"\0" * (attr_header - header_size - 32)
    out += struct.pack(">IIIII12sHH", 0x41545452, 0, total, data_start, len(data), b"", 0, len(attributes))
    out += entries + data + resource_fork
    assert len(out) == total
    return bytes(out)


def make_phase1_fixtures():
    # Legacy name encodings without the UTF-8 flag, as Windows Explorer
    # writes them on Japanese, Chinese and Russian systems.
    write("shift_jis.zip", build([
        Entry("日本語/".encode("shift_jis"), is_dir=True),
        Entry("日本語/テスト.txt".encode("shift_jis"), b"sjis"),
        Entry("報告書.txt".encode("shift_jis"), b"kanji"),
    ]))
    write("gbk.zip", build([
        Entry("文件/".encode("gbk"), is_dir=True),
        Entry("文件/报告.txt".encode("gbk"), b"gbk"),
        Entry("说明.txt".encode("gbk"), b"gbk"),
    ]))
    write("cp866.zip", build([
        Entry("Документы/".encode("cp866"), is_dir=True),
        Entry("Документы/Отчёт.txt".encode("cp866"), b"cp866"),
        Entry("readme.txt", b"ascii"),
    ]))

    # macOS metadata in __MACOSX AppleDouble entries, as Archive Utility
    # writes it: a Finder tag and comment, a resource fork, and a quarantine
    # attribute that must not be applied.
    tags = b"bplist00\xa1\x01UGreen\n\x08\x0a\x00\x00\x00\x00\x00\x00\x01\x01\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x10"
    file_metadata = apple_double(
        finder_info=b"TEXTttxt",
        attributes=[
            ("com.apple.metadata:_kMDItemUserTags", tags),
            ("com.apple.quarantine", b"0081;00000000;Evil;"),
            ("org.example.note", b"kept"),
        ],
        resource_fork=b"resource fork bytes",
    )
    folder_metadata = apple_double(attributes=[("org.example.folder", b"folder note")])
    write("macos_metadata.zip", build([
        Entry("Folder/", is_dir=True, mode=0o040755),
        Entry("Folder/file.txt", b"contents", mode=0o100644),
        Entry("Folder/plain.txt", b"no metadata", mode=0o100644),
        Entry("__MACOSX/", is_dir=True, mode=0o040755),
        Entry("__MACOSX/Folder/", is_dir=True, mode=0o040755),
        Entry("__MACOSX/Folder/._file.txt", file_metadata, mode=0o100644),
        Entry("__MACOSX/._Folder", folder_metadata, mode=0o100644),
    ]))


def main():
    os.makedirs(OUT, exist_ok=True)
    for f in os.listdir(OUT):
        if f.endswith(".zip"):
            os.remove(os.path.join(OUT, f))

    hello = b"Hello, world!\n"
    text = lorem(300_000)

    # A typical archive: folders, stored and deflated files, an empty file,
    # an executable and a setuid file.
    write("basic.zip", build([
        Entry("Holiday/", is_dir=True, mode=0o040755),
        Entry("Holiday/Photos/", is_dir=True, mode=0o040700),
        Entry("Holiday/notes.txt", hello, method=8, mode=0o100644),
        Entry("Holiday/Photos/beach.txt", b"sand " * 100, method=8, mode=0o100644),
        Entry("Holiday/stored.txt", b"not compressed\n", method=0, mode=0o100600),
        Entry("Holiday/empty.txt", b"", method=0, mode=0o100644),
        Entry("Holiday/run.sh", b"#!/bin/sh\necho hi\n", method=8, mode=0o100755),
        Entry("Holiday/setuid", b"x", method=0, mode=0o104755),
        Entry("Holiday/big.txt", text, method=8, mode=0o100644),
        Entry("README", b"top level\n", method=8, mode=0o100644),
    ]))

    # No explicit directory entries: folders must be synthesised.
    write("implicit_dirs.zip", build([
        Entry("a/b/c.txt", b"c"),
        Entry("a/d.txt", b"d"),
        Entry("e.txt", b"e"),
    ]))

    # ZIP64: per-entry extended information and ZIP64 end records.
    write("zip64.zip", build([
        Entry("one.txt", hello, zip64=True),
        Entry("dir/two.txt", b"two" * 1000, method=0, zip64=True),
    ], force_zip64_eocd=True))

    # Python's zipfile writing to an unseekable stream uses data descriptors.
    class Unseekable(io.RawIOBase):
        def __init__(self):
            self.buf = bytearray()

        def writable(self):
            return True

        def write(self, b):
            self.buf += b
            return len(b)

    stream = Unseekable()
    with zipfile.ZipFile(stream, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("streamed.txt", text[:5000])
        zf.writestr("second.txt", hello)
    write("data_descriptor.zip", bytes(stream.buf))

    # Names: UTF-8 flag, CP437 without the flag, and an Info-ZIP Unicode Path
    # extra field overriding a CP437 name.
    unicode_name = "Ünïcødé/日本語.txt".encode("utf-8")
    raw_cp437 = "café.txt".encode("cp437")
    upath = struct.pack("<BI", 1, zlib.crc32(b"plain.txt")) + "naïve.txt".encode("utf-8")
    write("names.zip", build([
        Entry(unicode_name, b"utf8", flags=0x0800),
        Entry(raw_cp437, b"cp437"),
        Entry(b"plain.txt", b"upath", extra=struct.pack("<HH", 0x7075, len(upath)) + upath),
        Entry("Shift/" .encode() + "テスト.txt".encode("shift_jis"), b"sjis"),
        Entry(b"win\\path\\file.txt", b"backslashes"),
    ]))

    # Path traversal attempts alongside a safe entry.
    write("traversal.zip", build([
        Entry("../../evil.txt", b"evil"),
        Entry("/absolute.txt", b"evil"),
        Entry("safe/../../escape.txt", b"evil"),
        Entry("C:/windows.txt", b"evil"),
        Entry("good.txt", b"good"),
    ]))

    # Symlinks: one escaping the destination, then a file written "through"
    # it; one contained.
    write("symlinks.zip", build([
        Entry("escape", b"../../../../tmp", method=0, mode=0o120777),
        Entry("escape/pwned.txt", b"pwned"),
        Entry("dir/", is_dir=True, mode=0o040755),
        Entry("dir/target.txt", b"target"),
        Entry("dir/link", b"target.txt", method=0, mode=0o120777),
        Entry("absolute-link", b"/etc/passwd", method=0, mode=0o120777),
    ]))

    # Encryption flag (ZipCrypto) and WinZip AES (method 99).
    aes_extra = struct.pack("<HHHBBBH", 0x9901, 7, 2, ord("A"), ord("E"), 3, 8)
    write("encrypted.zip", build([
        Entry("secret.txt", b"x" * 12, method=0, flags=0x0001, payload=bytes(range(24)), csize=24),
        Entry("aes.txt", b"x", raw_method=99, flags=0x0001, extra=aes_extra, payload=bytes(range(40)), csize=40),
        Entry("public.txt", hello),
    ]))

    # Methods Compression.framework cannot decode.
    write("unsupported_methods.zip", build([
        Entry("deflate64.bin", b"x", raw_method=9, payload=b"\x00" * 8, csize=8),
        Entry("bzip2.bin", b"x", raw_method=12, payload=b"\x00" * 8, csize=8),
        Entry("zstd.bin", b"x", raw_method=93, payload=b"\x00" * 8, csize=8),
        Entry("ok.txt", hello),
    ]))

    # A wrong CRC on otherwise valid data.
    write("bad_crc.zip", build([
        Entry("good.txt", hello),
        Entry("bad.txt", hello, crc=0xDEADBEEF),
    ]))

    # The directory's third record is damaged: the first two survive.
    def damage_third(cd):
        cd = bytearray(cd)
        index = -1
        for _ in range(3):
            index = cd.index(b"PK\x01\x02", index + 1)
        cd[index:index + 4] = b"XXXX"
        return bytes(cd)

    write("damaged_directory.zip", build([
        Entry("first.txt", b"1"),
        Entry("second.txt", b"2"),
        Entry("third.txt", b"3"),
        Entry("fourth.txt", b"4"),
    ], cd_override=damage_third))

    # A download cut off part way through: no directory at all.
    full = build([
        Entry("one.txt", hello),
        Entry("two.txt", text[:20000]),
        Entry("three.txt", text),
    ])
    write("truncated.zip", full[:len(full) * 2 // 3])

    # A self-extracting stub in front of an archive whose offsets ignore it.
    write("prefixed.zip", build([
        Entry("inside.txt", hello),
        Entry("folder/more.txt", b"more"),
    ], prefix=b"#!/bin/sh\necho 'self-extracting stub'\nexit 0\n" + b"\x00" * 100))

    # A declared size far beyond what the data produces.
    write("lying_size.zip", build([
        Entry("bomb.txt", b"a" * 1000, usize=1 << 41, zip64=True),
        Entry("short.txt", b"a" * 1000, usize=10),
    ]))

    # Two directory records pointing at the same data (overlapping bomb).
    entries = [Entry("a.txt", b"a" * 1000), Entry("b.txt", b"a" * 1000, offset=0)]
    write("overlapping.zip", build(entries))

    # Offsets pointing outside the file.
    write("bad_offset.zip", build([Entry("far.txt", hello, offset=10_000_000)]))

    # Large highly compressible entry, exercising many output chunks.
    write("zeros.zip", build([Entry("zeros.bin", b"\x00" * (16 << 20))]))

    # Mixed incompressible + compressible data (stored and dynamic blocks).
    rng = random.Random(7)
    mixed = bytes(rng.getrandbits(8) for _ in range(200_000)) + text
    write("mixed.zip", build([Entry("mixed.bin", mixed)]))

    # An empty archive.
    write("empty.zip", build([]))

    # Real-world producers.
    with zipfile.ZipFile(os.path.join(OUT, "python_zipfile.zip"), "w", compression=zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("py/hello.txt", hello)
        zf.writestr(zipfile.ZipInfo("py/folder/"), b"")
        zf.writestr("py/text.txt", text[:50000])

    if shutil.which("zip"):
        with tempfile.TemporaryDirectory() as tmp:
            root = os.path.join(tmp, "Project")
            os.makedirs(os.path.join(root, "src"))
            with open(os.path.join(root, "src", "main.c"), "wb") as f:
                f.write(b"int main(void) { return 0; }\n")
            with open(os.path.join(root, "build.sh"), "wb") as f:
                f.write(b"#!/bin/sh\ncc src/main.c\n")
            os.chmod(os.path.join(root, "build.sh"), 0o755)
            os.symlink("src/main.c", os.path.join(root, "main-link.c"))
            for path in [os.path.join(root, "src", "main.c"), os.path.join(root, "build.sh"), os.path.join(root, "src"), root]:
                os.utime(path, (1700000000, 1700000000), follow_symlinks=False)
            subprocess.run(["zip", "-q", "-r", "-y", "-X", os.path.join(OUT, "infozip.zip"), "Project"], cwd=tmp, check=True)


PASSWORD = b"secret"


def phase5_text():
    """Deterministic, compressible and not too repetitive."""
    rng = random.Random(5)
    words = ["archive", "folder", "password", "secret", "zip", "entry", "stream", "window", "symbol", "block"]
    return " ".join(rng.choice(words) + str(rng.randrange(1000)) for _ in range(20000)).encode()


def make_phase5_fixtures():
    """Encrypted and LZMA archives from independent writers.

    ZipCrypto comes from Info-ZIP `zip`; WinZip AES from `pyzipper` (run this
    with a Python that has it: `python3 -m venv v && v/bin/pip install pyzipper`);
    LZMA from Python's zipfile. The password is "secret" throughout.
    """
    text = phase5_text()
    rng = random.Random(11)
    noise = bytes(rng.getrandbits(8) for _ in range(5000))
    contents = {
        "hello.txt": b"Hello, encrypted world!\n",
        "big.txt": text,
        "folder/random.bin": noise,
    }

    if shutil.which("zip"):
        with tempfile.TemporaryDirectory() as tmp:
            os.makedirs(os.path.join(tmp, "folder"))
            for name, data in contents.items():
                with open(os.path.join(tmp, name), "wb") as f:
                    f.write(data)
            out = os.path.join(OUT, "zipcrypto.zip")
            if os.path.exists(out):
                os.remove(out)
            subprocess.run(["zip", "-q", "-X", "-P", PASSWORD.decode(), out, "hello.txt", "big.txt", "folder/random.bin"],
                           cwd=tmp, check=True)
            # Streamed from standard input: sizes follow the data (flag bit 3),
            # so the check byte comes from the time rather than the CRC.
            out = os.path.join(OUT, "zipcrypto_stream.zip")
            if os.path.exists(out):
                os.remove(out)
            with open(os.path.join(tmp, "big.txt"), "rb") as f:
                subprocess.run(["zip", "-q", "-P", PASSWORD.decode(), out, "-"], stdin=f, cwd=tmp, check=True)

    try:
        import pyzipper
    except ImportError:
        print("pyzipper not installed; skipping the AES fixtures")
    else:
        for bits in (128, 192, 256):
            with pyzipper.AESZipFile(os.path.join(OUT, f"aes{bits}.zip"), "w", compression=pyzipper.ZIP_DEFLATED,
                                     encryption=pyzipper.WZ_AES) as zf:
                zf.setpassword(PASSWORD)
                zf.setencryption(pyzipper.WZ_AES, nbits=bits)
                for name, data in contents.items():
                    zf.writestr(name, data)
                zf.writestr("empty.txt", b"")
        # Stored (no compression) and a plain entry beside the encrypted ones.
        with pyzipper.AESZipFile(os.path.join(OUT, "aes_stored.zip"), "w", compression=pyzipper.ZIP_STORED,
                                 encryption=pyzipper.WZ_AES) as zf:
            zf.setpassword(PASSWORD)
            zf.setencryption(pyzipper.WZ_AES, nbits=256)
            zf.writestr("stored.txt", contents["hello.txt"])

        # AE-1 keeps the CRC-32 that AE-2 leaves out: patch an AE-2 archive's
        # version and CRC fields in the local and central headers.
        with open(os.path.join(OUT, "aes128.zip"), "rb") as f:
            data = bytearray(f.read())
        crcs = {name: zlib.crc32(content) for name, content in contents.items()}
        crcs["empty.txt"] = 0
        pos = 0
        while True:
            pos = data.find(b"PK\x03\x04", pos)
            if pos < 0:
                break
            name_len, extra_len = struct.unpack_from("<HH", data, pos + 26)
            name = bytes(data[pos + 30:pos + 30 + name_len]).decode()
            struct.pack_into("<I", data, pos + 14, crcs[name])
            extra = pos + 30 + name_len
            data[extra + 4] = 1  # vendor version 1
            pos += 30
        pos = 0
        while True:
            pos = data.find(b"PK\x01\x02", pos)
            if pos < 0:
                break
            name_len, extra_len = struct.unpack_from("<HHH", data, pos + 28)[:2]
            name = bytes(data[pos + 46:pos + 46 + name_len]).decode()
            struct.pack_into("<I", data, pos + 16, crcs[name])
            data[pos + 46 + name_len + 4] = 1
            pos += 46
        with open(os.path.join(OUT, "aes_ae1.zip"), "wb") as f:
            f.write(data)

    with zipfile.ZipFile(os.path.join(OUT, "lzma.zip"), "w", compression=zipfile.ZIP_LZMA) as zf:
        zf.writestr("big.txt", text)
        zf.writestr("hello.txt", contents["hello.txt"])
        zf.writestr("folder/random.bin", noise)
        zf.writestr("one.txt", b"x")
        zf.writestr("empty.txt", b"")
        zf.writestr("large.txt", text * 40)


def phase6_tree():
    """(path, data, mode) in the order they are archived; paths ending in / are folders."""
    text = phase5_text()
    long_dir = "/".join(["a" * 40, "b" * 40, "c" * 40])
    return [
        ("docs/", None, 0o755),
        ("docs/readme.md", b"# Readme\n" + b"Some words about the archive.\n" * 60, 0o644),
        ("docs/big.txt", text, 0o644),
        ("bin/", None, 0o755),
        ("bin/run.sh", b"#!/bin/sh\necho run\n", 0o755),
        ("hello.txt", b"Hello, tar!\n", 0o644),
        ("empty.txt", b"", 0o644),
        (long_dir + "/file.txt", b"a long path\n", 0o644),
        ("\u00dcn\u00efc\u00f8d\u00e9/\u65e5\u672c\u8a9e.txt", b"unicode names\n", 0o644),
    ]


def make_phase6_fixtures():
    """tar, tar.gz, tar.xz and Apple Archive fixtures, from Python's tarfile,
    gzip and lzma, and from the system's tar, xz and aa."""
    import gzip
    import io
    import lzma
    import tarfile

    tree = phase6_tree()

    def build_tar(fmt, extra=True):
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode="w", format=fmt) as tf:
            for path, data, mode in tree:
                info = tarfile.TarInfo(path.rstrip("/"))
                info.mtime = 1700000000
                info.mode = mode
                if data is None:
                    info.type = tarfile.DIRTYPE
                    tf.addfile(info)
                else:
                    info.size = len(data)
                    tf.addfile(info, io.BytesIO(data))
            if extra:
                link = tarfile.TarInfo("link-to-hello")
                link.type = tarfile.SYMTYPE
                link.linkname = "hello.txt"
                link.mtime = 1700000000
                tf.addfile(link)
                hard = tarfile.TarInfo("hard-hello.txt")
                hard.type = tarfile.LNKTYPE
                hard.linkname = "hello.txt"
                hard.mtime = 1700000000
                tf.addfile(hard)
        return buffer.getvalue()

    def write_bytes(name, data):
        with open(os.path.join(OUT, name), "wb") as f:
            f.write(data)

    pax = build_tar(tarfile.PAX_FORMAT)
    write_bytes("pax.tar", pax)
    write_bytes("gnu.tar", build_tar(tarfile.GNU_FORMAT))
    write_bytes("ustar.tar", build_tar(tarfile.USTAR_FORMAT))

    # Compressed.
    def gz(data, **kw):
        out = io.BytesIO()
        with gzip.GzipFile(fileobj=out, mode="wb", mtime=0, **kw) as f:
            f.write(data)
        return out.getvalue()

    write_bytes("pax.tar.gz", gz(pax))
    half = len(pax) // 2
    write_bytes("multi.tar.gz", gz(pax[:half]) + gz(pax[half:]))
    write_bytes("pax.tar.xz", lzma.compress(pax, format=lzma.FORMAT_XZ, check=lzma.CHECK_CRC64))
    if shutil.which("xz"):
        with tempfile.TemporaryDirectory() as tmp:
            src = os.path.join(tmp, "blocks.tar")
            with open(src, "wb") as f:
                f.write(pax)
            subprocess.run(["xz", "-k", "-T2", "--block-size=65536", "--check=sha256", src], check=True)
            shutil.copy(src + ".xz", os.path.join(OUT, "blocks.tar.xz"))

    # What the system's tar makes, with ./ names.
    with tempfile.TemporaryDirectory() as tmp:
        root = os.path.join(tmp, "Project")
        for path, data, mode in tree:
            target = os.path.join(root, path)
            if data is None:
                os.makedirs(target, exist_ok=True)
            else:
                os.makedirs(os.path.dirname(target), exist_ok=True)
                with open(target, "wb") as f:
                    f.write(data)
                os.chmod(target, mode)
        os.symlink("hello.txt", os.path.join(root, "link-to-hello"))
        env = dict(os.environ, COPYFILE_DISABLE="1")
        subprocess.run(["tar", "-cf", os.path.join(OUT, "bsd.tar"), "-C", root, "."], check=True, env=env)
        subprocess.run(["tar", "-czf", os.path.join(OUT, "bsd.tar.gz"), "-C", root, "."], check=True, env=env)
        if shutil.which("aa"):
            for name, args in [("default", []), ("raw", ["-a", "raw"]), ("lzma", ["-a", "lzma"])]:
                out = os.path.join(OUT, f"{name}.aar")
                if os.path.exists(out):
                    os.remove(out)
                subprocess.run(["aa", "archive", "-d", root, *args, "-o", out], check=True)

    # Damaged and unusual.
    write_bytes("truncated.tar", pax[: len(pax) * 6 // 10])
    damaged = bytearray(pax)
    damaged[512 * 6 + 148] ^= 0x01     # a header checksum, a few entries in
    write_bytes("badheader.tar", bytes(damaged))
    write_bytes("truncated.tar.gz", gz(pax)[: len(gz(pax)) // 2])
    write_bytes("notatar.gz", gz(b"just some text, not a tar archive\n" * 100))
    write_bytes("empty.tar", b"\0" * 1024)

    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", format=tarfile.PAX_FORMAT) as tf:
        for name, kind in [("pipe", tarfile.FIFOTYPE), ("device", tarfile.CHRTYPE)]:
            info = tarfile.TarInfo(name)
            info.type = kind
            tf.addfile(info)
        info = tarfile.TarInfo("kept.txt")
        info.size = 4
        tf.addfile(info, io.BytesIO(b"kept"))
    write_bytes("special.tar", buffer.getvalue())

    # Formats that are recognised and not read.
    write_bytes("fake.7z", bytes([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0, 4]) + b"\0" * 64)
    write_bytes("fake.rar", b"Rar!\x1a\x07\x01\x00" + b"\0" * 64)
    write_bytes("fake.bz2", b"BZh9" + b"\x31\x41\x59\x26\x53\x59" + b"\0" * 32)


if __name__ == "__main__":
    main()
    make_phase1_fixtures()
    make_phase5_fixtures()
    make_phase6_fixtures()
