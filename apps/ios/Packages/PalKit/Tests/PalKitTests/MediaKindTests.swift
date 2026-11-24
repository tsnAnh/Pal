@testable import PalChat
import CoreGraphics
import Foundation
import Testing

@Suite("Media kind, limits and tile metrics")
struct MediaKindTests {
    @Test("every file extension maps to its kind regardless of case")
    func extensionMap() {
        let expected: [MediaKind: [String]] = [
            .image: ["a.png", "b.JPG", "c.heic", "d.webp"],
            .video: ["a.mp4", "b.MOV", "c.m4v", "d.webm", "e.mkv", "f.avi"],
            .audio: ["a.mp3", "b.WAV", "c.m4a", "d.aac", "e.flac", "f.ogg", "g.opus", "h.aiff", "i.AIFF"],
            .pdf: ["a.pdf", "b.PDF"],
            .archive: ["a.zip", "b.TAR", "c.gz", "d.7z", "e.rar", "f.tar.gz", "g.zst"],
            .document: ["a.txt", "b.md", "c.CSV", "d.docx", "e.xlsx", "f.json", "g.pptx"],
            .other: ["a.bin", "noextension", "b.exe", "c.unknownext", ""],
        ]
        for (kind, names) in expected {
            for name in names {
                #expect(MediaKind(fileName: name) == kind, "\(name) should be \(kind)")
            }
        }
    }

    @Test("a mime type wins over the file extension")
    func mimeOverridesExtension() {
        #expect(MediaKind(fileName: "blob.bin", mimeType: "video/mp4") == .video)
        #expect(MediaKind(fileName: "clip.mp4", mimeType: "image/png") == .image)
        #expect(MediaKind(fileName: "x.bin", mimeType: "audio/mpeg") == .audio)
        #expect(MediaKind(fileName: "x.bin", mimeType: "application/pdf") == .pdf)
    }

    @Test("mime parameters and casing do not change the kind")
    func mimeParameters() {
        #expect(MediaKind(fileName: "x.bin", mimeType: "video/mp4; codecs=avc1.42E01E") == .video)
        #expect(MediaKind(fileName: "x.bin", mimeType: "Text/Plain; charset=utf-8") == .document)
        #expect(MediaKind(mimeType: "AUDIO/MP4 ;x=y") == .audio)
    }

    @Test("a generic or unknown mime type falls back to the extension")
    func mimeFallsBack() {
        #expect(MediaKind(mimeType: "application/octet-stream") == nil)
        #expect(MediaKind(fileName: "clip.mp4", mimeType: "application/octet-stream") == .video)
        #expect(MediaKind(fileName: "song.flac", mimeType: "application/x-unheard-of") == .audio)
        #expect(MediaKind(fileName: "noextension", mimeType: "application/octet-stream") == .other)
    }

    @Test("document and archive mime types are recognised")
    func documentAndArchiveMime() {
        #expect(MediaKind(fileName: "x.bin", mimeType: "text/plain") == .document)
        #expect(MediaKind(fileName: "x.bin", mimeType: "application/json") == .document)
        #expect(MediaKind(fileName: "x.bin", mimeType: "application/zip") == .archive)
        #expect(MediaKind(fileName: "x.bin", mimeType: "application/gzip") == .archive)
        #expect(MediaKind(fileName: "x.bin", mimeType: "application/x-7z-compressed") == .archive)
    }

    @Test("only video and audio render inline")
    func rendersInline() {
        for kind in MediaKind.allCases {
            #expect(kind.rendersInline == (kind == .video || kind == .audio), "\(kind)")
        }
    }

    @Test("split routes video and audio to media and keeps order and ids")
    func splitRoutes() {
        let paths = ["/h/a.mp4", "/h/b.pdf", "/h/c.mp3", "/h/d.zip", "/h/e.MOV", "/h/f.txt"]
        let files = paths.map { FileReference(path: $0, directive: "MEDIA:\($0)") }
        let (media, rest) = MediaReference.split(files)
        #expect(media.map(\.name) == ["a.mp4", "c.mp3", "e.MOV"])
        #expect(media.map(\.kind) == [.video, .audio, .video])
        #expect(media.map(\.id) == [files[0].id, files[2].id, files[4].id])
        #expect(rest == [files[1], files[3], files[5]])
    }

    @Test("split of nothing or of non-media files yields no media")
    func splitEmpty() {
        #expect(MediaReference.split([]).media.isEmpty)
        let file = FileReference(path: "/h/a.pdf", directive: "MEDIA:/h/a.pdf")
        let (media, rest) = MediaReference.split([file])
        #expect(media.isEmpty)
        #expect(rest == [file])
    }

    @Test("asset refs are unchanged for video and files")
    func assetRefsUnchanged() {
        let video = "/h/cache/clip.mp4"
        let videoFile = FileReference(path: video, directive: "MEDIA:\(video)")
        #expect(videoFile.id == MessageFiles.assetRef(forHostPath: video))
        #expect(videoFile.id == ImageReference.digest(of: Data("media\u{0}\(video)".utf8)))
        #expect(MediaReference(file: videoFile).id == videoFile.id)

        let pdf = "/h/cache/report.pdf"
        let pdfFile = FileReference(path: pdf, directive: "MEDIA:\(pdf)")
        #expect(pdfFile.id == ImageReference.digest(of: Data("file\u{0}\(pdf)".utf8)))
    }

    @Test("limits are 32 MB for thumbnails and 200 MB for downloads")
    func limitValues() {
        #expect(MediaLimits.thumbnailSourceBytes == 32_000_000)
        #expect(MediaLimits.downloadBytes == 200_000_000)
    }

    @Test("limit boundaries are inclusive")
    func limitBoundaries() {
        #expect(MediaLimits.allowsThumbnail(size: 0))
        #expect(MediaLimits.allowsThumbnail(size: 32_000_000))
        #expect(!MediaLimits.allowsThumbnail(size: 32_000_001))
        #expect(MediaLimits.allowsDownload(size: 200_000_000))
        #expect(!MediaLimits.allowsDownload(size: 200_000_001))
    }

    @Test("durations read as clock times")
    func durationLabels() {
        #expect(MediaDuration.label(0) == "0:00")
        #expect(MediaDuration.label(-3) == "0:00")
        #expect(MediaDuration.label(.nan) == "0:00")
        #expect(MediaDuration.label(5) == "0:05")
        #expect(MediaDuration.label(65.4) == "1:05")
        #expect(MediaDuration.label(3600) == "1:00:00")
        #expect(MediaDuration.label(3725) == "1:02:05")
    }

    @Test("a poster tile keeps the 4:3 single size")
    func tileMetrics() {
        #expect(MediaTileMetrics.single == 220)
        #expect(MediaTileMetrics.singleHeight == MediaTileMetrics.single * 0.75)
    }
}

@Suite("Media poster aspect")
struct MediaPosterAspectTests {
    @Test("the real width and height set the tile height")
    func realRatio() {
        #expect(MediaPosterAspect.height(forWidth: 220, mediaWidth: 1920, mediaHeight: 1080) == 124)
        #expect(MediaPosterAspect.height(forWidth: 220, mediaWidth: 1000, mediaHeight: 1000) == 220)
        #expect(MediaPosterAspect.height(forWidth: 220, mediaWidth: 4, mediaHeight: 3) == MediaTileMetrics.singleHeight)
    }

    @Test("missing or empty dimensions keep the 4:3 placeholder")
    func placeholder() {
        let placeholder = MediaTileMetrics.singleHeight
        #expect(MediaPosterAspect.height(forWidth: 220, mediaWidth: nil, mediaHeight: nil) == placeholder)
        #expect(MediaPosterAspect.height(forWidth: 220, mediaWidth: 1920, mediaHeight: nil) == placeholder)
        #expect(MediaPosterAspect.height(forWidth: 220, mediaWidth: 0, mediaHeight: 1080) == placeholder)
        #expect(MediaPosterAspect.height(forWidth: 220, mediaWidth: 1920, mediaHeight: -1) == placeholder)
    }

    @Test("extreme shapes are clamped so a row never grows past a portrait or shrinks past a strip")
    func clamped() {
        #expect(MediaPosterAspect.ratio(width: 9, height: 16) == MediaPosterAspect.narrowest)
        #expect(MediaPosterAspect.ratio(width: 21, height: 9) == MediaPosterAspect.widest)
        #expect(MediaPosterAspect.height(forWidth: 220, mediaWidth: 9, mediaHeight: 16) == (220 / MediaPosterAspect.narrowest).rounded())
        #expect(MediaPosterAspect.height(forWidth: 220, mediaWidth: 100, mediaHeight: 1) == 110)
    }
}
