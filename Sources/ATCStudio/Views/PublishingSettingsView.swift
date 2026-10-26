import AppKit
import RestorationStation
import SwiftUI

/// Keeps the app's view of stored PodBean credentials in sync between the Settings window and the Review view.
@MainActor @Observable
final class PublishingAccountManager {
    enum ConnectionStatus: Equatable {
        case idle
        case testing
        case connected(PodcastAccountInfo)
        case failed(String)
    }

    private(set) var credentials: PodbeanCredentials?
    var connectionStatus: ConnectionStatus = .idle
    private var testTask: Task<Void, Never>?

    var hasCredentials: Bool {
        credentials?.isValid == true
    }

    init() {
        credentials = KeychainCredentialsStore.load()
    }

    func saveAndTest(clientID: String, clientSecret: String) {
        let trimmed = PodbeanCredentials(clientID: clientID, clientSecret: clientSecret)
        guard trimmed.isValid else {
            connectionStatus = .failed("Enter both your PodBean Client ID and Client Secret.")
            return
        }
        do {
            try KeychainCredentialsStore.save(trimmed)
            credentials = trimmed
            testConnection(with: trimmed)
        } catch {
            connectionStatus = .failed(error.localizedDescription)
        }
    }

    func testConnection(with override: PodbeanCredentials? = nil) {
        guard let active = override ?? credentials, active.isValid else {
            connectionStatus = .failed("Enter both your PodBean Client ID and Client Secret.")
            return
        }
        testTask?.cancel()
        connectionStatus = .testing
        testTask = Task {
            do {
                let info = try await PodbeanPublisher(credentials: active).testConnection()
                connectionStatus = .connected(info)
            } catch is CancellationError {
                connectionStatus = .idle
            } catch {
                connectionStatus = .failed(error.localizedDescription)
            }
        }
    }

    func removeCredentials() {
        testTask?.cancel()
        do {
            try KeychainCredentialsStore.delete()
            credentials = nil
            connectionStatus = .idle
        } catch {
            connectionStatus = .failed(error.localizedDescription)
        }
    }
}

/// Settings window (`Cmd+,`) for connecting ATC Studio to PodBean.
struct PublishingSettingsView: View {
    @Environment(PublishingAccountManager.self) private var account
    @State private var clientID = ""
    @State private var clientSecret = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "antenna.radiowaves.left.and.right.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("PodBean Publishing").font(.title3.weight(.semibold))
                    Text("Upload finished episodes directly to your PodBean podcast without opening a browser.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox("How to get your API keys") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Sign in at developers.podbean.com and click \"Generate API Key\".")
                    Text("2. Pick your church podcast and register an app name (for example, \"ATC Studio\").")
                    Text("3. Copy the Client ID and Client Secret below, then click Save & Test Connection.")
                    Link("Open PodBean Developer Portal →",
                         destination: URL(string: "https://developers.podbean.com")!)
                        .font(.callout)
                        .padding(.top, 2)
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            Form {
                TextField("Client ID", text: $clientID)
                    .textFieldStyle(.roundedBorder)
                SecureField("Client Secret", text: $clientSecret)
                    .textFieldStyle(.roundedBorder)
            }

            statusView

            HStack {
                if account.hasCredentials {
                    Button("Remove Credentials", role: .destructive) {
                        account.removeCredentials()
                        clientID = ""
                        clientSecret = ""
                    }
                }
                Spacer()
                if account.hasCredentials && !hasUnsavedEdits {
                    Button("Test Connection") {
                        account.testConnection()
                    }
                    .disabled(account.connectionStatus == .testing)
                }
                Button("Save & Test Connection") {
                    account.saveAndTest(clientID: clientID, clientSecret: clientSecret)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || clientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || account.connectionStatus == .testing
                )
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear {
            if let existing = account.credentials {
                clientID = existing.clientID
                clientSecret = existing.clientSecret
            }
        }
    }

    private var hasUnsavedEdits: Bool {
        let trimmed = PodbeanCredentials(clientID: clientID, clientSecret: clientSecret)
        return trimmed != account.credentials
    }

    @ViewBuilder
    private var statusView: some View {
        switch account.connectionStatus {
        case .idle:
            if account.hasCredentials {
                Label("Credentials saved in macOS Keychain.", systemImage: "key.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .testing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Testing connection to PodBean…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .connected(let info):
            Label("Connected to \"\(info.podcastTitle)\"", systemImage: "checkmark.seal.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        }
    }
}
