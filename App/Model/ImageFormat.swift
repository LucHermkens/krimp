import Foundation
import UniformTypeIdentifiers

/// Formats Krimp can write.
enum ImageFormat: String, CaseIterable, Sendable {
    case jpeg, png, webp, avif, gif, tiff, svg

    var name: String {
        switch self {
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .webp: "WebP"
        case .avif: "AVIF"
        case .gif: "GIF"
        case .tiff: "TIFF"
        case .svg: "SVG"
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .tiff: "tiff"
        default: rawValue
        }
    }

    /// Extensions that count as "the same" when deciding whether to keep the original's.
    var knownExtensions: Set<String> {
        switch self {
        case .jpeg: ["jpg", "jpeg", "jpe", "jfif"]
        case .tiff: ["tif", "tiff"]
        default: [rawValue]
        }
    }

    /// TIFF and SVG output ignore the quality slider.
    var usesQuality: Bool { self != .tiff && self != .svg }

    var codec: Core.Codec? {
        switch self {
        case .jpeg: .jpeg
        case .png: .png
        case .webp: .webp
        case .avif: .avif
        case .gif: .gif
        case .tiff, .svg: nil
        }
    }

    /// Output format for an input type identifier, if that type is also an output format.
    init?(typeIdentifier: String) {
        guard let type = UTType(typeIdentifier) else { return nil }
        let map: [(UTType, ImageFormat)] = [
            (.jpeg, .jpeg), (.png, .png), (.webP, .webp), (UTType("public.avif") ?? .heic, .avif),
            (.gif, .gif), (.tiff, .tiff), (.svg, .svg),
        ]
        guard let match = map.first(where: { type == $0.0 }) else { return nil }
        self = match.1
    }
}

extension UTType {
    static let svgz = UTType(importedAs: "io.github.luchermkens.krimp.svgz", conformingTo: .image)

    /// Short uppercase label for badges: "JPEG", "HEIC", "DNG", "SVG"…
    var badgeName: String {
        if let format = ImageFormat(typeIdentifier: identifier) { return format.name }
        if self == .svgz { return "SVGZ" }
        return (preferredFilenameExtension ?? identifier.components(separatedBy: ".").last ?? "?").uppercased()
    }
}
