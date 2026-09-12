Vivid — Third-Party Libraries
============================

This Vivid build includes the components listed below. Their complete license
texts are bundled beside this file and are available from Settings > About >
Open Source Licences.

Vivid and VividKit as a whole: GPL-3.0-only with the Apple distribution
permission, copyright 2026 blurbery and the respective contributors.
You may copy, modify and redistribute covered code under GPLv3. There is
no warranty except as required by applicable law. The full GPLv3 text and
Apple permission are included in this screen. Earlier Apache-2.0 grants
remain valid; their original licence text is also retained here.

Corresponding source and build instructions:
https://github.com/blurbery/vivid
Each binary release must identify its exact public source revision and
provide matching source and dependency rebuild materials. The Apple
permission preserves source disclosure; it does not allow closed-source
covered derivatives. Apple system frameworks retain Apple's terms.

FFmpegBuild and embedded media frameworks
  Revision: 421e13be7061de67d91b85ac34a6b22a002b164f (release 3.0.0)
  Source and rebuild script: https://github.com/superuser404notfound/FFmpegBuild/tree/421e13be7061de67d91b85ac34a6b22a002b164f

  Components built by that revision:
  - FFmpeg n8.1.2, currently 38b88335f99e76ed89ff3c93f877fdefce736c13:
    LGPL-2.1-or-later
  - dav1d 1.5.4, currently 54706fc6bc0cdecab7e9593974a4039cc038fca7:
    BSD-2-Clause
  - zimg release-3.0.6, currently
    f819b14e8f39d1282400b0d9543e8ef73c1b2bbd: WTFPL-2.0
  - libzvbi v0.2.45, currently
    d3a5ee9f2b047bf16cd1ee5ccf6ec05ee75409d0: LGPL-2.0-or-later,
    conveyed under LGPL-2.1;
    src/ure.c retains its MIT notice

  The exact build is configured without --enable-gpl, --enable-version3, or
  nonfree components. FFmpegBuild removes the three GPL libzvbi source files
  before compilation and publishes the replacement stubs and patches in its
  build.sh. The app embeds these nine libraries as separate dynamic
  frameworks: AetherLibavcodec, AetherLibavformat, AetherLibavutil,
  AetherLibswresample, AetherLibswscale, AetherLibavfilter, AetherLibdav1d,
  AetherLibzimg, and AetherLibzvbi.

  "Currently" records the tags' dereferenced values observed on 2026-09-04.
  FFmpegBuild's script records tag names rather than immutable upstream
  commit IDs; the dereferenced commits recorded here pin the exact sources if
  those tags ever move.

libass subtitle rendering and font dependencies
  Binary source: https://github.com/kingslay/FFmpegKit/tree/c32be9bfb628042737ad3ef622e930c5c7b15954/Sources
  Only libass, libfreetype, libfribidi and libharfbuzz frameworks are included.
  The FFmpegKit playback target, mpv, and GPL media libraries are not linked.
  libass 0.17.1: ISC; https://github.com/libass/libass/tree/0.17.1
  FreeType 2.13.2: FreeType License; https://github.com/freetype/freetype/tree/VER-2-13-2
  FriBidi 1.0.12: LGPL-2.1-or-later; https://github.com/fribidi/fribidi/tree/v1.0.12
  HarfBuzz 5.3.1: MIT; https://github.com/harfbuzz/harfbuzz/tree/5.3.1
  The font and subtitle frameworks are static, separately replaceable SwiftPM
  binary targets. Their upstream licenses remain unchanged. FreeType notice:
  Portions of this software are copyright © 2023 The FreeType Project
  (www.freetype.org). All rights reserved.

ThumbHash decoder
  Revision: a652ce6ed691242f459f468f0a8756cda3b90a82
  License: MIT
  Source: https://github.com/evanw/thumbhash/tree/a652ce6ed691242f459f468f0a8756cda3b90a82
  Vivid includes an adapted copy of the reference Swift decode path with input
  validation, cross-platform image creation, and a bounded asynchronous cache.

Apple tvOS media catalog sample
------------------------------

The experimental tvOS movie and series detail presentation uses the fold-snapping
implementation and material-gradient pattern from Apple's 2024 media catalog sample.
Source: https://developer.apple.com/documentation/swiftui/creating-a-tvos-media-catalog-app-in-swiftui

Copyright © 2024 Apple Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.


Source availability
-------------------

The links above identify the exact source and rebuild inputs for this build,
including each component's rebuild script and patches at the pinned revision.
They are this build's corresponding-source pointer; keep them matched to the
revisions each release actually resolves.

AetherEngine (tvOS playback)
  Upstream 6.80.0: 89ef0c347a17180739d8ca7a1a1cfbb163135271
  Source: https://github.com/superuser404notfound/AetherEngine/tree/89ef0c347a17180739d8ca7a1a1cfbb163135271
  Local source and integration changes: https://github.com/blurbery/vivid/tree/24f992e24346b17f123c7a80d4360cb91e486869/AetherEngine
  LGPL-3.0 with the bundled Apple Store / DRM Exception.
  The local package retains Vivid's FFmpegBuild revision above. It adds audio
  ordinal selection inside the existing probe and integration type aliases.
  Build the tvOS app using iosApp/project.yml and XcodeGen; replacing this local
  source package and rebuilding replaces the linked engine.

LibDovi (tvOS playback)
  Version: 2.1.0, dolby_vision 3.4.0
  Source and rebuild script: https://github.com/superuser404notfound/LibDovi/tree/2.1.0
  Licence: MIT, bundled separately.
