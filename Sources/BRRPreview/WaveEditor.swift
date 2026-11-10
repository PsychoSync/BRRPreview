import AppKit
import BRRCore
import Foundation
import UniformTypeIdentifiers

/// Edits an audio file and converts it to BRR. Playback uses the decoded exported file,
/// so the preview matches the sample the SNES will play.
@MainActor
final class WaveEditor: ObservableObject {
    enum DragMode: String, CaseIterable, Identifiable {
        case select = "Select"
        case setLoop = "Set loop"

        var id: String { rawValue }
    }

    let sourceURL: URL
    @Published private(set) var sample: EditableSample
    @Published private(set) var conversion: BRRConversion?
    @Published private(set) var isConverting = false
    /// The exported file decoded again, so playback includes its loop and rate.
    private(set) var previewDecoded: BRRDecoder.Result?
    @Published var outputRate: Double = BRRConverter.defaultOutputRate {
        didSet {
            guard outputRate != oldValue else { return }
            reconvert()
        }
    }
    /// Sample indices selected on the waveform. Edits act on this range, or the whole sample when nil.
    @Published private(set) var selection: Range<Int>?
    @Published var dragMode: DragMode = .select
    @Published var loopPreview = false {
        didSet {
            guard loopPreview != oldValue, isPlaying else { return }
            startPlayback()
        }
    }
    @Published private(set) var isPlaying = false
    @Published private(set) var status: String?
    @Published private(set) var errorMessage: String?
    private var undoStack: [EditableSample] = []
    private var loopDragSnapshot: EditableSample?

    private let player = SamplePlayer()
    private var conversionTask: Task<Void, Never>?

    init(url: URL) throws {
        sourceURL = url
        sample = try AudioImport.load(url)
        player.onFinished = { [weak self] in
            self?.isPlaying = false
        }
        reconvert()
    }

    var canUndo: Bool { !undoStack.isEmpty }

    /// The selection, or the whole sample when nothing is selected.
    var effectiveRange: Range<Int> { selection ?? 0..<sample.samples.count }

    // MARK: - Edits

    func crop() {
        guard let range = selection else { return }
        edit { $0.crop(range) }
    }

    func cut() {
        guard let range = selection else { return }
        edit { $0.cut(range) }
    }

    func reverse() {
        guard let range = selection else { return }
        edit { $0.reverse(range) }
    }

    func fadeIn() {
        let range = effectiveRange
        edit { $0.fadeIn(range) }
    }

    func fadeOut() {
        let range = effectiveRange
        edit { $0.fadeOut(range) }
    }

    func trimSilence() {
        edit { $0.trimSilence() }
    }

    func normalize() {
        edit { $0.normalize() }
    }

    func clearLoop() {
        edit(keepingSelection: true) { $0.loopStart = nil }
    }

    /// Starts a loop-point drag. The whole drag becomes one undo step.
    func beginLoopDrag() {
        loopDragSnapshot = sample
    }

    /// Moves the loop start while dragging. The BRR is re-encoded when the drag ends.
    func dragLoop(to index: Int) {
        sample.loopStart = clampedIndex(index)
    }

    func endLoopDrag() {
        guard let snapshot = loopDragSnapshot else { return }
        loopDragSnapshot = nil
        guard sample != snapshot else { return }
        undoStack.append(snapshot)
        reconvert()
    }

    /// Selects the samples from one index to another (inclusive), or clears the selection when they match.
    func selectRange(from start: Int, to end: Int) {
        let lower = clampedIndex(min(start, end))
        let upper = clampedIndex(max(start, end))
        selection = lower == upper ? nil : lower..<(upper + 1)
    }

    private func clampedIndex(_ index: Int) -> Int {
        min(max(index, 0), max(sample.samples.count - 1, 0))
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        sample = previous
        selection = nil
        reconvert()
    }

    private func edit(keepingSelection: Bool = false, _ change: (inout EditableSample) -> Void) {
        var updated = sample
        change(&updated)
        guard updated != sample else { return }
        undoStack.append(sample)
        sample = updated
        if !keepingSelection {
            selection = nil
        }
        reconvert()
    }

    // MARK: - Conversion

    private func reconvert() {
        let source = sample
        let rate = outputRate
        conversionTask?.cancel()
        isConverting = true
        conversionTask = Task { [weak self] in
            let converted = await Task.detached(priority: .userInitiated) {
                BRRConverter.convert(source, outputRate: rate)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.conversion = converted
            self.previewDecoded = BRRDecoder.decodeFile(converted.file)
            self.isConverting = false
            if self.isPlaying { self.startPlayback() }
        }
    }

    // MARK: - Playback

    func togglePreview() {
        if isPlaying {
            stopPlayback()
        } else {
            startPlayback()
        }
    }

    func stopPlayback() {
        player.stop()
        isPlaying = false
    }

    private func startPlayback() {
        guard let decoded = previewDecoded, !decoded.samples.isEmpty else { return }
        do {
            try player.play(
                decoded.samples,
                loopStart: decoded.loopStart,
                loop: loopPreview,
                rate: outputRate / BRRDecoder.sampleRate
            )
            isPlaying = true
            errorMessage = nil
        } catch {
            isPlaying = false
            errorMessage = "Audio playback failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Export

    func export() {
        guard let conversion else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "brr") ?? .data]
        panel.nameFieldStringValue = sourceURL.deletingPathExtension().lastPathComponent + ".brr"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(conversion.file).write(to: url)
            status = "Saved \(url.lastPathComponent) (\(conversion.file.count) bytes)"
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't save \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func stop() {
        conversionTask?.cancel()
        stopPlayback()
    }
}
