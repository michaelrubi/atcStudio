import RestorationStation
import SwiftUI

struct SpeakersView: View {
    @Environment(Library.self) private var library
    @State private var selection: Speaker.ID?
    @State private var search = ""
    @State private var editing: Speaker?
    @State private var pendingDelete: Speaker?
    @State private var errorMessage: String?

    private var filtered: [Speaker] {
        guard !search.isEmpty else { return library.speakers }
        return library.speakers.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.role.localizedCaseInsensitiveContains(search)
        }
    }

    private var selected: Speaker? { library.speakers.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                TextField("Search speakers", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Spacer()
                Button("Add Speaker", systemImage: "plus") { editing = Speaker(name: "") }
                Button("Edit", systemImage: "pencil") { editing = selected }
                    .disabled(selected == nil)
                Button("Delete", systemImage: "trash") { pendingDelete = selected }
                    .disabled(selected == nil)
            }

            Table(filtered, selection: $selection) {
                TableColumn("Name", value: \.name)
                TableColumn("Role", value: \.role)
                TableColumn("Last used") { speaker in
                    Text(speaker.lastUsedAt?.formatted(date: .abbreviated, time: .omitted) ?? "Never")
                        .foregroundStyle(speaker.lastUsedAt == nil ? .secondary : .primary)
                }
            }
            .contextMenu(forSelectionType: Speaker.ID.self) { ids in
                if let speaker = library.speakers.first(where: { ids.contains($0.id) }) {
                    Button("Edit") { editing = speaker }
                    Button("Delete", role: .destructive) { pendingDelete = speaker }
                }
            } primaryAction: { ids in
                editing = library.speakers.first { ids.contains($0.id) }
            }
            .overlay {
                if library.speakers.isEmpty {
                    ContentUnavailableView("No speakers yet", systemImage: "person.2",
                                           description: Text("Press Add Speaker. Names you type while mapping speakers are saved here too."))
                }
            }
        }
        .sheet(item: $editing) { speaker in
            SpeakerEditor(speaker: speaker) { saved in
                do {
                    let row = try library.save(saved)
                    selection = row.id
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }
        }
        .confirmationDialog(
            "Delete \"\(pendingDelete?.name ?? "")\"?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Delete Speaker", role: .destructive) {
                guard let speaker = pendingDelete else { return }
                do { try library.deleteSpeaker(speaker) } catch { errorMessage = error.localizedDescription }
            }
        }
        .errorAlert($errorMessage)
    }
}

private struct SpeakerEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Speaker
    @State private var errorMessage: String?
    /// Returns an error message, or nil on success.
    let onSave: (Speaker) -> String?

    init(speaker: Speaker, onSave: @escaping (Speaker) -> String?) {
        _draft = State(initialValue: speaker)
        self.onSave = onSave
    }

    var body: some View {
        Form {
            TextField("Name", text: $draft.name, prompt: Text("Pastor John Smith"))
            TextField("Role", text: $draft.role, prompt: Text("Lead Pastor, Host, Guest…"))
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(draft.id == nil ? "Add" : "Save") {
                    errorMessage = onSave(draft)
                    if errorMessage == nil { dismiss() }
                }
                .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
