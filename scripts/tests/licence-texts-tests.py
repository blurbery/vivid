#!/usr/bin/env python3
"""Prove the bundled Open Source Licences still carry every original text exactly.

Licence bodies that repeat byte for byte are stored once (the manifest's
"texts"). An entry's notice file keeps everything else from its original file,
with the shared body replaced by one marker line. Putting the shared text back
in place of the marker must reproduce the original file byte for byte.

ORIGINALS holds the SHA-256 and size of each file as bundled before the split
(the 35 files in iosApp/Resources/OpenSourceLicenses at the commit that first
listed every shipped library). README.txt is Vivid's own overview, which
changes with the docs, so it is only checked for presence. When a licence
file changes deliberately (for example a library update), update its entry
here with the hash this script prints for the reconstructed file.

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
    "FFmpeg-GPL-3.0-or-later.txt": ("085076450a7fe140cc871b3936cd715431009ab32b22394722d0ee2c5b9757c3", 47600),
    "FreeType-FTL.txt": ("a0a88ce5d8b60f5b65e4e1dd126d04f05a12860defc1595732a689ea4ae44b18", 15634),
    "FriBidi-LGPL-2.1.txt": ("bc49e3817305aebeb5cae9fcbda5d25496edba30567290e027eabe0ae9e3485f", 27035),
    "HarfBuzz-MIT.txt": ("9292bc854de0b74c7c68d600d6ae13f27b60f420440283a191087d14da10606d", 4154),
    "LittleCMS-MIT.txt": ("51c6e5ceac95d51abfbaeabc7112c32737f805f82dedf42032fe6ce3d5c4810f", 1664),
    "MoltenVK-Apache-2.0.txt": ("eb118319a0c21de2ff35e1239be628d9004aff578ee1229fe43cdd16a9f35f4e", 12156),
    "OpenSSL-Apache-2.0.txt": ("345f1e1a3f8faf9aec81cc317c669773fee85dd5a1ccd66a5eda6460f2f9afbb", 10831),
    "Plezy-GPL-3.0.txt": ("cadee7a5c565a0dc0751adb09ba1930252f55cb39103456d873dffaa82dfb18b", 35955),
    "Rust-Standard-Library-MIT.txt": ("4768b5b4d43bebe22c12e23aa4ed28f795416b3180bea43180ae22a248a6a9da", 3879),
    "SPIRV-Cross-Apache-2.0.txt": ("fb9b07689f16dd2f26bb823b304f866c3510b26cbf9882be78f115e473e16de2", 13751),
    "SPIRV-Headers-MIT.txt": ("53f637fa9add95006c58844267eeda7cb3ec8afda9b57ba27235a571e0292ee8", 24230),
    "SPIRV-Tools-Apache-2.0.txt": ("b03185cd87802fe40144ff4e75251c20a8c1dce90c4a2e27911f2a0a1f1fd223", 12065),
    "ThumbHash-MIT.txt": ("6606e42664459c756f5dd09200f689d04df36f82f22f6bff85d8e138dfd07ec6", 1700),
    "Vivid-Apache-2.0.txt": ("cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30", 11358),
    "Vivid-Apple-Distribution.txt": ("0e34a96aa82d61d38a37721f23825f1e2a76d08d85c0b92bd199c83f167f00fd", 4930),
    "Vivid-GPL-3.0.txt": ("3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986", 35149),
    "Vulkan-Headers-MIT.txt": ("a3132705aff09e9570975cd6d786ed523ba3cc8b00202f87e52660354273d0f6", 2611),
    "cereal-BSD-3-Clause.txt": ("04fd5dc52f69175e833cd041b0937e82fd6e0e21d79d233fd7059081210ad6ae", 2340),
    "dav1d-BSD-2-Clause.txt": ("f50a03872cfac7a7df6e6501001fd1552611a39449947341bea07f90c39732bf", 2032),
    "fast_float-MIT.txt": ("73aef326ccc5d476ab7d216ccbbac70040303b8ff83379224c2d56f5142f9bf1", 1759),
    "glad-CC0-1.0-Apache-2.0.txt": ("6c1aa2ce2fc8b2182a193dd7733ddfc23a5b3c971cd1041e0ce6637c0cf022af", 3978),
    "glslang-Multiple.txt": ("38a495842535d9fc839bf0e2506bba2234b932f13c22f07c05c9c892c037ed6d", 55653),
    "libass-ISC.txt": ("0c0ecfd31af3075fe953b53b61476dd96cf02b92c5578f339c8ed491357cc51c", 1380),
    "libbluray-LGPL-2.1.txt": ("884aaacb887f685971d546f1422f9f04530cc559c70fc6cbe1d5bbf95adf5ce9", 25209),
    "libdovi-MIT.txt": ("2ac7bd44cfc1c9cd26c093a22ee046b3b77b6084faf85f3bc660f62788f708ad", 20284),
    "libplacebo-LGPL-2.1.txt": ("5668d3f00936677e272f723dcc068801af2688d5a81e13e6491ae08ad493656c", 25195),
    "libudfread-LGPL-2.1.txt": ("a62ba659972196d4302bf2eb610de0c49d887edf3b8dd98b4aa52ed4b706821a", 27174),
    "libunibreak-Zlib.txt": ("0fd3236dc8ae59edfebe2e09e315ba6336eb104594bfdf89bd603b330c401101", 1642),
    "mpv-GPL-2.0-or-later.txt": ("974cd36ce277ec0f79fc30dd5982f30e618ce9930308de13a88d3af36a77f4a9", 49850),
    "shaderc-Apache-2.0.txt": ("2e6e7b9a7b8c85dc6e1753baad991192fdfc43b8773b7506088c1b714b869743", 12241),
    "uavs3d-BSD-3-Clause.txt": ("92987241ce896e958db7ef187d8b9bf95a7ead2593847ea875aec7cd1bb311d1", 2331),
    "uchardet-MPL-1.1.txt": ("7c2910b9704f9cf35b3524aed78a479bf64233ed9caa6663d082d1c296c0c1e6", 71244),
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
