import Foundation
import KrimpCore
import os

/// The result of processing one item.
struct ItemResult: Sendable, Equatable {
    enum Outcome: Sendable, Equatable {
        case written(URL)
        case alreadyOptimal
        case skipped(String)
        case unsupported
        case failed(String)
    }

    var outcome: Outcome
    var format: ImageFormat?
    var outputSize: Int64?
    var outputWidth: Int?
    var outputHeight: Int?
}

/// Encoded output for one item, before it's written anywhere.
struct EncodedOutput: Sendable {
    var data: Data
    var plan: OutputPlan
    var width: Int
    var height: Int
    /// Dimensions differ from the source.
    var resized: Bool
}

enum Pipeline {
    static let log = Logger(subsystem: "io.github.luchermkens.krimp", category: "pipeline")

    /// Safety net for SVG minification: renders must match within these limits.
    static let svgMaxDiff = Int(KRIMP_SVG_MAX_DIFF)
    static let svgMeanDiff = Double(KRIMP_SVG_MEAN_DIFF)

    /// Decode → normalise → resize → encode, without touching the file system beyond reading.
    static func encode(_ source: SourceInfo, options: ProcessingOptions) throws -> EncodedOutput {
        let data = try Data(contentsOf: source.url, options: .mappedIfSafe)
        let target = options.resizeEnabled
            ? Resize.targetSize(width: source.pixelWidth, height: source.pixelHeight, mode: options.resizeMode,
                                value: options.resizeValue, allowUpscale: source.kind == .svg)
            : (width: source.pixelWidth, height: source.pixelHeight)
        let resized = target.width != source.pixelWidth || target.height != source.pixelHeight

        switch source.kind {
        case .svg:
            let plan = try OutputPlan.resolve(source: source, options: options, hasAlpha: true, sourceData: data)
            if plan.format == .svg {
                var output = data
                if plan.minify {
                    // Compare before resizing, so rounding the new size can't trip the safety net.
                    let minified = try Core.rewriteSVG(data, minify: true)
                    let diff = try Core.compareSVG(data, minified)
                    if diff.max > svgMaxDiff || diff.mean > svgMeanDiff {
                        log.warning("""
                            Minify changed rendering of \(source.url.lastPathComponent, privacy: .public) \
                            (max \(diff.max), mean \(diff.mean)); oxvg jobs: \(Core.minifyJobs.joined(separator: ","), privacy: .public)
                            """)
                        throw ItemIssue.skipped("minify changed rendering")
                    }
                    output = minified
                }
                // Sets the new size, and turns .svgz into plain SVG.
                output = try Core.rewriteSVG(output, width: resized ? target.width : 0,
                                             height: resized ? target.height : 0, minify: false)
                return EncodedOutput(data: output, plan: plan, width: target.width, height: target.height, resized: resized)
            }
            // SVG → raster: render straight at the target size (upscaling allowed).
            let rgba = try Core.renderSVG(data, width: target.width, height: target.height)
            let bitmap = Bitmap(straight: rgba, width: target.width, height: target.height)
            let output = try Encode.raster(bitmap, format: plan.format, quality: plan.quality, progressive: plan.progressive)
            return EncodedOutput(data: output, plan: plan, width: target.width, height: target.height, resized: resized)

        case .raster:
            var plan = try OutputPlan.resolve(source: source, options: options, hasAlpha: source.mayHaveAlpha, sourceData: data)

            // Lossless PNG → PNG without resizing: optimise the original bytes; pixels stay identical.
            if source.isPlainPNG && !source.isAnimated && plan.format == .png && plan.quality == 100 && !resized {
                let output = try Core.optimizePNG(data)
                return EncodedOutput(data: output, plan: plan, width: target.width, height: target.height, resized: false)
            }

            var bitmap = try autoreleasepool { try Normalize.bitmap(from: Decode.image(from: data)) }
            if source.outputFormat == nil {
                // "Same as original" for HEIC/RAW/…: decide PNG vs JPEG on the actual pixels.
                plan = try OutputPlan.resolve(source: source, options: options, hasAlpha: bitmap.hasTransparency, sourceData: data)
            }
            if resized {
                bitmap = try Resize.scale(bitmap, width: target.width, height: target.height)
            }
            let output = try Encode.raster(bitmap, format: plan.format, quality: plan.quality, progressive: plan.progressive)
            return EncodedOutput(data: output, plan: plan, width: bitmap.width, height: bitmap.height, resized: resized)
        }
    }

    /// Encodes and writes one item. Never throws: every outcome is reported in the result.
    @concurrent
    static func process(_ source: SourceInfo, options: ProcessingOptions,
                        confirmPermanentReplace: @escaping @Sendable (URL) async -> Bool) async -> ItemResult {
        let encoded: EncodedOutput
        do {
            encoded = try encode(source, options: options)
        } catch let issue as ItemIssue {
            return ItemResult(outcome: issue.outcome)
        } catch DecodeError.unsupported {
            return ItemResult(outcome: .unsupported)
        } catch {
            return ItemResult(outcome: .failed(error.localizedDescription))
        }

        var result = ItemResult(outcome: .alreadyOptimal, format: encoded.plan.format,
                                outputSize: Int64(encoded.data.count),
                                outputWidth: encoded.width, outputHeight: encoded.height)

        // SVGZ → SVG counts as a format change: plain text can't be compared with gzip.
        let sameFormat = encoded.plan.format == source.outputFormat && source.type != .svgz
        if options.skipIfLarger && sameFormat && !encoded.resized && Int64(encoded.data.count) >= source.fileSize {
            result.outputSize = source.fileSize
            return result
        }
        if Task.isCancelled { return ItemResult(outcome: .skipped("Stopped")) }

        do {
            let url: URL
            switch options.outputMode {
            case .copy:
                url = try Writer.saveCopy(encoded.data, source: source.url, format: encoded.plan.format,
                                          prefix: options.prefix, suffix: options.suffix)
            case .replace:
                url = try await Writer.replace(encoded.data, source: source.url, format: encoded.plan.format,
                                               confirmPermanent: confirmPermanentReplace)
            }
            result.outcome = .written(url)
        } catch {
            result.outcome = .failed(error.localizedDescription)
        }
        return result
    }
}

private extension ItemIssue {
    var outcome: ItemResult.Outcome {
        switch self {
        case .skipped(let reason): .skipped(reason)
        case .alreadyOptimal: .alreadyOptimal
        case .unsupported: .unsupported
        }
    }
}
