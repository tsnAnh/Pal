@testable import HermesChat
import HermesProtocol
import Foundation
import Testing

@Suite("Image attachments in messages")
struct MessageImagesTests {
    @Test("a sent message with @image directives yields image items and clean text")
    func sentMessage() {
        let content = MessageImages.extract(
            from: "look at these\n@image:/home/h/.hermes/images/a.png\n@image:`/home/h/.hermes/images/my pic.jpg`",
            role: .user
        )
        #expect(content.text == "look at these")
        #expect(content.images.map(\.name) == ["a.png", "my pic.jpg"])
        #expect(content.images.allSatisfy { $0.assetRef != nil })
    }

    @Test("an image-only sent message leaves no text")
    func imageOnly() {
        let content = MessageImages.extract(from: "@image:/h/images/a.png\n[screenshot]", role: .user)
        #expect(content.text.isEmpty)
        #expect(content.images.count == 1)
    }

    @Test("a received message with MEDIA tags yields image items; other attachments and prose stay")
    func receivedMessage() {
        let content = MessageImages.extract(
            from: "Here is the chart.\nMEDIA:/h/cache/images/chart.png\nAnd the report MEDIA:/h/cache/documents/report.pdf",
            role: .assistant
        )
        #expect(content.images.map(\.name) == ["chart.png"])
        #expect(content.text.contains("Here is the chart."))
        #expect(content.text.contains("MEDIA:/h/cache/documents/report.pdf"))
        #expect(!content.text.contains("chart.png"))
    }

    @Test("several images keep order and drop duplicates")
    func several() {
        let content = MessageImages.extract(from: "MEDIA:/a/1.png MEDIA:/a/2.jpg MEDIA:/a/1.png", role: .assistant)
        #expect(content.images.map(\.name) == ["1.png", "2.jpg"])
    }

    @Test("the asset ref is the gateway library id: first 32 hex of sha256 over 'media', NUL, path")
    func assetRef() {
        #expect(ImageReference.assetRef(forHostPath: "/x/y.png") == "76b67863b732c63d6ec750f5ce78db3a")
        #expect(ImageReference.assetRef(forHostPath: "/x/y.png") != ImageReference.assetRef(forHostPath: "/x/z.png"))
    }

    @Test("inline data URLs and https image URLs are images; plain prose is untouched")
    func inlineAndRemote() {
        let png = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
        let inline = MessageImages.extract(from: "hi\ndata:image/png;base64,\(png)", role: .user)
        #expect(inline.images.count == 1)
        #expect(inline.text == "hi")
        let remote = MessageImages.extract(from: "https://example.com/p.jpg", role: .user)
        #expect(remote.images.count == 1)
        let plain = MessageImages.extract(from: "no images @here MEDIA is a word", role: .assistant)
        #expect(plain.images.isEmpty)
        #expect(plain.text == "no images @here MEDIA is a word")
    }

    @Test("a non-image path directive is not an image")
    func nonImage() {
        let content = MessageImages.extract(from: "@image:/h/notes.txt", role: .user)
        #expect(content.images.isEmpty)
    }
}

@Suite("Failed image loads")
struct ImageLoadFailureTests {
    @Test("the placeholder message carries the reason")
    func message() {
        #expect(ImageLoadFailure(reason: "It is no longer available.").message == "Image could not be loaded: It is no longer available.")
    }

    @Test("gateway and transport errors map to plain reasons")
    func describing() {
        #expect(ImageLoadFailure(describing: RPCError(code: 4151, message: "x")).reason == "It is no longer available.")
        #expect(ImageLoadFailure(describing: RPCError(code: 4152, message: "x")).reason == "It is too large to download.")
        #expect(ImageLoadFailure(describing: ChatError.notConnected).reason == "You are not connected right now.")
        #expect(ImageLoadFailure(describing: URLError(.notConnectedToInternet)).reason == "You are offline.")
        #expect(!ImageLoadFailure(describing: ChatError.attachmentRefused).reason.isEmpty)
    }
}

@Suite("Pending attachments and drop intake")
struct PendingAttachmentTests {
    @Test("dropping several images stages each one with a thumbnail, and remove drops only that one")
    func stageAndRemove() {
        var tray = PendingAttachments()
        let first = PendingAttachment(kind: .image, name: "a.jpg", thumbnail: Data([1]))
        let second = PendingAttachment(kind: .image, name: "b.jpg", thumbnail: Data([2]))
        tray.append(first)
        tray.append(second)
        #expect(tray.items.count == 2)
        #expect(tray.items.allSatisfy { $0.thumbnail != nil && $0.state == .uploading })
        tray.remove(first.id)
        #expect(tray.items.map(\.name) == ["b.jpg"])
    }

    @Test("a failed upload keeps its reason and is not sent")
    func failure() {
        var tray = PendingAttachments()
        let item = PendingAttachment(kind: .image, name: "a.jpg", thumbnail: nil)
        tray.append(item)
        tray.setState(.failed(reason: "Attachments need a connection."), for: item.id)
        #expect(tray.items[0].failureReason == "Attachments need a connection.")
        #expect(tray.readyToSend.isEmpty)
        tray.setState(.ready(.image(PromptAttachment(path: "/p.jpg", mime: "image/jpeg"))), for: item.id)
        #expect(tray.readyToSend.count == 1)
    }

    @Test("a drop classifies images, keeps other files as documents and rejects folders, remote URLs and overflow")
    func classify() {
        let urls = [
            URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.HEIC"), URL(fileURLWithPath: "/tmp/c.pdf"),
            URL(fileURLWithPath: "/tmp/folder/", isDirectory: true), URL(string: "https://example.com/x.png")!,
        ]
        let items = DropIntake.classify(urls)
        #expect(items[0] == .image(urls[0]))
        #expect(items[1] == .image(urls[1]))
        #expect(items[2] == .document(urls[2]))
        guard case .rejected(_, let folder) = items[3], case .rejected(_, let remote) = items[4] else {
            Issue.record("folder and remote URL must be rejected")
            return
        }
        #expect(folder == "Folders can't be attached.")
        #expect(remote == "Only files from this Mac can be attached.")
        let overflow = DropIntake.classify(urls, limit: 1)
        #expect(overflow.dropFirst().allSatisfy { if case .rejected = $0 { true } else { false } })
        #expect(DropIntake.rejectionMessage(for: items)?.contains("2 items") == true)
        #expect(DropIntake.rejectionMessage(for: Array(items.prefix(3))) == nil)
    }
}
