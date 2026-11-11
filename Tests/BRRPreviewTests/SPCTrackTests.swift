import XCTest
@testable import BRRPreview

/// Pure tracker tests. They don't need an SPC fixture.
final class SPCTrackTests: XCTestCase {
    private let frame = 1.0 / 30.0

    /// Eight voices, where each key is a voice playing (sample index, bar level).
    private func voices(_ playing: [Int: (source: Int, bars: Float)]) -> [SPCVoiceState] {
        (0..<8).map { index in
            guard let entry = playing[index] else { return SPCVoiceState.silent(index: index) }
            return SPCVoiceState(index: index, sampleIndex: entry.source, pitch: 0x1000, envelope: 100,
                                 bars: [Float](repeating: entry.bars, count: SPCVoiceState.barCount))
        }
    }

    /// Feeds `seconds` of unchanging voice state into the tracker and returns the time afterward.
    @discardableResult
    private func feed(_ tracks: inout [SPCTrackState], _ playing: [Int: (source: Int, bars: Float)],
                      seconds: Double, from time: Double) -> Double {
        var now = time
        for _ in 0..<Int((seconds / frame).rounded()) {
            SPCTrackTracker.update(&tracks, voices: voices(playing), time: now, frameDuration: frame)
            now += frame
        }
        return now
    }

    func testOneTrackPerSampleInFirstHeardOrder() {
        var tracks: [SPCTrackState] = []
        var time = feed(&tracks, [0: (7, 0)], seconds: 1, from: 0)
        time = feed(&tracks, [3: (2, 0)], seconds: 1, from: time)
        feed(&tracks, [5: (7, 0)], seconds: 1, from: time)

        XCTAssertEqual(tracks.map(\.sourceIndex), [7, 2])
        XCTAssertEqual(tracks.map(\.number), [1, 2])
    }

    func testSampleKeepsOneTrackAcrossVoices() {
        var tracks: [SPCTrackState] = []
        var time = feed(&tracks, [1: (5, 0)], seconds: 1, from: 0)
        time = feed(&tracks, [6: (5, 0)], seconds: 1, from: time)
        feed(&tracks, [2: (5, 0)], seconds: 1, from: time)

        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks[0].voicesUsed, [1, 6, 2])
        XCTAssertEqual(tracks[0].spans.count, 3)
        XCTAssertEqual(tracks[0].activeVoices, [2])
    }

    func testSimultaneousVoicesShareTheTrack() {
        var tracks: [SPCTrackState] = []
        feed(&tracks, [0: (4, 0.2), 4: (4, 0.7)], seconds: 1, from: 0)

        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks[0].activeVoices, [0, 4])
        XCTAssertTrue(tracks[0].bars.allSatisfy { abs($0 - 0.7) < 1e-6 }, "Track bars should take the loudest voice")
    }

    func testSilentVoicesAreIgnored() {
        var silent = (0..<8).map { SPCVoiceState.silent(index: $0) }
        silent[2] = SPCVoiceState(index: 2, sampleIndex: 9, pitch: 0x1000, envelope: 0,
                                  bars: [Float](repeating: 0, count: SPCVoiceState.barCount))
        var tracks: [SPCTrackState] = []
        SPCTrackTracker.update(&tracks, voices: silent, time: 0, frameDuration: frame)

        XCTAssertTrue(tracks.isEmpty, "A voice with no envelope is not sounding and must not create a track")
    }

    func testTrackStaysAfterItGoesSilent() {
        var tracks: [SPCTrackState] = []
        let time = feed(&tracks, [0: (4, 0)], seconds: 1, from: 0)
        feed(&tracks, [:], seconds: 1, from: time)

        XCTAssertEqual(tracks.count, 1)
        XCTAssertTrue(tracks[0].activeVoices.isEmpty)
        XCTAssertNotNil(tracks[0].spans.last?.end)
    }

    func testSpansOlderThanTheWindowArePruned() {
        var tracks: [SPCTrackState] = []
        let time = feed(&tracks, [0: (4, 0)], seconds: 1, from: 0)
        feed(&tracks, [:], seconds: SPCTrackTracker.timelineWindow + 10, from: time)

        XCTAssertEqual(tracks.count, 1, "Pruning the timeline must not remove the track itself")
        XCTAssertTrue(tracks[0].spans.isEmpty)
    }

    func testActiveSecondsAccumulateWhileSounding() {
        var tracks: [SPCTrackState] = []
        let time = feed(&tracks, [0: (4, 0)], seconds: 2, from: 0)
        feed(&tracks, [:], seconds: 2, from: time)

        XCTAssertEqual(tracks[0].activeSeconds, 2, accuracy: 0.05)
    }
}
