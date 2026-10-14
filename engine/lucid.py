#!/usr/bin/env python3
"""Lucid Engine build tool.

Builds every library of Vivid's media engine (libdovi, FreeType, FriBidi,
HarfBuzz, libunibreak, Little CMS, shaderc, MoltenVK, libplacebo, uavs3d,
libbluray, uchardet, dav1d, libass, FFmpeg and libmpv) from pinned upstream
sources plus Vivid's patch series, packages them as static xcframeworks and
writes a provenance report.

    python3 engine/lucid.py check-allowlist
    python3 engine/lucid.py fetch
    python3 engine/lucid.py cache-key --slice tvos-arm64
    python3 engine/lucid.py build --slice tvos-arm64 [--cache DIR]
    python3 engine/lucid.py test-audio --slice tvos-arm64
    python3 engine/lucid.py check --slice tvos-arm64
    python3 engine/lucid.py test --slice tvos-arm64
    python3 engine/lucid.py test-vo --slice tvos-arm64
    python3 engine/lucid.py package --input DIR --out DIR
    python3 engine/lucid.py test-libdovi
    python3 engine/lucid.py test-libass

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
import inspect
import json
import os
import plistlib
import re
import shlex
import shutil
import struct
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

# Every download must start with one of these (scheme, host and project):
# upstream projects and their official release hosts only.
FETCH_ALLOWED = (
    "https://github.com/FFmpeg/",
    "https://github.com/mpv-player/",
    "https://github.com/libass/",
    "https://github.com/videolan/",
    "https://github.com/mesonbuild/",
    "https://github.com/ninja-build/",
    "https://github.com/Kitware/",  # CMake release binary
    "https://github.com/quietvoid/",  # libdovi (dovi_tool) source
    "https://github.com/lu-zero/",  # cargo-c release binary
    "https://github.com/freetype/",  # FreeType (official mirror)
    "https://github.com/fribidi/",
    "https://github.com/harfbuzz/",
    "https://github.com/adah1972/",  # libunibreak
    "https://github.com/mm2/",  # Little CMS
    "https://github.com/haasn/",  # libplacebo (official mirror)
    "https://github.com/fastfloat/",  # libplacebo's 3rdparty/fast_float
    "https://github.com/Dav1dde/",  # libplacebo's 3rdparty/glad
    "https://github.com/pallets/",  # libplacebo's 3rdparty/jinja and markupsafe
    "https://github.com/KhronosGroup/",  # MoltenVK, Vulkan-Headers, SPIRV-*, glslang
    "https://github.com/USCiLab/",  # cereal, for MoltenVK
    "https://github.com/google/shaderc/",
    "https://github.com/uavs3/",
    "https://download.videolan.org/pub/videolan/libbluray/",  # release tarball
    "https://www.freedesktop.org/software/uchardet/releases/",  # release tarball
    "https://static.rust-lang.org/dist/",  # Rust toolchain components
    "https://static.crates.io/crates/",  # crates in libdovi's Cargo.lock
)
# Hosts that may appear in references (upstream homes, patch descriptions,
# the GNU licence address in the licence header of new source files, the
# URL field of FreeType's pkg-config file, and Microsoft's typography
# documentation, which upstream libass code cites).
REFERENCE_HOSTS = {"github.com", "code.videolan.org", "gitlab.freedesktop.org", "trac.ffmpeg.org",
                   "www.gnu.org", "freetype.org", "learn.microsoft.com"}
# Projects nothing here may reference: third-party build repositories and
# their binaries. Split so this file does not match itself.
DENIED = ("edde" "746", "mpv" "kit", "mpv-" "build", "ple" "zy")
FETCH_WORDS = re.compile(r"\b(curl|wget|urlopen|urlretrieve|git clone|git fetch)\b")

# Info.plist values of every framework. The identifier prefix is Vivid's own
# (blurbery's decision); the version and MinimumOSVersion keep today's values
# (facts 4.1 and 1.7, ITMS-90208).
PLIST_ID_PREFIX = "com.blurbery.vivid.lucid."
PLIST_VERSION = "87.88.520"
PLIST_MINIMUM_OS = "100.0"

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

# The libraries FFmpeg, libass and libmpv depend on, built here from upstream
# source (build facts for the libraries: docs/cores/lucid-engine-libs-build-facts.md).
# Each is installed on its own (`<work>/<slice>/deps/<name>`), can be reused
# from the dependency cache (`lucid.py build --cache`), and is checked against
# what today's interim build ships, recorded in engine/config/expected-libs/.
@dataclass(frozen=True)
class Dep:
    framework: str       # framework (or, for MoltenVK, static library) name
    library: str         # the installed static library the framework wraps
    pkgconfig: tuple     # pkg-config files consumers use
    needs: tuple = ()    # libraries whose pkg-config files and headers it uses
    kind: str = "framework"


# In build order: the quick ones first, then the three that take longest.
DEPS = {
    "freetype": Dep("Libfreetype", "libfreetype.a", ("freetype2",)),
    "fribidi": Dep("Libfribidi", "libfribidi.a", ("fribidi",)),
    "harfbuzz": Dep("Libharfbuzz", "libharfbuzz.a", ("harfbuzz",)),
    "unibreak": Dep("Libunibreak", "libunibreak.a", ("libunibreak",)),
    "lcms2": Dep("lcms2", "liblcms2.a", ("lcms2",)),
    "uavs3d": Dep("Libuavs3d", "libuavs3d.a", ("uavs3d",)),
    "libbluray": Dep("Libbluray", "libbluray.a", ("libbluray",), ("freetype",)),
    "uchardet": Dep("Libuchardet", "libuchardet.a", ("uchardet",)),
    "shaderc": Dep("Libshaderc_combined", "libshaderc_combined.a", ("shaderc",)),
    "moltenvk": Dep("MoltenVK", "libMoltenVK.a", ("vulkan",), kind="library"),
    "libplacebo": Dep("Libplacebo", "libplacebo.a", ("libplacebo",),
                      ("libdovi", "lcms2", "shaderc", "moltenvk")),
}
def dep_of(framework: str) -> str | None:
    """The dependency library a framework (or library) name belongs to."""
    return next((lib for lib, d in DEPS.items() if d.framework == framework), None)


BUILD_ORDER = ("libdovi",) + tuple(DEPS) + ("dav1d", "libass", "ffmpeg", "mpv")
BUILT_FRAMEWORKS = ({"Libdovi", "Libdav1d", "Libass", "Libmpv"} | {f"Lib{ff}" for ff in FFMPEG_LIBS}
                    | {d.framework for d in DEPS.values() if d.kind == "framework"})
BUILT_LIBRARIES = {d.framework for d in DEPS.values() if d.kind == "library"}
EXPECTED_LIBS = CONFIG / "expected-libs"
CMAKE_COMMON = ("-DBUILD_SHARED_LIBS=0", "-DCMAKE_BUILD_TYPE=Release",
                f"-DCMAKE_INSTALL_PREFIX={PREFIX}", "-DCMAKE_OSX_ARCHITECTURES=arm64",
                "-DCMAKE_POLICY_VERSION_MINIMUM=3.5", "-DCMAKE_SYSTEM_PROCESSOR=arm64",
                "-DCMAKE_VERBOSE_MAKEFILE=0")
# The build host's Python for CMake projects' generator scripts (Xcode's,
# the one meson runs under), so no other Python on the runner is picked up.
HOST_PYTHON = "/usr/bin/python3"
CRATES_URL = "https://static.crates.io/crates/{name}/{name}-{version}.crate"
CRATES_IO = "registry+https://github.com/rust-lang/crates.io-index"
HOST_RUST_TARGET = "aarch64-apple-darwin"
# libdovi as today's engine ships it: header SHA-256, exported C API and the
# functions libplacebo calls, recorded from the last green run (facts 2.7).
LIBDOVI_EXPECTED = CONFIG / "expected-libdovi.txt"
OPENSSL_SYMBOL = re.compile(
    r"^_(SSL_|TLS_|DTLS_|OPENSSL_|OpenSSL_|EVP_|X509_|BIO_|ERR_|CRYPTO_|PEM_|RAND_|HMAC_)")
MPV_PATCH_MARKER = b"Still waiting for TrueHD major sync"  # from mpv patch 0001

# The AVFoundation audio output's frozen log formats (patch specification
# 2.9). Each must appear in Libmpv with its trailing newline. The standalone
# "falling back to PCM" also needs a NUL straight before it, because three
# other formats end with the same text.
AO_LOG_FORMATS = (
    "trace edge %s: clock %.3f, fed %.3f, latency %.3f",
    "first start recovery after %.3f s",
    "resuming compressed feed after audio EOF",
    "compressed clock engaged after %.3f s, seeked %d, anchors %d",
    "compressed clock resumed after %.3f s, anchors %d",
    "item status %d -> %d, time control %d -> %d, pos %.3fs, fed %.3fs",
    "heartbeat: raw pos %.3fs, clamped %.3fs, fed %.3fs, status %d, tc %d, reader gap %lld B",
    "pcm: clock %.3f, fed %.3f, ahead %.3f, rate %.3f, status %d, latency %.3f, sufficient %d",
    "notification name: %s",
    "notification flush time %.3f, current %d",
    "pcm fresh sink after reset",
    "pcm fresh sink failed; requesting audio reload",
    "pcm renderer failed; requesting audio reload",
    "restarting due to system notification; this will cause desync",
    "elementary stream window overflow; falling back to PCM",
    "discarding burst with odd payload length",
    "discarding burst without syncframe",
    "skipping unexpected IEC 61937 data type 0x%x",
    "skipping burst with invalid payload length %d",
    "no IEC 61937 sync found in %d bytes; falling back to PCM",
    "loader requested offset %lld below the retained window at %lld",
    "playback did not engage; seeking to the stream start",
    "native compressed playback did not start; falling back to PCM",
    "player rejected the compressed stream: %s (%s:%ld)",
    "falling back to PCM",
)
AO_STANDALONE_FALLBACK = b"\0falling back to PCM\n"
# Option-name and Vivid markers (2.10). The option table stores short names.
AO_MARKERS = (b"manage-audio-session\0", b"compressed-anchor-start\0", b"compressed-lead",
              b"first start recovery after", b"trace edge %s")
AO_TVOS_OPTION = b"max-lookahead"
# Behaviour that must be compiled in (8.6, item 3).
AO_SYMBOL = "_AVSampleBufferAudioRendererOutputConfigurationDidChangeNotification"
AO_SELECTORS = (b"setDelaysRateChangeUntilHasSufficientMediaData:\0",
                b"setSupportsMultichannelContent:error:\0")
# The audio output's test vectors (9.3), built against the patched tree.
AUDIO_TEST = ENGINE / "tests" / "ao_avfoundation_vectors.c"
AUDIO_TEST_SOURCES = ("ao_avfoundation_core.c", "ao_avfoundation_pcm.c",
                      "ao_avfoundation_iec61937.c", "ao_avfoundation_startup.c",
                      "ao_avfoundation_compressed.c")

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
# FFmpeg for the build host, from the slice's patched tree, for the
# VideoToolbox glue test (engine/tests/ffmpeg/vt_glue_tests.m): libavutil,
# libavcodec and libavformat with only the HEVC decoder and parser, the
# hevc_videotoolbox hwaccel, the raw HEVC demuxer and the file protocol,
# under AddressSanitizer. Everything else is off, so nothing on the build
# host is detected or linked.
HOST_FFMPEG_CONFIGURE = (
    "--disable-everything", "--disable-autodetect", "--disable-programs", "--disable-doc",
    "--disable-network", "--disable-avdevice", "--disable-avfilter", "--disable-swscale",
    "--disable-swresample", "--disable-asm", "--enable-static", "--disable-shared",
    "--enable-pthreads", "--enable-videotoolbox", "--enable-decoder=hevc", "--enable-parser=hevc",
    "--enable-hwaccel=hevc_videotoolbox", "--enable-demuxer=hevc", "--enable-protocol=file",
    "--toolchain=clang-asan", "--cc=clang",
)
HOST_FFMPEG_LIBS = ("avformat", "avcodec", "avutil")
HOST_FFMPEG_REQUIRED = {
    "config.h": ("CONFIG_VIDEOTOOLBOX", "HAVE_PTHREADS"),
    "config_components.h": ("CONFIG_HEVC_DECODER", "CONFIG_HEVC_PARSER",
                            "CONFIG_HEVC_VIDEOTOOLBOX_HWACCEL", "CONFIG_HEVC_DEMUXER",
                            "CONFIG_FILE_PROTOCOL"),
}
GLUE_TEST_STREAM = DECODER_TESTS / "main10-64x64.hevc"


@dataclass(frozen=True)
class Slice:
    name: str            # xcframework library identifier Xcode derives
    sdk: str             # xcrun SDK
    target: str          # clang -target, {v} = minimum OS
    min_flag: str        # version-min flag, {v} = minimum OS
    subsystem: str       # meson host_machine subsystem
    plist_platform: str  # CFBundleSupportedPlatforms
    macho_platform: int  # LC_BUILD_VERSION platform
    tvos: bool
    simulator: bool
    rust_target: str     # Rust target triple for libdovi
    version_min_cmd: str  # older load command naming the platform (device slices)
    cmake_system: str    # CMAKE_SYSTEM_NAME
    # configure --host: the canonical form (aarch64) of today's arm64-ios-darwin
    # and arm64-tvos-darwin (facts 1.4), which libunibreak's config.sub of
    # 2018 does not recognise. It is the same host.
    autotools_host: str
    mvk_platform: str    # MoltenVK: xcodebuild generic/platform= and make target
    mvk_make: str


SLICES = {s.name: s for s in (
    Slice("ios-arm64", "iphoneos", "arm64-apple-ios{v}", "-mios-version-min={v}",
          "ios", "iPhoneOS", 2, False, False, "aarch64-apple-ios", "LC_VERSION_MIN_IPHONEOS",
          "iOS", "aarch64-ios-darwin", "iOS", "ios"),
    Slice("ios-arm64-simulator", "iphonesimulator", "arm64-apple-ios{v}-simulator",
          "-mios-simulator-version-min={v}", "ios-simulator", "iPhoneSimulator", 7, False, True,
          "aarch64-apple-ios-sim", "", "iOS", "aarch64-ios-darwin", "iOS Simulator", "iossim"),
    Slice("tvos-arm64", "appletvos", "arm64-apple-tvos{v}", "-mtvos-version-min={v}",
          "tvos", "AppleTVOS", 3, True, False, "aarch64-apple-tvos", "LC_VERSION_MIN_TVOS",
          "tvOS", "aarch64-tvos-darwin", "tvOS", "tvos"),
    Slice("tvos-arm64-simulator", "appletvsimulator", "arm64-apple-tvos{v}-simulator",
          "-mtvos-simulator-version-min={v}", "tvos-simulator", "AppleTVSimulator", 8, True, True,
          "aarch64-apple-tvos-sim", "", "tvOS", "aarch64-tvos-darwin", "tvOS Simulator", "tvossim"),
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


def embedded_commit(pin) -> str:
    """The commit id a pinned archive must embed: GitHub's archives embed the
    commit they were made from; a project's own release tarball embeds none."""
    return "" if pin.get("release_tarball") == "yes" else pin["commit"]


def source_parts(pins, lib: str) -> list[tuple[str, str]]:
    """The further archives a source tree is assembled from, in order, as
    (part name, folder in the tree): submodules and fetched externals."""
    return [tuple(p.split(":", 1)) for p in pins[f"source:{lib}"].get("parts", "").split()]


def assemble_source(pins, downloads: Path, lib: str, dest: Path) -> list[dict]:
    """Extract the library's archive into dest, then each part into its folder,
    which must be absent or empty in the archives extracted before it."""
    pin = pins[f"source:{lib}"]
    extract_tar(downloads / download_name(f"source:{lib}", pin["url"]), dest)
    parts = []
    for name, rel in source_parts(pins, lib):
        section = f"part:{name}"
        part_pin = pins[section]
        archive = downloads / download_name(section, part_pin["url"])
        target = dest / rel
        if target.is_symlink() or (target.exists() and any(target.iterdir())):
            raise Failure(f"{lib}: {rel} is not empty in the archives before {name}")
        extract_tar(archive, target)
        parts.append({"part": name, "path": rel, "version": part_pin["version"],
                      "url": part_pin["url"], "archive": archive.name,
                      "sha256": sha256_file(archive), "commit": part_pin["commit"],
                      "archive_commit": archive_commit(archive)})
    return parts


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
        if not section.startswith(("toolchain", "tool:", "rust:", "source:", "part:")):
            problems.append(f"pins.ini [{section}]: not a known kind of pin")
        url = pins[section].get("url")
        if url and not url.startswith(FETCH_ALLOWED):
            problems.append(f"pins.ini [{section}] url: not an allowlisted project: {url}")
        if url and not re.fullmatch(r"[0-9a-f]{64}", pins[section].get("sha256", "")):
            problems.append(f"pins.ini [{section}] url: no SHA-256")
    used = set()
    for section in pin_sections(pins, "source"):
        lib = section.split(":", 1)[1]
        for name, _ in source_parts(pins, lib):
            used.add(f"part:{name}")
            if f"part:{name}" not in pins:
                problems.append(f"pins.ini [{section}]: no [part:{name}]")
        if not (PATCHES / lib / "series").is_file():
            problems.append(f"pins.ini [{section}]: no engine/patches/{lib}/series")
    for section in set(pin_sections(pins, "part")) - used:
        problems.append(f"pins.ini [{section}]: no source uses it")
    if set(pin_sections(pins, "source")) != {f"source:{lib}" for lib in BUILD_ORDER}:
        problems.append("pins.ini: the [source:*] sections differ from the build order")
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
        if section.startswith(("source:", "part:")):
            commit, expected = archive_commit(dest), embedded_commit(pin)
            if commit != expected:
                raise Failure(f"{dest.name}: archive commit {commit or 'none'}, "
                              f"expected {expected or 'none (release tarball)'}")
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
    cmake: Path | None = None     # the pinned CMake
    toolchain_summary: dict | None = None  # recorded with each dependency build

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

    def dep_destdir(self, lib: str) -> Path:
        """Where a dependency library's build installs it (DESTDIR)."""
        return self.work / "deps-stage" / lib

    def dep_staged(self, lib: str) -> Path:
        """The installed prefix inside the DESTDIR."""
        return self.dep_destdir(lib) / PREFIX.lstrip("/")

    def dep_prefix(self, lib: str) -> Path:
        """The dependency's installed files (include/, lib/), from which the
        libraries after it build, as today's builds had them: the same
        folder layout gives the same paths in compiled-in assertion texts."""
        return self.work / "deps" / lib

    def logfile(self, name: str) -> Path:
        return self.out / "logs" / f"{name}.log"


def prepare_tools(pins, downloads: Path, root: Path) -> tuple[list[str], str, str, Path, Path]:
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
    extract_tar(downloads / download_name("tool:cmake", pins["tool:cmake"]["url"]), tools / "cmake")
    cmake = tools / "cmake" / "CMake.app" / "Contents" / "bin" / "cmake"
    version = run([cmake, "--version"], capture=True).split()
    if version[:3] != ["cmake", "version", pins["tool:cmake"]["version"]]:
        raise Failure(f"pinned CMake {pins['tool:cmake']['version']}, found {' '.join(version[:3])}")
    (bindir / "cmake").symlink_to(cmake)
    host_pkg_config = shutil.which("pkg-config")
    if not host_pkg_config:
        raise Failure("pkg-config is required (the CI runner image provides pkgconf)")
    (bindir / "pkg-config").symlink_to(host_pkg_config)
    python = HOST_PYTHON  # Xcode's Python runs meson and mpv's build scripts
    return [python, str(tools / "meson" / "meson.py")], str(bindir / "ninja"), \
        str(bindir / "pkg-config"), bindir, cmake


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


def stage_dep(ctx: Ctx, lib: str) -> list[str]:
    """Make an installed dependency visible to the libraries built after it:
    copy its pkg-config files into the slice's pkg-config folder, pointed at
    its own install folder. The installed files themselves keep the prefix
    /lucid-engine, so a cached copy stays valid in any work folder."""
    pc_dir = ctx.work / "pkgconfig"
    pc_dir.mkdir(parents=True, exist_ok=True)
    staged = []
    for pc in sorted((ctx.dep_prefix(lib) / "lib" / "pkgconfig").glob("*.pc")):
        (pc_dir / pc.name).write_text(rewrite_prefix(pc.read_text(), ctx.dep_prefix(lib)))
        staged.append(pc.name)
    missing = [n for n in DEPS[lib].pkgconfig if f"{n}.pc" not in staged]
    if missing:
        raise Failure(f"{lib}: no {', '.join(missing)}.pc installed")
    return staged


def write_system_pc(sdk: Path, pc_dir: Path) -> None:
    """pkg-config files for the SDK's zlib and libxml2 (FFmpeg, FreeType, libbluray)."""
    zlib = c_string(define(sdk / "usr/include/zlib.h", "ZLIB_VERSION"))
    xml = c_string(define(sdk / "usr/include/libxml2/libxml/xmlversion.h", "LIBXML_DOTTED_VERSION"))
    if not zlib or not xml:
        raise Failure(f"could not read the zlib or libxml2 version from {sdk}")
    pc_dir.mkdir(parents=True, exist_ok=True)
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
    parts = assemble_source(ctx.pins, ctx.downloads, lib, src)
    pristine = tree_files(src)
    applied = apply_series(lib, src, ctx.logfile(f"{lib}-patch"))
    patched = tree_files(src)
    changed = sorted(p for p in set(pristine) | set(patched) if pristine.get(p) != patched.get(p))
    declared = sorted(set().union(*[patch_paths(PATCHES / p["file"]) for p in applied]))
    if changed != declared:
        raise Failure(f"{lib}: changed files {changed} differ from the series' files {declared}")
    return {"version": pin["version"], "commit": pin["commit"], "url": pin["url"],
            "archive": archive.name, "sha256": sha256_file(archive),
            "archive_commit": archive_commit(archive), "embedded_commit": embedded_commit(pin),
            "parts": parts, "patches": applied, "pristine_tree": tree_digest(pristine),
            "patched_tree": tree_digest(patched), "changed_files": changed}


def write_cross_file(ctx: Ctx, path: Path, ndebug: bool, flags: list[str] | None = None,
                     properties: tuple = ()) -> None:
    flags = ctx.flags if flags is None else flags

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
        *properties,
        "",
        "[built-in options]",
        f"prefix = {PREFIX!r}",
        "buildtype = 'release'",
        "default_library = 'static'",
    ]
    if ndebug:
        lines.append("b_ndebug = 'true'")
    for lang in ("c", "cpp", "objc", "objcpp"):
        lines.append(f"{lang}_args = {arr(flags)}")
        lines.append(f"{lang}_link_args = {arr(['-lc++'] + flags)}")
    path.write_text("\n".join(lines) + "\n")


def rewrite_prefix(text: str, prefix: Path) -> str:
    """A pkg-config file's paths under /lucid-engine, pointed at prefix."""
    return re.sub(rf"(^|[=\s]|-I|-L){re.escape(PREFIX)}(?=/|\s|$)",
                  lambda m: m.group(1) + str(prefix), text, flags=re.M)


def rewrite_installed_pc(ctx: Ctx) -> None:
    """Point the installed pkg-config files at the staged prefix."""
    for pc in (ctx.prefix / "lib" / "pkgconfig").glob("*.pc"):
        pc.write_text(rewrite_prefix(pc.read_text(), ctx.prefix))


MESON_BUILTINS = ("buildtype", "optimization", "debug", "b_ndebug", "b_lto", "default_library",
                  "b_staticpic", "wrap_mode")


def build_meson(ctx: Ctx, lib: str, options: list[str], ndebug: bool,
                dest: Path | None = None, flags: list[str] | None = None,
                properties: tuple = ()) -> dict:
    """Configure, build and install a meson project; returns the options meson
    reports for the configured build (the built-ins above and every -D option
    passed), read back with `meson introspect`."""
    cross = ctx.work / f"cross-{lib}.ini"
    write_cross_file(ctx, cross, ndebug, flags, properties)
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
        run(ctx.meson + ["install", "-C", build, "--destdir", dest or ctx.install, "--no-rebuild"],
            env=env, logfile=logfile)
    finally:
        meson_log = build / "meson-logs" / "meson-log.txt"
        if meson_log.exists():
            shutil.copy2(meson_log, ctx.out / "logs" / f"{lib}-meson-log.txt")
    if dest is None:
        rewrite_installed_pc(ctx)
    wanted = set(MESON_BUILTINS) | {o[2:].split("=", 1)[0] for o in options if o.startswith("-D")}
    found = json.loads(run(ctx.meson + ["introspect", "--buildoptions", build], env=env,
                           capture=True))
    return {o["name"]: o["value"] for o in found if o["name"] in wanted}


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


# ------------------------------------------------------- dependency builds
#
# Each library is built with its upstream build system and the options of
# engine/config/<name>-*.txt (facts 1.4 and 3.1 to 3.11), installed with
# DESTDIR into its own folder, pruned to what consumers use, and recorded.

def dep_minimum_os(pins, lib: str) -> str:
    """The deployment target a library is compiled for (facts 1.3)."""
    return pins[f"source:{lib}"].get("minimum_os", pins["toolchain"]["minimum_os"])


def dep_flags_env(ctx: Ctx, lib: str) -> tuple[list[str], dict]:
    """The compiler flags and build environment of facts 1.4 for one library,
    at its own deployment target."""
    flags = compile_flags(ctx.sl, ctx.sdk, dep_minimum_os(ctx.pins, lib))
    env = dict(ctx.env)
    joined = " ".join(flags)
    for var in ("CFLAGS", "CPPFLAGS", "CXXFLAGS", "ASMFLAGS"):
        env[var] = joined
    env["LDFLAGS"] = "-lc++ " + joined
    return flags, env


def cross_properties(lib: str) -> tuple:
    """Extra cross-file properties for a library (engine/config/<lib>-cross.txt),
    one `name = value` per line: meson's has_function_<name> overrides."""
    path = CONFIG / f"{lib}-cross.txt"
    if not path.exists():
        return ()
    lines = [re.sub(r"(^|\s)#.*$", "", l).strip() for l in path.read_text().splitlines()]
    props = tuple(l for l in lines if l)
    bad = [p for p in props if not re.fullmatch(r"has_function_\w+ = (true|false)", p)]
    if bad:
        raise Failure(f"{path.name}: not a has_function override: {bad}")
    return props


def build_meson_dep(ctx: Ctx, lib: str) -> dict:
    """A meson library with meson's default b_ndebug=false (assertions as
    upstream builds them), not the libass and mpv cross file's true."""
    flags, _ = dep_flags_env(ctx, lib)
    options = read_list(CONFIG / f"{lib}-meson.txt")
    properties = cross_properties(lib)
    return {"meson_options": options, "cross_properties": list(properties),
            "meson": build_meson(ctx, lib, options, ndebug=False, dest=ctx.dep_destdir(lib),
                                 flags=flags, properties=properties)}


def cmake_cache(path: Path) -> dict[str, str]:
    values = {}
    for line in path.read_text(errors="replace").splitlines():
        m = re.match(r"^([A-Za-z_][\w.-]*):\w+=(.*)$", line)
        if m:
            values[m.group(1)] = m.group(2)
    return values


def build_cmake(ctx: Ctx, lib: str, src: Path, options: list[str], targets: tuple = (),
                build: Path | None = None) -> dict:
    """Configure with CMake's Makefile generator and the common values of
    facts 1.4, build with make (only `targets` if given) and install."""
    _, env = dep_flags_env(ctx, lib)
    build = build or ctx.build(lib)
    logfile = ctx.logfile(lib)
    args = [ctx.cmake, "-S", src, "-B", build, "-G", "Unix Makefiles", *CMAKE_COMMON,
            f"-DCMAKE_OSX_SYSROOT={ctx.sl.sdk}", f"-DCMAKE_SYSTEM_NAME={ctx.sl.cmake_system}",
            f"-DPython_EXECUTABLE={HOST_PYTHON}", f"-DPython3_EXECUTABLE={HOST_PYTHON}", *options]
    try:
        run(args, env=env, logfile=logfile)
        run(["make", f"-j{os.cpu_count() or 4}", *targets], cwd=build, env=env, logfile=logfile)
        if targets:
            # Installs what the install rules name, without building the rest.
            run([ctx.cmake, "--install", build], env={**env, "DESTDIR": str(ctx.dep_destdir(lib))},
                logfile=logfile)
        else:
            run(["make", "install", f"DESTDIR={ctx.dep_destdir(lib)}"], cwd=build, env=env,
                logfile=logfile)
    finally:
        for name in ("CMakeCache.txt", "CMakeFiles/CMakeConfigure.log"):
            if (build / name).exists():
                shutil.copy2(build / name, ctx.out / "logs" / f"{lib}-{Path(name).name}")
    cache = cmake_cache(build / "CMakeCache.txt")
    keys = [a[2:].split("=", 1)[0] for a in list(CMAKE_COMMON) + options if a.startswith("-D")]
    keys += ["CMAKE_OSX_SYSROOT", "CMAKE_SYSTEM_NAME", "CMAKE_C_FLAGS", "CMAKE_CXX_FLAGS",
             "CMAKE_C_FLAGS_RELEASE", "CMAKE_CXX_FLAGS_RELEASE", "CMAKE_ASM_FLAGS"]
    return {"cmake_options": options, "targets": list(targets),
            "cmake": {k: cache.get(k) for k in keys}}


def build_unibreak(ctx: Ctx) -> dict:
    """libunibreak with its own configure script and the cross flags as
    CFLAGS, so autoconf adds no -O (unoptimised, as today: facts 3.4)."""
    lib = "unibreak"
    _, env = dep_flags_env(ctx, lib)
    build = ctx.build(lib)
    build.mkdir(parents=True, exist_ok=True)
    logfile = ctx.logfile(lib)
    args = [f"--prefix={PREFIX}"] + read_list(CONFIG / "unibreak-configure.txt") + \
        [f"--host={ctx.sl.autotools_host}"]
    try:
        run([ctx.src(lib) / "configure"] + args, cwd=build, env=env, logfile=logfile)
        run(["make", f"-j{os.cpu_count() or 4}"], cwd=build, env=env, logfile=logfile)
        run(["make", "install", f"DESTDIR={ctx.dep_destdir(lib)}"], cwd=build, env=env, logfile=logfile)
    finally:
        if (build / "config.log").exists():
            shutil.copy2(build / "config.log", ctx.out / "logs" / f"{lib}-config.log")
    makefile = (build / "src" / "Makefile").read_text()
    made = {k: (re.search(rf"^{k} = (.*)$", makefile, re.M) or [None, None])[1]
            for k in ("CC", "CFLAGS", "CPPFLAGS", "LDFLAGS", "libunibreak_la_CFLAGS")}
    return {"configure": args, "make_variables": made}


def build_shaderc(ctx: Ctx) -> dict:
    """shaderc with glslang, SPIRV-Tools and SPIRV-Headers in third_party/,
    as its DEPS file places them. Consumers resolve `shaderc` to the combined
    library, so shaderc.pc becomes upstream's shaderc_combined.pc (facts 3.8)."""
    lib = "shaderc"
    record = build_cmake(ctx, lib, ctx.src(lib), read_list(CONFIG / "shaderc-cmake.txt"))
    pc = ctx.dep_staged(lib) / "lib" / "pkgconfig"
    shutil.copy2(pc / "shaderc_combined.pc", pc / "shaderc.pc")
    return record


def build_uavs3d(ctx: Ctx) -> dict:
    """uavs3d writes version.h and uavs3d.pc into its source folder while
    configuring, so it is built from a copy. Only the library target is
    built: the uavs3dec test program is not (facts 3.9)."""
    lib = "uavs3d"
    tree = ctx.build(lib) / "tree"
    shutil.copytree(ctx.src(lib), tree, symlinks=True)
    record = build_cmake(ctx, lib, tree, read_list(CONFIG / "uavs3d-cmake.txt"),
                         targets=("uavs3d",), build=ctx.build(lib) / "build")
    version_h = tree / "version.h"
    record["version_h"] = {name: macro(version_h, name) for name in
                           ("VER_MAJOR", "VER_MINOR", "VER_BUILD", "VERSION_TYPE", "VERSION_STR",
                            "VERSION_SHA1")}
    return record


def build_uchardet(ctx: Ctx) -> dict:
    return build_cmake(ctx, "uchardet", ctx.src("uchardet"), read_list(CONFIG / "uchardet-cmake.txt"))


def moltenvk_env(ctx: Ctx) -> dict:
    """xcodebuild and MoltenVK's scripts get a plain environment: the Xcode
    project's own settings decide every compiler flag (facts 3.7)."""
    env = {k: os.environ[k] for k in ("HOME", "USER", "LOGNAME", "TMPDIR", "DEVELOPER_DIR")
           if k in os.environ}
    env.update({"PATH": os.pathsep.join(["/usr/bin", "/bin", "/usr/sbin", "/sbin"]),
                "LC_ALL": "C", "ZERO_AR_DATE": "1",
                "SOURCE_DATE_EPOCH": ctx.env["SOURCE_DATE_EPOCH"],
                "GIT_CEILING_DIRECTORIES": ctx.env["GIT_CEILING_DIRECTORIES"]})
    return env


def vulkan_header_version(include: Path) -> str:
    """The Vulkan API version of MoltenVK's headers: 1.4.<VK_HEADER_VERSION>."""
    core = include / "vulkan" / "vulkan_core.h"
    complete = define(core, "VK_HEADER_VERSION_COMPLETE") or ""
    m = re.fullmatch(r"VK_MAKE_API_VERSION\(0, (\d+), (\d+), VK_HEADER_VERSION\)", complete)
    if not m:
        raise Failure(f"no VK_HEADER_VERSION_COMPLETE in {core}")
    return f"{m.group(1)}.{m.group(2)}.{define(core, 'VK_HEADER_VERSION')}"


def write_vulkan_pc(ctx: Ctx, prefix: Path) -> None:
    """vulkan.pc for MoltenVK, which upstream does not produce (facts 3.7):
    the Khronos loader's name and today's fields, at the version of the
    Vulkan headers MoltenVK ships (1.4.334)."""
    frameworks = ["CoreFoundation", "CoreGraphics", "Foundation", "IOSurface", "Metal",
                  "QuartzCore", "UIKit"] + ([] if ctx.sl.tvos else ["IOKit"])
    pc_dir = prefix / "lib" / "pkgconfig"
    pc_dir.mkdir(parents=True, exist_ok=True)
    (pc_dir / "vulkan.pc").write_text(
        f"prefix={PREFIX}\nincludedir=${{prefix}}/include\nlibdir=${{prefix}}/lib\n\n"
        "Name: Vulkan-Loader\nDescription: Vulkan Loader\n"
        f"Version: {vulkan_header_version(prefix / 'include')}\n"
        "Libs: -L${libdir} -lMoltenVK " + " ".join(f"-framework {f}" for f in frameworks) + "\n"
        "Cflags: -I${includedir}\n")


def build_moltenvk(ctx: Ctx) -> dict:
    """MoltenVK by upstream's documented procedure for one platform (facts
    3.7). The source tree already holds the externals at the revisions in
    ExternalRevisions/, where fetchDependencies would put them, so of that
    script only its remaining steps run here, exactly as it runs them:
    unpacking SPIRV-Tools' pre-generated headers, building the external
    libraries for the platform and packaging them. Then upstream's Makefile
    target builds MoltenVK, with the command-line variables of
    engine/config/moltenvk-make.txt."""
    lib = "moltenvk"
    tree = ctx.build(lib) / "MoltenVK"
    shutil.copytree(ctx.src(lib), tree, symlinks=True)
    env = moltenvk_env(ctx)
    logfile = ctx.logfile(lib)
    revisions = {name: (tree / "ExternalRevisions" / f"{name}_repo_revision").read_text().strip()
                 for name in ("SPIRV-Cross", "SPIRV-Headers", "SPIRV-Tools", "Vulkan-Headers",
                              "cereal")}
    parts = {rel: ctx.pins[f"part:{name}"]["commit"] for name, rel in source_parts(ctx.pins, lib)}
    placed = {"SPIRV-Cross": "External/SPIRV-Cross", "Vulkan-Headers": "External/Vulkan-Headers",
              "SPIRV-Tools": "External/SPIRV-Tools", "cereal": "External/cereal",
              "SPIRV-Headers": "External/SPIRV-Tools/external/spirv-headers"}
    for name, rel in placed.items():
        if parts.get(rel) != revisions[name]:
            raise Failure(f"MoltenVK: {rel} is pinned at {parts.get(rel)}, "
                          f"ExternalRevisions/ says {revisions[name]}")
    run(["unzip", "-o", "-q", "-d", "External/SPIRV-Tools", "Templates/spirv-tools/build.zip"],
        cwd=tree, env=env, logfile=logfile)
    shutil.rmtree(tree / "External" / "SPIRV-Tools" / "__MACOSX", ignore_errors=True)
    platform = ctx.sl.mvk_platform
    # fetchDependencies exports KEEP_CACHE="" and SKIP_PACKAGING=Y around
    # this build, so the scheme's own packaging phases do nothing; it
    # packages afterwards, below.
    run(["xcodebuild", "-project", "ExternalDependencies.xcodeproj",
         "-scheme", f"ExternalDependencies-{ctx.sl.cmake_system}",
         "-destination", f"generic/platform={platform}", "-configuration", "Release",
         "-enableAddressSanitizer", "NO", "-enableThreadSanitizer", "NO",
         "-enableUndefinedBehaviorSanitizer", "NO",
         "-derivedDataPath", f"External/build/Intermediates/{platform}", "-quiet", "build"],
        cwd=tree, env={**env, "KEEP_CACHE": "", "SKIP_PACKAGING": "Y"}, logfile=logfile)
    run(["bash", "-c", ". ./Scripts/create_ext_lib_xcframeworks.sh && "
                       ". ./Scripts/package_ext_libs_finish.sh"],
        cwd=tree, env={**env, "PROJECT_DIR": ".", "CONFIGURATION": "Release", "SKIP_PACKAGING": "",
                       "KEEP_CACHE": ""}, logfile=logfile)
    variables = read_list(CONFIG / "moltenvk-make.txt")
    run(["make", ctx.sl.mvk_make] + variables, cwd=tree, env=env, logfile=logfile)
    package = tree / "Package" / "Release" / "MoltenVK"
    xcf = package / "static" / "MoltenVK.xcframework"
    info = plistlib.loads((xcf / "Info.plist").read_bytes())
    platform_id = "tvos" if ctx.sl.tvos else "ios"
    variant = "simulator" if ctx.sl.simulator else None
    found = [l for l in info["AvailableLibraries"] if l["SupportedPlatform"] == platform_id
             and l.get("SupportedPlatformVariant") == variant]
    if len(found) != 1:
        raise Failure(f"MoltenVK: no single {platform_id} {variant or 'device'} library in {xcf}")
    built = xcf / found[0]["LibraryIdentifier"] / found[0]["LibraryPath"]
    prefix = ctx.dep_staged(lib)
    (prefix / "lib").mkdir(parents=True)
    target = prefix / "lib" / DEPS[lib].library
    if "Non-fat" in run(["lipo", "-info", built], capture=True):
        shutil.copy2(built, target)
    else:
        run(["lipo", built, "-thin", "arm64", "-output", target], logfile=logfile)
    shutil.copytree(package / "include", prefix / "include", symlinks=False)
    write_vulkan_pc(ctx, prefix)
    return {"make": [ctx.sl.mvk_make] + variables, "external_revisions": revisions,
            "xcframework_library": found[0], "archs": found[0].get("SupportedArchitectures")}


DEP_BUILDERS = {
    "freetype": lambda ctx: build_meson_dep(ctx, "freetype"),
    "fribidi": lambda ctx: build_meson_dep(ctx, "fribidi"),
    "harfbuzz": lambda ctx: build_meson_dep(ctx, "harfbuzz"),
    "unibreak": build_unibreak,
    "lcms2": lambda ctx: build_meson_dep(ctx, "lcms2"),
    "shaderc": build_shaderc,
    "moltenvk": build_moltenvk,
    "libplacebo": lambda ctx: build_meson_dep(ctx, "libplacebo"),
    "uavs3d": build_uavs3d,
    "libbluray": lambda ctx: build_meson_dep(ctx, "libbluray"),
    "uchardet": build_uchardet,
}
# The functions whose code decides each library's build, for its cache key.
COMMON_BUILD_FUNCTIONS = ("compile_flags", "build_env", "dep_flags_env", "dep_minimum_os",
                          "write_cross_file", "build_meson", "build_meson_dep", "cross_properties",
                          "build_cmake",
                          "assemble_source", "prepare_source", "apply_series", "extract_tar",
                          "write_system_pc", "prune_dep")
DEP_FUNCTIONS = {
    "unibreak": ("build_unibreak",), "shaderc": ("build_shaderc",),
    "moltenvk": ("build_moltenvk", "moltenvk_env", "write_vulkan_pc", "vulkan_header_version"),
    "uavs3d": ("build_uavs3d", "macro"), "uchardet": ("build_uchardet",),
    "libdovi": ("build_libdovi", "cargo_cinstall", "cargo_env", "vendor_crates",
                "strip_embedded_bitcode", "install_rust", "install_cargo_c"),
}


def prune_dep(ctx: Ctx, lib: str) -> None:
    """Keep only what consumers and the framework use: the headers, the one
    static library and the consumers' pkg-config files; then move them from
    the DESTDIR to the dependency's own folder."""
    prefix = ctx.dep_staged(lib)
    keep = {f"lib/{DEPS[lib].library}"} | {f"lib/pkgconfig/{n}.pc" for n in DEPS[lib].pkgconfig}
    for path in sorted(prefix.rglob("*"), reverse=True):
        rel = path.relative_to(prefix).as_posix()
        if rel == "include" or rel.startswith("include/"):
            continue
        if path.is_dir() and not path.is_symlink():
            if not any(path.iterdir()):
                path.rmdir()
        elif rel not in keep:
            path.unlink()
    for rel in keep:
        if not (prefix / rel).is_file():
            raise Failure(f"{lib}: {rel} was not installed")
    for item in ctx.dep_destdir(lib).iterdir():
        if item.name != PREFIX.lstrip("/"):
            raise Failure(f"{lib}: installed {item.name} outside {PREFIX}")
    ctx.dep_prefix(lib).parent.mkdir(parents=True, exist_ok=True)
    prefix.rename(ctx.dep_prefix(lib))


def dep_key(pins, sl: Slice, lib: str) -> str:
    """Everything that decides a library's build output: its pins (source
    and parts, the toolchain and build tools), its patch series, its option
    files, the code of the functions that build it and the keys of the
    libraries it builds against. A cached build is reused only when its key
    is equal."""
    h = hashlib.sha256()

    def add(label: str, data) -> None:
        h.update(label.encode() + b"\0")
        h.update(data if isinstance(data, bytes) else str(data).encode())
        h.update(b"\0")

    add("slice", repr(sl))
    add("toolchain", [(k, pins["toolchain"][k]) for k in ("xcode", "minimum_os",
                                                          "source_date_epoch")])
    sections = [s for s in pins.sections() if s.startswith("tool:")]
    if lib == "libdovi":
        sections += [s for s in pins.sections() if s.startswith("rust:")]
    sections += [f"source:{lib}"] + [f"part:{n}" for n, _ in source_parts(pins, lib)]
    for section in sections:
        add(section, sorted(pins[section].items()))
    series = PATCHES / lib / "series"
    if series.exists():
        add("series", series.read_bytes())
        for _, patch in read_series(lib):
            add(patch.name, patch.read_bytes())
    for path in sorted(CONFIG.glob(f"{lib}-*.txt")):
        add(path.name, path.read_bytes())
    for name in COMMON_BUILD_FUNCTIONS + DEP_FUNCTIONS.get(lib, ()):
        add(name, inspect.getsource(globals()[name]))
    add("constants", (PREFIX, CMAKE_COMMON, HOST_PYTHON, MESON_BUILTINS, DEPS.get(lib)))
    for need in (DEPS[lib].needs if lib in DEPS else ()):
        add(f"needs {need}", dep_key(pins, sl, need))
    return h.hexdigest()


def deps_key(pins, sl: Slice) -> str:
    """One key for all of a slice's dependency builds."""
    return hashlib.sha256("".join(f"{lib} {dep_key(pins, sl, lib)}\n" for lib in DEPS)
                          .encode()).hexdigest()


def build_dep(ctx: Ctx, lib: str, cache: Path | None) -> dict:
    """Build one dependency, or reuse its cached build when the key is equal;
    either way stage its pkg-config files for the libraries after it."""
    key = dep_key(ctx.pins, ctx.sl, lib)
    entry = cache / ctx.sl.name / lib if cache else None
    if entry and (entry / "record.json").is_file() and (entry / "install").is_dir():
        record = json.loads((entry / "record.json").read_text())
        if record.get("key") == key:
            log(f"reusing the cached build of {lib} (key {key[:16]})")
            shutil.copytree(entry / "install", ctx.dep_prefix(lib), symlinks=True)
            record["cache"] = "reused"
            record["staged_pkgconfig"] = stage_dep(ctx, lib)
            return record
    source = prepare_source(ctx, lib)
    started = now()
    configuration = DEP_BUILDERS[lib](ctx)
    record = {"key": key, "source": source, "configuration": configuration,
              "post_build_tree": tree_digest(tree_files(ctx.src(lib))),
              "started": started, "finished": now(), "built_by": ctx.toolchain_summary}
    prune_dep(ctx, lib)
    if entry:
        if entry.exists():
            shutil.rmtree(entry)
        shutil.copytree(ctx.dep_prefix(lib), entry / "install", symlinks=True)
        write_json(entry / "record.json", record)
        with open(cache / ctx.sl.name / "new", "a") as f:
            f.write(lib + "\n")
    record["cache"] = "built"
    record["staged_pkgconfig"] = stage_dep(ctx, lib)
    return record


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


def dep_headers(lib: str, inc: Path) -> list[tuple[Path, str]]:
    """The framework's Headers/ content, laid out as today's (facts 3.1 to
    3.11 and engine/config/expected-libs/)."""
    def folders(*names):
        return [(inc / n, n) for n in names]

    def contents(folder):
        return [(p, p.name) for p in sorted(folder.iterdir())]
    return {
        "freetype": lambda: folders("freetype2"),
        "fribidi": lambda: folders("fribidi"),
        "harfbuzz": lambda: folders("harfbuzz"),
        "unibreak": lambda: contents(inc),
        "lcms2": lambda: contents(inc),
        "shaderc": lambda: folders("glslang", "shaderc", "spirv-tools"),
        "libplacebo": lambda: contents(inc / "libplacebo"),
        "uavs3d": lambda: contents(inc),
        "libbluray": lambda: contents(inc / "libbluray"),
        "uchardet": lambda: folders("uchardet"),
    }[lib]()


def package_deps(ctx: Ctx) -> list[dict]:
    made = []
    for lib, dep in DEPS.items():
        prefix = ctx.dep_prefix(lib)
        library = prefix / "lib" / dep.library
        if dep.kind == "library":
            dest = ctx.out / "libraries" / dep.framework / dep.library
            dest.parent.mkdir(parents=True)
            shutil.copy2(library, dest)
            made.append({"name": dep.framework, "library": dep.library,
                         "binary_sha256": sha256_file(dest), "headers": 0})
        else:
            made.append(make_framework(ctx, dep.framework, library,
                                       dep_headers(lib, prefix / "include")))
    return made


def package_frameworks(ctx: Ctx) -> list[dict]:
    inc = ctx.prefix / "include"
    lib = ctx.prefix / "lib"
    made = package_deps(ctx) + [
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
        "cmake": first([ctx.cmake, "--version"]),
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
    meson, ninja, pkg_config, bindir, cmake = prepare_tools(pins, args.downloads, root)
    rust = install_rust(pins, args.downloads, root / "tools" / "rust", [sl.rust_target])
    install_cargo_c(pins, args.downloads, root / "tools" / "cargo-c")
    sdk = sdk_path(sl.sdk)
    flags = compile_flags(sl, sdk, pins["toolchain"]["minimum_os"])
    ctx = Ctx(sl, pins, args.downloads, root, work, out, sdk, flags, {}, meson, ninja, pkg_config,
              root / "tools" / "rust", root / "tools" / "cargo-c", cmake)
    ctx.env = build_env(root, bindir, flags, ctx.pc_dirs, pins["toolchain"]["source_date_epoch"])
    report = {"slice": sl.name, "started": now(), "repository_commit": repo_commit(),
              "pins_sha256": sha256_file(ENGINE / "pins.ini"), "toolchain": toolchain(ctx)}
    report["toolchain"]["rust_std_targets"] = rust["std_targets"]
    ctx.toolchain_summary = {k: report["toolchain"][k] for k in
                             ("xcode", "sdk", "sdk_version", "clang", "meson", "ninja", "cmake",
                              "make")}
    write_system_pc(ctx.sdk, ctx.work / "pkgconfig")
    cache = args.cache.resolve() if args.cache else None
    if cache:
        # `complete` holds the key once every dependency is in the cache;
        # `new` lists the dependencies this run built and stored.
        (cache / sl.name).mkdir(parents=True, exist_ok=True)
        for other in cache.iterdir():
            if other.name != sl.name:  # only this slice's builds belong here
                shutil.rmtree(other) if other.is_dir() else other.unlink()
        (cache / sl.name / "complete").unlink(missing_ok=True)
        (cache / sl.name / "new").write_text("")
    report["sources"], report["deps"] = {}, {}
    for lib in BUILD_ORDER:
        log(f"\n==== {lib} ({sl.name})")
        if lib in DEPS:
            record = build_dep(ctx, lib, cache)
            report["sources"][lib] = record.pop("source")
            report["deps"][lib] = record
            if cache and lib == tuple(DEPS)[-1]:
                # Every dependency is built or reused: the cache is complete.
                (cache / sl.name / "complete").write_text(deps_key(pins, sl) + "\n")
                for stale in (cache / sl.name).iterdir():
                    if stale.is_dir() and stale.name not in DEPS:
                        shutil.rmtree(stale)
                if not (cache / sl.name / "new").read_text().strip():
                    log("every dependency was reused from the cache")
            continue
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


def check_trees(c: Checks, pins, ctx_work: Path, report: dict, tmp: Path) -> None:
    for lib, info in report["sources"].items():
        src = ctx_work / "src" / lib
        c.equal(f"{lib}: source archive commit", info["archive_commit"],
                info.get("embedded_commit", info["commit"]))
        for part in info.get("parts", []):
            c.equal(f"{lib}: {part['path']} archive commit", part["archive_commit"], part["commit"])
        if lib in DEPS:
            # Recorded straight after the library's build, which may have
            # been an earlier run's (the dependency cache).
            c.equal(f"{lib}: source tree unchanged by the build",
                    report["deps"][lib]["post_build_tree"], info["patched_tree"])
        else:
            c.equal(f"{lib}: source tree unchanged by the build",
                    tree_digest(tree_files(src)), info["patched_tree"])
        again = tmp / lib
        assemble_source(pins, Path(report["downloads"]), lib, again)
        pristine = tree_digest(tree_files(again))
        apply_series(lib, again)
        c.equal(f"{lib}: pristine archives re-extracted", pristine, info["pristine_tree"])
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
    if name in BUILT_LIBRARIES:
        binary = fw / DEPS[dep_of(name)].library
        c.equal(f"{name}: architectures", run(["lipo", "-archs", binary], capture=True).split(),
                ["arm64"])
        out = run(["otool", "-l", binary], capture=True)
        c.equal(f"{name}: LC_BUILD_VERSION platform",
                set(re.findall(r"^\s*platform (\S+)$", out, re.M)), {str(sl.macho_platform)})
        c.equal(f"{name}: minimum OS", set(re.findall(r"^\s*minos (\S+)$", out, re.M)),
                {minimum_os})
        c.equal(f"{name}: static library only (no headers or module, as today)",
                sorted(p.name for p in fw.iterdir()), [DEPS[dep_of(name)].library])
        return
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


# ------------------------------------------------------ dependency checks

NM_DEFINED = re.compile(r"^[0-9a-f]+ \(([^)]*)\) (?:\(alignment [^)]*\) )?(.*?external)"
                        r"(?: automatically hidden)?(?: \[[^\]]*\])* (\S+)$")


def defined_symbols(archive: Path) -> dict[str, str]:
    """Defined global symbols of an arm64 archive with their kind, as recorded
    in engine/config/expected-libs/: default, hidden (private extern),
    weak-default or weak-hidden. A line nm prints in another form is kept
    as kind `unparsed`, so the comparison shows it."""
    found = {}
    for line in run(["nm", "-arch", "arm64", "-m", "-g", "-U", archive], capture=True).splitlines():
        m = NM_DEFINED.match(line)
        if m:
            kind = "hidden" if "private external" in m.group(2) else "default"
            found[m.group(3)] = ("weak-" if m.group(2).startswith("weak") else "") + kind
        elif line.strip() and not line.endswith(":"):
            found[line.strip()] = "unparsed"
    return found


def archive_imports(archive: Path, defined: dict[str, str]) -> set[str]:
    """Symbols the archive needs from outside itself."""
    undefined = {s.strip() for s in run(["nm", "-arch", "arm64", "-u", "-j", archive],
                                         capture=True).splitlines()
                 if s.strip() and not s.endswith(":")}
    return undefined - set(defined)


def names_digest(names) -> str:
    return hashlib.sha256("".join(n + "\n" for n in sorted(names)).encode()).hexdigest()


def pc_entries(text: str) -> dict[str, str]:
    """A pkg-config file's variables (`name=`) and fields (`Name:`), with
    whitespace collapsed and the install prefix written as <prefix>."""
    entries = {}
    for line in text.replace(PREFIX, "<prefix>").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        eq, colon = line.find("="), line.find(":")
        if eq >= 0 and (colon < 0 or eq < colon):
            key, value = "$" + line[:eq].strip(), line[eq + 1:]
        elif colon >= 0:
            key, value = line[:colon].strip() + ":", line[colon + 1:]
        else:
            key, value = line, ""
        entries[key] = " ".join(value.split())
    return entries


def expected_pc(sl: Slice, name: str) -> Path:
    plain = EXPECTED_LIBS / f"{name}.pc"
    return plain if plain.exists() else EXPECTED_LIBS / f"{name}-{'tvos' if sl.tvos else 'ios'}.pc"


def header_defines(path: Path) -> set[str]:
    """Macros a header defines (active #define lines only)."""
    return set(re.findall(r"^#\s*define\s+(\w+)", path.read_text(errors="replace"), re.M))


def macro(path: Path, name: str) -> str | None:
    """A macro's value without a trailing comment."""
    m = re.search(rf"^#\s*define\s+{re.escape(name)}\s+(.*?)\s*(/[*/].*)?$",
                  path.read_text(errors="replace"), re.M)
    return m.group(1) if m else None


def archive_cstrings(archive: Path) -> set[bytes]:
    """Every C string in the (__TEXT,__cstring) sections of an archive's members."""
    strings = set()
    for member in archive_members(archive):
        if member.startswith("__.SYMDEF") or member == "SORTED":
            continue
        data = subprocess.run(["ar", "-p", str(archive), member], stdout=subprocess.PIPE,
                              check=True).stdout
        if data[:4] == b"\xcf\xfa\xed\xfe":
            strings.update(macho_cstrings(data))
    return strings


def check_dep_configuration(c: Checks, lib: str, config: dict) -> None:
    """The build options read back from the configured build."""
    if "meson" in config:
        got = config["meson"]
        for opt in config["meson_options"]:
            name, value = opt[2:].split("=", 1)
            c.equal(f"{lib}: meson option {name}", str(got.get(name)).lower(), value.lower())
        builtins = {"buildtype": "release", "optimization": "3", "debug": "false",
                    "b_ndebug": "false", "b_lto": "false", "default_library": "static"}
        c.equal(f"{lib}: meson built-in options",
                {k: str(got.get(k)).lower() for k in builtins}, builtins)
    if "cmake" in config:
        got = config["cmake"]
        for opt in list(CMAKE_COMMON) + config["cmake_options"]:
            name, value = opt[2:].split("=", 1)
            c.equal(f"{lib}: CMake {name}", got.get(name), value)
        c.equal(f"{lib}: CMake Release flags (-O3, NDEBUG defined)",
                [got.get("CMAKE_C_FLAGS_RELEASE"), got.get("CMAKE_CXX_FLAGS_RELEASE")],
                ["-O3 -DNDEBUG", "-O3 -DNDEBUG"])
    if "make_variables" in config:
        cflags = config["make_variables"].get("CFLAGS") or ""
        c.expect(f"{lib}: CFLAGS are the cross flags only, with no -O (unoptimised, as today)",
                 "-arch arm64" in cflags and not re.search(r"(^|\s)-O", cflags)
                 and not re.search(r"(^|\s)-O", config["make_variables"].get("libunibreak_la_CFLAGS")
                                   or ""), cflags)


def check_dep_specifics(c: Checks, sl: Slice, lib: str, fw: Path, inc: Path, record: dict,
                        binary: Path) -> None:
    """What each library must have compiled in (facts 3.1 to 3.11)."""
    h = fw / "Headers"
    if lib == "freetype":
        opts = header_defines(h / "freetype2" / "freetype" / "config" / "ftoption.h")
        c.expect("FreeType: system zlib on (FT_CONFIG_OPTION_USE_ZLIB, _SYSTEM_ZLIB)",
                 {"FT_CONFIG_OPTION_USE_ZLIB", "FT_CONFIG_OPTION_SYSTEM_ZLIB"} <= opts)
        off = {"FT_CONFIG_OPTION_USE_PNG", "FT_CONFIG_OPTION_USE_BROTLI",
               "FT_CONFIG_OPTION_USE_BZIP2", "FT_CONFIG_OPTION_USE_HARFBUZZ"}
        c.expect("FreeType: PNG, brotli, bzip2 and HarfBuzz off", not off & opts, str(off & opts))
    elif lib == "fribidi":
        conf = h / "fribidi" / "fribidi-config.h"
        c.equal("FriBidi: version and Unicode version",
                [define(conf, "FRIBIDI_VERSION"), define(conf, "FRIBIDI_INTERFACE_VERSION"),
                 define(h / "fribidi" / "fribidi-unicode-version.h", "FRIBIDI_UNICODE_VERSION")],
                ['"1.0.12"', "4", '"14.0.0"'])
    elif lib == "harfbuzz":
        has = {d for d in header_defines(h / "harfbuzz" / "hb-features.h") if d.startswith("HB_HAS_")}
        c.equal("HarfBuzz: no optional backend (no GLib, ICU, FreeType, CoreText, cairo, GObject)",
                has, set())
        c.equal("HarfBuzz: version", define(h / "harfbuzz" / "hb-version.h", "HB_VERSION_STRING"),
                '"8.1.1"')
    elif lib == "unibreak":
        c.equal("libunibreak: version", macro(h / "unibreakbase.h", "UNIBREAK_VERSION"), "0x0601")
    elif lib == "lcms2":
        c.equal("Little CMS: version", macro(h / "lcms2.h", "LCMS_VERSION"), "2170")
    elif lib == "shaderc":
        info = h / "glslang" / "build_info.h"
        c.equal("shaderc: glslang version", [define(info, f"GLSLANG_VERSION_{p}")
                                             for p in ("MAJOR", "MINOR", "PATCH")],
                ["16", "0", "0"])
    elif lib == "moltenvk":
        c.equal("MoltenVK: Vulkan headers version", vulkan_header_version(inc), "1.4.334")
        api = inc / "MoltenVK" / "mvk_private_api.h"
        c.equal("MoltenVK: version", [macro(api, f"MVK_VERSION_{p}")
                                      for p in ("MAJOR", "MINOR", "PATCH")], ["1", "4", "1"])
        c.equal("MoltenVK: built with MVK_XCODE_16=0 and MVK_XCODE_26=0 (today's SDK gates)",
                record["configuration"]["make"][1:], ["MVK_XCODE_16=0", "MVK_XCODE_26=0"])
    elif lib == "libplacebo":
        conf = h / "config.h"
        have = {d for d in header_defines(conf) if d.startswith("PL_HAVE_")}
        c.equal("libplacebo: PL_HAVE_ features", have,
                {"PL_HAVE_DOVI", "PL_HAVE_GL_PROC_ADDR", "PL_HAVE_LCMS", "PL_HAVE_LIBDOVI",
                 "PL_HAVE_OPENGL", "PL_HAVE_SHADERC", "PL_HAVE_VK_PROC_ADDR", "PL_HAVE_VULKAN"})
        c.equal("libplacebo: version", [define(conf, "PL_MAJOR_VER"), define(conf, "PL_API_VER")],
                ["7", "351"])
        versions = {s for s in archive_cstrings(binary) if s.startswith(b"v7.")}
        c.equal("libplacebo: pl_version() string (an archive build: no git description)",
                versions, {b"v7.351.0"})
    elif lib == "uavs3d":
        v = record["configuration"]["version_h"]
        c.equal("uavs3d: version.h", v, {"VER_MAJOR": "1", "VER_MINOR": "2", "VER_BUILD": "1",
                                         "VERSION_TYPE": '"release"', "VERSION_STR": '"1.2.1"',
                                         "VERSION_SHA1": '"0e20d2c291853f196c68922a264bcd8471d75b68"'})
        strings = archive_cstrings(binary)
        c.expect("uavs3d: version line strings in the binary (1.2.1, release, VERSION_SHA1)",
                 {b"1.2.1", b"release", b"0e20d2c291853f196c68922a264bcd8471d75b68"} <= strings)
        c.equal("uavs3d: COMPILE_10BIT", record["configuration"]["cmake"].get("COMPILE_10BIT"), "1")
        asm = [m for m in archive_members(binary) if m.endswith(".S.o")]
        c.equal("uavs3d: arm64 NEON assembly objects", len(asm), 10)
    elif lib == "libbluray":
        v = h / "bluray-version.h"
        c.equal("libbluray: version", [define(v, f"BLURAY_VERSION_{p}")
                                       for p in ("MAJOR", "MINOR", "MICRO")], ["1", "4", "0"])
    elif lib == "uchardet":
        c.expect("uchardet: header", (h / "uchardet" / "uchardet.h").is_file())


def check_deps(c: Checks, sl: Slice, pins, work: Path, out: Path, report: dict) -> dict:
    """Every dependency against what today's interim build ships
    (engine/config/expected-libs/): form, headers, exported symbols,
    imports, assertions, deployment target, pkg-config contract and the
    configuration read back from its build."""
    summary = {}
    pc_env = {**os.environ, "PKG_CONFIG_LIBDIR": os.pathsep.join(
        [str(work / "pkgconfig"), str(work / "install" / PREFIX.lstrip("/") / "lib" / "pkgconfig")])}
    pc_env.pop("PKG_CONFIG_PATH", None)
    for lib, dep in DEPS.items():
        exp = read_sections(EXPECTED_LIBS / f"{lib}.txt")
        record = report["deps"][lib]
        name = dep.framework
        if dep.kind == "library":
            fw = out / "libraries" / name
            binary = fw / dep.library
        else:
            fw = out / "frameworks" / f"{name}.framework"
            binary = fw / name
        c.equal(f"{name}: {'library' if dep.kind == 'library' else 'framework'} name as today",
                exp.get("library" if dep.kind == "library" else "framework"), [name])
        minos = exp[f"minos-{sl.name}"]
        c.equal(f"{name}: deployment target as today", len(minos), 1)
        check_binary_form(c, sl, fw, name, minos[0])
        if dep.kind == "framework":
            headers = sorted(p.relative_to(fw / "Headers").as_posix()
                             for p in (fw / "Headers").rglob("*") if p.is_file())
            c.equal(f"{name}: headers as today", headers,
                    sorted(set(exp["headers"]) - set(exp.get("headers-not-built", []))))
        defined = defined_symbols(binary)
        unparsed = sorted(s for s, k in defined.items() if k == "unparsed")
        c.expect(f"{name}: every defined symbol has a known kind", not unparsed, str(unparsed[:5]))
        for kind in ("default", "hidden"):
            c.sets(f"{name}: {kind}-visibility symbols as today",
                   {s for s, k in defined.items() if k == kind}, set(exp[kind]))
        weak = {}
        for kind in ("weak-default", "weak-hidden"):
            names = [s for s, k in defined.items() if k == kind]
            weak[kind] = [len(names), names_digest(names)]
            if f"{kind}-toolchain" in exp:
                # Which inline functions and template instances the compiler
                # emits differs between Xcode 15.4 and 26.6 for the same
                # sources: the set Xcode 26.6 gives is recorded instead.
                c.equal(f"{name}: {kind} definitions as the pipeline's toolchain gives "
                        f"(count, SHA-256; today's: {exp[kind][0]})",
                        [str(len(names)), names_digest(names)], exp[f"{kind}-toolchain"])
            else:
                c.equal(f"{name}: {kind} definitions as today (count, SHA-256)",
                        [str(len(names)), names_digest(names)], exp[kind])
        imports = archive_imports(binary, defined)
        added = set(exp.get("imports-toolchain-added", []))
        removed = set(exp.get("imports-toolchain-removed", []))
        c.sets(f"{name}: imports as today" + (" apart from the toolchain's recorded differences"
                                              if added or removed else ""),
               imports, (set(exp[f"imports-{sl.name}"]) - removed) | added)
        asserts = "___assert_rtn" in set(exp[f"imports-{sl.name}"])
        c.equal(f"{name}: assertions {'on' if asserts else 'off'} as today",
                "___assert_rtn" in imports, asserts)
        inc = work / "deps" / lib / "include"
        for pc_name in dep.pkgconfig:
            ours = work / "deps" / lib / "lib" / "pkgconfig" / f"{pc_name}.pc"
            c.equal(f"{pc_name}.pc: contract as today", pc_entries(ours.read_text()),
                    pc_entries(expected_pc(sl, pc_name).read_text()))
            res = subprocess.run(["pkg-config", "--static", "--exists", "--print-errors", pc_name],
                                 env=pc_env, capture_output=True, text=True)
            c.expect(f"{pc_name}.pc: resolves with every Requires", res.returncode == 0, res.stderr)
        check_dep_configuration(c, lib, record["configuration"])
        check_dep_specifics(c, sl, lib, fw, inc, record, binary)
        summary[lib] = {"cache": record["cache"], "key": record["key"],
                        "symbols": {k: sum(1 for v in defined.values() if v == k)
                                    for k in ("default", "hidden", "weak-default", "weak-hidden")},
                        "weak": weak, "imports": len(imports)}
    return summary


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


def built_libraries(out: Path) -> dict[str, Path]:
    """The static libraries packaged as library xcframeworks (MoltenVK)."""
    return {name: out / "libraries" / name / DEPS[dep_of(name)].library
            for name in sorted(BUILT_LIBRARIES)}


def app_link_flags(app_link: dict[str, list[str]]) -> tuple[list[str], set[str]]:
    flags = [f for name in app_link["frameworks"] for f in ("-framework", name)]
    flags += [f"-l{name}" for name in app_link["libraries"]]
    names = {f"framework:{n}" for n in app_link["frameworks"]} | {f"lib:{n}" for n in app_link["libraries"]}
    # libSystem is always linked, and Foundation re-exports libobjc.
    return flags, names | {"lib:System", "lib:objc"}


def check_link(c: Checks, sl: Slice, pins, work: Path, out: Path, sdk: Path) -> dict:
    """Symbol closure over the whole link set, then a dead-stripped test link
    of a small program, as an app would link these frameworks."""
    app_min = pins["toolchain"]["app_minimum_tvos" if sl.tvos else "app_minimum_ios"]
    target = sl.target.format(v=app_min)
    fws = out / "frameworks"
    built = {p.stem: p / p.stem for p in sorted(fws.glob("*.framework"))}
    libraries = built_libraries(out)
    c.expect("every library of the link set is built here",
             set(built) == BUILT_FRAMEWORKS and all(p.is_file() for p in libraries.values()),
             f"frameworks {sorted(set(built) ^ BUILT_FRAMEWORKS)}, libraries "
             f"{[str(p) for p in libraries.values() if not p.is_file()]}")
    archives = {**built, **libraries}
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
    cmd += [str(p) for p in libraries.values()]
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


def check_libdovi(c: Checks, sl: Slice, pins, work: Path, fws: Path,
                  undefined: dict, defined: dict) -> dict:
    """libdovi against today's (the header and C API recorded in
    engine/config/expected-libdovi.txt), its panic strategy, and the libdovi
    functions libplacebo and FFmpeg call."""
    expected = read_sections(LIBDOVI_EXPECTED)
    fw = fws / "Libdovi.framework"
    header = (fw / "Headers" / "rpu_parser.h").read_bytes()
    exported = {s for s in defined["Libdovi"] if s.startswith("_dovi_")}
    c.sets("Libdovi: exported C API as today's", exported, set(expected["exported"]))
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

    c.equal("Libdovi: rpu_parser.h identical to today's (SHA-256)",
            hashlib.sha256(header).hexdigest(), expected["header-sha256"][0])

    placebo = fws / "Libplacebo.framework" / "Libplacebo"
    placebo_calls = {s for s in nm_symbols(placebo, True) if s.startswith("_dovi_")}
    c.expect("Libplacebo calls libdovi only through exported functions",
             bool(placebo_calls) and placebo_calls <= exported, str(sorted(placebo_calls)))
    c.sets("Libplacebo calls the same libdovi functions as today's", placebo_calls,
           set(expected["libplacebo-calls"]))
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


def ao_format_problems(data: bytes) -> list[str]:
    """Frozen audio output log formats missing from a Libmpv binary."""
    missing = [f for f in AO_LOG_FORMATS if (f + "\n").encode() not in data]
    if AO_STANDALONE_FALLBACK not in data:
        missing.append("standalone 'falling back to PCM' (NUL before it)")
    return missing


def check_audio_output(c: Checks, sl: Slice, libmpv: bytes, undefined: set[str],
                       out: Path, tree: Path) -> None:
    """The audio output checks of the patch specification (2.10 and 8.6)."""
    missing = ao_format_problems(libmpv)
    c.expect(f"Libmpv has all {len(AO_LOG_FORMATS)} frozen audio output log formats",
             not missing, str(missing))
    # The standalone check must catch a binary that lost the separate line:
    # change the byte in front of it and require a failure.
    doctored = libmpv.replace(AO_STANDALONE_FALLBACK, b"\x01falling back to PCM\n")
    c.expect("frozen-format check rejects a Libmpv without the standalone 'falling back to PCM'",
             ao_format_problems(doctored) == ["standalone 'falling back to PCM' (NUL before it)"])
    for marker in AO_MARKERS:
        c.expect(f"Libmpv contains {marker!r}", marker in libmpv)
    if sl.tvos:
        c.expect("Libmpv has the tvOS-only option max-lookahead",
                 AO_TVOS_OPTION + b"\0" in libmpv)
    else:
        c.expect("Libmpv has no max-lookahead on iOS", AO_TVOS_OPTION not in libmpv)
    c.expect(f"Libmpv references {AO_SYMBOL}", AO_SYMBOL in undefined)
    for selector in AO_SELECTORS:
        c.expect(f"Libmpv contains the selector {selector!r}", selector in libmpv)
    results = out / "audio-tests.json"
    tests = json.loads(results.read_text()) if results.exists() else {}
    c.expect("audio output test vectors ran from the patched tree and passed",
             tests.get("ok") is True and tests.get("vectors", 0) > 0,
             json.dumps(tests) if tests else f"{results} missing (run lucid.py test-audio)")
    # The result must belong to the sources this slice was built from.
    expected = {name: sha256_file(tree / "audio" / "out" / name) for name in AUDIO_TEST_SOURCES}
    c.equal("audio output test result matches this tree's sources", tests.get("sources"), expected)
    c.equal("audio output test result matches the test file", tests.get("test"),
            {AUDIO_TEST.name: sha256_file(AUDIO_TEST)})


def cmd_test_audio(args) -> None:
    """Builds the audio output's test vectors on the build host against the
    mpv tree the pipeline patched for this slice, and runs them."""
    root = args.work.resolve()
    if args.tree:
        tree, out = args.tree.resolve(), None
    else:
        sl = SLICES[args.slice]
        tree, out = root / sl.name / "src" / "mpv", root / "out" / sl.name
    audio_out = tree / "audio" / "out"
    sources = [audio_out / s for s in AUDIO_TEST_SOURCES]
    missing = [str(s) for s in sources + [AUDIO_TEST] if not s.exists()]
    if missing:
        raise Failure(f"audio test inputs missing: {missing}")
    build = Path(tempfile.mkdtemp(prefix="lucid-audio-test-"))
    try:
        exe = build / "ao_avfoundation_vectors"
        run(["xcrun", "--sdk", "macosx", "clang", "-std=c11", "-O1", "-g", "-Wall", "-Wextra",
             "-Wno-unused-parameter", "-Wno-sign-compare", "-Wno-missing-field-initializers",
             "-fsanitize=address,undefined", "-fno-sanitize-recover=undefined",
             "-I", audio_out, *sources, AUDIO_TEST, "-framework", "CoreMedia", "-o", exe])
        log(f"$ {exe}")
        res = subprocess.run([str(exe)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             text=True, errors="replace")
    finally:
        shutil.rmtree(build, ignore_errors=True)
    sys.stdout.write(res.stdout)
    m = re.search(r"^audio output vectors: (\d+) run, (\d+) failed$", res.stdout, re.M)
    ran, failed = (int(m.group(1)), int(m.group(2))) if m else (0, -1)
    ok = res.returncode == 0 and m is not None and ran > 0 and failed == 0
    result = {"ok": ok, "vectors": ran, "failed": failed, "exit_status": res.returncode,
              "sources": {s.name: sha256_file(s) for s in sources},
              "test": {AUDIO_TEST.name: sha256_file(AUDIO_TEST)}}
    if out is not None:
        out.mkdir(parents=True, exist_ok=True)
        write_json(out / "audio-tests.json", result)
    summary = (f"Audio output test vectors from the patched mpv tree: {ran} run, "
               f"{failed if failed >= 0 else 'unknown'} failed.\n")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write(f"## Lucid Engine audio output tests\n\n{summary}\n")
    if not ok:
        raise Failure(f"audio output test vectors failed (exit {res.returncode}, "
                      f"{ran} run, {failed} failed)")
    log(summary.strip())


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
    c.equal("every library built from source, in order", list(report["sources"]),
            list(BUILD_ORDER))
    for lib, info in report["sources"].items():
        c.equal(f"{lib}: archive SHA-256 matches pins.ini", info["sha256"],
                pins[f"source:{lib}"]["sha256"])
        c.equal(f"{lib}: parts match pins.ini",
                [[p["part"], p["path"], p["sha256"]] for p in info.get("parts", [])],
                [[n, rel, pins[f"part:{n}"]["sha256"]] for n, rel in source_parts(pins, lib)])
        c.equal(f"{lib}: patch series", [p["file"] for p in info["patches"]],
                [f"{lib}/{p.name}" for _, p in read_series(lib)])
    with tempfile.TemporaryDirectory(dir=root) as tmp:
        check_trees(c, pins, work, report, Path(tmp))

    # Framework form (the dependencies' in check_deps below).
    expected_names = set(BUILT_FRAMEWORKS)
    c.sets("framework set", {p.stem for p in fws.glob("*.framework")}, expected_names)
    c.sets("library set", {p.name for p in (out / "libraries").iterdir()}, BUILT_LIBRARIES)
    for name in sorted(expected_names):
        if not dep_of(name):
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
    check_audio_output(c, sl, libmpv, undefined["Libmpv"], out, work / "src" / "mpv")
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
    report["libdovi_checks"] = check_libdovi(c, sl, pins, work, fws, undefined, defined)

    # The dependencies built here against what today's interim build ships.
    report["dependency_checks"] = check_deps(c, sl, pins, work, out, report)
    c.equal("Libdovi: built with the pinned rustc", report["toolchain"]["rustc"],
            "rustc " + pins["rust:rustc"]["version"])

    # Reproducible archives: no member carries a build timestamp.
    archives = {name: fws / f"{name}.framework" / name for name in sorted(expected_names)}
    archives.update(built_libraries(out))
    for name, archive in archives.items():
        dated = [l for l in run(["ar", "-tv", archive], capture=True).splitlines()
                 if " 1970 " not in l]
        c.expect(f"{name}: archive members have zero timestamps", not dated, str(dated[:3]))

    # Linkability: symbol closure and a dead-stripped test link.
    report["link"] = check_link(c, sl, pins, work, out, sdk_path(sl.sdk))

    # The AVFoundation video output (patch spec 2.1, 2.3, 8.6).
    check_video_output(c, fws, work)

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
        for part in info.get("parts", []):
            lines.append(f"| {lib}: `{part['path']}` | {part['version']} | `{part['commit'][:12]}` "
                         f"| `{part['sha256'][:16]}...` | |")
    lines += ["", "| Dependency | Build | Cache key | Symbols (default, hidden, weak) | Imports |",
              "| --- | --- | --- | --- | --- |"]
    for lib, dep in report.get("dependency_checks", {}).items():
        sym = dep["symbols"]
        lines.append(f"| {lib} | {dep['cache']} | `{dep['key'][:16]}...` | {sym['default']}, "
                     f"{sym['hidden']}, {sym['weak-default'] + sym['weak-hidden']} | {dep['imports']} |")
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


def build_host_ffmpeg(src: Path, dest: Path, dovi_include: Path, logfile: Path) -> dict:
    """libavutil, libavcodec and libavformat for the build host, built out of
    tree from the slice's patched FFmpeg source (HOST_FFMPEG_CONFIGURE). The
    build folder also holds the host's generated headers (avconfig.h), which
    every host test uses instead of a slice's."""
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)
    env = {k: os.environ[k] for k in ("HOME", "USER", "LOGNAME", "TMPDIR", "DEVELOPER_DIR")
           if k in os.environ}
    env["PATH"] = os.pathsep.join(["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
    env["LC_ALL"] = "C"
    # Keep FFmpeg's version script out of any enclosing repository.
    env["GIT_CEILING_DIRECTORIES"] = str(src.parent)
    target = f"-target {HOST_TEST_TARGET}"
    args = list(HOST_FFMPEG_CONFIGURE) + [f"--extra-cflags={target} -I{dovi_include}",
                                          f"--extra-ldflags={target}"]
    try:
        run([src / "configure"] + args, cwd=dest, env=env, logfile=logfile)
    finally:
        config_log = dest / "ffbuild" / "config.log"
        if config_log.exists():
            shutil.copy2(config_log, logfile.with_name(logfile.stem + "-config.log"))
    for header, names in HOST_FFMPEG_REQUIRED.items():
        text = (dest / header).read_text()
        missing = [n for n in names if not re.search(rf"^#define {n} 1$", text, re.M)]
        if missing:
            raise Failure(f"host FFmpeg: {', '.join(missing)} not enabled in {header}")
    libs = [dest / f"lib{lib}" / f"lib{lib}.a" for lib in HOST_FFMPEG_LIBS]
    run(["make", f"-j{os.cpu_count() or 4}"] + [str(l.relative_to(dest)) for l in libs],
        cwd=dest, env=env, logfile=logfile)
    config_mak = (dest / "ffbuild" / "config.mak").read_text()
    extralibs = []
    for lib in HOST_FFMPEG_LIBS:
        m = re.search(rf"^EXTRALIBS-{lib}=(.*)$", config_mak, re.M)
        extralibs += shlex.split(m.group(1)) if m else []
    return {"build": dest, "libs": [str(l) for l in libs], "extralibs": extralibs,
            "configure": args}


def run_host_test(name: str, sources: list[Path], includes: list[Path], defines: list[str],
                  libs: list[str], argv: list[str], out: Path, flags: tuple = ()) -> dict:
    """Compile a host test and run it; it prints '<n> checks, <f> failed'."""
    exe = out / name
    cmd = ["xcrun", "--sdk", "macosx", "clang", "-target", HOST_TEST_TARGET, "-std=c17", "-O1",
           "-g", "-Wall", "-Werror=implicit-function-declaration", "-Werror=incompatible-pointer-types"]
    cmd += list(flags) + [f"-I{i}" for i in includes] + defines + [str(s) for s in sources] + libs
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
    src = work / "src" / "ffmpeg"
    module = src / "libavcodec" / "videotoolbox_dovi.c"
    if not module.is_file():
        raise Failure(f"{module} missing: build the slice first")
    test_dir = work / "decoder-tests"
    if test_dir.exists():
        shutil.rmtree(test_dir)
    test_dir.mkdir()
    sources = [module, DECODER_TESTS / "vt_dovi_tests.c"]
    (out / "logs").mkdir(parents=True, exist_ok=True)

    # libdovi and FFmpeg for the build host first: every suite compiles
    # against the patched source tree plus the host's own generated headers,
    # never a slice's build folder.
    host = build_host_libdovi(root, work, pins, out / "logs" / "libdovi-host.log")
    hostff = build_host_ffmpeg(src, test_dir / "ffmpeg-host", host["include"],
                               out / "logs" / "ffmpeg-host.log")
    report["decoder_test_host_ffmpeg"] = {
        "configure": [a.replace(str(work), "<work>") for a in hostff["configure"]],
        "extralibs": hostff["extralibs"]}
    includes = [src, hostff["build"], host["include"]]

    results = [run_host_test("vt_dovi_tests_scripted_libdovi", sources, includes,
                             ["-DVT_DOVI_TEST_FAKE_LIBDOVI"], [], [], test_dir)]

    corpus = write_decoder_corpus(host["assets"], test_dir / "corpus.bin")
    report["decoder_test_corpus"] = corpus
    log(f"libdovi corpus for FFmpeg's conversion: {corpus['cases']} NAL units "
        f"({corpus['converted_from_other_forms']} from Annex B or raw entries), "
        f"{corpus['abort_class_entries']} abort class entries")
    dovi_libs = [str(host["library"])] + host["libs"]
    results.append(run_host_test("vt_dovi_tests_libdovi", sources, includes, [], dovi_libs,
                                 [str(host["assets"] / "tests"), str(test_dir / "corpus.bin")],
                                 test_dir))

    # videotoolbox.c end to end: the host libraries above and a fake
    # VideoToolbox session in the test itself, under AddressSanitizer.
    results.append(run_host_test("vt_glue_tests", [DECODER_TESTS / "vt_glue_tests.m"], includes,
                                 [], hostff["libs"] + dovi_libs + hostff["extralibs"] +
                                 ["-framework", "Foundation"],
                                 [str(GLUE_TEST_STREAM), str(host["assets"] / "tests")],
                                 test_dir, ("-fsanitize=address", "-fno-omit-frame-pointer")))

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


# ------------------------------------------------------------- video output

# Option names the video output registers. The option table stores each
# short name; the group prefix is stored once (patch spec 2.3, 7.2).
VO_OPTION_NAMES = (b"composite-osd", b"pip-composite-osd", b"queue-lead-ms", b"presentation")
VO_ABSENT_OPTIONS = (b"osd-max-height", b"osd-video-res")
# What the output must reference to do its job (patch spec 4). "a|b" accepts
# either name: below a deployment target of iOS and tvOS 15 the SDK maps
# CoreMedia's "source" timebase calls inline to their older "master" names.
VO_REQUIRED_UNDEFINED = (
    "_CMTimebaseCreateWithSourceClock|_CMTimebaseCreateWithMasterClock",
    "_CMTimebaseSetRateAndAnchorTime",
    "_CMTimebaseCopySource|_CMTimebaseCopyMaster", "_CMClockGetHostTimeClock",
    "_CMSampleBufferCreateReadyWithImageBuffer",
    "_CMVideoFormatDescriptionCreateForImageBuffer",
    "_CMVideoFormatDescriptionMatchesImageBuffer",
    "_CVPixelBufferPoolCreate", "_kCVPixelBufferMetalCompatibilityKey",
    "_kCVPixelBufferIOSurfacePropertiesKey", "_kCVImageBufferPixelAspectRatioKey",
    "_kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ",
    "_CVImageBufferCreateColorSpaceFromAttachments", "_CVBufferPropagateAttachments",
    "_OBJC_CLASS_$_AVSampleBufferDisplayLayer", "_OBJC_CLASS_$_CIContext",
    "_OBJC_CLASS_$_CIImage", "_OBJC_CLASS_$_CATransaction", "_MTLCreateSystemDefaultDevice",
    "_UIApplicationDidBecomeActiveNotification", "_UIApplicationWillResignActiveNotification",
    "_av_hwdevice_ctx_alloc", "_av_hwdevice_ctx_init",
)
VO_REQUIRED_STRINGS = (
    b"DolbyVisionRPUData\x00", b"sampleBufferRenderer\x00",
    b"flushWithRemovalOfDisplayedImage:completionHandler:\x00",
    b"requiresFlushToResumeDecoding\x00", b"isReadyForMoreMediaData\x00",
    b"enqueueSampleBuffer:\x00", b"setControlTimebase:\x00",
)
VO_TEST_DIR = ENGINE / "tests" / "vo"
# The output's modules, compiled from the patched tree. The centre
# (video/out/vo_avfoundation.m) is not listed: test_centre.m and
# test_centre_tv.m include it themselves, with its layer calls renamed to the
# fake layers module, so the real layers.m can be tested on its own.
VO_TEST_MODULES = ("clock.c", "pacing.c", "pixels.c", "geometry.c", "pool.c", "timebase.c",
                   "subtitles.c", "frame.m", "layers.m")
VO_TEST_FRAMEWORKS = ("Foundation", "CoreFoundation", "CoreVideo", "CoreMedia", "CoreGraphics",
                      "CoreImage", "Metal", "IOSurface", "AVFoundation", "QuartzCore")


def vo_driver_list(vo_c: str) -> list[str]:
    """The entries of video_out_drivers[] in vo.c, in order."""
    m = re.search(r"video_out_drivers\[\]\s*=\s*\{(.*?)\};", vo_c, re.S)
    return re.findall(r"&(video_out_\w+)", m.group(1)) if m else []


def defining_member(archive: Path, symbol: str) -> str | None:
    """The archive member that defines a global symbol, if exactly one does."""
    owners = [l for l in run(["nm", "-A", "-g", "-U", archive], capture=True).splitlines()
              if l.endswith(" " + symbol)]
    return owners[0].rsplit(": ", 1)[0].split(":")[-1] if len(owners) == 1 else None


def macho_cstrings(obj: bytes) -> list[bytes]:
    """The C strings in a 64-bit Mach-O object's (__TEXT,__cstring) section."""
    magic, ncmds = struct.unpack_from("<I", obj, 0)[0], struct.unpack_from("<I", obj, 16)[0]
    if magic != 0xFEEDFACF:
        raise Failure("not a 64-bit Mach-O object")
    strings, off = [], 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", obj, off)
        if cmd == 0x19:  # LC_SEGMENT_64: 72 bytes, then 80 bytes per section
            for i in range(struct.unpack_from("<I", obj, off + 64)[0]):
                s = off + 72 + 80 * i
                if (obj[s + 16:s + 32].rstrip(b"\0"), obj[s:s + 16].rstrip(b"\0")) == \
                        (b"__TEXT", b"__cstring"):
                    length, start = struct.unpack_from("<Q", obj, s + 40)[0], \
                        struct.unpack_from("<I", obj, s + 48)[0]
                    strings += obj[start:start + length].split(b"\0")[:-1]
        off += size
    return strings


def check_video_output(c: Checks, fws: Path, work: Path) -> None:
    libmpv = fws / "Libmpv.framework" / "Libmpv"
    data = libmpv.read_bytes()
    defined, undefined = nm_symbols(libmpv, False), nm_symbols(libmpv, True)
    c.expect("Libmpv defines the avfoundation video output", "_video_out_avfoundation" in defined)
    drivers = vo_driver_list((work / "src" / "mpv" / "video" / "out" / "vo.c").read_text())
    c.equal("avfoundation video output registered first, before gpu-next", drivers[:2],
            ["video_out_avfoundation", "video_out_gpu_next"])
    config_h = work / "build" / "mpv" / "config.h"
    c.equal("HAVE_VO_AVFOUNDATION", define(config_h, "HAVE_VO_AVFOUNDATION"), "1")
    # The driver name, option prefix and device name are one string literal
    # in the object that defines the output. Read it from that object's
    # C string section: the literal can be the first string of the section,
    # with no NUL in front of it in the archive.
    member, cstrings = defining_member(libmpv, "_video_out_avfoundation"), []
    if member:
        cstrings = macho_cstrings(subprocess.run(["ar", "-p", str(libmpv), member],
                                                 stdout=subprocess.PIPE, check=True).stdout)
    c.expect("Libmpv has the avfoundation driver, option prefix and device name",
             b"avfoundation" in cstrings,
             f"no C string 'avfoundation' in {member or 'the member defining _video_out_avfoundation'}")
    for name in VO_OPTION_NAMES:
        c.expect(f"Libmpv has the video output option {name.decode()}",
                 b"\x00" + name + b"\x00" in data)
    for name in VO_ABSENT_OPTIONS:
        c.expect(f"Libmpv has no option {name.decode()}", name not in data)
    missing = [s for s in VO_REQUIRED_UNDEFINED if not set(s.split("|")) & undefined]
    c.expect("Libmpv's video output references what it needs", not missing, str(missing))
    absent = [s.decode().rstrip("\x00") for s in VO_REQUIRED_STRINGS if s not in data]
    c.expect("Libmpv's video output carries its selectors and the Dolby Vision key",
             not absent, str(absent))


def run_vo_tests(src: Path, includes: list[Path], out: Path) -> tuple[int, int, str]:
    """Builds the video output tests for the build host from the patched mpv
    tree and runs them. Returns (cases, failures, output)."""
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    sdk = sdk_path("macosx")
    # mpv's own floating-point flags and optimisation level, so the pixel and
    # timing arithmetic is tested as it ships.
    flags = ["-arch", "arm64", "-isysroot", str(sdk), "-mmacosx-version-min=11.0", "-O3",
             "-fno-math-errno", "-fno-signed-zeros", "-fno-trapping-math", "-Wall", "-Wno-unused-parameter", "-Wno-sign-compare", "-Wno-pointer-sign",
             "-Wno-missing-field-initializers", "-Werror=implicit-function-declaration",
             "-D_GNU_SOURCE", f"-I{src}", f"-I{VO_TEST_DIR}",
             # UIKit as far as layers.m needs it, for the macOS build host.
             f"-I{VO_TEST_DIR / 'shim'}"] + [f"-I{p}" for p in includes]
    sources = [src / "video" / "out" / "avfoundation" / m for m in VO_TEST_MODULES]
    sources += sorted(p for p in VO_TEST_DIR.iterdir() if p.suffix in (".c", ".m"))
    objects = []
    for source in sources:
        obj = out / (source.parent.name + "-" + source.stem + ".o")
        lang = ["-std=c11"] if source.suffix == ".c" else []
        run(["xcrun", "--sdk", "macosx", "clang", *flags, *lang, "-c", source, "-o", obj])
        objects.append(obj)
    binary = out / "vo-tests"
    link = [f for name in VO_TEST_FRAMEWORKS for f in ("-framework", name)]
    run(["xcrun", "--sdk", "macosx", "clang", "-arch", "arm64", "-isysroot", str(sdk),
         "-mmacosx-version-min=11.0", *objects, "-o", binary, *link])
    res = subprocess.run([str(binary)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         text=True, errors="replace")
    output = res.stdout
    m = re.search(r"^RESULT (\d+) cases, (\d+) failures$", output, re.M)
    cases, failures = (int(m.group(1)), int(m.group(2))) if m else (0, -1)
    if res.returncode != 0 and failures == 0:
        failures = -1  # crashed or failed outside a case
    return cases, failures, output


def cmd_test_vo(args) -> None:
    sl = SLICES[args.slice]
    work = args.work.resolve() / sl.name
    out = args.work.resolve() / "out" / sl.name
    includes = [work / "build" / "mpv", work / "install" / PREFIX.lstrip("/") / "include"]
    includes += sorted(p for p in (work / "deps").glob("*/include") if p.is_dir())
    cases, failures, output = run_vo_tests(work / "src" / "mpv", includes, work / "vo-tests")
    log(output)
    (out / "vo-tests.txt").write_text(output)
    summary = (f"## Lucid Engine video output tests (built with {sl.name})\n\n"
               f"{cases} cases, {failures if failures >= 0 else 'unknown'} failures\n\n")
    timings = [line for line in output.splitlines() if line.startswith("bench ")]
    if timings:
        summary += "Kernel timings:\n\n```\n" + "\n".join(timings) + "\n```\n\n"
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write(summary)
    if cases == 0:
        raise Failure("video output tests: no case ran")
    if failures != 0:
        raise Failure(f"video output tests: {failures if failures > 0 else 'a crash or'} "
                      f"failure(s) in {cases} cases")
    log(f"All {cases} video output test cases passed for {sl.name}.")


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


FRAMEWORK_PLIST_KEYS = {"CFBundleDevelopmentRegion", "CFBundleExecutable", "CFBundleIdentifier",
                        "CFBundleInfoDictionaryVersion", "CFBundleName", "CFBundlePackageType",
                        "CFBundleShortVersionString", "CFBundleSignature",
                        "CFBundleSupportedPlatforms", "CFBundleVersion", "MinimumOSVersion",
                        "NSPrincipalClass"}


def verify_xcframework(xcf: Path, name: str, kind: str, info: dict) -> None:
    """Each slice has today's form: a framework with its module map and
    Info.plist keys (Vivid's identifier), or MoltenVK's bare static library."""
    for lib in info["AvailableLibraries"]:
        root = xcf / lib["LibraryIdentifier"]
        if kind == "library":
            library = DEPS[dep_of(name)].library
            if (lib["LibraryPath"], lib["BinaryPath"], "HeadersPath" in lib) != (library, library,
                                                                                  False) \
                    or sorted(p.name for p in root.iterdir()) != [library]:
                raise Failure(f"{name}: {lib['LibraryIdentifier']} is not a bare {library}")
            continue
        fw = root / f"{name}.framework"
        if lib["LibraryPath"] != fw.name or lib["BinaryPath"] != f"{fw.name}/{name}":
            raise Failure(f"{name}: {lib['LibraryIdentifier']} paths {lib}")
        if not (fw / "Modules" / "module.modulemap").read_text() \
                .startswith(f"framework module {name} [system] {{\n"):
            raise Failure(f"{name}: module map does not name module {name}")
        plist = plistlib.loads((fw / "Info.plist").read_bytes())
        if set(plist) != FRAMEWORK_PLIST_KEYS or \
                plist["CFBundleIdentifier"] != PLIST_ID_PREFIX + name.replace("_", "-") or \
                plist["CFBundleExecutable"] != name or plist["CFBundleName"] != name:
            raise Failure(f"{name}: Info.plist {plist}")


def package_xcframeworks(inputs: dict[str, Path], names: list[tuple[str, str]],
                         out: Path) -> list[str]:
    """Create each xcframework and its zip in out; returns SHA256SUMS lines."""
    staging = out / "xcframeworks"
    sums = []
    for name, kind in names:
        xcf = staging / f"{name}.xcframework"
        cmd = ["xcodebuild", "-create-xcframework"]
        for slice_name in sorted(inputs):
            if kind == "library":
                cmd += ["-library", inputs[slice_name] / "libraries" / name /
                        DEPS[dep_of(name)].library]
            else:
                cmd += ["-framework", inputs[slice_name] / "frameworks" / f"{name}.framework"]
        run(cmd + ["-output", xcf])
        info = plistlib.loads((xcf / "Info.plist").read_bytes())
        ids = sorted(lib["LibraryIdentifier"] for lib in info["AvailableLibraries"])
        if ids != sorted(inputs):
            raise Failure(f"{name}: xcframework slices {ids}, expected {sorted(inputs)}")
        verify_xcframework(xcf, name, kind, info)
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
    names = sorted([(n, "framework") for n in BUILT_FRAMEWORKS] +
                   [(n, "library") for n in BUILT_LIBRARIES])
    for slice_name, path in inputs.items():
        found = sorted([(p.stem, "framework") for p in (path / "frameworks").glob("*.framework")] +
                       [(p.name, "library") for p in (path / "libraries").iterdir()])
        if found != names:
            raise Failure(f"{slice_name} has {found}, expected {names}")
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
    api = set(read_sections(LIBDOVI_EXPECTED)["exported"])
    c.sets("patched library exports libdovi's C API", built["patched"]["exported"], api)
    c.sets("unpatched library exports libdovi's C API", built["unpatched"]["exported"], api)
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


# -------------------------------------------------------------- libass test

LIBASS_TEST = ENGINE / "tests" / "libass"
# FreeType, FriBidi and HarfBuzz for the build host, from the same pinned
# archives and patch series as the slices' ([source:*] in pins.ini), built
# in this order with only what libass needs, so nothing else on the build
# host is detected or linked.
LIBASS_TEST_DEPS = {
    "freetype": ("-Dzlib=internal", "-Dbzip2=disabled", "-Dpng=disabled", "-Dharfbuzz=disabled",
                 "-Dbrotli=disabled", "-Dtests=disabled"),
    "fribidi": ("-Ddocs=false", "-Dbin=false", "-Dtests=false"),
    "harfbuzz": ("-Dglib=disabled", "-Dgobject=disabled", "-Dcairo=disabled", "-Dchafa=disabled",
                 "-Dicu=disabled", "-Dgraphite=disabled", "-Dfreetype=disabled", "-Dgdi=disabled",
                 "-Ddirectwrite=disabled", "-Dcoretext=disabled", "-Dwasm=disabled",
                 "-Dtests=disabled", "-Dintrospection=disabled", "-Ddocs=disabled",
                 "-Dutilities=disabled", "-Dbenchmark=disabled"),
}
# HarfBuzz 8.1.1's configure finds sincosf in macOS's libm, but the SDK's
# math.h declares it only as __sincosf, so its C++ sources use that name.
LIBASS_TEST_DEP_CXXFLAGS = {"harfbuzz": "-Dsincosf=__sincosf"}


def load_test_module(name: str):
    path = ENGINE / "tests" / name / f"{name}_test.py"
    spec = importlib.util.spec_from_file_location(f"{name}_test", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[f"{name}_test"] = module
    spec.loader.exec_module(module)
    return module


def verified_archive(pins, downloads: Path, section: str) -> Path:
    pin = pins[section]
    archive = downloads / download_name(section, pin["url"])
    if not archive.exists() or sha256_file(archive) != pin["sha256"] or \
            archive_commit(archive) != embedded_commit(pin):
        raise Failure(f"{archive.name} does not match pins.ini; run fetch first")
    return archive


def host_meson(meson: list[str], ninja: str, src: Path, build: Path, prefix: Path,
               options: list[str], env: dict, logfile: Path) -> None:
    run(meson + ["setup", build, src, f"--prefix={prefix}", "--libdir=lib",
                 "--default-library=static", "--buildtype=release", "-Db_ndebug=true"] + options,
        env=env, logfile=logfile)
    run([ninja, "-C", build], env=env, logfile=logfile)
    run(meson + ["install", "-C", build, "--no-rebuild"], env=env, logfile=logfile)


def cmd_test_libass(args) -> None:
    """Build libass for the host from the pinned source several times
    (upstream, each upstream patch of the series added in turn, the whole
    series, and the whole series under AddressSanitizer) against FreeType,
    FriBidi and HarfBuzz built here from pinned upstream sources, and run the
    scenario corpus of engine/tests/libass through each build."""
    t = load_test_module("libass")
    pins = load_pins()
    base = args.work.resolve()
    if " " in str(base):
        raise Failure(f"work directory {base} contains a space, which pkg-config cannot handle")
    if base.exists():
        shutil.rmtree(base)
    out = base / "out"
    (out / "logs").mkdir(parents=True)
    (out / "frames").mkdir()
    # prepare_tools also unpacks the pinned CMake, which nothing here uses.
    meson, ninja, pkg_config, bindir, _ = prepare_tools(pins, args.downloads, base)
    sdk = sdk_path("macosx")
    flags = " ".join(["-target", HOST_TEST_TARGET, "-isysroot", str(sdk)])
    deps = base / "deps"
    env = {k: os.environ[k] for k in ("HOME", "USER", "LOGNAME", "TMPDIR", "DEVELOPER_DIR")
           if k in os.environ}
    env.update({"PATH": os.pathsep.join([str(bindir), "/usr/bin", "/bin", "/usr/sbin", "/sbin"]),
                "LC_ALL": "C", "CC": "/usr/bin/clang", "CXX": "/usr/bin/clang++",
                "CFLAGS": flags, "CXXFLAGS": flags, "OBJCFLAGS": flags, "LDFLAGS": flags,
                "PKG_CONFIG_LIBDIR": str(deps / "lib" / "pkgconfig"),
                "GIT_CEILING_DIRECTORIES": str(base.parent)})
    report = {"started": now(), "repository_commit": repo_commit(),
              "pins_sha256": sha256_file(ENGINE / "pins.ini"), "target": HOST_TEST_TARGET,
              "toolchain": {"clang": run(["/usr/bin/clang", "--version"], capture=True)
                            .splitlines()[0], "sdk": str(sdk)},
              "dependencies": {}, "variants": {}}

    for name, options in LIBASS_TEST_DEPS.items():
        log(f"\n==== {name} for the build host")
        section = f"source:{name}"
        archive = verified_archive(pins, args.downloads, section)
        src = base / "src" / name
        extract_tar(archive, src)
        dep_patches = apply_series(name, src, out / "logs" / f"{name}-patch.log")
        dep_env = dict(env)
        if name in LIBASS_TEST_DEP_CXXFLAGS:
            dep_env["CXXFLAGS"] += " " + LIBASS_TEST_DEP_CXXFLAGS[name]
        host_meson(meson, ninja, src, base / "build" / name, deps, list(options), dep_env,
                   out / "logs" / f"{name}.log")
        report["dependencies"][name] = {"version": pins[section]["version"],
                                        "commit": pins[section]["commit"],
                                        "sha256": pins[section]["sha256"],
                                        "patches": dep_patches, "options": options}

    archive = verified_archive(pins, args.downloads, "source:libass")
    series = read_series("libass")
    configured = read_list(CONFIG / "libass-meson.txt")
    if "-Dlibunibreak=enabled" not in configured:
        raise Failure("libass-meson.txt no longer enables libunibreak; update test-libass")
    # libunibreak is not built for the host; it only changes where lines wrap.
    options = [o.replace("-Dlibunibreak=enabled", "-Dlibunibreak=disabled") for o in configured]
    harnesses = {}
    for variant, count in t.VARIANTS.items():
        log(f"\n==== libass, {variant} ({count} of {len(series)} patches)")
        work = base / variant
        src = work / "src"
        extract_tar(archive, src)
        pristine = tree_digest(tree_files(src))
        applied = []
        for digest, patch in series[:count]:
            run(["patch", "-p1", "-F0", "-N", "-t", "-i", patch], cwd=src,
                logfile=out / "logs" / f"{variant}-patch.log")
            applied.append({"file": f"libass/{patch.name}", "sha256": digest})
        if list(src.rglob("*.rej")) or list(src.rglob("*.orig")):
            raise Failure(f"libass {variant}: the series left .rej or .orig files")
        asan = variant.endswith("-asan")
        install = work / "install"
        host_meson(meson, ninja, src, work / "build", install,
                   options + (["-Db_sanitize=address", "-Db_lundef=false"] if asan else []),
                   env, out / "logs" / f"{variant}.log")
        lib_env = dict(env, PKG_CONFIG_LIBDIR=os.pathsep.join(
            [str(install / "lib" / "pkgconfig"), str(deps / "lib" / "pkgconfig")]))
        cflags = run([pkg_config, "--cflags", "freetype2", "fribidi", "harfbuzz"], env=lib_env,
                     capture=True).split()
        libs = run([pkg_config, "--static", "--libs", "libass"], env=lib_env, capture=True).split()
        harness = work / "harness"
        run(["/usr/bin/clang", "-isysroot", sdk, "-target", HOST_TEST_TARGET, "-O2", "-g",
             "-Wall", "-Werror", "-Wno-deprecated-declarations", "-I", src / "libass",
             "-I", work / "build"]
            + (["-DVIVID_PROBE"] if variant in t.PROBED else [])
            + (["-DVIVID_COUNTERS"] if variant in t.COUNTED else [])
            + (["-fsanitize=address"] if asan else []) + cflags
            + [LIBASS_TEST / "harness.c"] + libs + ["-lc++", "-o", harness],
            logfile=out / "logs" / f"{variant}.log")
        harnesses[variant] = harness
        report["variants"][variant] = {
            "patches": applied, "pristine_tree": pristine, "tree": tree_digest(tree_files(src)),
            "library_sha256": sha256_file(install / "lib" / "libass.a"),
            "address_sanitizer": asan, "event_cache_probe": variant in t.PROBED,
            "patch_0010_counters": variant in t.COUNTED}

    corpus = base / "corpus"
    corpus.mkdir()
    scenarios = t.build_corpus(base)
    commands = {s.name: t.write_inputs(s, corpus) for s in scenarios}
    results: dict = {}
    crashed = []
    for variant, harness in harnesses.items():
        log(f"\n==== {len(scenarios)} scenarios through the {variant} build")
        results[variant] = {}
        frames_dir = out / "frames" / variant
        frames_dir.mkdir()
        for s in scenarios:
            for path in s.cleanup:
                path.unlink(missing_ok=True)
            with open(commands[s.name]) as stdin, \
                    open(out / "logs" / f"{variant}-harness.log", "a") as err:
                err.write(f"harness: scenario {s.name}\n")
                err.flush()
                res = subprocess.run([str(harness)], stdin=stdin, stdout=subprocess.PIPE,
                                     stderr=err, text=True, timeout=900)
            (frames_dir / f"{s.name}.txt").write_text(res.stdout)
            if res.returncode != 0:
                crashed.append(f"{variant}/{s.name} (exit {res.returncode})")
            results[variant][s.name] = t.parse_output(res.stdout)
        log(f"{variant}: {sum(len(r['frames']) for r in results[variant].values())} frames")

    c = Checks()
    c.expect("every harness run finished", not crashed, ", ".join(crashed))
    c.equal("series: upstream patches first, then Vivid's",
            [p.name[:5] for _, p in series], list(t.SERIES_PREFIXES))
    c.expect("patched tree differs from upstream",
             report["variants"]["patched"]["tree"] != report["variants"]["upstream"]["tree"])
    verdict = t.evaluate(scenarios, results)
    c.expect(f"corpus: {verdict['checks']} scenario checks", not verdict["failures"],
             "; ".join(verdict["failures"][:20]))
    report["corpus"] = {k: verdict[k] for k in ("checks", "groups", "totals", "failures")}
    report["scenarios"] = len(scenarios)
    report["frames"] = {variant: sum(len(r["frames"]) for r in res.values())
                        for variant, res in results.items()}
    report["checks"] = c.results
    report["finished"] = now()
    write_json(out / "libass-test.json", report)
    summary = t.summary_markdown(scenarios, verdict, results) + "\n" + "\n".join(
        f"- {'PASS' if r['ok'] else 'FAIL'}: {r['check']}" for r in c.results) + "\n" + (
        f"\nHost dependencies: FreeType {pins['source:freetype']['version']}, FriBidi "
        f"{pins['source:fribidi']['version']}, HarfBuzz {pins['source:harfbuzz']['version']}; "
        f"patched tree `{report['variants']['patched']['tree'][:16]}...`.\n")
    (out / "libass-test.md").write_text(summary)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write(summary)
    log("\n" + summary)
    failed = [r for r in c.results if not r["ok"]]
    if failed:
        raise Failure(f"{len(failed)} of {len(c.results)} libass test checks failed")
    log(f"All {len(c.results)} libass test checks passed ({verdict['checks']} scenario checks).")


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
    p = sub.add_parser("cache-key", help="print the key of a slice's dependency builds")
    p.add_argument("--slice", required=True, choices=sorted(SLICES))
    p = sub.add_parser("test-libass", help="run the libass scenario corpus against upstream, "
                       "partly patched and patched libass on the host")
    p.add_argument("--work", type=Path,
                   default=default_dir("LUCID_LIBASS_TEST", "lucid-libass-test"),
                   help="work directory for the test (replaced on each run)")
    p.add_argument("--downloads", type=Path,
                   default=default_dir("LUCID_DOWNLOADS", "lucid-downloads"), help="download cache")
    p = sub.add_parser("build", help="build one slice")
    common(p)
    p.add_argument("--slice", required=True, choices=sorted(SLICES))
    p.add_argument("--cache", type=Path,
                   help="dependency cache: reuse builds whose key is unchanged, store new ones")
    p = sub.add_parser("test-audio", help="run the audio output test vectors against the "
                                          "slice's patched mpv tree")
    common(p)
    group = p.add_mutually_exclusive_group(required=True)
    group.add_argument("--slice", choices=sorted(SLICES))
    group.add_argument("--tree", type=Path, help="a patched mpv tree instead of a slice's")
    p = sub.add_parser("check", help="verify one built slice and finish its provenance report")
    common(p)
    p.add_argument("--slice", required=True, choices=sorted(SLICES))
    p.add_argument("--strict", action="store_true", help="also require the pinned Xcode")
    p = sub.add_parser("test", help="run the decoder tests built from a slice's patched trees")
    common(p)
    p.add_argument("--slice", required=True, choices=sorted(SLICES))
    p = sub.add_parser("test-vo", help="build and run the video output tests for one slice")
    common(p)
    p.add_argument("--slice", required=True, choices=sorted(SLICES))
    p = sub.add_parser("package", help="assemble xcframeworks from built slices")
    p.add_argument("--input", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True)
    args = parser.parse_args(argv)
    handlers = {"check-allowlist": cmd_check_allowlist, "fetch": cmd_fetch, "build": cmd_build,
                "cache-key": lambda a: print(deps_key(load_pins(), SLICES[a.slice])),
                "test-audio": cmd_test_audio, "check": cmd_check, "test": cmd_test,
                "test-vo": cmd_test_vo, "package": cmd_package,
                "test-libdovi": cmd_test_libdovi, "test-libass": cmd_test_libass}
    try:
        handlers[args.command](args)
    except Failure as e:
        print(f"\nerror: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
