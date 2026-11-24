import Testing

@testable import PalDesign

@Suite("Pop motion")
struct PalMotionTests {
    @Test("Reduce Motion picks the plain fade and everything else the scale and fade")
    func choice() {
        #expect(PalMotion.Pop(reduceMotion: true) == .fade)
        #expect(PalMotion.Pop(reduceMotion: false) == .scaleFade)
    }

    @Test("a hide finishes in about 0.2 s")
    func hideIsQuick() {
        #expect(PalMotion.popOutDuration > 0.1)
        #expect(PalMotion.popOutDuration <= 0.2)
    }
}
