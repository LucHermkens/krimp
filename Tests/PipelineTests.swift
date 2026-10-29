import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

private final class BundleToken {}

/// Helpers shared by the pipeline tests.
enum Fixtures {
    static let root = Bundle(for: BundleToken.self).resourceURL!.appendingPathComponent("Fixtures")

    static func url(_ path: String) -> URL { root.appendingPathComponent(path) }

    /// Copies a fixture into a fresh temporary folder (optionally renamed) and returns its URL.
    static func copy(_ path: String, as name: String? = nil) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("krimp-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent(name ?? (path as NSString).lastPathComponent)
        try FileManager.default.copyItem(at: url(path), to: target)
        return target
    }

    static func properties(_ data: Data) -> [CFString: Any] {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }

    /// Decodes and draws into 8-bit sRGB RGBA (straight alpha) for pixel checks.
    static func pixels(_ data: Data) throws -> Bitmap {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return try Normalize.bitmap(from: image).unpremultiplied()
    }
}

extension Bitmap {
    func pixel(_ x: Int, _ y: Int) -> [Int] {
        let i = (y * width + x) * 4
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in (0..<4).map { Int(raw[i + $0]) } }
    }
}

func close(_ a: [Int], _ b: [Int], within tolerance: Int) -> Bool {
    zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
}

func options(_ configure: (inout ProcessingOptions) -> Void = { _ in }) -> ProcessingOptions {
    var o = ProcessingOptions()
    configure(&o)
    return o
}

@Suite struct PipelineTests {
    @Test func iPhoneHEICComesOutUprightWithoutColourShift() throws {
        let source = try Decode.probe(Fixtures.url("pipeline/iphone-orientation6-p3.heic"))
        #expect(source.formatName == "HEIC")
        #expect((source.pixelWidth, source.pixelHeight) == (300, 400))

        let out = try Pipeline.encode(source, options: options())
        #expect(out.plan.format == .jpeg)
        #expect(out.plan.quality == 90)
        let px = try Fixtures.pixels(out.data)
        #expect((px.width, px.height) == (300, 400))
        // Stored top-left (red) is displayed top-right after "rotate 90 CW"; bottom-right (blue) bottom-left.
        #expect(close(px.pixel(260, 30), [255, 0, 0, 255], within: 12))
        #expect(close(px.pixel(30, 370), [0, 0, 255, 255], within: 12))
        // The body was sRGB (200, 100, 50) before conversion to Display P3.
        #expect(close(px.pixel(150, 200), [200, 100, 50, 255], within: 4), "\(px.pixel(150, 200))")

        let props = Fixtures.properties(out.data)
        #expect(props[kCGImagePropertyGPSDictionary] == nil)
        #expect(out.data.range(of: Data("ICC_PROFILE".utf8)) == nil)
        #expect((props[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
    }

    @Test func transparentPNGDownscalesWithoutHalos() throws {
        let source = try Decode.probe(Fixtures.url("pipeline/transparent-circle.png"))
        let out = try Pipeline.encode(source, options: options {
            $0.resizeEnabled = true
            $0.resizeMode = .longestEdge
            $0.resizeValue = 97
            $0.quality = 100
        })
        let px = try Fixtures.pixels(out.data)
        #expect((px.width, px.height) == (97, 97))
        var edgePixels = 0
        for y in 0..<px.height {
            for x in 0..<px.width {
                let p = px.pixel(x, y)
                guard p[3] >= 16 else { continue }
                if p[3] < 255 { edgePixels += 1 }
                #expect(p[0] >= 230 && p[1] <= 25 && p[2] <= 25, "dark fringe at \(x),\(y): \(p)")
            }
        }
        #expect(edgePixels > 50)
    }

    @Test func sixteenBitPNGBecomesEightBit() throws {
        let source = try Decode.probe(Fixtures.url("pipeline/gradient-16bit.png"))
        #expect(!source.isPlainPNG)
        let out = try Pipeline.encode(source, options: options { $0.quality = 100 })
        #expect(out.plan.format == .png)
        #expect(Fixtures.properties(out.data)[kCGImagePropertyDepth] as? Int == 8)
        let px = try Fixtures.pixels(out.data)
        #expect(px.pixel(10, 0)[0] <= 2)
        #expect(px.pixel(10, 255)[0] >= 253)
        let column = (0..<256).map { px.pixel(10, $0)[0] }
        #expect(column == column.sorted())
    }

    @Test func cmykJPEGIsConvertedToRGB() throws {
        let url = Fixtures.url("pipeline/cmyk.jpg")
        let source = try Decode.probe(url)
        let out = try Pipeline.encode(source, options: options())
        let props = Fixtures.properties(out.data)
        #expect(props[kCGImagePropertyColorModel] as? String == "RGB")
        // Compare against ImageIO's own CMYK → sRGB rendering.
        let reference = try Fixtures.pixels(try Data(contentsOf: url))
        let result = try Fixtures.pixels(out.data)
        var total = 0
        for y in stride(from: 0, to: result.height, by: 4) {
            for x in stride(from: 0, to: result.width, by: 4) {
                total += zip(reference.pixel(x, y).prefix(3), result.pixel(x, y).prefix(3)).map { abs($0 - $1) }.reduce(0, +)
            }
        }
        let mean = Double(total) / Double((result.width / 4) * (result.height / 4) * 3)
        #expect(mean < 4, "mean difference \(mean)")
    }

    @Test func animatedGIFUsesFirstFrame() throws {
        let source = try Decode.probe(Fixtures.url("pipeline/animated.gif"))
        #expect(source.isAnimated)
        let out = try Pipeline.encode(source, options: options())
        #expect(out.plan.format == .gif)
        let image = try #require(CGImageSourceCreateWithData(out.data as CFData, nil))
        #expect(CGImageSourceGetCount(image) == 1)
        #expect(close(try Fixtures.pixels(out.data).pixel(10, 10), [255, 0, 0, 255], within: 4))
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: Fixtures.url("downloaded/iphone-xs.dng").path),
                   "run `make fixtures` to download the DNG sample"))
    func cameraRawDecodesThroughImageIO() throws {
        let source = try Decode.probe(Fixtures.url("downloaded/iphone-xs.dng"))
        #expect(source.outputFormat == nil)
        let out = try Pipeline.encode(source, options: options {
            $0.resizeEnabled = true
            $0.resizeValue = 1000
        })
        #expect(out.plan.format == .jpeg)
        #expect((out.width, out.height) == (1000, 750))
    }

    @Test func fiftyMegapixelImageStaysWithinMemoryBudget() throws {
        let url = try Self.makeLargeJPEG(width: 8660, height: 5774)
        let before = Memory.footprint()
        let source = try Decode.probe(url)
        let out = try Pipeline.encode(source, options: options {
            $0.resizeEnabled = true
            $0.resizeValue = 2000
        })
        let peak = Memory.footprint().peak
        #expect((out.width, out.height) == (2000, 1333))
        // The peak is process-wide, so tests running in parallel inflate it. Run this test alone
        // for a clean number (≈630 MB, including generating the source JPEG).
        let growthMB = Double(peak.saturatingSubtract(before.current)) / 1_000_000
        print("50 MP: peak footprint \(Int(Double(peak) / 1_000_000)) MB (≈\(Int(growthMB)) MB above start)")
        #expect(growthMB < 2500)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Streams a gradient into a JPEG without holding the full bitmap in memory.
    static func makeLargeJPEG(width: Int, height: Int) throws -> URL {
        final class Generator {
            let width: Int
            var offset = 0
            init(width: Int) { self.width = width }
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("krimp-large-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("large.jpg")
        let generator = Generator(width: width)
        var callbacks = CGDataProviderSequentialCallbacks(
            version: 0,
            getBytes: { info, buffer, count in
                let g = Unmanaged<Generator>.fromOpaque(info!).takeUnretainedValue()
                let bytes = buffer.assumingMemoryBound(to: UInt8.self)
                for i in 0..<count {
                    let pos = g.offset + i
                    let pixel = pos / 3, channel = pos % 3
                    let x = pixel % g.width, y = pixel / g.width
                    bytes[i] = UInt8(truncatingIfNeeded: channel == 0 ? x / 34 : channel == 1 ? y / 23 : (x ^ y) & 0xFF)
                }
                g.offset += count
                return count
            },
            skipForward: { info, count in
                Unmanaged<Generator>.fromOpaque(info!).takeUnretainedValue().offset += Int(count)
                return count
            },
            rewind: { info in Unmanaged<Generator>.fromOpaque(info!).takeUnretainedValue().offset = 0 },
            releaseInfo: { info in Unmanaged<Generator>.fromOpaque(info!).release() })
        let provider = try #require(CGDataProvider(
            sequentialInfo: Unmanaged.passRetained(generator).toOpaque(), callbacks: &callbacks))
        let image = try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3,
            space: Normalize.sRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test func unicodeAndSpacesInFileNames() async throws {
        let url = try Fixtures.copy("graphics/poster.png", as: "Föto ñ 日本 (1).png")
        let source = try Decode.probe(url)
        let result = await Pipeline.process(source, options: options { $0.outputMode = .copy }) { _ in false }
        let expected = url.deletingLastPathComponent().appendingPathComponent("Föto ñ 日本 (1)-small.png")
        #expect(result.outcome == .written(expected))
        #expect(FileManager.default.fileExists(atPath: expected.path))
    }

    @Test func readOnlyFileIsNotReplacedButCanBeCopied() async throws {
        let url = try Fixtures.copy("photos/kodim15.png")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        let original = try Data(contentsOf: url)
        let source = try Decode.probe(url)

        let replaced = await Pipeline.process(source, options: options { $0.format = .jpeg }) { _ in true }
        #expect(replaced.outcome == .failed("File is read-only"))
        #expect(try Data(contentsOf: url) == original)

        let copied = await Pipeline.process(source, options: options { $0.format = .jpeg; $0.outputMode = .copy }) { _ in true }
        #expect(copied.outcome == .written(url.deletingLastPathComponent().appendingPathComponent("kodim15-small.jpg")))
    }

    @Test func svgWithViewBoxOnly() throws {
        let source = try Decode.probe(Fixtures.url("svg/icon-viewbox.svg"))
        #expect((source.pixelWidth, source.pixelHeight) == (24, 24))
        let png = try Pipeline.encode(source, options: options { $0.format = .png })
        #expect((png.width, png.height) == (24, 24))
        let big = try Pipeline.encode(source, options: options {
            $0.format = .png
            $0.resizeEnabled = true
            $0.resizeValue = 512
        })
        #expect((big.width, big.height) == (512, 512))
        #expect(Fixtures.properties(big.data)[kCGImagePropertyPixelWidth] as? Int == 512)
    }

    @Test func svgWithTextGradientAndClipPath() throws {
        let source = try Decode.probe(Fixtures.url("svg/text.svg"))
        let out = try Pipeline.encode(source, options: options { $0.format = .png; $0.quality = 100 })
        let px = try Fixtures.pixels(out.data)
        #expect(px.pixel(2, 2)[3] == 0, "clip path keeps the corner transparent")
        #expect(px.pixel(200, 30)[2] > 200, "gradient fill")
        var white = 0
        for y in 60..<95 { for x in 60..<340 where px.pixel(x, y).prefix(3).allSatisfy({ $0 > 240 }) { white += 1 } }
        #expect(white > 500, "text rendered (\(white) white pixels)")
    }

    @Test func svgzBecomesPlainMinifiedSVG() async throws {
        let url = try Fixtures.copy("pipeline/text.svgz")
        let source = try Decode.probe(url)
        #expect(source.kind == .svg)
        let result = await Pipeline.process(source, options: options { $0.outputMode = .copy }) { _ in false }
        let expected = url.deletingLastPathComponent().appendingPathComponent("text-small.svg")
        #expect(result.outcome == .written(expected))
        let text = try String(contentsOf: expected, encoding: .utf8)
        #expect(text.hasPrefix("<svg"))
    }

    @Test func svgUpscaledTo4000IsSharp() throws {
        let source = try Decode.probe(Fixtures.url("svg/styled-classes.svg"))
        let out = try Pipeline.encode(source, options: options {
            $0.format = .png
            $0.quality = 100
            $0.resizeEnabled = true
            $0.resizeValue = 4000
        })
        #expect((out.width, out.height) == (4000, 2000))
        // Across the left edge of the first badge (x = 20 of 320 → 250 px), the transition
        // from background to stroke takes at most a couple of pixels.
        let px = try Fixtures.pixels(out.data)
        let row = 1000
        let soft = (200..<300).filter { let a = px.pixel($0, row)[3]; return a > 10 && a < 245 }.count
        #expect(soft <= 3, "\(soft) soft pixels")
    }

    @Test func svgToSVGResizeChangesSizeNotRendering() throws {
        let url = Fixtures.url("svg/illustrator.svg")
        let source = try Decode.probe(url)
        let out = try Pipeline.encode(source, options: options {
            $0.resizeEnabled = true
            $0.resizeMode = .width
            $0.resizeValue = 400
        })
        #expect(out.plan == OutputPlan(format: .svg, quality: 100, progressive: true, minify: true))
        #expect(try Core.svgSize(out.data) == CGSize(width: 400, height: 400))
        let diff = try Core.compareSVG(try Data(contentsOf: url), out.data)
        #expect(diff.max <= Pipeline.svgMaxDiff && diff.mean <= Pipeline.svgMeanDiff)
        #expect(out.data.count < (try Data(contentsOf: url)).count)
    }

    @Test func resizeOnlyJPEGKeepsSourceQuality() throws {
        let source = try Decode.probe(Fixtures.url("jpeg/kodim23-q85.jpg"))
        let out = try Pipeline.encode(source, options: options {
            $0.formatEnabled = false
            $0.resizeEnabled = true
            $0.resizeMode = .width
            $0.resizeValue = 384
        })
        #expect(out.plan.format == .jpeg)
        #expect(abs(out.plan.quality - 85) <= 3)
        #expect((out.width, out.height) == (384, 256))
    }

    @Test func tiffIsLZWWithoutColourProfile() throws {
        let source = try Decode.probe(Fixtures.url("photos/kodim03.png"))
        let out = try Pipeline.encode(source, options: options { $0.format = .tiff })
        let props = Fixtures.properties(out.data)
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        #expect(tiff?[kCGImagePropertyTIFFCompression] as? Int == 5)
        #expect(out.data.range(of: Data("ICC_PROFILE".utf8)) == nil)
        #expect(out.data.range(of: Data("acsp".utf8)) == nil, "ICC profile signature")
    }

    @Test(arguments: [FormatChoice.jpeg, .png, .webp, .avif, .gif, .tiff])
    func metadataIsStripped(format: FormatChoice) throws {
        let source = try Decode.probe(Fixtures.url("pipeline/exif-gps.jpg"))
        let out = try Pipeline.encode(source, options: options { $0.format = format })
        for marker in ["Exif\0\0", "http://ns.adobe.com/xap/1.0/", "secret", "Canon", "ICC_PROFILE"] {
            #expect(out.data.range(of: Data(marker.utf8)) == nil, "\(format): found \(marker.debugDescription)")
        }
        #expect(Fixtures.properties(out.data)[kCGImagePropertyGPSDictionary] == nil)
    }

    @Test func formatOffKeepsFormatAndQuality() throws {
        func plan(_ path: String, alpha: Bool = false) throws -> OutputPlan {
            let url = Fixtures.url(path)
            return try OutputPlan.resolve(source: try Decode.probe(url), options: options { $0.formatEnabled = false },
                                          hasAlpha: alpha, sourceData: try Data(contentsOf: url))
        }
        #expect(try plan("photos/kodim03.png").quality == 100)
        #expect(try plan("pipeline/animated.gif") == OutputPlan(format: .gif, quality: 100, progressive: true, minify: false))
        #expect(try plan("pipeline/iphone-orientation6-p3.heic") == OutputPlan(format: .jpeg, quality: 95, progressive: true, minify: false))
        #expect(try plan("pipeline/iphone-orientation6-p3.heic", alpha: true).format == .png)
        #expect(try plan("svg/text.svg") == OutputPlan(format: .svg, quality: 100, progressive: true, minify: false))
        #expect(try plan("jpeg/kodim23-q60.jpg").quality == 60)

        let rgba = Data(repeating: 128, count: 16 * 16 * 4)
        let lossless = try Core.encode(rgba: rgba, width: 16, height: 16, codec: .webp, quality: 100, progressive: false)
        let lossy = try Core.encode(rgba: rgba, width: 16, height: 16, codec: .webp, quality: 80, progressive: false)
        #expect(Decode.isLosslessWebP(lossless))
        #expect(!Decode.isLosslessWebP(lossy))
    }

    @Test func rasterToSVGIsSkipped() async throws {
        let source = try Decode.probe(Fixtures.url("photos/kodim03.png"))
        let result = await Pipeline.process(source, options: options { $0.format = .svg }) { _ in false }
        #expect(result.outcome == .skipped("Can't convert raster to SVG"))
    }

    @Test func alreadyOptimalLeavesOriginalAlone() async throws {
        // An oxipng-optimised PNG can't get smaller losslessly.
        let url = try Fixtures.copy("graphics/poster.png")
        try Core.optimizePNG(try Data(contentsOf: url)).write(to: url)
        let before = try Data(contentsOf: url)
        let source = try Decode.probe(url)
        let result = await Pipeline.process(source, options: options { $0.quality = 100 }) { _ in false }
        #expect(result.outcome == .alreadyOptimal)
        #expect(try Data(contentsOf: url) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).count == 1)
    }

    @Test func pngShortcutKeepsPixelsIdentical() throws {
        let url = Fixtures.url("graphics/ui-screenshot.png")
        let source = try Decode.probe(url)
        #expect(source.isPlainPNG)
        let out = try Pipeline.encode(source, options: options { $0.formatEnabled = false })
        let a = try Fixtures.pixels(try Data(contentsOf: url)), b = try Fixtures.pixels(out.data)
        #expect(a.data == b.data)
    }
}

@Suite struct NamingTests {
    let source = URL(fileURLWithPath: "/tmp/photos/photo.jpg")

    @Test func defaultSuffix() {
        #expect(Writer.copyName(for: source, ext: "jpg", prefix: "", suffix: "-small") == "photo-small.jpg")
    }

    @Test func emptyAffixesSameExtensionUsesCopy() {
        #expect(Writer.copyName(for: source, ext: "jpg", prefix: "", suffix: "") == "photo-copy.jpg")
        #expect(Writer.copyName(for: source, ext: "JPG", prefix: "", suffix: "") == "photo-copy.JPG")
    }

    @Test func emptyAffixesDifferentExtensionUsesBareName() {
        #expect(Writer.copyName(for: source, ext: "webp", prefix: "", suffix: "") == "photo.webp")
    }

    @Test func prefix() {
        #expect(Writer.copyName(for: source, ext: "png", prefix: "web_", suffix: "") == "web_photo.png")
    }

    @Test func collisionsGetNumbered() throws {
        let url = try Fixtures.copy("jpeg/kodim03-q85.jpg", as: "photo.jpg")
        let dir = url.deletingLastPathComponent()
        let data = try Data(contentsOf: url)
        let first = try Writer.saveCopy(data, source: url, format: .jpeg, prefix: "", suffix: "-small")
        let second = try Writer.saveCopy(data, source: url, format: .jpeg, prefix: "", suffix: "-small")
        let third = try Writer.saveCopy(data, source: url, format: .jpeg, prefix: "", suffix: "-small")
        #expect(first.lastPathComponent == "photo-small.jpg")
        #expect(second.lastPathComponent == "photo-small-2.jpg")
        #expect(third.lastPathComponent == "photo-small-3.jpg")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 4)
    }

    @Test func extensionFollowsFormat() {
        #expect(Writer.outputExtension(for: URL(fileURLWithPath: "/a/b.JPEG"), format: .jpeg) == "JPEG")
        #expect(Writer.outputExtension(for: URL(fileURLWithPath: "/a/b.heic"), format: .jpeg) == "jpg")
        #expect(Writer.outputExtension(for: URL(fileURLWithPath: "/a/b.svgz"), format: .svg) == "svg")
    }

    @Test func invalidAffixes() {
        #expect(Settings.invalidAffix("a/b"))
        #expect(Settings.invalidAffix("a:b"))
        #expect(!Settings.invalidAffix("-small"))
    }
}

enum Memory {
    static func footprint() -> (current: UInt64, peak: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        return (info.phys_footprint, UInt64(info.ledger_phys_footprint_peak))
    }
}

extension UInt64 {
    func saturatingSubtract(_ other: UInt64) -> UInt64 { self > other ? self - other : 0 }
}
