#!/usr/bin/env python3
"""Lucid Engine build tool.

Builds Vivid's media engine libraries (libdovi, dav1d, libass, FFmpeg and
libmpv) from pinned upstream sources plus Vivid's patch series, packages them
as static xcframeworks and writes a provenance report. Everything else the
engine links comes from the interim prebuilt binaries pinned in pins.ini.

    python3 engine/lucid.py check-allowlist
    python3 engine/lucid.py fetch
    python3 engine/lucid.py build --slice tvos-arm64
    python3 engine/lucid.py check --slice tvos-arm64
    python3 engine/lucid.py test --slice tvos-arm64
    python3 engine/lucid.py package --input DIR --out DIR
    python3 engine/lucid.py test-libdovi

Needs Python 3.9 or later (standard library only), the Xcode command-line
tools and pkg-config. Building is meant for CI; see
docs/cores/lucid-engine-build.md.
"""

from __future__ import annotations

import argparse
import configparser
import datetime
import hashlib
import importlib.util
import json
import os
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit

ENGINE = Path(__file__).resolve().parent
REPO = ENGINE.parent
WORKFLOW = REPO / ".github" / "workflows" / "lucid-engine.yml"
CONFIG = ENGINE / "config"
PATCHES = ENGINE / "patches"

# Install prefix recorded in the binaries and pkg-config files. Files are
# staged with DESTDIR, so no build machine path ends up in the configuration
# strings.
PREFIX = "/lucid-engine"

# Every download must start with one of these (scheme, host and project).
FETCH_ALLOWED = (
    "https://github.com/FFmpeg/",
    "https://github.com/mpv-player/",
    "https://github.com/libass/",
    "https://github.com/videolan/",
    "https://github.com/mesonbuild/",
    "https://github.com/ninja-build/",
    "https://github.com/mpvkit/",  # interim prebuilt release assets only
    "https://github.com/quietvoid/",  # libdovi (dovi_tool) source
    "https://github.com/lu-zero/",  # cargo-c release binary
    "https://static.rust-lang.org/dist/",  # Rust toolchain components
    "https://static.crates.io/crates/",  # crates in libdovi's Cargo.lock
)
# Hosts that may appear in references (upstream homes, patch descriptions).
REFERENCE_HOSTS = {"github.com", "code.videolan.org", "gitlab.freedesktop.org", "trac.ffmpeg.org"}
# Projects nothing here may reference. Split so this file does not match itself.
DENIED = ("edde" "746",)
FETCH_WORDS = re.compile(r"\b(curl|wget|urlopen|urlretrieve|git clone|git fetch)\b")

# Values today's frameworks carry (facts 4.1). Kept for parity; the bundle
# identifier prefix and version are open questions (facts 6, item 5).
PLIST_ID_PREFIX = "com.mpvkit."
PLIST_VERSION = "87.88.520"
PLIST_MINIMUM_OS = "100.0"  # see facts 1.7 (ITMS-90208)

FFMPEG_LIBS = ("avcodec", "avdevice", "avfilter", "avformat", "avutil", "swresample", "swscale")
# Non-public FFmpeg headers today's frameworks also ship (facts 2.2, edit 2).
FFMPEG_EXTRA_HEADERS = {
    "avutil": ("getenv_utf8.h", "libm.h", "thread.h", "intmath.h", "mem_internal.h",
               "attributes_internal.h", "internal.h"),
    "avcodec": ("mathops.h",),
    "avformat": ("os_support.h",),
}
FFMPEG_CONFIG_H = ("avutil", "avcodec", "avformat")
HEADER_COUNTS = {"Libavcodec": 26, "Libavdevice": 3, "Libavfilter": 5, "Libavformat": 6,
                 "Libavutil": 109, "Libswresample": 3, "Libswscale": 3}
# Module map exclusions exactly as today (facts 4.1). hwcontext_amf.h,
# hwcontext_drm.h, hwcontext_mediacodec.h and hwcontext_oh.h are still not
# excluded, so `import Libavutil` fails as it does today.
MODULE_EXCLUDES = {
    "Libavcodec": ("xvmc.h", "vdpau.h", "qsv.h", "dxva2.h", "d3d11va.h", "d3d12va.h"),
    "Libavutil": ("hwcontext_vulkan.h", "hwcontext_vdpau.h", "hwcontext_vaapi.h",
                  "hwcontext_qsv.h", "hwcontext_opencl.h", "hwcontext_dxva2.h",
                  "hwcontext_d3d11va.h", "hwcontext_d3d12va.h", "hwcontext_cuda.h"),
}
BUILD_ORDER = ("libdovi", "dav1d", "libass", "ffmpeg", "mpv")
BUILT_FRAMEWORKS = {"Libdovi", "Libdav1d", "Libass", "Libmpv"} | {f"Lib{ff}" for ff in FFMPEG_LIBS}
CRATES_URL = "https://static.crates.io/crates/{name}/{name}-{version}.crate"
CRATES_IO = "registry+https://github.com/rust-lang/crates.io-index"
HOST_RUST_TARGET = "aarch64-apple-darwin"
# libdovi's C API, as today's prebuilt exports it (facts 2.7).
LIBDOVI_API = {
    "_dovi_convert_rpu_with_mode", "_dovi_data_free", "_dovi_parse_itu_t35_dovi_metadata_obu",
    "_dovi_parse_rpu", "_dovi_parse_rpu_bin_file", "_dovi_parse_unspec62_nalu", "_dovi_rpu_free",
    "_dovi_rpu_free_data_mapping", "_dovi_rpu_free_header", "_dovi_rpu_free_vdr_dm_data",
    "_dovi_rpu_get_data_mapping", "_dovi_rpu_get_error", "_dovi_rpu_get_header",
    "_dovi_rpu_get_vdr_dm_data", "_dovi_rpu_list_free", "_dovi_rpu_remove_mapping",
    "_dovi_rpu_set_active_area_offsets", "_dovi_write_av1_rpu_metadata_obu_t35_complete",
    "_dovi_write_av1_rpu_metadata_obu_t35_payload", "_dovi_write_rpu", "_dovi_write_unspec62_nalu",
}
OPENSSL_SYMBOL = re.compile(
    r"^_(SSL_|TLS_|DTLS_|OPENSSL_|OpenSSL_|EVP_|X509_|BIO_|ERR_|CRYPTO_|PEM_|RAND_|HMAC_)")
MPV_PATCH_MARKER = b"Still waiting for TrueHD major sync"  # from mpv patch 0001

# Dolby Vision decoding (ffmpeg 0010 to 0012, mpv 0040; patch spec 5, 6.1,
# 6.6 and 8.6). libdovi's pkg-config name, the references Libavcodec must
# have once the Dolby Vision patch is in (pristine FFmpeg has none of them),
# the two hevcdec messages logged at verbose, and mpv 0040's recovery line.
LIBDOVI_PC = "dovi"
DOVI_LIBAVCODEC_REFERENCES = (
    "_dovi_parse_unspec62_nalu", "_dovi_convert_rpu_with_mode", "_dovi_write_unspec62_nalu",
    "_kVTDecompressionPropertyKey_PropagatePerFrameHDRDisplayMetadata",
    "_kVTDecompressionPropertyKey_GeneratePerFrameHDRDisplayMetadata",
)
HEVCDEC_VERBOSE_MESSAGES = (
    r"Multiple Dolby Vision RPUs found in one AU. Skipping previous.\n",
    r"Skipping NAL unit %d\n",
)
MPV_HWDEC_RECOVERY_MARKER = b"Hardware decoder produced a frame again after %d decode failure%s."
# Substrings Vivid's adapter records as faults (patch spec 2.8); no message
# the decoder patches add may contain one.
FAULT_SUBSTRINGS = ("Too many packets", "queue overflow", "EOF", "End of file", "timed out",
                    "Connection reset", "Error decoding", "Invalid data")
# Patch numbers that belong to the decoder work, per library.
DECODER_PATCHES = {"ffmpeg": range(10, 30), "mpv": range(40, 50)}
# Host-side decoder tests (patch spec 9.4, 8.6 item 5), built from the
# patched FFmpeg tree by `lucid.py test`.
DECODER_TESTS = ENGINE / "tests" / "ffmpeg"
HOST_TEST_TARGET = "arm64-apple-macos12.0"


@dataclass(frozen=True)
class Slice:
    name: str            # xcframework library identifier Xcode derives
    sdk: str             # xcrun SDK
    target: str          # clang -target, {v} = minimum OS
    min_flag: str        # version-min flag, {v} = minimum OS
    subsystem: str       # meson host_machine subsystem
    prebuilt: str        # platform folder inside the prebuilt -all.zip files
    moltenvk: str        # slice inside MoltenVK.xcframework
    plist_platform: str  # CFBundleSupportedPlatforms
    macho_platform: int  # LC_BUILD_VERSION platform
    tvos: bool
    rust_target: str     # Rust target triple for libdovi
    version_min_cmd: str  # older load command naming the platform (device slices)


SLICES = {s.name: s for s in (
    Slice("ios-arm64", "iphoneos", "arm64-apple-ios{v}", "-mios-version-min={v}",
          "ios", "ios", "ios-arm64", "iPhoneOS", 2, False,
          "aarch64-apple-ios", "LC_VERSION_MIN_IPHONEOS"),
    Slice("ios-arm64-simulator", "iphonesimulator", "arm64-apple-ios{v}-simulator",
          "-mios-simulator-version-min={v}", "ios-simulator", "isimulator",
          "ios-arm64_x86_64-simulator", "iPhoneSimulator", 7, False,
          "aarch64-apple-ios-sim", ""),
    Slice("tvos-arm64", "appletvos", "arm64-apple-tvos{v}", "-mtvos-version-min={v}",
          "tvos", "tvos", "tvos-arm64_arm64e", "AppleTVOS", 3, True,
          "aarch64-apple-tvos", "LC_VERSION_MIN_TVOS"),
    Slice("tvos-arm64-simulator", "appletvsimulator", "arm64-apple-tvos{v}-simulator",
          "-mtvos-simulator-version-min={v}", "tvos-simulator", "tvsimulator",
          "tvos-arm64_x86_64-simulator", "AppleTVSimulator", 8, True,
          "aarch64-apple-tvos-sim", ""),
)}


class Failure(Exception):
    pass


# ------------------------------------------------------------------ helpers

def log(msg: str) -> None:
    print(msg, flush=True)


def run(cmd, cwd=None, env=None, logfile: Path | None = None, capture=False) -> str:
    """Run a command, streaming its output (and copying it to logfile)."""
    cmd = [str(c) for c in cmd]
    log(f"$ {shlex.join(cmd)}" + (f"   (in {cwd})" if cwd else ""))
    if capture:
        res = subprocess.run(cmd, cwd=cwd, env=env, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True)
        if res.returncode != 0:
            raise Failure(f"command failed ({res.returncode}): {shlex.join(cmd)}\n{res.stderr}")
        return res.stdout
    out = open(logfile, "a") if logfile else None
    try:
        proc = subprocess.Popen(cmd, cwd=cwd, env=env, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, errors="replace")
        for line in proc.stdout:
            sys.stdout.write(line)
            if out:
                out.write(line)
        proc.wait()
    finally:
        if out:
            out.close()
    if proc.returncode != 0:
        raise Failure(f"command failed ({proc.returncode}): {shlex.join(cmd)}")
    return ""


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def read_list(path: Path) -> list[str]:
    """Non-empty, non-comment lines; each line may hold several words."""
    words = []
    for line in path.read_text().splitlines():
        words.extend(re.sub(r"(^|\s)#.*$", "", line).split())
    return words


def read_sections(path: Path) -> dict[str, list[str]]:
    """`[name]` sections of whitespace-separated words, `#` comments."""
    sections: dict[str, list[str]] = {}
    current = None
    for line in path.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        m = re.fullmatch(r"\[([\w-]+)\]", line)
        if m:
            current = sections.setdefault(m.group(1), [])
        elif current is not None:
            current.extend(line.split())
    return sections


def load_pins() -> configparser.ConfigParser:
    pins = configparser.ConfigParser(interpolation=None)
    pins.read(ENGINE / "pins.ini")
    return pins


def pin_sections(pins, kind: str) -> list[str]:
    return [s for s in pins.sections() if s.startswith(kind + ":")]


def download_name(section: str, url: str) -> str:
    return section.replace(":", "-") + "-" + Path(urlsplit(url).path).name


def default_dir(env: str, leaf: str) -> Path:
    if os.environ.get(env):
        return Path(os.environ[env])
    base = os.environ.get("RUNNER_TEMP") or tempfile.gettempdir()
    return Path(base) / leaf


def inside_git_repo(path: Path) -> Path | None:
    for parent in [path, *path.parents]:
        if (parent / ".git").exists():
            return parent
    return None


def tree_files(root: Path) -> dict[str, str]:
    """Map of relative path to content hash (plus exec bit or link target)."""
    files = {}
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in filenames + [d for d in dirnames if os.path.islink(os.path.join(dirpath, d))]:
            p = Path(dirpath) / name
            rel = p.relative_to(root).as_posix()
            if p.is_symlink():
                files[rel] = "link:" + os.readlink(p)
            else:
                mode = "x" if os.access(p, os.X_OK) else "-"
                files[rel] = mode + sha256_file(p)
    return files


def tree_digest(files: dict[str, str]) -> str:
    h = hashlib.sha256()
    for rel in sorted(files):
        h.update(f"{rel}\0{files[rel]}\n".encode())
    return h.hexdigest()


def read_series(lib: str) -> list[tuple[str, Path]]:
    """The library's patch series, each patch verified against its SHA-256."""
    series = []
    for line in (PATCHES / lib / "series").read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        digest, name = line.split(None, 1)
        path = PATCHES / lib / name
        actual = sha256_file(path)
        if actual != digest:
            raise Failure(f"patch {lib}/{name}: SHA-256 {actual}, series says {digest}")
        series.append((digest, path))
    return series


def patch_paths(patch: Path) -> set[str]:
    """Files a patch touches, from its ---/+++ headers (-p1)."""
    paths = set()
    old = None
    for line in patch.read_text(errors="replace").splitlines():
        m = re.match(r"^--- (\S+)", line)
        if m:
            old = m.group(1)
            continue
        m = re.match(r"^\+\+\+ (\S+)", line)
        if m and old is not None:
            new = m.group(1)
            path = old if new == "/dev/null" else new
            paths.add(path.split("/", 1)[1])
            old = None
    return paths


def apply_series(lib: str, src: Path, logfile: Path | None = None) -> list[dict]:
    applied = []
    for digest, patch in read_series(lib):
        run(["patch", "-p1", "-F0", "-N", "-t", "-i", patch], cwd=src, logfile=logfile)
        applied.append({"file": f"{lib}/{patch.name}", "sha256": digest})
    leftovers = list(src.rglob("*.rej"))
    if leftovers:
        raise Failure(f"{lib}: patch left {', '.join(str(p) for p in leftovers)}")
    return applied


def extract_tar(archive: Path, dest: Path) -> None:
    """Extract a .tar.gz or .tar.xz without its top-level folder."""
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)
    run(["tar", "-xf", archive, "-C", dest, "--strip-components", "1"])


def archive_commit(archive: Path) -> str:
    with tarfile.open(archive) as tar:
        tar.next()
        return tar.pax_headers.get("comment", "")


# --------------------------------------------------------------- Rust parts

def archive_member(archive: Path, rel: str) -> bytes:
    """A file from a source archive, by its path below the top-level folder."""
    with tarfile.open(archive) as tar:
        for member in tar:
            parts = member.name.split("/", 1)
            if len(parts) == 2 and parts[1] == rel and member.isfile():
                return tar.extractfile(member).read()
    raise Failure(f"{archive.name}: no {rel}")


def parse_cargo_lock(text: str) -> list[dict]:
    """The [[package]] entries of a Cargo.lock (name, version, source, checksum)."""
    packages = []
    for chunk in text.split("[[package]]")[1:]:
        entry = {}
        for key in ("name", "version", "source", "checksum"):
            m = re.search(rf'^{key} = "([^"]*)"$', chunk, re.M)
            if m:
                entry[key] = m.group(1)
        packages.append(entry)
    return packages


def locked_crates(pins, downloads: Path) -> list[dict]:
    """Every crates.io package in libdovi's Cargo.lock, after checking the
    lock file against its pinned SHA-256. The lock file's checksum for each
    crate is the SHA-256 of its .crate file."""
    pin = pins["source:libdovi"]
    archive = downloads / download_name("source:libdovi", pin["url"])
    lock = archive_member(archive, pin["crate"] + "/Cargo.lock")
    digest = hashlib.sha256(lock).hexdigest()
    if digest != pin["cargo_lock_sha256"]:
        raise Failure(f"libdovi Cargo.lock: SHA-256 {digest}, pinned {pin['cargo_lock_sha256']}")
    crates = []
    for entry in parse_cargo_lock(lock.decode()):
        if "source" not in entry:
            continue  # the crate itself
        if entry["source"] != CRATES_IO or not re.fullmatch(r"[0-9a-f]{64}", entry.get("checksum", "")):
            raise Failure(f"libdovi Cargo.lock: {entry.get('name')} is not a checksummed crates.io package")
        crates.append({**entry, "url": CRATES_URL.format(**entry),
                       "file": f"{entry['name']}-{entry['version']}.crate"})
    return crates


def install_rust(pins, downloads: Path, prefix: Path, targets: list[str]) -> dict:
    """Install the pinned rustc, cargo and standard libraries (the host's and
    each target's) into prefix, from the dist tarballs, without rustup."""
    if prefix.exists():
        shutil.rmtree(prefix)
    prefix.mkdir(parents=True)
    sections = ["rust:rustc", "rust:cargo"] + [f"rust:std-{t}" for t in [HOST_RUST_TARGET] + targets]
    with tempfile.TemporaryDirectory(dir=prefix.parent) as tmp:
        for section in sections:
            if section not in pins:
                raise Failure(f"pins.ini has no [{section}]")
            unpacked = Path(tmp) / section.replace(":", "-")
            extract_tar(downloads / download_name(section, pins[section]["url"]), unpacked)
            for component in (unpacked / "components").read_text().split():
                src = unpacked / component
                for item in src.iterdir():
                    if item.name == "manifest.in":
                        continue
                    if item.is_dir():
                        shutil.copytree(item, prefix / item.name, symlinks=True, dirs_exist_ok=True)
                    else:
                        shutil.copy2(item, prefix / item.name)
    rustc = run([prefix / "bin" / "rustc", "-V"], capture=True).strip()
    expected = "rustc " + pins["rust:rustc"]["version"]
    if rustc != expected:
        raise Failure(f"installed {rustc!r}, pinned {expected!r}")
    installed = sorted(p.name for p in (prefix / "lib" / "rustlib").iterdir()
                       if (p / "lib").is_dir())
    return {"rustc": rustc, "cargo": run([prefix / "bin" / "cargo", "-V"], capture=True).strip(),
            "std_targets": installed}


def install_cargo_c(pins, downloads: Path, bindir: Path) -> str:
    pin = pins["tool:cargo-c"]
    bindir.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(downloads / download_name("tool:cargo-c", pin["url"])) as z:
        for name in ("cargo-capi", "cargo-cbuild", "cargo-cinstall", "cargo-ctest"):
            (bindir / name).write_bytes(z.read(name))
            (bindir / name).chmod(0o755)
    return run([bindir / "cargo-cinstall", "cinstall", "--version"], capture=True).strip()


def vendor_crates(pins, downloads: Path, dest: Path) -> list[dict]:
    """A Cargo directory source holding every locked crate, so the build runs
    offline (`--frozen`) from the verified downloads."""
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)
    crates = locked_crates(pins, downloads)
    for crate in crates:
        archive = downloads / "crates" / crate["file"]
        if sha256_file(archive) != crate["checksum"]:
            raise Failure(f"{archive.name}: SHA-256 differs from Cargo.lock")
        target = dest / f"{crate['name']}-{crate['version']}"
        extract_tar(archive, target)
        (target / ".cargo-checksum.json").write_text(
            json.dumps({"files": {}, "package": crate["checksum"]}))
    return crates


def cargo_env(rust: Path, cargo_bin: Path, cargo_home: Path, vendor: Path, remaps: dict) -> dict:
    """Environment for cargo-c: the pinned toolchain only, offline, with the
    vendored crates replacing crates.io."""
    cargo_home.mkdir(parents=True, exist_ok=True)
    (cargo_home / "config.toml").write_text(
        '[source.crates-io]\nreplace-with = "lucid-vendored"\n\n'
        f'[source.lucid-vendored]\ndirectory = {json.dumps(str(vendor))}\n\n'
        "[net]\noffline = true\n")
    env = {k: os.environ[k] for k in ("HOME", "USER", "LOGNAME", "TMPDIR", "DEVELOPER_DIR")
           if k in os.environ}
    env["PATH"] = os.pathsep.join([str(rust / "bin"), str(cargo_bin), "/usr/bin", "/bin",
                                   "/usr/sbin", "/sbin"])
    env.update({"LC_ALL": "C", "CARGO_HOME": str(cargo_home), "RUSTC": str(rust / "bin" / "rustc"),
                "CARGO": str(rust / "bin" / "cargo"), "CARGO_INCREMENTAL": "0",
                "CARGO_TERM_COLOR": "never", "ZERO_AR_DATE": "1"})
    # Keep build-machine paths out of the panic locations Rust records. The
    # encoded form (separated by 0x1f) allows spaces in paths.
    env["CARGO_ENCODED_RUSTFLAGS"] = "\x1f".join(
        f"--remap-path-prefix={src}={dst}" for src, dst in remaps.items())
    return env


def cargo_cinstall(crate_dir: Path, target: str, install: Path, target_dir: Path, env: dict,
                   rust: Path, logfile: Path | None = None) -> Path:
    """Build and stage libdovi; returns the static library, its embedded
    bitcode removed."""
    run([env["CARGO"], "cinstall", "--release", "--frozen", "--library-type=staticlib",
         f"--target={target}", f"--prefix={PREFIX}", f"--destdir={install}", "--libdir=lib",
         "--includedir=include", "--pkgconfigdir=lib/pkgconfig", f"--target-dir={target_dir}",
         f"--manifest-path={crate_dir / 'Cargo.toml'}"], cwd=crate_dir, env=env, logfile=logfile)
    library = install / PREFIX.lstrip("/") / "lib" / "libdovi.a"
    strip_embedded_bitcode(rust, library, logfile)
    return library


def strip_embedded_bitcode(rust: Path, archive: Path, logfile: Path | None = None) -> None:
    """Rust's prebuilt standard library objects carry LLVM bitcode (the
    __LLVM segment) for cross-crate LTO, written by a newer LLVM than
    Xcode's nm and linker read. Remove it with the pinned toolchain's own
    rust-objcopy; the machine code is unchanged."""
    objcopy = rust / "lib" / "rustlib" / HOST_RUST_TARGET / "bin" / "rust-objcopy"
    env = {**os.environ, "DYLD_LIBRARY_PATH": str(rust / "lib")}
    stripped = archive.with_name(archive.name + ".stripped")
    run([objcopy, "--remove-section=__LLVM,__bitcode", "--remove-section=__LLVM,__cmdline",
         archive, stripped], env=env, logfile=logfile)
    stripped.replace(archive)


def sdk_path(sdk: str) -> Path:
    return Path(run(["xcrun", "--sdk", sdk, "--show-sdk-path"], capture=True).strip())


def xcrun_find(sdk: str, tool: str) -> str:
    return run(["xcrun", "--sdk", sdk, "--find", tool], capture=True).strip()


def compile_flags(sl: Slice, sdk: Path, minimum_os: str) -> list[str]:
    """CFLAGS, CPPFLAGS, CXXFLAGS and ASMFLAGS for every library (facts 2.0)."""
    flags = ["-arch", "arm64", "-isysroot", str(sdk), "-target", sl.target.format(v=minimum_os),
             sl.min_flag.format(v=minimum_os)]
    if sl.tvos:
        flags.append("-DHAVE_FORK=0")
    if any(" " in f for f in flags):
        raise Failure(f"flags must not contain spaces: {flags}")
    return flags


def nm_symbols(archive: Path, undefined: bool) -> set[str]:
    args = ["nm", "-arch", "arm64", "-u", "-j"] if undefined else ["nm", "-arch", "arm64", "-g", "-U", "-j"]
    out = run(args + [archive], capture=True)
    return {s.strip() for s in out.splitlines() if s.strip().startswith("_")}


def ffmpeg_configuration(args: list[str]) -> str:
    """The FFMPEG_CONFIGURATION string configure records for these arguments."""
    def sh_quote(v: str) -> str:
        v = v.replace("'", "'\\''")
        return v if re.fullmatch(r"[A-Za-z0-9_/.+-]*", v) else f"'{v}'"
    parts = []
    for a in args:
        r = a.split("=", 1)[1] if "=" in a else a
        parts.append(a[: len(a) - len(r)] + sh_quote(r))
    return " ".join(parts)


def define(path: Path, name: str) -> str | None:
    m = re.search(rf"^#define {re.escape(name)} (.*)$", path.read_text(errors="replace"), re.M)
    return m.group(1).strip() if m else None


def c_string(value: str | None) -> str | None:
    if value is None:
        return None
    return value[1:-1].replace('\\"', '"').replace("\\\\", "\\")


# ---------------------------------------------------------------- allowlist

def cmd_check_allowlist(args) -> None:
    files = sorted(p for p in ENGINE.rglob("*") if p.is_file() and "__pycache__" not in p.parts)
    files.append(WORKFLOW)
    problems = []
    url_re = re.compile(r"https?://[^\s'\"<>()\[\]`]+")
    for path in files:
        rel = path.relative_to(REPO)
        text = path.read_text(errors="replace")
        for term in DENIED:
            if term in text.lower():
                problems.append(f"{rel}: references {term}")
        for url in url_re.findall(text):
            host = urlsplit(url).hostname or ""
            if host not in REFERENCE_HOSTS and not url.startswith(FETCH_ALLOWED):
                problems.append(f"{rel}: URL on a host that is not allowlisted: {url}")
        lines = text.splitlines()
        in_download = False
        for n, line in enumerate(lines, 1):
            if path.name == "lucid.py":
                if line.startswith("def "):
                    in_download = line.startswith("def download(")
                if in_download or line.lstrip().startswith(("FETCH_WORDS", "#")):
                    continue
            elif path.suffix == ".patch":
                continue
            if FETCH_WORDS.search(line):
                problems.append(f"{rel}:{n}: fetches outside lucid.py download(): {line.strip()}")
    pins = load_pins()
    for section in pins.sections():
        for key in ("url", "xcframework_url"):
            url = pins[section].get(key)
            if url and not url.startswith(FETCH_ALLOWED):
                problems.append(f"pins.ini [{section}] {key}: not an allowlisted project: {url}")
            if url and not pins[section].get(key.replace("url", "sha256")):
                problems.append(f"pins.ini [{section}] {key}: no SHA-256")
    for n, line in enumerate(WORKFLOW.read_text().splitlines(), 1):
        m = re.search(r"uses:\s*(\S+)", line)
        if m and not re.fullmatch(r"[\w.-]+(/[\w.-]+)+@[0-9a-f]{40}", m.group(1)):
            problems.append(f"{WORKFLOW.relative_to(REPO)}:{n}: action not pinned by commit SHA")
    if problems:
        raise Failure("allowlist check failed:\n  " + "\n  ".join(problems))
    log(f"Allowlist check passed: {len(files)} files, every fetch is pinned and allowlisted.")


# -------------------------------------------------------------------- fetch

def download(url: str, sha256: str, dest: Path) -> None:
    """The only network access: curl over HTTPS, then a SHA-256 check."""
    if not url.startswith(FETCH_ALLOWED):
        raise Failure(f"refusing to download from a project that is not allowlisted: {url}")
    if dest.exists() and sha256_file(dest) == sha256:
        log(f"cached  {dest.name}")
        return
    part = dest.with_suffix(dest.suffix + ".part")
    run(["curl", "--fail", "--location", "--silent", "--show-error", "--retry", "3",
         "--retry-delay", "5", "--proto", "=https", "--proto-redir", "=https",
         "--output", part, url])
    actual = sha256_file(part)
    if actual != sha256:
        part.unlink()
        raise Failure(f"{url}: SHA-256 {actual}, pinned {sha256}")
    part.rename(dest)
    log(f"fetched {dest.name}")


def cmd_fetch(args) -> None:
    pins = load_pins()
    args.downloads.mkdir(parents=True, exist_ok=True)
    only = tuple(args.only.split(",")) if args.only else ()
    for section in pins.sections():
        pin = pins[section]
        if "url" not in pin or (only and not section.startswith(only)):
            continue
        dest = args.downloads / download_name(section, pin["url"])
        download(pin["url"], pin["sha256"], dest)
        if section.startswith("source:"):
            commit = archive_commit(dest)
            if commit != pin["commit"]:
                raise Failure(f"{dest.name}: archive commit {commit}, pinned {pin['commit']}")
    if not only or "source:libdovi".startswith(only):
        crates = locked_crates(pins, args.downloads)
        (args.downloads / "crates").mkdir(exist_ok=True)
        for crate in crates:
            download(crate["url"], crate["checksum"], args.downloads / "crates" / crate["file"])
        log(f"{len(crates)} crates from libdovi's Cargo.lock present and verified.")
    log("All pinned inputs present and verified.")


# -------------------------------------------------------------------- build

@dataclass
class Ctx:
    sl: Slice
    pins: configparser.ConfigParser
    downloads: Path
    root: Path        # work root shared by all slices
    work: Path        # this slice's work directory
    out: Path         # this slice's output directory
    sdk: Path
    flags: list[str]
    env: dict
    meson: list[str]
    ninja: str
    pkg_config: str
    rust: Path | None = None      # pinned Rust toolchain prefix
    cargo_c: Path | None = None   # directory holding the cargo-c binaries

    @property
    def install(self) -> Path:
        return self.work / "install"

    @property
    def prefix(self) -> Path:
        return self.install / PREFIX.lstrip("/")

    @property
    def pc_dirs(self) -> list[Path]:
        return [self.work / "pkgconfig", self.prefix / "lib" / "pkgconfig"]

    def src(self, lib: str) -> Path:
        return self.work / "src" / lib

    def build(self, lib: str) -> Path:
        return self.work / "build" / lib

    def logfile(self, name: str) -> Path:
        return self.out / "logs" / f"{name}.log"


def prepare_tools(pins, downloads: Path, root: Path) -> tuple[list[str], str, str, Path]:
    tools = root / "tools"
    bindir = tools / "bin"
    if tools.exists():
        shutil.rmtree(tools)
    bindir.mkdir(parents=True)
    meson_pin = pins["tool:meson"]
    extract_tar(downloads / download_name("tool:meson", meson_pin["url"]), tools / "meson")
    with zipfile.ZipFile(downloads / download_name("tool:ninja", pins["tool:ninja"]["url"])) as z:
        (bindir / "ninja").write_bytes(z.read("ninja"))
    (bindir / "ninja").chmod(0o755)
    host_pkg_config = shutil.which("pkg-config")
    if not host_pkg_config:
        raise Failure("pkg-config is required (the CI runner image provides pkgconf)")
    (bindir / "pkg-config").symlink_to(host_pkg_config)
    python = "/usr/bin/python3"  # Xcode's Python runs meson and mpv's build scripts
    return [python, str(tools / "meson" / "meson.py")], str(bindir / "ninja"), \
        str(bindir / "pkg-config"), bindir


def build_env(ctx_root: Path, bindir: Path, flags: list[str], pc_dirs: list[Path],
              source_date_epoch: str) -> dict:
    env = {k: os.environ[k] for k in ("HOME", "USER", "LOGNAME", "TMPDIR", "DEVELOPER_DIR")
           if k in os.environ}
    # Xcode's tools first, so `gcc` (FFmpeg's default compiler) is Apple clang.
    env["PATH"] = os.pathsep.join([str(bindir), "/usr/bin", "/bin", "/usr/sbin", "/sbin"])
    env["LC_ALL"] = "C"
    # Reproducible archives: ar, ranlib and libtool write zero timestamps, and
    # clang's __DATE__ and __TIME__ (mpv's build date) come from this date.
    env["ZERO_AR_DATE"] = "1"
    env["SOURCE_DATE_EPOCH"] = source_date_epoch
    env["CC"] = "/usr/bin/clang"
    env["CXX"] = "/usr/bin/clang++"
    joined = " ".join(flags)
    for var in ("CFLAGS", "CPPFLAGS", "CXXFLAGS", "ASMFLAGS"):
        env[var] = joined
    env["LDFLAGS"] = "-lc++ " + joined
    env["PKG_CONFIG_LIBDIR"] = os.pathsep.join(str(p) for p in pc_dirs)
    # Stop FFmpeg's and mpv's version scripts from finding any enclosing repo.
    env["GIT_CEILING_DIRECTORIES"] = str(ctx_root.parent)
    return env


def stage_prebuilt(ctx: Ctx) -> list[dict]:
    """Unpack this slice's headers, static libraries and pkg-config files."""
    staged = []
    pc_dir = ctx.work / "pkgconfig"
    pc_dir.mkdir(parents=True, exist_ok=True)
    sl = ctx.sl
    for section in pin_sections(ctx.pins, "prebuilt"):
        name = section.split(":", 1)[1]
        pin = ctx.pins[section]
        archive = ctx.downloads / download_name(section, pin["url"])
        dest = ctx.work / "deps" / name
        lib_prefix = f"lib/{sl.prebuilt}/thin/arm64/lib/"
        moltenvk_lib = f"lib/MoltenVK.xcframework/{sl.moltenvk}/libMoltenVK.a"
        pc_prefix = f"pkgconfig-example/{sl.prebuilt}/arm64/"
        libs, pcs = [], []
        with zipfile.ZipFile(archive) as z:
            for info in z.infolist():
                n = info.filename
                if info.is_dir() or ".." in Path(n).parts or n.startswith("/"):
                    continue
                if n.startswith("include/"):
                    target = dest / n
                elif n.startswith(lib_prefix) and n.endswith(".a") or n == moltenvk_lib:
                    target = dest / "lib" / Path(n).name
                    libs.append(target.name)
                elif n.startswith(pc_prefix) and n.endswith(".pc"):
                    text = z.read(n).decode()
                    text = re.sub(r"/path/to/workdir/[^/\s]+/[^/\s]+/thin/[^/\s]+", str(dest), text)
                    if "/path/to/workdir" in text:
                        raise Failure(f"{section}: unexpected path in {n}")
                    (pc_dir / Path(n).name).write_text(text)
                    pcs.append(Path(n).name)
                    continue
                else:
                    continue
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(z.read(n))
        if not libs or not pcs:
            raise Failure(f"{section}: nothing staged for {sl.name} (libraries {libs}, pc {pcs})")
        for lib in libs:
            path = dest / "lib" / lib
            archs = run(["lipo", "-archs", path], capture=True).split()
            if archs != ["arm64"]:
                if "arm64" not in archs:
                    raise Failure(f"{section}: {lib} has no arm64 ({archs})")
                thin = path.with_name(path.name + ".thin")
                run(["lipo", path, "-thin", "arm64", "-output", thin])
                thin.replace(path)
        staged.append({"name": name, "archive": archive.name, "sha256": pin["sha256"],
                       "libraries": sorted(libs), "pkgconfig": sorted(pcs)})
    write_system_pc(ctx.sdk, pc_dir)
    return staged


def write_system_pc(sdk: Path, pc_dir: Path) -> None:
    """pkg-config files for the SDK's zlib and libxml2 (FFmpeg, FreeType, libbluray)."""
    zlib = c_string(define(sdk / "usr/include/zlib.h", "ZLIB_VERSION"))
    xml = c_string(define(sdk / "usr/include/libxml2/libxml/xmlversion.h", "LIBXML_DOTTED_VERSION"))
    if not zlib or not xml:
        raise Failure(f"could not read the zlib or libxml2 version from {sdk}")
    (pc_dir / "zlib.pc").write_text(
        f"Name: zlib\nDescription: zlib from the SDK\nVersion: {zlib}\nLibs: -lz\nCflags:\n")
    (pc_dir / "libxml-2.0.pc").write_text(
        f"Name: libXML\nDescription: libxml2 from the SDK\nVersion: {xml}\n"
        "Libs: -lxml2\nLibs.private: -lz -lpthread -licucore -lm\n"
        f"Cflags: -I{sdk}/usr/include/libxml2\n")


def prepare_source(ctx: Ctx, lib: str) -> dict:
    """Extract the pristine archive and apply the patch series, checking that
    exactly the files the series names have changed."""
    section = f"source:{lib}"
    pin = ctx.pins[section]
    archive = ctx.downloads / download_name(section, pin["url"])
    src = ctx.src(lib)
    extract_tar(archive, src)
    pristine = tree_files(src)
    applied = apply_series(lib, src, ctx.logfile(f"{lib}-patch"))
    patched = tree_files(src)
    changed = sorted(p for p in set(pristine) | set(patched) if pristine.get(p) != patched.get(p))
    declared = sorted(set().union(*[patch_paths(PATCHES / p["file"]) for p in applied]))
    if changed != declared:
        raise Failure(f"{lib}: changed files {changed} differ from the series' files {declared}")
    return {"version": pin["version"], "commit": pin["commit"], "url": pin["url"],
            "archive": archive.name, "sha256": sha256_file(archive),
            "archive_commit": archive_commit(archive), "patches": applied,
            "pristine_tree": tree_digest(pristine), "patched_tree": tree_digest(patched),
            "changed_files": changed}


def write_cross_file(ctx: Ctx, path: Path, ndebug: bool) -> None:
    def arr(items):
        return "[" + ", ".join(repr(str(i)) for i in items) + "]"
    lines = [
        "[binaries]",
        "c = '/usr/bin/clang'",
        "cpp = '/usr/bin/clang++'",
        "objc = '/usr/bin/clang'",
        "objcpp = '/usr/bin/clang++'",
        f"ar = {xcrun_find(ctx.sl.sdk, 'ar')!r}",
        f"strip = {xcrun_find(ctx.sl.sdk, 'strip')!r}",
        f"pkg-config = {ctx.pkg_config!r}",
        "",
        "[host_machine]",
        "system = 'darwin'",
        f"subsystem = {ctx.sl.subsystem!r}",
        "kernel = 'xnu'",
        "cpu_family = 'aarch64'",
        "cpu = 'arm64'",
        "endian = 'little'",
        "",
        "[properties]",
        f"pkg_config_libdir = {arr(ctx.pc_dirs)}",
        "needs_exe_wrapper = true",
        "",
        "[built-in options]",
        f"prefix = {PREFIX!r}",
        "buildtype = 'release'",
        "default_library = 'static'",
    ]
    if ndebug:
        lines.append("b_ndebug = 'true'")
    for lang in ("c", "cpp", "objc", "objcpp"):
        lines.append(f"{lang}_args = {arr(ctx.flags)}")
        lines.append(f"{lang}_link_args = {arr(['-lc++'] + ctx.flags)}")
    path.write_text("\n".join(lines) + "\n")


def rewrite_installed_pc(ctx: Ctx) -> None:
    """Point the installed pkg-config files at the staged prefix."""
    for pc in (ctx.prefix / "lib" / "pkgconfig").glob("*.pc"):
        text = pc.read_text()
        text = re.sub(rf"(^|[=\s]|-I|-L){re.escape(PREFIX)}(?=/|\s|$)",
                      lambda m: m.group(1) + str(ctx.prefix), text, flags=re.M)
        pc.write_text(text)


def build_meson(ctx: Ctx, lib: str, options: list[str], ndebug: bool) -> None:
    cross = ctx.work / f"cross-{lib}.ini"
    write_cross_file(ctx, cross, ndebug)
    env = {k: v for k, v in ctx.env.items()
           if k not in ("CC", "CXX", "CFLAGS", "CPPFLAGS", "CXXFLAGS", "ASMFLAGS", "LDFLAGS")}
    logfile = ctx.logfile(lib)
    build = ctx.build(lib)
    try:
        # Relative cross file, so mpv's recorded configuration has no machine path.
        run(ctx.meson + ["setup", build, ctx.src(lib), f"--cross-file={cross.name}"] + options,
            cwd=ctx.work, env=env, logfile=logfile)
        # -k 0 reports every failing file in one run, not just the first.
        run([ctx.ninja, "-C", build, "-k", "0"], env=env, logfile=logfile)
        run(ctx.meson + ["install", "-C", build, "--destdir", ctx.install, "--no-rebuild"],
            env=env, logfile=logfile)
    finally:
        meson_log = build / "meson-logs" / "meson-log.txt"
        if meson_log.exists():
            shutil.copy2(meson_log, ctx.out / "logs" / f"{lib}-meson-log.txt")
    rewrite_installed_pc(ctx)


def libdovi_flags(pkg_config: str, env: dict) -> dict:
    """libdovi's include path and -ldovi for FFmpeg (patch spec 5.6, 8.4).

    FFmpeg's configure has no libdovi switch, so the Dolby Vision patch
    (ffmpeg 0011) gets libdovi through the compiler and linker flags. The
    flags come from the dovi.pc that the slice's libdovi build installed."""
    def query(*opts):
        return run([pkg_config, *opts, LIBDOVI_PC], env=env, capture=True).split()
    cflags = query("--cflags-only-I")
    ldflags = query("--libs-only-L") + ["-ldovi"]
    includes = [Path(f[2:]) for f in cflags if f.startswith("-I")]
    if not any((d / "libdovi" / "rpu_parser.h").is_file() for d in includes):
        raise Failure(f"libdovi/rpu_parser.h not found through {LIBDOVI_PC}.pc ({cflags})")
    if any(" " in f for f in cflags + ldflags):
        raise Failure(f"libdovi flags must not contain spaces: {cflags + ldflags}")
    return {"cflags": cflags, "ldflags": ldflags}


def build_ffmpeg(ctx: Ctx, dovi: dict) -> list[str]:
    args = [f"--prefix={PREFIX}"] + read_list(CONFIG / "ffmpeg-configure.txt")
    build = ctx.build("ffmpeg")
    build.mkdir(parents=True, exist_ok=True)
    logfile = ctx.logfile("ffmpeg")
    jobs = f"-j{os.cpu_count() or 4}"
    # libdovi reaches FFmpeg only through its compiler and linker flags, so
    # the configure line, and with it avformat_configuration(), is unchanged.
    env = dict(ctx.env)
    env["CFLAGS"] = " ".join([env["CFLAGS"]] + dovi["cflags"])
    env["LDFLAGS"] = " ".join([env["LDFLAGS"]] + dovi["ldflags"])
    try:
        run([ctx.src("ffmpeg") / "configure"] + args, cwd=build, env=env, logfile=logfile)
        run(["make", jobs], cwd=build, env=env, logfile=logfile)
        run(["make", "install", f"DESTDIR={ctx.install}"], cwd=build, env=env, logfile=logfile)
    finally:
        config_log = build / "ffbuild" / "config.log"
        if config_log.exists():
            shutil.copy2(config_log, ctx.out / "logs" / "ffmpeg-config.log")
    rewrite_installed_pc(ctx)
    return args


def build_libdovi(ctx: Ctx) -> dict:
    """libdovi's C library (the dolby_vision crate) with cargo-c, as a static
    library, from the patched source and the vendored, locked crates."""
    pin = ctx.pins["source:libdovi"]
    crate_dir = ctx.src("libdovi") / pin["crate"]
    lock = sha256_file(crate_dir / "Cargo.lock")
    if lock != pin["cargo_lock_sha256"]:
        raise Failure(f"libdovi Cargo.lock: SHA-256 {lock}, pinned {pin['cargo_lock_sha256']}")
    vendor = ctx.work / "vendor"
    crates = vendor_crates(ctx.pins, ctx.downloads, vendor)
    env = cargo_env(ctx.rust, ctx.cargo_c, ctx.work / "cargo-home", vendor,
                    {ctx.src("libdovi"): "/lucid-engine/src/libdovi",
                     vendor: "/lucid-engine/vendor"})
    env["SOURCE_DATE_EPOCH"] = ctx.env["SOURCE_DATE_EPOCH"]
    env["TVOS_DEPLOYMENT_TARGET" if ctx.sl.tvos else "IPHONEOS_DEPLOYMENT_TARGET"] = \
        ctx.pins["toolchain"]["minimum_os"]
    cargo_cinstall(crate_dir, ctx.sl.rust_target, ctx.install, ctx.build("libdovi"), env,
                   ctx.rust, ctx.logfile("libdovi"))
    rewrite_installed_pc(ctx)
    return {"rust_target": ctx.sl.rust_target, "cargo_lock_sha256": lock,
            "crates": [f"{c['name']} {c['version']}" for c in crates],
            "rustflags": env["CARGO_ENCODED_RUSTFLAGS"].split("\x1f")}


def make_framework(ctx: Ctx, name: str, library: Path, headers: list[tuple[Path, str]]) -> dict:
    fw = ctx.out / "frameworks" / f"{name}.framework"
    (fw / "Headers").mkdir(parents=True)
    (fw / "Modules").mkdir()
    shutil.copy2(library, fw / name)
    for src, rel in headers:
        dest = fw / "Headers" / rel
        if src.is_dir():
            shutil.copytree(src, dest)
        else:
            shutil.copy2(src, dest)
    excludes = "".join(f'    exclude header "{h}"\n' for h in MODULE_EXCLUDES.get(name, ()))
    (fw / "Modules" / "module.modulemap").write_text(
        f'framework module {name} [system] {{\n    umbrella "."\n{excludes}    export *\n}}\n')
    plist = {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleExecutable": name,
        "CFBundleIdentifier": PLIST_ID_PREFIX + name.replace("_", "-"),
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": name,
        "CFBundlePackageType": "FMWK",
        "CFBundleShortVersionString": PLIST_VERSION,
        "CFBundleSignature": "????",
        "CFBundleSupportedPlatforms": [ctx.sl.plist_platform],
        "CFBundleVersion": PLIST_VERSION,
        "MinimumOSVersion": PLIST_MINIMUM_OS,
        "NSPrincipalClass": "",
    }
    with open(fw / "Info.plist", "wb") as f:
        plistlib.dump(plist, f, sort_keys=True)
    count = sum(1 for p in (fw / "Headers").rglob("*") if p.is_file())
    return {"name": name, "binary_sha256": sha256_file(fw / name), "headers": count}


def package_frameworks(ctx: Ctx) -> list[dict]:
    inc = ctx.prefix / "include"
    lib = ctx.prefix / "lib"
    made = [
        make_framework(ctx, "Libdovi", lib / "libdovi.a",
                       [(inc / "libdovi" / "rpu_parser.h", "rpu_parser.h")]),
        make_framework(ctx, "Libdav1d", lib / "libdav1d.a", [(inc / "dav1d", "dav1d")]),
        make_framework(ctx, "Libass", lib / "libass.a", [(inc / "ass", "ass")]),
    ]
    for ff in FFMPEG_LIBS:
        headers = [(h, h.name) for h in sorted((inc / f"lib{ff}").iterdir())]
        headers += [(ctx.src("ffmpeg") / f"lib{ff}" / h, h) for h in FFMPEG_EXTRA_HEADERS.get(ff, ())]
        if ff in FFMPEG_CONFIG_H:
            headers.append((ctx.build("ffmpeg") / "config.h", "config.h"))
        made.append(make_framework(ctx, f"Lib{ff}", lib / f"lib{ff}.a", headers))
    made.append(make_framework(ctx, "Libmpv", lib / "libmpv.a", [(inc / "mpv", "mpv")]))
    return made


def toolchain(ctx: Ctx) -> dict:
    def first(cmd):
        return run(cmd, capture=True, env=ctx.env).strip().splitlines()[0]
    return {
        "xcode": " ".join(run(["xcodebuild", "-version"], capture=True).split()),
        "sdk": ctx.sl.sdk,
        "sdk_version": run(["xcrun", "--sdk", ctx.sl.sdk, "--show-sdk-version"], capture=True).strip(),
        "clang": first(["/usr/bin/clang", "--version"]),
        "meson": first(ctx.meson + ["--version"]),
        "meson_python": first([ctx.meson[0], "--version"]),
        "ninja": first([ctx.ninja, "--version"]),
        "pkg-config": first([ctx.pkg_config, "--version"]),
        "make": first(["make", "--version"]),
        "rustc": first([ctx.rust / "bin" / "rustc", "-vV"]),
        "rustc_verbose": run([ctx.rust / "bin" / "rustc", "-vV"], capture=True).strip().splitlines(),
        "cargo": first([ctx.rust / "bin" / "cargo", "-V"]),
        "cargo_c": first([ctx.cargo_c / "cargo-cinstall", "cinstall", "--version"]),
        "minimum_os": ctx.pins["toolchain"]["minimum_os"],
        "source_date_epoch": ctx.env["SOURCE_DATE_EPOCH"],
        "zero_ar_date": ctx.env["ZERO_AR_DATE"],
        "flags": ctx.flags,
    }


def cmd_build(args) -> None:
    sl = SLICES[args.slice]
    pins = load_pins()
    root = args.work.resolve()
    if " " in str(root):
        raise Failure(f"work directory {root} contains a space, which pkg-config and "
                      "FFmpeg's configure cannot handle")
    repo = inside_git_repo(root)
    if repo:
        raise Failure(f"work directory {root} is inside the git repository {repo}; "
                      "use a directory outside any repository (FFmpeg's version script "
                      "would read that repository)")
    work, out = root / sl.name, root / "out" / sl.name
    for d in (work, out):
        if d.exists():
            shutil.rmtree(d)
    (out / "logs").mkdir(parents=True)
    work.mkdir(parents=True)
    meson, ninja, pkg_config, bindir = prepare_tools(pins, args.downloads, root)
    rust = install_rust(pins, args.downloads, root / "tools" / "rust", [sl.rust_target])
    install_cargo_c(pins, args.downloads, root / "tools" / "cargo-c")
    sdk = sdk_path(sl.sdk)
    flags = compile_flags(sl, sdk, pins["toolchain"]["minimum_os"])
    ctx = Ctx(sl, pins, args.downloads, root, work, out, sdk, flags, {}, meson, ninja, pkg_config,
              root / "tools" / "rust", root / "tools" / "cargo-c")
    ctx.env = build_env(root, bindir, flags, ctx.pc_dirs, pins["toolchain"]["source_date_epoch"])
    report = {"slice": sl.name, "started": now(), "repository_commit": repo_commit(),
              "pins_sha256": sha256_file(ENGINE / "pins.ini"), "toolchain": toolchain(ctx)}
    report["toolchain"]["rust_std_targets"] = rust["std_targets"]
    report["prebuilt"] = stage_prebuilt(ctx)
    report["sources"] = {}
    for lib in BUILD_ORDER:
        log(f"\n==== {lib} ({sl.name})")
        report["sources"][lib] = prepare_source(ctx, lib)
        if lib == "libdovi":
            report["libdovi"] = build_libdovi(ctx)
        elif lib == "dav1d":
            build_meson(ctx, lib, read_list(CONFIG / "dav1d-meson.txt"), ndebug=False)
        elif lib == "libass":
            build_meson(ctx, lib, read_list(CONFIG / "libass-meson.txt"), ndebug=True)
        elif lib == "ffmpeg":
            dovi = libdovi_flags(ctx.pkg_config, ctx.env)
            report["ffmpeg_libdovi_flags"] = {
                k: [f.replace(str(ctx.work), "<work>") for f in v] for k, v in dovi.items()}
            report["ffmpeg_configure_args"] = build_ffmpeg(ctx, dovi)
        elif lib == "mpv":
            options = read_list(CONFIG / "mpv-meson.txt")
            build_meson(ctx, lib, options, ndebug=True)
            report["mpv_meson_options"] = options
    report["frameworks"] = package_frameworks(ctx)
    report["finished"] = now()
    write_json(out / "provenance.json", report)
    log(f"\nBuilt {len(report['frameworks'])} frameworks in {out / 'frameworks'}")


def now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def repo_commit() -> str:
    if os.environ.get("GITHUB_SHA"):
        return os.environ["GITHUB_SHA"]
    try:
        return run(["git", "-C", REPO, "rev-parse", "HEAD"], capture=True).strip()
    except Failure:
        return "unknown"


def write_json(path: Path, data) -> None:
    path.write_text(json.dumps(data, indent=2, sort_keys=False) + "\n")


# -------------------------------------------------------------------- check

class Checks:
    def __init__(self):
        self.results: list[dict] = []

    def expect(self, name: str, ok: bool, detail: str = "") -> bool:
        self.results.append({"check": name, "ok": bool(ok), "detail": detail})
        log(f"{'PASS' if ok else 'FAIL'}  {name}" + (f": {detail}" if detail and not ok else ""))
        return ok

    def equal(self, name: str, actual, expected) -> bool:
        return self.expect(name, actual == expected, f"got {actual!r}, expected {expected!r}")

    def sets(self, name: str, actual: set, expected: set) -> bool:
        missing, extra = sorted(expected - actual), sorted(actual - expected)
        detail = "; ".join(x for x in (f"missing {missing}" if missing else "",
                                       f"unexpected {extra}" if extra else "") if x)
        return self.expect(name, not missing and not extra, detail)


def check_trees(c: Checks, ctx_work: Path, report: dict, tmp: Path) -> None:
    for lib, info in report["sources"].items():
        src = ctx_work / "src" / lib
        c.equal(f"{lib}: source archive commit", info["archive_commit"], info["commit"])
        c.equal(f"{lib}: source tree unchanged by the build",
                tree_digest(tree_files(src)), info["patched_tree"])
        again = tmp / lib
        extract_tar(Path(report["downloads"]) / info["archive"], again)
        pristine = tree_digest(tree_files(again))
        apply_series(lib, again)
        c.equal(f"{lib}: pristine archive re-extracted", pristine, info["pristine_tree"])
        c.equal(f"{lib}: tree equals pristine plus series",
                tree_digest(tree_files(again)), info["patched_tree"])
        shutil.rmtree(again)


def archive_members(archive: Path) -> list[str]:
    return run(["ar", "-t", archive], capture=True).split()


def member_platforms(binary: Path) -> dict[str, tuple[str, str]]:
    """(platform, minimum OS) of every archive member, from LC_BUILD_VERSION
    or, for older objects, the LC_VERSION_MIN_* command naming the platform."""
    found: dict[str, tuple[str, str]] = {}
    member = None
    lines = run(["otool", "-l", binary], capture=True).splitlines()
    for i, line in enumerate(lines):
        m = re.match(r"^\S.*\((\S+)\):$", line)
        if m:
            member = m.group(1)
            continue
        m = re.match(r"^\s*cmd (LC_BUILD_VERSION|LC_VERSION_MIN_\w+)$", line)
        if m and member:
            block = "\n".join(lines[i:i + 6])
            if m.group(1) == "LC_BUILD_VERSION":
                platform = re.search(r"^\s*platform (\S+)$", block, re.M).group(1)
                minos = re.search(r"^\s*minos (\S+)$", block, re.M).group(1)
            else:
                platform = m.group(1)
                minos = re.search(r"^\s*version (\S+)$", block, re.M).group(1)
            found[member] = (platform, minos)
    return found


def version_tuple(v: str) -> tuple[int, ...]:
    return tuple(int(x) for x in v.split("."))


def check_binary_form(c: Checks, sl: Slice, fw: Path, name: str, minimum_os: str) -> None:
    binary = fw / name
    c.equal(f"{name}: architectures", run(["lipo", "-archs", binary], capture=True).split(), ["arm64"])
    out = run(["otool", "-l", binary], capture=True)
    platforms = set(re.findall(r"^\s*platform (\S+)$", out, re.M))
    minos = set(re.findall(r"^\s*minos (\S+)$", out, re.M))
    if name == "Libdovi":
        # Rust's prebuilt standard library carries Rust's own minimums
        # (device objects use LC_VERSION_MIN_*); the crate's objects use 14.0.
        members = member_platforms(binary)
        allowed = {str(sl.macho_platform)} | ({sl.version_min_cmd} if sl.version_min_cmd else set())
        c.expect(f"{name}: every member is built for the slice's platform",
                 bool(members) and all(p in allowed for p, _ in members.values()),
                 str(sorted({p for p, _ in members.values()})))
        c.expect(f"{name}: no member needs a newer OS than {minimum_os}",
                 all(version_tuple(v) <= version_tuple(minimum_os) for _, v in members.values()),
                 str(sorted({v for _, v in members.values()})))
        # cargo-c builds the dolby_vision crate under its library name, dovi.
        crate = {v for m, (_, v) in members.items() if m.startswith("dovi-")}
        c.equal(f"{name}: the crate's own objects' minimum OS", crate, {minimum_os})
    else:
        c.equal(f"{name}: LC_BUILD_VERSION platform", platforms, {str(sl.macho_platform)})
        c.equal(f"{name}: minimum OS", minos, {minimum_os})
    plist = plistlib.loads((fw / "Info.plist").read_bytes())
    c.equal(f"{name}: Info.plist identifier", plist.get("CFBundleIdentifier"),
            PLIST_ID_PREFIX + name.replace("_", "-"))
    c.equal(f"{name}: Info.plist platform", plist.get("CFBundleSupportedPlatforms"), [sl.plist_platform])
    c.equal(f"{name}: Info.plist MinimumOSVersion", plist.get("MinimumOSVersion"), PLIST_MINIMUM_OS)
    c.expect(f"{name}: module map", (fw / "Modules" / "module.modulemap").read_text()
             .startswith(f"framework module {name} [system] {{"))


# ------------------------------------------------------------- link checks

# Symbols the linker itself provides to every link. Objective-C selector
# stubs (_objc_msgSend$<selector>, emitted by current clang) are also
# synthesised by the linker, as calls to objc_msgSend in libobjc.
LINKER_PROVIDED = {"___dso_handle"}
SELECTOR_STUB = "_objc_msgSend$"
TBD_KINDS = {
    "symbols": ("{}",), "weak-symbols": ("{}",), "thread-local-symbols": ("{}",),
    "global": ("{}",), "weak": ("{}",), "thread_local": ("{}",),
    "objc-classes": ("_OBJC_CLASS_$_{}", "_OBJC_METACLASS_$_{}"),
    "objc_class": ("_OBJC_CLASS_$_{}", "_OBJC_METACLASS_$_{}"),
    "objc-eh-types": ("_OBJC_EHTYPE_$_{}",), "objc_eh_type": ("_OBJC_EHTYPE_$_{}",),
    "objc-ivars": ("_OBJC_IVAR_$_{}",), "objc_ivar": ("_OBJC_IVAR_$_{}",),
}
LINK_TEST_SOURCE = """\
#include <Libdovi/rpu_parser.h>
#include <Libmpv/mpv/client.h>

const char *avformat_configuration(void);

int main(void)
{
    mpv_handle *mpv = mpv_create();
    if (mpv) {
        mpv_initialize(mpv);
        mpv_terminate_destroy(mpv);
    }
    dovi_rpu_free(dovi_parse_unspec62_nalu(NULL, 0));
    return avformat_configuration()[0] == '\\0';
}
"""


def parse_tbd(text: str) -> tuple[set[str], set[str]]:
    """The symbols a text-based stub (.tbd, version 4 YAML or 5 JSON) exports,
    including those of the libraries it describes inline, and the install
    names of the libraries it re-exports."""
    names: list[tuple[str, str]] = []
    reexported: set[str] = set()
    if text.lstrip().startswith("{"):
        doc = json.loads(text)
        for lib in [doc.get("main_library", {})] + doc.get("libraries", []):
            for entry in lib.get("exported_symbols", []) + lib.get("reexported_symbols", []):
                for section in ("data", "text"):
                    for kind, items in entry.get(section, {}).items():
                        names += [(kind, i) for i in items]
            for entry in lib.get("reexported_libraries", []):
                reexported.update(entry.get("names", []))
    else:
        for doc in re.split(r"^---.*$", text, flags=re.M):
            for block in re.finditer(r"^(exports|reexports|reexported-libraries):\n(.*?)(?=^\S|\Z)",
                                     doc, re.M | re.S):
                for kind, items in re.findall(r"([a-z-]+):\s*\[(.*?)\]", block.group(2), re.S):
                    items = [i.strip().strip("'\"") for i in items.split(",") if i.strip()]
                    if block.group(1) == "reexported-libraries":
                        if kind == "libraries":
                            reexported.update(items)
                    else:
                        names += [(kind, i) for i in items]
    symbols = {form.format(name) for kind, name in names for form in TBD_KINDS.get(kind, ())}
    return symbols, reexported


def link_name(path: str) -> str | None:
    """How an app links a library, from its SDK path or install name:
    framework:X or lib:x. None for private frameworks and Swift libraries."""
    path = path.lstrip("/")
    parts = path.split("/")
    if path.startswith("System/Library/Frameworks/"):
        return "framework:" + parts[3].split(".framework")[0]
    if path.startswith("usr/lib/system/"):
        return "lib:System"
    if path.startswith("usr/lib/") and not path.startswith("usr/lib/swift/"):
        return "lib:" + re.sub(r"^lib", "", parts[-1]).split(".")[0]
    return None


def sdk_exports(sdk: Path) -> tuple[dict[str, set[str]], dict[str, set[str]]]:
    """Every symbol the SDK's public .tbd stubs export, with the libraries
    that export it, and which libraries each library re-exports."""
    exports: dict[str, set[str]] = {}
    reexports: dict[str, set[str]] = {}
    for root in (sdk / "usr" / "lib", sdk / "System" / "Library" / "Frameworks"):
        for tbd in sorted(root.rglob("*.tbd")):
            link = link_name(tbd.relative_to(sdk).as_posix())
            if tbd.is_symlink() or link is None:
                continue
            symbols, reexported = parse_tbd(tbd.read_text(errors="replace"))
            for symbol in symbols:
                exports.setdefault(symbol, set()).add(link)
            reexports.setdefault(link, set()).update(
                n for n in map(link_name, reexported) if n and n != link)
    return exports, reexports


def with_reexports(links: set[str], reexports: dict[str, set[str]]) -> set[str]:
    """The libraries these links provide, following re-exports."""
    result, todo = set(), list(links)
    while todo:
        link = todo.pop()
        if link not in result:
            result.add(link)
            todo.extend(reexports.get(link, ()))
    return result


def prebuilt_archives(pins, work: Path) -> dict[str, Path]:
    """The staged archive behind each pinned prebuilt framework."""
    archives = {}
    for section in pin_sections(pins, "prebuilt"):
        for fw in pins[section]["frameworks"].split():
            lib = "lib" + (fw[3:] if fw.startswith("Lib") else fw) + ".a"
            archives[fw] = work / "deps" / section.split(":", 1)[1] / "lib" / lib
    return archives


def app_link_flags(app_link: dict[str, list[str]]) -> tuple[list[str], set[str]]:
    flags = [f for name in app_link["frameworks"] for f in ("-framework", name)]
    flags += [f"-l{name}" for name in app_link["libraries"]]
    names = {f"framework:{n}" for n in app_link["frameworks"]} | {f"lib:{n}" for n in app_link["libraries"]}
    # libSystem is always linked, and Foundation re-exports libobjc.
    return flags, names | {"lib:System", "lib:objc"}


def check_link(c: Checks, sl: Slice, pins, work: Path, fws: Path, sdk: Path) -> dict:
    """Symbol closure over the whole link set, then a dead-stripped test link
    of a small program, as an app would link these frameworks."""
    app_min = pins["toolchain"]["app_minimum_tvos" if sl.tvos else "app_minimum_ios"]
    target = sl.target.format(v=app_min)
    built = {p.stem: p / p.stem for p in sorted(fws.glob("*.framework"))}
    prebuilt = prebuilt_archives(pins, work)
    c.expect("pinned prebuilt archives staged", all(p.exists() for p in prebuilt.values()),
             str([str(p) for p in prebuilt.values() if not p.exists()]))
    archives = {**built, **prebuilt}
    runtime = Path(run(["xcrun", "--sdk", sl.sdk, "clang", "-target", target,
                        "-print-libgcc-file-name"], capture=True).strip())
    defined = set().union(*(nm_symbols(p, False) for p in archives.values()))
    runtime_defined = nm_symbols(runtime, False)
    exports, reexports = sdk_exports(sdk)
    app_link = read_sections(CONFIG / "app-link.txt")
    link_flags, link_names = app_link_flags(app_link)
    link_names = with_reexports(link_names, reexports)
    missing, outside, needed, stubs = {}, {}, set(), 0
    for name, path in archives.items():
        for symbol in sorted(nm_symbols(path, True) - defined - LINKER_PROVIDED):
            if symbol.startswith(SELECTOR_STUB):
                stubs += 1
                continue
            providers = exports.get(symbol)
            if providers:
                needed |= providers
                if not providers & link_names:
                    outside[symbol] = sorted(providers)
            elif symbol not in runtime_defined:
                missing.setdefault(name, []).append(symbol)
    c.expect("symbol closure: every undefined symbol is defined in the link set or the SDK",
             not missing, json.dumps(missing))
    c.expect("symbol closure: SDK symbols come from the app's frameworks and libraries",
             not outside, json.dumps(outside))

    test = work / "linktest"
    if test.exists():
        shutil.rmtree(test)
    test.mkdir()
    (test / "main.c").write_text(LINK_TEST_SOURCE)
    cmd = ["xcrun", "--sdk", sl.sdk, "clang", "-target", target, "-isysroot", str(sdk),
           "-F", str(fws), str(test / "main.c"), "-o", str(test / "linktest"), "-Wl,-dead_strip"]
    cmd += [f for name in built for f in ("-framework", name)]
    cmd += [str(p) for p in prebuilt.values()]
    cmd += link_flags
    log(f"$ {shlex.join(cmd)}")
    res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if res.stdout:
        log(res.stdout)
    linked = res.returncode == 0
    c.expect("dead-stripped test link of mpv_create, mpv_initialize, mpv_terminate_destroy, "
             "avformat_configuration, dovi_parse_unspec62_nalu and dovi_rpu_free",
             linked, res.stdout[-2000:])
    if linked:
        symbols = nm_symbols(test / "linktest", False)
        c.expect("test link contains libmpv, libavformat and libdovi",
                 {"_mpv_create", "_avformat_configuration", "_dovi_parse_unspec62_nalu"} <= symbols)
    return {"target": target, "system_libraries_needed": sorted(needed),
            "selector_stub_references": stubs, "linked": linked}


def string_literals(lines: list[str]) -> list[str]:
    """C string literals in source lines, plus each run of adjacent literals
    joined, as the compiler concatenates them."""
    found, run_ = [], []
    for line in lines:
        literals = re.findall(r'"((?:[^"\\\n]|\\.)*)"', line)
        found += literals
        if literals:
            run_ += literals
        elif run_:
            found.append("".join(run_))
            run_ = []
    if run_:
        found.append("".join(run_))
    return found


def decoder_patches(lib: str) -> list[Path]:
    return [p for _, p in read_series(lib)
            if re.match(r"\d{4}-", p.name) and int(p.name[:4]) in DECODER_PATCHES[lib]]


def check_decoder(c: Checks, report: dict, work: Path, libavcodec_undefined: set) -> None:
    """Dolby Vision and decoder checks (patch spec 8.6 items 4 and 5, 2.8, 5.9, 6.6)."""
    flags = report.get("ffmpeg_libdovi_flags", {})
    c.expect("FFmpeg built with libdovi's include path and -ldovi",
             any(f.startswith("-I") for f in flags.get("cflags", ()))
             and "-ldovi" in flags.get("ldflags", ()), json.dumps(flags))
    for symbol in DOVI_LIBAVCODEC_REFERENCES:
        c.expect(f"Libavcodec references {symbol}", symbol in libavcodec_undefined)
    hevcdec = (work / "src" / "ffmpeg" / "libavcodec" / "hevc" / "hevcdec.c").read_text()
    for message in HEVCDEC_VERBOSE_MESSAGES:
        levels = re.findall(r"(AV_LOG_\w+),\s*\"" + re.escape(message) + '"', hevcdec)
        c.equal(f"hevcdec logs \"{message}\" at verbose", levels, ["AV_LOG_VERBOSE"])
    hits = []
    for lib in DECODER_PATCHES:
        for patch in decoder_patches(lib):
            added = [l[1:] for l in patch.read_text().splitlines()
                     if l.startswith("+") and not l.startswith("+++")]
            for text in string_literals(added):
                hits += [f"{patch.name}: {term!r} in \"{text}\"" for term in FAULT_SUBSTRINGS
                         if term in text]
    c.expect("decoder patches add no message with a fault substring", not hits, "; ".join(hits))

def first_difference(a: bytes, b: bytes) -> str:
    la, lb = a.decode(errors="replace").splitlines(), b.decode(errors="replace").splitlines()
    for n, (x, y) in enumerate(zip(la, lb), 1):
        if x != y:
            return f"line {n}: {x!r} != {y!r}"
    return f"{len(la)} lines != {len(lb)} lines"


def check_libdovi(c: Checks, sl: Slice, pins, work: Path, fws: Path, downloads: Path,
                  undefined: dict, defined: dict) -> dict:
    """libdovi against today's prebuilt (same C API and header), its panic
    strategy, and the libdovi functions libplacebo and FFmpeg call."""
    fw = fws / "Libdovi.framework"
    header = (fw / "Headers" / "rpu_parser.h").read_bytes()
    exported = {s for s in defined["Libdovi"] if s.startswith("_dovi_")}
    c.sets("Libdovi: exported C API", exported, LIBDOVI_API)
    members = archive_members(fw / "Libdovi")
    unwind = sorted(m for m in members if m.startswith("panic_unwind-"))
    abort = sorted(m for m in members if m.startswith("panic_abort-"))
    c.expect("Libdovi: built with panic=unwind (panic_unwind linked, panic_abort not)",
             bool(unwind) and not abort, f"panic_unwind {unwind}, panic_abort {abort}")
    c.expect("Libdovi: no embedded LLVM bitcode",
             not re.search(r"^\s*segname __LLVM$", run(["otool", "-l", fw / "Libdovi"], capture=True),
                           re.M))
    version = pins["source:libdovi"]["version"].split(".")
    c.equal("Libdovi: RPU_PARSER version macros",
            [define(fw / "Headers" / "rpu_parser.h", f"RPU_PARSER_{p}")
             for p in ("MAJOR", "MINOR", "PATCH")], version)
    pc = (work / "install" / PREFIX.lstrip("/") / "lib" / "pkgconfig" / "dovi.pc").read_text()
    c.expect("dovi.pc: name dovi, version as pinned", re.search(r"^Name: dovi$", pc, re.M) is not None
             and re.search(rf"^Version: {re.escape('.'.join(version))}$", pc, re.M) is not None, pc)

    ref = pins["reference:libdovi"]
    with zipfile.ZipFile(downloads / download_name("reference:libdovi", ref["url"])) as z:
        ref_header = z.read("include/libdovi/rpu_parser.h")
        ref_lib = z.read(f"lib/{sl.prebuilt}/thin/arm64/lib/libdovi.a")
    c.expect("Libdovi: rpu_parser.h identical to today's prebuilt", header == ref_header,
             first_difference(header, ref_header))
    with tempfile.TemporaryDirectory(dir=work) as tmp:
        ref_path = Path(tmp) / "libdovi.a"
        ref_path.write_bytes(ref_lib)
        ref_exported = {s for s in nm_symbols(ref_path, False) if s.startswith("_dovi_")}
    c.sets("Libdovi: exported C API equals today's prebuilt", exported, ref_exported)

    placebo = prebuilt_archives(pins, work)["Libplacebo"]
    placebo_calls = {s for s in nm_symbols(placebo, True) if s.startswith("_dovi_")}
    c.expect("Libplacebo calls libdovi only through exported functions",
             bool(placebo_calls) and placebo_calls <= exported, str(sorted(placebo_calls)))
    ffmpeg_calls = set().union(*(undefined[f"Lib{ff}"] for ff in FFMPEG_LIBS))
    ffmpeg_calls = {s for s in ffmpeg_calls if s.startswith("_dovi_")}
    c.expect("FFmpeg calls libdovi only through exported functions", ffmpeg_calls <= exported,
             str(sorted(ffmpeg_calls)))
    ffmpeg_src = work / "src" / "ffmpeg"
    ffmpeg_files = sorted(str(p.relative_to(ffmpeg_src)) for p in ffmpeg_src.rglob("*")
                          if p.suffix in (".c", ".h", ".m") and p.is_file()
                          and re.search(rb"libdovi|rpu_parser\.h", p.read_bytes()))
    return {"exported": sorted(exported), "libplacebo_calls": sorted(placebo_calls),
            "ffmpeg_calls": sorted(ffmpeg_calls), "ffmpeg_sources_using_libdovi": ffmpeg_files,
            "panic_runtime": unwind, "members": len(members)}


def build_date(epoch: int) -> str:
    """clang's __DATE__ " " __TIME__ for SOURCE_DATE_EPOCH (UTC)."""
    t = datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc)
    return f"{t.strftime('%b')} {t.day:2d} {t.year} {t.strftime('%H:%M:%S')}"


def cmd_check(args) -> None:
    sl = SLICES[args.slice]
    pins = load_pins()
    root = args.work.resolve()
    work, out = root / sl.name, root / "out" / sl.name
    report = json.loads((out / "provenance.json").read_text())
    report["downloads"] = str(args.downloads)
    fws = out / "frameworks"
    minimum_os = pins["toolchain"]["minimum_os"]
    c = Checks()

    # Toolchain and inputs.
    if args.strict:
        c.expect("Xcode version matches pins.ini", report["toolchain"]["xcode"]
                 .startswith(f"Xcode {pins['toolchain']['xcode']} "), report["toolchain"]["xcode"])
    for lib, info in report["sources"].items():
        c.equal(f"{lib}: archive SHA-256 matches pins.ini", info["sha256"],
                pins[f"source:{lib}"]["sha256"])
        c.equal(f"{lib}: patch series", [p["file"] for p in info["patches"]],
                [f"{lib}/{p.name}" for _, p in read_series(lib)])
    with tempfile.TemporaryDirectory(dir=root) as tmp:
        check_trees(c, work, report, Path(tmp))

    # Framework form.
    expected_names = set(BUILT_FRAMEWORKS)
    c.sets("framework set", {p.stem for p in fws.glob("*.framework")}, expected_names)
    for name in sorted(expected_names):
        check_binary_form(c, sl, fws / f"{name}.framework", name, minimum_os)
    for name, count in HEADER_COUNTS.items():
        c.equal(f"{name}: header count", sum(1 for p in (fws / f"{name}.framework" / "Headers")
                                             .rglob("*") if p.is_file()), count)

    # FFmpeg: configuration, licence and TLS.
    build = work / "build" / "ffmpeg"
    config_h = build / "config.h"
    expected_conf = ffmpeg_configuration(report["ffmpeg_configure_args"])
    c.equal("FFmpeg configuration in config.h", c_string(define(config_h, "FFMPEG_CONFIGURATION")),
            expected_conf)
    avformat = fws / "Libavformat.framework" / "Libavformat"
    owner = [l for l in run(["nm", "-A", "-g", "-U", avformat], capture=True).splitlines()
             if l.endswith(" _avformat_configuration")]
    c.expect("Libavformat defines _avformat_configuration", len(owner) == 1, str(owner))
    binary_conf = ""
    if owner:
        member = owner[0].rsplit(": ", 1)[0].split(":")[-1]
        data = subprocess.run(["ar", "-p", str(avformat), member], stdout=subprocess.PIPE,
                              check=True).stdout
        m = re.search(rb"--prefix=[^\x00]*", data)
        binary_conf = m.group(0).decode() if m else ""
    c.equal("avformat_configuration() string", binary_conf, expected_conf)
    c.expect("configuration has --enable-securetransport", "--enable-securetransport" in binary_conf.split())
    for banned in ("--enable-gpl", "--enable-version3", "--enable-openssl", "--enable-nonfree"):
        c.expect(f"configuration lacks {banned}", banned not in binary_conf.split())
    c.expect("configuration lacks delogo", "delogo" not in binary_conf)
    c.equal("FFMPEG_LICENSE", c_string(define(config_h, "FFMPEG_LICENSE")), "LGPL version 2.1 or later")
    licences = set()
    for ff in FFMPEG_LIBS:
        data = (fws / f"Lib{ff}.framework" / f"Lib{ff}").read_bytes()
        found = {m.decode() for m in re.findall(rb"lib\w+ license: ([^\x00]*)\x00", data)}
        c.equal(f"Lib{ff}: licence string", found, {"LGPL version 2.1 or later"})
        licences |= found
    flags = read_sections(CONFIG / "expected-ffmpeg-config.txt")
    for word in flags["on"]:
        c.equal(f"CONFIG_{word.upper()}", define(config_h, f"CONFIG_{word.upper()}"), "1")
    for word in flags["off"]:
        c.equal(f"CONFIG_{word.upper()}", define(config_h, f"CONFIG_{word.upper()}"), "0")
    for word in flags["have-off"]:
        c.equal(f"HAVE_{word.upper()}", define(config_h, f"HAVE_{word.upper()}"), "0")
    components = {}
    kinds = {"DECODER": "decoder", "ENCODER": "encoder", "DEMUXER": "demuxer", "MUXER": "muxer",
             "PARSER": "parser", "BSF": "bsf", "HWACCEL": "hwaccel", "PROTOCOL": "protocol",
             "FILTER": "filter", "INDEV": "indev", "OUTDEV": "outdev"}
    for m in re.finditer(r"^#define CONFIG_(\w+?)_(" + "|".join(kinds) + r") 1$",
                         (build / "config_components.h").read_text(), re.M):
        components.setdefault(kinds[m.group(2)], set()).add(m.group(1).lower())
    expected_components = read_sections(CONFIG / "expected-ffmpeg-components.txt")
    filter_symbols = set(expected_components.pop("filter-symbols"))
    for kind, names in expected_components.items():
        c.sets(f"FFmpeg {kind} components", components.get(kind, set()), set(names))

    # Symbols across every framework binary.
    undefined, defined = {}, {}
    for name in sorted(expected_names):
        binary = fws / f"{name}.framework" / name
        undefined[name], defined[name] = nm_symbols(binary, True), nm_symbols(binary, False)
    openssl = sorted({s for n in expected_names for s in undefined[n] | defined[n]
                      if OPENSSL_SYMBOL.match(s)})
    c.expect("no OpenSSL symbols", not openssl, str(openssl[:10]))
    c.expect("_SecIdentityCreate not referenced",
             not any("_SecIdentityCreate" in undefined[n] for n in expected_names))
    c.expect("delogo filter absent", not any("_ff_vf_delogo" in defined[n] for n in expected_names))
    registry = {m.group(1) for s in defined["Libavfilter"]
                for m in [re.match(r"^_ff_((?:af|vf|asrc|asink|vsrc|vsink|avf|avsrc)_\w+)$", s)] if m}
    c.sets("Libavfilter filter registry symbols", registry, filter_symbols)
    c.expect("Libavcodec uses kCVPixelBufferMetalCompatibilityKey",
             "_kCVPixelBufferMetalCompatibilityKey" in undefined["Libavcodec"])
    for key in ("_kCVPixelBufferOpenGLESCompatibilityKey",
                "_kCVPixelBufferIOSurfaceOpenGLTextureCompatibilityKey"):
        c.expect(f"{key} not referenced", not any(key in undefined[n] for n in expected_names))
    check_decoder(c, report, work, undefined["Libavcodec"])

    # mpv: configuration, features, licence marker and patch marker.
    mpv_config = work / "build" / "mpv" / "config.h"
    configuration = c_string(define(mpv_config, "CONFIGURATION")) or ""
    expected_options = " ".join(shlex.quote(o) for o in report["mpv_meson_options"])
    c.expect("mpv configuration options", configuration == expected_options
             or configuration.startswith(expected_options + " --cross-file="), configuration)
    c.expect("mpv configuration has -Dgpl=false", "-Dgpl=false" in configuration.split())
    features = (c_string(define(mpv_config, "FULLCONFIG")) or "").split()
    c.sets("mpv features", set(features), set(read_list(CONFIG / "expected-mpv-features.txt")))
    libmpv = (fws / "Libmpv.framework" / "Libmpv").read_bytes()
    c.expect("Libmpv carries -Dgpl=false", b"-Dgpl=false" in libmpv)
    c.expect("Libmpv has no -Dgpl=true", b"-Dgpl=true" not in libmpv)
    c.expect("Libmpv contains mpv patch 0001", MPV_PATCH_MARKER in libmpv)
    # Vivid's adapter reads the AVFoundation output's restart log line.
    c.expect("Libmpv keeps the AVFoundation 'notification name' log line",
             b"notification name: %s" in libmpv)
    date = build_date(int(pins["toolchain"]["source_date_epoch"]))
    c.expect(f"Libmpv build date is SOURCE_DATE_EPOCH ({date})", date.encode() in libmpv)
    c.expect("Libmpv contains mpv patch 0040 (hardware decoding error tolerance)",
             MPV_HWDEC_RECOVERY_MARKER in libmpv)
    client_h = fws / "Libmpv.framework" / "Headers" / "mpv" / "client.h"
    c.equal("MPV_CLIENT_API_VERSION", define(client_h, "MPV_CLIENT_API_VERSION"), "MPV_MAKE_VERSION(2, 5)")
    c.sets("Libmpv headers", {p.name for p in client_h.parent.iterdir()},
           {"client.h", "render.h", "render_gl.h", "stream_cb.h"})

    # libass and dav1d.
    ass_h = fws / "Libass.framework" / "Headers" / "ass" / "ass.h"
    c.equal("LIBASS_VERSION", define(ass_h, "LIBASS_VERSION"), "0x01705000")
    dav1d_v = fws / "Libdav1d.framework" / "Headers" / "dav1d" / "version.h"
    c.equal("DAV1D_API_VERSION", tuple(define(dav1d_v, f"DAV1D_API_VERSION_{p}")
                                       for p in ("MAJOR", "MINOR", "PATCH")), ("7", "0", "0"))
    for name in ("Libass", "Libdav1d"):
        asm = [m for m in archive_members(fws / f"{name}.framework" / name) if m.endswith(".S.o")]
        c.expect(f"{name}: arm64 assembly built", bool(asm), "no .S objects in the archive")

    # libdovi: C API and header as today's prebuilt, panic strategy, callers.
    report["libdovi_checks"] = check_libdovi(c, sl, pins, work, fws, args.downloads,
                                             undefined, defined)
    c.equal("Libdovi: built with the pinned rustc", report["toolchain"]["rustc"],
            "rustc " + pins["rust:rustc"]["version"])

    # Reproducible archives: no member carries a build timestamp.
    for name in sorted(expected_names):
        dated = [l for l in run(["ar", "-tv", fws / f"{name}.framework" / name],
                                capture=True).splitlines() if " 1970 " not in l]
        c.expect(f"{name}: archive members have zero timestamps", not dated, str(dated[:3]))

    # Linkability: symbol closure and a dead-stripped test link.
    report["link"] = check_link(c, sl, pins, work, fws, sdk_path(sl.sdk))

    report["ffmpeg"] = {"configuration": binary_conf, "licences": sorted(licences),
                        "components": {k: len(v) for k, v in sorted(components.items())}}
    report["mpv"] = {"configuration": configuration, "features": features}
    report["checks"] = c.results
    report.pop("downloads")
    write_json(out / "provenance.json", report)
    summary = summarise(report)
    (out / "provenance.md").write_text(summary)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write(summary)
    failed = [r for r in c.results if not r["ok"]]
    if failed:
        raise Failure(f"{len(failed)} of {len(c.results)} checks failed")
    log(f"\nAll {len(c.results)} checks passed for {sl.name}.")


def summarise(report: dict) -> str:
    ok = sum(r["ok"] for r in report["checks"])
    lines = [f"## Lucid Engine provenance: {report['slice']}", "",
             f"- Repository commit: `{report['repository_commit']}`",
             f"- pins.ini SHA-256: `{report['pins_sha256']}`",
             f"- {report['toolchain']['xcode']}, {report['toolchain']['sdk']} SDK "
             f"{report['toolchain']['sdk_version']}, {report['toolchain']['clang']}",
             f"- Checks: {ok} of {len(report['checks'])} passed", "",
             "| Source | Version | Commit | Archive SHA-256 | Patches |", "| --- | --- | --- | --- | --- |"]
    for lib, info in report["sources"].items():
        patches = ", ".join(f"`{Path(p['file']).name}` ({p['sha256'][:12]})" for p in info["patches"]) or "none"
        lines.append(f"| {lib} | {info['version']} | `{info['commit'][:12]}` | `{info['sha256'][:16]}...` | {patches} |")
    lines += ["", "| Prebuilt | Archive | SHA-256 |", "| --- | --- | --- |"]
    for item in report["prebuilt"]:
        lines.append(f"| {item['name']} | `{item['archive']}` | `{item['sha256'][:16]}...` |")
    dovi = report.get("libdovi_checks", {})
    lines += ["", f"libdovi: {report['toolchain'].get('rustc', '')}, "
              f"{report['toolchain'].get('cargo_c', '')}, target `{report['libdovi']['rust_target']}`, "
              f"Cargo.lock `{report['libdovi']['cargo_lock_sha256'][:16]}...`, "
              f"{len(report['libdovi']['crates'])} vendored crates. Panic runtime: "
              f"{', '.join(dovi.get('panic_runtime', [])) or 'none'}.", "",
              f"libdovi functions libplacebo calls: "
              f"{', '.join(f'`{s[1:]}`' for s in dovi.get('libplacebo_calls', [])) or 'none'}. "
              f"FFmpeg calls: {', '.join(f'`{s[1:]}`' for s in dovi.get('ffmpeg_calls', [])) or 'none'}.",
              "", f"FFmpeg `avformat_configuration()`: `{report['ffmpeg']['configuration']}`", "",
              f"FFmpeg licence: {', '.join(report['ffmpeg']['licences'])}", "",
              "FFmpeg libdovi flags (CFLAGS and LDFLAGS only): `"
              + " ".join(sum(report.get("ffmpeg_libdovi_flags", {}).values(), [])) + "`", "",
              f"mpv configuration: `{report['mpv']['configuration']}`", "",
              f"mpv features: `{' '.join(report['mpv']['features'])}`", "",
              f"Test link ({report['link']['target']}, dead-stripped): "
              f"{'linked' if report['link']['linked'] else 'FAILED'}. System libraries the "
              f"link set needs: {', '.join(report['link']['system_libraries_needed'])}", ""]
    failed = [r for r in report["checks"] if not r["ok"]]
    if failed:
        lines += ["### Failed checks", ""] + [f"- {r['check']}: {r['detail']}" for r in failed] + [""]
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------- test

def build_host_libdovi(root: Path, work: Path, pins, logfile: Path) -> dict:
    """libdovi for the build host, from the slice's own patched libdovi tree,
    with the same pinned toolchain, cargo-c and vendored crates the slice
    build used (patch spec 8.6 item 5: the decoder tests use the patched
    libdovi build)."""
    pin = pins["source:libdovi"]
    src = work / "src" / "libdovi"
    rust, cargo_c, vendor = root / "tools" / "rust", root / "tools" / "cargo-c", work / "vendor"
    for path in (src / pin["crate"], rust / "lib" / "rustlib" / HOST_RUST_TARGET, cargo_c, vendor):
        if not path.exists():
            raise Failure(f"{path} missing: build the slice first")
    host = work / "decoder-tests" / "libdovi"
    env = cargo_env(rust, cargo_c, host / "cargo-home", vendor,
                    {src: "/lucid-engine/src/libdovi", vendor: "/lucid-engine/vendor"})
    lib = cargo_cinstall(src / pin["crate"], HOST_RUST_TARGET, host / "install", host / "target",
                         env, rust, logfile)
    prefix = host / "install" / PREFIX.lstrip("/")
    return {"library": lib, "include": prefix / "include",
            "libs": pc_field(prefix / "lib" / "pkgconfig" / "dovi.pc", "Libs.private"),
            "assets": src / "assets"}


def write_decoder_corpus(assets: Path, dest: Path) -> dict:
    """The RPUs of the libdovi corpus (engine/tests/libdovi) in the form FFmpeg
    hands to libdovi, an HEVC NAL unit starting 0x7C 0x01, for the decoder
    test to pass through FFmpeg's conversion. Entries in Annex B form get the
    NAL header in place of their start code and raw RPUs are escaped behind
    it, as they would sit in a packet; AV1 payloads are left out. Format:
    b"VTDC", a count, then per case a 16-bit name length, the name, a flag
    byte (1: an entry of an abort class, 2: FFmpeg's conversion is expected
    to succeed), a 32-bit length and the bytes, all big-endian."""
    t = load_libdovi_test()
    entries = []
    for c in t.build_corpus(assets):
        flags = 1 if c.abort_class else 0
        if c.data[:2] == b"\x7c\x01":
            nal, name = c.data, c.name
            flags |= 2 if c.ffmpeg_expect == "convert" else 0
        elif c.data[:5] == b"\x00\x00\x00\x01\x19":
            nal, name = b"\x7c\x01" + c.data[4:], c.name + "/as-nal"
        elif c.data[:4] == b"\x00\x00\x01\x19":
            nal, name = b"\x7c\x01" + c.data[3:], c.name + "/as-nal"
        elif c.data[:1] == b"\x19":
            nal, name = b"\x7c\x01" + t.escape(c.data), c.name + "/as-nal"
        else:
            continue
        entries.append((name, flags, nal))
    out = bytearray(b"VTDC" + len(entries).to_bytes(4, "big"))
    for name, flags, nal in entries:
        out += len(name.encode()).to_bytes(2, "big") + name.encode() + bytes([flags])
        out += len(nal).to_bytes(4, "big") + nal
    dest.write_bytes(bytes(out))
    return {"cases": len(entries), "abort_class_entries": sum(1 for e in entries if e[1] & 1),
            "converted_from_other_forms": sum(1 for e in entries if e[0].endswith("/as-nal"))}


def run_host_test(name: str, sources: list[Path], includes: list[Path], defines: list[str],
                  libs: list[str], argv: list[str], out: Path) -> dict:
    """Compile a host test and run it; it prints '<n> checks, <f> failed'."""
    exe = out / name
    cmd = ["xcrun", "--sdk", "macosx", "clang", "-target", HOST_TEST_TARGET, "-std=c17", "-O1",
           "-g", "-Wall", "-Werror=implicit-function-declaration", "-Werror=incompatible-pointer-types"]
    cmd += [f"-I{i}" for i in includes] + defines + [str(s) for s in sources] + libs
    cmd += ["-framework", "CoreFoundation", "-framework", "CoreMedia", "-framework", "CoreVideo",
            "-framework", "VideoToolbox", "-framework", "CoreGraphics", "-o", str(exe)]
    run(cmd)
    res = subprocess.run([str(exe)] + argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         text=True)
    log(res.stdout)
    m = re.search(r"(\d+) checks, (\d+) failed", res.stdout)
    checks, failed = (int(m.group(1)), int(m.group(2))) if m else (0, -1)
    ok = res.returncode == 0 and checks > 0 and failed == 0
    return {"suite": name, "checks": checks, "failed": failed, "exit": res.returncode, "ok": ok}


def cmd_test(args) -> None:
    """Decoder tests from the patched FFmpeg tree (patch spec 9.4, 8.6 item 5)."""
    sl = SLICES[args.slice]
    pins = load_pins()
    root = args.work.resolve()
    work, out = root / sl.name, root / "out" / sl.name
    report = json.loads((out / "provenance.json").read_text())
    src, build = work / "src" / "ffmpeg", work / "build" / "ffmpeg"
    module = src / "libavcodec" / "videotoolbox_dovi.c"
    if not module.is_file():
        raise Failure(f"{module} missing: build the slice first")
    dovi_includes = [Path(f[2:].replace("<work>", str(work)))
                     for f in report["ffmpeg_libdovi_flags"]["cflags"] if f.startswith("-I")]
    includes = [src, build] + dovi_includes
    test_dir = work / "decoder-tests"
    if test_dir.exists():
        shutil.rmtree(test_dir)
    test_dir.mkdir()
    sources = [module, DECODER_TESTS / "vt_dovi_tests.c"]
    (out / "logs").mkdir(parents=True, exist_ok=True)

    results = [run_host_test("vt_dovi_tests_scripted_libdovi", sources, includes,
                             ["-DVT_DOVI_TEST_FAKE_LIBDOVI"], [], [], test_dir)]

    host = build_host_libdovi(root, work, pins, out / "logs" / "libdovi-host.log")
    corpus = write_decoder_corpus(host["assets"], test_dir / "corpus.bin")
    report["decoder_test_corpus"] = corpus
    log(f"libdovi corpus for FFmpeg's conversion: {corpus['cases']} NAL units "
        f"({corpus['converted_from_other_forms']} from Annex B or raw entries), "
        f"{corpus['abort_class_entries']} abort class entries")
    results.append(run_host_test("vt_dovi_tests_libdovi", sources,
                                 [src, build, host["include"]], [],
                                 [str(host["library"])] + host["libs"],
                                 [str(host["assets"] / "tests"), str(test_dir / "corpus.bin")],
                                 test_dir))

    report["decoder_tests"] = results
    for r in results:
        detail = r.get("detail") or f"{r['checks']} checks, {r['failed']} failed, exit {r['exit']}"
        report.setdefault("checks", []).append(
            {"check": f"decoder tests: {r['suite']}", "ok": r["ok"], "detail": detail})
        log(f"{'PASS' if r['ok'] else 'FAIL'}  decoder tests {r['suite']}: {detail}")
    write_json(out / "provenance.json", report)
    lines = ["", "### Decoder tests (patched FFmpeg tree, build host)", "",
             "| Suite | Checks | Failed | Result |", "| --- | --- | --- | --- |"]
    lines += [f"| {r['suite']} | {r['checks']} | {r['failed']} | "
              f"{'passed' if r['ok'] else 'FAILED: ' + (r.get('detail') or '')} |" for r in results]
    summary = "\n".join(lines) + "\n"
    with open(out / "provenance.md", "a") as f:
        f.write(summary)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write(summary)
    failed = [r for r in results if not r["ok"]]
    if failed:
        raise Failure(f"{len(failed)} decoder test suite(s) failed")
    log(f"All decoder test suites passed for {sl.name}.")


# ------------------------------------------------------------------ package

FIXED_ZIP_TIME = (1980, 1, 1, 0, 0, 0)


def zip_tree(src: Path, dest: Path) -> None:
    """Deterministic zip whose root entry is src's own folder."""
    with zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for path in [src] + sorted(src.rglob("*")):
            rel = path.relative_to(src.parent).as_posix()
            if path.is_symlink():
                raise Failure(f"unexpected symlink in {path}")
            if path.is_dir():
                info = zipfile.ZipInfo(rel + "/", FIXED_ZIP_TIME)
                info.external_attr = (0o40755 << 16) | 0x10
                z.writestr(info, b"")
            else:
                info = zipfile.ZipInfo(rel, FIXED_ZIP_TIME)
                info.external_attr = ((0o100755 if os.access(path, os.X_OK) else 0o100644) << 16)
                info.compress_type = zipfile.ZIP_DEFLATED
                z.writestr(info, path.read_bytes())


def package_xcframeworks(inputs: dict[str, Path], names: list[str], out: Path) -> list[str]:
    """Create each xcframework and its zip in out; returns SHA256SUMS lines."""
    staging = out / "xcframeworks"
    sums = []
    for name in names:
        xcf = staging / f"{name}.xcframework"
        cmd = ["xcodebuild", "-create-xcframework"]
        for slice_name in sorted(inputs):
            cmd += ["-framework", inputs[slice_name] / "frameworks" / f"{name}.framework"]
        run(cmd + ["-output", xcf])
        info = plistlib.loads((xcf / "Info.plist").read_bytes())
        ids = sorted(lib["LibraryIdentifier"] for lib in info["AvailableLibraries"])
        if ids != sorted(inputs):
            raise Failure(f"{name}: xcframework slices {ids}, expected {sorted(inputs)}")
        # xcodebuild lists the slices in a different order from run to run;
        # sort them so identical frameworks give an identical Info.plist.
        info["AvailableLibraries"].sort(key=lambda lib: lib["LibraryIdentifier"])
        with open(xcf / "Info.plist", "wb") as f:
            plistlib.dump(info, f, sort_keys=True)
        archive = out / f"{name}.xcframework.zip"
        zip_tree(xcf, archive)
        with zipfile.ZipFile(archive) as z:
            if any(not n.startswith(f"{name}.xcframework/") for n in z.namelist()):
                raise Failure(f"{archive.name}: root entry is not {name}.xcframework/")
        sums.append(f"{sha256_file(archive)}  {archive.name}")
    shutil.rmtree(staging)
    return sums


def cmd_package(args) -> None:
    inputs = {}
    for prov in sorted(args.input.rglob("provenance.json")):
        report = json.loads(prov.read_text())
        if report["slice"] in inputs:
            raise Failure(f"slice {report['slice']} appears twice in {args.input}")
        if not all(r["ok"] for r in report.get("checks", [{"ok": False}])):
            raise Failure(f"{prov}: slice {report['slice']} has not passed its checks")
        inputs[report["slice"]] = prov.parent
    if not inputs:
        raise Failure(f"no slice outputs under {args.input}")
    names = None
    for slice_name, path in inputs.items():
        found = sorted(p.stem for p in (path / "frameworks").glob("*.framework"))
        if names is not None and found != names:
            raise Failure(f"{slice_name} has frameworks {found}, other slices {names}")
        names = found
    out = args.out
    if out.exists():
        shutil.rmtree(out)
    (out / "provenance").mkdir(parents=True)
    sums = package_xcframeworks(inputs, names, out)
    # Reproducibility: packaging the same inputs again must give the same zips.
    with tempfile.TemporaryDirectory(dir=out.parent) as tmp:
        again = package_xcframeworks(inputs, names, Path(tmp))
    if again != sums:
        raise Failure("packaging the same slices twice gave different zips:\n  "
                      + "\n  ".join(sorted(set(sums) ^ set(again))))
    (out / "SHA256SUMS").write_text("\n".join(sums) + "\n")
    for slice_name, path in inputs.items():
        shutil.copy2(path / "provenance.json", out / "provenance" / f"{slice_name}.json")
        shutil.copy2(path / "provenance.md", out / "provenance" / f"{slice_name}.md")
    summary = ["## Lucid Engine xcframeworks", "",
               f"Slices: {', '.join(sorted(inputs))}", "",
               "Packaged twice from the same slices: identical zips.", "",
               "SwiftPM checksums (SHA-256 of each zip):", "", "```", *sums, "```", ""]
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write("\n".join(summary))
    log("\n".join(summary))


# ------------------------------------------------------------- libdovi test

def load_libdovi_test():
    path = ENGINE / "tests" / "libdovi" / "libdovi_test.py"
    spec = importlib.util.spec_from_file_location("libdovi_test", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules["libdovi_test"] = module
    spec.loader.exec_module(module)
    return module


def pc_field(pc: Path, key: str) -> list[str]:
    m = re.search(rf"^{re.escape(key)}:(.*)$", pc.read_text(), re.M)
    return m.group(1).split() if m else []


def run_harness(harness: Path, cases: Path, tmp: Path, dumps: Path, stderr_log: Path) -> str:
    log(f"$ {harness} {cases} {tmp} {dumps}  (stderr to {stderr_log.name})")
    for d in (tmp, dumps):
        d.mkdir(parents=True, exist_ok=True)
    with open(stderr_log, "w") as err:
        res = subprocess.run([str(harness), str(cases), str(tmp), str(dumps)],
                             stdout=subprocess.PIPE, stderr=err, text=True)
    if res.returncode != 0:
        raise Failure(f"{harness.name} failed ({res.returncode}); see {stderr_log}")
    return res.stdout


def panics_per_case(stderr_log: Path) -> dict[int, int]:
    """Rust panic messages each case printed, from the harness's markers."""
    counts: dict[int, int] = {}
    case = -1
    for line in stderr_log.read_text(errors="replace").splitlines():
        m = re.match(r"^harness: case (\d+)$", line)
        if m:
            case = int(m.group(1))
        elif " panicked at " in line:
            counts[case] = counts.get(case, 0) + 1
    return counts


def cmd_test_libdovi(args) -> None:
    """Build libdovi for the host twice, unpatched and with Vivid's series,
    from the same pinned source, toolchain and crates as the slices, and run
    the malformed and valid RPU corpus through harness.c against both."""
    t = load_libdovi_test()
    pins = load_pins()
    pin = pins["source:libdovi"]
    base = args.work.resolve()
    if base.exists():
        shutil.rmtree(base)
    base.mkdir(parents=True)
    out = base / "out"
    out.mkdir()
    rust = install_rust(pins, args.downloads, base / "tools" / "rust", [])
    cargo_c_bin = base / "tools" / "cargo-c"
    cargo_c = install_cargo_c(pins, args.downloads, cargo_c_bin)
    vendor = base / "vendor"
    crates = vendor_crates(pins, args.downloads, vendor)
    archive = args.downloads / download_name("source:libdovi", pin["url"])
    if sha256_file(archive) != pin["sha256"] or archive_commit(archive) != pin["commit"]:
        raise Failure(f"{archive.name} does not match pins.ini; run fetch first")
    sdk = sdk_path("macosx")
    report = {"started": now(), "repository_commit": repo_commit(),
              "pins_sha256": sha256_file(ENGINE / "pins.ini"), "target": HOST_RUST_TARGET,
              "toolchain": {**rust, "cargo_c": cargo_c,
                            "clang": run(["/usr/bin/clang", "--version"], capture=True).splitlines()[0]},
              "crates": len(crates), "variants": {}}
    built = {}
    for variant in ("unpatched", "patched"):
        log(f"\n==== libdovi, {variant} ({HOST_RUST_TARGET})")
        work = base / variant
        src = work / "src"
        extract_tar(archive, src)
        pristine = tree_files(src)
        applied = apply_series("libdovi", src, out / f"{variant}-patch.log") \
            if variant == "patched" else []
        crate_dir = src / pin["crate"]
        if sha256_file(crate_dir / "Cargo.lock") != pin["cargo_lock_sha256"]:
            raise Failure("libdovi Cargo.lock differs from pins.ini")
        env = cargo_env(base / "tools" / "rust", cargo_c_bin, work / "cargo-home", vendor,
                        {src: "/lucid-engine/src/libdovi", vendor: "/lucid-engine/vendor"})
        install = work / "install"
        lib = cargo_cinstall(crate_dir, HOST_RUST_TARGET, install, work / "target", env,
                             base / "tools" / "rust", out / f"{variant}-build.log")
        prefix = install / PREFIX.lstrip("/")
        harness = work / "harness"
        run(["/usr/bin/clang", "-isysroot", sdk, "-O1", "-Wall", "-Werror",
             "-Wno-deprecated-declarations", "-I", prefix / "include",
             ENGINE / "tests" / "libdovi" / "harness.c", lib, "-o", harness]
            + pc_field(prefix / "lib" / "pkgconfig" / "dovi.pc", "Libs.private"))
        members = archive_members(lib)
        built[variant] = {
            "header": (prefix / "include" / "libdovi" / "rpu_parser.h").read_bytes(),
            "exported": {s for s in nm_symbols(lib, False) if s.startswith("_dovi_")},
            "harness": harness,
        }
        report["variants"][variant] = {
            "patches": applied, "pristine_tree": tree_digest(pristine),
            "tree": tree_digest(tree_files(src)), "library_sha256": sha256_file(lib),
            "panic_runtime": sorted(m.split("-")[0] for m in members
                                    if m.startswith(("panic_unwind-", "panic_abort-"))),
        }

    c = Checks()
    c.expect("patched and unpatched rpu_parser.h are identical",
             built["patched"]["header"] == built["unpatched"]["header"],
             first_difference(built["patched"]["header"], built["unpatched"]["header"]))
    c.sets("patched library exports libdovi's C API", built["patched"]["exported"], LIBDOVI_API)
    c.sets("unpatched library exports libdovi's C API", built["unpatched"]["exported"], LIBDOVI_API)
    c.equal("unpatched library aborts on panic (upstream's -Cpanic=abort)",
            report["variants"]["unpatched"]["panic_runtime"], ["panic_abort"])
    c.equal("patched library unwinds (panic_unwind)",
            report["variants"]["patched"]["panic_runtime"], ["panic_unwind"])

    cases = t.build_corpus(base / "unpatched" / "src" / "assets")
    cases_file = out / "cases.bin"
    t.write_cases(cases, cases_file)
    results, panics = {}, {}
    for variant in ("patched", "unpatched"):
        log(f"\n==== corpus of {len(cases)} cases through the {variant} library")
        stderr_log = out / f"{variant}-stderr.log"
        text = run_harness(built[variant]["harness"], cases_file, base / variant / "tmp",
                           out / f"{variant}-dumps", stderr_log)
        (out / f"{variant}-results.tsv").write_text(text)
        results[variant] = t.parse_output(text, len(cases))
        panics[variant] = panics_per_case(stderr_log)
    verdict = t.evaluate(cases, results["patched"], results["unpatched"],
                         (out / "patched-dumps", out / "unpatched-dumps"))
    for name, g in verdict["groups"].items():
        g["patched_panics_caught"] = sum(panics["patched"].get(i, 0)
                                         for i, cs in enumerate(cases) if (cs.group or cs.kind) == name)
    c.expect("corpus: cases ran", len(cases) > 0 and len(results["patched"]) == len(cases))
    c.expect("corpus: no abort in the patched library, expected results, unchanged results "
             "wherever unpatched 3.3.2 does not abort, and every abort class reached",
             not verdict["failures"], "; ".join(verdict["failures"][:20]))
    for cls, k in verdict["classes"].items():
        c.expect(f"abort class '{cls}': unpatched 3.3.2 aborts on it", k["unpatched_aborts"] > 0,
                 str(k))
    c.expect("corpus: the patched library caught panics at the boundary",
             sum(panics["patched"].values()) > 0, str(sum(panics["patched"].values())))

    report["corpus"] = verdict
    report["corpus"]["patched_panics_caught"] = sum(panics["patched"].values())
    report["checks"] = c.results
    report["finished"] = now()
    write_json(out / "libdovi-test.json", report)
    summary = t.summary_markdown(verdict) + "\n" + "\n".join(
        f"- {'PASS' if r['ok'] else 'FAIL'}: {r['check']}" for r in c.results) + "\n" + (
        f"\nToolchain: {rust['rustc']}, {rust['cargo']}, {cargo_c}. Patched tree "
        f"`{report['variants']['patched']['tree'][:16]}...`; patched panics caught: "
        f"{report['corpus']['patched_panics_caught']}.\n")
    (out / "libdovi-test.md").write_text(summary)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write(summary)
    log("\n" + summary)
    failed = [r for r in c.results if not r["ok"]]
    if failed:
        raise Failure(f"{len(failed)} of {len(c.results)} libdovi test checks failed")
    log(f"All {len(c.results)} libdovi test checks passed.")


# --------------------------------------------------------------------- main

def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)

    def common(p):
        p.add_argument("--work", type=Path, default=default_dir("LUCID_WORK", "lucid-engine"),
                       help="work directory, outside any git repository")
        p.add_argument("--downloads", type=Path,
                       default=default_dir("LUCID_DOWNLOADS", "lucid-downloads"),
                       help="download cache")

    sub.add_parser("check-allowlist", help="refuse fetches from projects that are not allowlisted")
    p = sub.add_parser("fetch", help="download and verify every pinned input")
    common(p)
    p.add_argument("--only", help="comma-separated pins.ini section prefixes to fetch")
    p = sub.add_parser("test-libdovi", help="run the malformed RPU corpus against patched and "
                       "unpatched libdovi on the host")
    p.add_argument("--work", type=Path,
                   default=default_dir("LUCID_LIBDOVI_TEST", "lucid-libdovi-test"),
                   help="work directory for the test (replaced on each run)")
    p.add_argument("--downloads", type=Path,
                   default=default_dir("LUCID_DOWNLOADS", "lucid-downloads"), help="download cache")
    p = sub.add_parser("build", help="build one slice")
    common(p)
    p.add_argument("--slice", required=True, choices=sorted(SLICES))
    p = sub.add_parser("check", help="verify one built slice and finish its provenance report")
    common(p)
    p.add_argument("--slice", required=True, choices=sorted(SLICES))
    p.add_argument("--strict", action="store_true", help="also require the pinned Xcode")
    p = sub.add_parser("test", help="run the decoder tests built from a slice's patched trees")
    common(p)
    p.add_argument("--slice", required=True, choices=sorted(SLICES))
    p = sub.add_parser("package", help="assemble xcframeworks from built slices")
    p.add_argument("--input", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True)
    args = parser.parse_args(argv)
    handlers = {"check-allowlist": cmd_check_allowlist, "fetch": cmd_fetch, "build": cmd_build,
                "check": cmd_check, "test": cmd_test, "package": cmd_package,
                "test-libdovi": cmd_test_libdovi}
    try:
        handlers[args.command](args)
    except Failure as e:
        print(f"\nerror: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
