import SwiftUI

public struct AvatarOutline: Equatable {
    public var gap: CGFloat
    public var thickness: CGFloat
    public var color: Color

    public init(gap: CGFloat, thickness: CGFloat, color: Color) {
        self.gap = gap
        self.thickness = thickness
        self.color = color
    }
}
