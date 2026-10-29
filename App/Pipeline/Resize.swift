import Accelerate
import Foundation

enum Resize {
    /// Target size for `mode`/`value`, keeping the aspect ratio. Raster sources are never upscaled:
    /// if the result would be larger than the source, the source size is returned.
    static func targetSize(width: Int, height: Int, mode: ResizeMode, value: Int, allowUpscale: Bool) -> (width: Int, height: Int) {
        guard width > 0, height > 0, value > 0 else { return (width, height) }
        let w = Double(width), h = Double(height), v = Double(value)
        let scale = switch mode {
        case .width: v / w
        case .height: v / h
        case .longestEdge: v / max(w, h)
        case .percentage: v / 100
        }
        if scale >= 1 && !allowUpscale { return (width, height) }
        return (max(1, Int((w * scale).rounded())), max(1, Int((h * scale).rounded())))
    }

    /// High-quality (Lanczos) resampling with vImage. Works on premultiplied pixels so
    /// transparent edges don't pick up dark halos.
    static func scale(_ bitmap: Bitmap, width: Int, height: Int) throws -> Bitmap {
        precondition(bitmap.premultiplied, "resize premultiplied pixels")
        if width == bitmap.width && height == bitmap.height { return bitmap }
        var output = Data(count: width * height * 4)
        // vImage only reads the source; borrowing it avoids copying a possibly huge buffer.
        let error = bitmap.data.withUnsafeBytes { src in
            output.withUnsafeMutableBytes { dst in
                var s = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.baseAddress), height: vImagePixelCount(bitmap.height),
                                      width: vImagePixelCount(bitmap.width), rowBytes: bitmap.width * 4)
                var d = vImage_Buffer(data: dst.baseAddress, height: vImagePixelCount(height),
                                      width: vImagePixelCount(width), rowBytes: width * 4)
                return vImageScale_ARGB8888(&s, &d, nil, vImage_Flags(kvImageHighQualityResampling))
            }
        }
        guard error == kvImageNoError else { throw DecodeError.unreadable("Resize failed (vImage \(error))") }
        return Bitmap(premultiplied: output, width: width, height: height)
    }
}
