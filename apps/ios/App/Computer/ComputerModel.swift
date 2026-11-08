import CoreGraphics
import Foundation
import HermesBotProfile
import HermesRFB
import Observation
import UIKit

enum ComputerPhase: Equatable {
    case connecting
    case live
    case unavailable(ComputerFailure)
    case lost
}

private enum ComputerInput: Sendable {
    case pointer(buttons: UInt8, x: Int, y: Int)
    case key(UInt32, down: Bool)
    case text(String)
    case clipboard(String)
}

@MainActor
@Observable
final class ComputerModel {
    static let reconnectDelays: [Duration] = [.milliseconds(400), .seconds(1), .seconds(2)]
    static let copyWait: Duration = .milliseconds(1500)

    private(set) var phase = ComputerPhase.connecting
    private(set) var hasControl = false
    private(set) var isTakingControl = false
    private(set) var attempt = 0
    private(set) var frame: CGImage?
    private(set) var remoteSize: RFBSize?
    private(set) var pointerRemote: CGPoint?
    var trackpad = false
    var trackpadButtons: UInt8 = 0
    private(set) var recenterToken = 0
    var keyboardShown = false
    var showsHelp = false
    var toast: String?

    let botName: String
    private let service: ComputerService
    private let openStream: @Sendable (ComputerObservation) async throws -> any RFBTransport
    private var session: RFBSession?
    private var viewerID: String?
    private var pendingAskAt: Double?
    private var input: AsyncStream<ComputerInput>.Continuation?
    private var pressed: UInt8 = 0
    private var lastRemote: CGPoint?
    private var reopening = false
    private var latestClipboard: String?
    private var clipboardWaiter: CheckedContinuation<String?, Never>?

    init(
        botName: String,
        service: ComputerService,
        openStream: @escaping @Sendable (ComputerObservation) async throws -> any RFBTransport
    ) {
        self.botName = botName
        self.service = service
        self.openStream = openStream
    }

    var canAct: Bool { phase == .live }

    var statusLabel: String {
        switch phase {
        case .connecting: "connecting"
        case .live: hasControl ? "controlling" : "watching"
        case .unavailable: "unavailable"
        case .lost: "lost"
        }
    }

    func run() async {
        var failures = 0
        while !Task.isCancelled {
            phase = .connecting
            let observation: ComputerObservation
            do {
                observation = try await service.prepare(for: botName, viewerID: viewerID)
            } catch is CancellationError {
                break
            } catch {
                phase = .unavailable(ComputerFailure.classify(error))
                break
            }
            viewerID = observation.viewerID
            let end = await stream(observation, onReady: { failures = 0 })
            guard let end, !Task.isCancelled, end != .closed || reopening else { break }
            reopening = false
            hasControl = false
            switch end {
            case .controlTaken:
                toast = String(localized: "Another device took control")
            case .desktopGone:
                phase = .unavailable(.unavailable)
                return
            case .closed:
                continue
            case .failed, .lost, .ticketRejected:
                guard failures < Self.reconnectDelays.count else {
                    phase = .lost
                    return
                }
                try? await Task.sleep(for: Self.reconnectDelays[failures])
                failures += 1
            }
        }
        await closeSession()
    }

    func retry() {
        attempt += 1
    }

    func takeControl() async {
        guard canAct, !hasControl, !isTakingControl, let viewerID else { return }
        isTakingControl = true
        defer { isTakingControl = false }
        do {
            let lease = try await service.takeControl(for: botName, viewerID: viewerID)
            hasControl = lease.isHeld(by: viewerID)
        } catch ComputerFailure.staleViewer {
            toast = String(localized: "Couldn't take control. Try again.")
            self.viewerID = nil
            reopening = true
            await session?.close()
        } catch ComputerFailure.notAllowed {
            toast = String(localized: "You can't control this computer")
        } catch {
            toast = String(localized: "Couldn't take control")
        }
    }

    func handBack() async {
        guard hasControl, let viewerID else { return }
        releasePressedButtons()
        trackpad = false
        keyboardShown = false
        do {
            _ = try await service.handBack(for: botName, viewerID: viewerID, resolvingAskAt: pendingAskAt)
            pendingAskAt = nil
            hasControl = false
        } catch ComputerFailure.staleViewer {
            hasControl = false
        } catch {
            toast = String(localized: "Couldn't hand it back")
        }
    }

    func pointer(_ point: CGPoint, buttons: UInt8) {
        guard hasControl else { return }
        pressed = buttons
        lastRemote = point
        input?.yield(.pointer(buttons: buttons, x: Int(point.x.rounded()), y: Int(point.y.rounded())))
    }

    func click(at point: CGPoint, button: UInt8 = RFBButtons.left) {
        pointer(point, buttons: 0)
        pointer(point, buttons: button)
        pointer(point, buttons: 0)
    }

    func scroll(at point: CGPoint, up: Bool, notches: Int) {
        let button = up ? RFBButtons.scrollUp : RFBButtons.scrollDown
        for _ in 0..<notches {
            pointer(point, buttons: button)
            pointer(point, buttons: 0)
        }
    }

    func recenterPointer() {
        recenterToken += 1
    }

    func movePointerIndicator(to point: CGPoint?) {
        pointerRemote = point
    }

    func type(_ text: String) {
        guard hasControl else { return }
        input?.yield(.text(text))
    }

    func press(_ keysym: UInt32, down: Bool) {
        guard hasControl else { return }
        input?.yield(.key(keysym, down: down))
    }

    func tap(key keysym: UInt32) {
        press(keysym, down: true)
        press(keysym, down: false)
    }

    func pasteFromPhone() {
        guard hasControl, let text = UIPasteboard.general.string, !text.isEmpty else {
            toast = String(localized: "Nothing to paste")
            return
        }
        input?.yield(.clipboard(text))
        input?.yield(.key(Self.controlLeft, down: true))
        input?.yield(.key(0x76, down: true))
        input?.yield(.key(0x76, down: false))
        input?.yield(.key(Self.controlLeft, down: false))
    }

    func copyToPhone() async {
        guard hasControl else { return }
        latestClipboard = nil
        input?.yield(.key(Self.controlLeft, down: true))
        input?.yield(.key(0x63, down: true))
        input?.yield(.key(0x63, down: false))
        input?.yield(.key(Self.controlLeft, down: false))
        let copied = await awaitClipboard()
        if let copied, !copied.isEmpty {
            UIPasteboard.general.string = copied
            toast = String(localized: "Copied to phone")
        } else {
            toast = String(localized: "Nothing to copy")
        }
    }

    private static let controlLeft: UInt32 = 0xFFE3

    private func awaitClipboard() async -> String? {
        await withCheckedContinuation { continuation in
            clipboardWaiter = continuation
            Task { [weak self] in
                try? await Task.sleep(for: Self.copyWait)
                self?.resolveClipboardWaiter(nil)
            }
        }
    }

    private func resolveClipboardWaiter(_ text: String?) {
        guard let waiter = clipboardWaiter else { return }
        clipboardWaiter = nil
        waiter.resume(returning: text)
    }

    private func releasePressedButtons() {
        guard pressed != 0, let point = lastRemote else { return }
        pointer(point, buttons: 0)
    }

    private func stream(_ observation: ComputerObservation, onReady: () -> Void) async -> RFBSessionEnd? {
        let transport: any RFBTransport
        do {
            transport = try await openStream(observation)
        } catch {
            return .lost
        }
        let session = RFBSession(transport: transport)
        self.session = session
        let (inputStream, continuation) = AsyncStream.makeStream(of: ComputerInput.self)
        input = continuation
        let pump = Task { await session.run() }
        let sender = Task { for await item in inputStream { await Self.apply(item, to: session) } }
        let renderer = Task { for await framebuffer in session.frames { await self.render(framebuffer) } }
        defer {
            continuation.finish()
            input = nil
            sender.cancel()
            renderer.cancel()
            pump.cancel()
            self.session = nil
            resolveClipboardWaiter(nil)
        }
        for await event in session.events {
            switch event {
            case .ready(let size, _):
                remoteSize = size
                phase = .live
                onReady()
                hasControl = observation.lease.isHeld(by: observation.viewerID)
                if !hasControl, observation.lease.ask != nil, !observation.lease.humanHolds {
                    pendingAskAt = observation.lease.askAt
                    Task { await takeControl() }
                }
            case .resized(let size):
                remoteSize = size
            case .clipboard(let text):
                latestClipboard = text
                resolveClipboardWaiter(text)
            case .bell:
                break
            case .ended(let end):
                return end
            }
        }
        return nil
    }

    private func render(_ framebuffer: RFBFramebuffer) async {
        let image = await Task.detached(priority: .userInitiated) { framebuffer.makeImage() }.value
        if let image { frame = image }
    }

    private func closeSession() async {
        hasControl = false
        await session?.close()
    }

    private static func apply(_ item: ComputerInput, to session: RFBSession) async {
        switch item {
        case .pointer(let buttons, let x, let y): await session.pointer(buttons: buttons, x: x, y: y)
        case .key(let keysym, let down): await session.key(keysym, down: down)
        case .text(let text): await session.type(text)
        case .clipboard(let text): await session.clipboard(text)
        }
    }
}
