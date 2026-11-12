import Foundation
import PalProtocol
import Synchronization

public enum InputLimits {
    public static let maxTypedCharacters = 500
    public static let maxScrollLines = 50
    public static let maxCoordinate = 100_000.0
    public static let maxEventsPerCall = 1100
    public static let minEventDelay: Duration = .milliseconds(8)
    public static let dragSteps = 20
}

public struct InputModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = InputModifiers(rawValue: 1)
    public static let shift = InputModifiers(rawValue: 2)
    public static let option = InputModifiers(rawValue: 4)
    public static let control = InputModifiers(rawValue: 8)
}

public enum InputEvent: Sendable, Equatable {
    case mouseMove(x: Double, y: Double)
    case mouseDown(x: Double, y: Double, button: InputButton, clickState: Int)
    case mouseUp(x: Double, y: Double, button: InputButton, clickState: Int)
    case mouseDrag(x: Double, y: Double, button: InputButton)
    case scroll(dx: Int, dy: Int)
    case key(code: UInt16, down: Bool, modifiers: InputModifiers)
    case character(String, down: Bool)
}

public protocol InputEventSource: Sendable {
    var isAccessibilityTrusted: Bool { get }
    var isScreenLocked: Bool { get }
    var isSecureInputActive: Bool { get }
    var isOwnAppFrontmost: Bool { get }
    func displays() -> [InputDisplayRecord]
    func pointer() -> (x: Double, y: Double)
    func isOwnWindow(atX x: Double, y: Double) -> Bool
    func post(_ event: InputEvent) -> Bool
}

public enum InputActivity: Sendable, Equatable {
    case began
    case ended
    case stopped
}

public struct EscapeBurstDetector: Sendable {
    public static let presses = 3
    public static let window: TimeInterval = 1.5

    private var stamps: [TimeInterval] = []

    public init() {}

    public mutating func record(at time: TimeInterval) -> Bool {
        stamps = stamps.filter { time - $0 <= Self.window }
        stamps.append(time)
        guard stamps.count >= Self.presses else { return false }
        stamps.removeAll()
        return true
    }
}

public struct InputKeyChord: Sendable, Equatable {
    public var code: UInt16
    public var modifiers: InputModifiers
}

public enum InputKeyMap {
    public static func parse(_ text: String) -> InputKeyChord? {
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let last = parts.last, let code = codes[last == "" ? "plus" : last] else { return nil }
        var modifiers: InputModifiers = []
        for name in parts.dropLast() {
            guard let modifier = modifierNames[name] else { return nil }
            modifiers.insert(modifier)
        }
        return InputKeyChord(code: code, modifiers: modifiers)
    }

    private static let modifierNames: [String: InputModifiers] = [
        "cmd": .command, "command": .command, "shift": .shift, "alt": .option, "option": .option, "opt": .option,
        "ctrl": .control, "control": .control,
    ]

    private static let codes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36,
        "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
        ".": 47, "tab": 48, "space": 49, "`": 50, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "left": 123, "right": 124,
        "down": 125, "up": 126, "plus": 24, "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98,
        "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]
}

public actor InputController: InputProviding {
    static let stoppedMessage = "The owner stopped mouse and keyboard control. It stays off until they turn it on again; tell them instead of retrying."

    private let source: any InputEventSource
    private let pause: @Sendable (Duration) async throws -> Void
    private let stopped = Mutex(false)
    private let observer = Mutex<(@Sendable (InputActivity) -> Void)?>(nil)

    public init(
        source: any InputEventSource,
        pause: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.source = source
        self.pause = pause
    }

    public nonisolated func observe(_ handler: @escaping @Sendable (InputActivity) -> Void) {
        observer.withLock { $0 = handler }
    }

    public nonisolated func stop() {
        stopped.withLock { $0 = true }
        observer.withLock { $0 }?(.stopped)
    }

    public nonisolated func rearm() {
        stopped.withLock { $0 = false }
    }

    public nonisolated var isStopped: Bool { stopped.withLock { $0 } }

    public func displays() async throws -> InputDisplaysRecord {
        try ready()
        let pointer = source.pointer()
        return InputDisplaysRecord(displays: source.displays(), pointerX: pointer.x, pointerY: pointer.y)
    }

    public func move(_ target: InputMoveTarget) async throws -> InputPostRecord {
        let point: (x: Double, y: Double)
        switch target {
        case .absolute(let absolute): point = try resolve(absolute)
        case .relative(let dx, let dy):
            let here = source.pointer()
            point = try resolve(InputPoint(x: here.x + dx, y: here.y + dy))
        }
        try ready(pointer: point)
        return try await send([.mouseMove(x: point.x, y: point.y)])
    }

    public func click(at point: InputPoint?, button: InputButton, clicks: Int) async throws -> InputPostRecord {
        guard (1...2).contains(clicks) else { throw DeviceProviderError.invalidArgs("clicks must be 1 or 2.") }
        let target = try point.map(resolve) ?? source.pointer()
        try ready(pointer: target)
        var events: [InputEvent] = point == nil ? [] : [.mouseMove(x: target.x, y: target.y)]
        for state in 1...clicks {
            events.append(.mouseDown(x: target.x, y: target.y, button: button, clickState: state))
            events.append(.mouseUp(x: target.x, y: target.y, button: button, clickState: state))
        }
        return try await send(events)
    }

    public func drag(from: InputPoint, to: InputPoint, button: InputButton) async throws -> InputPostRecord {
        let start = try resolve(from), end = try resolve(to)
        try ready(pointer: start)
        try ready(pointer: end)
        var events: [InputEvent] = [
            .mouseMove(x: start.x, y: start.y),
            .mouseDown(x: start.x, y: start.y, button: button, clickState: 1),
        ]
        for step in 1...InputLimits.dragSteps {
            let fraction = Double(step) / Double(InputLimits.dragSteps)
            events.append(.mouseDrag(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction, button: button))
        }
        events.append(.mouseUp(x: end.x, y: end.y, button: button, clickState: 1))
        return try await send(events)
    }

    public func scroll(at point: InputPoint?, dx: Int, dy: Int) async throws -> InputPostRecord {
        guard dx != 0 || dy != 0, abs(dx) <= InputLimits.maxScrollLines, abs(dy) <= InputLimits.maxScrollLines else {
            throw DeviceProviderError.invalidArgs("dx and dy must be between -\(InputLimits.maxScrollLines) and \(InputLimits.maxScrollLines), not both 0.")
        }
        let target = try point.map(resolve) ?? source.pointer()
        try ready(pointer: target)
        var events: [InputEvent] = point == nil ? [] : [.mouseMove(x: target.x, y: target.y)]
        events.append(.scroll(dx: dx, dy: dy))
        return try await send(events)
    }

    public func type(_ text: String) async throws -> InputPostRecord {
        guard !text.isEmpty, text.count <= InputLimits.maxTypedCharacters else {
            throw DeviceProviderError.invalidArgs("text must be 1 to \(InputLimits.maxTypedCharacters) characters.")
        }
        try ready(keyboard: true)
        var events: [InputEvent] = []
        for character in text {
            switch character {
            case "\n", "\r\n": events += Self.keyPress(36, [])
            case "\t": events += Self.keyPress(48, [])
            default: events += [.character(String(character), down: true), .character(String(character), down: false)]
            }
        }
        return try await send(events)
    }

    public func press(key: String) async throws -> InputPostRecord {
        guard let chord = InputKeyMap.parse(key) else {
            throw DeviceProviderError.invalidArgs("\(key) is not a key. Use a name such as return, escape, tab, left, f5, a, or a combo such as cmd+c.")
        }
        try ready(keyboard: true)
        return try await send(Self.keyPress(chord.code, chord.modifiers))
    }

    private static func keyPress(_ code: UInt16, _ modifiers: InputModifiers) -> [InputEvent] {
        [.key(code: code, down: true, modifiers: modifiers), .key(code: code, down: false, modifiers: modifiers)]
    }

    private func ready(pointer: (x: Double, y: Double)? = nil, keyboard: Bool = false) throws {
        if isStopped { throw DeviceProviderError.failed(Self.stoppedMessage) }
        guard source.isAccessibilityTrusted else { throw DeviceProviderError.permissionDenied }
        if source.isScreenLocked { throw DeviceProviderError.failed("The screen is locked or the login window is showing, so no input was sent.") }
        if keyboard {
            if source.isOwnAppFrontmost { throw DeviceProviderError.failed("Pal is the frontmost app and bots cannot type into it. Nothing was sent.") }
            if source.isSecureInputActive {
                throw DeviceProviderError.failed("Secure input is on (a password field has focus): macOS blocks typing there, so nothing was sent. Do not retry.")
            }
        }
        if let pointer, source.isOwnWindow(atX: pointer.x, y: pointer.y) {
            throw DeviceProviderError.failed("That point is inside one of Pal's own windows and bots cannot control them. Nothing was sent.")
        }
    }

    private func resolve(_ point: InputPoint) throws -> (x: Double, y: Double) {
        let displays = source.displays()
        var x = point.x, y = point.y
        if let id = point.display {
            guard let display = displays.first(where: { $0.id == id }) else {
                throw DeviceProviderError.invalidArgs("Display \(id) does not exist. Call input.displays.")
            }
            x += display.x
            y += display.y
            guard display.contains(x: x, y: y) else { throw DeviceProviderError.invalidArgs("That point is outside display \(id).") }
        }
        guard displays.contains(where: { $0.contains(x: x, y: y) }) else {
            throw DeviceProviderError.invalidArgs("The point (\(Int(x.rounded())), \(Int(y.rounded()))) is outside every display. Call input.displays.")
        }
        return (x, y)
    }

    private func send(_ events: [InputEvent]) async throws -> InputPostRecord {
        guard events.count <= InputLimits.maxEventsPerCall else { throw DeviceProviderError.invalidArgs("That is too many input events for one call.") }
        observer.withLock { $0 }?(.began)
        defer { observer.withLock { $0 }?(.ended) }
        var sent = 0
        for event in events {
            try Task.checkCancellation()
            if isStopped { throw DeviceProviderError.failed(Self.stoppedMessage) }
            guard source.post(event) else {
                throw DeviceProviderError.failed("The event could not be posted; \(sent) of \(events.count) events went out.")
            }
            sent += 1
            try await pause(InputLimits.minEventDelay)
        }
        let pointer = source.pointer()
        return InputPostRecord(events: sent, pointerX: pointer.x, pointerY: pointer.y)
    }
}

enum InputToolHandler {
    static func run(_ action: DeviceToolAction, _ raw: JSONValue, provider: any InputProviding) async throws -> JSONValue {
        switch action {
        case .inputDisplays: return try await displays(provider)
        case .inputMove: return try wire(try await move(raw, provider))
        case .inputClick: return try wire(try await click(raw, provider))
        case .inputDrag: return try wire(try await drag(raw, provider))
        case .inputScroll: return try wire(try await scroll(raw, provider))
        case .inputType: return try wire(try await type(raw, provider))
        case .inputKey: return try wire(try await press(raw, provider))
        default: throw DeviceProviderError.unsupported
        }
    }

    private static func wire(_ record: InputPostRecord) throws -> JSONValue {
        try DeviceWire.encode(InputResultWire(events: record.events, pointerX: record.pointerX, pointerY: record.pointerY))
    }

    private static func displays(_ provider: any InputProviding) async throws -> JSONValue {
        let record = try await provider.displays()
        let displays = record.displays.map {
            InputDisplayWire(id: $0.id, name: $0.name, main: $0.isMain, x: $0.x, y: $0.y, width: $0.width, height: $0.height, scale: $0.scale)
        }
        return try DeviceWire.encode(InputDisplaysWire(displays: displays, pointerX: record.pointerX, pointerY: record.pointerY))
    }

    private static func move(_ raw: JSONValue, _ provider: any InputProviding) async throws -> InputPostRecord {
        let args: InputMoveArgs = try DeviceWire.decodeArgs(raw)
        if args.dx != nil || args.dy != nil {
            guard let dx = args.dx, let dy = args.dy, args.x == nil, args.y == nil else {
                throw DeviceProviderError.invalidArgs("Pass either x and y, or dx and dy.")
            }
            try check(dx, dy)
            return try await provider.move(.relative(dx: dx, dy: dy))
        }
        guard let point = try point(x: args.x, y: args.y, display: args.display) else {
            throw DeviceProviderError.invalidArgs("Pass x and y, or dx and dy.")
        }
        return try await provider.move(.absolute(point))
    }

    private static func click(_ raw: JSONValue, _ provider: any InputProviding) async throws -> InputPostRecord {
        let args: InputClickArgs = try DeviceWire.decodeArgs(raw)
        let clicks = args.clicks ?? 1
        guard (1...2).contains(clicks) else { throw DeviceProviderError.invalidArgs("clicks must be 1 or 2.") }
        return try await provider.click(at: point(x: args.x, y: args.y, display: args.display), button: button(args.button), clicks: clicks)
    }

    private static func drag(_ raw: JSONValue, _ provider: any InputProviding) async throws -> InputPostRecord {
        let args: InputDragArgs = try DeviceWire.decodeArgs(raw)
        try check(args.fromX, args.fromY, args.toX, args.toY)
        return try await provider.drag(
            from: InputPoint(x: args.fromX, y: args.fromY, display: args.display),
            to: InputPoint(x: args.toX, y: args.toY, display: args.display),
            button: button(args.button)
        )
    }

    private static func scroll(_ raw: JSONValue, _ provider: any InputProviding) async throws -> InputPostRecord {
        let args: InputScrollArgs = try DeviceWire.decodeArgs(raw)
        return try await provider.scroll(at: point(x: args.x, y: args.y, display: args.display), dx: args.dx ?? 0, dy: args.dy ?? 0)
    }

    private static func type(_ raw: JSONValue, _ provider: any InputProviding) async throws -> InputPostRecord {
        let args: InputTypeArgs = try DeviceWire.decodeArgs(raw)
        return try await provider.type(args.text)
    }

    private static func press(_ raw: JSONValue, _ provider: any InputProviding) async throws -> InputPostRecord {
        let args: InputKeyArgs = try DeviceWire.decodeArgs(raw)
        return try await provider.press(key: args.key)
    }

    private static func point(x: Double?, y: Double?, display: Int?) throws -> InputPoint? {
        switch (x, y) {
        case (nil, nil): return nil
        case (let x?, let y?):
            try check(x, y)
            return InputPoint(x: x, y: y, display: display)
        default: throw DeviceProviderError.invalidArgs("Pass x and y together.")
        }
    }

    private static func check(_ values: Double...) throws {
        guard values.allSatisfy({ $0.isFinite && abs($0) <= InputLimits.maxCoordinate }) else {
            throw DeviceProviderError.invalidArgs("Coordinates must be numbers within \(Int(InputLimits.maxCoordinate)).")
        }
    }

    private static func button(_ text: String?) throws -> InputButton {
        guard let button = InputButton(rawValue: text ?? "left") else { throw DeviceProviderError.invalidArgs("button must be left, right or middle.") }
        return button
    }
}
