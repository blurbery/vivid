#!/usr/bin/env python3
"""Lucid Engine build tool.

Builds Vivid's media engine libraries (dav1d, libass, FFmpeg and libmpv) from
pinned upstream sources plus Vivid's patch series, packages them as static
xcframeworks and writes a provenance report. Everything else the engine links
comes from the interim prebuilt binaries pinned in pins.ini.

    python3 engine/lucid.py check-allowlist
    python3 engine/lucid.py fetch
    python3 engine/lucid.py build --slice tvos-arm64
    python3 engine/lucid.py check --slice tvos-arm64
    python3 engine/lucid.py package --input DIR --out DIR

Needs Python 3.9 or later (standard library only), the Xcode command-line
tools and pkg-config. Building is meant for CI; see
docs/cores/lucid-engine-build.md.
"""

from __future__ import annotations

import argparse
import configparser
import datetime
import hashlib
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
)
# Hosts that may appear in references (upstream homes, patch descriptions,
# and the GNU licence address in the licence header of new source files).
REFERENCE_HOSTS = {"github.com", "code.videolan.org", "gitlab.freedesktop.org", "trac.ffmpeg.org",
                   "www.gnu.org"}
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
BUILD_ORDER = ("dav1d", "libass", "ffmpeg", "mpv")
OPENSSL_SYMBOL = re.compile(
    r"^_(SSL_|TLS_|DTLS_|OPENSSL_|OpenSSL_|EVP_|X509_|BIO_|ERR_|CRYPTO_|PEM_|RAND_|HMAC_)")
MPV_PATCH_MARKER = b"Still waiting for TrueHD major sync"  # from mpv patch 0001


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


SLICES = {s.name: s for s in (
    Slice("ios-arm64", "iphoneos", "arm64-apple-ios{v}", "-mios-version-min={v}",
          "ios", "ios", "ios-arm64", "iPhoneOS", 2, False),
    Slice("ios-arm64-simulator", "iphonesimulator", "arm64-apple-ios{v}-simulator",
          "-mios-simulator-version-min={v}", "ios-simulator", "isimulator",
          "ios-arm64_x86_64-simulator", "iPhoneSimulator", 7, False),
    Slice("tvos-arm64", "appletvos", "arm64-apple-tvos{v}", "-mtvos-version-min={v}",
          "tvos", "tvos", "tvos-arm64_arm64e", "AppleTVOS", 3, True),
    Slice("tvos-arm64-simulator", "appletvsimulator", "arm64-apple-tvos{v}-simulator",
          "-mtvos-simulator-version-min={v}", "tvos-simulator", "tvsimulator",
          "tvos-arm64_x86_64-simulator", "AppleTVSimulator", 8, True),
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
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)
    run(["tar", "-xzf", archive, "-C", dest, "--strip-components", "1"])


def archive_commit(archive: Path) -> str:
    with tarfile.open(archive) as tar:
        tar.next()
        return tar.pax_headers.get("comment", "")


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
    for section in pins.sections():
        pin = pins[section]
        if "url" not in pin:
            continue
        dest = args.downloads / download_name(section, pin["url"])
        download(pin["url"], pin["sha256"], dest)
        if section.startswith("source:"):
            commit = archive_commit(dest)
            if commit != pin["commit"]:
                raise Failure(f"{dest.name}: archive commit {commit}, pinned {pin['commit']}")
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


def build_env(ctx_root: Path, bindir: Path, flags: list[str], pc_dirs: list[Path]) -> dict:
    env = {k: os.environ[k] for k in ("HOME", "USER", "LOGNAME", "TMPDIR", "DEVELOPER_DIR")
           if k in os.environ}
    # Xcode's tools first, so `gcc` (FFmpeg's default compiler) is Apple clang.
    env["PATH"] = os.pathsep.join([str(bindir), "/usr/bin", "/bin", "/usr/sbin", "/sbin"])
    env["LC_ALL"] = "C"
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


def build_ffmpeg(ctx: Ctx) -> list[str]:
    args = [f"--prefix={PREFIX}"] + read_list(CONFIG / "ffmpeg-configure.txt")
    build = ctx.build("ffmpeg")
    build.mkdir(parents=True, exist_ok=True)
    logfile = ctx.logfile("ffmpeg")
    jobs = f"-j{os.cpu_count() or 4}"
    try:
        run([ctx.src("ffmpeg") / "configure"] + args, cwd=build, env=ctx.env, logfile=logfile)
        run(["make", jobs], cwd=build, env=ctx.env, logfile=logfile)
        run(["make", "install", f"DESTDIR={ctx.install}"], cwd=build, env=ctx.env, logfile=logfile)
    finally:
        config_log = build / "ffbuild" / "config.log"
        if config_log.exists():
            shutil.copy2(config_log, ctx.out / "logs" / "ffmpeg-config.log")
    rewrite_installed_pc(ctx)
    return args


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
        "minimum_os": ctx.pins["toolchain"]["minimum_os"],
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
    sdk = sdk_path(sl.sdk)
    flags = compile_flags(sl, sdk, pins["toolchain"]["minimum_os"])
    ctx = Ctx(sl, pins, args.downloads, root, work, out, sdk, flags, {}, meson, ninja, pkg_config)
    ctx.env = build_env(root, bindir, flags, ctx.pc_dirs)
    report = {"slice": sl.name, "started": now(), "repository_commit": repo_commit(),
              "pins_sha256": sha256_file(ENGINE / "pins.ini"), "toolchain": toolchain(ctx)}
    report["prebuilt"] = stage_prebuilt(ctx)
    report["sources"] = {}
    for lib in BUILD_ORDER:
        log(f"\n==== {lib} ({sl.name})")
        report["sources"][lib] = prepare_source(ctx, lib)
        if lib == "dav1d":
            build_meson(ctx, lib, read_list(CONFIG / "dav1d-meson.txt"), ndebug=False)
        elif lib == "libass":
            build_meson(ctx, lib, read_list(CONFIG / "libass-meson.txt"), ndebug=True)
        elif lib == "ffmpeg":
            report["ffmpeg_configure_args"] = build_ffmpeg(ctx)
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


def check_binary_form(c: Checks, sl: Slice, fw: Path, name: str, minimum_os: str) -> None:
    binary = fw / name
    c.equal(f"{name}: architectures", run(["lipo", "-archs", binary], capture=True).split(), ["arm64"])
    out = run(["otool", "-l", binary], capture=True)
    platforms = set(re.findall(r"^\s*platform (\S+)$", out, re.M))
    minos = set(re.findall(r"^\s*minos (\S+)$", out, re.M))
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
#include <Libmpv/mpv/client.h>

const char *avformat_configuration(void);

int main(void)
{
    mpv_handle *mpv = mpv_create();
    if (mpv) {
        mpv_initialize(mpv);
        mpv_terminate_destroy(mpv);
    }
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
    c.expect("dead-stripped test link of mpv_create, mpv_initialize, mpv_terminate_destroy "
             "and avformat_configuration", linked, res.stdout[-2000:])
    if linked:
        symbols = nm_symbols(test / "linktest", False)
        c.expect("test link contains libmpv and libavformat",
                 {"_mpv_create", "_avformat_configuration"} <= symbols)
    return {"target": target, "system_libraries_needed": sorted(needed),
            "selector_stub_references": stubs, "linked": linked}


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
    expected_names = {"Libdav1d", "Libass", "Libmpv"} | {f"Lib{ff}" for ff in FFMPEG_LIBS}
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

    # Linkability: symbol closure and a dead-stripped test link.
    report["link"] = check_link(c, sl, pins, work, fws, sdk_path(sl.sdk))

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
    lines += ["", "| Prebuilt | Archive | SHA-256 |", "| --- | --- | --- |"]
    for item in report["prebuilt"]:
        lines.append(f"| {item['name']} | `{item['archive']}` | `{item['sha256'][:16]}...` |")
    lines += ["", f"FFmpeg `avformat_configuration()`: `{report['ffmpeg']['configuration']}`", "",
              f"FFmpeg licence: {', '.join(report['ffmpeg']['licences'])}", "",
              f"mpv configuration: `{report['mpv']['configuration']}`", "",
              f"mpv features: `{' '.join(report['mpv']['features'])}`", "",
              f"Test link ({report['link']['target']}, dead-stripped): "
              f"{'linked' if report['link']['linked'] else 'FAILED'}. System libraries the "
              f"link set needs: {', '.join(report['link']['system_libraries_needed'])}", ""]
    failed = [r for r in report["checks"] if not r["ok"]]
    if failed:
        lines += ["### Failed checks", ""] + [f"- {r['check']}: {r['detail']}" for r in failed] + [""]
    return "\n".join(lines) + "\n"


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
VO_TEST_MODULES = ("clock.c", "pacing.c", "pixels.c", "geometry.c", "pool.c", "timebase.c",
                   "subtitles.c", "frame.m")
VO_TEST_FRAMEWORKS = ("Foundation", "CoreFoundation", "CoreVideo", "CoreMedia", "CoreGraphics",
                      "CoreImage", "Metal", "IOSurface")


def vo_driver_list(vo_c: str) -> list[str]:
    """The entries of video_out_drivers[] in vo.c, in order."""
    m = re.search(r"video_out_drivers\[\]\s*=\s*\{(.*?)\};", vo_c, re.S)
    return re.findall(r"&(video_out_\w+)", m.group(1)) if m else []


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
    c.expect("Libmpv has the avfoundation driver, option prefix and device name",
             b"\x00avfoundation\x00" in data)
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
             "-D_GNU_SOURCE", f"-I{src}", f"-I{VO_TEST_DIR}"] + [f"-I{p}" for p in includes]
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
    summary = (f"## Lucid Engine video output tests: {sl.name}\n\n"
               f"{cases} cases, {failures if failures >= 0 else 'unknown'} failures\n\n")
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
        archive = out / f"{name}.xcframework.zip"
        zip_tree(xcf, archive)
        with zipfile.ZipFile(archive) as z:
            if any(not n.startswith(f"{name}.xcframework/") for n in z.namelist()):
                raise Failure(f"{archive.name}: root entry is not {name}.xcframework/")
        sums.append(f"{sha256_file(archive)}  {archive.name}")
    shutil.rmtree(staging)
    (out / "SHA256SUMS").write_text("\n".join(sums) + "\n")
    for slice_name, path in inputs.items():
        shutil.copy2(path / "provenance.json", out / "provenance" / f"{slice_name}.json")
        shutil.copy2(path / "provenance.md", out / "provenance" / f"{slice_name}.md")
    summary = ["## Lucid Engine xcframeworks", "",
               f"Slices: {', '.join(sorted(inputs))}", "",
               "SwiftPM checksums (SHA-256 of each zip):", "", "```", *sums, "```", ""]
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write("\n".join(summary))
    log("\n".join(summary))


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
    p = sub.add_parser("build", help="build one slice")
    common(p)
    p.add_argument("--slice", required=True, choices=sorted(SLICES))
    p = sub.add_parser("check", help="verify one built slice and finish its provenance report")
    common(p)
    p.add_argument("--slice", required=True, choices=sorted(SLICES))
    p.add_argument("--strict", action="store_true", help="also require the pinned Xcode")
    p = sub.add_parser("test-vo", help="build and run the video output tests for one slice")
    common(p)
    p.add_argument("--slice", required=True, choices=sorted(SLICES))
    p = sub.add_parser("package", help="assemble xcframeworks from built slices")
    p.add_argument("--input", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True)
    args = parser.parse_args(argv)
    handlers = {"check-allowlist": cmd_check_allowlist, "fetch": cmd_fetch, "build": cmd_build,
                "check": cmd_check, "test-vo": cmd_test_vo, "package": cmd_package}
    try:
        handlers[args.command](args)
    except Failure as e:
        print(f"\nerror: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
