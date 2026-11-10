import BRRCore
import Foundation
import XCTest
@testable import BRRPreview

/// Runs against a real SPC when `BRR_SPC_FIXTURE` points at one; otherwise the tests are skipped.
@MainActor
final class SPCSampleTests: XCTestCase {
    private let voiceCount = 8

    private func openFixture() throws -> SPCSession {
        guard let path = ProcessInfo.processInfo.environment["BRR_SPC_FIXTURE"] else {
            throw XCTSkip("Set BRR_SPC_FIXTURE to an SPC file to run SPC sample tests.")
        }
        return try SPCSession(url: URL(fileURLWithPath: path))
    }

    /// Songs often carry an xid6 tag after the 64 KB image, so a larger file must still open.
    func testOpensFileWithTrailingTag() throws {
        let fixture = try openFixture()
        let original = try Data(contentsOf: fixture.url)
        let tagged = original + Data(repeating: 0, count: 100)
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("tagged-\(UUID().uuidString).spc")
        try tagged.write(to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }

        let session = try SPCSession(url: copy)
        session.shutdown()
    }

    func testRejectsFileWithoutSPCHeader() throws {
        let junk = Data(repeating: 0x41, count: SPCSession.fileSize)
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("junk-\(UUID().uuidString).spc")
        try junk.write(to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }

        XCTAssertThrowsError(try SPCSession(url: copy))
    }

    /// Plays briefly so the song keys on voices, then returns the first voice with a readable sample.
    private func firstSounding(_ session: SPCSession) throws -> SPCSampleSnapshot {
        session.play()
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            for voice in 0..<voiceCount {
                if let snapshot = session.snapshot(voice: voice), snapshot.blockCount > 0 {
                    session.stop()
                    return snapshot
                }
            }
        }
        session.stop()
        throw XCTSkip("No voice held a readable sample during the test window.")
    }

    private func sine(frequency: Double, sampleRate: Double, seconds: Double) -> EditableSample {
        let count = Int(sampleRate * seconds)
        let samples = (0..<count).map { Float(0.5 * sin(2 * Double.pi * frequency * Double($0) / sampleRate)) }
        return EditableSample(samples: samples, sourceRate: sampleRate, loopStart: nil)
    }

    func testSnapshotEndsChainWithEND() throws {
        let session = try openFixture()
        defer { session.shutdown() }
        let snapshot = try firstSounding(session)

        XCTAssertEqual(snapshot.data.count, snapshot.blockCount * 9)
        let endHeader = snapshot.data[(snapshot.blockCount - 1) * 9]
        XCTAssertTrue(endHeader & 0x01 != 0, "Last block of a chain must carry END")
    }

    func testExtractWritesBRRAndMetadata() throws {
        let session = try openFixture()
        defer { session.shutdown() }
        let snapshot = try firstSounding(session)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("spc-extract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let brr = folder.appendingPathComponent("voice.brr")
        let sidecar = try session.extract(snapshot, to: brr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: brr.path))
        XCTAssertEqual(sidecar.lastPathComponent, "voice.txt")

        let text = try String(contentsOf: sidecar, encoding: .utf8)
        XCTAssertTrue(text.contains("Start address:"))
        XCTAssertTrue(text.contains("Sample index (SRCN):"))
    }

    func testSameAudioReplacementKeepsSlotAndData() throws {
        let session = try openFixture()
        defer { session.shutdown() }
        let snapshot = try firstSounding(session)
        let original = session.originalSample(snapshot)

        let result = try session.replace(snapshot, with: original, options: ReplacementOptions(pitchMode: .keepOwn))
        XCTAssertFalse(result.relocated)
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(result.start, snapshot.start)
        XCTAssertEqual(result.blockCount, snapshot.blockCount)
        XCTAssertEqual(result.loopBlock, snapshot.loopBlock)

        let written = try XCTUnwrap(session.readRAM(snapshot.start, count: result.blockCount * 9))
        let reread = try XCTUnwrap(session.snapshot(voice: snapshot.voice))
        XCTAssertEqual(reread.start, snapshot.start)

        let before = BRRDecoder.decode(snapshot.data).samples.map(Double.init)
        let after = BRRDecoder.decode(written).samples.map(Double.init)
        XCTAssertEqual(after.count, before.count)
        let error = zip(before, after).reduce(0.0) { $0 + pow($1.0 - $1.1, 2) }
        let energy = before.reduce(0.0) { $0 + $1 * $1 }
        XCTAssertLessThan(sqrt(error / max(energy, 1)), 0.3, "Re-encoded audio drifted too far from the original")
    }

    func testRefuseThrowsWhenOversize() throws {
        let session = try openFixture()
        defer { session.shutdown() }
        let snapshot = try firstSounding(session)
        let long = sine(frequency: 220, sampleRate: 32_000, seconds: 5)

        XCTAssertThrowsError(try session.replace(snapshot, with: long, options: ReplacementOptions(oversize: .refuse)))
    }

    func testTruncateKeepsEndAndFitsSlot() throws {
        let session = try openFixture()
        defer { session.shutdown() }
        let snapshot = try firstSounding(session)
        let long = sine(frequency: 220, sampleRate: 32_000, seconds: 5)

        let result = try session.replace(snapshot, with: long, options: ReplacementOptions(oversize: .truncate))
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.blockCount, snapshot.blockCount)
        XCTAssertNil(result.loopBlock, "A loop point past the cut must be dropped")

        let written = session.readRAM(snapshot.start, count: result.blockCount * 9) ?? []
        XCTAssertTrue(written[(result.blockCount - 1) * 9] & 0x01 != 0)
    }

    func testMatchOriginalKeepsOriginalPitch() throws {
        let session = try openFixture()
        defer { session.shutdown() }
        let snapshot = try firstSounding(session)
        guard let originalFrequency = snapshot.frequency else {
            throw XCTSkip("Sounding sample is unpitched; pitch match can't be checked.")
        }

        // Keep the input tone under the detector's 2 kHz ceiling; the replacement must still land on the original pitch.
        let tone = sine(frequency: 600, sampleRate: 44_100, seconds: 0.5)
        let result = try session.replace(snapshot, with: tone,
                                         options: ReplacementOptions(pitchMode: .matchOriginal, oversize: .truncate))

        let written = session.readRAM(result.start, count: result.blockCount * 9) ?? []
        let pcm = BRRDecoder.decode(written).samples
        let played = try XCTUnwrap(PitchDetector.fundamentalFrequency(samples: pcm, sampleRate: Double(BRRDecoder.sampleRate)))
        XCTAssertEqual(played, originalFrequency, accuracy: originalFrequency * 0.02)
    }
}
