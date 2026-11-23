@testable import PalChat
import Foundation
import Testing

@Suite("Conversation media list and viewer")
struct MediaViewerStateTests {
    private let first = MediaReference(id: "v1", name: "first.mp4", kind: .video)
    private let second = MediaReference(id: "v2", name: "second.mov", kind: .video)
    private let third = MediaReference(id: "v3", name: "third.mp4", kind: .video)
    private let song = MediaReference(id: "a1", name: "song.mp3", kind: .audio)
    private let report = MediaReference(id: "p1", name: "report.pdf", kind: .pdf)

    private func rows() -> [ConversationMediaRow] {
        [
            ConversationMediaRow(rowID: "u1", media: [first, song, second]),
            ConversationMediaRow(rowID: "a1", media: [report, third]),
            ConversationMediaRow(rowID: "g1", media: [first]),
        ]
    }

    private func viewer(opening media: MediaReference, inRow rowID: String) throws -> MediaViewerState {
        try #require(ConversationMediaList.viewer(opening: media, inRow: rowID, rows: rows()))
    }

    @Test("only videos are listed, in transcript order")
    func listsVideosInOrder() {
        let items = ConversationMediaList.list(from: rows())
        #expect(items.map(\.reference.name) == ["first.mp4", "second.mov", "third.mp4", "first.mp4"])
        #expect(!items.contains { $0.reference.kind != .video })
    }

    @Test("ids are scoped to their row so the same video twice is two entries")
    func rowScopedIDs() {
        let items = ConversationMediaList.list(from: rows())
        #expect(Set(items.map(\.id)).count == items.count)
        #expect(items.first?.id == ConversationMediaList.itemID(rowID: "u1", media: first))
        #expect(items.last?.id == ConversationMediaList.itemID(rowID: "g1", media: first))
        #expect(items.first?.id != items.last?.id)
    }

    @Test("rows without video contribute nothing")
    func noVideo() {
        let items = ConversationMediaList.list(from: [ConversationMediaRow(rowID: "r", media: [song, report])])
        #expect(items.isEmpty)
        #expect(ConversationMediaList.list(from: []).isEmpty)
    }

    @Test("opening a video lands on its index")
    func opensAtIndex() throws {
        let atFirst = try viewer(opening: first, inRow: "u1")
        let atSecond = try viewer(opening: second, inRow: "u1")
        let atThird = try viewer(opening: third, inRow: "a1")
        let landed: [Int] = [atFirst.index, atSecond.index, atThird.index]
        #expect(landed == [0, 1, 2])
    }

    @Test("the same video opened from its second row lands on the second entry")
    func opensRightRow() throws {
        let state = try viewer(opening: first, inRow: "g1")
        #expect(state.index == 3)
        #expect(state.anchorRowID == "g1")
        #expect(state.current.reference.id == "v1")
    }

    @Test("an unknown video, an audio file, or a row that lacks the video does not open")
    func refusesToOpen() {
        let unknown = MediaReference(id: "zz", name: "zz.mp4", kind: .video)
        #expect(ConversationMediaList.viewer(opening: unknown, inRow: "u1", rows: rows()) == nil)
        #expect(ConversationMediaList.viewer(opening: second, inRow: "g1", rows: rows()) == nil)
        #expect(ConversationMediaList.viewer(opening: first, inRow: "missing", rows: rows()) == nil)
        #expect(ConversationMediaList.viewer(opening: song, inRow: "u1", rows: rows()) == nil)
        #expect(ConversationMediaList.viewer(opening: first, inRow: "u1", rows: []) == nil)
    }

    @Test("next and previous stop at the ends instead of wrapping")
    func clamps() throws {
        var state = try viewer(opening: first, inRow: "u1")
        #expect(!state.canGoPrevious)
        #expect(state.canGoNext)
        state.goPrevious()
        #expect(state.index == 0)
        for _ in 0..<10 { state.goNext() }
        #expect(state.index == state.items.count - 1)
        #expect(state.canGoPrevious)
        #expect(!state.canGoNext)
        state.goPrevious()
        #expect(state.current.id == state.items[state.items.count - 2].id)
        #expect(state.title == state.current.reference.name)
    }

    @Test("navigating never moves the anchor row")
    func anchorStays() throws {
        var state = try viewer(opening: second, inRow: "u1")
        state.goNext()
        state.goNext()
        #expect(state.anchorRowID == "u1")
    }

    @Test("the stepper and position label show only with more than one video")
    func stepper() throws {
        let single = try #require(ConversationMediaList.viewer(
            opening: first, inRow: "u1", rows: [ConversationMediaRow(rowID: "u1", media: [first, song])]
        ))
        #expect(!single.showsStepper)
        #expect(single.positionLabel == nil)

        var many = try viewer(opening: first, inRow: "u1")
        #expect(many.showsStepper)
        let opening = try #require(many.positionLabel)
        #expect(opening.contains("1") && opening.contains("4"))
        many.goNext()
        let next = try #require(many.positionLabel)
        #expect(next.contains("2") && next.contains("4"))
    }

    @Test("recording stores a temporary copy for a known item and ignores an unknown one")
    func recordsFiles() throws {
        var state = try viewer(opening: first, inRow: "u1")
        let url = URL(fileURLWithPath: "/tmp/pal-media/abc/first.mp4")
        let id = state.current.id
        state.record(url, for: id)
        #expect(state.file(for: id) == url)
        state.record(URL(fileURLWithPath: "/tmp/other.mp4"), for: "nope/none")
        #expect(state.file(for: "nope/none") == nil)
        #expect(state.files.count == 1)
    }

    @Test("closing returns every recorded copy and clears the state")
    func closeReturnsFiles() throws {
        var state: MediaViewerState? = try viewer(opening: first, inRow: "u1")
        let one = URL(fileURLWithPath: "/tmp/pal-media/1/first.mp4")
        let two = URL(fileURLWithPath: "/tmp/pal-media/2/second.mov")
        state?.record(one, for: ConversationMediaList.itemID(rowID: "u1", media: first))
        state?.goNext()
        state?.record(two, for: ConversationMediaList.itemID(rowID: "u1", media: second))
        let leftovers = MediaViewerState.close(&state)
        #expect(Set(leftovers) == Set([one, two]))
        #expect(state == nil)
    }

    @Test("closing a viewer with nothing recorded, or no viewer, returns nothing")
    func closeEmpty() throws {
        var untouched: MediaViewerState? = try viewer(opening: first, inRow: "u1")
        let fromUntouched = MediaViewerState.close(&untouched)
        #expect(fromUntouched.isEmpty)
        #expect(untouched == nil)
        var closed: MediaViewerState?
        let fromClosed = MediaViewerState.close(&closed)
        #expect(fromClosed.isEmpty)
        #expect(closed == nil)
    }
}
