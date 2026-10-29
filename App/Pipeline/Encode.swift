import Foundation
import ImageIO
import UniformTypeIdentifiers

enum Encode {
    /// Encodes pixels into `format`. `quality` is 1–100 (100 = lossless where supported).
    static func raster(_ bitmap: Bitmap, format: ImageFormat, quality: Int, progressive: Bool,
                       maxEffort: Bool = false) throws -> Data {
        if format == .tiff { return try tiff(bitmap) }
        guard let codec = format.codec else { throw DecodeError.unreadable("\(format.name) can't encode pixels") }
        let straight = bitmap.unpremultiplied()
        return try Core.encode(rgba: straight.data, width: straight.width, height: straight.height, codec: codec,
                               quality: quality, progressive: progressive, maxEffort: maxEffort)
    }

    /// LZW-compressed TIFF via ImageIO, with no metadata and no embedded colour profile.
    static func tiff(_ bitmap: Bitmap) throws -> Data {
        // An untagged (device RGB) image keeps ImageIO from embedding an ICC profile;
        // the pixels are sRGB, which is what untagged images are assumed to be.
        let straight = bitmap.unpremultiplied()
        let opaque = !bitmap.hasTransparency
        guard let provider = CGDataProvider(data: straight.data as CFData),
              let image = CGImage(
                width: straight.width, height: straight.height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: straight.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: (opaque ? CGImageAlphaInfo.noneSkipLast : .last).rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw DecodeError.unreadable("Couldn't create TIFF image") }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.tiff.identifier as CFString, 1, nil)
        else { throw DecodeError.unreadable("ImageIO can't write TIFF") }
        let properties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5],  // 5 = LZW
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw DecodeError.unreadable("TIFF encoding failed") }
        return output as Data
    }
}
