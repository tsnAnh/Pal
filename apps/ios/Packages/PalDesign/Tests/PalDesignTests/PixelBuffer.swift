import CoreGraphics
import Foundation
import ImageIO

enum ParityError: Error {
    case renderFailed(String)
    case unreadable(URL)
    case sizeMismatch(expected: Int, actual: Int)
}

struct PixelBuffer {
    let side: Int
    private(set) var rgba: [UInt8]

    init(png url: URL, side: Int) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw ParityError.unreadable(url) }
        try self.init(image: image, side: side)
    }

    init(image: CGImage, side: Int) throws {
        guard image.width == side, image.height == side else {
            throw ParityError.sizeMismatch(expected: side, actual: image.width)
        }
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let drewIntoWhite = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drewIntoWhite else { throw ParityError.unreadable(URL(fileURLWithPath: "/dev/null")) }
        self.side = side
        self.rgba = bytes
    }

    func compare(to other: PixelBuffer, tolerance: Int, id: String, group: String) -> ParityScore {
        var differing = 0
        var total = 0
        var maxDiff = 0
        let pixels = side * side
        for pixel in 0..<pixels {
            var worst = 0
            for channel in 0..<3 {
                let diff = abs(Int(rgba[pixel * 4 + channel]) - Int(other.rgba[pixel * 4 + channel]))
                total += diff
                worst = max(worst, diff)
            }
            maxDiff = max(maxDiff, worst)
            if worst > tolerance { differing += 1 }
        }
        return ParityScore(
            id: id, group: group,
            differingFraction: Double(differing) / Double(pixels),
            meanDifference: Double(total) / Double(pixels * 3 * 255),
            maxDifference: maxDiff
        )
    }
}
