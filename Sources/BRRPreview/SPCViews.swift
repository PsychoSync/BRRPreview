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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// The SPC's header, its save action, and one row per DSP voice.
struct SPCDetailView: View {
    @ObservedObject var model: PreviewModel
    @ObservedObject var session: SPCSession

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
                Button("Save SPC As…") {
                    model.saveSPC()
                }
                .help("Saves the current emulator state, including any replaced samples")
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

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(session.voices) { voice in
                        SPCTrackRow(model: model, session: session, voice: voice)
                    }
                }
            }
        }
    }

    private var detailLine: String {
        [session.gameTitle, session.authorName].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// One DSP voice: its sample, live spectrum, mute and solo, and extract or replace actions.
struct SPCTrackRow: View {
    @ObservedObject var model: PreviewModel
    @ObservedObject var session: SPCSession
    let voice: SPCVoiceState

    var body: some View {
        let muted = session.mutedVoices.contains(voice.index)
        let soloed = session.soloVoices.contains(voice.index)

        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Track \(voice.index + 1)")
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

                Button("Extract…") {
                    model.extractSample(voice: voice.index)
                }
                .help("Save this track's BRR sample with its loop point and metadata")

                Button("Replace…") {
                    model.beginReplacement(voice: voice.index)
                }
                .help("Replace this track's sample while the song keeps playing")
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
