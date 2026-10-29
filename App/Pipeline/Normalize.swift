import Accelerate
import CoreGraphics
import Foundation

/// 8-bit sRGB RGBA pixels, tightly packed (`width * 4` stride).
struct Bitmap: @unchecked Sendable {
    var data: Data
    let width: Int
    let height: Int
    /// CoreGraphics and vImage work premultiplied; the encoders want straight alpha.
    var premultiplied: Bool

    init(premultiplied data: Data, width: Int, height: Int) {
        self.data = data
        self.width = width
        self.height = height
        self.premultiplied = true
    }

    init(straight data: Data, width: Int, height: Int) {
        self.data = data
        self.width = width
        self.height = height
        self.premultiplied = false
    }

    /// True if any pixel isn't fully opaque.
    var hasTransparency: Bool {
        data.withUnsafeBytes { raw in
            let px = raw.bindMemory(to: UInt8.self)
            var i = 3
            while i < px.count {
                if px[i] != 255 { return true }
                i += 4
            }
            return false
        }
    }

    func unpremultiplied() -> Bitmap {
        guard premultiplied else { return self }
        var copy = self
        copy.data.withUnsafeMutableBytes { raw in
            var buffer = vImage_Buffer(data: raw.baseAddress, height: vImagePixelCount(height),
                                       width: vImagePixelCount(width), rowBytes: width * 4)
            vImageUnpremultiplyData_RGBA8888(&buffer, &buffer, vImage_Flags(kvImageNoFlags))
        }
        copy.premultiplied = false
        return copy
    }

    func cgImage() -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let alpha: CGImageAlphaInfo = premultiplied ? .premultipliedLast : .last
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: Normalize.sRGB, bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

enum Normalize {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Draws into an 8-bit premultiplied sRGB RGBA context. This converts CMYK, grayscale,
    /// 16-bit, wide-gamut and HDR sources (gain maps are already gone at this point).
    static func bitmap(from image: CGImage) throws -> Bitmap {
        let width = image.width, height = image.height
        var data = Data(count: width * height * 4)
        let drawn = data.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw DecodeError.unreadable("Couldn't allocate \(width)×\(height) bitmap") }
        return Bitmap(premultiplied: data, width: width, height: height)
    }
}
