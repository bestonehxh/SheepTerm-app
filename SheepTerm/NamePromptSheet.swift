import SwiftUI

/// Tiny one-field prompt used for creating and renaming groups.
struct NamePromptSheet: View {
    let title: String
    let confirmLabel: String
    let onCommit: (String) -> Void

    @State var name: String
    @Environment(\.dismiss) private var dismiss

    init(title: String, confirmLabel: String = "Save", initialName: String = "", onCommit: @escaping (String) -> Void) {
        self.title = title
        self.confirmLabel = confirmLabel
        self.onCommit = onCommit
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmLabel, action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 300)
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
        dismiss()
    }
}
