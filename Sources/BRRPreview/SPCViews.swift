import BRRCore
import SwiftUI

/// Play, pause, stop, and volume for the loaded SPC. Sits in the sidebar's lower left corner.
struct SPCTransportView: View {
    @ObservedObject var session: SPCSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Button {
                    session.togglePlayback()
                } label: {
                    Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 18)
                }
                .help(session.isPlaying ? "Pause" : "Play")

                Button {
                    session.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .frame(width: 18)
                }
                .help("Stop and restart the song")
            }
            .buttonStyle(.borderless)
            .font(.title3)

            HStack(spacing: 6) {
                Image(systemName: "speaker.fill")
                    .foregroundStyle(.secondary)
                Slider(value: $session.volume, in: 0...1)
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(TransportGlass())
    }
}

/// Liquid Glass on macOS 26 and later. Earlier systems get a translucent material instead.
private struct TransportGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10))
        } else {
            content.background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.regularMaterial)
                    .opacity(0.55)
            }
        }
    }
}

/// The SPC's header, its save action, and one row per DSP voice.
struct SPCDetailView: View {
    @ObservedObject var model: PreviewModel
    @ObservedObject var session: SPCSession
    @State private var showingSaveSheet = false
    /// Tags the user confirmed in the save sheet. The save panel opens once the sheet has closed.
    @State private var confirmedTags: SPCExtendedTags?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = session.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
            }

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.songTitle.isEmpty ? session.url.lastPathComponent : session.songTitle)
                        .font(.title2.bold())
                    if !detailLine.isEmpty {
                        Text(detailLine)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                HStack {
                    Button("Extract All Samples…") {
                        model.extractAllSamples()
                    }
                    .help("Save every distinct sample in the song as BRR, each with a metadata sidecar")

                    Button("Save SPC As…") {
                        showingSaveSheet = true
                    }
                    .help("Review the song's extended tags, then save the current emulator state, including any replaced samples")
                }
            }

            Text(session.url.deletingLastPathComponent().path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if let status = session.statusMessage {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Picker("View", selection: $session.viewMode) {
                ForEach(SPCViewMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 240)

            ScrollView {
                VStack(spacing: 8) {
                    switch session.viewMode {
                    case .voices:
                        ForEach(session.voices) { voice in
                            SPCVoiceRow(model: model, session: session, voice: voice)
                        }
                    case .tracks:
                        if session.tracks.isEmpty {
                            Text("Tracks appear as the song plays. Each sample gets one track, however many voices play it.")
                                .foregroundStyle(.secondary)
                                .padding(.top, 24)
                        }
                        ForEach(session.tracks) { track in
                            SPCTrackRow(model: model, session: session, track: track)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingSaveSheet, onDismiss: {
            if let tags = confirmedTags {
                confirmedTags = nil
                model.saveSPC(tags: tags)
            }
        }) {
            SPCSaveSheet(fileName: session.url.lastPathComponent, initialTags: session.extendedTags) { tags in
                confirmedTags = tags
            }
        }
    }

    private var detailLine: String {
        [session.gameTitle, session.authorName].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// The latest guess for one SRCN. It is kept with its SRCN so a row can hide it once the sample changes.
struct SRCNGuess: Equatable {
    let sourceIndex: Int
    let guess: InstrumentGuess?
}

/// The guess line under a row. It only appears while the row still plays the sample that was guessed.
struct SRCNGuessLine: View {
    let guess: SRCNGuess?
    let sourceIndex: Int

    var body: some View {
        if let guess, guess.sourceIndex == sourceIndex {
            if let result = guess.guess {
                InstrumentGuessView(guess: result)
                    .padding(.horizontal, 8)
            } else {
                Text("No guess: the sample is empty or can't be read.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }
        }
    }
}

/// One DSP voice: its sample, live spectrum, mute and solo, and extract or replace actions.
struct SPCVoiceRow: View {
    @ObservedObject var model: PreviewModel
    @ObservedObject var session: SPCSession
    let voice: SPCVoiceState
    @State private var guess: SRCNGuess?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row
            SRCNGuessLine(guess: guess, sourceIndex: voice.sampleIndex)
        }
    }

    private var row: some View {
        let muted = session.mutedVoices.contains(voice.index)
        let soloed = session.soloVoices.contains(voice.index)

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Voice \(voice.index + 1)")
                    .font(.headline)
                Text(String(format: "SRCN $%02X", voice.sampleIndex))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(noteName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 110, alignment: .leading)

            SpectrumView(bars: voice.bars)
                .frame(height: 44)
                .opacity(muted ? 0.35 : 1)

            HStack(spacing: 6) {
                Button("M") {
                    session.toggleMute(voice.index)
                }
                .tint(muted ? Color.red : Color.secondary)
                .help("Mute this track")

                Button("S") {
                    session.toggleSolo(voice.index)
                }
                .tint(soloed ? Color.yellow : Color.secondary)
                .help("Solo this track")

                Button("Guess") {
                    guess = SRCNGuess(sourceIndex: voice.sampleIndex,
                                      guess: session.guessInstrument(sourceIndex: voice.sampleIndex))
                }
                .help("Heuristic guess at this sample's instrument type. It is not a trained model.")

                Button("Extract…") {
                    model.extractSample(voice: voice.index)
                }
                .help("Save this voice's BRR sample with its loop point and metadata")

                Button("Replace…") {
                    model.beginReplacement(voice: voice.index)
                }
                .help("Replace this voice's sample while the song keeps playing")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var noteName: String {
        guard voice.pitch > 0, voice.envelope > 0 else { return "silent" }
        return Note.name(midi: Int(Note.midi(frequency: voice.frequency).rounded()))
    }
}

/// One sample heard in the song. It keeps its track number as voices come and go.
struct SPCTrackRow: View {
    @ObservedObject var model: PreviewModel
    @ObservedObject var session: SPCSession
    let track: SPCTrackState
    @State private var guess: SRCNGuess?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row
            SRCNGuessLine(guess: guess, sourceIndex: track.sourceIndex)
        }
    }

    private var row: some View {
        let muted = session.mutedTracks.contains(track.sourceIndex)
        let soloed = session.soloTracks.contains(track.sourceIndex)

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Track \(track.number)")
                    .font(.headline)
                Text(String(format: "SRCN $%02X", track.sourceIndex))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(liveLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 110, alignment: .leading)
            .help("Voices used: " + voicesUsedLine)

            VStack(spacing: 4) {
                SpectrumView(bars: track.bars)
                    .frame(height: 30)
                VoiceTimelineView(track: track, now: session.playbackTime, laneCount: session.voices.count)
                    .frame(height: 56)
            }
            .opacity(muted ? 0.35 : 1)

            HStack(spacing: 6) {
                Button("M") {
                    session.toggleTrackMute(track.sourceIndex)
                }
                .tint(muted ? Color.red : Color.secondary)
                .help("Mute this track")

                Button("S") {
                    session.toggleTrackSolo(track.sourceIndex)
                }
                .tint(soloed ? Color.yellow : Color.secondary)
                .help("Solo this track")

                Button("Guess") {
                    guess = SRCNGuess(sourceIndex: track.sourceIndex,
                                      guess: session.guessInstrument(sourceIndex: track.sourceIndex))
                }
                .help("Heuristic guess at this sample's instrument type. It is not a trained model.")

                Button("Extract…") {
                    model.extractSample(track: track)
                }
                .help("Save this track's BRR sample with its loop point and metadata")

                Button("Replace…") {
                    model.beginReplacement(track: track)
                }
                .help("Replace this track's sample everywhere it plays, while the song keeps playing")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var liveLine: String {
        track.activeVoices.isEmpty ? "silent" : "voice " + voiceList(track.activeVoices)
    }

    private var voicesUsedLine: String {
        voiceList(track.voicesUsed)
    }

    private func voiceList(_ voices: [Int]) -> String {
        voices.sorted().map { "\($0 + 1)" }.joined(separator: ", ")
    }
}

/// Recent voice history for one track. Each voice has a lane; bars show when the track's sample sounded there.
struct VoiceTimelineView: View {
    let track: SPCTrackState
    let now: Double
    let laneCount: Int

    var body: some View {
        Canvas { context, size in
            let window = SPCTrackTracker.timelineWindow
            let windowStart = now - window
            let laneHeight = size.height / CGFloat(laneCount)
            let color = Color(hue: Double(track.number % 12) / 12, saturation: 0.65, brightness: 0.9)

            for span in track.spans {
                let spanEnd = min(span.end ?? now, now)
                let spanStart = max(span.start, windowStart)
                guard spanEnd > spanStart else { continue }
                let x0 = CGFloat((spanStart - windowStart) / window) * size.width
                let x1 = CGFloat((spanEnd - windowStart) / window) * size.width
                let rect = CGRect(x: x0,
                                  y: CGFloat(span.voice) * laneHeight + 1,
                                  width: max(2, x1 - x0),
                                  height: max(1, laneHeight - 2))
                context.fill(Path(rect), with: .color(color))
            }
        }
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
        .help("Last \(Int(SPCTrackTracker.timelineWindow)) seconds. Each row is a voice, top to bottom from voice 1.")
    }
}

/// Log-spaced bars for a live spectrum. Each bar is normalized to 0...1.
struct SpectrumView: View {
    let bars: [Float]

    var body: some View {
        Canvas { context, size in
            guard !bars.isEmpty else { return }
            let slot = size.width / CGFloat(bars.count)
            for (index, level) in bars.enumerated() {
                let height = max(1, CGFloat(level) * size.height)
                let rect = CGRect(x: CGFloat(index) * slot + 1,
                                  y: size.height - height,
                                  width: max(1, slot - 2),
                                  height: height)
                context.fill(Path(rect), with: .color(.accentColor))
            }
        }
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
    }
}
