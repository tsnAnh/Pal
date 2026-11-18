import Foundation

public struct InputDisplayWire: Encodable, Sendable, Equatable {
    public var id: Int
    public var name: String?
    public var main: Bool
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var scale: Double

    public init(id: Int, name: String?, main: Bool, x: Double, y: Double, width: Double, height: Double, scale: Double) {
        self.id = id
        self.name = name
        self.main = main
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.scale = scale
    }
}

public struct InputDisplaysWire: Encodable, Sendable, Equatable {
    public var displays: [InputDisplayWire]
    public var pointerX: Double
    public var pointerY: Double

    public init(displays: [InputDisplayWire], pointerX: Double, pointerY: Double) {
        self.displays = displays
        self.pointerX = pointerX
        self.pointerY = pointerY
    }
}

public struct InputResultWire: Encodable, Sendable, Equatable {
    public var events: Int
    public var pointerX: Double?
    public var pointerY: Double?

    public init(events: Int, pointerX: Double?, pointerY: Double?) {
        self.events = events
        self.pointerX = pointerX
        self.pointerY = pointerY
    }
}
