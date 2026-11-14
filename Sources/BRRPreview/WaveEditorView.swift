import BRRCore
import SwiftUI

/// Waveform editor shown in the detail pane for audio files. Drag on the waveform to select a range
/// or move the loop point, then edit and export as BRR.
struct WaveEditorView: View {
    @ObservedObject var editor: WaveEditor
    /// Hidden when the editor feeds an SPC sample replacement, which always converts at the native rate.
    var showsExportControls: Bool = true
    var showsPlaybackControls: Bool = true
    var returnToPlayback: (() -> Void)? = nil
    @State private var dragStart: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: showsExportControls ? 12 : 6) {
            if showsExportControls {
                HStack {
                    Text(editor.sourceURL.lastPathComponent)
                        .font(.title2.bold())
                    Spacer()
                    if let returnToPlayback {
                        Button(action: returnToPlayback) {
                            Label("Go back to playback", systemImage: "arrow.left")
                        }
                    }
                }
                Text(editor.sourceURL.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            waveform
                .frame(height: showsExportControls ? 160 : 75)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topTrailing) {
                    if !showsExportControls && editor.isConverting {
                        ProgressView().controlSize(.small).padding(6)
                    }
                }

            Text(selectionDescription)
                .font(.callout)
                .foregroundStyle(.secondary)

            Picker("Drag on waveform", selection: $editor.dragMode) {
                ForEach(WaveEditor.DragMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            editButtons

            if showsPlaybackControls { playbackRow }

            if showsExportControls { stats }

            if let error = editor.errorMessage {
                Text(error).foregroundStyle(.red)
            }
            if let status = editor.status {
                Text(status).foregroundStyle(.secondary)
            }

            if showsExportControls { Spacer(minLength: 0) }
        }
    }

    // MARK: - Waveform

    private var waveform: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                draw(in: context, size: size)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        handleDrag(value, width: geometry.size.width)
                    }
                    .onEnded { _ in
                        if editor.dragMode == .setLoop { editor.endLoopDrag() }
                        dragStart = nil
                    }
            )
        }
    }

    private func draw(in context: GraphicsContext, size: CGSize) {
        let samples = editor.sample.samples
        let count = samples.count
        guard count > 0, size.width > 0 else { return }
        let midY = size.height / 2

        if let selection = editor.selection {
            let x0 = CGFloat(selection.lowerBound) / CGFloat(count) * size.width
            let x1 = CGFloat(selection.upperBound) / CGFloat(count) * size.width
            let rect = CGRect(x: x0, y: 0, width: x1 - x0, height: size.height)
            context.fill(Path(rect), with: .color(Color.accentColor.opacity(0.2)))
        }

        var wave = Path()
        let columns = Int(size.width)
        for column in 0..<columns {
            let lower = column * count / columns
            let upper = min(max(lower + 1, (column + 1) * count / columns), count)
            var low: Float = 0
            var high: Float = 0
            for i in lower..<upper {
                low = min(low, samples[i])
                high = max(high, samples[i])
            }
            let x = CGFloat(column) + 0.5
            wave.move(to: CGPoint(x: x, y: midY - CGFloat(high) * midY))
            wave.addLine(to: CGPoint(x: x, y: midY - CGFloat(low) * midY))
        }
        context.stroke(wave, with: .color(.primary.opacity(0.7)), lineWidth: 1)

        if let loop = editor.sample.loopStart {
            let x = CGFloat(loop) / CGFloat(count) * size.width
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(line, with: .color(.green), lineWidth: 2)
        }
    }

    private func index(for x: CGFloat, width: CGFloat) -> Int {
        let count = editor.sample.samples.count
        guard count > 0, width > 0 else { return 0 }
        return min(max(Int(x / width * CGFloat(count)), 0), count - 1)
    }

    private func handleDrag(_ value: DragGesture.Value, width: CGFloat) {
        let index = index(for: value.location.x, width: width)
        if dragStart == nil {
            dragStart = index
            if editor.dragMode == .setLoop { editor.beginLoopDrag() }
        }
        guard let start = dragStart else { return }
        switch editor.dragMode {
        case .select:
            editor.selectRange(from: start, to: index)
        case .setLoop:
            editor.dragLoop(to: index)
        }
    }

    // MARK: - Controls

    private var editButtons: some View {
        Group {
            if showsExportControls {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) { primaryEditButtons }
                    HStack(spacing: 8) { otherEditButtons }
                }
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        primaryEditButtons
                        otherEditButtons
                    }
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var primaryEditButtons: some View {
        Group {
            Button("Crop", action: editor.crop).disabled(editor.selection == nil)
            Button("Cut", action: editor.cut).disabled(editor.selection == nil)
            Button("Reverse", action: editor.reverse).disabled(editor.selection == nil)
            Button("Fade In", action: editor.fadeIn)
            Button("Fade Out", action: editor.fadeOut)
        }
    }

    private var otherEditButtons: some View {
        Group {
            Button("Trim Silence", action: editor.trimSilence)
            Button("Normalize", action: editor.normalize)
            Button("Clear Loop", action: editor.clearLoop).disabled(editor.sample.loopStart == nil)
            Button("Undo", action: editor.undo)
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!editor.canUndo)
        }
    }

    private var playbackRow: some View {
        HStack(spacing: 16) {
            Button {
                editor.togglePreview()
            } label: {
                Label(editor.isPlaying ? "Stop" : "Play", systemImage: editor.isPlaying ? "stop.fill" : "play.fill")
                    .frame(width: 80)
            }

            Toggle("Loop", isOn: $editor.loopPreview)
                .help("Repeat the preview from the loop point, or the whole sample when there is none. Tab toggles it.")

            if showsExportControls {
                Picker("Output rate", selection: $editor.outputRate) {
                    ForEach(BRRConverter.outputRates, id: \.self) { rate in
                        Text(String(format: "%.3g kHz", rate / 1000)).tag(rate)
                    }
                }
                .frame(width: 160)
            }

            Spacer()

            if showsExportControls {
                Button("Export BRR…", action: editor.export)
                    .buttonStyle(.borderedProminent)
                    .disabled(editor.conversion == nil)
            }
        }
    }

    // MARK: - Information

    private var selectionDescription: String {
        let sample = editor.sample
        let range = editor.effectiveRange
        let seconds = Double(range.count) / sample.sourceRate
        let scope = editor.selection == nil ? "Whole sample" : "Selection"
        return String(format: "%@: %.3f s (samples %d–%d of %d). Space plays or stops.",
                      scope, seconds, range.lowerBound, range.upperBound, sample.samples.count)
    }

    private var stats: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let conversion = editor.conversion {
                Text(String(format: "%.3f s at %.3g kHz · %d BRR bytes · pitch register 0x%04X",
                            Double(conversion.sampleCount) / conversion.outputRate,
                            conversion.outputRate / 1000,
                            conversion.file.count,
                            UInt32(conversion.pitchRegister)))
                if let loop = editor.sample.loopStart {
                    Text(String(format: "Loop at %.3f s", Double(loop) / editor.sample.sourceRate))
                } else {
                    Text("No loop point")
                }
                if !conversion.encoding.loopHeaderFits {
                    Text("The loop point is too far into the sample for the 2-byte header, so it won't be saved. Shorten the sample or move the loop earlier.")
                        .foregroundStyle(.orange)
                }
            }
            if editor.isConverting {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
