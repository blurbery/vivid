"""Corpus and verdicts for the libdovi C API test (`lucid.py test-libdovi`).

Builds a corpus of Dolby Vision RPUs, runs it through harness.c linked
against the patched and the unpatched libdovi, and checks the rules of
docs/playback/lucid-engine-patch-spec.md 5.13 and 9.4:

- no input aborts the patched library, through every entry point and in
  the order FFmpeg's profile 7 conversion and libplacebo call them;
- malformed RPUs give each entry point's error result, and the display
  management query never returns null after a header that has the data;
- unpatched 3.3.2 aborts on each abort class (run in its own process);
- wherever unpatched 3.3.2 does not abort, both libraries give the same
  results and bytes (valid profile 5, 7, 8.1 and 8.4 RPUs from libdovi's
  test assets byte for byte), and error texts differ only where the
  patch's own checks fire, as single lines without fault substrings.

The malformed RPUs are generated here: zero-filled buffers, every
truncation of valid samples, random bytes after every start pattern,
every single-bit flip of valid profile 7 RPUs, FFmpeg's guard vectors, and
RPUs written field by field with a correct CRC that carry one defect each.
Python 3.9 standard library only. Part of Vivid's Lucid Engine build; MIT
licence, like libdovi.
"""

from __future__ import annotations

import random
import struct
from dataclasses import dataclass, field
from pathlib import Path

# Corpus kinds.
VALID = "valid"            # both libraries must agree byte for byte
ERROR = "error"            # every entry point must return its error result
NO_ABORT = "no-abort"      # must not abort; the parse may succeed or fail
WRITES_FAIL = "writes-fail"  # parses as upstream does; every writer must fail cleanly
HEADER_RULE = "header-rule"  # as VALID, except headers 5.13 rule 2 turns into null

FLAG_DUMP = 1
FLAG_NULL = 2
FLAG_SKIP_RPU = 4        # dovi_parse_rpu
FLAG_SKIP_NALU = 8       # dovi_parse_unspec62_nalu
FLAG_SKIP_AV1 = 16       # dovi_parse_itu_t35_dovi_metadata_obu
FLAG_SKIP_CALLERS = 32   # FFmpeg's and libplacebo's call sequences
# A valid RPU goes only to the parser that takes its form; the same bytes go
# through every parser again as a no-abort case.
ONLY = {
    "hevc-nalu": FLAG_SKIP_RPU | FLAG_SKIP_AV1,
    "hevc-rpu": FLAG_SKIP_NALU | FLAG_SKIP_AV1 | FLAG_SKIP_CALLERS,
    "av1-obu": FLAG_SKIP_RPU | FLAG_SKIP_NALU | FLAG_SKIP_CALLERS,
}

SEED = 20261013
# Most memory one patched case may use (every entry point, every mode).
MAX_RSS_KB = 64 * 1024


# The abort classes of spec 5.13. Unpatched 3.3.2 must abort on each (shown
# in a separate process per case), and the patched build must not.
CLASS_MAPPING = "mapping method code of 2 or more"
CLASS_INTERP = "linear interpolation in a first-order piece"
CLASS_CRC = "CRC range (FFmpeg's guard class)"
CLASS_LENGTH = "unknown CM v4.0 level 8, 9 or 10 block length"
CLASS_COUNT = "very large Exp-Golomb count"
CLASS_WRITER = "writing a curve that mixes polynomial and MMR pieces"
ABORT_CLASSES = (CLASS_MAPPING, CLASS_INTERP, CLASS_CRC, CLASS_LENGTH, CLASS_COUNT, CLASS_WRITER)


@dataclass
class Case:
    name: str
    kind: str
    data: bytes
    flags: int = 0
    group: str = ""
    required_parse: tuple = ()  # parser columns that must parse (VALID only)
    abort_class: str = ""       # one of ABORT_CLASSES, for the class's own entries
    ffmpeg_expect: str = "skip"  # FFmpeg's conversion result (WRITES_FAIL, NAL form)


# ------------------------------------------------------------ bitstreams

def crc32_mpeg2(data: bytes) -> int:
    crc = 0xFFFFFFFF
    for byte in data:
        crc ^= byte << 24
        for _ in range(8):
            crc = ((crc << 1) ^ 0x04C11DB7) if crc & 0x80000000 else crc << 1
            crc &= 0xFFFFFFFF
    return crc


class Bits:
    def __init__(self):
        self.bits: list[int] = []

    def u(self, value: int, n: int) -> "Bits":
        for i in reversed(range(n)):
            self.bits.append((value >> i) & 1)
        return self

    def flag(self, value) -> "Bits":
        self.bits.append(1 if value else 0)
        return self

    def ue(self, value: int) -> "Bits":
        v = value + 1
        n = v.bit_length() - 1
        self.bits.extend([0] * n)
        return self.u(v, n + 1)

    def ue_raw(self, leading_zeros: int, suffix: int) -> "Bits":
        """An Exp-Golomb code with an explicit prefix, for codes no u64 holds."""
        self.bits.extend([0] * leading_zeros)
        self.bits.append(1)
        return self.u(suffix, leading_zeros)

    def se(self, value: int) -> "Bits":
        return self.ue(2 * value - 1 if value > 0 else -2 * value)

    def varbits(self, value: int, n: int) -> "Bits":
        """EMDF variable_bits(n), as libdovi's parse_variable_bits reads it."""
        chunks = []
        while value >= 1 << n:
            chunks.insert(0, value & ((1 << n) - 1))
            value = (value >> n) - 1
        chunks.insert(0, value)
        for i, c in enumerate(chunks):
            self.u(c, n).flag(i < len(chunks) - 1)
        return self

    def align(self, bit: int = 0) -> "Bits":
        while len(self.bits) % 8:
            self.bits.append(bit)
        return self

    def tobytes(self) -> bytes:
        assert len(self.bits) % 8 == 0
        out = bytearray()
        for i in range(0, len(self.bits), 8):
            b = 0
            for bit in self.bits[i:i + 8]:
                b = (b << 1) | bit
            out.append(b)
        return bytes(out)


def escape(raw: bytes) -> bytes:
    """Adds HEVC emulation prevention bytes."""
    out, zeros = bytearray(), 0
    for b in raw:
        if zeros >= 2 and b <= 3:
            out.append(3)
            zeros = 0
        out.append(b)
        zeros = zeros + 1 if b == 0 else 0
    return bytes(out)


def unescape(data: bytes) -> bytes:
    out = bytearray()
    for i, b in enumerate(data):
        if i >= 2 and b == 3 and data[i - 1] == 0 and data[i - 2] == 0:
            continue
        out.append(b)
    return bytes(out)


def annexb(raw: bytes) -> bytes:
    return b"\x00\x00\x00\x01" + escape(raw)


def with_crc(body: bytes) -> bytes:
    """body starts with the 0x19 prefix; appends the CRC32 and 0x80."""
    return body + struct.pack(">I", crc32_mpeg2(body[1:])) + b"\x80"


def fix_crc(raw: bytes) -> bytes:
    """Recomputes the CRC32 of an RPU (0x19 ... CRC32 0x80, no trailing zeros)."""
    return with_crc(raw[:-5])


# ----------------------------------------------------------- RPU writer

def poly_piece(order_minus1=0, interp=0, coefs=((0, 0), (1, 0)), idc=0):
    return {"idc": idc, "order": order_minus1, "interp": interp, "coefs": list(coefs)}


def mmr_piece(order_minus1=0, constant=(0, 0), idc=1):
    coefs = [[(0, 0)] * 7 for _ in range(order_minus1 + 1)]
    return {"idc": idc, "mmr_order": order_minus1, "constant": constant, "coefs": coefs}


def l8_payload(length: int) -> Bits:
    b = Bits().u(1, 8)  # target_display_index
    for _ in range(6):
        b.u(2048, 12)
    if length > 10:
        b.u(2048, 12)
    if length > 12:
        b.u(2048, 12)
    if length > 13:
        for _ in range(6):
            b.u(0, 8)
    if length > 19:
        for _ in range(6):
            b.u(0, 8)
    return b


def block(level: int, length: int, payload: Bits, length_code=None) -> Bits:
    b = Bits()
    if length_code is not None:
        b.bits.extend(length_code.bits)
    else:
        b.ue(length)
    b.u(level, 8)
    b.bits.extend(payload.bits)
    pad = min(length, 64) * 8 - len(payload.bits)
    b.bits.extend([0] * max(pad, 0))
    return b


def default_cmv29():
    return [block(1, 5, Bits().u(0, 12).u(2081, 12).u(1229, 12))]


def default_cmv40():
    return [
        block(254, 2, Bits().u(0, 8).u(2, 8)),
        block(8, 25, l8_payload(25)),
        block(9, 1, Bits().u(0, 8)),
        block(10, 5, Bits().u(20, 8).u(2081, 12).u(62, 12).u(0, 8)),
    ]


def build_rpu(**o) -> bytes:
    """A raw RPU (0x19 prefix ... CRC32 0x80) for profile 8.1 by default.
    Keyword arguments override single fields or inject raw codes."""
    def g(key, default):
        return o.get(key, default)

    w = Bits().u(0x19, 8)
    # rpu_data_header()
    w.u(2, 6).u(g("rpu_format", 18), 11).u(g("vdr_rpu_profile", 1), 4).u(0, 4)
    w.flag(1).flag(0).u(0, 2)  # vdr_seq_info_present, chroma explicit, coefficient_data_type 0
    if "log2_denom_code" in o:
        w.bits.extend(o["log2_denom_code"].bits)
    else:
        w.ue(g("coefficient_log2_denom", 23))
    w.u(1, 2).flag(g("bl_full_range", 0))
    w.ue(2).ue(2).ue(4)  # bl, el and vdr bit depths minus 8
    w.flag(0).u(0, 3).flag(0).flag(1)  # spatial, reserved, el spatial, disable_residual
    w.flag(not o.get("no_dm")).flag(0)  # vdr_dm_metadata_present, use_prev_vdr_rpu
    # rpu_data_mapping()
    w.bits.extend(g("vdr_rpu_id_code", Bits().ue(0)).bits)
    w.ue(0).ue(0)
    curves = g("curves", [[poly_piece(coefs=((0, 0), (1, 0)))] for _ in range(3)])
    pivots = g("pivots", [[0, 1023] for _ in range(3)])
    for cmp in range(3):
        code = o.get(f"num_pivots_code{cmp}")
        if code is not None:
            w.bits.extend(code.bits)
        else:
            w.ue(len(pivots[cmp]) - 2)
        for p in pivots[cmp]:
            w.u(p, 10)
    if "partitions_code" in o:
        w.bits.extend(o["partitions_code"].bits)
    else:
        w.ue(0)
    w.ue(0)
    for cmp in range(3):
        for piece in curves[cmp]:
            if isinstance(piece.get("idc_code"), Bits):
                w.bits.extend(piece["idc_code"].bits)
            else:
                w.ue(piece["idc"])
            if "order" in piece:
                if isinstance(piece.get("order_code"), Bits):
                    w.bits.extend(piece["order_code"].bits)
                else:
                    w.ue(piece["order"])
                if piece["order"] == 0:
                    w.flag(piece["interp"])
                for ci, cf in piece["coefs"]:
                    w.se(ci).u(cf, 23)
            else:
                w.u(piece["mmr_order"], 2)
                w.se(piece["constant"][0]).u(piece["constant"][1], 23)
                for order in piece["coefs"]:
                    for ci, cf in order:
                        w.se(ci).u(cf, 23)
    w.bits.extend(g("mapping_tail", Bits()).bits)
    if o.get("no_dm"):
        w.align()
        return with_crc(w.tobytes())
    # vdr_dm_data_payload()
    if "affected_code" in o:
        w.bits.extend(o["affected_code"].bits)
    else:
        w.ue(0)
    w.bits.extend(g("current_code", Bits().ue(0)).bits)
    w.bits.extend(g("refresh_code", Bits().ue(0)).bits)
    for c in (9574, 0, 13802, 9574, -1540, -5348, 9574, 17610, 0):
        w.u(c & 0xFFFF, 16)
    for c in (16777216, 134217728, 134217728):
        w.u(c, 32)
    for c in (7222, 8771, 390, 2654, 12430, 1300, 0, 422, 15962):
        w.u(c & 0xFFFF, 16)
    w.u(65535, 16).u(0, 16).u(0, 16).u(0, 32)
    w.u(12, 5).u(0, 2).u(0, 2).u(1, 2)
    w.u(62, 12).u(3079, 12).u(42, 10)
    blocks29 = g("cmv29", default_cmv29())
    if "cmv29_count_code" in o:
        w.bits.extend(o["cmv29_count_code"].bits)
    else:
        w.ue(len(blocks29))
    w.align()
    for b in blocks29:
        w.bits.extend(b.bits)
    blocks40 = g("cmv40", default_cmv40())
    if blocks40 is not None:
        if "cmv40_count_code" in o:
            w.bits.extend(o["cmv40_count_code"].bits)
        else:
            w.ue(len(blocks40))
        w.align()
        for b in blocks40:
            w.bits.extend(b.bits)
    w.align()
    return with_crc(w.tobytes())


def av1_payload(raw: bytes, size=None, country_code=False) -> bytes:
    """ITU-T T.35 payload carrying `raw` (0x19 ... 0x80) in an EMDF container."""
    payload = raw[1:]
    w = Bits().u(0x3B, 16).u(0x800, 32)
    w.u(0, 2).u(6, 3).u(31, 5).varbits(225, 5)
    w.u(0, 4).flag(1)
    w.varbits(len(payload) if size is None else size, 8)
    for b in payload:
        w.u(b, 8)
    w.u(0, 5).u(1, 2).u(0, 2).u(0, 8)
    w.align(1)
    out = w.tobytes()
    return (b"\xb5" + out) if country_code else out


# ----------------------------------------------------------------- corpus

def split_annexb(data: bytes) -> list[bytes]:
    """NAL units of an Annex B stream, each with its 4-byte start code."""
    starts = []
    i = 0
    while True:
        i = data.find(b"\x00\x00\x00\x01", i)
        if i < 0:
            break
        starts.append(i)
        i += 4
    units = []
    for n, s in enumerate(starts):
        end = starts[n + 1] if n + 1 < len(starts) else len(data)
        units.append(data[s:end])
    return units


def asset_rpus(assets: Path) -> list[tuple[str, bytes]]:
    rpus = []
    for path in sorted((assets / "tests").glob("*.bin")):
        for n, unit in enumerate(split_annexb(path.read_bytes())):
            rpus.append((f"tests/{path.name}#{n}", unit))
    for name in ("regular_rpu.bin", "regular_rpu_mel.bin"):
        path = assets / "hevc_tests" / name
        for n, unit in enumerate(split_annexb(path.read_bytes())):
            rpus.append((f"hevc_tests/{name}#{n}", unit))
    return rpus


def raw_rpu(unit: bytes) -> bytes:
    """The unescaped RPU (0x19 ... 0x80) of an Annex B RPU unit."""
    raw = unescape(unit[4:])
    return raw.rstrip(b"\x00")




def oversized_codes() -> list[tuple[str, Bits]]:
    codes = [(f"2^{e}", Bits().ue(1 << e)) for e in (16, 20, 24, 31, 32, 40, 48, 50, 56, 62, 63)]
    codes.append(("2^64-2", Bits().ue((1 << 64) - 2)))
    codes.append(("64-zero-prefix", Bits().ue_raw(64, (1 << 64) - 1)))
    codes.append(("70-zero-prefix", Bits().ue_raw(70, 0)))
    codes.append(("1000-zero-prefix", Bits().ue_raw(1000, 0)))
    return codes


# FFmpeg's libdovi guard vectors (spec 9.4): the first three are the CRC
# range class, which unpatched 3.3.2 aborts on; the fourth is not.
GUARD_VECTORS = [
    ("guard/zeros", bytes([0x7C, 0x01, 0x19, 0x08, 0x09]) + bytes(20), True),
    ("guard/80-80", bytes([0x7C, 0x01, 0x19, 0x08, 0x09, 0x80, 0x80]) + bytes(18), True),
    ("guard/escaped", bytes([0x7C, 0x01, 0x19, 0x08, 0x09, 0x00, 0x00, 0x03]) + bytes(17), True),
    ("guard/not-skipped", bytes([0x7C, 0x01, 0x19, 0x08, 0x09, 0x01, 0x02, 0x80]) + bytes(17), False),
]

# Start patterns libdovi recognises: HEVC (validated_trimmed_data) and AV1.
START_PATTERNS = [
    ("annexb-4", b"\x00\x00\x00\x01\x19"), ("annexb-3", b"\x00\x00\x01\x19\x08"),
    ("prefix-0001", b"\x00\x01\x19\x08\x09"), ("nalu-7c01", b"\x7c\x01\x19\x08\x09"),
    ("prefix-01", b"\x01\x19\x08\x09"), ("rpu", b"\x19\x08\x09"),
    ("av1", bytes([0x00, 0x3B, 0x00, 0x00, 0x08, 0x00, 0x37, 0xCD, 0x08])),
    ("av1-country", bytes([0xB5, 0x00, 0x3B, 0x00, 0x00, 0x08, 0x00, 0x37, 0xCD, 0x08])),
]


def crafted_cases() -> list[Case]:
    cases = []

    def add(name, kind, data, group, abort_class=""):
        cases.append(Case(name, kind, data, group=group or abort_class, abort_class=abort_class))

    base = build_rpu()
    add("crafted/p81-baseline", VALID, base, "crafted valid")
    p5 = build_rpu(vdr_rpu_profile=0, bl_full_range=1)
    add("crafted/p5-baseline", VALID, p5, "crafted valid")
    chroma_mmr = [[poly_piece()], [mmr_piece()], [mmr_piece(order_minus1=2)]]
    mmr = build_rpu(curves=chroma_mmr)
    add("crafted/p81-mmr-baseline", VALID, mmr, "crafted valid")
    multi = build_rpu(pivots=[[0, 300, 700, 1023], [0, 1023], [0, 512, 1023]],
                      curves=[[poly_piece(1, coefs=((0, 0), (1, 0), (0, 0)))] * 3,
                              [mmr_piece()], [mmr_piece(), mmr_piece(1)]])
    add("crafted/p81-multi-piece", VALID, multi, "crafted valid")
    add("crafted/p81-baseline-annexb", VALID, annexb(base), "crafted valid")
    add("crafted/p81-baseline-nalu", VALID, b"\x7c\x01" + escape(base), "crafted valid")
    add("crafted/p81-baseline-av1", VALID, av1_payload(base), "crafted valid")
    add("crafted/p81-baseline-av1-country", VALID, av1_payload(base, country_code=True),
        "crafted valid")
    add("crafted/p5-baseline-av1", VALID, av1_payload(p5), "crafted valid")
    # A header without display management data. Conversion to 8.4 (mode 4)
    # then gives a header that says the data is present while the RPU has
    # none; 5.13 rule 2 makes that header query return null.
    cases.append(Case("crafted/p81-no-dm", HEADER_RULE, build_rpu(no_dm=True), FLAG_DUMP,
                      "header without display management data"))

    # Each abort class: the baseline with that one field changed and the CRC
    # recomputed, in its HEVC NAL form (what FFmpeg and libplacebo pass) and
    # as a raw RPU or AV1 payload.
    def add_class(name, raw, cls, kind=ERROR):
        add(name, kind, b"\x7c\x01" + escape(raw), "", cls)
        add(name + "/raw", kind, raw, "", cls)

    for code in (2, 3, 7, 255, 1 << 20, 1 << 40):
        for cmp in (0, 1):
            curves = [[poly_piece()] for _ in range(3)]
            curves[cmp] = [dict(poly_piece(), idc_code=Bits().ue(code))]
            raw = build_rpu(curves=curves)
            add_class(f"mapping-method/code-{code}/curve{cmp}", raw, CLASS_MAPPING)
            add(f"mapping-method/code-{code}/curve{cmp}/av1", ERROR, av1_payload(raw), "",
                CLASS_MAPPING)

    for cmp in range(3):
        for coefs in (((0, 0), (1, 0)), ()):
            curves = [[poly_piece()] for _ in range(3)]
            curves[cmp] = [poly_piece(interp=1, coefs=coefs)]
            tag = "with-coefs" if coefs else "bare"
            add_class(f"linear-interp/curve{cmp}/{tag}", build_rpu(curves=curves), CLASS_INTERP)
    curves = [[poly_piece(1, coefs=((0, 0), (1, 0), (0, 0))), poly_piece(interp=1)]
              for _ in range(3)]
    add_class("linear-interp/second-piece", build_rpu(pivots=[[0, 500, 1023]] * 3, curves=curves),
              CLASS_INTERP)

    for name, data, aborts in GUARD_VECTORS:
        add(name, ERROR, data, "" if aborts else "guard vectors", CLASS_CRC if aborts else "")
    # 5 or fewer bytes left after the start bytes, escapes and trailing zeros
    # (the class); 6 left (the boundary, which libdovi rejects cleanly).
    for rest, in_class in ((b"", True), (b"\x80", True), (b"\x80\x80", True),
                           (b"\x00\x00\x03", True), (b"\x01\x80", True),
                           (b"\x00\x00\x03\x80", False), (b"\x01\x02\x80", False)):
        cls, group = (CLASS_CRC, "") if in_class else ("", "guard vectors")
        data = b"\x7c\x01\x19\x08\x09" + rest
        add(f"crc-range/nalu-{rest.hex() or 'none'}", ERROR, data + bytes(30 - len(data)),
            group, cls)
        data = b"\x00\x00\x00\x01\x19\x08\x09" + rest
        add(f"crc-range/annexb-{rest.hex() or 'none'}", ERROR, data + bytes(32 - len(data)),
            group, cls)

    l254 = block(254, 2, Bits().u(0, 8).u(2, 8))
    for length in (0, 1, 9, 11, 14, 18, 20, 24, 26, 255, 1 << 20):
        raw = build_rpu(cmv40=[l254, block(8, length, l8_payload(length))])
        add_class(f"cmv40-length/level8/{length}", raw, CLASS_LENGTH)
    for length in (0, 2, 16, 18, 255, 1 << 20):
        payload = Bits().u(255, 8)
        if length > 1:
            for _ in range(8):
                payload.u(1, 16)
        add_class(f"cmv40-length/level9/{length}",
                  build_rpu(cmv40=[l254, block(9, length, payload)]), CLASS_LENGTH)
    for length in (0, 4, 6, 20, 22, 255, 1 << 20):
        payload = Bits().u(20, 8).u(2081, 12).u(62, 12).u(255, 8)
        if length > 5:
            for _ in range(8):
                payload.u(1, 16)
        add_class(f"cmv40-length/level10/{length}",
                  build_rpu(cmv40=[l254, block(10, length, payload)]), CLASS_LENGTH)

    for label, code in oversized_codes():
        # Codes of more than 64 bits fail to decode before anything is
        # reserved, so they are not entries of the count class.
        decodable = label not in ("70-zero-prefix", "1000-zero-prefix")

        def add_count(name, raw):
            if decodable:
                add_class(name, raw, CLASS_COUNT)
            else:
                add(name, ERROR, b"\x7c\x01" + escape(raw), "other large counts")
                add(name + "/raw", ERROR, raw, "other large counts")

        for cmp in (0, 2):
            add_count(f"count/num_pivots_minus2/curve{cmp}/{label}",
                      build_rpu(**{f"num_pivots_code{cmp}": code}))
        add_count(f"count/cmv29-num_ext_blocks/{label}", build_rpu(cmv29_count_code=code))
        add_count(f"count/cmv40-num_ext_blocks/{label}", build_rpu(cmv40_count_code=code))
        # Counts that size nothing: expected to fail cleanly in both builds.
        add(f"count/cmv29-ext_block_length/{label}", ERROR,
            build_rpu(cmv29=[block(1, 5, Bits().u(0, 12).u(2081, 12).u(1229, 12),
                                   length_code=code)]), "other large counts")
        add(f"count/coefficient_log2_denom/{label}", ERROR, build_rpu(log2_denom_code=code),
            "other large counts")
        add(f"count/poly_order_minus1/{label}", ERROR,
            build_rpu(curves=[[dict(poly_piece(), order_code=code)]] + [[poly_piece()]] * 2),
            "other large counts")
        add(f"count/affected_dm_metadata_id/{label}", ERROR, build_rpu(affected_code=code),
            "other large counts")
        # The partition count is only stored, so such an RPU can parse.
        add(f"count/num_x_partitions_minus1/{label}", NO_ABORT, build_rpu(partitions_code=code),
            "other large counts (stored only)")
        # A level 8 length libdovi does not know; codes of more than 64 bits
        # fail to parse before the block is reached.
        known = "zero-prefix" not in label or label.startswith("64")
        add(f"count/cmv40-l8-length/{label}", ERROR,
            build_rpu(cmv40=[l254, block(8, 25, l8_payload(25), length_code=code)]),
            "" if known else "other large counts", CLASS_LENGTH if known else "")
    for size in (1 << 16, 1 << 24, (1 << 31) + 5, (1 << 32) - 1):
        add(f"count/av1-emdf_payload_size/{size}", ERROR, av1_payload(base, size=size), "",
            CLASS_COUNT)

    # u64::MAX (an Exp-Golomb code with 64 leading zeros) in a field parsing
    # only stores. Upstream parses it; its writer then writes a run of
    # 4294967295 zero bits (512 MiB) before failing.
    max_code = Bits().ue_raw(64, (1 << 64) - 1)
    for field_name in ("vdr_rpu_id_code", "partitions_code", "current_code", "refresh_code"):
        raw = build_rpu(**{field_name: max_code})
        label = field_name[:-5]
        # Conversion mode 2 resets the partition counts, so FFmpeg's
        # conversion writes that one; the other fields survive conversion.
        cases.append(Case(f"write-u64-max/{label}", WRITES_FAIL, b"\x7c\x01" + escape(raw),
                          group="u64::MAX in a stored field", required_parse=("hevc-nalu",),
                          ffmpeg_expect="convert" if label == "partitions" else "skip"))
        cases.append(Case(f"write-u64-max/{label}/raw", WRITES_FAIL, raw, ONLY["hevc-rpu"],
                          "u64::MAX in a stored field", ("hevc-rpu",)))

    # Mixed mapping methods within one curve, in a profile 8 RPU whose curves
    # conversion mode 2 keeps: upstream parses it, then its writer indexes
    # past the end of the polynomial pieces and panics.
    for order, curve in (("mmr-then-poly", [mmr_piece(), poly_piece()]),
                         ("poly-then-mmr", [poly_piece(), mmr_piece()])):
        raw = build_rpu(pivots=[[0, 1023], [0, 500, 1023], [0, 1023]],
                        curves=[[poly_piece()], curve, [poly_piece()]])
        cases.append(Case(f"writer/mixed-methods/{order}", WRITES_FAIL,
                          b"\x7c\x01" + escape(raw), group=CLASS_WRITER,
                          required_parse=("hevc-nalu",), abort_class=CLASS_WRITER))
        cases.append(Case(f"writer/mixed-methods/{order}/raw", WRITES_FAIL, raw,
                          ONLY["hevc-rpu"], CLASS_WRITER, ("hevc-rpu",), CLASS_WRITER))
    return cases


def build_corpus(assets: Path) -> list[Case]:
    rng = random.Random(SEED)
    cases: list[Case] = []

    # Valid RPUs from libdovi's own test assets (profile 5, 7 FEL and MEL,
    # 8.1 and 8.4 among them), each given to the parser for its form and
    # compared between the builds, and through every parser as no-abort
    # cases.
    required = {"profile5.bin", "fel_orig.bin", "mel_orig.bin", "profile8.bin", "profile84.bin",
                "p84-01-ref.bin", "p5-01-ref.bin"}

    def add_valid(name, data, form, group, require=True):
        cases.append(Case(name, VALID, data, FLAG_DUMP | ONLY[form], group,
                          (form,) if require else ()))
        cases.append(Case(name + "/every-parser", NO_ABORT, data, 0,
                          "valid RPUs through every parser"))

    valid_units = asset_rpus(assets)
    for name, unit in valid_units:
        req = name.split("/")[-1].split("#")[0] in required
        add_valid(f"asset/{name}", unit, "hevc-nalu", "libdovi test assets", req)
        raw = raw_rpu(unit)
        if name.startswith("tests/") and raw[:1] == b"\x19":
            add_valid(f"asset/{name}/raw", raw, "hevc-rpu", "libdovi test assets", False)
    for path in sorted((assets / "av1-rpu").glob("*.bin")):
        if path.name.endswith("-ref.bin"):
            for n, unit in enumerate(split_annexb(path.read_bytes())):
                add_valid(f"asset/av1-rpu/{path.name}#{n}", unit, "hevc-nalu",
                          "libdovi test assets", path.name in required)
        else:
            add_valid(f"asset/av1-rpu/{path.name}", path.read_bytes(), "av1-obu",
                      "libdovi test assets")

    crafted = crafted_cases()
    for c in crafted:
        if c.kind == VALID:
            if c.name.endswith(("av1", "av1-country")):
                form = "av1-obu"
            elif c.name.endswith(("annexb", "nalu")):
                form = "hevc-nalu"
            else:
                form = "hevc-rpu"
            add_valid(c.name, c.data, form, c.group)
        else:
            cases.append(c)

    # Every entry point with null pointers.
    cases.append(Case("null-pointers", ERROR, b"", FLAG_NULL, "null pointers"))

    # Zero-filled buffers, alone and after each start pattern.
    for label, prefix in [("none", b"")] + START_PATTERNS:
        for n in list(range(0, 40)) + [64, 100, 255, 256, 512, 4096]:
            cases.append(Case(f"zero-filled/{label}/{n}", ERROR, prefix + bytes(n),
                              group="zero-filled"))

    # Every truncation of valid profile 5, 7 FEL, 7 MEL and 8.1 RPUs.
    by_name = dict(valid_units)
    samples = [("profile5", by_name["tests/profile5.bin#0"]),
               ("p7-fel", by_name["tests/fel_orig.bin#0"]),
               ("p7-mel", by_name["tests/mel_orig.bin#0"]),
               ("p81", by_name["tests/profile8.bin#0"])]
    for label, unit in samples:
        end = len(unit.rstrip(b"\x00"))
        for n in range(end):
            cases.append(Case(f"truncated/{label}/{n}", ERROR, unit[:n], group="truncations"))
        nalu = b"\x7c\x01" + unit[4:end]
        for n in range(len(nalu)):
            cases.append(Case(f"truncated/{label}-nalu/{n}", ERROR, nalu[:n],
                              group="truncations"))
        raw = raw_rpu(unit)
        for n in range(len(raw)):
            cases.append(Case(f"truncated/{label}-raw/{n}", ERROR, raw[:n], group="truncations"))
    for path in sorted((assets / "av1-rpu").glob("*.bin"))[:2]:
        data = path.read_bytes()
        for n in range(len(data) - 16):
            cases.append(Case(f"truncated/av1-{path.name}/{n}", ERROR, data[:n],
                              group="truncations"))

    # Every single-bit flip of valid profile 7 RPUs (FEL and MEL).
    for label in ("p7-fel", "p7-mel"):
        unit = dict(samples)[label]
        for i in range(len(unit) * 8):
            flipped = bytearray(unit)
            flipped[i // 8] ^= 0x80 >> (i % 8)
            cases.append(Case(f"bit-flip/{label}/{i}", ERROR, bytes(flipped), group="bit flips"))

    # Random bytes from a fixed seed, alone and after each start pattern.
    for i in range(1000):
        n = rng.randrange(0, 600)
        cases.append(Case(f"random/none/{i}", ERROR, bytes(rng.getrandbits(8) for _ in range(n)),
                          group="random bytes"))
    for label, prefix in START_PATTERNS:
        for i in range(250):
            n = rng.randrange(0, 400)
            cases.append(Case(f"random/{label}/{i}", ERROR,
                              prefix + bytes(rng.getrandbits(8) for _ in range(n)),
                              group="random bytes"))

    # Structured fuzz: valid RPUs with random byte changes and a corrected
    # CRC, so parsing reaches the mapping and display management data.
    # These may parse; the requirement is that nothing aborts.
    sources = [raw_rpu(u) for _, u in samples] + [c.data for c in crafted
                                                  if c.kind == VALID and c.data[:1] == b"\x19"
                                                  and not c.name.endswith("no-dm")]
    for i in range(3000):
        raw = bytearray(rng.choice(sources))
        for _ in range(rng.randrange(1, 9)):
            pos = rng.randrange(3, len(raw) - 5)
            if rng.random() < 0.5:
                raw[pos] ^= 1 << rng.randrange(8)
            else:
                raw[pos] = rng.getrandbits(8)
        cases.append(Case(f"mutated-crc-fixed/{i}", NO_ABORT, fix_crc(bytes(raw)),
                          group="random changes, CRC corrected"))
    for i in range(1000):
        head = rng.choice(sources)[:rng.randrange(4, 12)]
        body = head + bytes(rng.getrandbits(8) for _ in range(rng.randrange(0, 300)))
        cases.append(Case(f"random-tail-crc-fixed/{i}", NO_ABORT, with_crc(body),
                          group="random changes, CRC corrected"))
    return cases


def write_cases(cases: list[Case], path: Path) -> None:
    with open(path, "wb") as f:
        f.write(b"LDVC1\n")
        for c in cases:
            name = c.name.encode()
            f.write(struct.pack(">I", len(name)) + name + bytes([c.flags]))
            f.write(struct.pack(">I", len(c.data)) + c.data)


# --------------------------------------------------------------- verdicts

COLUMNS = ("hevc-rpu", "hevc-nalu", "av1-obu", "bin-file")


@dataclass
class Result:
    status: str
    parsers: dict = field(default_factory=dict)
    ffmpeg: str = ""
    placebo: str = ""
    patch_texts: int = 0
    bad_texts: int = 0
    header_rule: int = 0
    digest: str = ""
    digest_results: str = ""
    max_rss_kb: int = 0


def parse_output(text: str, count: int) -> list[Result]:
    results: list[Result | None] = [None] * count
    for line in text.splitlines():
        parts = line.split("\t")
        if len(parts) != 12:
            raise ValueError(f"unexpected harness line: {line!r}")
        index = int(parts[0])
        if parts[2] == "-":
            results[index] = Result(parts[1])
            continue
        texts, bad, header_rule = (int(x) for x in parts[8].split(":"))
        results[index] = Result(parts[1], dict(zip(COLUMNS, parts[2:6])), parts[6], parts[7],
                                texts, bad, header_rule, parts[9], parts[10], int(parts[11]))
    missing = [i for i, r in enumerate(results) if r is None]
    if missing:
        raise ValueError(f"harness gave no result for {len(missing)} cases, first {missing[0]}")
    return results  # type: ignore[return-value]


def evaluate(cases: list[Case], patched: list[Result], unpatched: list[Result],
             dumps: tuple[Path, Path]) -> dict:
    """Spec 5.13 rules 1 to 5 and 9.4, case by case."""
    failures: list[str] = []
    groups: dict[str, dict] = {}
    classes = {cls: {"cases": 0, "unpatched_aborts": 0, "not_aborting": []}
               for cls in ABORT_CLASSES}
    max_rss = unpatched_max_rss = 0
    changed_texts = 0
    header_rule_cases = 0

    def dump_paths(i):
        return f"(dumps {dumps[0] / f'{i}.txt'} and {dumps[1] / f'{i}.txt'})"

    for i, c in enumerate(cases):
        p, u = patched[i], unpatched[i]
        g = groups.setdefault(c.group or c.kind, {
            "kind": c.kind, "cases": 0, "patched_aborts": 0, "patched_error_results": 0,
            "patched_parsed": 0, "unpatched_aborts": 0, "identical": 0})
        g["cases"] += 1
        unpatched_aborted = u.status != "exit:0"
        g["unpatched_aborts"] += unpatched_aborted
        if c.abort_class:
            k = classes[c.abort_class]
            k["cases"] += 1
            k["unpatched_aborts"] += unpatched_aborted
            if not unpatched_aborted:
                k["not_aborting"].append(c.name)
        if p.status != "exit:0":
            g["patched_aborts"] += 1
            failures.append(f"{c.name}: patched library ended with {p.status}")
            continue
        max_rss = max(max_rss, p.max_rss_kb)
        unpatched_max_rss = max(unpatched_max_rss, u.max_rss_kb)
        if p.max_rss_kb > MAX_RSS_KB:
            failures.append(f"{c.name}: patched case used {p.max_rss_kb} KB of memory")
        cols = [p.parsers[k] for k in COLUMNS[:3]]

        # Rules 1 and 2: no abort; error results through the API's channels.
        if any(col in ("inconsistent", "null") for col in cols):
            failures.append(f"{c.name}: patched parsers gave {cols}")
        if p.placebo == "dm-null":
            failures.append(f"{c.name}: display management query returned null after a header "
                            "that has the data")
        # Rule 4: added error texts are single lines without fault substrings.
        if p.bad_texts:
            failures.append(f"{c.name}: {p.bad_texts} added error texts break the rules")

        if c.kind == ERROR:
            ok = (all(col == "err" for col in cols) and p.parsers["bin-file"] in ("err", "empty")
                  and p.ffmpeg == "skip" and p.placebo == "skip")
            if ok:
                g["patched_error_results"] += 1
            else:
                failures.append(f"{c.name}: expected error results, got {p.parsers}, "
                                f"FFmpeg {p.ffmpeg}, libplacebo {p.placebo}")
        elif c.kind == NO_ABORT:
            if any(col.startswith("ok") for col in cols):
                g["patched_parsed"] += 1
            else:
                g["patched_error_results"] += 1
        elif c.kind == WRITES_FAIL:
            # Parses as upstream; every writer fails cleanly. In NAL form,
            # FFmpeg's conversion skips it at the write, and libplacebo gets
            # its metadata exactly as today.
            form = c.required_parse[0]
            ok = p.parsers[form] == "ok:4"
            if form == "hevc-nalu":
                ok = ok and p.ffmpeg == c.ffmpeg_expect and p.placebo == "meta"
            if ok:
                g["patched_parsed"] += 1
            else:
                failures.append(f"{c.name}: expected a parse as upstream with every writer "
                                f"failing, got {p.parsers}, FFmpeg {p.ffmpeg}, libplacebo "
                                f"{p.placebo}")
        elif c.kind == VALID:
            if unpatched_aborted:
                failures.append(f"{c.name}: unpatched library ended with {u.status}")
            if any(col.startswith("ok") for col in cols):
                g["patched_parsed"] += 1
            for col in c.required_parse:
                if not p.parsers[col].startswith("ok"):
                    failures.append(f"{c.name}: {col} did not parse ({p.parsers[col]})")

        # Rule 3: wherever unpatched 3.3.2 does not abort, the same results
        # and bytes; error texts may differ only where the patch's own check
        # fired first. Valid RPUs must match exactly.
        # A header that says display management data is present must never
        # come with a null display management result (rule 2).
        if p.header_rule:
            failures.append(f"{c.name}: {p.header_rule} headers say display management data "
                            "is present but that query returned null")
        if c.kind == HEADER_RULE:
            if unpatched_aborted or not u.header_rule or p.digest_results != u.digest_results:
                failures.append(f"{c.name}: expected unpatched 3.3.2 to give a header without "
                                f"its display management data ({u.status}, {u.header_rule}) and "
                                f"the patched header query to return null {dump_paths(i)}")
            else:
                g["patched_parsed"] += 1
                header_rule_cases += 1
            continue

        # Rule 3: where unpatched 3.3.2 does not abort, the same results and
        # bytes. Error texts may differ only where the patch's own check fired
        # first, and a header only where rule 2 turns it into null.
        if not unpatched_aborted:
            if p.digest == u.digest:
                g["identical"] += 1
            elif c.kind == VALID:
                failures.append(f"{c.name}: patched and unpatched results differ {dump_paths(i)}")
            elif p.digest_results != u.digest_results:
                failures.append(f"{c.name}: patched and unpatched results differ beyond error "
                                f"texts {dump_paths(i)}")
            elif not p.patch_texts and not u.header_rule:
                failures.append(f"{c.name}: an error text changed without the patch's check "
                                f"firing {dump_paths(i)}")
            else:
                changed_texts += bool(p.patch_texts)
                header_rule_cases += bool(u.header_rule)

    for cls, k in classes.items():
        if not k["unpatched_aborts"]:
            failures.append(f"abort class '{cls}': unpatched 3.3.2 aborted on none of its "
                            f"{k['cases']} entries")
    return {"cases": len(cases), "groups": groups, "classes": classes, "failures": failures,
            "patched_max_rss_kb": max_rss, "unpatched_max_rss_kb": unpatched_max_rss,
            "error_texts_changed_by_checks": changed_texts,
            "headers_nulled_by_rule_2": header_rule_cases,
            "unpatched_aborts": sum(g["unpatched_aborts"] for g in groups.values())}


def summary_markdown(report: dict) -> str:
    lines = ["## libdovi C API test", "",
             f"- Cases: {report['cases']}",
             f"- Patched library: {sum(g['patched_aborts'] for g in report['groups'].values())} "
             f"aborts; unpatched library: {report['unpatched_aborts']} aborts",
             f"- Cases where only an error text changed (the patch's own check fired first): "
             f"{report['error_texts_changed_by_checks']}",
             f"- Cases where a header query returned null under rule 2 (unpatched gave a header "
             f"saying display management data is present, without that data): "
             f"{report['headers_nulled_by_rule_2']}",
             f"- Peak resident memory of any case that did not abort: patched "
             f"{report['patched_max_rss_kb']} KB (limit {MAX_RSS_KB} KB), unpatched "
             f"{report['unpatched_max_rss_kb']} KB",
             f"- Failures: {len(report['failures'])}", "",
             "| Abort class (spec 5.13) | Entries | Unpatched 3.3.2 aborted on | Did not abort |",
             "| --- | --- | --- | --- |"]
    for cls, k in report["classes"].items():
        missing = ", ".join(k["not_aborting"][:6]) + (" ..." if len(k["not_aborting"]) > 6 else "")
        lines.append(f"| {cls} | {k['cases']} | {k['unpatched_aborts']} | {missing or 'none'} |")
    lines += ["", "| Group | Expectation | Cases | Patched aborts | Error results | Parsed | "
              "Identical to unpatched | Unpatched aborts |",
              "| --- | --- | --- | --- | --- | --- | --- | --- |"]
    for name, g in report["groups"].items():
        lines.append(f"| {name} | {g['kind']} | {g['cases']} | {g['patched_aborts']} | "
                     f"{g['patched_error_results']} | {g['patched_parsed']} | "
                     f"{g['identical']} | {g['unpatched_aborts']} |")
    if report["failures"]:
        lines += ["", "### Failures", ""] + [f"- {f}" for f in report["failures"][:50]]
    return "\n".join(lines) + "\n"
