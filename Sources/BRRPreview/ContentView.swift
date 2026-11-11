import BRRCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: PreviewModel

    var body: some View {
        NavigationSplitView {
            BrowserList(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 260)
        } detail: {
            DetailView(model: model)
        }
        .navigationTitle("BRR Preview")
    }
}

struct BrowserList: View {
    @ObservedObject var model: PreviewModel

    var body: some View {
        List {
            ForEach(model.visibleRows) { row in
                BrowserRowView(model: model, row: row)
            }
        }
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .top, alignment: .leading) {
            VStack(spacing: 6) {
                Button {
                    model.chooseFiles()
                } label: {
                    Label("Add Files", systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .help("Add individual .brr, .spc, or audio files to the browser")

                Button {
                    model.chooseFolders()
                } label: {
                    Label("Add Folders", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .help("Add one or more folders to browse for .brr files")
            }
            .buttonStyle(.bordered)
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
        .safeAreaInset(edge: .bottom, alignment: .leading) {
            if let spc = model.spc {
                SPCTransportView(session: spc)
                    .padding(10)
            }
        }
        .overlay {
            if model.roots.isEmpty {
                Text("Add files or folders containing .brr or audio files")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
        .background {
            BrowserBackdrop()
                .ignoresSafeArea()
        }
    }
}

/// Faint artwork stretched across the whole browser section. Loaded from the app bundle, so it is absent under `swift run`.
struct BrowserBackdrop: View {
    private static let image: NSImage? = Bundle.main
        .url(forResource: "Background", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image)
                .resizable()
                .opacity(0.15)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
        }
    }
}

struct BrowserRowView: View {
    @ObservedObject var model: PreviewModel
    let row: BrowserRow

    var body: some View {
        let node = row.node
        Group {
            if node.isDirectory {
                Button {
                    model.toggleExpanded(node)
                } label: {
                    Label {
                        Text(node.name)
                    } icon: {
                        Image(systemName: model.isExpanded(node) ? "folder.fill" : "folder")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if row.depth == 0 {
                        Button("Remove Folder") {
                            model.removeFolder(node)
                        }
                    }
                }
            } else {
                Button {
                    model.select(node)
                } label: {
                    Label(node.name, systemImage: node.isSPC ? "music.note.list" : (node.isAudio ? "music.note" : "waveform"))
                        .foregroundStyle(model.currentURL == node.url ? Color.accentColor : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onDrag {
                    NSItemProvider(contentsOf: node.url) ?? NSItemProvider()
                }
                .contextMenu {
                    if row.depth == 0 {
                        Button("Remove File") {
                            model.removeFolder(node)
                        }
                    }
                }
            }
        }
        .padding(.leading, CGFloat(row.depth) * 14)
    }
}

struct DetailView: View {
    @ObservedObject var model: PreviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let error = model.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
            }

            if let replacement = model.replacement {
                SPCReplaceView(model: model, replacement: replacement)
            } else if let spc = model.spc {
                SPCDetailView(model: model, session: spc)
            } else if let editor = model.editor {
                WaveEditorView(editor: editor)
            } else if let sample = model.selected {
                Text(sample.name)
                    .font(.title2.bold())
                Text(sample.url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                WaveformView(samples: sample.decoded.samples)
                    .frame(height: 140)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

                PitchInfoView(model: model)

                VStack(alignment: .leading, spacing: 6) {
                    Button("Guess Instrument") {
                        model.guessInstrument()
                    }
                    .help("Heuristic guess from the envelope and spectrum. It is not a trained model.")
                    if let guess = model.instrumentGuess {
                        InstrumentGuessView(guess: guess)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                    .frame(height: 96)

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("Duration").foregroundStyle(.secondary)
                        Text(String(format: "%.3f s at 32 kHz", sample.duration))
                    }
                    GridRow {
                        Text("Samples").foregroundStyle(.secondary)
                        Text("\(sample.decoded.samples.count)")
                    }
                    GridRow {
                        Text("BRR blocks").foregroundStyle(.secondary)
                        Text("\(sample.decoded.blockCount)")
                    }
                    GridRow {
                        Text("End flag").foregroundStyle(.secondary)
                        Text(sample.decoded.hasEndFlag ? "Set" : "Not set")
                    }
                    GridRow {
                        Text("Loop flag").foregroundStyle(.secondary)
                        Text(sample.decoded.hasLoopFlag ? "Set" : "Not set")
                    }
                }
                .font(.callout)

                HStack(spacing: 16) {
                    Button {
                        model.togglePlayback()
                    } label: {
                        Label(model.isPlaying ? "Stop" : "Play", systemImage: model.isPlaying ? "stop.fill" : "play.fill")
                            .frame(width: 80)
                    }

                    Toggle("Loop", isOn: $model.loopEnabled)
                        .help("While a note key is held, the note repeats from the file's loop point, or the whole sample if it has none. Release to stop. Tab toggles it.")
                }

                Text("Keys: Q–P and 2 3 5 6 7 0 9 play notes (hold to loop when Loop is on) · ←/→ octave · ↑/↓ sample · Space play/stop · Tab loop")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Spacer()
                Text("Select a .brr file to preview it, or an audio file (WAV, AIFF, CAF, M4A, MP3, OGG) to convert it.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct InstrumentGuessView: View {
    let guess: InstrumentGuess

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: "Guess: %@ (%.0f%%)", guess.instrument.displayName, guess.confidence * 100))
                .fontWeight(.medium)
            Text(guess.reasons.joined(separator: " · "))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PitchInfoView: View {
    @ObservedObject var model: PreviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let frequency = model.detectedFrequency {
                let midi = Note.midi(frequency: frequency)
                let nearest = Int(midi.rounded())
                let cents = (midi - Double(nearest)) * 100
                Text(String(format: "Detected %.1f Hz (nearest %@, %+.0f cents)", frequency, Note.name(midi: nearest), cents))
            } else {
                Text("No clear pitch detected. Playing at the native rate, with the filename note (or C4) as the reference.")
            }
            Text(String(format: "Playing %@ (%.1f Hz)", Note.name(midi: model.selectedNote), Note.frequency(midi: Double(model.selectedNote))))
                .fontWeight(.medium)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PianoView: View {
    @ObservedObject var model: PreviewModel

    private let whiteSemitones = [0, 2, 4, 5, 7, 9, 11, 12]
    /// Black keys with the index of the white key to their left.
    private let blackKeys: [(semitone: Int, whiteIndex: Int)] = [(1, 0), (3, 1), (6, 3), (8, 4), (10, 5)]

    var body: some View {
        HStack(spacing: 8) {
            octaveButton(systemImage: "minus", direction: -1)
            keyboard
            octaveButton(systemImage: "plus", direction: 1)
        }
    }

    /// Shows one octave starting at the C of the selected note.
    private var octaveBase: Int {
        model.keyboardOctaveBase
    }

    private var keyboard: some View {
        GeometryReader { geometry in
            let whiteWidth = geometry.size.width / CGFloat(whiteSemitones.count)
            let blackWidth = whiteWidth * 0.6
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(whiteSemitones, id: \.self) { semitone in
                        key(octaveBase + semitone, isBlack: false)
                            .frame(width: whiteWidth)
                    }
                }
                ForEach(blackKeys, id: \.semitone) { black in
                    key(octaveBase + black.semitone, isBlack: true)
                        .frame(width: blackWidth, height: geometry.size.height * 0.6)
                        .offset(x: CGFloat(black.whiteIndex + 1) * whiteWidth - blackWidth / 2)
                }
            }
        }
    }

    private func key(_ note: Int, isBlack: Bool) -> some View {
        let isSelected = note == model.selectedNote
        let isEnabled = model.noteRange.contains(note)
        let fill: Color = isSelected ? .accentColor : (isBlack ? .black : .white)
        return Text(note % 12 == 0 ? Note.name(midi: note) : "")
            .font(.caption2)
            .foregroundStyle(isBlack || isSelected ? Color.white : Color.black)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 4)
            .background(fill, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.6), lineWidth: 1))
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.4)
            .allowsHitTesting(isEnabled)
            .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity, perform: {}, onPressingChanged: { isDown in
                if isDown {
                    model.playNote(note, loop: model.loopEnabled)
                } else {
                    model.releaseNote(note)
                }
            })
            .help(Note.name(midi: note))
    }


    private func octaveButton(systemImage: String, direction: Int) -> some View {
        let target = model.selectedNote + 12 * direction
        return Button {
            model.shiftOctave(direction)
        } label: {
            Image(systemName: systemImage)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.bordered)
        .disabled(!model.noteRange.contains(target))
        .help(direction < 0 ? "Down one octave" : "Up one octave")
    }
}

struct WaveformView: View {
    let samples: [Int16]

    var body: some View {
        Canvas { context, size in
            guard !samples.isEmpty, size.width > 0 else { return }
            let mid = size.height / 2
            let columns = Int(size.width)
            var path = Path()
            for column in 0..<columns {
                let start = column * samples.count / columns
                let end = min(max(start + 1, (column + 1) * samples.count / columns), samples.count)
                var low = Int16.max
                var high = Int16.min
                for sample in samples[start..<end] {
                    low = min(low, sample)
                    high = max(high, sample)
                }
                let x = CGFloat(column) + 0.5
                let top = mid - CGFloat(high) / 32768 * mid
                let bottom = mid - CGFloat(low) / 32768 * mid
                path.move(to: CGPoint(x: x, y: top))
                path.addLine(to: CGPoint(x: x, y: max(bottom, top + 1)))
            }
            context.stroke(path, with: .color(.accentColor), lineWidth: 1)
        }
    }
}
