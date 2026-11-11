import Foundation

enum AvatarBlink {
    static let period = 4.2
    static let spreadSeconds = 4.0
    static let closedScale = 0.1
    static let closingStart = 0.96

    static var length: Double { period * (1 - closingStart) }

    static func delaySeconds(for key: String) -> Double {
        Double(JSCompat.hash31OverCodePoints(key) % 1000) / 1000 * spreadSeconds
    }

    static func openness(at time: Double, delay: Double) -> Double {
        let phase = cycleTime(time, delay: delay)
        let start = period * closingStart
        guard phase >= start else { return 1 }
        let progress = (phase - start) / length
        let closing = progress < 0.5 ? progress * 2 : (1 - progress) * 2
        return 1 - (1 - closedScale) * Ease.easeInOut(closing)
    }

    static func nextStart(after time: Double, delay: Double) -> Double {
        let phase = cycleTime(time, delay: delay)
        let start = period * closingStart
        return time + (phase < start ? start - phase : period - phase + start)
    }

    private static func cycleTime(_ time: Double, delay: Double) -> Double {
        let phase = (time - delay).truncatingRemainder(dividingBy: period)
        return phase < 0 ? phase + period : phase
    }
}
