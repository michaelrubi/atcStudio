import AppKit
import RestorationStation
import SwiftUI

/// After a run: name each voice, pick a title, fix the summary, and save the package.
struct EpisodeReviewView: View {
    @Environment(Library.self) private var library
    @Environment(PublishingAccountManager.self) private var publishing
    @Bindable var review: EpisodeReview
    @State private var player = PreviewPlayer()
    @State private var showPublishSheet = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Label("Your episode is ready.", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                HStack(spacing: 24) {
                    LabeledContent("Length", value: Timecode.string(review.package.totalDuration))
                    LabeledContent("Message starts at", value: Timecode.string(review.package.introOffset, millis: true))
                    if let analysis = review.package.analysis, analysis.ranModels.contains(.uhm) {
                        LabeledContent("Filler words", value: "\(analysis.fillers.count)")
                    }
                }
                .fixedSize()

                if let analysis = review.package.analysis, analysis.ranModels.contains(.who), !analysis.speakers.isEmpty {
                    speakerSection(analysis)
                }
                titleSection
                actions
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .onDisappear { player.stop() }
        .sheet(isPresented: $showPublishSheet) {
            PodbeanPublishSheet(review: review, isPresented: $showPublishSheet)
        }
    }

    // MARK: - Speakers

    private func speakerSection(_ analysis: EpisodeAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Who is speaking?").font(.title3.weight(.semibold))
            Text("Play each sample, then type or pick a name. New names are saved for next time.")
                .foregroundStyle(.secondary)
            ForEach(analysis.speakers) { info in
                HStack(spacing: 12) {
                    Button("Play 6s Sample", systemImage: "play.fill") {
                        player.play(review.masterURL, from: info.sample.lowerBound, until: info.sample.upperBound)
                    }
                    VStack(alignment: .leading) {
                        Text(EpisodePackage.defaultName(for: info.speaker)).font(.headline)
                        Text("\(Int((info.share * 100).rounded()))% of talk time").foregroundStyle(.secondary)
                    }
                    .frame(width: 130, alignment: .leading)
                    SpeakerNameField(name: review.binding(for: info.speaker), saved: library.speakers) { name in
                        remember(name)
                    }
                }
            }
        }
    }

    private func remember(_ name: String) {
        do {
            try review.remember(name, in: library)
        } catch {
            review.error = error.localizedDescription
        }
    }

    // MARK: - Title and summary

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Title and summary").font(.title3.weight(.semibold))
            HStack {
                TextField("Episode title", text: $review.package.title)
                    .textFieldStyle(.roundedBorder)
                if !review.package.suggestedTitles.isEmpty {
                    Menu("Title Ideas") {
                        ForEach(review.package.suggestedTitles, id: \.self) { idea in
                            Button(idea) { review.package.title = idea }
                        }
                    }
                    .fixedSize()
                }
            }
            TextEditor(text: $review.package.summary)
                .font(.body)
                .frame(minHeight: 70, maxHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                .overlay(alignment: .topLeading) {
                    if review.package.summary.isEmpty {
                        Text("Episode summary (plain text)").foregroundStyle(.tertiary).padding(6).allowsHitTesting(false)
                    }
                }
        }
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if review.publishResult == nil && publishing.hasCredentials {
                    Button("Publish to PodBean…", systemImage: "antenna.radiowaves.left.and.right") {
                        // Publish uploads the saved files, so save any edits first.
                        if review.hasChanges { review.save(library: library) }
                        if !review.hasChanges { showPublishSheet = true }
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Save your changes, then upload this episode to PodBean")
                    Button(review.hasChanges ? "Save Changes" : "Saved", systemImage: "square.and.arrow.down") {
                        review.save(library: library)
                    }
                    .disabled(!review.hasChanges)
                } else {
                    Button(review.hasChanges ? "Save Changes" : "Saved", systemImage: "square.and.arrow.down") {
                        review.save(library: library)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!review.hasChanges)
                }

                Menu("More", systemImage: "ellipsis.circle") {
                    Button("Play Episode", systemImage: "play.circle") { NSWorkspace.shared.open(review.masterURL) }
                    Button("Reveal in Finder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([review.masterURL])
                    }
                    Button("Copy Show Notes", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(review.package.showNotes, forType: .string)
                        review.copiedNotes = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            review.copiedNotes = false
                        }
                    }
                }
                .fixedSize()

                if review.publishResult == nil && !publishing.hasCredentials {
                    SettingsLink {
                        Label("Set up PodBean in Settings", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }

                if review.copiedNotes {
                    Text("Copied.").foregroundStyle(.secondary)
                }
            }
            if let published = review.publishResult {
                HStack(spacing: 12) {
                    Label(
                        "Published to PodBean (\(published.status.label)) on \(published.publishedAt.formatted(date: .abbreviated, time: .shortened))",
                        systemImage: "checkmark.seal.fill"
                    )
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)

                    if let permalink = published.permalinkURL {
                        Link("Open in PodBean", destination: permalink)
                            .font(.callout)
                    }
                }
                if let skipped = published.skippedArtworkReason {
                    Text(skipped)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(review.folder.path(percentEncoded: false))
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let error = review.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
    }
}

/// Modal sheet for reviewing show notes, choosing Draft vs Publish Now, and uploading to PodBean.
private struct PodbeanPublishSheet: View {
    @Environment(PublishingAccountManager.self) private var publishing
    @Bindable var review: EpisodeReview
    @Binding var isPresented: Bool
    @State private var status: PublishStatus = .draft
    @State private var progress: PublishProgress?
    @State private var errorMessage: String?
    @State private var publishTask: Task<Void, Never>?

    private var isUploading: Bool {
        publishTask != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "antenna.radiowaves.left.and.right.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Publish to PodBean").font(.title2.weight(.semibold))
                    Text("Uploads master_episode.mp3 and creates the episode on your PodBean account.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let published = review.publishResult {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            "Published to PodBean (\(published.status.label)) on \(published.publishedAt.formatted(date: .abbreviated, time: .shortened))",
                            systemImage: "checkmark.seal.fill"
                        )
                        .font(.headline)
                        .foregroundStyle(.green)

                        if let skipped = published.skippedArtworkReason {
                            Text(skipped)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }

                        if let permalink = published.permalinkURL {
                            Link("Open in PodBean →", destination: permalink)
                                .font(.callout.weight(.medium))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Title") {
                        Text(review.package.title)
                            .fontWeight(.medium)
                    }
                    if !review.package.speakerList.isEmpty {
                        LabeledContent("Speakers") {
                            Text(review.package.speakerList.joined(separator: ", "))
                        }
                    }

                    Text("Show Notes Preview").font(.subheadline.weight(.semibold))
                    ScrollView {
                        Text(review.package.showNotes)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(8)
                    }
                    .frame(minHeight: 110, maxHeight: 180)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))

                    Picker("Publication Status", selection: $status) {
                        Text("Draft (Recommended)").tag(PublishStatus.draft)
                        Text("Publish Now").tag(PublishStatus.publish)
                    }
                    .pickerStyle(.segmented)
                    .disabled(isUploading)
                }

                if let progress {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: progress.fraction)
                        Text(progress.message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }

            HStack {
                Spacer()
                if isUploading {
                    Button("Cancel", role: .cancel) {
                        publishTask?.cancel()
                        publishTask = nil
                        progress = nil
                    }
                } else if review.publishResult != nil {
                    Button("Done") {
                        isPresented = false
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel) {
                        isPresented = false
                    }
                    .keyboardShortcut(.cancelAction)

                    Button(status == .draft ? "Upload Draft" : "Publish Episode") {
                        startPublish()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func startPublish() {
        guard let credentials = publishing.credentials, credentials.isValid else {
            errorMessage = "Check your PodBean Client ID and Secret in Settings."
            return
        }
        errorMessage = nil
        progress = PublishProgress(message: "Starting upload…", fraction: 0)
        let currentPackage = review.package
        let folder = review.folder
        let chosenStatus = status

        publishTask = Task {
            defer { publishTask = nil }
            do {
                let publisher = PodbeanPublisher(credentials: credentials)
                let result = try await publisher.publish(
                    package: currentPackage,
                    in: folder,
                    status: chosenStatus
                ) { update in
                    Task { @MainActor in
                        self.progress = update
                    }
                }
                review.recordPublished(result)
                progress = nil
            } catch is CancellationError {
                progress = nil
            } catch {
                progress = nil
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// A name field with a menu of saved speakers. Typing filters the menu.
/// Return (or picking from the menu) saves the name to the Speakers list.
private struct SpeakerNameField: View {
    @Binding var name: String
    let saved: [Speaker]
    let onCommit: (String) -> Void

    private var matches: [Speaker] {
        let query = name.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, !saved.contains(where: { $0.name.caseInsensitiveCompare(query) == .orderedSame })
        else { return saved }
        return saved.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.role.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        HStack(spacing: 6) {
            TextField("Name, for example Pastor John", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onCommit(name) }
            Menu {
                if matches.isEmpty {
                    Text(saved.isEmpty ? "No saved speakers yet" : "No match. Press Return to add \"\(name)\".")
                }
                ForEach(matches) { speaker in
                    Button(speaker.role.isEmpty ? speaker.name : "\(speaker.name) (\(speaker.role))") {
                        name = speaker.name
                        onCommit(speaker.name)
                    }
                }
                if !name.isEmpty {
                    Divider()
                    Button("Clear") { name = "" }
                }
            } label: {
                Image(systemName: "person.crop.circle")
            }
            .menuIndicator(.visible)
            .fixedSize()
            .help("Saved speakers")
        }
        .frame(maxWidth: 420)
    }
}

/// The editable package for one finished run, and its folder on disk.
@MainActor @Observable
final class EpisodeReview {
    var package: EpisodePackage
    private(set) var folder: URL
    private(set) var saved: EpisodePackage?
    private(set) var publishResult: PublishResult?
    let artworkPath: String?
    var error: String?
    var copiedNotes = false

    var masterURL: URL { folder.appending(path: EpisodePackageExporter.masterName) }
    var hasChanges: Bool { saved != package }

    init(package: EpisodePackage, folder: URL, artworkPath: String?) {
        self.package = package
        self.folder = folder
        self.artworkPath = artworkPath
        self.publishResult = PublishResult.load(from: folder)
    }

    /// Reopens a past episode from its `episode.json`. Its artwork is already in the folder.
    convenience init?(reopening folder: URL) {
        guard let package = EpisodePackage.load(from: folder) else { return nil }
        self.init(package: package, folder: folder, artworkPath: nil)
        saved = package
    }

    func binding(for speaker: Int) -> Binding<String> {
        Binding { self.package.speakerNames[speaker] ?? "" } set: { self.package.speakerNames[speaker] = $0 }
    }

    /// Adds a typed name to the Speakers list, or marks a saved one as used now.
    func remember(_ rawName: String, in library: Library) throws {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !isDefaultName(name) else { return }
        try library.database.upsertSpeaker(named: name)
        try library.reload()
    }

    /// Writes the files. With `library`, also saves every typed name to the Speakers list.
    func save(library: Library?) {
        copiedNotes = false
        do {
            if let library {
                for name in Set(package.speakerNames.values) { try remember(name, in: library) }
            }
            folder = try EpisodePackageExporter.export(package, artworkPath: artworkPath, in: folder)
            saved = package
            publishResult = PublishResult.load(from: folder)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func recordPublished(_ result: PublishResult) {
        publishResult = result
    }

    private func isDefaultName(_ name: String) -> Bool {
        name.range(of: #"^speaker \d+$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
