#!/usr/bin/env python3
"""Prepare a release of the Lucid Engine Swift package (blurbery/lucid-engine).

    python3 engine/publish_package.py --run RUN_ID --version 0.1.0 \\
        --package /path/to/lucid-engine [--work DIR] [--downloads DIR]

Takes one green run of the Lucid Engine build workflow and, in a clean
checkout of the package repository (it refuses one with uncommitted or
untracked files before writing anything):

1. checks the run: the Lucid Engine build workflow on the pipeline branch,
   completed and successful, with every slice, both host test jobs and the
   packaging job successful, and its commit present in this repository;
2. downloads its lucid-engine-xcframeworks artefact with the GitHub CLI and
   verifies it: exactly the 21 framework zips and MoltenVK's, each zip's
   SHA-256 against SHA256SUMS and against `swift package compute-checksum`,
   each zip's layout and Info.plist (the four arm64 slices), and each
   slice's provenance report (built from the run's commit, every check
   passed);
3. writes Package.swift (one library product, LucidEngine, whose wrapper
   target links exactly the run commit's engine/config/app-link.txt, and one
   binary target per zip at this release's download URL), README.md, NOTICE,
   LICENSE (the package's own files, LGPL-2.1-or-later) and LICENSES/ (each
   library's licence texts, taken from the pinned upstream archives, which
   are downloaded and checked through lucid.py's download function);
4. checks the manifest with `swift package dump-package`, and that it names
   no URL but this release's, scans every generated and staged file for
   private details of the machine it runs on, and stages the release assets
   (the zips, SHA256SUMS and provenance-<slice>.json and .md) and the
   release notes under the package's ignored .build/ folder;
5. prints the commands that commit the package, push it and create the
   release. It publishes nothing itself.

It refuses a run that is not green or whose artefacts fail any check. Needs
the GitHub CLI (signed in), Git, the Xcode command-line tools (swift) and
Python 3.9 or later. See docs/cores/lucid-engine-build.md.
"""

from __future__ import annotations

import argparse
import getpass
import importlib.util
import json
import os
import plistlib
import re
import shutil
import socket
import subprocess
import sys
import tarfile
import tempfile
import textwrap
import zipfile
from pathlib import Path

ENGINE = Path(__file__).resolve().parent
REPO = ENGINE.parent


def load_lucid():
    spec = importlib.util.spec_from_file_location("lucid", ENGINE / "lucid.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules["lucid"] = module
    spec.loader.exec_module(module)
    return module


L = load_lucid()
Failure = L.Failure
log = L.log

WORKFLOW_NAME = "Lucid Engine build"
ARTEFACT = "lucid-engine-xcframeworks"
SLICES = ("ios-arm64", "ios-arm64-simulator", "tvos-arm64", "tvos-arm64-simulator")
REQUIRED_JOBS = tuple(f"Build {s}" for s in SLICES) + (
    "libdovi C API test", "libass host tests", "Package xcframeworks")

# Each library in the package, in the order README.md and NOTICE list them:
# its source pin, name, framework (or library) names, the version as shown,
# where its upstream source lives, the licence it is used under, its
# licence texts in LICENSES/ and any further notes. Versions and commits
# come from pins.ini at the run's commit.
LIBRARIES = (
    {"pin": "mpv", "name": "mpv", "version": "v0.41.0",
     "home": "https://github.com/mpv-player/mpv",
     "licence": "LGPL-2.1-or-later (built with -Dgpl=false)",
     "texts": ("mpv/LICENSE.LGPL", "mpv/Copyright")},
    {"pin": "ffmpeg", "name": "FFmpeg", "version": "n8.0.1",
     "home": "https://github.com/FFmpeg/FFmpeg",
     "licence": "LGPL-2.1-or-later (built without --enable-gpl, --enable-version3 or OpenSSL; "
                "TLS through Apple's Secure Transport)",
     "texts": ("FFmpeg/LICENSE.md", "FFmpeg/COPYING.LGPLv2.1"),
     "notes": ("This software is based in part on the work of the Independent JPEG Group.",)},
    {"pin": "libass", "name": "libass", "version": "0.17.5",
     "home": "https://github.com/libass/libass", "licence": "ISC",
     "texts": ("libass/COPYING",)},
    {"pin": "dav1d", "name": "dav1d", "version": "1.5.3",
     "home": "https://github.com/videolan/dav1d", "licence": "BSD-2-Clause",
     "texts": ("dav1d/COPYING",)},
    {"pin": "libdovi", "name": "libdovi, the C API of the dolby_vision crate",
     "short": "libdovi (`dolby_vision` crate)", "version": "3.3.2 (tag libdovi-3.3.2)",
     "home": "https://github.com/quietvoid/dovi_tool", "subfolder": "dolby_vision",
     "licence": "MIT", "texts": ("libdovi/LICENSE",)},
    {"pin": "freetype", "name": "FreeType", "version": "2.12.1 (tag VER-2-12-1)",
     "home": "https://github.com/freetype/freetype",
     "licence": "FTL (FreeType is FTL OR GPL-2.0-or-later; FTL is used)",
     "texts": ("FreeType/LICENSE.TXT", "FreeType/FTL.TXT"),
     "notes": ("Portions of this software are copyright (c) 2022 The FreeType Project",
               "(www.freetype.org). All rights reserved.")},
    {"pin": "fribidi", "name": "GNU FriBidi", "version": "1.0.12 (tag v1.0.12)",
     "home": "https://github.com/fribidi/fribidi", "licence": "LGPL-2.1-or-later",
     "texts": ("FriBidi/COPYING",)},
    {"pin": "harfbuzz", "name": "HarfBuzz", "version": "8.1.1",
     "home": "https://github.com/harfbuzz/harfbuzz",
     "licence": "MIT (\"Old MIT\"); the Universal Shaping Engine data is MIT",
     "texts": ("HarfBuzz/COPYING", "HarfBuzz/ms-use-COPYING (src/ms-use/COPYING)")},
    {"pin": "unibreak", "name": "libunibreak", "version": "6.1 (release tarball of tag libunibreak_6_1)",
     "home": "https://github.com/adah1972/libunibreak", "licence": "Zlib",
     "texts": ("libunibreak/LICENCE",)},
    {"pin": "lcms2", "name": "Little CMS", "version": "2.17 (tag lcms2.17)",
     "home": "https://github.com/mm2/Little-CMS", "licence": "MIT",
     "texts": ("lcms2/LICENSE",)},
    {"pin": "shaderc", "name": "shaderc", "version": "2025.5 (tag v2025.5)",
     "home": "https://github.com/google/shaderc", "licence": "Apache-2.0",
     "texts": ("shaderc/LICENSE",), "parts_from": "the revisions in its DEPS file"},
    {"pin": "moltenvk", "name": "MoltenVK", "version": "1.4.1 (tag v1.4.1)",
     "home": "https://github.com/KhronosGroup/MoltenVK", "licence": "Apache-2.0",
     "texts": ("MoltenVK/LICENSE",), "parts_from": "the revisions in its ExternalRevisions folder"},
    {"pin": "libplacebo", "name": "libplacebo", "version": "7.351.0 (tag v7.351.0)",
     "home": "https://github.com/haasn/libplacebo", "licence": "LGPL-2.1-or-later",
     "texts": ("libplacebo/LICENSE",), "parts_from": "its 3rdparty submodules at that commit",
     "build_only_parts": ("jinja", "markupsafe")},
    {"pin": "uavs3d", "name": "uavs3d", "version": "1.2",
     "home": "https://github.com/uavs3/uavs3d", "licence": "BSD-3-Clause",
     "texts": ("uavs3d/COPYING",)},
    {"pin": "libbluray", "name": "libbluray", "version": "1.4.0 (release tarball of tag 1.4.0)",
     "home": "https://code.videolan.org/videolan/libbluray", "licence": "LGPL-2.1-or-later",
     "texts": ("libbluray/COPYING",),
     "notes": ("Contains libudfread 1.2.0 (its contrib/libudfread submodule,",
               "https://code.videolan.org/videolan/libudfread), LGPL-2.1-or-later:",
               "LICENSES/libbluray/libudfread/COPYING")},
    {"pin": "uchardet", "name": "uchardet", "version": "0.0.8 (release tarball of tag v0.0.8)",
     "home": "https://gitlab.freedesktop.org/uchardet/uchardet",
     "licence": "MPL-1.1, GPL-2.0-or-later or LGPL-2.1-or-later; LGPL-2.1-or-later is used",
     "table_licence": "LGPL-2.1-or-later (one of three)", "texts": ("uchardet/COPYING",)},
)

# The parts compiled into the frameworks, with their homes and licences as
# NOTICE gives them (jinja and markupsafe only generate code while building).
PARTS = {
    "glslang": ("glslang", "https://github.com/KhronosGroup/glslang",
                "BSD-3-Clause, BSD-2-Clause, MIT, Apache-2.0 and other terms, as its licence file gives them",
                ("shaderc/glslang/LICENSE.txt",)),
    "spirv-tools": ("SPIRV-Tools", "https://github.com/KhronosGroup/SPIRV-Tools", "Apache-2.0",
                    None),
    "spirv-headers": ("SPIRV-Headers", "https://github.com/KhronosGroup/SPIRV-Headers",
                      "MIT (Khronos terms)", None),
    "spirv-cross": ("SPIRV-Cross", "https://github.com/KhronosGroup/SPIRV-Cross", "Apache-2.0",
                    None),
    "cereal": ("cereal", "https://github.com/USCiLab/cereal", "BSD-3-Clause", None),
    "vulkan-headers-1.4.334": ("Vulkan-Headers", "https://github.com/KhronosGroup/Vulkan-Headers",
                               "Apache-2.0 OR MIT (MIT used)", None),
    "vulkan-headers-1.4.310": ("Vulkan-Headers", "https://github.com/KhronosGroup/Vulkan-Headers",
                               "Apache-2.0 OR MIT (MIT used)", None),
    "fast-float": ("fast_float", "https://github.com/fastfloat/fast_float",
                   "MIT OR Apache-2.0 OR BSL-1.0 (MIT used)", None),
    "glad": ("glad (generated loader)", "https://github.com/Dav1dde/glad", "MIT", None),
}
# Folder names under LICENSES/<library>/ for each part.
PART_FOLDERS = {"spirv-tools": "SPIRV-Tools", "spirv-headers": "SPIRV-Headers",
                "spirv-cross": "SPIRV-Cross", "cereal": "cereal", "glslang": "glslang",
                "vulkan-headers-1.4.334": "Vulkan-Headers", "vulkan-headers-1.4.310": "Vulkan-Headers",
                "fast-float": "fast_float", "glad": "glad"}
LICENSES_DIR_OF = {"mpv": "mpv", "ffmpeg": "FFmpeg", "libass": "libass", "dav1d": "dav1d",
                   "libdovi": "libdovi", "freetype": "FreeType", "fribidi": "FriBidi",
                   "harfbuzz": "HarfBuzz", "unibreak": "libunibreak", "lcms2": "lcms2",
                   "shaderc": "shaderc", "moltenvk": "MoltenVK", "libplacebo": "libplacebo",
                   "uavs3d": "uavs3d", "libbluray": "libbluray", "uchardet": "uchardet"}

# LICENSES/<path>: (pins.ini section, the file's path inside that archive,
# below the archive's top folder).
LICENCE_FILES = {
    "mpv/LICENSE.LGPL": ("source:mpv", "LICENSE.LGPL"),
    "mpv/Copyright": ("source:mpv", "Copyright"),
    "FFmpeg/LICENSE.md": ("source:ffmpeg", "LICENSE.md"),
    "FFmpeg/COPYING.LGPLv2.1": ("source:ffmpeg", "COPYING.LGPLv2.1"),
    "libass/COPYING": ("source:libass", "COPYING"),
    "dav1d/COPYING": ("source:dav1d", "COPYING"),
    "libdovi/LICENSE": ("source:libdovi", "dolby_vision/LICENSE"),
    "libdovi/rust-std/LICENSE-MIT": ("rust:std-aarch64-apple-ios", "LICENSE-MIT"),
    "FreeType/LICENSE.TXT": ("source:freetype", "LICENSE.TXT"),
    "FreeType/FTL.TXT": ("source:freetype", "docs/FTL.TXT"),
    "FriBidi/COPYING": ("source:fribidi", "COPYING"),
    "HarfBuzz/COPYING": ("source:harfbuzz", "COPYING"),
    "HarfBuzz/ms-use-COPYING": ("source:harfbuzz", "src/ms-use/COPYING"),
    "libunibreak/LICENCE": ("source:unibreak", "LICENCE"),
    "lcms2/LICENSE": ("source:lcms2", "LICENSE"),
    "shaderc/LICENSE": ("source:shaderc", "LICENSE"),
    "shaderc/glslang/LICENSE.txt": ("part:glslang", "LICENSE.txt"),
    "shaderc/SPIRV-Tools/LICENSE": ("part:spirv-tools", "LICENSE"),
    "shaderc/SPIRV-Headers/LICENSE": ("part:spirv-headers", "LICENSE"),
    "MoltenVK/LICENSE": ("source:moltenvk", "LICENSE"),
    "MoltenVK/SPIRV-Cross/LICENSE": ("part:spirv-cross", "LICENSE"),
    "MoltenVK/SPIRV-Tools/LICENSE": ("part:spirv-tools", "LICENSE"),
    "MoltenVK/SPIRV-Headers/LICENSE": ("part:spirv-headers", "LICENSE"),
    "MoltenVK/cereal/LICENSE": ("part:cereal", "LICENSE"),
    "MoltenVK/Vulkan-Headers/LICENSE.md": ("part:vulkan-headers-1.4.334", "LICENSE.md"),
    "MoltenVK/Vulkan-Headers/MIT.txt": ("part:vulkan-headers-1.4.334", "LICENSES/MIT.txt"),
    "libplacebo/LICENSE": ("source:libplacebo", "LICENSE"),
    "libplacebo/fast_float/LICENSE-MIT": ("part:fast-float", "LICENSE-MIT"),
    "libplacebo/glad/LICENSE": ("part:glad", "LICENSE"),
    "libplacebo/Vulkan-Headers/LICENSE.md": ("part:vulkan-headers-1.4.310", "LICENSE.md"),
    "libplacebo/Vulkan-Headers/MIT.txt": ("part:vulkan-headers-1.4.310", "LICENSES/MIT.txt"),
    "uavs3d/COPYING": ("source:uavs3d", "COPYING"),
    "libbluray/COPYING": ("source:libbluray", "COPYING"),
    "libbluray/libudfread/COPYING": ("source:libbluray", "contrib/libudfread/COPYING"),
    "uchardet/COPYING": ("source:uchardet", "COPYING"),
}
# The crates compiled into Libdovi (dolby_vision with its capi feature, as
# its Cargo.lock locks them), their licences and the text kept for each.
CRATES = (
    ("anyhow", "1.0.98", "MIT OR Apache-2.0", "LICENSE-MIT"),
    ("bitstream-io", "2.6.0", "MIT OR Apache-2.0", "LICENSE-MIT"),
    ("bitvec", "1.0.1", "MIT", "LICENSE.txt"),
    ("bitvec_helpers", "3.1.6", "MIT", "LICENSE"),
    ("crc", "3.3.0", "MIT OR Apache-2.0", "LICENSE-MIT"),
    ("crc-catalog", "2.4.0", "MIT OR Apache-2.0", "LICENSES/MIT.txt"),
    ("funty", "2.0.0", "MIT", "LICENSE.txt"),
    ("libc", "0.2.172", "MIT OR Apache-2.0", "LICENSE-MIT"),
    ("radium", "0.7.0", "MIT", "LICENSE.txt"),
    ("tap", "1.0.1", "MIT", "LICENSE.txt"),
    ("tinyvec", "1.9.0", "Zlib OR Apache-2.0 OR MIT", "LICENSE-MIT.md"),
    ("wyz", "0.5.1", "MIT", "LICENSE.txt"),
)

# Vivid's own patches are licensed like the library they patch; mpv 0001 and
# libass 0001 and 0002 are unchanged upstream changes.
PATCH_LICENCES = {"mpv": "LGPL-2.1-or-later", "ffmpeg": "LGPL-2.1-or-later", "libass": "ISC",
                  "libdovi": "MIT", "libbluray": "LGPL-2.1-or-later", "uavs3d": "BSD-3-Clause"}
UPSTREAM_PATCHES = {("mpv", "0001"), ("libass", "0001"), ("libass", "0002")}

PACKAGE_LICENCE_HEADER = """\
Lucid Engine Swift package
==========================

The files of this repository that are not third-party (Package.swift, the
Sources folder, README.md and NOTICE) are copyright blurbery and are
licensed under the GNU Lesser General Public License, version 2.1 or (at
your option) any later version (LGPL-2.1-or-later). The text of version 2.1
follows.

The libraries in the release assets keep their own licences: see NOTICE and
the LICENSES folder.

------------------------------------------------------------------------------

"""

WRAPPER_SOURCE = """\
// This target only carries the LucidEngine product's link settings: the
// system frameworks and libraries Lucid Engine's static frameworks need.
// It has no code. Import the frameworks themselves, for example `import Libmpv`.
"""


# ------------------------------------------------------------------ helpers

def gh_json(args: list[str]):
    res = subprocess.run(["gh"] + args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if res.returncode != 0:
        raise Failure(f"gh {' '.join(args)} failed: {res.stderr.strip()}")
    return json.loads(res.stdout)


def git(*args: str) -> str:
    res = subprocess.run(["git", "-C", str(REPO)] + list(args), stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, text=True)
    if res.returncode != 0:
        raise Failure(f"git {' '.join(args)} failed: {res.stderr.strip()}")
    return res.stdout


def pins_at(commit: str):
    """pins.ini as the run's commit has it."""
    import configparser
    pins = configparser.ConfigParser(interpolation=None)
    pins.read_string(git("show", f"{commit}:engine/pins.ini"))
    return pins


def app_link_at(commit: str) -> dict[str, list[str]]:
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "app-link.txt"
        path.write_text(git("show", f"{commit}:engine/config/app-link.txt"))
        return L.read_sections(path)


def series_at(commit: str, lib: str) -> list[str]:
    """The patch file names of a library's series at the commit."""
    names = []
    for line in git("show", f"{commit}:engine/patches/{lib}/series").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            names.append(line.split(None, 1)[1])
    return names


def archive_member(archive: Path, rel: str) -> bytes:
    """A file of an archive by its path below the archive's top folder."""
    with tarfile.open(archive) as tar:
        for member in tar:
            parts = member.name.split("/", 1)
            if len(parts) == 2 and parts[1] == rel and member.isfile():
                return tar.extractfile(member).read()
    raise Failure(f"{archive.name} has no {rel}")


# ---------------------------------------------------------------- the run

def check_run(run_id: int, repo: str, branch: str) -> dict:
    info = gh_json(["run", "view", str(run_id), "--repo", repo, "--json",
                    "workflowName,status,conclusion,headSha,headBranch,event,jobs,url,attempt"])
    problems = []
    if info["workflowName"] != WORKFLOW_NAME:
        problems.append(f"workflow is {info['workflowName']!r}, not {WORKFLOW_NAME!r}")
    if info["headBranch"] != branch:
        problems.append(f"branch is {info['headBranch']!r}, not {branch!r}")
    if info["event"] != "push":
        problems.append(f"event is {info['event']!r}, not a push")
    if info["status"] != "completed" or info["conclusion"] != "success":
        problems.append(f"run is {info['status']} with conclusion {info['conclusion'] or 'none'}")
    jobs = {j["name"]: j for j in info["jobs"]}
    for name in REQUIRED_JOBS:
        if name not in jobs:
            problems.append(f"job {name!r} missing")
        elif jobs[name]["conclusion"] != "success":
            problems.append(f"job {name!r} concluded {jobs[name]['conclusion'] or 'none'}")
    for name, job in jobs.items():
        if name not in REQUIRED_JOBS and job["conclusion"] not in ("success", "skipped"):
            problems.append(f"job {name!r} concluded {job['conclusion'] or 'none'}")
    if problems:
        raise Failure(f"run {run_id} is not a green {WORKFLOW_NAME} run:\n  " + "\n  ".join(problems))
    sha = info["headSha"]
    if subprocess.run(["git", "-C", str(REPO), "cat-file", "-e", f"{sha}^{{commit}}"],
                      stderr=subprocess.DEVNULL).returncode != 0:
        raise Failure(f"commit {sha} of run {run_id} is not in this repository; fetch it first")
    log(f"Run {run_id}: {WORKFLOW_NAME} on {branch} at {sha}, every job successful.")
    return info


# ------------------------------------------------------------- artefacts

def expected_names() -> list[str]:
    return sorted(L.BUILT_FRAMEWORKS | L.BUILT_LIBRARIES)


def verify_artefact(art: Path, sha: str) -> dict[str, str]:
    """The zips' SHA-256 by name, after every check of the artefact."""
    names = expected_names()
    zips = [f"{n}.xcframework.zip" for n in names]
    present = sorted(p.name for p in art.iterdir())
    extra = sorted(set(present) - set(zips) - {"SHA256SUMS", "provenance"})
    missing = sorted(set(zips + ["SHA256SUMS", "provenance"]) - set(present))
    if extra or missing:
        raise Failure(f"artefact: missing {missing or 'nothing'}, unexpected {extra or 'nothing'}")

    sums = {}
    for line in (art / "SHA256SUMS").read_text().splitlines():
        m = re.fullmatch(r"([0-9a-f]{64})  (\S+)", line)
        if not m or m.group(2) in sums:
            raise Failure(f"SHA256SUMS: unexpected line {line!r}")
        sums[m.group(2)] = m.group(1)
    if sorted(sums) != zips:
        raise Failure(f"SHA256SUMS lists {sorted(sums)}, expected {zips}")

    for name in names:
        z = art / f"{name}.xcframework.zip"
        digest = L.sha256_file(z)
        if digest != sums[z.name]:
            raise Failure(f"{z.name}: SHA-256 {digest}, SHA256SUMS says {sums[z.name]}")
        swiftpm = subprocess.run(["swift", "package", "compute-checksum", str(z)],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if swiftpm.returncode != 0 or swiftpm.stdout.strip() != digest:
            raise Failure(f"{z.name}: SwiftPM checksum {swiftpm.stdout.strip() or swiftpm.stderr.strip()}"
                          f" differs from its SHA-256 {digest}")
        check_zip(z, name)

    for s in SLICES:
        for ext in ("json", "md"):
            if not (art / "provenance" / f"{s}.{ext}").is_file():
                raise Failure(f"artefact: provenance/{s}.{ext} missing")
        report = json.loads((art / "provenance" / f"{s}.json").read_text())
        if report.get("slice") != s or report.get("repository_commit") != sha:
            raise Failure(f"provenance/{s}.json: slice {report.get('slice')}, commit "
                          f"{report.get('repository_commit')}, expected {s} at {sha}")
        failed = [c["check"] for c in report.get("checks", []) if not c["ok"]]
        if failed or not report.get("checks"):
            raise Failure(f"provenance/{s}.json: failed checks {failed or 'none recorded'}")
        tests = report.get("decoder_tests", [])
        if len(tests) != 3 or not all(t["ok"] for t in tests):
            raise Failure(f"provenance/{s}.json: decoder tests {tests}")
    extra = sorted(p.name for p in (art / "provenance").iterdir()
                   if p.name not in {f"{s}.{e}" for s in SLICES for e in ("json", "md")})
    if extra:
        raise Failure(f"artefact: unexpected provenance files {extra}")
    log(f"Artefact verified: {len(names)} zips against SHA256SUMS and SwiftPM, "
        f"{len(SLICES)} provenance reports from {sha}.")
    return {name: sums[f"{name}.xcframework.zip"] for name in names}


def check_zip(z: Path, name: str) -> None:
    root = f"{name}.xcframework/"
    with zipfile.ZipFile(z) as archive:
        bad = archive.testzip()
        if bad:
            raise Failure(f"{z.name}: {bad} fails its CRC")
        for entry in archive.namelist():
            if not entry.startswith(root) or ".." in entry.split("/") or entry.startswith("/"):
                raise Failure(f"{z.name}: entry {entry} outside {root}")
        info = plistlib.loads(archive.read(root + "Info.plist"))
    libs = {lib["LibraryIdentifier"]: lib for lib in info.get("AvailableLibraries", [])}
    if sorted(libs) != sorted(SLICES):
        raise Failure(f"{z.name}: slices {sorted(libs)}, expected {sorted(SLICES)}")
    path = "libMoltenVK.a" if name in L.BUILT_LIBRARIES else f"{name}.framework"
    for ident, lib in libs.items():
        if lib.get("SupportedArchitectures") != ["arm64"] or lib.get("LibraryPath") != path:
            raise Failure(f"{z.name}: {ident} is {lib.get('LibraryPath')} for "
                          f"{lib.get('SupportedArchitectures')}, expected {path} for arm64")


# -------------------------------------------------------------- licences

def write_licences(pins, downloads: Path, dest: Path) -> list[str]:
    """LICENSES/ from the pinned archives, each downloaded and checked."""
    downloads.mkdir(parents=True, exist_ok=True)
    archives = {}
    for section in sorted({s for s, _ in LICENCE_FILES.values()}):
        pin = pins[section]
        archive = downloads / L.download_name(section, pin["url"])
        L.download(pin["url"], pin["sha256"], archive)
        if section.startswith(("source:", "part:")):
            commit, expected = L.archive_commit(archive), L.embedded_commit(pin)
            if commit != expected:
                raise Failure(f"{archive.name}: archive commit {commit or 'none'}, "
                              f"expected {expected or 'none (release tarball)'}")
        archives[section] = archive
    locked = {c["name"]: c for c in L.locked_crates(pins, downloads)}
    (downloads / "crates").mkdir(exist_ok=True)
    crate_files = {}
    for name, version, _, text in CRATES:
        crate = locked.get(name)
        if not crate or crate["version"] != version:
            raise Failure(f"crate {name} {version} is not what libdovi's Cargo.lock locks "
                          f"({crate['version'] if crate else 'absent'})")
        archive = downloads / "crates" / crate["file"]
        L.download(crate["url"], crate["checksum"], archive)
        crate_files[f"libdovi/crates/{name}/{text.rsplit('/', 1)[-1]}"] = (archive, text)

    if dest.exists():
        shutil.rmtree(dest)
    written = []
    for rel, (section, inner) in sorted(LICENCE_FILES.items()):
        out = dest / rel
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(archive_member(archives[section], inner))
        written.append(rel)
    for rel, (archive, inner) in sorted(crate_files.items()):
        out = dest / rel
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(archive_member(archive, inner))
        written.append(rel)
    return written


# -------------------------------------------------------------- the files

def package_swift(version: str, sha: str, release: str, sums: dict[str, str],
                  link: dict[str, list[str]]) -> str:
    targets = "\n".join(f'    built("{n}", "{sums[n]}"),' for n in expected_names())
    settings = "\n".join([f'                .linkedFramework("{f}"),' for f in link["frameworks"]]
                         + [f'                .linkedLibrary("{lib}"),' for lib in link["libraries"]])
    return f"""// swift-tools-version:5.9
//
// Lucid Engine {version}: libmpv, FFmpeg and every library they use, built
// from upstream source by Vivid's pipeline at blurbery/vivid
// {sha}. See README.md.

import PackageDescription

/// Release assets of this repository, built by Vivid's pipeline.
let release = "{release}"

/// A framework (or MoltenVK's static library) Vivid's pipeline builds. The
/// checksum is the SHA-256 of the zip, as listed in the release's
/// `SHA256SUMS`.
func built(_ name: String, _ checksum: String) -> Target {{
    .binaryTarget(name: name, url: "\\(release)/\\(name).xcframework.zip", checksum: checksum)
}}

let binaries: [Target] = [
{targets}
]

let binaryNames = binaries.map(\\.name)

let package = Package(
    name: "LucidEngine",
    platforms: [.iOS(.v14), .tvOS(.v14)],
    products: [
        // Every framework, plus the wrapper that links the system frameworks
        // and libraries they need. Import the frameworks by name, for example
        // `import Libmpv`.
        .library(name: "LucidEngine", targets: ["LucidEngine"] + binaryNames),
    ],
    targets: [
        .target(
            name: "LucidEngine",
            dependencies: binaryNames.map {{ .target(name: $0) }},
            // Exactly the system frameworks and libraries of Vivid's
            // engine/config/app-link.txt, which the pipeline's link test uses.
            linkerSettings: [
{settings}
            ]
        ),
    ] + binaries
)
"""


def frameworks_of(pins, lib: dict) -> list[str]:
    names = pins[f"source:{lib['pin']}"]["frameworks"].split()
    return names


def number_ranges(numbers: list[str]) -> str:
    """'0010', '0011', '0012', '0020' as '0010 to 0012 and 0020'."""
    groups: list[list[str]] = []
    for n in numbers:
        if groups and int(n) == int(groups[-1][-1]) + 1:
            groups[-1].append(n)
        else:
            groups.append([n])
    parts = []
    for g in groups:
        parts += g if len(g) < 3 else [f"{g[0]} to {g[-1]}"]
    return parts[0] if len(parts) == 1 else ", ".join(parts[:-1]) + " and " + parts[-1]


def patch_summary(sha: str, lib: str) -> str:
    """The series as upstream changes and Vivid's own patches, or ''."""
    numbers = [name.split("-", 1)[0] for name in series_at(sha, lib)]
    upstream = [n for n in numbers if (lib, n) in UPSTREAM_PATCHES]
    own = [n for n in numbers if (lib, n) not in UPSTREAM_PATCHES]
    out = []
    if upstream:
        out.append(f"upstream {number_ranges(upstream)}, unchanged")
    if own:
        out.append(f"Vivid's {number_ranges(own)} ({PATCH_LICENCES[lib]})")
    return "; ".join(out)


def wrapped(text: str, indent: str = "  ", more: str = "    ") -> list[str]:
    return textwrap.wrap(text, width=79, initial_indent=indent, subsequent_indent=more,
                         break_long_words=False, break_on_hyphens=False)


def readme(version: str, run: dict, run_id: int, pins, sums: dict[str, str]) -> str:
    sha, short = run["headSha"], run["headSha"][:7]
    tree = f"https://github.com/blurbery/vivid/tree/{sha}"
    blob = f"https://github.com/blurbery/vivid/blob/{sha}"
    rows = []
    for lib in LIBRARIES:
        pin = pins[f"source:{lib['pin']}"]
        frameworks = ", ".join(f"`{n}`" for n in frameworks_of(pins, lib))
        series = series_at(sha, lib["pin"])
        patches = (f"[{len(series)}]({tree}/engine/patches/{lib['pin']}/series)" if series
                   else "none")
        home = lib["home"].split("://", 1)[1].split("/", 1)[1]
        rows.append(f"| {frameworks} | {lib.get('short', lib['name'])} | {pin['version']} "
                    f"(`{pin['commit'][:8]}`) | [{home}]({lib['home']}) | "
                    f"{lib.get('table_licence', lib['licence'].split(' (')[0])} | {patches} |")
    return f"""# Lucid Engine

Lucid Engine is the media engine of [Vivid](https://github.com/blurbery/vivid), an Apple media client by blurbery. This repository serves it as a Swift package: libmpv, FFmpeg and every library they use, as static xcframeworks for iOS and tvOS, all built from upstream source by Vivid's own pipeline.

## Using it

```swift
.package(url: "https://github.com/blurbery/lucid-engine", revision: "<commit of a release tag>")
```

Add the `LucidEngine` product to the app target and import the frameworks by name, for example `import Libmpv`. The product also links the system frameworks and libraries the engine needs (Vivid's [`engine/config/app-link.txt`]({blob}/engine/config/app-link.txt)).

- Slices: `ios-arm64`, `ios-arm64-simulator`, `tvos-arm64` and `tvos-arm64-simulator`. There are no x86_64 simulator, arm64e or macOS slices, so the package supports only these four.
- Platforms: iOS 14 and tvOS 14. Each library keeps its own deployment target, as before: 14.0 for libmpv, FFmpeg, libass, dav1d and libdovi, and 13.0 to 15.0 for the others (uavs3d 15.0; MoltenVK 14.5 on tvOS). Vivid's apps target iOS 18 and tvOS 26.
- The `Libavutil` module does not import, because its module map includes FFmpeg's hardware headers for other platforms (AMF, DRM, MediaCodec and OpenHarmony). Its functions still link.

## Release {version}

Built by Vivid's pipeline from [`blurbery/vivid` at `{short}`]({tree}/engine) (`{sha}`), in GitHub Actions run [{run_id}]({run['url']}). Every library is built from its upstream source with Vivid's patch series; no prebuilt third-party binary is used. The release assets are the {len(sums)} xcframework zips (21 frameworks and MoltenVK's static library), `SHA256SUMS` (each zip's SHA-256, which is also its SwiftPM checksum) and the provenance report of each slice.

| Frameworks | Library | Version | Upstream source | Licence as built | Patches |
| --- | --- | --- | --- | --- | --- |
{chr(10).join(rows)}

The patch series are in [`engine/patches`]({tree}/engine/patches). Vivid's own patches are licensed like the library they patch: LGPL-2.1-or-later for mpv, FFmpeg and libbluray, ISC for libass, MIT for libdovi and BSD-3-Clause for uavs3d. mpv `0001` and libass `0001` and `0002` are upstream changes, unchanged, with their upstream attribution. FFmpeg uses Apple's Secure Transport for TLS; there is no OpenSSL.

## Rebuilding

The build runs in Vivid's [Lucid Engine build workflow]({blob}/.github/workflows/lucid-engine.yml) with [`engine/lucid.py`]({blob}/engine/lucid.py), and this package is written by [`engine/publish_package.py`]({blob}/engine/publish_package.py) from that run's artefacts. Every download is pinned by URL and SHA-256 in `engine/pins.ini`. The [build guide]({blob}/docs/cores/lucid-engine-build.md) at the same commit describes the steps, the checks and the outputs. The builds are reproducible: unchanged inputs give byte-identical zips across CI runs, so a rebuild at `{short}` with the same Xcode should match `SHA256SUMS`.

## Licences

Each library keeps its own licence. [`NOTICE`](NOTICE) lists every library with its version, upstream commit and licence, including the code the libraries contain from other projects. The licence texts are in [`LICENSES`](LICENSES), taken from the upstream source at the listed commits. This repository's own files (`Package.swift`, `Sources`, this README and `NOTICE`) are licensed under LGPL-2.1-or-later; see [`LICENSE`](LICENSE).

Maintainer: blurbery.
"""


def notice(version: str, run: dict, pins) -> str:
    sha = run["headSha"]
    title = f"Lucid Engine {version}"
    lines = [title, "=" * len(title), "",
             "The libraries in this package, their versions and licences. Each licence text",
             "is in LICENSES/, taken from the upstream source at the commit given here.", "",
             "Built from upstream source by Vivid's pipeline",
             "----------------------------------------------", "",
             f"Pipeline: https://github.com/blurbery/vivid/tree/{sha}/engine",
             "Every library below is built from its upstream source. Vivid's patches are in",
             "engine/patches at that commit. Vivid's own patches are licensed like the",
             "library they patch: LGPL-2.1-or-later for mpv, FFmpeg and libbluray, ISC for",
             "libass, MIT for libdovi and BSD-3-Clause for uavs3d. mpv patch 0001 and",
             "libass patches 0001 and 0002 are upstream changes, unchanged.", ""]
    for lib in LIBRARIES:
        pin = pins[f"source:{lib['pin']}"]
        frameworks = ", ".join(frameworks_of(pins, lib))
        head = f"{lib['name']} ({frameworks})"
        lines.append(head if len(head) <= 78 else head.replace(", Libavformat", ",\nLibavformat"))
        lines.append(f"  Version: {lib['version']}")
        lines.append(f"  Commit: {pin['commit']}")
        source = lib["home"]
        if lib.get("subfolder"):
            source = f"{lib['home']}/tree/{pin['commit']}/{lib['subfolder']}"
        lines.append(f"  Source: {source}")
        patches = patch_summary(sha, lib["pin"])
        lines += wrapped(f"Licence: {lib['licence']}")
        if patches:
            lines += wrapped(f"Patches: {patches}")
        texts = [f"LICENSES/{t}" for t in lib["texts"]]
        lines += wrapped(("Texts: " if len(texts) > 1 else "Text: ") + ", ".join(texts))
        for note in lib.get("notes", ()):
            lines.append(f"  {note}")
        if lib["pin"] == "libdovi":
            lines += ["  Libdovi also contains the crates dolby_vision uses with its capi feature,",
                      "  at the versions its Cargo.lock locks, and the Rust standard library:"]
            for name, ver, lic, text in CRATES:
                lines.append(f"    {name + ' ' + ver:<22}{lic:<28}"
                             f"LICENSES/libdovi/crates/{name}/{text.rsplit('/', 1)[-1]}")
            rust = pins["rust:rustc"]["version"].split()[0]
            lines += [f"    Rust standard library {rust}   MIT OR Apache-2.0   "
                      "LICENSES/libdovi/rust-std/LICENSE-MIT",
                      "  For crates under a choice of licences, MIT is used. The standard library's",
                      "  own dependencies are listed in the Rust toolchain's COPYRIGHT files."]
        parts = L.source_parts(pins, lib["pin"])
        compiled = [(name, rel) for name, rel in parts if name not in lib.get("build_only_parts", ())]
        if compiled:
            lines.append(f"  Contains, at {lib['parts_from']}:")
            for name, _ in compiled:
                label, home, lic, texts = PARTS[name]
                part = pins[f"part:{name}"]
                folder = f"LICENSES/{LICENSES_DIR_OF[lib['pin']]}/{PART_FOLDERS[name]}"
                files = sorted(r for r in LICENCE_FILES
                               if r.startswith(f"{LICENSES_DIR_OF[lib['pin']]}/{PART_FOLDERS[name]}/"))
                lines.append(f"    {label} {part['commit']}")
                lines.append(f"      {home}")
                shown = ", ".join(f"LICENSES/{f}" for f in files) or folder
                lines += wrapped(f"{lic}: {shown}", "      ", "        ")
        if lib.get("build_only_parts"):
            lines += wrapped(f"Its {' and '.join(lib['build_only_parts'])} submodules only generate "
                             "code while building and are not part of the framework.", "  ", "  ")
        lines.append("")
    return "\n".join(lines)


def release_notes(version: str, run: dict, run_id: int, pins) -> str:
    sha = run["headSha"]
    versions = [f"{lib['name'].split(',')[0]} {pins['source:' + lib['pin']]['version']}"
                for lib in LIBRARIES]
    return "\n".join([
        f"- Lucid Engine {version} as a Swift package: one `LucidEngine` product with 22 static "
        "xcframeworks (21 frameworks and MoltenVK's static library) for iOS and tvOS, on arm64 "
        "devices and arm64 simulators.",
        f"- Every library is built from its upstream source by Vivid's pipeline at blurbery/vivid "
        f"`{sha}` (GitHub Actions run {run_id}), with Vivid's patch series. No prebuilt "
        "third-party binary is used, and `Package.swift` points only at this release's assets.",
        f"- Contains {', '.join(versions[:-1])} and {versions[-1]}.",
        "- mpv and FFmpeg are LGPL-2.1-or-later; FFmpeg uses Apple's Secure Transport for TLS "
        "and there is no OpenSSL. `NOTICE` and `LICENSES` give every library's licence.",
        "- Assets: the 22 xcframework zips, `SHA256SUMS` (each zip's SHA-256, which is also its "
        "SwiftPM checksum) and each slice's provenance report.",
    ]) + "\n"


# ------------------------------------------------------------------ checks

def check_clean(package: Path) -> None:
    """Refuse a package checkout with uncommitted or untracked files, before
    anything is written: the release replaces LICENSES/ and the package's
    own files there. Ignored files (the staged .build/ folder) do not count."""
    res = subprocess.run(["git", "-C", str(package), "status", "--porcelain",
                          "--untracked-files=all"],
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if res.returncode != 0:
        raise Failure(f"git status failed in {package}: {res.stderr.strip()}")
    changes = res.stdout.splitlines()
    if changes:
        listed = "\n".join(f"  {line}" for line in changes[:20])
        more = f"\n  ... and {len(changes) - 20} more" if len(changes) > 20 else ""
        raise Failure(f"{package} has uncommitted or untracked files, which the release "
                      f"would overwrite or delete; commit, stash or remove them first, "
                      f"including the files of an earlier preparation that was not "
                      f"committed:\n{listed}{more}")


def check_manifest(package: Path, release: str, sums: dict[str, str],
                   link: dict[str, list[str]]) -> None:
    text = (package / "Package.swift").read_text()
    urls = re.findall(r"https?://[^\s\"\\]+", text)
    foreign = [u for u in urls if not u.startswith(release + "/") and u != release]
    if foreign:
        raise Failure(f"Package.swift names other URLs: {foreign}")
    res = subprocess.run(["swift", "package", "dump-package", "--package-path", str(package)],
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if res.returncode != 0:
        raise Failure(f"swift package dump-package failed:\n{res.stderr}")
    manifest = json.loads(res.stdout)
    binaries = {t["name"]: t for t in manifest["targets"] if t["type"] == "binary"}
    if sorted(binaries) != expected_names():
        raise Failure(f"Package.swift binary targets {sorted(binaries)}")
    for name, target in binaries.items():
        if target.get("url") != f"{release}/{name}.xcframework.zip" or \
                target.get("checksum") != sums[name]:
            raise Failure(f"Package.swift: {name} has {target.get('url')} {target.get('checksum')}")
    products = manifest["products"]
    if len(products) != 1 or products[0]["name"] != "LucidEngine":
        raise Failure(f"Package.swift products {[p['name'] for p in products]}")
    wrapper = next(t for t in manifest["targets"] if t["name"] == "LucidEngine")
    linked = [(s["kind"], next(iter(s["kind"].values()))["_0"] if isinstance(s["kind"], dict) else None)
              for s in wrapper.get("settings", [])]
    frameworks = [v for k, v in linked if "linkedFramework" in k]
    libraries = [v for k, v in linked if "linkedLibrary" in k]
    if frameworks != link["frameworks"] or libraries != link["libraries"]:
        raise Failure(f"Package.swift links {frameworks} and {libraries}, app-link.txt says "
                      f"{link['frameworks']} and {link['libraries']}")
    log(f"Package.swift: {len(binaries)} binary targets at {release}, the LucidEngine product, "
        "and exactly app-link.txt's frameworks and libraries.")


def scan_private(paths: list[Path], strict_text: list[Path]) -> None:
    """Refuse files that carry this machine's private details: its home folder
    or user name, its host name, or any /Users/ path other than a CI
    runner's. strict_text files (the ones written here) must also hold no
    e-mail address except a GitHub noreply one."""
    home, user, host = str(Path.home()), getpass.getuser(), socket.gethostname().split(".")[0]
    terms = [t for t in {home, f"/Users/{user}", host} if t and len(t) > 2]
    problems = []
    for path in paths:
        data = path.read_bytes()
        text = data.decode("utf-8", "replace")
        for term in terms:
            if term in text:
                problems.append(f"{path.name}: contains a private detail of this machine")
        for m in re.finditer(r"/Users/(?!runner/)[A-Za-z0-9._-]+", text):
            problems.append(f"{path.name}: names a home folder ({m.group(0)[:7]}...)")
        if path in strict_text:
            for m in re.finditer(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", text):
                if not m.group(0).endswith("@users.noreply.github.com"):
                    problems.append(f"{path.name}: contains an e-mail address")
    if problems:
        raise Failure("private details found:\n  " + "\n  ".join(sorted(set(problems))))
    log(f"Private details: none in {len(paths)} files.")


# -------------------------------------------------------------------- main

def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--run", type=int, required=True, help="a green Lucid Engine build run id")
    parser.add_argument("--version", required=True, help="the release version, for example 0.1.0")
    parser.add_argument("--package", type=Path, required=True,
                        help="a clean checkout of blurbery/lucid-engine")
    parser.add_argument("--work", type=Path, default=L.default_dir("LUCID_PUBLISH", "lucid-publish"),
                        help="work directory (replaced on each run)")
    parser.add_argument("--downloads", type=Path,
                        default=L.default_dir("LUCID_DOWNLOADS", "lucid-downloads"),
                        help="download cache for the licence texts' archives")
    parser.add_argument("--repo", default="blurbery/vivid")
    parser.add_argument("--branch", default="experiment/lucid-engine-build")
    parser.add_argument("--package-repo", default="blurbery/lucid-engine")
    args = parser.parse_args(argv)
    try:
        if not re.fullmatch(r"\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?", args.version):
            raise Failure(f"version {args.version!r} is not of the form 1.2.3 or 1.2.3-label")
        package = args.package.resolve()
        if not (package / ".git").exists():
            raise Failure(f"{package} is not a checkout of {args.package_repo}")
        check_clean(package)
        tag = f"v{args.version}"
        release = f"https://github.com/{args.package_repo}/releases/download/{tag}"

        run = check_run(args.run, args.repo, args.branch)
        sha = run["headSha"]
        pins, link = pins_at(sha), app_link_at(sha)

        work = args.work.resolve()
        if work.exists():
            shutil.rmtree(work)
        art = work / "artefact"
        art.mkdir(parents=True)
        L.run(["gh", "run", "download", str(args.run), "--repo", args.repo, "--name", ARTEFACT,
               "--dir", art])
        sums = verify_artefact(art, sha)

        written = write_licences(pins, args.downloads.resolve(), package / "LICENSES")
        lgpl = (package / "LICENSES" / "FFmpeg" / "COPYING.LGPLv2.1").read_text()
        (package / "LICENSE").write_text(PACKAGE_LICENCE_HEADER + lgpl)
        (package / "Sources" / "LucidEngine").mkdir(parents=True, exist_ok=True)
        (package / "Sources" / "LucidEngine" / "LucidEngine.swift").write_text(WRAPPER_SOURCE)
        (package / "Package.swift").write_text(package_swift(args.version, sha, release, sums, link))
        (package / "README.md").write_text(readme(args.version, run, args.run, pins, sums))
        (package / "NOTICE").write_text(notice(args.version, run, pins))
        check_manifest(package, release, sums, link)

        staged = package / ".build" / f"release-{tag}"
        if staged.exists():
            shutil.rmtree(staged)
        staged.mkdir(parents=True)
        for name in expected_names():
            shutil.copy2(art / f"{name}.xcframework.zip", staged)
        shutil.copy2(art / "SHA256SUMS", staged)
        for s in SLICES:
            for ext in ("json", "md"):
                shutil.copy2(art / "provenance" / f"{s}.{ext}", staged / f"provenance-{s}.{ext}")
        notes = package / ".build" / f"release-notes-{tag}.md"
        notes.write_text(release_notes(args.version, run, args.run, pins))

        generated = [package / n for n in ("Package.swift", "README.md", "NOTICE", "LICENSE")]
        generated += [package / "Sources" / "LucidEngine" / "LucidEngine.swift", notes]
        text_assets = [p for p in staged.iterdir() if not p.name.endswith(".zip")]
        licences = [package / "LICENSES" / r for r in written]
        scan_private(generated + text_assets + licences, generated + text_assets)

        log(f"\nLucid Engine {args.version} from run {args.run} ({sha}) is ready in the package "
            f"checkout. Release assets ({len(list(staged.iterdir()))} files) are in "
            f".build/release-{tag}/ and the release notes in .build/release-notes-{tag}.md.\n")
        log("| Asset | SHA-256 (SwiftPM checksum) |\n| --- | --- |")
        for name in expected_names():
            log(f"| {name}.xcframework.zip | {sums[name]} |")
        log("\nReview the changes, then, from the package checkout:\n")
        log("  git add Package.swift README.md NOTICE LICENSE LICENSES Sources")
        log(f"  git commit -m 'feat: serve Lucid Engine {args.version} as a Swift package'")
        log("  git push origin main")
        log(f"  gh release create {tag} --repo {args.package_repo} --target \"$(git rev-parse HEAD)\" "
            f"--title {args.version} --notes-file .build/release-notes-{tag}.md "
            f".build/release-{tag}/*")
        log("\nAdd --prerelease for a prerelease version. Afterwards, download two assets back with "
            "gh release download and compare them with SHA256SUMS, and resolve the package once "
            "from a scratch consumer.")
    except Failure as e:
        print(f"\nerror: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
