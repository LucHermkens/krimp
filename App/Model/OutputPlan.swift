import Foundation

/// What to do with one item, resolved from the inspector settings and the source.
struct OutputPlan: Sendable, Equatable {
    var format: ImageFormat
    /// 1–100; 100 = lossless where the format supports it.
    var quality: Int
    var progressive: Bool
    /// SVG output only.
    var minify: Bool
    /// PNG only: Zopfli instead of libdeflate.
    var maxEffort = false

    /// The quality used for JPEG re-encodes when the source quality can't be estimated.
    static let fallbackJPEGQuality = 95

    /// "Same as original": keep output formats, otherwise PNG for images with alpha, JPEG without.
    static func sameFormat(for source: SourceInfo, hasAlpha: Bool) -> ImageFormat {
        source.outputFormat ?? (hasAlpha ? .png : .jpeg)
    }

    /// The badge before processing, e.g. "HEIC → JPEG".
    static func previewFormat(for source: SourceInfo, options: ProcessingOptions) -> ImageFormat? {
        if options.formatEnabled && options.format != .same {
            return ImageFormat(rawValue: options.format.rawValue)
        }
        return sameFormat(for: source, hasAlpha: source.mayHaveAlpha)
    }

    /// `sourceData` is needed for JPEG quality estimation and WebP lossless detection.
    static func resolve(source: SourceInfo, options: ProcessingOptions, hasAlpha: Bool, sourceData: Data?) throws -> OutputPlan {
        let same = sameFormat(for: source, hasAlpha: hasAlpha)

        if options.formatEnabled {
            let format = options.format == .same ? same : ImageFormat(rawValue: options.format.rawValue)!
            if format == .svg && source.kind != .svg { throw ItemIssue.skipped("Can't convert raster to SVG") }
            return OutputPlan(format: format, quality: format.usesQuality ? options.quality : 100,
                              progressive: options.progressive, minify: format == .svg,
                              maxEffort: format == .png && options.pngMaxEffort)
        }

        // Format card off: keep format and quality.
        let quality: Int
        switch same {
        case .jpeg:
            if source.outputFormat == .jpeg, let data = sourceData, let estimate = Core.estimateJPEGQuality(data) {
                // Never q100: it bloats files, often past the original.
                quality = min(max(estimate, 50), 99)
            } else {
                quality = fallbackJPEGQuality
            }
        case .webp:
            quality = sourceData.map(Decode.isLosslessWebP) == true ? 100 : 95
        case .avif:
            quality = 95
        case .png, .gif, .tiff, .svg:
            quality = 100
        }
        return OutputPlan(format: same, quality: quality, progressive: true, minify: false)
    }
}

/// Outcomes that aren't plain success or failure.
enum ItemIssue: LocalizedError, Equatable {
    case skipped(String)
    case alreadyOptimal
    case unsupported

    var errorDescription: String? {
        switch self {
        case .skipped(let reason): "Skipped: \(reason)"
        case .alreadyOptimal: "Already optimal"
        case .unsupported: "Unsupported"
        }
    }
}
