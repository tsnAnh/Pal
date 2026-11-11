import Foundation
import HermesChat
import Testing

@Suite("Media link")
struct MediaLinkTests {
    private func url(_ string: String) -> URL {
        URL(string: string)!
    }

    @Test func inlinePlayableVideos() {
        for link in [
            "https://cdn.example.com/a.mp4",
            "http://cdn.example.com/a.M4V",
            "https://cdn.example.com/a.mov?token=1",
            "https://cdn.example.com/live/index.m3u8",
            "file:///tmp/clip.MP4",
        ] {
            #expect(MediaLink.isInlinePlayableVideo(url(link)), "\(link)")
            #expect(MediaLink.isVideoLink(url(link)), "\(link)")
        }
    }

    @Test func recognisedButNotInlinePlayable() {
        for link in ["https://cdn.example.com/a.webm", "https://cdn.example.com/a.MKV", "https://cdn.example.com/a.avi"] {
            #expect(!MediaLink.isInlinePlayableVideo(url(link)), "\(link)")
            #expect(MediaLink.isVideoLink(url(link)), "\(link)")
        }
    }

    @Test func nonVideoLinks() {
        for link in [
            "https://example.com/a.png",
            "https://example.com/video",
            "https://example.com/mp4",
            "https://example.com/a.mp4.txt",
            "ftp://example.com/a.mp4",
            "data:video/mp4;base64,AAAA",
            "javascript:void(0)",
        ] {
            #expect(!MediaLink.isInlinePlayableVideo(url(link)), "\(link)")
            #expect(!MediaLink.isVideoLink(url(link)), "\(link)")
        }
    }
}
