@testable import PalChat
import Foundation
import Testing

@Suite("Drop sources")
struct DropSourceTests {
    @Test("a Finder drag is a file URL even when it also carries text and an icon image")
    func fileURL() {
        #expect(DropSource.classify(typeIdentifiers: ["public.file-url", "public.utf8-plain-text", "public.tiff"]) == .fileURL)
    }

    @Test("a screenshot thumbnail or Photos promise exposes the promised image type")
    func filePromise() {
        let identifiers = ["com.apple.NSFilePromiseItemMetaData", "com.apple.pasteboard.promised-file-content-type", "public.jpeg"]
        let source = DropSource.classify(typeIdentifiers: identifiers)
        #expect(source == .image(typeIdentifier: "public.jpeg"))
    }

    @Test("a promised document is content, not an image")
    func promisedDocument() {
        let source = DropSource.classify(typeIdentifiers: ["com.apple.NSFilePromiseItemMetaData", "com.adobe.pdf"])
        #expect(source == .content(typeIdentifier: "com.adobe.pdf"))
    }

    @Test("every image representation is accepted in the preference order png, jpeg, heic, tiff, webp")
    func imagePreference() {
        for type in ["public.png", "public.jpeg", "public.heic", "public.tiff", "org.webmproject.webp"] {
            #expect(DropSource.classify(typeIdentifiers: [type]) == .image(typeIdentifier: type))
        }
        #expect(DropSource.classify(typeIdentifiers: ["public.tiff", "public.heic", "public.png"]) == .image(typeIdentifier: "public.png"))
        #expect(DropSource.classify(typeIdentifiers: ["public.tiff", "public.jpeg"]) == .image(typeIdentifier: "public.jpeg"))
        #expect(DropSource.classify(typeIdentifiers: ["public.tiff", "org.webmproject.webp"]) == .image(typeIdentifier: "public.tiff"))
    }

    @Test("an image type outside the list is still taken through the image fallback")
    func imageFallback() {
        #expect(DropSource.classify(typeIdentifiers: ["com.compuserve.gif"]) == .image(typeIdentifier: "com.compuserve.gif"))
    }

    @Test("a browser image drag prefers the image data over its address and text")
    func browserImage() {
        let source = DropSource.classify(typeIdentifiers: ["public.url", "public.utf8-plain-text", "public.html", "public.png"])
        #expect(source == .image(typeIdentifier: "public.png"))
    }

    @Test("an address alone is a web link, not a file")
    func webLink() {
        #expect(DropSource.classify(typeIdentifiers: ["public.url", "public.utf8-plain-text"]) == .webLink)
        #expect(!DropSource.classify(typeIdentifiers: ["public.url"]).isAttachment)
    }

    @Test("plain text is left to the text field")
    func text() {
        #expect(DropSource.classify(typeIdentifiers: ["public.utf8-plain-text"]) == .text)
        #expect(DropSource.classify(typeIdentifiers: ["public.rtf", "public.utf8-plain-text"]) == .text)
    }

    @Test("an unknown type is unsupported and an empty drag too")
    func unsupported() {
        #expect(DropSource.classify(typeIdentifiers: ["com.example.unknown-card"]) == .unsupported)
        #expect(DropSource.classify(typeIdentifiers: []) == .unsupported)
    }

    @Test("only files, images and content make the text field hand the drag to the pane")
    func forwarding() {
        #expect(DropSource.carriesAttachment(typeIdentifiers: ["public.file-url", "public.utf8-plain-text"]))
        #expect(DropSource.carriesAttachment(typeIdentifiers: ["public.url", "public.utf8-plain-text", "public.png"]))
        #expect(!DropSource.carriesAttachment(typeIdentifiers: ["public.url", "public.utf8-plain-text"]))
        #expect(!DropSource.carriesAttachment(typeIdentifiers: ["public.utf8-plain-text"]))
    }

    @Test("every failure has a plain reason, and several are summarised once")
    func failures() {
        #expect(DropFailure.tooLarge(limitMegabytes: 24).message == "That file is over 24 MB, so it was not attached.")
        #expect(DropFailure.unsupported.message == "This item can't be attached.")
        #expect(DropFailure.webLinkOnly.message.contains("web link"))
        #expect(DropFailure.unreadable.message == "That item couldn't be read.")
        #expect(DropFailure.summary(of: []) == nil)
        #expect(DropFailure.summary(of: [.unsupported]) == "This item can't be attached.")
        #expect(DropFailure.summary(of: [.unsupported, .unreadable]) == "2 items weren't attached. This item can't be attached.")
    }

    @Test("an empty batch has nothing to attach and nothing to report")
    func emptyBatch() {
        #expect(DropBatch().isEmpty)
        #expect(!DropBatch(failures: [.unsupported]).isEmpty)
    }

    @Test("the persisted drop log names a source and a failure without leaking a file name")
    func logLabels() {
        #expect(DropSource.fileURL.label == "fileURL")
        #expect(DropSource.image(typeIdentifier: "public.png").label == "image(public.png)")
        #expect(DropSource.unsupported.label == "unsupported")
        #expect(DropFailure.rejected("secret-name.pdf").label == "rejected")
        #expect(DropFailure.tooLarge(limitMegabytes: 24).label == "tooLarge")
    }

    @Test("a pasteboard shape is accepted when any item is a file, an image, a document or a file promise")
    func acceptsDrag() {
        let finder = ["public.file-url", "public.utf8-plain-text", "public.tiff"]
        let safari = ["public.url", "public.utf8-plain-text", "public.html", "public.png", "public.tiff"]
        let screenshotPromise = ["com.apple.NSFilePromiseItemMetaData", "com.apple.pasteboard.promised-file-content-type"]
        let photosPromise = ["com.apple.NSFilePromiseItemMetaData", "com.apple.pasteboard.promised-file-url", "dyn.ah62d4rv4gu8"]
        for shape in [finder, safari, screenshotPromise, photosPromise, ["public.jpeg"], ["com.adobe.pdf"], ["public.heic"]] {
            #expect(DropSource.acceptsDrag(items: [shape]), "\(shape)")
        }
        #expect(DropSource.acceptsDrag(items: [["public.utf8-plain-text"], finder]))
    }

    @Test("text, a bare link and an empty pasteboard are refused with a stated reason")
    func refusesDrag() {
        #expect(!DropSource.acceptsDrag(items: [["public.utf8-plain-text", "public.rtf"]]))
        #expect(!DropSource.acceptsDrag(items: [["public.url", "public.utf8-plain-text"]]))
        #expect(!DropSource.acceptsDrag(items: []))
        #expect(DropSource.refusal(items: []) == "empty-pasteboard")
        #expect(DropSource.refusal(items: [["public.utf8-plain-text"]]) == "no-attachment-source")
        #expect(DropSource.refusal(items: [["public.png"]]) == "none")
    }

    @Test("the registered set holds files, images and documents, and no text or bare link type")
    func registeredSet() {
        let registered = DropSource.registeredTypeIdentifiers
        #expect(registered.contains("public.file-url") && registered.contains("public.image") && registered.contains("com.adobe.pdf"))
        for identifier in ["public.item", "public.data", "public.content", "public.url", "public.utf8-plain-text", "public.text"] {
            #expect(!registered.contains(identifier), "\(identifier)")
        }
    }

    @Test("a promised file reports a promise marker so the receiver, not a data read, loads it")
    func promiseMarkers() {
        #expect(DropSource.isFilePromise(typeIdentifiers: ["com.apple.NSFilePromiseItemMetaData", "public.png"]))
        #expect(!DropSource.isFilePromise(typeIdentifiers: ["public.png", "public.tiff"]))
    }
}
