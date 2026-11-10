import Foundation

/// A folder, `.brr` file, or audio file shown in the sample browser. Folder contents are read on first access.
final class BrowserNode: Identifiable {
    let url: URL
    let isDirectory: Bool
    private var loadedChildren: [BrowserNode]?

    var id: URL { url }
    var name: String { url.lastPathComponent }
    /// Audio files open in the waveform editor for conversion to BRR.
    var isAudio: Bool { !isDirectory && AudioImport.extensions.contains(url.pathExtension.lowercased()) }
    /// SPC song files play in the SPC player, with per-track tools.
    var isSPC: Bool { !isDirectory && url.pathExtension.lowercased() == "spc" }

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    var children: [BrowserNode]? {
        guard isDirectory else { return nil }
        if loadedChildren == nil {
            loadedChildren = BrowserNode.contents(of: url)
        }
        return loadedChildren
    }

    static func contents(of folder: URL) -> [BrowserNode] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let nodes = entries.compactMap { url -> BrowserNode? in
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let ext = url.pathExtension.lowercased()
            guard isDirectory || ext == "brr" || ext == "spc" || AudioImport.extensions.contains(ext) else { return nil }
            return BrowserNode(url: url, isDirectory: isDirectory)
        }

        return nodes.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}
