#if canImport(UIKit) || canImport(AppKit)
import Foundation
import QuartzCore
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

@MainActor
public final class FrameMonitor: NSObject {
    public static let reportFileName = "pal-hitch.json"
    public static let reportLinePrefix = "PAL_HITCH "
    private static let flushInterval: CFTimeInterval = 2

    private static var running: FrameMonitor?

    public static func startIfRequested() {
        guard running == nil, PalPerf.isRequested() else { return }
        let monitor = FrameMonitor(reportURL: reportLocation())
        guard monitor.start() else { return }
        running = monitor
    }

    private let diagnostics = Diagnostics.osLog()
    private let startedAt = Date()
    private let reportURL: URL
    private var platform = ""
    private var counter = HitchCounter()
    private var link: CADisplayLink?
    private var firstTimestamp: CFTimeInterval?
    private var lastTimestamp: CFTimeInterval?
    private var lastFlush: CFTimeInterval = 0

    private static func reportLocation() -> URL {
        let directory = ProcessInfo.processInfo.environment[PalPerf.directoryKey].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return directory.appending(path: reportFileName)
    }

    private init(reportURL: URL) {
        self.reportURL = reportURL
        super.init()
    }

    private func start() -> Bool {
        #if canImport(UIKit)
        let created = CADisplayLink(target: self, selector: #selector(tick(_:)))
        let platform = "iOS"
        #else
        guard let created = NSScreen.main?.displayLink(target: self, selector: #selector(tick(_:))) else { return false }
        let platform = "macOS"
        #endif
        self.platform = platform
        created.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        created.add(to: .main, forMode: .common)
        link = created
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(resumed), name: Self.activeNotification, object: nil)
        center.addObserver(self, selector: #selector(terminating), name: Self.terminateNotification, object: nil)
        return true
    }

    private static var activeNotification: Notification.Name {
        #if canImport(UIKit)
        UIApplication.didBecomeActiveNotification
        #else
        NSApplication.didBecomeActiveNotification
        #endif
    }

    private static var terminateNotification: Notification.Name {
        #if canImport(UIKit)
        UIApplication.willTerminateNotification
        #else
        NSApplication.willTerminateNotification
        #endif
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        defer { lastTimestamp = now }
        guard let last = lastTimestamp else {
            firstTimestamp = now
            return
        }
        let frameMs = (now - last) * 1000
        switch counter.record(frameMs: frameMs, atSeconds: now - (firstTimestamp ?? now)) {
        case .smooth: break
        case .hitch: PalPerf.event("hitch")
        case .severe: PalPerf.event("hitch.severe")
        case .long:
            PalPerf.event("hitch.severe")
            PalPerf.event("hitch.long", count: Int(frameMs.rounded()))
        }
        if now - lastFlush >= Self.flushInterval {
            lastFlush = now
            flush(synchronously: false)
        }
    }

    @objc private func resumed() {
        lastTimestamp = nil
    }

    @objc private func terminating() {
        flush(synchronously: true)
    }

    private func flush(synchronously: Bool) {
        let duration = (lastTimestamp ?? 0) - (firstTimestamp ?? 0)
        let report = counter.report(platform: platform, startedAt: startedAt, durationSeconds: max(duration, 0))
        guard let data = try? report.jsonData() else { return }
        let url = reportURL
        let diagnostics = diagnostics
        let write: @Sendable () -> Void = {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                diagnostics.warning("perf", "hitch report not written: \(Diagnostics.describe(error))")
            }
        }
        if synchronously {
            write()
            print(Self.reportLinePrefix + (String(data: data, encoding: .utf8) ?? ""))
        } else {
            DispatchQueue.global(qos: .utility).async(execute: write)
        }
    }
}
#endif
