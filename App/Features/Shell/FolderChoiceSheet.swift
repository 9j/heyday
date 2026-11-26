import HeydayKit
import SwiftUI

/// Asked when the server would not make the folder for Reply Later or Set Aside:
/// which mailbox to use instead. The mail that was being put away waits for the answer.
struct FolderChoiceSheet: View {
    let choice: AppFoldersFeature.Choice
    let workspace: Workspace

    private enum Source {
        case existing, new
    }

    @State private var source: Source
    @State private var existingPath: String?
    @State private var newName = ""

    private let candidates: [Mailbox]
    private var trimmedName: String { newName.trimmingCharacters(in: .whitespaces) }

    init(choice: AppFoldersFeature.Choice, workspace: Workspace) {
        self.choice = choice
        self.workspace = workspace
        candidates = workspace.directory.userFolders()
        // A mailbox that already goes by the folder's name is the likeliest answer.
        let likeliest = candidates.first { $0.name == choice.folder.rawValue } ?? candidates.first
        _existingPath = State(initialValue: likeliest?.path)
        _source = State(initialValue: likeliest == nil ? .new : .existing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Choose a Mailbox for \(choice.folder.rawValue)")
                    .font(.headline)
                Text("The server wouldn’t make “\(choice.refusedPath)”. Nothing was moved.")
                    .fixedSize(horizontal: false, vertical: true)
                Text(choice.refusal.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("Where to keep it", selection: $source) {
                Text("Use a folder or label that already exists").tag(Source.existing)
                Text("Make a folder with another name").tag(Source.new)
            }
            .choiceOfSentences()
            .labelsHidden()

            switch source {
            case .existing:
                Picker("Mailbox", selection: $existingPath) {
                    ForEach(candidates) { mailbox in
                        Text(mailbox.displayPath).tag(Optional(mailbox.path))
                    }
                }
            case .new:
                TextField("Name", text: $newName, prompt: Text("\(choice.folder.rawValue) (Heyday)"))
                    .onSubmit(confirm)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    workspace.appFolders.send(.choiceCancelled(choice.folder))
                }
                Button(source == .existing ? "Use This Mailbox" : "Make Folder", action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConfirm)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var canConfirm: Bool {
        switch source {
        case .existing: existingPath != nil
        case .new: !trimmedName.isEmpty
        }
    }

    private func confirm() {
        guard canConfirm else { return }
        switch source {
        case .existing:
            if let existingPath {
                workspace.appFolders.send(.existingChosen(choice.folder, path: existingPath, at: .now))
            }
        case .new:
            workspace.appFolders.send(.newFolderChosen(choice.folder, path: workspace.directory.path(forNewFolderNamed: trimmedName)))
        }
    }
}
