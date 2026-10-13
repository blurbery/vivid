Vivid: Source Licence and Third-Party Libraries
===============================================

This overview records source provenance and dependency information for Vivid.
Settings > About > Open Source Licences lists every bundled third-party
component; each opens on its own page with its notice and full licence text.
A licence text that Vivid or several components use word for word (Apache
2.0, GPL 3.0 and LGPL 2.1) is stored once and listed under Licence texts;
the notices of the components that use it mark where it applies.
THIRD_PARTY_NOTICES.md in the source revision for this build lists every
component, version and source.

Vivid: GPL-3.0-only with the Apple distribution
permission, copyright 2026 blurbery and the respective contributors.
You may copy, modify and redistribute covered code under GPLv3. There is
no warranty except as required by applicable law. The full GPLv3 text and
Apple permission are included in this screen. Earlier Apache-2.0 grants
remain valid; their original licence text is also retained here.

Vivid attribution: GPLv3 section 7 additional terms

Vivid is developed and maintained by blurbery.

These terms accompany GPL-3.0-only under sections 7(b) and 7(c), effective for the licensing revision containing this notice. They apply only to copyrightable Vivid material for which blurbery holds copyright or has express authority to impose these terms. They do not assert ownership of third-party components or other contributors' work, or impose these terms on that work without the necessary authority.

Attribution and origin

Under section 7(b), when conveying covered material or a modified version containing it, preserve the following author attribution in that material's source notices:

This software includes material from Vivid, developed by blurbery.

This attribution refers only to the covered Vivid material, not to the whole of a recipient's project or independently authored additions. Its formatting and location within the source notices may change provided the attribution remains readable and associated with the covered material. No logo, promotional link, advertising credit or particular user-interface placement is required.

Under section 7(c), do not misrepresent the origin of the covered material. Modified versions must be marked in a reasonable manner as different from the original Vivid material. Recipients may use their own project names, identify their own maintainers and describe their changes. No prescribed fork name or exact modification statement is required. Attribution does not imply that blurbery maintains or endorses a derivative.

Licence and existing notices

These are attribution and origin conditions, not an additional permission. Removing an additional permission, such as the Apple distribution permission, does not by itself remove these conditions. Preserve notices referring to these terms as required by GPLv3 sections 4 and 5. These terms impose no conditions on private use or private modification beyond GPLv3 and do not restrict lawful modification, redistribution or commercial use.

The standard GPLv3 licence text (LICENSE) and Apple distribution permission (LICENSE-APPLE-EXCEPTION) remain unchanged. These terms do not retroactively change earlier grants, including earlier GPL or Apache-2.0 grants, or restrict independent reuse rights under third-party licences. Preserve applicable third-party notices; see Third-party libraries (THIRD_PARTY_NOTICES.md).

The separate brand policy (TRADEMARK.md) governs Vivid's name and logo. Factual attribution is distinct from adopting Vivid as another project's branding.

Paths in the attribution terms refer to the corresponding source revision
provided with this build.

Corresponding source and build instructions:
The first row of Open Source Licences, "Source for this build", gives
the exact source commit this build was made from and its GitHub link. That
revision contains the complete source, project specs, build instructions
and THIRD_PARTY_NOTICES.md. Lucid Engine's build pipeline and Vivid's
engine patches are at the pipeline link under Lucid media engine below.
Vivid's repository is https://github.com/blurbery/vivid
The Apple permission preserves source disclosure; it does not allow
closed-source covered derivatives. Apple system frameworks retain Apple's
terms.

Lucid media engine (iOS and tvOS)
  Package: https://github.com/blurbery/lucid-engine/tree/11d60dc20a28e946677eb15ff832e7135603e92b
  Lucid Engine 0.1.0-interim.1, product LucidEngine. Its NOTICE lists
  every library with its version, upstream commit and licence, and its
  LICENSES folder holds their texts. Package.swift records every binary
  URL and SHA-256 checksum.
  Vivid's engine pipeline built mpv 0.41.0, FFmpeg 8.0.1, libass, dav1d
  and libdovi from upstream source with Vivid's engine patches.
  Pipeline and patches:
  https://github.com/blurbery/vivid/tree/10faa2a8b45d683380e8e452638be2d9c4c8a3cd/engine
  mpv is built with -Dgpl=false and FFmpeg without --enable-gpl or
  --enable-version3, so both are LGPL-2.1-or-later as built. FFmpeg uses
  Apple's Secure Transport for HTTPS; there is no OpenSSL. Vivid's own
  engine patches are licensed under LGPL-2.1-or-later, except the libdovi
  patch, which is MIT. The other libraries listed in THIRD_PARTY_NOTICES.md
  are interim prebuilt binaries until a later Lucid Engine release builds
  them from source. All of them are static libraries linked into the app
  executable.

  This software is based in part on the work of the Independent JPEG Group.

  Portions of this software are copyright (c) 2022 The FreeType Project
  (www.freetype.org). All rights reserved.

ThumbHash decoder
  Revision: a652ce6ed691242f459f468f0a8756cda3b90a82
  License: MIT
  Source: https://github.com/evanw/thumbhash/tree/a652ce6ed691242f459f468f0a8756cda3b90a82
  Vivid includes an adapted copy of the reference Swift decode path with input
  validation, cross-platform image creation, and a bounded asynchronous cache.

Apple tvOS media catalog sample
------------------------------

The tvOS movie and series detail presentation uses the fold-snapping
implementation and material-gradient pattern from Apple's 2024 media catalog sample.
Source: https://developer.apple.com/documentation/swiftui/creating-a-tvos-media-catalog-app-in-swiftui

Copyright © 2024 Apple Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

CollectionHStack (tvOS Home rows)
  Revision: 15baaaa759a0e252addae08431c79a49a25e4afc
  Source: https://github.com/LePips/CollectionHStack/tree/15baaaa759a0e252addae08431c79a49a25e4afc
  MIT, bundled in CollectionHStack-MIT.txt.

DifferenceKit (CollectionHStack dependency)
  Version: 1.3.0, revision 073b9671ce2b9b5b96398611427a1f929927e428
  Source: https://github.com/ra1028/DifferenceKit/tree/073b9671ce2b9b5b96398611427a1f929927e428
  Apache 2.0, bundled in DifferenceKit-Apache-2.0.txt.
