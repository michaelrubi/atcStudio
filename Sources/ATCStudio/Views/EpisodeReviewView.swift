import AppKit
import RestorationStation
import SwiftUI

/// After a run: name each voice, pick a title, fix the summary, and save the package.
struct EpisodeReviewView: View {
    @Environment(Library.self) private var library
    @Bindable var review: EpisodeReview
    @State private var player = PreviewPlayer()

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Label("Restoration Station: Your episode is ready.", systemImage: "checkmark.seal.fill")
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
                Button(review.hasChanges ? "Save Changes" : "Saved", systemImage: "square.and.arrow.down") {
                    review.save(library: library)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!review.hasChanges)
                Button("Reveal in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([review.masterURL])
                }
                Button("Copy Show Notes", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(review.package.showNotes, forType: .string)
                    review.copiedNotes = true
                }
                Button("Play Episode", systemImage: "play.circle") { NSWorkspace.shared.open(review.masterURL) }
                if review.copiedNotes {
                    Text("Copied.").foregroundStyle(.secondary)
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
    let artworkPath: String?
    var error: String?
    var copiedNotes = false

    var masterURL: URL { folder.appending(path: EpisodePackageExporter.masterName) }
    var hasChanges: Bool { saved != package }

    init(package: EpisodePackage, folder: URL, artworkPath: String?) {
        self.package = package
        self.folder = folder
        self.artworkPath = artworkPath
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
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func isDefaultName(_ name: String) -> Bool {
        name.range(of: #"^speaker \d+$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
