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
were updated; their upstream texts are unchanged. README.txt is Vivid's own overview, which
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
    "FFmpeg-LGPL-2.1-or-later.txt": ("72c161ec48722bdd4da18a6eeaec7caddfa8b6187d4ee1db2325e21f0d055931", 39281),
    "FreeType-FTL.txt": ("43f694f5089e4732027b2768e23c9f0eace282577a1f77b6ad067ee7e1190ce0", 15662),
    "FriBidi-LGPL-2.1.txt": ("efd0135835b87549883f9a3edc513d160338db4989942a933e4728ce869c6cde", 27063),
    "HarfBuzz-MIT.txt": ("6e2007cc2b240522af63f4ed2c7e90d11f0e726d246c1887bde53f00a1902dda", 4182),
    "LittleCMS-MIT.txt": ("35203b0504d5cb4dfc32837a242863e0098ab350457d20b7483f6a4dfeac50fe", 1693),
    "MoltenVK-Apache-2.0.txt": ("57085b42ecb28c36b3e6293cbdad2fa3f49323a7d4652d3dc27dc80dab710d60", 12183),
    "Rust-Standard-Library-MIT.txt": ("4e33a8e97437d3dbf459cb4adc16d14cb8300685f7b956c3c82c3768d6d6f6cb", 3664),
    "SPIRV-Cross-Apache-2.0.txt": ("fb9b07689f16dd2f26bb823b304f866c3510b26cbf9882be78f115e473e16de2", 13751),
    "SPIRV-Headers-MIT.txt": ("53f637fa9add95006c58844267eeda7cb3ec8afda9b57ba27235a571e0292ee8", 24230),
    "SPIRV-Tools-Apache-2.0.txt": ("b03185cd87802fe40144ff4e75251c20a8c1dce90c4a2e27911f2a0a1f1fd223", 12065),
    "ThumbHash-MIT.txt": ("c3848c6ae5964087a2a7c73de48d47d713f641319beebc74d243652614d8d65b", 1721),
    "Vivid-Apache-2.0.txt": ("cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30", 11358),
    "Vivid-Apple-Distribution.txt": ("0e34a96aa82d61d38a37721f23825f1e2a76d08d85c0b92bd199c83f167f00fd", 4930),
    "Vivid-GPL-3.0.txt": ("3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986", 35149),
    "Vulkan-Headers-MIT.txt": ("a3132705aff09e9570975cd6d786ed523ba3cc8b00202f87e52660354273d0f6", 2611),
    "cereal-BSD-3-Clause.txt": ("04fd5dc52f69175e833cd041b0937e82fd6e0e21d79d233fd7059081210ad6ae", 2340),
    "dav1d-BSD-2-Clause.txt": ("2951973ad07b25b7b20f5d1eec0ad7ff249c286a1aec47bbd3d98374874cf676", 2081),
    "fast_float-MIT.txt": ("73aef326ccc5d476ab7d216ccbbac70040303b8ff83379224c2d56f5142f9bf1", 1759),
    "glad-CC0-1.0-Apache-2.0.txt": ("6c1aa2ce2fc8b2182a193dd7733ddfc23a5b3c971cd1041e0ce6637c0cf022af", 3978),
    "glslang-Multiple.txt": ("38a495842535d9fc839bf0e2506bba2234b932f13c22f07c05c9c892c037ed6d", 55653),
    "libass-ISC.txt": ("0f2322cb9a1c7ef06552910f2cd689a8f2c8c46abf3d4f6d96dda9819eac40bc", 1405),
    "libbluray-LGPL-2.1.txt": ("2e3c8f707f47c236a842237fd2ca3d9d9a4b1f0741267c5489972b74c8eddb62", 25235),
    "libdovi-MIT.txt": ("a872f0512e3aa3d745e212cec8716c8b88f52fee80d79e277418726d11b502b8", 20330),
    "libplacebo-LGPL-2.1.txt": ("8c283115f55c0ab275afefcf515001fac48149f9e3b9f99953effc681bfdc2f5", 25213),
    "libudfread-LGPL-2.1.txt": ("a62ba659972196d4302bf2eb610de0c49d887edf3b8dd98b4aa52ed4b706821a", 27174),
    "libunibreak-Zlib.txt": ("322404a04b67c66bdc9adfba8867f7aa03a497fe805b9958784b86c2ac0ead9e", 1670),
    "mpv-LGPL-2.1-or-later.txt": ("61e72a0755849d42909f81b2219dfa84048897e5dc699dd31bf6b22c294b9817", 31864),
    "shaderc-Apache-2.0.txt": ("8a1d23d6ed8c9946843c0490fb4b50792e637d27ef3b9b65a901ca24312feac4", 12263),
    "uavs3d-BSD-3-Clause.txt": ("1b08310787bfced71a5e7212cf4e22562ccb65e2053abb29c82dcd06b2f222f4", 2281),
    "uchardet-MPL-1.1.txt": ("e3eabe0b51755b0f429c581ee6fc1d28da6db34d2ece6a23ea58ca81ba2c2b45", 71262),
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
