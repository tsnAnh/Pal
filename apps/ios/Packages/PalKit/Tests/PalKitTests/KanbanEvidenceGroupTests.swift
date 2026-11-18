import Foundation
import PalKanban
import PalProtocol
import PalTransport
import Testing

@Suite("Kanban evidence groups")
struct KanbanEvidenceGroupTests {
    private static let pull1 = "https://github.com/TitoniumLab/SmileWallpaper/pull/1"

    private func evidence(_ id: Int, _ kind: String, payload: [String: JSONValue] = [:], run: Int = 1, at: Int? = nil) throws -> KanbanEvidence {
        var object: [String: JSONValue] = [
            "evidence_id": .int(id), "run_id": .int(run), "kind": .string(kind), "payload": .object(payload),
            "producer_profile": "bot", "source": "github",
        ]
        if let at { object["observed_at"] = .int(at) }
        return try #require(KanbanEvidence(.object(object)))
    }

    private func pullRequest(_ id: Int, _ kind: String, _ url: String, run: Int = 1, at: Int? = nil) throws -> KanbanEvidence {
        try evidence(id, kind, payload: ["pr_url": .string(url)], run: run, at: at)
    }

    private func repoSetup() throws -> [KanbanEvidence] {
        try [322, 323, 334, 335].flatMap { run in
            [
                try pullRequest(run * 10, "pr_published", Self.pull1, run: run, at: 1000 + run),
                try pullRequest(run * 10 + 1, "pr_merged", Self.pull1, run: run, at: 1000 + run),
            ]
        }
    }

    @Test("the same pull request published and merged on four runs collapses to two groups of four, newest first")
    func repoSetupCase() throws {
        let items = try repoSetup()
        #expect(items.count == 8)
        let groups = KanbanEvidenceGroup.groups(items)
        #expect(groups.map(\.kind) == [.prMerged, .prPublished], "equal times fall back to the higher evidence id")
        #expect(groups.map(\.count) == [4, 4])
        #expect(groups.map(\.latest.runID) == [335, 335])
        #expect(groups.map(\.latest.evidenceID) == [3351, 3350])
        #expect(groups.allSatisfy { $0.url?.absoluteString == Self.pull1 })
        #expect(Set(groups.map(\.id)).count == groups.count, "ids are unique so a list can key on them")
    }

    @Test("input order does not change the groups")
    func orderIndependent() throws {
        let items = try repoSetup()
        #expect(KanbanEvidenceGroup.groups(items.reversed()) == KanbanEvidenceGroup.groups(items))
    }

    @Test("groups order by the newest item, with a missing time counting as oldest")
    func newestFirst() throws {
        let groups = KanbanEvidenceGroup.groups([
            try pullRequest(1, "pr_published", "https://github.com/a/b/pull/1", at: 500),
            try pullRequest(2, "pr_published", "https://github.com/a/b/pull/2", at: 900),
            try pullRequest(9, "pr_published", "https://github.com/a/b/pull/3"),
            try pullRequest(3, "pr_published", "https://github.com/a/b/pull/1", at: 950),
        ])
        #expect(groups.map { $0.url?.lastPathComponent } == ["1", "2", "3"])
        #expect(groups.map(\.count) == [2, 1, 1])
        #expect(groups.first?.latest.evidenceID == 3)
    }

    @Test("more groups than the visible limit are all returned, so a view can fold the rest")
    func overLimit() throws {
        let items = try (1...5).map { try pullRequest($0, "pr_published", "https://github.com/a/b/pull/\($0)", at: $0) }
        let groups = KanbanEvidenceGroup.groups(items)
        #expect(KanbanEvidenceGroup.visibleLimit == 3)
        #expect(groups.count == 5)
        #expect(groups.map(\.latest.evidenceID) == [5, 4, 3, 2, 1])
        #expect(groups.prefix(KanbanEvidenceGroup.visibleLimit).map(\.latest.evidenceID) == [5, 4, 3])
        #expect(groups.dropFirst(KanbanEvidenceGroup.visibleLimit).map(\.latest.evidenceID) == [2, 1], "the rest is what a view folds")
    }

    @Test("one kind with different links stays separate, and a repeat of the same link folds")
    func differentLinks() throws {
        let groups = KanbanEvidenceGroup.groups([
            try pullRequest(1, "pr_published", "https://github.com/a/b/pull/1", at: 1),
            try pullRequest(2, "pr_published", "https://github.com/a/b/pull/2", at: 2),
            try pullRequest(3, "pr_published", "https://github.com/a/b/pull/1", at: 3),
        ])
        #expect(groups.count == 2)
        #expect(Dictionary(uniqueKeysWithValues: groups.map { ($0.url?.lastPathComponent ?? "", $0.count) }) == ["1": 2, "2": 1])
    }

    @Test("items without a link group by their summary, and kinds never mix")
    func summaryGroups() throws {
        let groups = KanbanEvidenceGroup.groups([
            try evidence(1, "artifact_built", payload: ["name": "app.zip"], at: 1),
            try evidence(2, "artifact_built", payload: ["name": "app.zip"], at: 2),
            try evidence(3, "artifact_built", payload: ["name": "other.zip"], at: 3),
            try evidence(4, "execution_ref", at: 4),
            try evidence(5, "execution_ref", at: 5),
        ])
        #expect(groups.map(\.kind) == [.executionRef, .artifactBuilt, .artifactBuilt])
        #expect(groups.map(\.count) == [2, 1, 2])
        #expect(groups.map(\.summary) == [nil, "other.zip", "app.zip"])
        #expect(groups.allSatisfy { $0.url == nil })
        #expect(Set(groups.map(\.id)).count == 3)
    }

    @Test("no evidence has no groups")
    func empty() {
        #expect(KanbanEvidenceGroup.groups([]).isEmpty)
    }

    @Test("a GitHub pull request reads as number and repo, anything else as host and path", arguments: [
        ("https://github.com/acme/pal/pull/12", "#12 · pal", "acme/pal"),
        ("https://github.com/acme/pal/pull/12/files", "#12 · pal", "acme/pal"),
        ("https://GitHub.com/acme/pal/pull/7", "#7 · pal", "acme/pal"),
        ("https://github.com/acme/pal", "github.com", "acme/pal"),
        ("https://github.com/acme/pal/issues/12", "github.com", "acme/pal/issues/12"),
        ("https://github.com/acme/pal/pull/x", "github.com", "acme/pal/pull/x"),
        ("https://gitlab.example.com/g/p/-/merge_requests/3", "gitlab.example.com", "g/p/-/merge_requests/3"),
        ("https://example.com", "example.com", "https://example.com"),
        ("https://example.com/", "example.com", "https://example.com/"),
    ])
    func pullRequestRow(_ raw: String, _ title: String, _ subtitle: String) throws {
        let row = KanbanPresentation.pullRequestRow(try #require(URL(string: raw)))
        #expect(row.title == title)
        #expect(row.subtitle == subtitle)
    }
}
