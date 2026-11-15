import CoreGraphics
import Foundation

let args = CommandLine.arguments
let x = Double(args[1])!
let y = Double(args[2])!
let count = Int(args[3])!
let dy = Int32(args[4])!
let fling = args.count > 5 && args[5] == "fling"
let source = CGEventSource(stateID: .hidSystemState)

CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)?.post(tap: .cghidEventTap)

func post(_ delta: Int32, phase: Int64, momentum: Int64) {
    let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)!
    event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
    event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    event.location = CGPoint(x: x, y: y)
    event.post(tap: .cghidEventTap)
}

post(0, phase: 128, momentum: 0)
post(dy, phase: 1, momentum: 0)
for _ in 0..<count {
    post(dy, phase: 2, momentum: 0)
    Thread.sleep(forTimeInterval: 0.016)
}
post(0, phase: 4, momentum: 0)
if fling {
    var velocity = Double(dy) * 1.5
    post(Int32(velocity), phase: 0, momentum: 1)
    while abs(velocity) > 1 {
        velocity *= 0.95
        post(Int32(velocity), phase: 0, momentum: 2)
        Thread.sleep(forTimeInterval: 0.016)
    }
    post(0, phase: 0, momentum: 3)
}
