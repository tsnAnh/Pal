import CoreGraphics
import PalChat
import Testing

struct SwipeReplyTests {
    private static let startXs: [CGFloat] = [0, 12, 27, 28, 120, 200, 380]

    @Test("a mostly vertical drag never begins a reply swipe, wherever it starts", arguments: startXs)
    func verticalDragsStayWithTheScrollView(startX: CGFloat) {
        for degrees in stride(from: 40.0, through: 140.0, by: 5.0) {
            for sign in [1.0, -1.0] {
                let radians = degrees * .pi / 180
                let velocity = CGSize(width: cos(radians) * 900, height: sign * sin(radians) * 900)
                #expect(!SwipeReply.begins(startX: startX, velocity: velocity), "angle \(degrees) sign \(sign)")
            }
        }
    }

    @Test("a leftward or still drag never begins a reply swipe", arguments: startXs)
    func leftwardDragsNeverBegin(startX: CGFloat) {
        #expect(!SwipeReply.begins(startX: startX, velocity: .zero))
        #expect(!SwipeReply.begins(startX: startX, velocity: CGSize(width: -600, height: 0)))
        #expect(!SwipeReply.begins(startX: startX, velocity: CGSize(width: -600, height: 40)))
    }

    @Test("a drag from the screen edge stays with the system back swipe")
    func edgeDragsNeverBegin() {
        #expect(!SwipeReply.begins(startX: SwipeReply.edgeInset - 1, velocity: CGSize(width: 800, height: 0)))
    }

    @Test("a rightward, horizontally dominant drag away from the edge begins a reply swipe", arguments: [28.0, 120.0, 380.0])
    func horizontalDragsBegin(startX: CGFloat) {
        #expect(SwipeReply.begins(startX: startX, velocity: CGSize(width: 800, height: 0)))
        #expect(SwipeReply.begins(startX: startX, velocity: CGSize(width: 800, height: -400)))
    }
}
