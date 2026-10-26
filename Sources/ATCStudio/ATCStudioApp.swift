import AppKit
import RestorationStation
import SwiftUI

@main
struct ATCStudioApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var library = Library.load()
    @State private var models = ModelManager()
    @State private var updater = UpdateManager()
    @State private var publishing = PublishingAccountManager()
    @State private var selectedTab: AppTab = .workspace

    var body: some Scene {
        WindowGroup("ATC Studio") {
            Group {
                if let library {
                    ContentView(selectedTab: $selectedTab)
                        .environment(library)
                        .environment(models)
                        .environment(updater)
                        .environment(publishing)
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
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About ATC Studio") { AppDelegate.showAbout() }
                Button("Check for Updates…") { updater.checkForUpdates(userInitiated: true) }
            }
            CommandGroup(replacing: .help) {
                Button("ATC Studio Guide") { selectedTab = .guide }
                    .keyboardShortcut("?", modifiers: .command)
            }
        }

        Settings {
            PublishingSettingsView()
                .environment(publishing)
        }
    }
}

enum AppTab: Hashable {
    case workspace
    case templates
    case speakers
    case models
    case guide
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare SwiftPM executable (`swift run`) rather than a .app bundle.
        NSApp.setActivationPolicy(.regular)
        // A bare executable has no Info.plist icon, so set the Dock (and About panel) icon here.
        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "svg"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// The standard About panel, with the Desert Ant Labs credit their license asks for.
    @MainActor static func showAbout() {
        let credits = NSMutableAttributedString(
            string: "As The Church Studio. Open source.\n\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
        credits.append(NSAttributedString(
            string: "On-device AI by Desert Ant Labs 🐜",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .link: URL(string: "https://desertant.com")!]))
        credits.append(NSAttributedString(
            string: "\nClear, Voz, Who, Align, Uhm, and Title models.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "ATC Studio",
            .credits: credits,
        ])
    }
}

struct ContentView: View {
    @Environment(ModelManager.self) private var models
    @Environment(UpdateManager.self) private var updater
    @Binding var selectedTab: AppTab
    @State private var showModelSheet = false
    /// Offer the model download once. The MP3 path works without models, so don't nag.
    @AppStorage("offeredModelDownload") private var offeredModelDownload = false

    var body: some View {
        @Bindable var updater = updater
        TabView(selection: $selectedTab) {
            Tab("Workspace", systemImage: "waveform", value: .workspace) {
                WorkspaceView()
            }
            Tab("Templates", systemImage: "rectangle.stack", value: .templates) {
                TemplatesView()
            }
            Tab("Speakers", systemImage: "person.2", value: .speakers) {
                SpeakersView()
            }
            Tab("Models", systemImage: "cpu", value: .models) {
                ScrollView { ModelsView() }
            }
            Tab("Guide", systemImage: "book", value: .guide) {
                GuideView()
            }
        }
        .padding()
        .toolbar {
            ToolbarItem(placement: .automatic) {
                UpdateToolbarButton()
            }
        }
        .onAppear {
            if !models.allReady && !offeredModelDownload {
                offeredModelDownload = true
                showModelSheet = true
            }
            updater.checkOnLaunchIfNeeded()
        }
        .sheet(isPresented: $showModelSheet) {
            ModelsView { showModelSheet = false }
                .frame(width: 560)
        }
        .sheet(isPresented: $updater.isShowingSheet) {
            UpdateSheet()
        }
    }
}
