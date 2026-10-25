import AppKit
import RestorationStation
import SwiftUI

/// Coordinates GitHub Release update checks, caching, DMG downloads, and installation.
@MainActor @Observable
final class UpdateManager {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate(latestVersion: String?)
        case available(ReleaseInfo)
        case downloading(ReleaseInfo, Double)
        case verifying(ReleaseInfo)
        case downloadedDMG(ReleaseInfo, URL)
        case failed(String)
    }

    private static let checkInterval: TimeInterval = 12 * 3600
    private static let lastCheckKey = "updateLastCheckTimestamp"
    private static let etagKey = "updateCachedETag"
    private static let payloadKey = "updateCachedReleasePayload"

    private(set) var status: Status = .idle
    var isShowingSheet = false
    private var activeTask: Task<Void, Never>?

    var currentVersion: String { ReleaseUpdater.currentAppVersion() }
    var isDevelopmentBuild: Bool { !ReleaseUpdater.isPackagedReleaseApp() }

    var availableRelease: ReleaseInfo? {
        switch status {
        case .available(let info), .downloading(let info, _), .verifying(let info), .downloadedDMG(let info, _):
            return info
        default:
            return nil
        }
    }

    var isBusy: Bool {
        switch status {
        case .checking, .downloading, .verifying:
            return true
        default:
            return false
        }
    }

    /// Runs a silent background check on launch if at least 12 hours have passed since the last check.
    func checkOnLaunchIfNeeded() {
        let defaults = UserDefaults.standard
        if let cachedData = defaults.data(forKey: Self.payloadKey),
           let cached = try? ReleaseUpdater.decodeRelease(from: cachedData),
           ReleaseUpdater.isVersion(cached.version, newerThan: currentVersion) {
            status = .available(cached)
        }

        // Skip automatic network checks on unversioned `swift run` builds unless the user clicks Check.
        guard !isDevelopmentBuild else { return }
        let lastCheck = defaults.double(forKey: Self.lastCheckKey)
        guard Date().timeIntervalSince1970 - lastCheck >= Self.checkInterval else { return }
        checkForUpdates(userInitiated: false)
    }

    /// Queries GitHub Releases for the latest version. When `userInitiated` is true, presents the status sheet.
    func checkForUpdates(userInitiated: Bool) {
        if userInitiated {
            isShowingSheet = true
        }
        guard !isBusy else { return }
        status = .checking

        activeTask?.cancel()
        activeTask = Task {
            let defaults = UserDefaults.standard
            let cachedETag = userInitiated ? nil : defaults.string(forKey: Self.etagKey)
            do {
                let result = try await ReleaseUpdater.fetchLatestRelease(etag: cachedETag)
                defaults.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)

                switch result {
                case .release(let info, let etag, let rawData):
                    if let etag { defaults.set(etag, forKey: Self.etagKey) }
                    defaults.set(rawData, forKey: Self.payloadKey)
                    applyRelease(info, userInitiated: userInitiated)

                case .notModified:
                    if let cachedData = defaults.data(forKey: Self.payloadKey),
                       let info = try? ReleaseUpdater.decodeRelease(from: cachedData) {
                        applyRelease(info, userInitiated: userInitiated)
                    } else {
                        status = .upToDate(latestVersion: currentVersion)
                    }

                case .noReleasesPublished:
                    status = .upToDate(latestVersion: nil)
                }
            } catch is CancellationError {
                status = .idle
            } catch {
                if userInitiated {
                    status = .failed(error.localizedDescription)
                } else {
                    status = .idle
                }
            }
        }
    }

    private func applyRelease(_ info: ReleaseInfo, userInitiated: Bool) {
        if ReleaseUpdater.isVersion(info.version, newerThan: currentVersion) {
            status = .available(info)
        } else {
            status = .upToDate(latestVersion: info.version)
        }
    }

    /// Downloads the release DMG and either installs & relaunches (if running from a writable `.app` bundle)
    /// or opens the DMG in Finder for drag-and-drop installation.
    func downloadAndInstall(_ release: ReleaseInfo) {
        guard let asset = release.dmgAsset else {
            NSWorkspace.shared.open(release.htmlURL)
            return
        }
        guard !isBusy else { return }
        status = .downloading(release, 0)

        activeTask?.cancel()
        activeTask = Task {
            do {
                let dmgURL = try await ReleaseUpdater.downloadDMG(asset) { fraction in
                    Task { @MainActor [weak self] in
                        if case .downloading = self?.status {
                            self?.status = .downloading(release, fraction)
                        }
                    }
                }
                try Task.checkCancellation()

                if ReleaseUpdater.canReplaceRunningBundle() {
                    status = .verifying(release)
                    let targetApp = Bundle.main.bundleURL
                    let stagedApp = try await Task.detached {
                        try await ReleaseUpdater.stageVerifiedApp(fromDMG: dmgURL)
                    }.value
                    try? FileManager.default.removeItem(at: dmgURL.deletingLastPathComponent())
                    try ReleaseUpdater.launchAtomicSwapAndRelaunch(stagedApp: stagedApp, targetApp: targetApp)
                    NSApplication.shared.terminate(nil)
                } else {
                    status = .downloadedDMG(release, dmgURL)
                    NSWorkspace.shared.open(dmgURL)
                }
            } catch is CancellationError {
                status = .available(release)
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
    }
}

/// Toolbar button that checks for updates or highlights an available GitHub release.
struct UpdateToolbarButton: View {
    @Environment(UpdateManager.self) private var updater

    var body: some View {
        if let release = updater.availableRelease {
            Button {
                updater.isShowingSheet = true
            } label: {
                Label("Update Available (v\(release.version))", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .help("ATC Studio \(release.version) is available on GitHub")
        } else {
            Button {
                updater.checkForUpdates(userInitiated: true)
            } label: {
                Label(updater.status == .checking ? "Checking…" : "Check for Updates",
                      systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(updater.isBusy)
            .help("Check GitHub Releases for a newer version of ATC Studio")
        }
    }
}

/// Modal sheet displaying update status, release notes, download progress, and install actions.
struct UpdateSheet: View {
    @Environment(UpdateManager.self) private var updater

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            switch updater.status {
            case .idle, .checking:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Checking GitHub Releases for updates…")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 12)

            case .upToDate(let latest):
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("ATC Studio is up to date.", systemImage: "checkmark.seal.fill")
                            .font(.headline)
                            .foregroundStyle(.green)
                        if let latest {
                            Text("Installed version: \(updater.currentVersion) (latest release: \(latest)).")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("No releases have been published on GitHub yet (installed version: \(updater.currentVersion)).")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

            case .available(let release):
                releaseDetails(release)

            case .downloading(let release, let fraction):
                releaseDetails(release)
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: fraction)
                    Text("Downloading \(release.dmgAsset?.name ?? "update")… \(Int(fraction * 100))%")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

            case .verifying(let release):
                releaseDetails(release)
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Verifying signature and preparing to relaunch…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

            case .downloadedDMG(let release, let dmgURL):
                releaseDetails(release)
                GroupBox {
                    HStack {
                        Label("Disk image downloaded and opened.", systemImage: "externaldrive.fill.badge.checkmark")
                            .foregroundStyle(.green)
                        Spacer()
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([dmgURL])
                        }
                        .controlSize(.small)
                    }
                    .padding(4)
                }

            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            footerActions
        }
        .padding(20)
        .frame(width: 520)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.app.fill")
                .font(.system(size: 32))
                .foregroundStyle( Color.accentColor )
            VStack(alignment: .leading, spacing: 2) {
                Text("Software Update").font(.title2.weight(.semibold))
                Text(updater.isDevelopmentBuild
                     ? "Installed version: \(updater.currentVersion) (Development Build)"
                     : "Installed version: v\(updater.currentVersion)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func releaseDetails(_ release: ReleaseInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(release.title).font(.headline)
                Spacer()
                if let published = release.publishedAt {
                    Text(published.formatted(date: .abbreviated, time: .omitted))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if !release.notes.isEmpty {
                ScrollView {
                    Text(release.notes)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                }
                .frame(minHeight: 110, maxHeight: 200)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
            }
        }
    }

    private var footerActions: some View {
        HStack {
            Link("View Releases on GitHub", destination: updater.availableRelease?.htmlURL ?? ReleaseUpdater.releasesWebURL)
                .font(.callout)

            Spacer()

            if updater.isBusy {
                Button("Cancel", role: .cancel) {
                    updater.cancel()
                }
            } else {
                Button("Close") {
                    updater.isShowingSheet = false
                }
                .keyboardShortcut(.cancelAction)

                if case .failed = updater.status {
                    Button("Try Again") {
                        updater.checkForUpdates(userInitiated: true)
                    }
                    .buttonStyle(.borderedProminent)
                } else if let release = updater.availableRelease {
                    if release.dmgAsset != nil {
                        let canAutoReplace = ReleaseUpdater.canReplaceRunningBundle()
                        Button(canAutoReplace ? "Update & Relaunch" : "Download DMG") {
                            updater.downloadAndInstall(release)
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    } else {
                        Button("Open on GitHub") {
                            NSWorkspace.shared.open(release.htmlURL)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    Button("Check Again") {
                        updater.checkForUpdates(userInitiated: true)
                    }
                }
            }
        }
    }
}
