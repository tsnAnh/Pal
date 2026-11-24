@testable import PalChat
import CoreGraphics
import Testing

@Suite("Chat image fit")
struct ChatImageFitTests {
    private let box = CGSize(width: 320, height: 320)

    private func fitted(_ width: Int, _ height: Int) -> CGSize {
        ChatImageFit.size(ratio: ChatImageFit.ratio(pixelWidth: width, pixelHeight: height), in: box)
    }

    @Test("a wide screenshot keeps its whole width at its own ratio")
    func wideScreenshot() {
        let size = fitted(1772, 550)
        #expect(size.width == 320)
        #expect(abs(size.width / size.height - 1772.0 / 550.0) < 0.05)
    }

    @Test("a 1.3 to 1 picture and a portrait picture fit inside the box without cropping")
    func otherRatios() {
        let landscape = fitted(1300, 1000)
        #expect(landscape.width == 320)
        #expect(abs(landscape.width / landscape.height - 1.3) < 0.02)
        let portrait = fitted(1000, 1600)
        #expect(portrait.height == 320)
        #expect(abs(portrait.width / portrait.height - 0.625) < 0.01)
    }

    @Test("no ratio ever leaves the box")
    func staysInTheBox() {
        for (width, height) in [(1, 1), (4000, 30), (30, 4000), (1920, 1080), (1080, 1920), (500, 500)] {
            let size = fitted(width, height)
            #expect(size.width <= box.width && size.height <= box.height, "\(width)x\(height) -> \(size)")
        }
    }

    @Test("an unknown or broken size takes the stable placeholder ratio")
    func placeholder() {
        let expected = ChatImageFit.size(ratio: ChatImageFit.placeholderRatio, in: box)
        #expect(expected == CGSize(width: 320, height: 240))
        for (width, height) in [(nil, nil), (1772, nil), (nil, 550), (0, 550), (1772, 0), (-1, 5)] as [(Int?, Int?)] {
            #expect(ChatImageFit.size(ratio: ChatImageFit.ratio(pixelWidth: width, pixelHeight: height), in: box) == expected)
        }
    }

    @Test("a degenerate box is returned as it is")
    func degenerateBox() {
        #expect(ChatImageFit.size(ratio: 2, in: .zero) == .zero)
        #expect(ChatImageFit.size(ratio: 0, in: box) == box)
    }
}
