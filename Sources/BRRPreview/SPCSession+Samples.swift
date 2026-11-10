import BRRCore
import Foundation

enum OversizePolicy: String, CaseIterable, Identifiable {
    case refuse = "Refuse if too long"
    case truncate = "Truncate to original length"
    case relocate = "Relocate in free RAM"

    var id: String { rawValue }
}

struct ReplacementOptions: Equatable {
    var pitchMode: SampleReplacement.PitchMode = .matchOriginal
    var cents: Double = 0
    var oversize: OversizePolicy = .refuse
}

/// One track's sample as it sits in live SPC RAM.
struct SPCSampleSnapshot {
    let voice: Int
    let sourceIndex: Int
    let directoryAddress: Int
    let start: Int
    let loopAddress: Int
    /// BRR bytes from `start` through the block with END set.
    let data: [UInt8]
    let blockCount: Int
    /// Block where looping begins. Nil when the END block doesn't have the LOOP flag.
    let loopBlock: Int?
    /// Pitch of the decoded sample, when it's clearly pitched.
    let frequency: Double?
}

struct ReplacementResult {
    let start: Int
    let blockCount: Int
    let loopBlock: Int?
    let relocated: Bool
    let truncated: Bool
    let frequency: Double?
}

extension SPCSession {
    private static let blockSize = BRRDecoder.blockSize
    private static let directoryEntries = 64

    /// Reads the sample that voice `voice` is currently pointing at, from live RAM.
    func snapshot(voice: Int) -> SPCSampleSnapshot? {
        let sourceIndex = readDSP(voice * 0x10 + 4)
        let directoryAddress = directoryBase + sourceIndex * 4
        guard let entry = readRAM(directoryAddress, count: 4), let ram = readRAM(0, count: 0x10000) else {
            return nil
        }
        let start = Int(entry[0]) | Int(entry[1]) << 8
        let loopAddress = Int(entry[2]) | Int(entry[3]) << 8
        guard let blocks = SampleReplacement.chainBlockCount(in: ram, start: start) else { return nil }

        let data = Array(ram[start..<start + blocks * Self.blockSize])
        let endHeader = ram[start + (blocks - 1) * Self.blockSize]
        let loopBlock = endHeader & 0x02 != 0
            ? SampleReplacement.loopBlock(start: start, loopAddress: loopAddress, blockCount: blocks)
            : nil
        let decoded = BRRDecoder.decode(data).samples
        let frequency = PitchDetector.fundamentalFrequency(samples: decoded, sampleRate: Double(BRRDecoder.sampleRate))

        return SPCSampleSnapshot(voice: voice, sourceIndex: sourceIndex, directoryAddress: directoryAddress,
                                 start: start, loopAddress: loopAddress, data: data, blockCount: blocks,
                                 loopBlock: loopBlock, frequency: frequency)
    }

    /// The snapshot's audio as an editable sample, for the original side of the replacement page.
    func originalSample(_ snapshot: SPCSampleSnapshot) -> EditableSample {
        let decoded = BRRDecoder.decode(snapshot.data)
        let floats = decoded.samples.map { Float($0) / 32_768 }
        let loopStart = snapshot.loopBlock.map { $0 * BRRDecoder.samplesPerBlock }
        return EditableSample(samples: floats, sourceRate: Double(BRRDecoder.sampleRate), loopStart: loopStart)
    }

    /// Writes the sample as a BRR file that keeps the original loop point, plus a `.txt` metadata sidecar next to it.
    func extract(_ snapshot: SPCSampleSnapshot, to brrURL: URL) throws -> URL {
        let file = BRREncoder.file(BRREncoder.Encoding(data: snapshot.data, blockCount: snapshot.blockCount,
                                                       loopBlock: snapshot.loopBlock))
        try Data(file).write(to: brrURL, options: .atomic)

        let sidecar = brrURL.deletingPathExtension().appendingPathExtension("txt")
        try metadataText(for: snapshot).write(to: sidecar, atomically: true, encoding: .utf8)
        return sidecar
    }

    private func metadataText(for snapshot: SPCSampleSnapshot) -> String {
        func hex(_ value: Int, digits: Int) -> String {
            String(format: "$%0\(digits)X", value)
        }

        var lines = [
            "Source SPC: \(url.lastPathComponent)",
            "Song: \(songTitle)",
            "Game: \(gameTitle)",
            "Author: \(authorName)",
            "Voice: \(snapshot.voice)",
            "Sample index (SRCN): \(snapshot.sourceIndex) (\(hex(snapshot.sourceIndex, digits: 2)))",
            "Directory address: \(hex(snapshot.directoryAddress, digits: 4))",
            "Start address: \(hex(snapshot.start, digits: 4))",
            "Loop address: \(hex(snapshot.loopAddress, digits: 4))",
            "Blocks: \(snapshot.blockCount) (\(snapshot.data.count) bytes)",
            "Sample rate: \(BRRDecoder.sampleRate) Hz (native)",
            "Pitch register: 0x1000",
        ]
        if let loopBlock = snapshot.loopBlock {
            lines.append("Loop block: \(loopBlock) (sample index \(loopBlock * BRRDecoder.samplesPerBlock))")
        } else {
            lines.append("Loop: none")
        }
        if let frequency = snapshot.frequency {
            let midi = Int(Note.midi(frequency: frequency).rounded())
            lines.append(String(format: "Detected pitch: %.2f Hz (%@)", frequency, Note.name(midi: midi)))
        } else {
            lines.append("Detected pitch: unpitched")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Converts `sample` to BRR, places it in the track's slot, and updates the directory entry.
    /// Only the chosen sample index changes; other voices using the same index also pick up the new sound.
    @discardableResult
    func replace(_ snapshot: SPCSampleSnapshot, with sample: EditableSample,
                 options: ReplacementOptions) throws -> ReplacementResult {
        let newFrequency = Self.pitch(of: sample)
        let rate = SampleReplacement.declaredSourceRate(
            actualRate: sample.sourceRate,
            newFrequency: newFrequency,
            originalFrequency: snapshot.frequency,
            mode: options.pitchMode,
            cents: options.cents
        )
        let adjusted = EditableSample(samples: sample.samples, sourceRate: rate, loopStart: sample.loopStart)
        var encoding = BRRConverter.convert(adjusted, outputRate: Double(BRRDecoder.sampleRate)).encoding

        var start = snapshot.start
        var relocated = false
        var truncated = false
        if encoding.blockCount > snapshot.blockCount {
            switch options.oversize {
            case .refuse:
                throw SPCError(message: "The new sample needs \(encoding.blockCount) BRR blocks but the original slot holds \(snapshot.blockCount). Shorten it, or choose Truncate or Relocate.")
            case .truncate:
                encoding = Self.truncated(encoding, to: snapshot.blockCount)
                truncated = true
            case .relocate:
                guard let free = freeRun(bytes: encoding.blockCount * Self.blockSize) else {
                    throw SPCError(message: "No free RAM block of \(encoding.blockCount * Self.blockSize) bytes was found for relocation.")
                }
                start = free
                relocated = true
            }
        }

        let loopAddress = encoding.loopBlock.map { start + $0 * Self.blockSize } ?? start
        try writeRAM(start, encoding.data)
        try writeRAM(snapshot.directoryAddress, [
            UInt8(start & 0xFF), UInt8(start >> 8),
            UInt8(loopAddress & 0xFF), UInt8(loopAddress >> 8),
        ])

        return ReplacementResult(start: start, blockCount: encoding.blockCount, loopBlock: encoding.loopBlock,
                                 relocated: relocated, truncated: truncated, frequency: newFrequency)
    }

    private static func pitch(of sample: EditableSample) -> Double? {
        let pcm = sample.samples.map { Int16(clamping: Int(($0 * 32_768).rounded())) }
        return PitchDetector.fundamentalFrequency(samples: pcm, sampleRate: sample.sourceRate)
    }

    /// Keeps the first `blocks` blocks and marks the last one END, clearing LOOP unless the loop point still fits.
    private static func truncated(_ encoding: BRREncoder.Encoding, to blocks: Int) -> BRREncoder.Encoding {
        var data = Array(encoding.data.prefix(blocks * blockSize))
        let last = (blocks - 1) * blockSize
        let loopBlock = encoding.loopBlock.flatMap { $0 < blocks ? $0 : nil }
        data[last] |= 0x01
        if loopBlock != nil {
            data[last] |= 0x02
        } else {
            data[last] &= ~0x02
        }
        return BRREncoder.Encoding(data: data, blockCount: blocks, loopBlock: loopBlock)
    }

    /// Finds `bytes` of zero-filled RAM that no directory entry, the DSP page, the echo buffer, or the
    /// boot ROM and zero page use. This is a heuristic: the song may use zeroed RAM later.
    private func freeRun(bytes: Int) -> Int? {
        guard let ram = readRAM(0, count: 0x10000) else { return nil }
        var reserved = [Bool](repeating: false, count: 0x10000)
        func reserve(_ range: Range<Int>) {
            for address in range where address >= 0 && address < reserved.count {
                reserved[address] = true
            }
        }

        reserve(0..<0x400)
        reserve(0xFFC0..<0x10000)
        let directory = directoryBase
        reserve(directory..<directory + 0x100)
        let echoStart = readDSP(0x6D) << 8
        let echoLength = max((readDSP(0x7D) & 0x0F) * 0x800, 4)
        reserve(echoStart..<echoStart + echoLength)
        for index in 0..<Self.directoryEntries {
            let entry = directory + index * 4
            let start = Int(ram[entry]) | Int(ram[entry + 1]) << 8
            guard let blocks = SampleReplacement.chainBlockCount(in: ram, start: start) else { continue }
            reserve(start..<start + blocks * Self.blockSize)
        }

        var run = 0
        for address in 0x400..<0xFFC0 {
            if !reserved[address] && ram[address] == 0 {
                run += 1
                if run == bytes {
                    return address - bytes + 1
                }
            } else {
                run = 0
            }
        }
        return nil
    }
}
