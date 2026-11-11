import SwiftUI

extension AvatarRig {
    var bodyColor: AvatarColor? {
        guard let first = body.first else { return nil }
        return first.fill ?? first.stroke?.color
    }

    func toned(for scheme: ColorScheme) -> AvatarRig {
        guard scheme == .light, let body = bodyColor, body.isWhite, let ink = AvatarColor(css: AvatarColor.darkEyeFillCSS) else {
            return self
        }
        func inked(_ element: AvatarDrawing.Element) -> AvatarDrawing.Element {
            var result = element
            result.fill = element.fill.map { $0.recolored(to: ink) }
            result.stroke = element.stroke.map { stroke in
                AvatarDrawing.Stroke(color: stroke.color.recolored(to: ink), width: stroke.width, round: stroke.round)
            }
            return result
        }
        var toned = self
        toned.body = self.body.map(inked)
        toned.dots = dots.map(inked)
        toned.eyes.fill = eyes.fill == body ? ink : ink.eyeFill
        return toned
    }
}

extension AvatarContent {
    func toned(for scheme: ColorScheme) -> AvatarContent {
        switch self {
        case .rig(let rig): .rig(rig.toned(for: scheme))
        case .photo: self
        }
    }
}
