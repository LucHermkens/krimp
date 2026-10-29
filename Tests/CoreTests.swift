import Foundation
import ImageIO
import Testing


@Suite struct CoreTests {
    /// 2×2: red, green, blue, transparent white.
    static let pixels = Data([255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 0])

    @Test(arguments: [Core.Codec.jpeg, .png, .webp, .gif, .avif], [90, 100])
    func roundTrips2x2(codec: Core.Codec, quality: Int) throws {
        let encoded = try Core.encode(rgba: Self.pixels, width: 2, height: 2, codec: codec, quality: quality, progressive: true)
        let source = try #require(CGImageSourceCreateWithData(encoded as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 2 && image.height == 2)
    }

    @Test func rendersAndMinifiesSVG() throws {
        let svg = Data("""
            <?xml version="1.0"?>
            <!-- trivial -->
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">
              <metadata>editor junk</metadata>
              <rect x="0.000" y="0.000" width="10" height="10" fill="#FF0000"/>
            </svg>
            """.utf8)
        #expect(try Core.svgSize(svg) == CGSize(width: 10, height: 10))

        let rgba = try Core.renderSVG(svg, width: 4, height: 4)
        #expect(rgba.count == 4 * 4 * 4)
        #expect(Array(rgba.prefix(4)) == [255, 0, 0, 255])

        let minified = try Core.rewriteSVG(svg, minify: true)
        #expect(minified.count < svg.count)
        let diff = try Core.compareSVG(svg, minified)
        #expect(diff.max == 0)
    }

    @Test func reportsErrors() {
        #expect(throws: Core.Error.self) { try Core.svgSize(Data("not svg".utf8)) }
    }
}
