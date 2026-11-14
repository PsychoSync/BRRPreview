import BRRCore
import Combine
import SwiftUI

/// State for replacing one track's sample: the live original, the chosen new sample, and the options.
@MainActor
final class SPCReplacement: ObservableObject {
    enum Section: String, CaseIterable {
        case original = "Original"
        case new = "New sample"
    }

    let session: SPCSession
    let snapshot: SPCSampleSnapshot
    /// What the user sees for this sample, such as "Voice 3" or "Track 2".
    let label: String
    let originalSamples: [Int16]

    @Published var options = ReplacementOptions() {
        didSet { updateNewPitch() }
    }
    @Published private(set) var newEditor: WaveEditor?
    @Published private(set) var selectedSection: Section = .original
    @Published private(set) var browserURL: URL?
    @Published private(set) var isAuditioningSource = false
    @Published var errorMessage: String?

    let original: SampleAudition
    let newSample: SampleAudition
    var activeAudition: SampleAudition { selectedSection == .original ? original : newSample }
    var noteRange: ClosedRange<Int> {
        let center = Int(Note.midi(frequency: original.referenceFrequency).rounded())
        return max(0, center - 24)...min(127, center + 24)
    }
    private let player = SamplePlayer()
    private var editorSubscription: AnyCancellable?
    private var auditionSubscriptions: Set<AnyCancellable> = []
    private var newFrequency: Double?
    private var heldKeys: [Character: (Section, Int)] = [:]
    private var browserPressStart: Date?
    private var browserDecoded: BRRDecoder.Result?

    init(session: SPCSession, snapshot: SPCSampleSnapshot, label: String) {
        self.session = session
        self.snapshot = snapshot
        self.label = label
        self.originalSamples = BRRDecoder.decode(snapshot.data).samples
        let reference = snapshot.frequency ?? Note.frequency(midi: Double(Note.referenceMIDI))
        let note = min(127, max(0, Int(Note.midi(frequency: reference).rounded())))
        original = SampleAudition(referenceFrequency: reference, note: note)
        newSample = SampleAudition(referenceFrequency: reference, note: note)
        original.setSample(originalSamples, loopStart: snapshot.loopBlock.map { $0 * BRRDecoder.samplesPerBlock })
        original.loopEnabled = snapshot.loopBlock != nil
        for audition in [original, newSample] {
            audition.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &auditionSubscriptions)
        }
        newSample.$volume.sink { [weak self] value in self?.player.volume = value }
            .store(in: &auditionSubscriptions)
        player.onFinished = { [weak self] in
            self?.isAuditioningSource = false
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

    func selectSection(_ section: Section) {
        guard section != selectedSection else { return }
        if !activeAudition.hold { activeAudition.stop() }
        stopBrowserPreview()
        selectedSection = section
    }

    func playNote(_ midi: Int) {
        stopBrowserPreview()
        activeAudition.playNote(midi)
    }

    func shiftOctave(_ delta: Int) {
        let note = activeAudition.note + delta * 12
        guard noteRange.contains(note) else { return }
        playNote(note)
    }

    func keyDown(_ key: Character, repeating: Bool) -> Bool {
        guard let midi = PianoKeys.midi(for: key, octaveBase: activeAudition.note / 12 * 12) else { return false }
        if !repeating, noteRange.contains(midi) {
            heldKeys[key] = (selectedSection, midi)
            playNote(midi)
        }
        return true
    }

    func keyUp(_ key: Character) -> Bool {
        guard let (section, midi) = heldKeys.removeValue(forKey: key) else { return false }
        (section == .original ? original : newSample).releaseNote(midi)
        return true
    }

    func toggleLoop() { activeAudition.loopEnabled.toggle() }

    func previewSource(_ url: URL, sustained: Bool = false) {
        if !original.hold { original.stop() }
        if !newSample.hold { newSample.stop() }
        stopBrowserPreview()
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
            browserDecoded = decoded
            browserURL = url
            browserPressStart = sustained ? Date() : nil
            player.volume = newSample.volume
            try player.play(decoded.samples, loopStart: decoded.loopStart,
                            loop: sustained && (decoded.loopStart != nil || decoded.hasLoopFlag), rate: 1)
            isAuditioningSource = true
            errorMessage = nil
        } catch {
            stopBrowserPreview()
            errorMessage = "Couldn't preview \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func releaseBrowserPreview() {
        guard let start = browserPressStart, isAuditioningSource else { return }
        browserPressStart = nil
        // A short click auditions once; a held press sustains until release.
        if Date().timeIntervalSince(start) < 0.2, let decoded = browserDecoded {
            do {
                try player.play(decoded.samples, loopStart: nil, loop: false, rate: 1)
            } catch {
                stopBrowserPreview()
                errorMessage = "Audio playback failed: \(error.localizedDescription)"
            }
        } else {
            stopBrowserPreview()
        }
    }

    func stopBrowserPreview() {
        player.stop()
        isAuditioningSource = false
        browserPressStart = nil
    }

    func togglePreview() {
        if isAuditioningSource {
            stopBrowserPreview()
        } else {
            activeAudition.togglePlayback()
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
            stopBrowserPreview()
            newSample.releaseAll()
            newSample.setSample([], loopStart: nil)
            newFrequency = nil
            newEditor?.stop()
            editor.outputRate = BRRDecoder.sampleRate
            newEditor = editor
            newSample.loopEnabled = editor.sample.loopStart != nil
            editorSubscription = editor.$previewDecoded.compactMap { $0 }.sink { [weak self] decoded in
                guard let self else { return }
                self.newFrequency = PitchDetector.fundamentalFrequency(
                    samples: decoded.samples, sampleRate: BRRDecoder.sampleRate)
                self.updateNewPitch()
                self.newSample.setSample(decoded.samples, loopStart: decoded.loopStart)
            }
            selectSection(.new)
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

    private func updateNewPitch() {
        let ratio = SampleReplacement.declaredSourceRate(
            actualRate: BRRDecoder.sampleRate, newFrequency: newFrequency,
            originalFrequency: snapshot.frequency, mode: options.pitchMode, cents: options.totalCents)
        newSample.pitchMultiplier = ratio / BRRDecoder.sampleRate
    }

    func releaseAllNotes() {
        heldKeys.removeAll()
        original.releaseAll()
        newSample.releaseAll()
        stopBrowserPreview()
    }

    func close() {
        releaseAllNotes()
        editorSubscription = nil
        newEditor?.stop()
        newEditor = nil
    }
}

/// The selected sample owns the shared piano. Held notes can keep sounding while the other side is edited.
struct SPCReplaceView: View {
    @ObservedObject var model: PreviewModel
    @ObservedObject var replacement: SPCReplacement

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header

                if let error = replacement.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                }

                originalSection
                VStack(spacing: 4) {
                    Text("Piano / keyboard: \(replacement.selectedSection.rawValue)")
                        .font(.caption).foregroundStyle(.secondary)
                    NoteKeyboardView(selectedNote: replacement.activeAudition.note, noteRange: replacement.noteRange,
                                     noteOn: replacement.playNote,
                                     noteOff: replacement.activeAudition.releaseNote,
                                     shiftOctave: replacement.shiftOctave)
                        .frame(height: 72)
                    Text("Q–P / number keys: notes · ←/→: octave · Space: play/stop · Tab: loop")
                        .font(.caption2).foregroundStyle(.secondary)
                }
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionButton(.original)
                Spacer()
                AuditionControls(audition: replacement.original)
            }
            Text(replacement.originalSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
            WaveformView(samples: replacement.originalSamples)
                .frame(height: 65)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(8)
        .background(panelBackground(.original))
        .simultaneousGesture(TapGesture().onEnded { replacement.selectSection(.original) })
    }

    @ViewBuilder
    private var newSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionButton(.new)
                Spacer()
                AuditionControls(audition: replacement.newSample)
                    .disabled(replacement.newEditor == nil)
            }

            if let editor = replacement.newEditor {
                HStack {
                    Text(editor.sourceURL.lastPathComponent)
                        .lineLimit(1)
                    Spacer()
                    Button("Choose different…") {
                        model.chooseReplacementSource()
                    }
                }
                WaveEditorView(editor: editor, showsExportControls: false, showsPlaybackControls: false)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("Drag a sample from the browser here")
                        .foregroundStyle(.secondary)
                    Text("Click to preview; hold to sustain with its loop")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Button("Select new sample…") {
                        model.chooseReplacementSource()
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 90)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(style: StrokeStyle(lineWidth: 1, dash: [6]))
                        .foregroundStyle(.secondary)
                )
            }
        }
        .padding(8)
        .background(panelBackground(.new))
        .simultaneousGesture(TapGesture().onEnded { replacement.selectSection(.new) })
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Pitch", selection: $replacement.options.pitchMode) {
                    ForEach([SampleReplacement.PitchMode.matchOriginal, .keepOwn], id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .frame(maxWidth: .infinity)
                Picker("Length", selection: $replacement.options.oversize) {
                    ForEach(OversizePolicy.allCases) { policy in
                        Text(policy.rawValue).tag(policy)
                    }
                }
                .frame(maxWidth: .infinity)
            }

            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pitch: \(Int(replacement.options.semitones)) semitones")
                    Slider(value: $replacement.options.semitones, in: -24...24, step: 1)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fine tune: \(Int(replacement.options.cents)) cents")
                    Slider(value: $replacement.options.cents, in: -100...100, step: 1)
                }
                Button("Reset") {
                    replacement.options.semitones = 0
                    replacement.options.cents = 0
                }
            }
            .font(.caption)
            Text(
                "Pitch and fine tune affect the new sample immediately and are included when applied. Volumes are preview-only."
            )
            .font(.caption2).foregroundStyle(.secondary)
            if let error = replacement.original.errorMessage ?? replacement.newSample.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func sectionButton(_ section: SPCReplacement.Section) -> some View {
        Button {
            replacement.selectSection(section)
        } label: {
            Label(
                section.rawValue,
                systemImage: replacement.selectedSection == section ? "largecircle.fill.circle" : "circle"
            )
            .font(.headline)
        }
        .buttonStyle(.plain)
    }

    private func panelBackground(_ section: SPCReplacement.Section) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.secondary.opacity(0.05))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(replacement.selectedSection == section ? Color.accentColor : Color.secondary.opacity(0.2),
                        lineWidth: replacement.selectedSection == section ? 2 : 1))
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

private struct AuditionControls: View {
    @ObservedObject var audition: SampleAudition

    var body: some View {
        HStack(spacing: 10) {
            Button(action: audition.togglePlayback) {
                Image(systemName: audition.isPlaying ? "stop.fill" : "play.fill")
            }
            .help("Play or stop this sample")
            Toggle("Loop", isOn: $audition.loopEnabled)
            Toggle("Hold note", isOn: $audition.hold)
                .help("Latch the note after releasing the key. Enable Loop to repeat continuously.")
            HStack(spacing: 3) {
                VolumeKnob(value: $audition.volume)
                    .frame(width: 28, height: 28)
                Text("\(Int(audition.volume * 100))%")
                    .monospacedDigit().font(.caption)
                    .frame(width: 32, alignment: .trailing)
            }
            .help("Independent preview volume; does not change the exported sample")
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
    }
}

private struct VolumeKnob: NSViewRepresentable {
    @Binding var value: Float

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: Double(value), minValue: 0, maxValue: 1,
                              target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        slider.sliderType = .circular
        slider.isContinuous = true
        slider.setAccessibilityLabel("Preview volume")
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.parent = self
        slider.floatValue = value
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject {
        var parent: VolumeKnob
        init(parent: VolumeKnob) { self.parent = parent }
        @objc func changed(_ sender: NSSlider) { parent.value = sender.floatValue }
    }
}
