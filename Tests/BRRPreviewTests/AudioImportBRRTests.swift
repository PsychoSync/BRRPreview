import XCTest
@testable import BRRCore
@testable import BRRPreview

final class AudioImportBRRTests: XCTestCase {
    private func tone(count: Int) -> [Float] {
        (0..<count).map { i in 0.5 * Float(sin(2 * Double.pi * 440 * Double(i) / 32_000)) }
    }

    func testBRRIsAcceptedAsSampleButNotAsAudio() {
        XCTAssertTrue(AudioImport.sampleExtensions.contains("brr"))
        XCTAssertFalse(AudioImport.extensions.contains("brr"))
        XCTAssertTrue(AudioImport.sampleExtensions.contains("wav"))
    }

    func testLoadingBRRDecodesToThirtyTwoKilohertzSamples() throws {
        let encoded = BRRConverter.convert(EditableSample(samples: tone(count: 1_600), sourceRate: 32_000),
                                           outputRate: 32_000).file
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-\(UUID().uuidString).brr")
        try Data(encoded).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let sample = try AudioImport.load(url)
        let decoded = BRRDecoder.decodeFile(encoded)

        XCTAssertEqual(sample.sourceRate, BRRDecoder.sampleRate)
        XCTAssertEqual(sample.samples.count, decoded.samples.count)
        XCTAssertEqual(sample.loopStart, decoded.loopStart)
        XCTAssertEqual(Int16((sample.samples[100] * 32_768).rounded()), decoded.samples[100])
    }

    func testBRRImportKeepsStoredLoopAndLoopsRawFilesFromStart() throws {
        let encoding = BRREncoder.encode(tone(count: 1600), loopStart: 160)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".brr")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(BRREncoder.file(encoding)).write(to: url)
        XCTAssertEqual(try AudioImport.load(url).loopStart, 160)
        try Data(encoding.data).write(to: url)
        XCTAssertEqual(try AudioImport.load(url).loopStart, 0)
    }
}
