import BRRCore
import SwiftUI

/// State for replacing one track's sample: the live original, the chosen new sample, and the options.
@MainActor
final class SPCReplacement: ObservableObject {
    let session: SPCSession
    let snapshot: SPCSampleSnapshot
    /// What the user sees for this sample, such as "Voice 3" or "Track 2".
    let label: String
    let originalSamples: [Int16]

    @Published var options = ReplacementOptions()
    @Published private(set) var newEditor: WaveEditor?
    /// The original and a browser preview share one player, so only one of them sounds at a time.
    @Published private(set) var isAuditioningOriginal = false
    @Published private(set) var isAuditioningSource = false
    @Published var errorMessage: String?

    private let player = SamplePlayer()

    init(session: SPCSession, snapshot: SPCSampleSnapshot, label: String) {
        self.session = session
        self.snapshot = snapshot
        self.label = label
        self.originalSamples = BRRDecoder.decode(snapshot.data).samples
        player.onFinished = { [weak self] in
            Task { @MainActor in self?.stopAuditions() }
        }
    }

    var originalSummary: String {
        var parts = [String(format: "SRCN $%02X", snapshot.sourceIndex), "\(snapshot.blockCount) blocks"]
        parts.append(snapshot.loopBlock.map { "loops from block \($0)" } ?? "no loop")
        if let frequency = snapshot.frequency {
            let note = Note.name(midi: Int(Note.midi(frequency: frequency).rounded()))
            parts.append("\(String(format: "%.1f", frequency)) Hz (\(note))")
        } else {
            parts.append("unpitched")
        }
        return parts.joined(separator: " · ")
    }

    func toggleOriginalPlayback() {
        if isAuditioningOriginal {
            stopAuditions()
            return
        }
        newEditor?.stopPlayback()
        do {
            try player.play(originalSamples, loopStart: snapshot.loopBlock.map { $0 * BRRDecoder.samplesPerBlock },
                            loop: false, rate: 1)
            isAuditioningOriginal = true
            isAuditioningSource = false
            errorMessage = nil
        } catch {
            errorMessage = "Audio playback failed: \(error.localizedDescription)"
        }
    }

    /// Plays a sample from the browser without choosing it. It plays once at its native 32 kHz speed.
    func previewSource(_ url: URL) {
        newEditor?.stopPlayback()
        do {
            let decoded: BRRDecoder.Result
            if url.pathExtension.lowercased() == "brr" {
                decoded = BRRDecoder.decodeFile([UInt8](try Data(contentsOf: url)))
            } else {
                let sample = try AudioImport.load(url)
                decoded = BRRDecoder.decodeFile(BRRConverter.convert(sample, outputRate: BRRDecoder.sampleRate).file)
            }
            guard !decoded.samples.isEmpty else {
                throw SPCError(message: "\(url.lastPathComponent) doesn't contain any samples.")
            }
            try player.play(decoded.samples, loopStart: nil, loop: false, rate: 1)
            isAuditioningSource = true
            isAuditioningOriginal = false
            errorMessage = nil
        } catch {
            stopAuditions()
            errorMessage = "Couldn't preview \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Space during a replacement: stops whatever sample is playing here, otherwise toggles the new sample.
    func togglePreview() {
        if isAuditioningOriginal || isAuditioningSource {
            stopAuditions()
        } else {
            newEditor?.togglePreview()
        }
    }

    /// Loads a sample file as the new sample. Audio and BRR files are accepted.
    func loadSource(_ url: URL) {
        guard AudioImport.sampleExtensions.contains(url.pathExtension.lowercased()) else {
            errorMessage = "\(url.lastPathComponent) isn't a sample file."
            return
        }
        do {
            let editor = try WaveEditor(url: url)
            newEditor?.stop()
            newEditor = editor
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func apply() throws -> ReplacementResult {
        guard let newEditor else {
            throw SPCError(message: "Select a new sample first.")
        }
        return try session.replace(snapshot, with: newEditor.sample, options: options)
    }

    private func stopAuditions() {
        player.stop()
        isAuditioningOriginal = false
        isAuditioningSource = false
    }

    func close() {
        stopAuditions()
        newEditor?.stop()
        newEditor = nil
    }
}

/// Side-by-side page for replacing a track's sample. The original sits above the new sample's editor.
struct SPCReplaceView: View {
    @ObservedObject var model: PreviewModel
    @ObservedObject var replacement: SPCReplacement

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if let error = replacement.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                }

                originalSection
                Divider()
                newSection
                Divider()
                optionsSection
            }
            .padding(.bottom, 8)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Replace \(replacement.label)")
                    .font(.title2.bold())
                Text("The song keeps playing. The new sample is heard the next time this track's sample plays.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") {
                model.cancelReplacement()
            }
            .keyboardShortcut(.cancelAction)
            Button("Apply") {
                model.applyReplacement()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(replacement.newEditor == nil)
        }
    }

    private var originalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Original")
                .font(.headline)
            Text(replacement.originalSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
            WaveformView(samples: replacement.originalSamples)
                .frame(height: 120)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            Button {
                replacement.toggleOriginalPlayback()
            } label: {
                Label(replacement.isAuditioningOriginal ? "Stop" : "Play original",
                      systemImage: replacement.isAuditioningOriginal ? "stop.fill" : "play.fill")
                    .frame(width: 130)
            }
        }
    }

    @ViewBuilder
    private var newSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("New sample")
                .font(.headline)

            if let editor = replacement.newEditor {
                HStack {
                    Text(editor.sourceURL.lastPathComponent)
                        .lineLimit(1)
                    Spacer()
                    Button("Choose different…") {
                        model.chooseReplacementSource()
                    }
                }
                WaveEditorView(editor: editor, showsExportControls: false)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("Drag a sample from the browser here")
                        .foregroundStyle(.secondary)
                    Text("Click a browser sample to preview it")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Button("Select new sample…") {
                        model.chooseReplacementSource()
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 140)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(style: StrokeStyle(lineWidth: 1, dash: [6]))
                        .foregroundStyle(.secondary)
                )
            }
        }
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Options")
                .font(.headline)

            Picker("Pitch", selection: $replacement.options.pitchMode) {
                ForEach([SampleReplacement.PitchMode.matchOriginal, .keepOwn], id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .frame(maxWidth: 320)

            HStack {
                Text("Fine tune")
                Slider(value: $replacement.options.cents, in: -100...100, step: 1)
                    .frame(maxWidth: 240)
                Text("\(Int(replacement.options.cents)) cents")
                    .monospacedDigit()
                    .frame(width: 80, alignment: .leading)
            }

            Picker("If it's longer than the original", selection: $replacement.options.oversize) {
                ForEach(OversizePolicy.allCases) { policy in
                    Text(policy.rawValue).tag(policy)
                }
            }
            .frame(maxWidth: 420)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) else {
            return false
        }
        let target = replacement
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in target.loadSource(url) }
        }
        return true
    }
}
