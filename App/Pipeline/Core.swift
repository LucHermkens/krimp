import Foundation
import KrimpCore

/// Thin Swift wrapper around the Rust `krimp_core` C ABI.
enum Core {
    struct Error: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Formats encoded by the Rust core (TIFF and SVG output are handled elsewhere).
    enum Codec: Sendable {
        case jpeg, png, webp, gif, avif

        var raw: KrimpFormat {
            switch self {
            case .jpeg: KRIMP_JPEG
            case .png: KRIMP_PNG
            case .webp: KRIMP_WEBP
            case .gif: KRIMP_GIF
            case .avif: KRIMP_AVIF
            }
        }
    }

    struct Features: OptionSet, Sendable {
        let rawValue: UInt32
        static let avif = Features(rawValue: UInt32(KRIMP_FEATURE_AVIF))
        static let svgMinify = Features(rawValue: UInt32(KRIMP_FEATURE_SVG_MIN))
    }

    static let features = Features(rawValue: krimp_available_features())

    /// oxvg jobs that run when minifying SVG.
    static let minifyJobs: [String] = String(cString: krimp_svg_minify_jobs())
        .split(separator: ",").map(String.init)

    /// Encodes 8-bit sRGB RGBA with straight alpha and a `width * 4` stride.
    static func encode(rgba: Data, width: Int, height: Int, codec: Codec, quality: Int, progressive: Bool,
                       maxEffort: Bool = false) throws -> Data {
        precondition(rgba.count == width * height * 4)
        let options = KrimpOptions(format: codec.raw, quality: UInt8(clamping: quality), progressive: progressive,
                                   max_effort: maxEffort)
        return try output { out in
            rgba.withUnsafeBytes { raw in
                krimp_encode(raw.baseAddress!.assumingMemoryBound(to: UInt8.self), UInt32(width), UInt32(height), options, out)
            }
        }
    }

    /// Lossless oxipng pass over existing PNG bytes; pixels stay bit-identical.
    /// `maxEffort` uses Zopfli: a few percent smaller, many times slower.
    static func optimizePNG(_ png: Data, maxEffort: Bool = false) throws -> Data {
        try output { out in png.withBytes { krimp_optimize_png($0, $1, maxEffort, out) } }
    }

    /// IJG-equivalent quality from the luma quantisation table, or nil for non-standard tables.
    static func estimateJPEGQuality(_ jpeg: Data) -> Int? {
        let q = jpeg.withBytes { krimp_jpeg_estimate_quality($0, $1) }
        return q < 0 ? nil : Int(q)
    }

    /// Intrinsic size: width/height, else the viewBox.
    static func svgSize(_ svg: Data) throws -> CGSize {
        var width: Float = 0
        var height: Float = 0
        try check(svg.withBytes { krimp_svg_size($0, $1, &width, &height) })
        return CGSize(width: CGFloat(width), height: CGFloat(height))
    }

    /// Renders at exactly `width`×`height` into straight-alpha sRGB RGBA.
    static func renderSVG(_ svg: Data, width: Int, height: Int) throws -> Data {
        try output { out in svg.withBytes { krimp_svg_render($0, $1, UInt32(width), UInt32(height), out) } }
    }

    /// SVG → SVG. Zero width/height keeps the current size.
    static func rewriteSVG(_ svg: Data, width: Int = 0, height: Int = 0, minify: Bool) throws -> Data {
        try output { out in
            svg.withBytes { krimp_svg_rewrite($0, $1, UInt32(width), UInt32(height), minify, out) }
        }
    }

    /// Renders both at `size` px on the long edge and compares pixels.
    static func compareSVG(_ a: Data, _ b: Data, size: Int = 512) throws -> (max: Int, mean: Double) {
        var maxDiff: UInt8 = 0
        var meanDiff: Float = 0
        try check(a.withBytes { pa, la in
            b.withBytes { pb, lb in krimp_svg_compare(pa, la, pb, lb, UInt32(size), &maxDiff, &meanDiff) }
        })
        return (Int(maxDiff), Double(meanDiff))
    }

    // MARK: - Helpers

    private static func check(_ status: Int32) throws {
        guard status == 0 else { throw Error(message: String(cString: krimp_last_error())) }
    }

    /// Calls `body` with an out-buffer and hands its bytes to `Data` without copying.
    private static func output(_ body: (UnsafeMutablePointer<KrimpBuffer>) -> Int32) throws -> Data {
        var buffer = KrimpBuffer(ptr: nil, len: 0)
        try check(body(&buffer))
        guard let ptr = buffer.ptr else { return Data() }
        return Data(bytesNoCopy: ptr, count: buffer.len, deallocator: .custom { ptr, len in
            krimp_buffer_free(KrimpBuffer(ptr: ptr.assumingMemoryBound(to: UInt8.self), len: len))
        })
    }
}

private extension Data {
    func withBytes<R>(_ body: (UnsafePointer<UInt8>, Int) -> R) -> R {
        withUnsafeBytes { raw in
            // Empty Data may have no base address; hand Rust a valid dangling pointer instead.
            let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) ?? UnsafePointer(bitPattern: 1)!
            return body(base, raw.count)
        }
    }
}
