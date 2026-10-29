import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What Krimp knows about an input file before processing it.
struct SourceInfo: Sendable {
    enum Kind: Sendable { case raster, svg }

    let url: URL
    let kind: Kind
    let type: UTType
    let fileSize: Int64
    /// Display size in pixels (EXIF orientation applied); intrinsic size for SVG.
    let pixelWidth: Int
    let pixelHeight: Int
    /// More than one frame/page; only the first is used.
    let isAnimated: Bool
    /// From the file's properties; the pipeline re-checks actual pixels.
    let mayHaveAlpha: Bool
    /// 8-bit-or-less sRGB/untagged PNG, eligible for the lossless oxipng shortcut.
    let isPlainPNG: Bool

    var formatName: String { type.badgeName }
    /// The input format, when Krimp can also write it.
    var outputFormat: ImageFormat? { kind == .svg ? .svg : ImageFormat(typeIdentifier: type.identifier) }
}

enum DecodeError: LocalizedError {
    case unsupported
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .unsupported: "Unsupported"
        case .unreadable(let reason): reason
        }
    }
}

enum Decode {
    /// Every type ImageIO can decode on this system, plus SVG/SVGZ.
    static let readableTypes: [UTType] = {
        let identifiers = (CGImageSourceCopyTypeIdentifiers() as? [String]) ?? []
        var types = identifiers.compactMap(UTType.init)
        types += [.svg, .svgz]
        return types
    }()

    static func isSVG(_ url: URL) -> Bool {
        ["svg", "svgz"].contains(url.pathExtension.lowercased())
    }

    /// Reads the size and type without decoding pixels.
    static func probe(_ url: URL) throws -> SourceInfo {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        let fileSize = Int64(values.fileSize ?? 0)

        if isSVG(url) {
            let data = try Data(contentsOf: url)
            let size = try Core.svgSize(data)
            return SourceInfo(
                url: url, kind: .svg, type: url.pathExtension.lowercased() == "svgz" ? .svgz : .svg,
                fileSize: fileSize, pixelWidth: max(1, Int(size.width.rounded())),
                pixelHeight: max(1, Int(size.height.rounded())), isAnimated: false, mayHaveAlpha: true,
                isPlainPNG: false)
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let typeID = CGImageSourceGetType(source) as String?,
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { throw DecodeError.unsupported }

        let orientation = (props[kCGImagePropertyOrientation] as? UInt32) ?? 1
        let swapped = (5...8).contains(orientation)
        let type = UTType(typeID) ?? .image
        let depth = props[kCGImagePropertyDepth] as? Int ?? 8
        let profile = props[kCGImagePropertyProfileName] as? String
        let plainPNG = type == .png && depth <= 8 && (profile == nil || profile!.hasPrefix("sRGB"))

        return SourceInfo(
            url: url, kind: .raster, type: type, fileSize: fileSize,
            pixelWidth: swapped ? height : width, pixelHeight: swapped ? width : height,
            isAnimated: CGImageSourceGetCount(source) > 1,
            mayHaveAlpha: props[kCGImagePropertyHasAlpha] as? Bool ?? false,
            isPlainPNG: plainPNG)
    }

    /// Decodes the first frame with EXIF orientation applied, at full resolution.
    static func image(from data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { throw DecodeError.unsupported }
        // The thumbnail API is ImageIO's way to decode with the orientation transform applied;
        // asking for the full size means no resampling happens.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw DecodeError.unreadable("Couldn't decode image")
        }
        return image
    }

    /// Small preview for the grid (≈256 px), SVG via resvg.
    static func thumbnail(for url: URL, maxPixels: Int = 256) -> CGImage? {
        if isSVG(url) {
            guard let data = try? Data(contentsOf: url), let size = try? Core.svgSize(data) else { return nil }
            let scale = Double(maxPixels) / max(size.width, size.height)
            let w = max(1, Int((size.width * scale).rounded())), h = max(1, Int((size.height * scale).rounded()))
            guard let rgba = try? Core.renderSVG(data, width: w, height: h) else { return nil }
            return Bitmap(straight: rgba, width: w, height: h).cgImage()
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// True when a WebP file is lossless (VP8L bitstream).
    static func isLosslessWebP(_ data: Data) -> Bool {
        guard data.count >= 16, data.prefix(4) == Data("RIFF".utf8) else { return false }
        var offset = 12
        while offset + 8 <= data.count {
            let start = data.startIndex + offset
            let fourCC = String(decoding: data[start..<start + 4], as: UTF8.self)
            if fourCC == "VP8L" { return true }
            if fourCC == "VP8 " { return false }
            let size = data[start + 4..<start + 8].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
            offset += 8 + size + (size & 1)
        }
        return false
    }
}
