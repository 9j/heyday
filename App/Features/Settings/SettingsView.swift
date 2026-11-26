import HeydayKit
import SwiftUI

/// The app's settings: the connected account, what the Screener has been told,
/// what to notify about, where Reply Later and Set Aside are kept, and who translates. A window of tabs on
/// a Mac; on iPhone and iPad a list that leads to each.
struct SettingsView: View {
    let services: AppServices

    #if !os(macOS)
    @Environment(\.dismiss) private var dismiss
    #endif

    var body: some View {
        #if os(macOS)
        TabView {
            Tab("Account", systemImage: "person.crop.circle") { account }
            Tab("Screener", systemImage: "hand.thumbsup") { screener }
            Tab("Notifications", systemImage: "bell") { notifications }
            Tab("Folders", systemImage: "folder") { folders }
            Tab("Translation", systemImage: "translate") { translation }
        }
        .frame(width: 560, height: 420)
        #else
        NavigationStack {
            List {
                NavigationLink { account.navigationTitle("Account") } label: { Label("Account", systemImage: "person.crop.circle") }
                NavigationLink { screener.navigationTitle("Screener") } label: { Label("Screener", systemImage: "hand.thumbsup") }
                NavigationLink { notifications.navigationTitle("Notifications") } label: { Label("Notifications", systemImage: "bell") }
                NavigationLink { folders.navigationTitle("Folders") } label: { Label("Folders", systemImage: "folder") }
                NavigationLink { translation.navigationTitle("Translation") } label: { Label("Translation", systemImage: "translate") }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #endif
    }

    private var account: some View {
        AccountSettings(session: services.session, workspace: services.activeWorkspace)
    }

    @ViewBuilder
    private var screener: some View {
        if let workspace = services.activeWorkspace {
            ScreenerSettings(workspace: workspace)
        } else {
            ContentUnavailableView("No Account Connected", systemImage: "hand.thumbsup")
        }
    }

    @ViewBuilder
    private var notifications: some View {
        if let workspace = services.activeWorkspace {
            NotificationSettings(workspace: workspace)
        } else {
            ContentUnavailableView("No Account Connected", systemImage: "bell")
        }
    }

    @ViewBuilder
    private var folders: some View {
        if let workspace = services.activeWorkspace {
            FolderSettings(workspace: workspace)
        } else {
            ContentUnavailableView("No Account Connected", systemImage: "folder")
        }
    }

    private var translation: some View {
        TranslationSettingsPane(store: services.translation)
    }
}

private struct AccountSettings: View {
    let session: Store<AccountFeature>
    /// The connected account's window state, for what it keeps the same on every Mac.
    let workspace: Workspace?

    @State private var isConfirmingRemoval = false

    private var account: MailAccount? {
        switch session.state {
        case .ready(let account, _), .unavailable(let account, _), .connecting(let account, _): account
        case .restoring, .settingUp: nil
        }
    }

    var body: some View {
        if let account {
            Form {
                Section {
                    LabeledContent("Name", value: account.sender.name)
                    LabeledContent("Email Address", value: account.sender.address)
                    LabeledContent("Username", value: account.username)
                }
                Section {
                    LabeledContent("Incoming Mail (IMAP)", value: Self.describe(account.imap))
                    LabeledContent("Outgoing Mail (SMTP)", value: Self.describe(account.smtp))
                }
                if let workspace {
                    Section {
                        LabeledContent("Screener, Notifications and Folders") {
                            HStack {
                                Text(Self.describe(workspace.sync.state.status))
                                    .foregroundStyle(.secondary)
                                Button("Sync Now") { workspace.syncNow() }
                                    .disabled(workspace.sync.state.status == .running)
                            }
                        }
                    } header: {
                        Text("On Your Other Devices")
                    } footer: {
                        Text("Kept in a folder named Heyday in this account.")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Section {
                    Button("Remove Account…", role: .destructive) { isConfirmingRemoval = true }
                }
            }
            .formStyle(.grouped)
            .confirmationDialog("Remove \(account.sender.address) from Heyday?", isPresented: $isConfirmingRemoval) {
                Button("Remove Account", role: .destructive) { session.send(.signOutRequested) }
            } message: {
                Text("Your mail stays on the server. You can add the account again at any time.")
            }
        } else {
            ContentUnavailableView("No Account", systemImage: "person.crop.circle", description: Text("Add an account in the main window."))
        }
    }

    private static func describe(_ status: SyncFeature.Status) -> String {
        switch status {
        case .waiting: "Not synced yet"
        case .running: "Syncing…"
        case .upToDate(let time): "Up to date as of \(time.formatted(date: .omitted, time: .shortened))"
        case .failed(let error): error.userMessage
        }
    }

    private static func describe(_ endpoint: ServerEndpoint) -> String {
        let security = switch endpoint.security {
        case .tls: "TLS"
        case .startTLS: "STARTTLS"
        case .none: "no encryption"
        }
        return "\(endpoint.host):\(endpoint.port), \(security)"
    }
}

/// Every sender the Screener has an answer for, and a way to change the answer.
private struct ScreenerSettings: View {
    let workspace: Workspace

    private struct Row: Identifiable {
        let address: String
        let decision: SenderDecision
        var id: String { address }
    }

    var body: some View {
        if let rules = workspace.rules.state.rules {
            VStack(alignment: .leading, spacing: 10) {
                Text("Screening mail that arrived after \(rules.screeningSince.formatted(date: .abbreviated, time: .shortened))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                let rows = rules.decisions.map { Row(address: $0.key, decision: $0.value) }.sorted { $0.address < $1.address }
                if rows.isEmpty {
                    ContentUnavailableView("No Decisions Yet", systemImage: "hand.thumbsup")
                } else {
                    decisions(rows)
                }
            }
            .padding(20)
        } else {
            ProgressView()
        }
    }

    @ViewBuilder
    private func decisions(_ rows: [Row]) -> some View {
        #if os(macOS)
        Table(rows) {
            TableColumn("Sender", value: \.address)
            TableColumn("Their Email Goes To") { row in
                destinationPicker(for: row)
                    .labelsHidden()
            }
            .width(160)
        }
        #else
        // A table keeps only its first column on a phone, so each sender is a row
        // with the choice beside it.
        List(rows) { row in
            destinationPicker(for: row, label: row.address)
        }
        .listStyle(.plain)
        #endif
    }

    private func destinationPicker(for row: Row, label: String = "Their email goes to") -> some View {
        Picker(label, selection: decisionBinding(for: row)) {
            Text("Mebox").tag(SenderDecision.approved(.mebox))
            Text("The Feed").tag(SenderDecision.approved(.feed))
            Text("Paper Trail").tag(SenderDecision.approved(.paperTrail))
            Divider()
            Text("Screened Out").tag(SenderDecision.screenedOut)
        }
    }

    private func decisionBinding(for row: Row) -> Binding<SenderDecision> {
        Binding(
            get: { row.decision },
            set: { workspace.decide($0, for: EmailAddress(address: row.address)) }
        )
    }
}

/// Who and what new mail is announced for, and the way to make it quiet again.
private struct NotificationSettings: View {
    let workspace: Workspace

    var body: some View {
        if let rules = workspace.notifications.state.rules {
            Form {
                Section {
                    if rules.notifyingSenders.isEmpty {
                        Text("None")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(rules.notifyingSenders, id: \.self) { address in
                        // Listed because it is on: switching it off takes it off the list.
                        Toggle(address, isOn: Binding(
                            get: { true },
                            set: { if !$0 { workspace.setNotifying(false, about: EmailAddress(address: address)) } }
                        ))
                    }
                } header: {
                    Text("Notify Me When These Senders Write")
                } footer: {
                    Text("Turned on from a conversation’s menu.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Section {
                    LabeledContent("Conversations Being Followed", value: String(rules.notifyingConversationCount))
                    Button("Stop Following All of Them") { workspace.notifications.send(.conversationsSilenced(at: .now)) }
                        .disabled(rules.notifyingConversationCount == 0)
                }
            }
            .formStyle(.grouped)
        } else {
            ProgressView()
        }
    }
}

/// Which mailbox on the server holds Reply Later mail, and which Set Aside.
private struct FolderSettings: View {
    let workspace: Workspace

    var body: some View {
        Form {
            Section {
                ForEach(MailboxDirectory.AppFolder.allCases, id: \.self) { folder in
                    Picker(folder.rawValue, selection: assignment(of: folder)) {
                        Text("Automatic: \(workspace.directory.path(for: folder))").tag(String?.none)
                        Divider()
                        ForEach(choices(for: folder), id: \.path) { choice in
                            Text(choice.label).tag(Optional(choice.path))
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// The mailboxes on offer: the person's folders and labels, plus wherever the
    /// folder is now if that is not one the server listed at launch.
    private func choices(for folder: MailboxDirectory.AppFolder) -> [(path: String, label: String)] {
        var choices = workspace.directory.userFolders().map { (path: $0.path, label: $0.displayPath) }
        if let current = workspace.appFolders.state.assignments?[folder], !choices.contains(where: { $0.path == current }) {
            choices.insert((current, current), at: 0)
        }
        return choices
    }

    private func assignment(of folder: MailboxDirectory.AppFolder) -> Binding<String?> {
        Binding(
            get: { workspace.appFolders.state.assignments?[folder] },
            set: { workspace.appFolders.send(.reassigned(folder, path: $0, at: .now)) }
        )
    }
}

/// Which language mail is translated into, by which service, and that service's key.
private struct TranslationSettingsPane: View {
    let store: Store<TranslationSettingsFeature>

    /// A key being typed. It leaves this field only for the keychain.
    @State private var draftKey = ""

    private var settings: TranslationSettings { store.state.settings }
    private var service: TranslationService { settings.chosenService }
    private var hasKey: Bool { store.state.servicesWithKey.contains(service.id) }

    var body: some View {
        Form {
            Section {
                Picker("Translate Into", selection: binding(\.language)) {
                    ForEach(TranslationLanguages.all) { language in
                        Text(language.nativeName).tag(language.code)
                    }
                }
                Picker("Show", selection: binding(\.display)) {
                    Text("The translation under the original").tag(TranslationSettings.Display.withOriginal)
                    Text("The translation only").tag(TranslationSettings.Display.translationOnly)
                }
            }
            Section {
                Picker("Translate With", selection: binding(\.service)) {
                    ForEach(TranslationServices.all) { service in
                        Text(service.name).tag(service.id)
                    }
                }
                if service.takesAddress {
                    TextField("Address", text: binding(\.customAddress), prompt: Text("https://example.com/v1"))
                }
                if service.takesModel {
                    TextField("Model", text: model, prompt: Text(service.defaultModel.isEmpty ? "The model’s name" : service.defaultModel))
                }
                if service.keyNeed != .none {
                    keyField
                }
            } footer: {
                Text(explanation)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.service) { draftKey = "" }
        .alert(
            "Couldn’t Save",
            isPresented: Binding(get: { store.state.storageProblem != nil }, set: { if !$0 { store.send(.storageProblemDismissed) } })
        ) {
            Button("OK") {}
        } message: {
            Text(store.state.storageProblem ?? "")
        }
    }

    @ViewBuilder
    private var keyField: some View {
        LabeledContent("API Key") {
            HStack {
                SecureField("API Key", text: $draftKey, prompt: Text(hasKey ? "Saved in your keychain" : "Paste a key"))
                    .labelsHidden()
                    .onSubmit(saveKey)
                // With nothing typed, the button forgets the stored key.
                Button(draftKey.isEmpty && hasKey ? "Remove" : "Save", action: saveKey)
                    .disabled(draftKey.isEmpty && !hasKey)
            }
        }
        if let keysURL = service.keysURL {
            Link("Get a key from \(service.name)", destination: keysURL)
        }
    }

    private func saveKey() {
        store.send(.keyEntered(draftKey, service: service.id))
        draftKey = ""
    }

    /// The one thing a person cannot see for themselves: where their mail's text goes.
    private var explanation: String {
        "Translate sends the open messages’ text to \(service.name)."
    }

    private var model: Binding<String> {
        Binding(
            get: { settings.models[service.id] ?? "" },
            set: { entered in
                var changed = settings
                changed.models[service.id] = entered.isEmpty ? nil : entered
                store.send(.changed(changed))
            }
        )
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<TranslationSettings, Value>) -> Binding<Value> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in
                var changed = settings
                changed[keyPath: keyPath] = value
                store.send(.changed(changed))
            }
        )
    }
}
