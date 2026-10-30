#!/usr/bin/env python3
"""Prove the bundled Open Source Licences still carry every original text exactly.

Licence bodies that repeat byte for byte are stored once (the manifest's
"texts"). An entry's notice file keeps everything else from its original file,
with the shared body replaced by one marker line. Putting the shared text back
in place of the marker must reproduce the original file byte for byte.

ORIGINALS holds the SHA-256 and size of each file as bundled before the split
(the 35 files in iosApp/Resources/OpenSourceLicenses at the commit that first
listed every shipped library). The ThumbHash entry records that file after its
Vivid-written header lines were corrected. When Lucid Engine replaced the
previous engine package, the OpenSSL entry was removed, mpv and FFmpeg moved to
their LGPL texts, and the other engine libraries' Vivid-written header lines
were updated; their upstream texts are unchanged. When the app moved to Lucid
Engine 0.1.0, which builds every library from upstream source, only the
engine libraries' Vivid-written header lines changed again (how each is built,
its patches and the pipeline commit). Later, the Rust standard library notice
gained the MIT texts of the crates.io crates built into it, and notices for
the bundled Jellyfin logo (CC BY-SA 4.0) and Seerr icon (MIT) were added.
README.txt is Vivid's own overview, which changes with the docs, so it is only
checked for presence. When a licence file changes deliberately (for example a
library update), update its entry here with the hash this script prints for
the reconstructed file.

Run: python3 scripts/tests/licence-texts-tests.py [--against <git revision>]
--against also compares each reconstruction with that revision's file.
"""
import hashlib
import json
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[2]
folder = root / 'iosApp/Resources/OpenSourceLicenses'
manifest_path = folder / 'licences.json'

ORIGINALS = {
    "CollectionHStack-MIT.txt": ("15b4a276eedf002db591914c38370c999d6ff705001a0f6dcb76d605395d5637", 1626),
    "DifferenceKit-Apache-2.0.txt": ("b68a29426b9fc7ec32083b034ed6536ac00bb05dabc2a65f87a628e53f33270b", 12048),
    "FFmpeg-LGPL-2.1-or-later.txt": ("09def22db086c05e6886e0609c5192d64310a5c3fb53e2419734b50ce635c0ac", 39271),
    "FreeType-FTL.txt": ("1896a2775dbc981b7e4b5fe49aad4266f520b0a25cb303fbb86a7d4222d440d9", 15666),
    "FriBidi-LGPL-2.1.txt": ("5c1e6a8f3fcfe67f42ad71ddd3d442c2a96f5c6c3c213aa82b8f2204db39111d", 27081),
    "HarfBuzz-MIT.txt": ("bab90809a4b4c1880913755acb1601e3de94e0613a4ebb9157cb154f4c17a889", 4200),
    "Jellyfin-Logo-CC-BY-SA-4.0.txt": ("624e42e310cf4e501b5e41b92c85cf52dc8a0bcb98246f8627886e4454bb3f34", 21462),
    "LittleCMS-MIT.txt": ("a0bb4110b8ec064afdd3ec5074a7974312865b1c808e00152ed8127b83f91ee9", 1711),
    "MoltenVK-Apache-2.0.txt": ("b1b93fb781f8351460a69d4441e8b3629a47da2b7c3e872ec1c82cb13cd6b822", 12201),
    "Rust-Standard-Library-MIT.txt": ("b78fc93abe11a6be1b491a2320295a4f0e8bd84b40570e60fc120d43a527fcc4", 19918),
    "SPIRV-Cross-Apache-2.0.txt": ("fb9b07689f16dd2f26bb823b304f866c3510b26cbf9882be78f115e473e16de2", 13751),
    "SPIRV-Headers-MIT.txt": ("53f637fa9add95006c58844267eeda7cb3ec8afda9b57ba27235a571e0292ee8", 24230),
    "SPIRV-Tools-Apache-2.0.txt": ("b03185cd87802fe40144ff4e75251c20a8c1dce90c4a2e27911f2a0a1f1fd223", 12065),
    "Seerr-Icon-MIT.txt": ("015b031dd7f8d5b70cc5038da6ab4c22c2d89daad264b2a134b119c9feac3b95", 2160),
    "ThumbHash-MIT.txt": ("c3848c6ae5964087a2a7c73de48d47d713f641319beebc74d243652614d8d65b", 1721),
    "Vivid-Apache-2.0.txt": ("cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30", 11358),
    "Vivid-Apple-Distribution.txt": ("0e34a96aa82d61d38a37721f23825f1e2a76d08d85c0b92bd199c83f167f00fd", 4930),
    "Vivid-GPL-3.0.txt": ("3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986", 35149),
    "Vulkan-Headers-MIT.txt": ("a3132705aff09e9570975cd6d786ed523ba3cc8b00202f87e52660354273d0f6", 2611),
    "cereal-BSD-3-Clause.txt": ("04fd5dc52f69175e833cd041b0937e82fd6e0e21d79d233fd7059081210ad6ae", 2340),
    "dav1d-BSD-2-Clause.txt": ("77e2969e188c9a730459c62a8e1ffd540927af15a64b79259a318cc8f1674812", 2088),
    "fast_float-MIT.txt": ("73aef326ccc5d476ab7d216ccbbac70040303b8ff83379224c2d56f5142f9bf1", 1759),
    "glad-CC0-1.0-Apache-2.0.txt": ("6c1aa2ce2fc8b2182a193dd7733ddfc23a5b3c971cd1041e0ce6637c0cf022af", 3978),
    "glslang-Multiple.txt": ("38a495842535d9fc839bf0e2506bba2234b932f13c22f07c05c9c892c037ed6d", 55653),
    "libass-ISC.txt": ("8fbf6eaac5939cf46ed69c7b3585659ea6ba76e52ee6511bc5552e6ca013a60e", 1662),
    "libbluray-LGPL-2.1.txt": ("d2768131265b95a4bb15d9480b226389d27db70b7480975082eeb502d5a6bb87", 25401),
    "libdovi-MIT.txt": ("a8d1cdf179b7ab421fa1b6fba7e3e32083a1dc37e927dc32ac8072e5d2aa1a63", 20428),
    "libplacebo-LGPL-2.1.txt": ("fa8a9f3de639c85dd5784a29a0b97e9ff2dfc9e6363ee52b035662abb11cce01", 25231),
    "libudfread-LGPL-2.1.txt": ("a62ba659972196d4302bf2eb610de0c49d887edf3b8dd98b4aa52ed4b706821a", 27174),
    "libunibreak-Zlib.txt": ("ebc3dd591fbfd5f36c4db8044691d06672034f0fcf811bcfde87aa44e4a26ba6", 1688),
    "mpv-LGPL-2.1-or-later.txt": ("b3588cc6fcf3858937f5ba0e4fb40b848cdace4f2c364e70003e362e9b66b28b", 31854),
    "shaderc-Apache-2.0.txt": ("3a13ca2c36384ab1eb7517b36bf085eb75a95ff7625edb93f4dc9809cdee659c", 12281),
    "uavs3d-BSD-3-Clause.txt": ("ff9fa66aa7201706327a0e6a830281448f1e8b9f5cbce45941c3c8d4d6d675b8", 2442),
    "uchardet-MPL-1.1.txt": ("f4609df78ec01fd8599c41f8ad9e9e852510663d0cc8ee75002cbce0c761af5a", 71280),
}
OVERVIEW = 'README.txt'

failures = []


def check(condition, message):
    if not condition:
        failures.append(message)
    return condition


def read(name):
    return (folder / name).read_bytes().decode('utf-8')


against = None
if len(sys.argv) == 3 and sys.argv[1] == '--against':
    against = sys.argv[2]
elif len(sys.argv) != 1:
    sys.exit(__doc__)

manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
marker_format = manifest['marker']
check('{title}' in marker_format, 'marker must contain {title}')
texts = {t['id']: t for t in manifest['texts']}
entries = manifest['entries']
check(len(texts) == len(manifest['texts']), 'shared text ids must be unique')
check(len({e['id'] for e in entries}) == len(entries), 'entry ids must be unique')
check(entries and entries[0].get('notice') == OVERVIEW, 'the overview must be the first entry')
markers = {tid: marker_format.format(title=t['title']) for tid, t in texts.items()}

# Every referenced file exists, and every bundled licence file is referenced.
referenced = {t['file'] for t in texts.values()}
for entry in entries:
    check('name' in entry, '%s has no name' % entry['id'])
    check('notice' in entry or 'text' in entry, '%s has no notice or text' % entry['id'])
    if 'text' in entry:
        check(entry['text'] in texts, '%s uses unknown text %s' % (entry['id'], entry.get('text')))
    if 'notice' in entry:
        referenced.add(entry['notice'])
for name in sorted(referenced):
    check((folder / name).is_file(), 'missing file %s' % name)
bundled = {p.name for p in folder.iterdir() if p.suffix == '.txt'}
for name in sorted(bundled - referenced):
    failures.append('bundled file %s is not in the manifest' % name)
for tid in texts:
    check(any(e.get('text') == tid for e in entries), 'shared text %s is unused' % tid)

# Shared texts and stand-alone notices must not contain any marker line.
for tid, t in texts.items():
    body = read(t['file'])
    for m in markers.values():
        check(m not in body, '%s contains a marker' % t['file'])

# Rebuild each original file from its notice and shared text.
rebuilt = {}
for entry in entries:
    notice = entry.get('notice')
    tid = entry.get('text')
    if notice and tid:
        text = read(notice)
        marker = markers[tid]
        others = [m for k, m in markers.items() if k != tid]
        lines = text.split('\n')
        if not check(lines.count(marker) == 1 and text.count(marker) == 1,
                     '%s must contain its marker once, on its own line' % notice):
            continue
        check(not any(m in text for m in others), '%s contains another text\'s marker' % notice)
        shared = read(texts[tid]['file']).strip('\n')
        rebuilt[notice] = text.replace(marker, shared, 1)
    elif notice:
        text = read(notice)
        check(not any(m in text for m in markers.values()), '%s has a marker but no shared text' % notice)
        rebuilt[notice] = text
    elif tid:
        name = texts[tid]['file']
        check(name not in rebuilt, '%s is rebuilt twice' % name)
        rebuilt[name] = read(name)

check(set(rebuilt) == set(ORIGINALS) | {OVERVIEW},
      'rebuilt files differ from the originals: missing %s, extra %s' % (
          sorted(set(ORIGINALS) - set(rebuilt)), sorted(set(rebuilt) - set(ORIGINALS) - {OVERVIEW})))
matched = 0
for name, (digest, size) in sorted(ORIGINALS.items()):
    if name not in rebuilt:
        continue
    data = rebuilt[name].encode('utf-8')
    actual = hashlib.sha256(data).hexdigest()
    if check(actual == digest and len(data) == size,
             '%s does not rebuild to its original (got %s, %d bytes)' % (name, actual, len(data))):
        matched += 1
    if against:
        path = 'iosApp/Resources/OpenSourceLicenses/' + name
        original = subprocess.run(['git', '-C', str(root), 'show', '%s:%s' % (against, path)],
                                  capture_output=True, check=True).stdout
        check(original == data, '%s differs from %s' % (name, against))

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)

stored = sum((folder / n).stat().st_size for n in bundled)
original_total = sum(size for _, size in ORIGINALS.values())
print('%d licence files rebuild byte for byte from %d entries and %d shared texts%s'
      % (matched, len(entries), len(texts), ' (also checked against %s)' % against if against else ''))
print('stored licence text: %d bytes (originals without the overview: %d bytes)' % (stored - (folder / OVERVIEW).stat().st_size, original_total))
