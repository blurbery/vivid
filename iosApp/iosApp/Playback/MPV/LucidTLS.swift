// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
#if (os(iOS) || os(tvOS))
import Libmpv

/// HTTPS certificate checks for streams Lucid reads itself.
///
/// mpv leaves `tls-verify` off by default. Lucid Engine's LGPL FFmpeg reads
/// HTTPS through Apple's Secure Transport, which checks certificates against
/// the system trust store. An FFmpeg built with OpenSSL has no trust store on
/// Apple platforms, so turning checks on there would refuse every HTTPS
/// stream. Checks are therefore on only when the linked FFmpeg was built with
/// Secure Transport.
enum LucidTLS {
    /// Whether the linked FFmpeg reads HTTPS through Secure Transport.
    static let verifiesCertificates: Bool = {
        guard let configuration = lucidAVFormatConfiguration() else { return false }
        return String(cString: configuration).contains("--enable-securetransport")
    }()

    /// Turns on certificate checks before `mpv_initialize` when the linked
    /// FFmpeg can check against the system trust store. Returns 0 without
    /// changing anything otherwise.
    @discardableResult
    static func apply(to mpv: OpaquePointer) -> Int32 {
        guard verifiesCertificates else { return 0 }
        return mpv_set_option_string(mpv, "tls-verify", "yes")
    }
}

/// FFmpeg's `const char *avformat_configuration(void)`, the configure flags
/// libavformat was built with. `import Libavformat` can't be used: the
/// packaged Libavutil module includes `hwcontext_amf.h`, which needs AMD's
/// AMF SDK headers, so the module fails to build. A function with no
/// arguments that returns a pointer is called the same way from Swift and C
/// on arm64 and x86_64, so this declaration links straight to FFmpeg's.
@_silgen_name("avformat_configuration")
private func lucidAVFormatConfiguration() -> UnsafePointer<CChar>?
#endif
