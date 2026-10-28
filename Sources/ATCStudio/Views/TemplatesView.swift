import RestorationStation
import SwiftUI
import UniformTypeIdentifiers

struct TemplatesView: View {
    @Environment(Library.self) private var library
    @State private var selection: Template.ID?
    @State private var pendingDelete: Template?
    @State private var errorMessage: String?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(library.templates, selection: $selection) { template in
                    Text(template.name).tag(template.id)
                }
                Divider()
                HStack(spacing: 0) {
                    Button("Add Template", systemImage: "plus", action: addTemplate)
                    Button("Delete Template", systemImage: "minus") {
                        pendingDelete = library.templates.first { $0.id == selection }
                    }
                    .disabled(selection == nil)
                    Spacer()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(minWidth: 200, idealWidth: 220, maxWidth: 300)

            Group {
                if let template = library.templates.first(where: { $0.id == selection }) {
                    TemplateEditor(template: template).id(template.id)
                } else {
                    ContentUnavailableView("Pick a template", systemImage: "rectangle.stack",
                                           description: Text("Or press + to make a new one."))
                }
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if selection == nil { selection = library.templates.first?.id } }
        .confirmationDialog(
            "Delete \"\(pendingDelete?.name ?? "")\"?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Delete Template", role: .destructive) {
                guard let template = pendingDelete else { return }
                run { try library.deleteTemplate(template) }
                selection = library.templates.first?.id
            }
        } message: {
            Text("Your audio files are not deleted. Only this template is removed.")
        }
        .errorAlert($errorMessage)
    }

    private func addTemplate() {
        run {
            let template = try library.save(Template(name: library.unusedTemplateName()))
            selection = template.id
        }
    }

    private func run(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = error.localizedDescription }
    }
}

/// Edits a draft copy of one template. Changes are written on Save.
private struct TemplateEditor: View {
    @Environment(Library.self) private var library
    @Environment(EpisodeJob.self) private var job
    let template: Template
    @State private var draft: Template
    @State private var errorMessage: String?
    @State private var player = PreviewPlayer()
    @State private var previewTask: Task<Void, Never>?
    @State private var rendering: AudioCompositionService.Transition?
    @State private var previewFile: URL?
    @State private var previewError: String?

    init(template: Template) {
        self.template = template
        _draft = State(initialValue: template)
    }

    private var hasChanges: Bool { draft != template }

    var body: some View {
        Form {
            Section {
                TextField("Template name", text: $draft.name)
            }

            Section("Intro bumper") {
                FilePickerRow(title: "Intro Music", path: $draft.introMusicPath, types: .audioStems)
                FilePickerRow(title: "Intro Voice-Over", path: $draft.introVoPath, types: .audioStems,
                              hint: "Optional. Swap this for seasonal announcements.")
            }

            Section("Outro bumper") {
                FilePickerRow(title: "Outro Music", path: $draft.outroMusicPath, types: .audioStems)
                FilePickerRow(title: "Outro Voice-Over", path: $draft.outroVoPath, types: .audioStems,
                              hint: "Optional.")
            }

            Section("Artwork") {
                FilePickerRow(title: "Episode Artwork", path: $draft.artworkPath, types: [.jpeg, .png])
            }

            Section {
                TextField("Custom vocabulary", text: $draft.customVocabulary,
                          prompt: Text("As The Church, Pastor John, Ecclesiastes"), axis: .vertical)
                    .lineLimit(3...8)
                Text("\(draft.vocabularyTerms.count) words. Separate each word or name with a comma.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Custom vocabulary")
            } footer: {
                Text("Church name, podcast name, pastors' names, and Bible words. This helps the transcript spell them right.")
            }

            Section {
                SliderRow(title: "Music lead-in", value: $draft.introLeadInSec, range: 0...10, unit: .seconds)
                SliderRow(title: "Music fade-in", value: $draft.duckRampSec, range: 0.1...5, unit: .seconds)
                SliderRow(title: "Music under voice (max)", value: $draft.duckingDb, range: -40...0, unit: .decibels)
                SliderRow(title: "Hold after voice", value: $draft.introSwellSec, range: 0...5, unit: .seconds)
                SliderRow(title: "Crossfade to message", value: $draft.crossfadeSec, range: 0...5, unit: .seconds)
            } header: {
                Text("Intro mix")
            } footer: {
                Text("The music starts quiet and gets louder. It stays at one level while the intro voice plays. Then it fades into the message.")
            }

            Section {
                SliderRow(title: "Music under last words", value: $draft.outroUnderlapSec, range: 0...10, unit: .seconds)
                SliderRow(title: "Fade out", value: $draft.outroFadeSec, range: 0...10, unit: .seconds)
            } header: {
                Text("Outro mix")
            } footer: {
                Text("The music comes in under the speaker's last words. It stays at one level under the outro voice, then fades out. The finished episode is set to standard podcast loudness.")
            }

            previewSection

            Section {
                HStack {
                    Button("Reset Mix to Defaults", action: resetMix)
                    Spacer()
                    Button("Revert") { draft = template }
                        .disabled(!hasChanges)
                    Button("Save", action: save)
                        .keyboardShortcut("s")
                        .buttonStyle(.borderedProminent)
                        .disabled(!hasChanges)
                }
            }
        }
        .formStyle(.grouped)
        .errorAlert($errorMessage)
        .onDisappear(perform: stopPreview)
    }

    // MARK: - Preview

    @ViewBuilder private var previewSection: some View {
        Section {
            if let source = job.source, job.isReady {
                HStack {
                    previewButton("Hear Intro", .intro, source: source)
                        .disabled(draft.introMusicPath == nil && draft.introVoPath == nil)
                    previewButton("Hear Outro", .outro, source: source)
                        .disabled(draft.outroMusicPath == nil && draft.outroVoPath == nil)
                    if rendering != nil {
                        ProgressView().controlSize(.small)
                        Text("Mixing…").foregroundStyle(.secondary)
                    }
                    if player.isPlaying {
                        Button("Stop", systemImage: "stop.fill") { player.stop() }
                    }
                }
                if let previewError {
                    Label(previewError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            } else {
                Text("Add a recording in the Workspace tab first. Then you can hear the intro and outro here.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Hear the mix")
        } footer: {
            if let source = job.source, job.isReady {
                Text("Uses the settings above, even before you save. Mixes only a few seconds of \"\(source.lastPathComponent)\", so it is fast.")
            }
        }
    }

    private func previewButton(_ title: String, _ transition: AudioCompositionService.Transition, source: URL) -> some View {
        Button(title, systemImage: "play.fill") { preview(transition, source: source) }
            .disabled(rendering != nil)
    }

    private func preview(_ transition: AudioCompositionService.Transition, source: URL) {
        stopPreview()
        rendering = transition
        previewError = nil
        let template = draft
        let trim = job.trim
        let output = FileManager.default.temporaryDirectory.appending(path: "atc-preview-\(UUID().uuidString).mp3")
        previewTask = Task {
            do {
                let result = try await AudioCompositionService(ffmpeg: .locate())
                    .preview(transition, mainAudio: source, template: template, trim: trim, to: output)
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: output)
                    return
                }
                previewFile = output
                player.play(output, from: 0, until: result.totalDurationSeconds)
            } catch is CancellationError {
            } catch {
                previewError = error.localizedDescription
            }
            if !Task.isCancelled { rendering = nil }
        }
    }

    private func stopPreview() {
        previewTask?.cancel()
        previewTask = nil
        rendering = nil
        player.stop()
        if let previewFile { try? FileManager.default.removeItem(at: previewFile) }
        previewFile = nil
    }

    private func resetMix() {
        let defaults = Template(name: draft.name)
        draft.introLeadInSec = defaults.introLeadInSec
        draft.duckingDb = defaults.duckingDb
        draft.duckRampSec = defaults.duckRampSec
        draft.introSwellDb = defaults.introSwellDb
        draft.introSwellSec = defaults.introSwellSec
        draft.crossfadeSec = defaults.crossfadeSec
        draft.outroUnderlapSec = defaults.outroUnderlapSec
        draft.outroFadeSec = defaults.outroFadeSec
    }

    private func save() {
        do { try library.save(draft) } catch { errorMessage = error.localizedDescription }
    }
}

private extension [UTType] {
    static let audioStems: [UTType] = [.wav, .mp3]
}

private struct FilePickerRow: View {
    @Environment(Library.self) private var library
    let title: String
    @Binding var path: String?
    let types: [UTType]
    var hint: String?
    @State private var isPicking = false
    @State private var errorMessage: String?

    private var fileExists: Bool {
        path.map { FileManager.default.fileExists(atPath: $0) } ?? false
    }

    var body: some View {
        LabeledContent {
            HStack {
                if let path {
                    Label(URL(filePath: path).lastPathComponent,
                          systemImage: fileExists ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(fileExists ? .green : .orange)
                        .help(fileExists ? "Saved copy: \(path)" : "File not found: \(path)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Clear", systemImage: "xmark.circle") { self.path = nil }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                } else {
                    Text("None").foregroundStyle(.secondary)
                }
                Button("Choose…") { isPicking = true }
            }
        } label: {
            Text(title)
            if let hint { Text(hint) }
        }
        .fileImporter(isPresented: $isPicking, allowedContentTypes: types) { result in
            do {
                path = try library.importAsset(at: result.get())
            } catch {
                errorMessage = "Could not copy the file. \(error.localizedDescription)"
            }
        }
        .errorAlert($errorMessage)
    }
}

private struct SliderRow: View {
    enum Unit { case seconds, decibels }

    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: Unit

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range, step: unit == .seconds ? 0.1 : 0.5)
                Text(label)
                    .monospacedDigit()
                    .frame(width: 64, alignment: .trailing)
            }
        }
    }

    private var label: String {
        switch unit {
        case .seconds: value.formatted(.number.precision(.fractionLength(1))) + " s"
        case .decibels: value.formatted(.number.precision(.fractionLength(1))) + " dB"
        }
    }
}

extension View {
    func errorAlert(_ message: Binding<String?>) -> some View {
        alert("Something went wrong",
              isPresented: Binding(get: { message.wrappedValue != nil },
                                   set: { if !$0 { message.wrappedValue = nil } })) {
            Button("OK") {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
