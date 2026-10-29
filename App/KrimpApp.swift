import QuickLookUI
import SwiftUI

@main
struct KrimpApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        Window("Krimp", id: "main") {
            ContentView()
                .environment(appDelegate.model)
        }
        .defaultSize(width: 1120, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Images…") { appDelegate.model.showImporter = true }
                    .keyboardShortcut("o")
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Decode.logSupport()
        #if DEBUG
        DebugSnapshot.scheduleIfRequested(model: model)
        #endif
    }

    /// Dock drops and Finder's "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        model.add(urls)
    }

    // Quick Look panel control: the app delegate sits at the end of the responder chain.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        model.quickLook.take(panel)
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        model.quickLook.release(panel)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
