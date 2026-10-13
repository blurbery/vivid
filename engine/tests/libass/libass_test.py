"""libass host test corpus and checks for Vivid's Lucid Engine.

`lucid.py test-libass` builds libass 0.17.5 for the build host several times
from the same pinned source (upstream, upstream with the symbol font patch
only, the series up to the upstream event cache, the whole series, and the
whole series with AddressSanitizer), links harness.c against each and runs
every scenario here through each build, one harness process per scenario.
This module writes the scenarios and judges the results. See
docs/cores/lucid-engine-build.md, "libass host tests".

Licence: ISC, like libass.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

MiB = 1 << 20
EVENT_CACHE_BUDGET = 32 * MiB       # EVENT_RENDER_CACHE_MAX_SIZE in the series

SYSTEM_FONTS = Path("/System/Library/Fonts")
SUPPLEMENTAL = SYSTEM_FONTS / "Supplemental"
FONT_FILES = {
    "times": SUPPLEMENTAL / "Times New Roman.ttf",
    "arial-unicode": SUPPLEMENTAL / "Arial Unicode.ttf",
}
# Families the corpus asks Core Text for, with a file that must exist.
FAMILIES = {
    "Arial": SUPPLEMENTAL / "Arial.ttf",
    "Times New Roman": SUPPLEMENTAL / "Times New Roman.ttf",
    "Georgia": SUPPLEMENTAL / "Georgia.ttf",
    "Verdana": SUPPLEMENTAL / "Verdana.ttf",
    "Courier New": SUPPLEMENTAL / "Courier New.ttf",
    "Impact": SUPPLEMENTAL / "Impact.ttf",
    "Hiragino Sans": SYSTEM_FONTS / "ヒラギノ角ゴシック W3.ttc",
    "Geeza Pro": SYSTEM_FONTS / "GeezaPro.ttc",
    "Arial Hebrew": SYSTEM_FONTS / "ArialHB.ttc",
    "Apple Color Emoji": SYSTEM_FONTS / "Apple Color Emoji.ttc",
    "Webdings": SUPPLEMENTAL / "Webdings.ttf",
    "Wingdings": SUPPLEMENTAL / "Wingdings.ttf",
    "Wingdings 2": SUPPLEMENTAL / "Wingdings 2.ttf",
    "Wingdings 3": SUPPLEMENTAL / "Wingdings 3.ttf",
    "Symbol": SYSTEM_FONTS / "Symbol.ttf",
}

# Builds, in the order lucid.py makes them: name -> number of series patches.
# The series is upstream's symbol font commit (0001), upstream's event cache
# pull request (0002) and Vivid's patch (0010).
SERIES_PREFIXES = ("0001-", "0002-", "0010-")
VARIANTS = {"upstream": 0, "symbol-font": 1, "event-cache": 2, "patched": 3, "patched-asan": 3}
PROBED = ("event-cache", "patched", "patched-asan")   # builds that have the cache
COUNTED = ("patched", "patched-asan")   # builds with patch 0010's font counters
# Where patch 0010 changes what the upstream event cache does: any scenario
# with a glyph that a fallback search could not provide (see unresolved()),
# the memory probes, and this one, the same text with different effects.
EVENT_CACHE_DELTAS = ("same-text-different-effects",)

HD, UHD = (1920, 1080), (3840, 2160)
FRAME = 42                                  # about 24 frames a second, in ms

THAI_KO_KAI, THAI_KHO_KHAI, DEVANAGARI_KA = "ก", "ข", "क"
UNASSIGNED = "͸"                       # no font has a glyph for it


# ------------------------------------------------------------------ scripts

STYLE_FORMAT = ("Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, "
                "BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, "
                "BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding")
EVENT_FORMAT = "Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text"


def style(name, font="Arial", size=56, primary="&H00FFFFFF", secondary="&H000000FF",
          outline="&H00000000", back="&H80000000", bold=0, italic=0, underline=0, strike=0,
          sx=100, sy=100, spacing=0, angle=0, border=1, outline_w=2, shadow=1, align=2,
          ml=40, mr=40, mv=40) -> str:
    return (f"Style: {name},{font},{size},{primary},{secondary},{outline},{back},{bold},{italic},"
            f"{underline},{strike},{sx},{sy},{spacing},{angle},{border},{outline_w},{shadow},"
            f"{align},{ml},{mr},{mv},1")


def ts(ms: int) -> str:
    cs = ms // 10
    return f"{cs // 360000}:{cs // 6000 % 60:02d}:{cs // 100 % 60:02d}.{cs % 100:02d}"


def event(start, end, sty, text, layer=0, ml=0, mr=0, mv=0, effect="") -> str:
    return f"Dialogue: {layer},{ts(start)},{ts(end)},{sty},,{ml},{mr},{mv},{effect},{text}"


def script(styles, events, wrap=0, scaled="yes") -> str:
    return "\n".join([
        "[Script Info]", "ScriptType: v4.00+", "PlayResX: 1920", "PlayResY: 1080",
        f"WrapStyle: {wrap}", f"ScaledBorderAndShadow: {scaled}", "YCbCr Matrix: None", "",
        "[V4+ Styles]", f"Format: {STYLE_FORMAT}", *styles, "",
        "[Events]", f"Format: {EVENT_FORMAT}", *events, ""])


BASE_STYLES = [
    style("Plain"),
    style("Box3", border=3, outline_w=4, shadow=0, outline="&H60101010"),
    style("Box4", border=4, outline_w=2, shadow=6, back="&H70101010"),
    style("Outlined", outline_w=4, shadow=3, outline="&H00202020", back="&H90000000"),
    style("Sign", font="Impact", size=72, align=5, outline_w=3, shadow=0),
    style("Top", font="Georgia", size=50, align=8, outline_w=2, shadow=2),
]

SRT_TEXT = r"{\i1}Hello{\i0} there, this is a\Nstatic SubRip line."


@dataclass
class Scenario:
    name: str
    group: str            # steady, dynamic, mixed, pixels, symbol, fallback, memory
    ass: str
    size: tuple = HD
    init: str = "coretext Arial -"
    setup: list = field(default_factory=list)      # commands after init
    commands: list = field(default_factory=list)   # after track; "render" lines etc.
    note: str = ""
    allowed_window: tuple | None = None   # (from, to) ms where missing glyphs may lag
    cleanup: list = field(default_factory=list)    # files to remove before a run
    baseline: str = ""    # pressure: the same scenario without the line under test


def frames(t0: int, count: int, step: int = FRAME) -> str:
    return f"render f {t0} {step} {count}"


def enc(s: str) -> str:
    return s.replace("%", "%25").replace(" ", "%20")


def steady_scenarios() -> list[Scenario]:
    one = {
        "srt-opaque-box": event(0, 60000, "Box3", SRT_TEXT),
        "srt-background-box": event(0, 60000, "Box4", SRT_TEXT),
        "vector-clip-sign": event(0, 60000, "Sign", r"{\pos(960,300)\clip(m 640 230 l 1280 230 "
                                  r"1280 330 960 360 640 330)}CLIPPED SIGN TEXT"),
        "inverse-vector-clip-sign": event(0, 60000, "Sign", r"{\pos(960,620)\iclip(m 900 570 l 1020 570 "
                                          r"1020 680 900 680)}INVERSE CLIP"),
        "outlined-line": event(0, 60000, "Outlined", r"{\blur1.5}An outlined static line\Nwith "
                               r"a soft shadow."),
        "rectangle-clip-sign": event(0, 60000, "Sign", r"{\an7\pos(80,80)\clip(80,80,700,150)}"
                                     "Rectangle clipped sign"),
        "drawing-sign": event(0, 60000, "Plain", r"{\an7\pos(1500,120)\p1\bord3\1c&H3080FF&}"
                              r"m 0 0 l 300 0 300 120 0 120{\p0}"),
        "plain-line": event(0, 60000, "Plain", "A plain static line without a box."),
    }
    out = []
    for size in (HD, UHD):
        tag = "1080p" if size == HD else "2160p"
        for name, ev in one.items():
            out.append(Scenario(f"{name}-{tag}", "steady", script(BASE_STYLES, [ev]), size,
                                commands=[frames(1000, 240)]))
        out.append(Scenario(f"sign-and-dialogue-{tag}", "steady",
                            script(BASE_STYLES, [one["vector-clip-sign"], one["srt-background-box"],
                                                 one["outlined-line"], one["srt-opaque-box"]]),
                            size, commands=[frames(1000, 240)]))
    return out


def dynamic_scenarios() -> list[Scenario]:
    run = [frames(0, 80, 40)]
    items = {
        "move": [event(0, 4000, "Plain", r"{\move(200,540,1700,540,500,2500)}Moving text")],
        "move-whole-event": [event(0, 4000, "Top", r"{\move(300,200,1500,800)}Diagonal")],
        "fade": [event(0, 3000, "Plain", r"{\fad(600,600)}Fading line")],
        "fade-complex": [event(0, 3200, "Plain",
                               r"{\fade(255,0,200,0,800,1600,2400)}Complex fade")],
        "transform": [event(0, 3200, "Plain",
                            r"{\an5\pos(960,540)\t(0,2000,\frz360\fscx150\1c&H00FF00&)}Turning")],
        "transform-accel-blur": [event(0, 3200, "Plain",
                                       r"{\t(500,2500,2,\blur6\bord8\fs90)}Blur grows")],
        "karaoke": [event(0, 3200, "Plain",
                          r"{\k40}Ka{\k40}ra{\kf80}o{\ko60}ke {\K50}line {\k30}end")],
        "animated-rect-clip": [event(0, 3200, "Plain", r"{\clip(0,0,200,1080)\t(0,2500,"
                                     r"\clip(0,0,1920,1080))}Wipe reveal across the screen")],
        "animated-inverse-clip": [event(0, 3200, "Sign", r"{\pos(960,540)\iclip(900,400,1000,700)"
                                        r"\t(0,2500,\iclip(400,400,1500,700))}Opening hole")],
        "animated-box4-colour": [event(0, 3200, "Box4",
                                       r"{\t(0,2500,\4c&H0000FF&\4a&H30&)}Box colour fades")],
        "animated-box3-colour": [event(0, 3200, "Box3",
                                       r"{\t(0,2500,\3c&H00C000&)}Opaque box colour")],
        "collision-shift": [
            event(0, 3200, "Plain", "First line at the bottom"),
            event(500, 2600, "Plain", "Second line pushes up"),
            event(1000, 2000, "Plain", "Third line"),
            event(1500, 3200, "Plain", "Fourth line takes a free slot"),
            event(700, 2900, "Top", "A top line"),
            event(900, 2200, "Top", "Another top line")],
        "appear-leave": [
            event(200, 900, "Plain", r"{\an7\pos(100,100)}Appears early"),
            event(400, 2000, "Plain", r"{\an9\pos(1820,100)}Stays a while"),
            event(1300, 1340, "Plain", r"{\an5\pos(960,540)}One frame"),
            event(1500, 3100, "Sign", "Late sign"),
            event(2500, 2900, "Top", "Brief top line")],
        "banner": [event(0, 3200, "Plain", "Banner text scrolls across", effect="Banner;6")],
        "scroll-up": [event(0, 3200, "Plain", "Scrolling up", effect="Scroll up;300;900;8")],
        "scroll-down": [event(0, 3200, "Plain", "Scrolling down", effect="Scroll down;200;700;6;1")],
        "move-beside-static-text": [
            event(0, 3200, "Plain", "A static line below"),
            event(0, 3200, "Top", r"{\move(100,300,1800,300)}Moving above it")],
        "same-text-one-moving": [
            event(0, 3200, "Plain", "Same words"),
            event(0, 3200, "Plain", r"{\move(200,300,1700,300)}Same words")],
    }
    return [Scenario(name, "dynamic", script(BASE_STYLES, evs), commands=list(run))
            for name, evs in items.items()]


def mixed_scenarios() -> list[Scenario]:
    run = [frames(0, 80, 40)]
    items = {
        "background-box-and-moving-sign": [
            event(0, 3200, "Box4", SRT_TEXT),
            event(0, 3200, "Sign", r"{\move(300,300,1600,300)}Moving sign")],
        "vector-clip-and-karaoke": [
            event(0, 3200, "Sign", r"{\pos(960,300)\clip(m 640 230 l 1280 230 1280 330 640 330)}"
                  "CLIPPED SIGN TEXT"),
            event(0, 3200, "Plain", r"{\k50}Sing {\kf80}along {\ko60}now")],
        "boxes-colliding": [
            event(0, 3200, "Box4", "First boxed line"),
            event(600, 2600, "Box4", "Second boxed line"),
            event(1200, 3200, "Box3", "An opaque box joins"),
            event(1800, 2400, "Box4", "Brief boxed line")],
        "opaque-box-and-fade": [
            event(0, 3200, "Box3", SRT_TEXT),
            event(0, 3200, "Top", r"{\fad(500,500)}Fading top line")],
        "inverse-clip-appearing": [
            event(0, 3200, "Sign", r"{\pos(960,620)\iclip(m 900 570 l 1020 570 1020 680 "
                  r"900 680)}INVERSE CLIP"),
            event(1000, 2000, "Box4", "A boxed line appears")],
    }
    return [Scenario(name, "mixed", script(BASE_STYLES, evs), commands=list(run))
            for name, evs in items.items()]


def pixel_scenarios() -> list[Scenario]:
    run = [frames(0, 30, 120), frames(3600, 30, 120)]
    styles = BASE_STYLES + [
        style("Bold", font="Verdana", size=48, bold=1, outline_w=1, shadow=2, align=1),
        style("Italic", font="Georgia", size=52, italic=1, underline=1, align=3),
        style("Strike", font="Courier New", size=44, strike=1, spacing=4, align=4),
        style("Wide", font="Times New Roman", size=60, sx=140, sy=80, angle=8, align=6),
        style("Narrow", font="Arial", size=64, sx=70, sy=120, align=7, outline_w=0, shadow=0),
        style("Vertical", font="@Hiragino Sans", size=56, align=9, mr=80),
        style("Japanese", font="Hiragino Sans", size=56, align=8),
        style("Arabic", font="Geeza Pro", size=60, align=3),
        style("Hebrew", font="Arial Hebrew", size=60, align=1),
        style("Emoji", font="Apple Color Emoji", size=60, align=5),
    ]
    items = {
        "styles": [
            event(0, 6000, "Bold", "Bold Verdana with a shadow"),
            event(0, 6000, "Italic", "Italic underlined Georgia"),
            event(0, 6000, "Strike", "Struck spaced Courier"),
            event(0, 6000, "Wide", "Wide, squashed and turned"),
            event(0, 6000, "Narrow", "Narrow and tall"),
            event(0, 6000, "Box3", "Opaque box"), event(0, 6000, "Box4", "Background box")],
        "override-tags": [
            event(0, 6000, "Plain", r"{\b1}bold{\b0} {\i1}italic{\i0} {\u1}under{\u0} "
                  r"{\s1}strike{\s0} {\fs80}big{\fs40}small{\r} {\fscx150}wide{\fscx100} "
                  r"{\fsp8}spaced{\fsp0}"),
            event(0, 6000, "Top", r"{\1c&H00FFFF&\3c&H800000&\bord4\shad3\4c&H404040&}Colours "
                  r"{\1a&H80&}half{\alpha&H00&} {\xbord6\ybord1}xy border {\xshad5\yshad-3}"
                  r"shadow {\be3}edge blur {\blur4}gaussian"),
            event(0, 6000, "Plain", r"{\an7\pos(60,300)\q2}No wrapping at all for this "
                  r"particularly long line of words that goes past the edge"),
            event(0, 6000, "Plain", r"{\an4\pos(60,700)\fnTimes New Roman\fe0}Font change "
                  r"{\fnCourier New}courier{\r}reset\hhard\Nnew line")],
        "clips-and-drawings": [
            event(0, 6000, "Sign", r"{\pos(500,300)\clip(2,m 600 400 b 900 100 1500 100 1800 "
                  r"400 l 1800 800 600 800)}Scaled vector clip"),
            event(0, 6000, "Sign", r"{\pos(1400,300)\iclip(1300,250,1500,350)}Rectangle hole"),
            event(0, 6000, "Plain", r"{\an7\pos(200,600)\p2\bord2\3c&H00FF00&}m 0 0 b 200 -200 "
                  r"400 -200 600 0 l 600 300 0 300{\p0}"),
            event(0, 6000, "Plain", r"{\an7\pos(1000,650)\p1\pbo-20\blur2\1c&HFF8000&}m 0 0 "
                  r"l 200 0 100 160{\p0} after the drawing")],
        "transforms-3d": [
            event(0, 6000, "Sign", r"{\pos(500,300)\frx40\fry20}Tilted sign"),
            event(0, 6000, "Sign", r"{\pos(1400,300)\org(1400,600)\frz25}Rotated round a point"),
            event(0, 6000, "Plain", r"{\an5\pos(960,700)\fax0.3\fay0.1}Sheared text")],
        "vertical-and-japanese": [
            event(0, 6000, "Vertical", "縦書きのテスト、「日本語」。"),
            event(0, 6000, "Japanese", "日本語の字幕です。ひらがなとカタカナ")],
        "arabic-and-hebrew": [
            event(0, 6000, "Arabic", "مرحبا بالعالم، هذا اختبار 123"),
            event(0, 6000, "Hebrew", "שלום עולם, זה מבחן 456"),
            event(0, 6000, "Plain", "Mixed: English עברית العربية 2026")],
        "emoji": [event(0, 6000, "Emoji", "Emoji 😀🎬🌏 and text"),
                  event(0, 6000, "Plain", "Plain text with emoji 🍿")],
        "wrapping": [
            event(0, 6000, "Plain", r"{\q0}Smart wrapping keeps the lines of this sentence about "
                  "even in length when it is too long for the screen"),
            event(0, 6000, "Top", r"{\q1}End of line wrapping puts as many words as fit on the "
                  "first line of this long sentence and the rest below"),
            event(0, 6000, "Plain", r"{\an5\pos(960,540)\q3}Lower line wider wrapping of a long "
                  "sentence that needs two or more lines")],
        "recurring-lines": [
            event(0, 1500, "Plain", "The same words again"),
            event(1500, 3000, "Plain", "The same words again"),
            event(3600, 5000, "Plain", r"{\fad(200,200)}The same words again"),
            event(500, 2500, "Top", "Shown twice at once"),
            event(500, 2500, "Top", "Shown twice at once", layer=1),
            event(4000, 6000, "Box4", "The same words again")],
        "same-text-different-effects": [
            event(0, 2000, "Plain", "Effect sharing"),
            event(2000, 4000, "Plain", "Effect sharing", effect="Banner;8"),
            event(4000, 6000, "Plain", "Effect sharing", effect="Scroll up;300;900;6"),
            event(500, 5500, "Top", "Effect sharing", effect="Unknown effect text")],
        "unresolved-glyph-core-text": [
            event(0, 6000, "Plain", f"Unassigned {UNASSIGNED} code point"),
            event(500, 1500, "Top", f"Recurring {UNASSIGNED}"),
            event(3600, 4800, "Top", f"Recurring {UNASSIGNED}")],
        "layers-and-collisions": [
            event(0, 6000, "Plain", "Layer zero line", layer=0),
            event(0, 6000, "Plain", "Layer one line", layer=1),
            event(1000, 5000, "Plain", "Second layer zero line", layer=0),
            event(3600, 6000, "Plain", r"{\pos(960,1000)}Positioned, no collision")],
    }
    out = [Scenario(name, "pixels", script(styles, evs), commands=list(run))
           for name, evs in items.items()]
    out.append(Scenario("styles-2160p", "pixels", script(styles, items["styles"]), UHD,
                        commands=list(run)))
    out.append(Scenario("wrap-style-2-unscaled-borders", "pixels",
                        script(styles, items["wrapping"] + items["styles"], wrap=2, scaled="no"),
                        commands=list(run)))
    return out


def symbol_scenarios() -> list[Scenario]:
    texts = ["Latin abc XYZ 123", "Привет мир", "Γειά σου", "漢字かな", "مرحبا"]
    out = []
    for font in ("Webdings", "Wingdings", "Wingdings 2", "Wingdings 3", "Symbol"):
        sty = [style("Sym", font=font, size=60, align=5)]
        evs = [event(0, 6000, "Sym", rf"{{\pos(960,{140 + 180 * i})}}{t}")
               for i, t in enumerate(texts)]
        out.append(Scenario(f"symbol-{font.lower().replace(' ', '-')}", "symbol",
                            script(sty, evs), commands=[frames(0, 20, 300)]))
    return out


def fallback_scenarios(work: Path) -> list[Scenario]:
    """Fonts from the harness's own provider, so fallback is deterministic:
    "Base" (Times New Roman, no Thai or Devanagari) for the text, and the
    default family "Fallback" with two members: one claiming Thai whose file
    cannot be opened, and Arial Unicode claiming only Devanagari but also
    covering Thai. Thai is then unresolved until a Devanagari character adds
    Arial Unicode as a fallback face."""
    missing = work / "no-such-font.ttf"
    late = work / "late-font.ttf"

    def setup(thai_path: Path) -> list[str]:
        return [f"provider-font Base {enc(str(FONT_FILES['times']))} 400 20-24F",
                f"provider-font Fallback {enc(str(thai_path))} 400 E00-E7F",
                f"provider-font Fallback {enc(str(FONT_FILES['arial-unicode']))} 400 900-97F"]

    sty = [style("Base", font="Base", size=64, outline_w=2, shadow=1),
           style("BaseTop", font="Base", size=56, align=8, outline_w=2, shadow=1),
           style("BaseBox", font="Base", size=56, align=5, border=4, outline_w=2, shadow=4)]
    k, kk, ka = THAI_KO_KAI, THAI_KHO_KHAI, DEVANAGARI_KA
    init = "none Fallback -"
    run = [frames(0, 100, 100)]
    out = [
        Scenario("unresolved-static", "fallback",
                 script(sty, [event(0, 10000, "Base", f"Static {k} line")]),
                 init=init, setup=setup(missing), commands=list(run)),
        Scenario("unresolved-static-box", "fallback",
                 script(sty, [event(0, 10000, "BaseBox", f"Boxed {k} sign")]),
                 init=init, setup=setup(missing), commands=list(run)),
        Scenario("face-added-later-in-the-same-render", "fallback",
                 script(sty, [event(0, 10000, "Base", f"Thai {k} then Devanagari {ka}")]),
                 init=init, setup=setup(missing), commands=list(run)),
        Scenario("face-added-by-a-later-event", "fallback",
                 script(sty, [event(0, 10000, "Base", f"Waiting {k} line"),
                              event(3000, 10000, "BaseTop", f"Adds a face {ka}")]),
                 init=init, setup=setup(missing), commands=list(run)),
        Scenario("face-added-by-an-earlier-event", "fallback",
                 script(sty, [event(3000, 10000, "BaseTop", f"Adds a face {ka}"),
                              event(0, 10000, "Base", f"Waiting {k} line")]),
                 init=init, setup=setup(missing), commands=list(run)),
        Scenario("face-added-to-a-boxed-sign", "fallback",
                 script(sty, [event(0, 10000, "BaseBox", f"Boxed {k} sign"),
                              event(3000, 10000, "BaseTop", f"Adds a face {ka}")]),
                 init=init, setup=setup(missing), commands=list(run)),
        Scenario("recurring-line-after-a-face", "fallback",
                 script(sty, [event(0, 2000, "Base", f"Recurring {k} line"),
                              event(2000, 4000, "BaseTop", f"Adds a face {ka}"),
                              event(4000, 6000, "Base", f"Recurring {k} line")]),
                 init=init, setup=setup(missing), commands=[frames(0, 70, 100)]),
        Scenario("recurring-line-without-a-face", "fallback",
                 script(sty, [event(0, 2000, "Base", f"Recurring {k} line"),
                              event(4000, 6000, "Base", f"Recurring {k} line")]),
                 init=init, setup=setup(missing), commands=[frames(0, 70, 100)]),
        Scenario("font-file-appears", "fallback",
                 script(sty, [event(0, 9000, "Base", f"Waiting {k} line"),
                              event(4000, 9000, "BaseTop", f"Another Thai {kk} line")]),
                 init=init, setup=setup(late),
                 commands=[frames(0, 20, 100),
                           f"copy {enc(str(FONT_FILES['arial-unicode']))} {enc(str(late))}",
                           frames(2000, 70, 100), f"remove {enc(str(late))}"],
                 allowed_window=(2000, 4000), cleanup=[late]),
        Scenario("font-file-appears-recurring-line", "fallback",
                 script(sty, [event(0, 9000, "Base", f"Recurring {k} line"),
                              event(3000, 9000, "BaseTop", f"Recurring {k} line")]),
                 init=init, setup=setup(late),
                 commands=[frames(0, 20, 100),
                           f"copy {enc(str(FONT_FILES['arial-unicode']))} {enc(str(late))}",
                           frames(2000, 70, 100), f"remove {enc(str(late))}"],
                 allowed_window=(2000, 3000), cleanup=[late]),
    ]
    return out


def memory_scenarios() -> list[Scenario]:
    n = 400
    sty = [style("Big", size=110, border=4, outline_w=3, shadow=8, back="&H60000000"),
           style("Plain")]
    evs = [event(i * 100, (i + 1) * 100, "Big", f"Distinct line {i}: a long static subtitle\\N"
                 f"with a second row number {i * 7 % 1000}") for i in range(n)]
    long_run = []
    for part in range(4):
        long_run += [f"render f {part * n * 25 + 10} 50 {n // 2}", f"heap part{part + 1}"]
    reset_evs = [event(0, 5000, "Plain", "Reset me"), event(0, 5000, "Big", "And me too"),
                 event(9000, 9500, "Plain", "Later")]
    reset = [frames(1000, 5), "probe rendered",
             "set-fonts coretext Arial -", "probe after-set-fonts", frames(1000, 3),
             "frame-size 1280 720", "probe after-frame-size", frames(1000, 3),
             "storage-size 1280 720", "probe after-storage-size", frames(1000, 3)]
    for name, cmd in (("shaper", "shaper 0"), ("line-spacing", "line-spacing 12"),
                      ("use-margins", "use-margins 1"), ("style-change", "style-size 0 70")):
        reset += [frames(1000, 3), "probe before-" + name, cmd, frames(6000, 1),
                  "probe after-" + name, frames(1000, 3)]
    return [Scenario("long-run-2160p", "memory", script(sty, evs), UHD, commands=long_run),
            Scenario("reset-and-settings", "memory", script(sty, reset_evs), commands=reset)]


PRESSURE_FRAMES = 120              # five seconds at 24 frames a second


def pressure_scenarios(work: Path) -> list[Scenario]:
    """Four full-frame translucent drawings at 2160p (just under the event
    render cache's 32 MiB budget on their own) and a large static line keep
    more than the budget in images on screen, so the cut at the start of
    every frame goes through the whole cache and drops every entry that no
    image holds. The line has glyphs that no font provides: an unassigned
    code point, the same beside a Devanagari letter whose fallback face is
    added on the first frame, and a CJK line whose style's family has a CJK
    font that cannot be opened, with the harness's own fonts, and an emoji
    line through Core Text. Each is compared with the drawings alone."""
    missing = work / "no-such-font.ttf"
    times = enc(str(FONT_FILES["times"]))
    own = [f"provider-font Base {times} 400 20-24F",
           f"provider-font Fallback {enc(str(missing))} 400 E00-E7F",
           f"provider-font Fallback {enc(str(FONT_FILES['arial-unicode']))} 400 900-97F",
           f"provider-font CJK {times} 400 20-24F",
           f"provider-font CJK {enc(str(missing))} 400 3000-30FF,4E00-9FFF"]
    sheets = [event(0, 60000, "Sheet", rf"{{\pos(0,0)\p1\1c{c}\1a&HE0&}}"
                    r"m 0 0 l 1920 0 1920 1080 0 1080{\p0}")
              for c in ("&H3060C0&", "&HC06030&", "&H30C060&", "&HA0A0A0&")]

    def styles(font: str) -> list[str]:
        return [style("Sheet", font=font, outline_w=0, shadow=0, align=7),
                style("Line", font=font, size=120, outline_w=2, shadow=1)]

    run = [frames(1000, PRESSURE_FRAMES)]
    base = "pressure-drawings-2160p"
    lines = {"pressure-unassigned-2160p": ("Base", f"Unassigned {UNASSIGNED} code point"),
             "pressure-face-added-2160p": ("Base", f"Unassigned {UNASSIGNED} and {DEVANAGARI_KA}"),
             "pressure-emoji-2160p": ("Arial", "Plain text with emoji 😀🎬🍿"),
             "pressure-cjk-2160p": ("CJK", "日本語の字幕が表示されない")}
    out = [Scenario(base, "pressure", script(styles("Base"), sheets), UHD,
                    init="none Fallback -", setup=list(own), commands=list(run))]
    for name, (font, text) in lines.items():
        core_text = font == "Arial"
        out.append(Scenario(name, "pressure",
                            script(styles(font), sheets + [event(0, 60000, "Line", text)]), UHD,
                            init="coretext Arial -" if core_text else "none Fallback -",
                            setup=[] if core_text else list(own), commands=list(run),
                            baseline=base))
    return out


def build_corpus(work: Path) -> list[Scenario]:
    missing = [f"{n}: {p}" for n, p in {**FONT_FILES, **FAMILIES}.items() if not p.exists()]
    if missing:
        raise RuntimeError("system fonts the corpus needs are missing: " + "; ".join(missing))
    return (steady_scenarios() + dynamic_scenarios() + mixed_scenarios() + pixel_scenarios()
            + symbol_scenarios() + fallback_scenarios(work) + memory_scenarios()
            + pressure_scenarios(work))


def write_inputs(s: Scenario, corpus: Path) -> Path:
    """The scenario's script and harness commands; returns the command file."""
    ass = corpus / f"{s.name}.ass"
    ass.write_text(s.ass, encoding="utf-8")
    lines = [f"init {s.size[0]} {s.size[1]} {s.init}", *s.setup, f"track {enc(str(ass))}",
             *s.commands]
    cmd = corpus / f"{s.name}.cmd"
    cmd.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return cmd


# ------------------------------------------------------------------ results

@dataclass
class Frame:
    t: int
    change: int
    composite: str
    images: str
    count: int
    attempts: int
    failures: int
    open_failures: int
    cache: int
    bad_types: int
    ns: int               # time ass_render_frame() took
    faces: int            # fallback faces added, from patch 0010's counter, or -1
    unresolved: int       # glyph lookups no face satisfied, from 0010's counter, or -1


def parse_output(text: str) -> dict:
    frames_, probes, heaps, done = [], {}, {}, False
    for line in text.splitlines():
        p = line.split()
        if not p:
            continue
        if p[0] == "frame":
            frames_.append(Frame(int(p[3]), int(p[4]), p[5], p[6], int(p[7]), int(p[8]),
                                 int(p[9]), int(p[10]), int(p[11]), int(p[12]), int(p[13]),
                                 int(p[14]), int(p[15])))
        elif p[0] == "probe":
            probes[p[1]] = int(p[2])
        elif p[0] == "heap":
            heaps[p[1]] = int(p[2])
        elif p[0] == "done":
            done = True
    return {"frames": frames_, "probes": probes, "heaps": heaps, "done": done}


class Verdict:
    def __init__(self):
        self.failures: list[str] = []
        self.groups: dict[str, dict] = {}
        self.notes: list[str] = []
        self.checks = 0

    def check(self, ok: bool, what: str) -> None:
        self.checks += 1
        if not ok:
            self.failures.append(what)

    def group(self, name: str) -> dict:
        return self.groups.setdefault(name, {"scenarios": 0, "frames": 0, "checks": 0})


def uses_background_box(ass: str) -> bool:
    boxed = set()
    for line in ass.splitlines():
        if line.startswith("Style: ") and line.split(",")[15] == "4":
            boxed.add(line[7:].split(",")[0])
        elif line.startswith("Dialogue: ") and line.split(",")[3] in boxed:
            return True
    return False


def unresolved(frames_) -> bool:
    """Whether a fallback search failed, leaving a glyph unresolved."""
    return any(f.failures or f.open_failures for f in frames_)


def evaluate(scenarios: list[Scenario], results: dict) -> dict:
    """results[variant][scenario name] -> parsed harness output."""
    v = Verdict()
    up, sym, ec, pa = (results[k] for k in ("upstream", "symbol-font", "event-cache", "patched"))
    asan = results.get("patched-asan")
    totals = {"upstream_changes_on_static": {}, "event_cache_gaps": [], "symbol_differences": {},
              "unresolved_scenarios": [],
              "mixed_value_differences": {}, "fallback": {}, "memory": {}, "pressure": {}}
    for s in scenarios:
        g = v.group(s.group)
        before = v.checks
        g["scenarios"] += 1
        P, U = pa[s.name]["frames"], up[s.name]["frames"]
        g["frames"] += len(P)
        name = f"{s.group}/{s.name}"
        for variant, res in results.items():
            v.check(res[s.name]["done"] and len(res[s.name]["frames"]) == len(P),
                    f"{name}: {variant} build ran every frame")
        if asan is not None:
            same = [(f.change, f.composite, f.images, f.attempts, f.cache, f.faces,
                     f.unresolved) for f in P] == \
                [(f.change, f.composite, f.images, f.attempts, f.cache, f.faces, f.unresolved)
                 for f in asan[s.name]["frames"]]
            v.check(same, f"{name}: the AddressSanitizer build gives the patched build's results")
        # Clones carry their image's type. libass leaves a background box's
        # type unset, so only scenarios without one are checked.
        if not uses_background_box(s.ass):
            for variant in ("patched", "patched-asan"):
                if variant in results:
                    v.check(not any(f.bad_types for f in results[variant][s.name]["frames"]),
                            f"{name}: every image of the {variant} build has a valid type")
        # No false negatives and no stale lists, in every scenario.
        for i in range(1, len(P)):
            if P[i].composite != P[i - 1].composite:
                v.check(P[i].change != 0, f"{name}: frame {i} ({P[i].t} ms) looks different "
                        "but the patched build reports no change")
            if P[i].change == 0:
                v.check(P[i].images == P[i - 1].images,
                        f"{name}: frame {i} reports no change but its images differ")
        # Apart from what patch 0010 deliberately changes, the patched build
        # behaves exactly as the upstream event cache (0001 and 0002) does.
        if unresolved(P):
            totals["unresolved_scenarios"].append(s.name)
        if s.name not in EVENT_CACHE_DELTAS and s.group != "memory" and not unresolved(P):
            E = ec[s.name]["frames"]
            diff = [i for i, (a, b) in enumerate(zip(P, E))
                    if (a.change, a.images) != (b.change, b.images)]
            v.check(not diff, f"{name}: change values or images differ from the upstream event "
                    f"cache build at frames {diff[:8]}")
        ref = sym if s.group == "symbol" else up
        R = ref[s.name]["frames"]
        lo, hi = s.allowed_window or (None, None)
        diffs = [i for i, (a, b) in enumerate(zip(P, R)) if a.composite != b.composite]
        bad = [i for i in diffs if lo is None or not (lo <= P[i].t <= hi)]
        v.check(not bad, f"{name}: composite differs from {'the symbol font build' if ref is sym else 'upstream'} "
                f"at frames {bad[:8]}")
        if s.group == "symbol":
            totals["symbol_differences"][s.name] = sum(
                1 for a, b in zip(R, U) if a.composite != b.composite)
        if s.group == "steady":
            ref_i = 1 if P[0].attempts else 0
            steady = all(f.change == 0 for f in P[ref_i + 1:]) and \
                all(f.images == P[ref_i].images for f in P[ref_i:])
            v.check(steady, f"{name}: every render after the first reports no change and "
                    "repeats the first images")
            totals["upstream_changes_on_static"][s.name] = sum(1 for f in U[1:] if f.change)
            if s.name.startswith(("srt-background-box", "vector-clip-sign", "inverse-vector")):
                v.check(all(f.change for f in U[1:]), f"{name}: upstream reports a change on every "
                        "frame (the behaviour the series removes)")
        if s.group == "dynamic":
            vals = [i for i, (a, b) in enumerate(zip(P, U)) if a.change != b.change]
            v.check(not vals, f"{name}: change values differ from upstream at frames {vals[:8]}")
            v.check(sum(1 for f in U[1:] if f.change) > 0, f"{name}: the scenario changes")
        if s.group == "mixed":
            totals["mixed_value_differences"][s.name] = sum(
                1 for a, b in zip(P, U) if a.change != b.change)
        if s.group == "fallback":
            evaluate_fallback(v, s, totals, P, U, ec[s.name]["frames"])
        if s.group == "pixels" and s.name == "unresolved-glyph-core-text":
            evaluate_core_text(v, s, totals, P, U)
        if s.group == "memory":
            evaluate_memory(v, s, totals, pa[s.name], ec[s.name], up[s.name])
        if s.group == "pressure":
            evaluate_pressure(v, s, totals, results)
        if s.group != "memory":
            gaps = [i for i, (a, b) in enumerate(zip(ec[s.name]["frames"], R))
                    if a.composite != b.composite]
            if gaps:
                totals["event_cache_gaps"].append(f"{s.name} ({len(gaps)} frames)")
        g["checks"] += v.checks - before
    return {"failures": v.failures, "checks": v.checks, "groups": v.groups, "totals": totals}


def evaluate_fallback(v: Verdict, s: Scenario, totals: dict, P, U, E) -> None:
    name = f"fallback/{s.name}"
    attempts_p = [f.attempts for f in P]
    attempts_u = [f.attempts for f in U]
    totals["fallback"][s.name] = {
        "patched_attempts": sum(attempts_p), "upstream_attempts": sum(attempts_u),
        "event_cache_attempts": sum(f.attempts for f in E),
        "patched_changes": sum(1 for f in P[1:] if f.change),
        "event_cache_differs_from_upstream": sum(
            1 for a, b in zip(E, U) if a.composite != b.composite)}
    if s.name.startswith("unresolved-static"):
        v.check(attempts_p[0] > 0 and not any(attempts_p[1:]),
                f"{name}: the patched build searches for the missing glyph only once")
        v.check(all(attempts_u), f"{name}: upstream searches on every frame")
        v.check(not any(f.change for f in P[1:]), f"{name}: no change after the first frame")
    if s.name == "face-added-later-in-the-same-render":
        v.check(U[0].composite != U[1].composite and all(f.composite == U[1].composite
                                                         for f in U[1:]),
                f"{name}: upstream shows the glyph from the second frame")
        v.check(sum(1 for f in P[1:] if f.change) == 1 and P[1].change,
                f"{name}: one extra change report, on the second frame, then none")
        v.check(any(a.composite != b.composite for a, b in zip(E, U)),
                f"{name}: the event cache alone keeps the glyph missing (gap reached)")
    if s.name.startswith("face-added-by") or s.name == "face-added-to-a-boxed-sign":
        appear = next(i for i, f in enumerate(U) if f.t >= 3000)
        v.check(not any(f.change for f in P[1:appear]),
                f"{name}: no change before the face is added")
        v.check(sum(1 for f in P[appear + 2:] if f.change) == 0,
                f"{name}: nothing more once no faces are being added")
        v.check(any(a.composite != b.composite for a, b in zip(E, U)),
                f"{name}: the event cache alone keeps the glyph missing (gap reached)")
    if s.name == "recurring-line-after-a-face":
        third = next(i for i, f in enumerate(U) if f.t >= 4000)
        v.check(any(a.composite != b.composite for a, b in zip(E[third:], U[third:])),
                f"{name}: the event cache alone reuses the first line's missing glyph")
    if s.name == "recurring-line-without-a-face":
        third = next(i for i, f in enumerate(U) if f.t >= 4000)
        v.check(P[third].attempts > 0 and not any(attempts_p[third + 1:]),
                f"{name}: the second event renders its own text once, without inheriting")
        v.check(E[third].attempts == 0,
                f"{name}: the event cache alone inherits the first event's render (gap reached)")
    if s.allowed_window:
        lo, hi = s.allowed_window
        lag = [f.t for f, u in zip(P, U) if f.composite != u.composite]
        totals["fallback"][s.name]["lagging_frames_ms"] = lag
        v.check(bool(lag) and min(lag) >= lo and max(lag) <= hi,
                f"{name}: missing glyphs lag upstream only from the font file's arrival to the "
                f"first face added after it ({lag[:5]}...)")


def evaluate_core_text(v: Verdict, s: Scenario, totals: dict, P, U) -> None:
    # Whether Core Text finds no font for the code point depends on the
    # system's fonts, so this only applies when upstream searched at all.
    name = f"pixels/{s.name}"
    totals["fallback"][s.name] = {"patched_attempts": sum(f.attempts for f in P),
                                  "upstream_attempts": sum(f.attempts for f in U)}
    if sum(f.attempts for f in U):
        v.check(sum(f.attempts for f in U) > sum(f.attempts for f in P) > 0,
                f"{name}: Core Text fallback runs, and less often in the patched build")


def evaluate_memory(v: Verdict, s: Scenario, totals: dict, pa: dict, ec: dict, up: dict) -> None:
    name = f"memory/{s.name}"
    if s.name.startswith("long-run"):
        peak = max(f.cache for f in pa["frames"])
        totals["memory"]["long_run_peak_bytes"] = peak
        totals["memory"]["long_run_heap"] = {k: {"patched": pa["heaps"][k],
                                                 "upstream": up["heaps"][k]} for k in pa["heaps"]}
        v.check(EVENT_CACHE_BUDGET * 3 // 4 < peak <= EVENT_CACHE_BUDGET + 8 * MiB,
                f"{name}: the event render cache reaches and keeps to its 32 MiB budget "
                f"(peak {peak})")
        extra = [pa["heaps"][k] - up["heaps"][k] for k in sorted(pa["heaps"])]
        totals["memory"]["long_run_extra_heap"] = extra
        v.check(all(x <= EVENT_CACHE_BUDGET + 16 * MiB for x in extra) and
                extra[-1] - extra[1] <= 8 * MiB,
                f"{name}: the patched build's extra memory stays bounded ({extra})")
    else:
        probes, eprobes = pa["probes"], ec["probes"]
        totals["memory"]["reset_probes"] = probes
        totals["memory"]["reset_probes_event_cache"] = eprobes
        v.check(probes.get("rendered", 0) > 0, f"{name}: the cache fills")
        for key, value in probes.items():
            if key.startswith("after-"):
                v.check(value == 0, f"{name}: the cache is empty {key} ({value} bytes)")
            elif key.startswith("before-"):
                v.check(value > 0, f"{name}: the cache refills {key}")
        totals["memory"]["event_cache_keeps_after"] = sorted(
            k for k, val in eprobes.items() if k.startswith("after-") and val)


def median_ms(frames_) -> float:
    ns = sorted(f.ns for f in frames_)
    return round((ns[len(ns) // 2] + ns[(len(ns) - 1) // 2]) / 2e6, 4) if ns else 0.0


def messages(f: Frame) -> int:
    return f.attempts + f.failures + f.open_failures


def evaluate_pressure(v: Verdict, s: Scenario, totals: dict, results: dict) -> None:
    """Frames are counted from 1 in these checks: frame 1 is the first render
    and frame 2 the second, which may render the line once more only when
    frame 1 added a fallback face. Timings are recorded, not checked: shared
    runners are too noisy for a 0.01 ms bound, so the checks count fallback
    searches and renders of the line instead."""
    name = f"pressure/{s.name}"
    P, E, U = (results[k][s.name]["frames"] for k in ("patched", "event-cache", "upstream"))
    info = {"cache_bytes": min(f.cache for f in P),
            "median_ms_after_frame_2": {k: median_ms(results[k][s.name]["frames"][2:])
                                        for k in ("patched", "event-cache", "upstream")}}
    totals["pressure"][s.name] = info
    if not s.baseline:
        v.check(not any(f.change for f in P[1:]), f"{name}: no change after the first frame")
        return
    v.check(all(f.cache > EVENT_CACHE_BUDGET for f in P),
            f"{name}: the images on screen keep the event render cache over its 32 MiB budget "
            f"on every frame (smallest {info['cache_bytes']} bytes)")
    reached = P[0].unresolved > 0 and unresolved(P[:1])
    after = P[2:]
    base = median_ms(results["patched"][s.baseline]["frames"][2:])
    info.update({
        "unresolved_glyphs_reached": reached,
        "patched_messages": [messages(f) for f in P[:3]] + [sum(messages(f) for f in after)],
        "patched_line_renders_after_frame_2": sum(1 for f in after if f.unresolved),
        "faces_added_on_frame_1": P[0].faces,
        "event_cache_messages_after_frame_2": sum(messages(f) for f in E[2:]),
        "upstream_messages_per_frame": round(sum(messages(f) for f in U) / len(U), 2),
        "baseline_median_ms_after_frame_2": base,
        "patched_difference_ms": round(info["median_ms_after_frame_2"]["patched"] - base, 4)})
    # Core Text decides whether the emoji have glyphs; the harness's own
    # fonts make the other lines unresolved on every system.
    if not s.init.startswith("coretext"):
        v.check(reached, f"{name}: the line has glyphs that no font provides")
        v.check(all(f.attempts for f in U), f"{name}: upstream searches on every frame")
    if "face-added" in s.name:
        v.check(P[0].faces > 0 and P[1].unresolved > 0,
                f"{name}: frame 1 adds a fallback face and frame 2 renders the line once more")
    v.check(not any(messages(f) for f in after),
            f"{name}: no fallback messages after frame 2 ({info['patched_messages']})")
    v.check(not any(f.unresolved for f in after),
            f"{name}: the line is not rendered again after frame 2")
    v.check(P[0].faces > 0 or not (messages(P[1]) or P[1].unresolved or P[1].change),
            f"{name}: frame 2 searches, renders the line or reports a change only when frame 1 "
            "added a fallback face")
    v.check(not any(f.change for f in after), f"{name}: no change after frame 2")


def summary_markdown(scenarios: list[Scenario], verdict: dict, results: dict) -> str:
    frames_ = sum(len(r["frames"]) for res in results.values() for r in res.values())
    lines = ["## libass host tests", "",
             f"{len(scenarios)} scenarios through {len(results)} builds ({frames_} frames), "
             f"{verdict['checks']} checks, {len(verdict['failures'])} failed.", "",
             "| Group | Scenarios | Frames per build | Checks |", "| --- | --- | --- | --- |"]
    for name, g in verdict["groups"].items():
        lines.append(f"| {name} | {g['scenarios']} | {g['frames']} | {g['checks']} |")
    t = verdict["totals"]
    lines += ["", "Upstream change reports after the first frame on static output (patched: 0):",
              ", ".join(f"{k} {n}" for k, n in t["upstream_changes_on_static"].items()), "",
              "Fallback searches (patched / upstream / upstream event cache alone):",
              ", ".join(f"{k} {x['patched_attempts']}/{x['upstream_attempts']}/"
                        f"{x.get('event_cache_attempts', '-')}" for k, x in t["fallback"].items()),
              "", "Scenarios with glyphs a fallback search could not provide: "
              + ", ".join(t["unresolved_scenarios"]),
              "", "Upstream event cache alone (patches 0001 and 0002) differs from upstream "
              "(from the symbol font build, for symbol fonts) in: "
              + (", ".join(t["event_cache_gaps"]) or "nothing"), "",
              "Symbol font frames that differ from upstream because of patch 0001: "
              + ", ".join(f"{k} {n}" for k, n in t["symbol_differences"].items()), ""]
    m = t["memory"]
    if m:
        lines += [f"Event render cache peak over the long run: {m.get('long_run_peak_bytes')} "
                  f"bytes; extra heap over upstream at each checkpoint: "
                  f"{m.get('long_run_extra_heap')}. Upstream event cache alone keeps entries "
                  f"after: {', '.join(m.get('event_cache_keeps_after', [])) or 'nothing'}.", ""]
    if t["pressure"]:
        lines += ["Over the event render cache's budget (patched build; median ms per frame after "
                  "frame 2 for patched / event cache alone / upstream; fallback messages on "
                  "frames 1, 2, 3 and after):",
                  ", ".join(f"{k} {x['median_ms_after_frame_2']['patched']}/"
                            f"{x['median_ms_after_frame_2']['event-cache']}/"
                            f"{x['median_ms_after_frame_2']['upstream']}"
                            + (f" messages {x['patched_messages']}" if "patched_messages" in x
                               else "") for k, x in t["pressure"].items()), ""]
    if verdict["failures"]:
        lines += ["Failures:", ""] + [f"- {f}" for f in verdict["failures"][:40]] + [""]
    return "\n".join(lines)


def write_report(path: Path, scenarios, verdict, results) -> None:
    data = {"verdict": verdict,
            "scenarios": [{"name": s.name, "group": s.group, "size": s.size} for s in scenarios],
            "frames": {var: {n: [f.__dict__ for f in r["frames"]] for n, r in res.items()}
                       for var, res in results.items()}}
    path.write_text(json.dumps(data, indent=1, default=str))
