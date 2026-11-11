import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct BRRPreviewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = PreviewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 720, minHeight: 460)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Files…") {
                    model.chooseFiles()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Add Folders…") {
                    model.chooseFolders()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}
