import Darwin
import Foundation
import PalChat
import PalProtocol

struct StageStats: Encodable {
    var medianMs: Double
    var minMs: Double
    var maxMs: Double
    var samplesMs: [Double]

    init(_ samples: [Double]) {
        let ordered = samples.sorted()
        medianMs = ordered.count % 2 == 1 ? ordered[ordered.count / 2] : (ordered[ordered.count / 2 - 1] + ordered[ordered.count / 2]) / 2
        minMs = ordered.first ?? 0
        maxMs = ordered.last ?? 0
        samplesMs = samples
    }
}

struct Report: Encodable {
    var label: String
    var iterations: Int
    var frameBytes: Int
    var wireMessages: Int
    var transcriptItems: Int
    var timelineRows: Int
    var inlineImages: Int
    var cachedItems: Int
    var cacheBytes: Int
    var peakResidentMB: Double
    var stages: [String: StageStats]
    var stageOrder: [String]
    var openPathMs: StageStats
}

func elapsedMs(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}

func timed<T>(_ body: () throws -> T) rethrows -> (T, Double) {
    let clock = ContinuousClock()
    let start = clock.now
    let value = try body()
    return (value, elapsedMs(clock.now - start))
}

struct Rebuilt {
    var rows: Int
    var images: Int
}

func rebuild(_ source: [TranscriptItem]) -> Rebuilt {
    let folded = BotThreadFolding.fold(source, links: [])
    let items = folded.filter { item in
        if case .tool(let call) = item.content { return call.imageGeneration != nil }
        return true
    }
    _ = Set(folded.map(\.id))
    let entries = ChatTimeline.entries(items: items, date: { $0.timestamp }, lastSeen: nil)
    var rows = 0
    var images = 0
    for entry in entries {
        switch entry.item.content {
        case .user(let text, _):
            guard entry.item.inbound.isPerson else { rows += 1; continue }
            let content = MessageImages.extract(from: text, role: .user)
            images += content.images.count
            rows += 1
        case .assistant(let text, _, let streaming):
            if streaming { continue }
            let content = MessageImages.extract(from: text, role: .assistant)
            images += content.images.count
            if content.text.isEmpty, content.images.isEmpty { continue }
            rows += 1
        default:
            rows += 1
        }
    }
    return Rebuilt(rows: rows, images: images)
}

func peakResidentMB() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_maxrss) / 1_048_576
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

let arguments = CommandLine.arguments
guard arguments.count >= 4, let iterations = Int(arguments[3]), iterations > 0 else {
    fail("usage: palperf <label> <frame-file> <iterations>")
}
let label = arguments[1]
guard let text = try? String(contentsOfFile: arguments[2], encoding: .utf8) else { fail("cannot read \(arguments[2])") }
let frameBytes = text.utf8.count

let cacheRoot = FileManager.default.temporaryDirectory.appending(path: "palperf-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
defer { try? FileManager.default.removeItem(at: cacheRoot) }

let order = ["utf8Data", "rpcFrameDecode", "snapshotDecode", "transcriptLoad", "rebuildLive", "cacheBuild", "cacheEncode", "cacheDecode", "rebuildFromCache", "cacheSaveToDisk", "cacheLoadFromDisk"]
var samples: [String: [Double]] = [:]
var openPath: [Double] = []
var wireMessages = 0
var transcriptItems = 0
var timelineRows = 0
var inlineImages = 0
var cachedItems = 0
var cacheBytes = 0

for _ in 0..<(iterations + 1) {
    var record: [String: Double] = [:]
    let (data, utf8Ms) = timed { Data(text.utf8) }
    record["utf8Data"] = utf8Ms
    let (message, frameMs) = try timed { try RPCCodec.decode(data) }
    record["rpcFrameDecode"] = frameMs
    guard case .response(let response) = message, let result = response.result else { fail("frame is not a response") }
    let (snapshot, snapshotMs) = try timed { try result.decoded(as: SessionSnapshot.self) }
    record["snapshotDecode"] = snapshotMs
    var transcript = Transcript()
    let (_, loadMs) = timed { transcript.reconcile(with: snapshot) }
    record["transcriptLoad"] = loadMs
    let (built, rebuildMs) = timed { rebuild(transcript.items) }
    record["rebuildLive"] = rebuildMs
    let (cached, buildMs) = timed { CachedTranscript(sessionID: transcript.sessionID, items: transcript.items, date: { $0.timestamp }) }
    record["cacheBuild"] = buildMs
    guard let cached else { fail("transcript produced no cache") }
    let (encoded, encodeMs) = try timed { try JSONEncoder().encode(cached) }
    record["cacheEncode"] = encodeMs
    let (restored, decodeMs) = try timed { () throws -> [TranscriptItem] in
        try JSONDecoder().decode(CachedTranscript.self, from: encoded).transcriptItems
    }
    record["cacheDecode"] = decodeMs
    let (fromCache, cacheRebuildMs) = timed { rebuild(restored) }
    record["rebuildFromCache"] = cacheRebuildMs

    let store = CacheStore(root: cacheRoot)
    let (_, saveMs) = timed {
        store.save(cached, name: CachedTranscript.cacheName(forBot: "perf"), account: "perf")
        store.drain()
    }
    record["cacheSaveToDisk"] = saveMs
    let (loaded, loadDiskMs) = timed { store.load(CachedTranscript.self, name: CachedTranscript.cacheName(forBot: "perf"), account: "perf") }
    record["cacheLoadFromDisk"] = loadDiskMs
    guard loaded == cached else { fail("cache round trip changed the transcript") }

    wireMessages = snapshot.messages.count
    transcriptItems = transcript.items.count
    timelineRows = built.rows
    inlineImages = built.images
    cachedItems = restored.count
    cacheBytes = encoded.count
    _ = fromCache

    let isWarmup = samples["utf8Data"] == nil
    if isWarmup {
        for key in order { samples[key] = [] }
        continue
    }
    for key in order { samples[key]?.append(record[key] ?? 0) }
    openPath.append(["utf8Data", "rpcFrameDecode", "snapshotDecode", "transcriptLoad", "rebuildLive"].reduce(0) { $0 + (record[$1] ?? 0) })
}

let report = Report(
    label: label,
    iterations: iterations,
    frameBytes: frameBytes,
    wireMessages: wireMessages,
    transcriptItems: transcriptItems,
    timelineRows: timelineRows,
    inlineImages: inlineImages,
    cachedItems: cachedItems,
    cacheBytes: cacheBytes,
    peakResidentMB: peakResidentMB(),
    stages: samples.mapValues { StageStats($0) },
    stageOrder: order,
    openPathMs: StageStats(openPath)
)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
print(String(decoding: try encoder.encode(report), as: UTF8.self))
