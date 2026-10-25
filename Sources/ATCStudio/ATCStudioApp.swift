import AppKit
import RestorationStation
import SwiftUI

@main
struct ATCStudioApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var library = Library.load()

    var body: some Scene {
        WindowGroup("ATC Studio") {
            Group {
                if let library {
                    ContentView()
                        .environment(library)
                } else {
                    ContentUnavailableView(
                        "Restoration Station could not open its database",
                        systemImage: "exclamationmark.triangle",
                        description: Text(Library.loadError ?? "Unknown error"))
                }
            }
            .frame(minWidth: 900, minHeight: 600)
        }
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare SwiftPM executable (`swift run`) rather than a .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
    var body: some View {
        TabView {
            Tab("Workspace", systemImage: "waveform") {
                WorkspaceView()
            }
            Tab("Templates", systemImage: "rectangle.stack") {
                TemplatesView()
            }
            Tab("Speakers", systemImage: "person.2") {
                SpeakersView()
            }
        }
        .padding()
    }
}
