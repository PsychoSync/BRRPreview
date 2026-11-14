import AppKit
import BRRCore
import XCTest
@testable import BRRPreview

/// A tiny SPC driver starts a looping tone, then switches to another sample after a delay.
@MainActor
enum TestSPC {
    static func image() -> [UInt8] {
        var image = [UInt8](repeating: 0, count: SPCSession.fileSize)
        image.replaceSubrange(0..<SPCSession.magic.count, with: SPCSession.magic)
        image[0x21] = 0x1A
        image[0x22] = 0x1A
        image[0x23] = 0x1B
        image[0x24] = 30
        image[0x25] = 0
        image[0x26] = 2
        image[0x2B] = 0xEF
        var code: [UInt8] = []
        func dsp(_ register: UInt8, _ value: UInt8) {
            code += [0x8F, register, 0xF2, 0x8F, value, 0xF3]
        }
        dsp(0x4C, 1)
        code += [0xCD, 0xFF, 0x8D, 0xFF, 0xFE, 0xFE, 0x1D, 0xD0, 0xF9]
        dsp(0x04, 2)
        dsp(0x4C, 1)
        code += [0x2F, 0xFE]
        image.replaceSubrange(0x300..<0x300 + code.count, with: code)
        for source in 1...3 {
            let start = 0x2000 + source * 0x1000
            let samples = (0..<1024).map { Float(sin(Double($0) * Double(source) * 2 * .pi / 64) * 0.4) }
            let brr = BRREncoder.encode(samples, loopStart: 0).data
            image.replaceSubrange((0x100 + start)..<(0x100 + start + brr.count), with: brr)
            let entry = 0x1100 + source * 4
            image.replaceSubrange(entry..<entry + 4,
                                  with: [UInt8(start & 255), UInt8(start >> 8), UInt8(start & 255), UInt8(start >> 8)])
        }
        let dspBase = SPCSession.dspOffset
        for (reg, value) in [(0x0C, 127), (0x1C, 127), (0x6C, 0x20), (0x5D, 0x10),
                             (0x00, 127), (0x01, 127), (0x03, 0x10), (0x04, 1), (0x07, 127)] {
            image[dspBase + reg] = UInt8(value)
        }
        return image
    }

    @MainActor static func session() throws -> SPCSession {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).spc")
        try Data(image()).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try SPCSession(url: url)
    }
}

@MainActor
final class SPCScannerTests: XCTestCase {
    func testScanFindsLaterSampleButExcludesUnusedDirectoryEntry() throws {
        let image = TestSPC.image()
        let early = try SPCSampleScanner.scan(image: image, duration: 0.05)
        let full = try SPCSampleScanner.scan(image: image, duration: 1)
        XCTAssertEqual(Set(early.map(\.sourceIndex)), [1])
        XCTAssertEqual(Set(full.map(\.sourceIndex)), [1, 2])
        XCTAssertTrue(full.allSatisfy { $0.loopBlock == 0 })
    }

    func testScanExcludesSilentAndNoiseOnlyVoices() throws {
        var silent = TestSPC.image()
        silent[SPCSession.dspOffset] = 0
        silent[SPCSession.dspOffset + 1] = 0
        XCTAssertTrue(try SPCSampleScanner.scan(image: silent, duration: 1).isEmpty)
        var noise = TestSPC.image()
        noise[SPCSession.dspOffset + 0x3D] = 1
        XCTAssertTrue(try SPCSampleScanner.scan(image: noise, duration: 1).isEmpty)
    }
}

@MainActor
final class SPCAuditionTests: XCTestCase {
    func testNamesApplyToExportsAndDuplicatesDoNotOverwrite() throws {
        let session = try TestSPC.session()
        defer { session.shutdown() }
        let snapshots = try SPCSampleScanner.scan(image: TestSPC.image(), duration: 1)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        session.sampleNames = [1: "../Violin", 2: "../Violin"]
        XCTAssertEqual(try session.extractUsed(snapshots + snapshots, to: folder), 2)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertTrue(names.contains("_Violin.brr"))
        XCTAssertTrue(names.contains("_Violin-2.brr"))
        XCTAssertEqual(try session.extractUsed(snapshots, to: folder), 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 8)
    }

    func testKeyboardRoutesToSelectedSectionAndReleasesOriginalOwner() throws {
        let session = try TestSPC.session()
        defer { session.shutdown() }
        let snapshot = try XCTUnwrap(session.snapshot(sourceIndex: 1))
        let replacement = SPCReplacement(session: session, snapshot: snapshot, label: "Track 1")
        defer { replacement.close() }
        XCTAssertTrue(replacement.original.loopEnabled)
        XCTAssertTrue(replacement.keyDown("q", repeating: false))
        XCTAssertTrue(replacement.original.isPlaying)
        replacement.original.hold = true
        replacement.selectSection(.new)
        XCTAssertTrue(replacement.keyUp("q"))
        XCTAssertTrue(replacement.original.isPlaying, "The original's Hold note keeps its loop sounding")
        replacement.original.hold = false
        XCTAssertFalse(replacement.original.isPlaying)
        replacement.selectSection(.original)
        XCTAssertTrue(replacement.keyDown("q", repeating: false))
        XCTAssertTrue(replacement.keyUp("q"))
        XCTAssertFalse(replacement.original.isPlaying, "Without Hold note, releasing the key ends a loop")
    }

    func testCoarseAndFineTuningUpdateNewAuditionAndAppliedEncoding() async throws {
        let session = try TestSPC.session()
        defer { session.shutdown() }
        let snapshot = try XCTUnwrap(session.snapshot(sourceIndex: 1))
        let replacement = SPCReplacement(session: session, snapshot: snapshot, label: "Track 1")
        defer { replacement.close() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".brr")
        try Data(BRREncoder.file(.init(data: snapshot.data, blockCount: snapshot.blockCount,
                                     loopBlock: snapshot.loopBlock))).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        replacement.loadSource(url)
        for _ in 0..<200 where replacement.newSample.samples.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(replacement.newSample.samples.isEmpty)
        XCTAssertTrue(replacement.newSample.loopEnabled)
        replacement.newSample.hold = true
        let rate = replacement.newSample.rate
        replacement.options.semitones = 12
        replacement.options.cents = 50
        XCTAssertEqual(replacement.newSample.rate / rate, pow(2, 12.5 / 12), accuracy: 0.001)
        XCTAssertTrue(replacement.newSample.isPlaying)
        XCTAssertNil(replacement.newSample.errorMessage)
        let result = try replacement.apply()
        XCTAssertLessThan(result.blockCount, snapshot.blockCount)
        let pcm = BRRDecoder.decode(try XCTUnwrap(
            session.readRAM(result.start, count: result.blockCount * BRRDecoder.blockSize))).samples
        let frequency = try XCTUnwrap(PitchDetector.fundamentalFrequency(
            samples: pcm, sampleRate: BRRDecoder.sampleRate))
        let expected = try XCTUnwrap(snapshot.frequency) * pow(2, 12.5 / 12)
        XCTAssertEqual(frequency, expected, accuracy: expected * 0.02)
        replacement.options.semitones = -24
        replacement.options.cents = -100
        XCTAssertTrue(replacement.newSample.isPlaying)
        XCTAssertNil(replacement.newSample.errorMessage)
        XCTAssertTrue(replacement.newSample.hold)
    }

    func testBrowsingAndReturningKeepsTheSameSPCPlaying() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let spcURL = folder.appendingPathComponent("song.spc")
        try Data(TestSPC.image()).write(to: spcURL)
        let sampleURL = folder.appendingPathComponent("tone.brr")
        let sample = try XCTUnwrap(SPCSampleScanner.scan(image: TestSPC.image(), duration: 0.05).first)
        try Data(sample.data).write(to: sampleURL)
        let model = PreviewModel()
        model.select(BrowserNode(url: spcURL, isDirectory: false))
        let session = try XCTUnwrap(model.spc)
        defer { session.shutdown(); model.stop() }
        let handle = session.handle.emu
        model.select(BrowserNode(url: sampleURL, isDirectory: false))
        XCTAssertFalse(model.showingSPC)
        XCTAssertEqual(model.selected?.url, sampleURL)
        XCTAssertTrue(session.isPlaying)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertGreaterThan(session.playbackTime, 0)
        model.goToSPC()
        XCTAssertTrue(model.showingSPC)
        XCTAssertTrue(session.isPlaying)
        XCTAssertEqual(model.spc?.handle.emu, handle)
        XCTAssertFalse(model.isPlaying)
    }

    func testBrowserHoldLoopsUntilReleaseWithoutSelectingReplacement() async throws {
        let session = try TestSPC.session()
        defer { session.shutdown() }
        let snapshot = try XCTUnwrap(session.snapshot(sourceIndex: 1))
        let replacement = SPCReplacement(session: session, snapshot: snapshot, label: "Track 1")
        defer { replacement.close() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".brr")
        try Data(snapshot.data).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        replacement.previewSource(url, sustained: true)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(replacement.isAuditioningSource, "This short sample must still be looping")
        XCTAssertNil(replacement.newEditor)
        replacement.releaseBrowserPreview()
        XCTAssertFalse(replacement.isAuditioningSource)
    }
}
