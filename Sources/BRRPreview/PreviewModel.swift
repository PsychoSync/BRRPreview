import AppKit
import BRRCore
import Foundation
import UniformTypeIdentifiers

struct LoadedSample: Equatable {
    let url: URL
    let decoded: BRRDecoder.Result

    var name: String { url.lastPathComponent }
    var duration: TimeInterval { Double(decoded.samples.count) / BRRDecoder.sampleRate }
}

/// A row in the browser list: a folder or sample at a given nesting depth.
struct BrowserRow: Identifiable {
    let node: BrowserNode
    let depth: Int

    var id: URL { node.url }
}

@MainActor
final class PreviewModel: ObservableObject {
    private static let foldersKey = "folderPaths"
    private static let legacyFolderKey = "lastFolderPath"

    @Published private(set) var roots: [BrowserNode] = []
    /// Paths of folders currently expanded in the browser.
    @Published private(set) var expandedFolders: Set<String> = []
    @Published private(set) var selected: LoadedSample?
    /// Waveform editor for the audio file being converted. Shown in place of the piano while set.
    @Published private(set) var editor: WaveEditor?
    /// Kept alive while browsing samples; `showingSPC` selects the song's detail page.
    @Published private(set) var spc: SPCSession?
    @Published private(set) var showingSPC = false
    /// Sample replacement for one track of the open SPC, shown in place of the SPC page while set.
    @Published private(set) var replacement: SPCReplacement?
    @Published private(set) var isPlaying = false
    @Published private(set) var errorMessage: String?
    /// Fundamental of the selected sample at its native 32 kHz rate, or nil for unpitched material.
    @Published private(set) var detectedFrequency: Double?
    @Published private(set) var selectedNote = Note.referenceMIDI
    /// When on, a note loops for as long as its key is held. Off by default.
    @Published var loopEnabled = false {
        didSet {
            if !loopEnabled { releaseHeldLoop() }
        }
    }

    private let player = SamplePlayer()
    private var keyMonitor: Any?
    /// The note currently looping because its key is held, if any.
    private var loopingNote: Int?
    /// Note started by each keyboard key that is still held, so key-up can release it.
    private var heldKeyNotes: [Character: Int] = [:]

    init() {
        player.onFinished = { [weak self] in
            self?.isPlaying = false
            self?.loopingNote = nil
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.releaseHeldLoop()
                self?.editor?.stopPlayback()
                self?.replacement?.releaseAllNotes()
            }
        }
        let savedPaths = UserDefaults.standard.stringArray(forKey: Self.foldersKey)
            ?? UserDefaults.standard.string(forKey: Self.legacyFolderKey).map { [$0] }
            ?? []
        for path in savedPaths {
            var isDirectory: ObjCBool = true
            // Paths that no longer exist restore as folders, as before, so the entry stays visible and removable.
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
                appendRoot(URL(fileURLWithPath: path), isDirectory: isDirectory.boolValue)
            } else {
                appendRoot(URL(fileURLWithPath: path, isDirectory: true), isDirectory: true)
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                return event.type == .keyUp ? self.handleKeyUp(event) : self.handleKeyDown(event)
            }
            return handled ? nil : event
        }
    }

    func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            appendRoot(url, isDirectory: true)
        }
        saveFolders()
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where BrowserNode.isSupportedFile(url) {
            appendRoot(url, isDirectory: false)
        }
        saveFolders()
    }

    func removeFolder(_ node: BrowserNode) {
        roots.removeAll { $0.url.path == node.url.path }
        saveFolders()
    }

    func isExpanded(_ node: BrowserNode) -> Bool {
        expandedFolders.contains(node.url.path)
    }

    func toggleExpanded(_ node: BrowserNode) {
        if isExpanded(node) {
            expandedFolders.remove(node.url.path)
        } else {
            expandedFolders.insert(node.url.path)
        }
    }

    /// Folders and samples in display order, with folders nested to the current expansion state.
    var visibleRows: [BrowserRow] {
        var rows: [BrowserRow] = []
        func visit(_ nodes: [BrowserNode], depth: Int) {
            for node in nodes {
                rows.append(BrowserRow(node: node, depth: depth))
                if node.isDirectory, isExpanded(node) {
                    visit(node.children ?? [], depth: depth + 1)
                }
            }
        }
        visit(roots, depth: 0)
        return rows
    }

    private func appendRoot(_ url: URL, isDirectory: Bool) {
        let url = url.standardizedFileURL
        guard !roots.contains(where: { $0.url.path == url.path }) else { return }
        roots.append(BrowserNode(url: url, isDirectory: isDirectory))
        if isDirectory {
            expandedFolders.insert(url.path)
        }
    }

    private func saveFolders() {
        UserDefaults.standard.set(roots.map { $0.url.path }, forKey: Self.foldersKey)
        UserDefaults.standard.removeObject(forKey: Self.legacyFolderKey)
    }

    /// Every sample in display order, with the folders above each one.
    private func sampleEntries() -> [(sample: BrowserNode, ancestors: [BrowserNode])] {
        var entries: [(sample: BrowserNode, ancestors: [BrowserNode])] = []
        func visit(_ nodes: [BrowserNode], ancestors: [BrowserNode]) {
            for node in nodes {
                if node.isDirectory {
                    visit(node.children ?? [], ancestors: ancestors + [node])
                } else {
                    entries.append((node, ancestors))
                }
            }
        }
        visit(roots, ancestors: [])
        return entries
    }

    /// The file shown in the detail pane: the open SPC, the editor's audio file, or the selected BRR sample.
    var currentURL: URL? {
        if replacement != nil { return replacement?.browserURL }
        return showingSPC ? spc?.url : (editor?.sourceURL ?? selected?.url)
    }

    /// Moves to the next or previous sample across all folders, wrapping at the ends, and plays it.
    func stepSample(_ delta: Int) {
        let entries = sampleEntries()
        guard !entries.isEmpty else { return }
        let index: Int
        if let current = entries.firstIndex(where: { $0.sample.url == currentURL }) {
            index = (current + delta % entries.count + entries.count) % entries.count
        } else {
            index = delta > 0 ? 0 : entries.count - 1
        }
        let entry = entries[index]
        for folder in entry.ancestors {
            expandedFolders.insert(folder.url.path)
        }
        select(entry.sample)
    }

    /// Opens audio files in the waveform editor. BRR files are decoded and played. SPC files start playing.
    /// While a sample replacement is open, a click previews a sample. Dropping it or choosing it selects it.
    func select(_ node: BrowserNode) {
        if replacement != nil {
            guard node.isAudio || node.isBRR else {
                replacement?.errorMessage = "Choose an audio or BRR sample to preview."
                return
            }
            stop()
            replacement?.previewSource(node.url)
            return
        }
        if node.isSPC {
            openSPC(node.url)
            return
        }
        showingSPC = false
        if node.isAudio {
            openEditor(node.url)
            return
        }
        closeEditor()
        do {
            let decoded = BRRDecoder.decodeFile([UInt8](try Data(contentsOf: node.url)))
            guard !decoded.samples.isEmpty else {
                selected = nil
                errorMessage = "\(node.name) doesn't contain any complete BRR blocks."
                return
            }
            selected = LoadedSample(url: node.url, decoded: decoded)
            detectedFrequency = PitchDetector.fundamentalFrequency(samples: decoded.samples, sampleRate: BRRDecoder.sampleRate)
            let baseName = node.url.deletingPathExtension().lastPathComponent
            selectedNote = clamped(Note.midi(parsing: baseName) ?? Note.referenceMIDI)
            errorMessage = nil
            playSelected()
        } catch {
            selected = nil
            errorMessage = "Couldn't read \(node.name): \(error.localizedDescription)"
        }
    }

    func togglePlayback() {
        if isPlaying {
            stop()
        } else {
            playSelected()
        }
    }

    func stop() {
        player.stop()
        isPlaying = false
        loopingNote = nil
    }

    /// Notes the keyboard can reach while keeping the playback rate within the player's varispeed range.
    var noteRange: ClosedRange<Int> {
        let center = Note.midi(frequency: nativeFrequency)
        let span = 12 * log2(SamplePlayer.rateRange.upperBound)
        let lower = max(0, Int((center - span).rounded(.up)))
        let upper = min(127, Int((center + span).rounded(.down)))
        return lower...upper
    }

    /// Plays the selected sample transposed so its detected pitch sounds at `note`.
    /// With `loop`, the note repeats until `releaseNote` is called for it or playback stops.
    func playNote(_ note: Int, loop: Bool = false) {
        selectedNote = clamped(note)
        loopingNote = loop ? selectedNote : nil
        playSelected(loop: loop)
    }

    /// Ends a looping note when its key is released. Other notes are left to play out.
    func releaseNote(_ note: Int) {
        guard loopingNote == note else { return }
        stop()
    }

    func shiftOctave(_ octaves: Int) {
        let target = selectedNote + 12 * octaves
        guard noteRange.contains(target) else { return }
        playNote(target)
    }

    private func releaseHeldLoop() {
        heldKeyNotes.removeAll()
        if loopingNote != nil { stop() }
    }

    /// C at the start of the octave shown on the on-screen keyboard and mapped to Q.
    var keyboardOctaveBase: Int {
        (selectedNote / 12) * 12
    }

    /// Handles the window's keyboard shortcuts. Returns true when the event was used.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard !(event.window is NSPanel),
              !((event.window?.firstResponder as? NSTextView)?.isFieldEditor ?? false),
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        else { return false }

        if replacement != nil { return handleReplacementKey(event) }
        if spc != nil && showingSPC { return handleSPCKey(event) }

        // Tab also reports a specialKey, so only arrows are handled here.
        if let special = event.specialKey, [.upArrow, .downArrow, .leftArrow, .rightArrow].contains(special) {
            switch special {
            case .upArrow: stepSample(-1)
            case .downArrow: stepSample(1)
            case .leftArrow: shiftOctave(-1)
            default: shiftOctave(1)
            }
            return true
        }

        guard let key = event.charactersIgnoringModifiers?.lowercased().first else { return false }
        if let editor {
            // Space and Tab control the editor's preview. Other keys are left for the window.
            switch key {
            case " ":
                if !event.isARepeat { editor.togglePreview() }
                return true
            case "\t":
                if !event.isARepeat { editor.loopPreview.toggle() }
                return true
            default:
                return false
            }
        }
        switch key {
        case " ":
            if !event.isARepeat { togglePlayback() }
            return true
        case "\t":
            if !event.isARepeat { loopEnabled.toggle() }
            return true
        default:
            guard let midi = PianoKeys.midi(for: key, octaveBase: keyboardOctaveBase) else { return false }
            if !event.isARepeat, noteRange.contains(midi) {
                heldKeyNotes[key] = midi
                playNote(midi, loop: loopEnabled)
            }
            return true
        }
    }

    /// While an SPC is open, Space plays or pauses it and the up/down arrows change songs.
    private func handleSPCKey(_ event: NSEvent) -> Bool {
        if let special = event.specialKey {
            switch special {
            case .upArrow:
                stepSample(-1)
                return true
            case .downArrow:
                stepSample(1)
                return true
            default:
                return false
            }
        }
        guard let key = event.charactersIgnoringModifiers?.lowercased().first, key == " " else { return false }
        if !event.isARepeat { spc?.togglePlayback() }
        return true
    }

    private func handleReplacementKey(_ event: NSEvent) -> Bool {
        guard let replacement else { return false }
        if let special = event.specialKey, [.upArrow, .downArrow, .leftArrow, .rightArrow].contains(special) {
            if !event.isARepeat {
                if special == .leftArrow { replacement.shiftOctave(-1) }
                if special == .rightArrow { replacement.shiftOctave(1) }
            }
            return true
        }
        guard let key = event.charactersIgnoringModifiers?.lowercased().first else { return false }
        switch key {
        case " ":
            if !event.isARepeat { replacement.togglePreview() }
            return true
        case "\t":
            if !event.isARepeat { replacement.toggleLoop() }
            return true
        default:
            return replacement.keyDown(key, repeating: event.isARepeat)
        }
    }

    /// Releases the note a piano key started. Returns true when the event was used.
    func handleKeyUp(_ event: NSEvent) -> Bool {
        guard let key = event.charactersIgnoringModifiers?.lowercased().first else { return false }
        if let replacement { return replacement.keyUp(key) }
        guard let note = heldKeyNotes.removeValue(forKey: key)
        else { return false }
        releaseNote(note)
        return true
    }


    private var nativeFrequency: Double {
        detectedFrequency ?? Note.frequency(midi: Double(Note.referenceMIDI))
    }

    private func clamped(_ note: Int) -> Int {
        min(max(note, noteRange.lowerBound), noteRange.upperBound)
    }

    /// Varispeed factor that moves the sample from its detected pitch to the selected note.
    private var playbackRate: Double {
        Note.frequency(midi: Double(selectedNote)) / nativeFrequency
    }

    private func openEditor(_ url: URL) {
        do {
            let opened = try WaveEditor(url: url)
            stop()
            selected = nil
            editor?.stop()
            editor = opened
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func closeEditor() {
        editor?.stop()
        editor = nil
    }

    private func openSPC(_ url: URL) {
        if spc?.url == url {
            goToSPC()
            return
        }
        do {
            let session = try SPCSession(url: url)
            stop()
            closeEditor()
            selected = nil
            cancelReplacement()
            spc?.shutdown()
            spc = session
            showingSPC = true
            errorMessage = nil
            session.play()
        } catch {
            errorMessage = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func goToSPC() {
        guard spc != nil else { return }
        stop()
        editor?.stopPlayback()
        showingSPC = true
    }

    func beginReplacement(voice: Int) {
        guard let spc else { return }
        guard let snapshot = spc.snapshot(voice: voice) else {
            spc.errorMessage = "Voice \(voice + 1) has no sample to replace."
            return
        }
        beginReplacement(spc, snapshot: snapshot, label: "Voice \(voice + 1)")
    }

    /// Replacing by track changes the directory entry, so every voice playing this sample picks up the new sound.
    func beginReplacement(track: SPCTrackState) {
        guard let spc else { return }
        guard let snapshot = spc.snapshot(sourceIndex: track.sourceIndex) else {
            spc.errorMessage = "Track \(track.number) has no sample to replace."
            return
        }
        beginReplacement(spc, snapshot: snapshot, label: "Track \(track.number)")
    }

    private func beginReplacement(_ spc: SPCSession, snapshot: SPCSampleSnapshot, label: String) {
        NSApplication.shared.keyWindow?.makeFirstResponder(nil)
        stop()
        editor?.stopPlayback()
        showingSPC = true
        cancelReplacement()
        replacement = SPCReplacement(session: spc, snapshot: snapshot, label: label)
    }

    func cancelReplacement() {
        replacement?.close()
        replacement = nil
    }

    func applyReplacement() {
        guard let replacement else { return }
        do {
            let result = try replacement.apply()
            var notes: [String] = []
            if result.relocated { notes.append("moved to free RAM") }
            if result.truncated { notes.append("truncated to fit") }
            let suffix = notes.isEmpty ? "" : " (\(notes.joined(separator: ", ")))"
            spc?.statusMessage = "Replaced \(replacement.label.lowercased())\(suffix)."
            cancelReplacement()
        } catch {
            replacement.errorMessage = error.localizedDescription
        }
    }

    func chooseReplacementSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = AudioImport.sampleExtensions.compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        replacement?.loadSource(url)
    }

    func extractSample(voice: Int) {
        guard let spc else { return }
        guard let snapshot = spc.snapshot(voice: voice) else {
            spc.errorMessage = "Voice \(voice + 1) has no sample to extract."
            return
        }
        saveSample(spc, snapshot, track: nil, label: "voice \(voice + 1)",
                   fileName: spc.sampleFileStem(sourceIndex: snapshot.sourceIndex,
                                                fallback: String(format: "voice%d-%02X", voice + 1, snapshot.sourceIndex)) + ".brr")
    }

    func extractSample(track: SPCTrackState) {
        guard let spc else { return }
        guard let snapshot = spc.snapshot(sourceIndex: track.sourceIndex) else {
            spc.errorMessage = "Track \(track.number) has no sample to extract."
            return
        }
        saveSample(spc, snapshot, track: track, label: "track \(track.number)",
                   fileName: spc.sampleFileStem(sourceIndex: snapshot.sourceIndex,
                                                fallback: String(format: "track%02d-%02X", track.number, snapshot.sourceIndex)) + ".brr")
    }

    private func saveSample(_ spc: SPCSession, _ snapshot: SPCSampleSnapshot, track: SPCTrackState?,
                            label: String, fileName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let written = try spc.extract(snapshot, to: url, track: track)
            spc.errorMessage = nil
            spc.statusMessage = "Extracted \(written.lastPathComponent) and its metadata."
        } catch {
            spc.errorMessage = "Couldn't extract \(label): \(error.localizedDescription)"
        }
    }

    /// Writes every distinct sample in the song to a folder the user picks.
    func extractAllSamples(duration: Double) {
        guard let spc, !spc.isExtracting else { return }
        guard duration.isFinite, duration > 0, duration <= 3600 else {
            spc.errorMessage = "Choose a scan length greater than 0 and no more than 60 minutes."
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Extract"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        spc.isExtracting = true
        spc.errorMessage = nil
        spc.statusMessage = "Scanning \(Int(duration / 60)) minutes for used samples…"
        Task {
            defer { spc.isExtracting = false }
            do {
                let count = try await spc.extractAll(to: folder, duration: duration)
                spc.errorMessage = nil
                spc.statusMessage = count == 0
                    ? "No audible BRR samples found in the scanned interval."
                    : "Extracted \(count) sample\(count == 1 ? "" : "s") to \(folder.lastPathComponent)."
            } catch {
                spc.errorMessage = "Couldn't extract samples: \(error.localizedDescription)"
                spc.statusMessage = nil
            }
        }
    }


    /// Writes the emulator's current state, so the saved SPC reflects any replaced samples. `tags` come from the save sheet.
    func saveSPC(tags: SPCExtendedTags) {
        guard let spc else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = spc.url.lastPathComponent
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(spc.savedImage(tags: tags)).write(to: url, options: .atomic)
            spc.extendedTags = tags
            spc.errorMessage = nil
            spc.statusMessage = "Saved \(url.lastPathComponent)."
        } catch {
            spc.errorMessage = "Couldn't save \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func playSelected(loop: Bool = false) {
        guard let selected else { return }
        do {
            try player.play(selected.decoded.samples, loopStart: selected.decoded.loopStart, loop: loop, rate: playbackRate)
            isPlaying = true
            errorMessage = nil
        } catch {
            isPlaying = false
            errorMessage = "Audio playback failed: \(error.localizedDescription)"
        }
    }
}
