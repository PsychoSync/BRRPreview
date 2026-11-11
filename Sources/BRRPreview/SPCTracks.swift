import Foundation

/// Voices are the DSP's eight hardware channels. Tracks follow a sample (SRCN) across whichever voices play it.
enum SPCViewMode: String, CaseIterable, Identifiable {
    case voices = "Voices"
    case tracks = "Tracks"

    var id: String { rawValue }
}

/// A stretch of time one voice spent sounding a track's sample. `end` is nil while the voice still sounds it.
struct VoiceSpan: Equatable {
    let voice: Int
    let start: Double
    var end: Double?
}

/// One sample heard during the song. A sample has exactly one track, however many voices play it.
struct SPCTrackState: Identifiable, Equatable {
    /// Directory index (SRCN) of the sample.
    let sourceIndex: Int
    /// 1-based order in which the sample was first heard.
    let number: Int
    /// Playback time of the first sounding frame, in seconds.
    let firstHeard: Double
    /// Voices the sample has played on, in order of first use.
    var voicesUsed: [Int] = []
    /// Seconds the sample has been sounding on any voice.
    var activeSeconds: Double = 0
    /// Spans that overlap the recent timeline window.
    var spans: [VoiceSpan] = []
    /// Voices sounding the sample right now, ascending.
    var activeVoices: [Int] = []
    /// Per-bar maximum of the sounding voices' spectra.
    var bars: [Float] = [Float](repeating: 0, count: SPCVoiceState.barCount)

    var id: Int { sourceIndex }
}

enum SPCTrackTracker {
    /// Seconds of voice history kept for each track's timeline.
    static let timelineWindow = 60.0

    /// Advances all tracks by one frame. A new sample gets the next track number. Tracks are never removed here.
    static func update(_ tracks: inout [SPCTrackState], voices: [SPCVoiceState], time: Double, frameDuration: Double) {
        var sounding: [Int: [SPCVoiceState]] = [:]
        for voice in voices where voice.isSounding {
            sounding[voice.sampleIndex, default: []].append(voice)
        }

        for sourceIndex in sounding.keys.sorted() where !tracks.contains(where: { $0.sourceIndex == sourceIndex }) {
            tracks.append(SPCTrackState(sourceIndex: sourceIndex, number: tracks.count + 1, firstHeard: time))
        }

        let windowStart = time - timelineWindow
        for index in tracks.indices {
            let current = sounding[tracks[index].sourceIndex] ?? []
            let currentVoices = current.map(\.index).sorted()

            for span in tracks[index].spans.indices where tracks[index].spans[span].end == nil {
                if !currentVoices.contains(tracks[index].spans[span].voice) {
                    tracks[index].spans[span].end = time
                }
            }
            for voice in currentVoices where !tracks[index].spans.contains(where: { $0.voice == voice && $0.end == nil }) {
                tracks[index].spans.append(VoiceSpan(voice: voice, start: time, end: nil))
                if !tracks[index].voicesUsed.contains(voice) {
                    tracks[index].voicesUsed.append(voice)
                }
            }
            tracks[index].spans.removeAll { span in
                if let end = span.end { return end < windowStart }
                return false
            }

            tracks[index].activeVoices = currentVoices
            if !currentVoices.isEmpty {
                tracks[index].activeSeconds += frameDuration
            }

            var bars = [Float](repeating: 0, count: SPCVoiceState.barCount)
            for voice in current {
                for bar in bars.indices {
                    bars[bar] = max(bars[bar], voice.bars[bar])
                }
            }
            tracks[index].bars = bars
        }
    }
}
