import CoreGraphics
import Foundation
import ImageIO
import PalBotProfile
import PalDesign
import PalProtocol
import SwiftUI
import Testing
import UniformTypeIdentifiers

@testable import Pal

private struct Pixel {
    let r: Int
    let g: Int
    let b: Int

    var spread: Int { max(r, g, b) - min(r, g, b) }
}

private struct Measurement {
    let icon: PixelBox
    let text: PixelBox
    let bitmap: Bitmap
}

private struct Bitmap {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(_ image: CGImage) {
        width = image.width
        height = image.height
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        bytes = data
    }

    func pixel(_ x: Int, _ y: Int) -> Pixel {
        let index = (y * width + x) * 4
        return Pixel(r: Int(bytes[index]), g: Int(bytes[index + 1]), b: Int(bytes[index + 2]))
    }

    func bounds(in columns: Range<Int>? = nil, where matches: (Pixel) -> Bool) -> PixelBox? {
        var box: PixelBox?
        for y in 0..<height {
            for x in columns ?? 0..<width where matches(pixel(x, y)) {
                box = box?.including(x, y) ?? PixelBox(minX: x, maxX: x + 1, minY: y, maxY: y + 1)
            }
        }
        return box
    }
}

private struct PixelBox {
    var minX: Int
    var maxX: Int
    var minY: Int
    var maxY: Int

    var width: Int { maxX - minX }
    var height: Int { maxY - minY }
    var midY: CGFloat { CGFloat(minY + maxY) / 2 }

    func including(_ x: Int, _ y: Int) -> PixelBox {
        PixelBox(minX: min(minX, x), maxX: max(maxX, x + 1), minY: min(minY, y), maxY: max(maxY, y + 1))
    }
}

private enum Ink {
    static func isIcon(_ p: Pixel) -> Bool { p.g < 90 && (p.r > 120 || p.b > 120) && abs(p.r - p.b) > 40 || isMix(p) }
    static func isMix(_ p: Pixel) -> Bool { p.g < 60 && p.r > 70 && p.b > 70 }
    static func isPure(_ p: Pixel) -> Bool { p.g < 40 && ((p.r > 225 && p.b < 40) || (p.b > 225 && p.r < 40)) }
    static func isText(_ p: Pixel) -> Bool { p.g > 90 && p.g - p.r > 60 && p.g - p.b > 60 }
    static func isDark(_ p: Pixel) -> Bool { p.r < 140 && p.g < 140 && p.b < 140 && p.spread < 30 }
}

private func checkerboard(side: Int) -> Data {
    let context = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    for column in 0..<side {
        for row in 0..<side {
            let isRed = (column + row) % 2 == 0
            context.setFillColor(CGColor(srgbRed: isRed ? 1 : 0, green: 0, blue: isRed ? 0 : 1, alpha: 1))
            context.fill(CGRect(x: column, y: row, width: 1, height: 1))
        }
    }
    return png(context.makeImage()!)
}

private func png(_ image: CGImage) -> Data {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

@MainActor
private func render(_ view: some View, scale: CGFloat) -> Bitmap {
    let theme = PalTheme(mode: .light, palette: AppearanceMode.light.palette(systemScheme: .light))
    let renderer = ImageRenderer(
        content: view.padding(8).background(Color.white).environment(\.colorScheme, .light).environment(\.hermesTheme, theme)
    )
    renderer.scale = scale
    return Bitmap(renderer.cgImage!)
}

@MainActor
private func settled(_ view: some View, scale: CGFloat, until ready: (Bitmap) -> Bool) async -> Bitmap {
    var bitmap = render(view, scale: scale)
    for _ in 0..<150 where !ready(bitmap) {
        try? await Task.sleep(for: .milliseconds(20))
        bitmap = render(view, scale: scale)
    }
    return bitmap
}

private let linkURL = URL(string: "https://icons.demo.com/page")!

private func linkText(link: String) -> AttributedString {
    var text = AttributedString("HHHH ")
    var anchor = AttributedString(link)
    anchor.link = linkURL
    text += anchor
    return text
}

struct InlineStyleCase: Sendable, CustomTestStringConvertible {
    let style: PalTextStyle
    let weight: Font.Weight?
    let testDescription: String

    static let all = [
        InlineStyleCase(style: .chatBody, weight: nil, testDescription: "body"),
        InlineStyleCase(style: .chatStatus, weight: .bold, testDescription: "heading"),
    ]
}

private let inlineIconPoints: CGFloat = 17
private let scales: [CGFloat] = [1, 2, 3]

@MainActor
@Suite("A link's site icon is sharp and centred on its text")
struct LinkIconRenderingTests {
    private func inline(_ style: InlineStyleCase, cache: FaviconCache) -> some View {
        InlineText(
            text: linkText(link: "x"), highlight: "", isCurrentMatch: false, style: style.style, weight: style.weight,
            foreground: Color(.sRGB, red: 0, green: 0.75, blue: 0)
        )
        .frame(width: 300, alignment: .leading)
        .environment(\.faviconCache, cache)
    }

    private func measureInline(_ style: InlineStyleCase, scale: CGFloat, source: Int) async -> Measurement? {
        let data = checkerboard(side: source)
        let cache = FaviconCache { _ in data }
        let bitmap = await settled(inline(style, cache: cache), scale: scale) { $0.bounds(where: Ink.isIcon) != nil }
        guard let icon = bitmap.bounds(where: Ink.isIcon),
              let capitals = bitmap.bounds(in: 0..<icon.minX, where: Ink.isText)
        else { return nil }
        return Measurement(icon: icon, text: capitals, bitmap: bitmap)
    }

    private func oneToOneShare(_ bitmap: Bitmap, _ box: PixelBox) -> Double {
        let inset = max(2, box.width / 6)
        var exact = 0
        var total = 0
        for y in (box.minY + inset)..<(box.maxY - inset) {
            for x in (box.minX + inset)..<(box.maxX - inset) {
                total += 1
                let here = bitmap.pixel(x, y)
                let neighbours = [bitmap.pixel(x + 1, y), bitmap.pixel(x, y + 1)]
                if Ink.isPure(here), neighbours.allSatisfy({ Ink.isPure($0) && ($0.r > $0.b) != (here.r > here.b) }) { exact += 1 }
            }
        }
        return total == 0 ? 0 : Double(exact) / Double(total)
    }

    @Test("the inline icon sits on the centre of the capitals", arguments: InlineStyleCase.all, scales)
    func inlineCentred(style: InlineStyleCase, scale: CGFloat) async throws {
        let measured = try #require(await measureInline(style, scale: scale, source: 96))
        let offset = (measured.icon.midY - measured.text.midY) / scale
        print(
            "MEASURE inline \(style.testDescription) @\(Int(scale))x icon \(measured.icon.width)x\(measured.icon.height)px",
            "capitals \(measured.text.height)px offset \(offset)pt"
        )
        #expect(abs(offset) <= 1 / scale + 0.01)
    }

    @Test("an icon made of exactly the drawn pixels reaches the screen one to one", arguments: scales)
    func inlineSharp(scale: CGFloat) async throws {
        let pixels = Int(inlineIconPoints * scale)
        let measured = try #require(await measureInline(InlineStyleCase.all[0], scale: scale, source: pixels))
        let share = oneToOneShare(measured.bitmap, measured.icon)
        print("MEASURE inline sharp @\(Int(scale))x source \(pixels)px drawn \(measured.icon.width)x\(measured.icon.height)px one-to-one \(share)")
        #expect(abs(measured.icon.width - pixels) <= 1)
        #expect(share > 0.98)
    }

    @Test("a 16 px icon is not stretched over a Retina screen, the vector globe stands in", arguments: [CGFloat(2), 3])
    func lowResolutionFallsBack(scale: CGFloat) async throws {
        let data = checkerboard(side: 16)
        let cache = FaviconCache { _ in data }
        let bitmap = await settled(inline(InlineStyleCase.all[0], cache: cache), scale: scale) { $0.bounds(where: Ink.isIcon) != nil }
        let stretched = bitmap.bounds(where: Ink.isIcon)
        print("MEASURE inline 16px source @\(Int(scale))x drawn \(stretched.map { "\($0.width)px" } ?? "globe")")
        #expect(stretched == nil)
    }

    @Test("a 32 px icon is still drawn on a 3x screen", arguments: [CGFloat(2), 3])
    func standardResolutionStays(scale: CGFloat) async throws {
        let measured = try #require(await measureInline(InlineStyleCase.all[0], scale: scale, source: 32))
        #expect(measured.icon.width == Int(inlineIconPoints * scale))
    }

    private func libraryModel() -> LibraryModel {
        let root = FileManager.default.temporaryDirectory.appending(path: "link-icon-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let surfaces = SurfaceCache(store: CacheStore(root: root), account: { "test|me" })
        let service = LibraryService(gateway: BotsGateway { _, _ in throw CancellationError() })
        return LibraryModel(botName: "bot", library: service, surfaces: surfaces)
    }

    private var libraryEntry: LibraryEntry {
        LibraryEntry(id: "link", kind: .link, title: "HHHH", kindLabel: "Link", url: linkURL, occurredAt: Date(timeIntervalSince1970: 0))
    }

    private func measureRow(_ row: some View, scale: CGFloat, source: Int) async -> Measurement? {
        let data = checkerboard(side: source)
        let cache = FaviconCache { _ in data }
        let view = row.frame(width: 320, alignment: .leading).environment(\.faviconCache, cache)
        let bitmap = await settled(view, scale: scale) { $0.bounds(where: Ink.isIcon) != nil }
        guard let icon = bitmap.bounds(where: Ink.isIcon),
              let text = bitmap.bounds(in: icon.maxX..<bitmap.width, where: Ink.isDark)
        else { return nil }
        return Measurement(icon: icon, text: text, bitmap: bitmap)
    }

    #if os(macOS)
    private func row() -> some View {
        MacLibraryRow(
            item: MacLibraryRowItem(entry: libraryEntry, subtitle: "", groupID: "g", isFirst: false, isLast: false),
            isPreparing: false, model: libraryModel()
        )
    }

    private let rowIconPoints: CGFloat = 20
    #else
    private func row() -> some View {
        LibraryRow(entry: libraryEntry, model: libraryModel())
    }

    private let rowIconPoints: CGFloat = LibraryMetrics.iconSize
    #endif

    @Test("the library row icon is centred on its text", arguments: scales)
    func libraryCentred(scale: CGFloat) async throws {
        let measured = try #require(await measureRow(row(), scale: scale, source: 96))
        let offset = (measured.icon.midY - measured.text.midY) / scale
        print("MEASURE library row @\(Int(scale))x icon \(measured.icon.width)x\(measured.icon.height)px text \(measured.text.height)px offset \(offset)pt")
        #expect(abs(offset) <= 1)
    }

    @Test("a library icon made of exactly the drawn pixels reaches the screen one to one", arguments: scales)
    func librarySharp(scale: CGFloat) async throws {
        let pixels = Int(rowIconPoints * scale)
        let measured = try #require(await measureRow(row(), scale: scale, source: pixels))
        let share = oneToOneShare(measured.bitmap, measured.icon)
        print("MEASURE library sharp @\(Int(scale))x source \(pixels)px drawn \(measured.icon.width)x\(measured.icon.height)px one-to-one \(share)")
        #expect(abs(measured.icon.width - pixels) <= 1)
        #expect(share > 0.98)
    }

    @Test("a library icon never stretches a 16 px source over a Retina screen", arguments: [CGFloat(2), 3])
    func libraryLowResolutionFallsBack(scale: CGFloat) async throws {
        let data = checkerboard(side: 16)
        let cache = FaviconCache { _ in data }
        let view = row().frame(width: 320, alignment: .leading).environment(\.faviconCache, cache)
        let bitmap = await settled(view, scale: scale) { $0.bounds(where: Ink.isIcon) != nil }
        let stretched = bitmap.bounds(where: Ink.isIcon)
        print("MEASURE library 16px source @\(Int(scale))x drawn \(stretched.map { "\($0.width)px" } ?? "globe")")
        #expect(stretched == nil)
    }
}
