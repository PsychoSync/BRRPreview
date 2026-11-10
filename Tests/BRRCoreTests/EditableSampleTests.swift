import XCTest
@testable import BRRCore

final class EditableSampleTests: XCTestCase {
    private func ramp(_ count: Int, loop: Int? = nil) -> EditableSample {
        EditableSample(samples: (0..<count).map { Float($0) / 100 }, sourceRate: 32_000, loopStart: loop)
    }

    func testCropKeepsLoopInsideRangeRelative() {
        var s = ramp(100, loop: 40)
        s.crop(20..<80)
        XCTAssertEqual(s.samples.count, 60)
        XCTAssertEqual(s.loopStart, 20)
    }

    func testCropBeforeLoopMovesLoopToStart() {
        var s = ramp(100, loop: 50)
        s.crop(0..<30)
        XCTAssertEqual(s.loopStart, nil, "loop after the crop is removed")
        var t = ramp(100, loop: 10)
        t.crop(30..<90)
        XCTAssertEqual(t.loopStart, 0, "loop before the crop becomes the start")
    }

    func testCutShiftsLoopAfterCut() {
        var s = ramp(100, loop: 60)
        s.cut(10..<30)
        XCTAssertEqual(s.samples.count, 80)
        XCTAssertEqual(s.loopStart, 40)
    }

    func testCutInsideLoopMovesLoopToCutPoint() {
        var s = ramp(100, loop: 50)
        s.cut(40..<60)
        XCTAssertEqual(s.loopStart, 40)
    }

    func testCutBeforeLoopShiftsLoopBack() {
        var s = ramp(100, loop: 50)
        s.cut(0..<10)
        XCTAssertEqual(s.loopStart, 40)
    }

    func testReverseInsideLoopClearsLoop() {
        var s = ramp(100, loop: 50)
        s.reverse(40..<60)
        XCTAssertNil(s.loopStart)
        XCTAssertEqual(s.samples[40], 0.59, accuracy: 1e-6)
    }

    func testFadeOutEndsAtZero() {
        var s = EditableSample(samples: [Float](repeating: 1, count: 10), sourceRate: 32_000)
        s.fadeOut(0..<10)
        XCTAssertEqual(s.samples.last ?? 1, 0.1, accuracy: 1e-6)
        XCTAssertEqual(s.samples.first ?? 0, 1, accuracy: 1e-6)
    }

    func testNormalizeSetsPeak() {
        var s = EditableSample(samples: [0.1, -0.25, 0.2], sourceRate: 32_000)
        s.normalize()
        XCTAssertEqual(s.samples.map { abs($0) }.max() ?? 0, 0.99, accuracy: 1e-6)
    }

    func testTrimSilenceRemovesEdges() {
        var s = EditableSample(samples: [0, 0, 0, 0.5, 0.2, 0, 0], sourceRate: 32_000, loopStart: 4)
        s.trimSilence()
        XCTAssertEqual(s.samples, [0.5, 0.2])
        XCTAssertEqual(s.loopStart, 1)
    }

    func testOutOfRangeEditsAreClamped() {
        var s = ramp(10)
        s.cut(5..<100)
        XCTAssertEqual(s.samples.count, 5)
    }
}
