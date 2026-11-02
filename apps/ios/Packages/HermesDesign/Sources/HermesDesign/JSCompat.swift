import Foundation

enum JSCompat {
    static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            true
        default:
            false
        }
    }

    static func trim(_ text: String) -> String {
        var scalars = Substring(text).unicodeScalars
        while let first = scalars.first, isWhitespace(first) { scalars.removeFirst() }
        while let last = scalars.last, isWhitespace(last) { scalars.removeLast() }
        return String(scalars)
    }

    static func utf16Units(_ text: String) -> [UInt16] {
        Array(text.utf16)
    }

    static func firstUTF16Unit(of scalar: Unicode.Scalar) -> UInt32 {
        UInt32(scalar.utf16.first ?? 0)
    }

    static func hash31(units: some Sequence<UInt32>) -> UInt32 {
        var hash: UInt64 = 0
        for unit in units {
            hash = (hash &* 31 &+ UInt64(unit)) & 0xFFFF_FFFF
        }
        return UInt32(hash)
    }

    static func hash31OverCodePoints(_ text: String) -> UInt32 {
        hash31(units: text.unicodeScalars.map(firstUTF16Unit(of:)))
    }

    static func hash31OverUTF16(_ text: String) -> UInt32 {
        hash31(units: text.utf16.map(UInt32.init))
    }

    static func round(_ value: Double) -> Double {
        let floor = value.rounded(.down)
        return value - floor >= 0.5 ? floor + 1 : floor
    }

    static func round2(_ value: Double) -> Double {
        round(value * 100) / 100
    }

    static func numberString(_ value: Double) -> String {
        if value == 0 { return "0" }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return value.description
    }

    static func r2String(_ value: Double) -> String {
        numberString(round2(value))
    }

    static func toFixed2(_ value: Double) -> String {
        if value < 0 { return "-" + toFixed2(-value) }
        let eighths = value * 8
        if eighths == eighths.rounded(), abs(value) < 1e12 {
            let scaled = value * 1000
            if scaled == scaled.rounded(), Int64(scaled) % 10 == 5 {
                let up = (Int64(scaled) + 5) / 10
                return String(format: "%lld.%02lld", up / 100, up % 100)
            }
        }
        return String(format: "%.2f", value)
    }

    static func parseFloatPrefix(_ text: String) -> Double {
        let characters = Array(text.trimmingJSWhitespaceLeading().unicodeScalars)
        var index = 0
        func digit(_ i: Int) -> Bool { i < characters.count && characters[i].value >= 0x30 && characters[i].value <= 0x39 }
        var end = 0
        if index < characters.count, characters[index] == "+" || characters[index] == "-" { index += 1 }
        let digitsStart = index
        while digit(index) { index += 1 }
        var sawDigits = index > digitsStart
        if index < characters.count, characters[index] == "." {
            var fraction = index + 1
            while digit(fraction) { fraction += 1 }
            if fraction > index + 1 || sawDigits {
                sawDigits = sawDigits || fraction > index + 1
                index = fraction
            }
        }
        guard sawDigits else { return .nan }
        end = index
        if end < characters.count, characters[end] == "e" || characters[end] == "E" {
            var exponent = end + 1
            if exponent < characters.count, characters[exponent] == "+" || characters[exponent] == "-" { exponent += 1 }
            let exponentDigits = exponent
            while digit(exponent) { exponent += 1 }
            if exponent > exponentDigits { end = exponent }
        }
        var literal = String(String.UnicodeScalarView(characters[0..<end]))
        if literal.hasSuffix(".") { literal.removeLast() }
        if literal.hasPrefix("+") { literal.removeFirst() }
        if literal.hasPrefix(".") { literal = "0" + literal }
        if literal.hasPrefix("-.") { literal = "-0" + literal.dropFirst() }
        return Double(literal) ?? .nan
    }

    static func lowercased(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var result = String.UnicodeScalarView()
        for (index, scalar) in scalars.enumerated() {
            if scalar.value == 0x03A3 {
                result.append(isFinalSigma(scalars, at: index) ? Unicode.Scalar(0x03C2)! : Unicode.Scalar(0x03C3)!)
            } else {
                result.append(contentsOf: scalar.properties.lowercaseMapping.unicodeScalars)
            }
        }
        return String(result)
    }

    private static func isFinalSigma(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        var before = index - 1
        while before >= 0, scalars[before].properties.isCaseIgnorable { before -= 1 }
        guard before >= 0, scalars[before].properties.isCased else { return false }
        var after = index + 1
        while after < scalars.count, scalars[after].properties.isCaseIgnorable { after += 1 }
        return after >= scalars.count || !scalars[after].properties.isCased
    }

    static func normalizeSeed(_ seed: String) -> String {
        lowercased(trim(seed.precomposedStringWithCanonicalMapping))
    }

    static func numbers(in pathData: String) -> [Double] {
        let bytes = Array(pathData.utf8)
        var values: [Double] = []
        var index = 0
        func digit(_ i: Int) -> Bool { i < bytes.count && bytes[i] >= 0x30 && bytes[i] <= 0x39 }
        while index < bytes.count {
            let start = index
            if bytes[index] == 0x2D, digit(index + 1) { index += 1 } else if !digit(index) {
                index += 1
                continue
            }
            while digit(index) { index += 1 }
            if index < bytes.count, bytes[index] == 0x2E, digit(index + 1) {
                index += 1
                while digit(index) { index += 1 }
            }
            if start < index, let value = Double(String(decoding: bytes[start..<index], as: UTF8.self)) {
                values.append(value)
            }
        }
        return values
    }
}

private extension String {
    func trimmingJSWhitespaceLeading() -> String {
        var scalars = Substring(self).unicodeScalars
        while let first = scalars.first, JSCompat.isWhitespace(first) { scalars.removeFirst() }
        return String(scalars)
    }
}
