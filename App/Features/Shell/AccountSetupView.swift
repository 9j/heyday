import HeydayKit
import SwiftUI

/// The form an account is added with: who you are, how to sign in (Password / App Password
/// or OAuth 2.0), and where your IMAP and SMTP servers are. Entering an email address
/// auto-fills settings from built-in presets or Thunderbird's ISPDB.
struct AccountSetupView: View {
    let setup: AccountSetup
    let problem: String?
    let onChange: (AccountSetup) -> Void
    let onAutoconfig: (String) -> Void
    let onConnect: () -> Void

    @State private var showsServers = false
    @State private var lastAutoDetectedDomain = ""

    private var detectedDomain: String {
        MailProviderCatalog.domain(of: setup.address) ?? ""
    }

    private var activePreset: MailProviderPreset? {
        setup.matchedPreset
    }

    private var allowsPassword: Bool {
        activePreset?.authSupport.allowsPassword ?? true
    }

    private var allowsOAuth2: Bool {
        guard let preset = activePreset else { return true }
        return preset.authSupport.oauthProvider != nil
    }

    private var serversSummary: String {
        guard !setup.imap.host.isEmpty || !setup.smtp.host.isEmpty else { return "Not configured" }
        let imap = setup.imap.host.isEmpty ? "—" : "\(setup.imap.host):\(setup.imap.port)"
        let smtp = setup.smtp.host.isEmpty ? "—" : "\(setup.smtp.host):\(setup.smtp.port)"
        return "\(imap) · \(smtp)"
    }

    private var primaryButtonTitle: String {
        guard setup.authChoice == .oauth2 else { return "Connect" }
        switch setup.oauthProvider {
        case .fastmail: return "Sign In with Fastmail"
        case .microsoft: return "Sign In with Microsoft"
        case .google: return "Sign In with Google"
        case .custom: return "Sign In with OAuth 2.0"
        }
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: binding(\.name), prompt: Text("Jane Doe"))
                // Verbatim: left to itself, the system turns an address into a link.
                TextField("Email Address", text: binding(\.address), prompt: Text(verbatim: "you@example.com"))
                    .typedAsAnAddress()

                autoconfigStatusRow
            } header: {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Add Your Mail Account")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.primary)
                        .textCase(nil)
                    providerQuickBar
                }
                .padding(.bottom, 8)
            }

            signInSection

            Section {
                DisclosureGroup(isExpanded: $showsServers) {
                    Group {
                        Text("Incoming Mail (IMAP)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        server(\.imap)
                        Text("Outgoing Mail (SMTP)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                        server(\.smtp)
                        Toggle("The server keeps a copy of what I send", isOn: binding(\.serverSavesSentMail))
                    }
                } label: {
                    HStack {
                        Text("Server Settings")
                        Spacer()
                        Text(serversSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } footer: {
                Text(setup.authChoice == .oauth2
                    ? "OAuth tokens are stored in your keychain and refreshed automatically."
                    : "The password is kept in your keychain.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 560)
        .onAppear {
            showsServers = setup.imap.host.isEmpty && setup.smtp.host.isEmpty
            if !setup.imap.host.isEmpty {
                lastAutoDetectedDomain = detectedDomain
            }
        }
        .task(id: detectedDomain) {
            let domain = detectedDomain
            guard !domain.isEmpty,
                  domain != lastAutoDetectedDomain,
                  !ServerEndpoint.isLoopback(setup.imap.host)
            else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            lastAutoDetectedDomain = domain
            if let preset = MailProviderCatalog.preset(forDomain: domain) {
                applyPreset(preset)
            } else {
                onAutoconfig(domain)
            }
        }
        .onChange(of: setup.autoconfigStatus) { _, status in
            if case .matched = status {
                showsServers = false
            } else if case .notFound = status {
                showsServers = true
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                #if os(macOS)
                Button("Proton Mail Bridge", action: fillInBridgeSettings)
                    .help("Fills in 127.0.0.1 with ports 1143 and 1025. Copy the username and password from Bridge’s Mailbox details.")
                Spacer()
                #endif
                Button(action: onConnect) {
                    Text(primaryButtonTitle)
                        #if !os(macOS)
                        // On a phone the one button spans the screen, under the thumb.
                        .frame(maxWidth: .infinity)
                        #endif
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: 560)
            #if !os(macOS)
            .background(.bar)
            #endif
        }
    }

    // MARK: Quick provider strip & autoconfig indicator

    private var providerQuickBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(MailProviderCatalog.all) { preset in
                    let isSelected = setup.matchedPresetID == preset.id
                    Button {
                        applyPreset(preset)
                    } label: {
                        Text(preset.displayName)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                isSelected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06),
                                in: Capsule()
                            )
                            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .textCase(nil)
    }

    @ViewBuilder
    private var autoconfigStatusRow: some View {
        switch setup.autoconfigStatus {
        case .idle:
            EmptyView()
        case .lookingUp(let domain):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Looking up server settings for \(domain)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .matched(let name):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                Text("Configured for \(name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .notFound:
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Text("No automatic settings found — enter IMAP and SMTP details below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Sign In section

    private var signInSection: some View {
        Section {
            if allowsPassword && allowsOAuth2 {
                Picker("Method", selection: authChoiceBinding) {
                    Text("Password").tag(AccountSetup.AuthChoice.password)
                    Text("OAuth 2.0").tag(AccountSetup.AuthChoice.oauth2)
                }
                .pickerStyle(.segmented)
            }

            TextField("Username", text: binding(\.username), prompt: Text("Usually your email address"))
                .typedAsAnAddress()

            switch setup.authChoice {
            case .password:
                SecureField("Password", text: binding(\.password), prompt: Text(passwordPrompt))
                    .onSubmit(onConnect)
            case .oauth2:
                oauthFields
            }
        } header: {
            Text("Sign In")
        } footer: {
            signInFooter
        }
    }

    private var passwordPrompt: String {
        switch setup.matchedPresetID {
        case "icloud": "App-specific password (xxxx-xxxx-xxxx-xxxx)"
        case "gmail", "fastmail", "yahoo": "App password"
        default: ""
        }
    }

    @ViewBuilder
    private var oauthFields: some View {
        if activePreset == nil {
            Picker("Provider", selection: oauthProviderBinding) {
                ForEach(OAuth2ProviderID.allCases, id: \.self) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
        }

        if setup.oauthProvider.supportsDynamicRegistration {
            LabeledContent("Client Registration") {
                Text("Automatic (PKCE)")
                    .foregroundStyle(.secondary)
            }
        } else {
            TextField("OAuth Client ID", text: binding(\.oauthClientID), prompt: Text(clientIDPrompt))
                .typedAsAnAddress()
            if setup.oauthProvider == .google || setup.oauthProvider == .custom {
                SecureField("Client Secret (optional)", text: binding(\.oauthClientSecret), prompt: Text("Only if required by your client"))
            }
        }

        if setup.oauthProvider == .custom {
            TextField("Authorization URL", text: binding(\.customAuthURL), prompt: Text(verbatim: "https://auth.example.com/authorize"))
                .typedAsAnAddress()
            TextField("Token URL", text: binding(\.customTokenURL), prompt: Text(verbatim: "https://auth.example.com/token"))
                .typedAsAnAddress()
            TextField("Scopes", text: binding(\.customScopes), prompt: Text(verbatim: "imap smtp offline_access"))
                .typedAsAnAddress()
        }
    }

    private var clientIDPrompt: String {
        switch setup.oauthProvider {
        case .google: "123456-abc.apps.googleusercontent.com"
        case .microsoft: "Application (client) ID from Entra ID"
        case .fastmail: "Optional"
        case .custom: "Client ID"
        }
    }

    @ViewBuilder
    private var signInFooter: some View {
        let helpText: String? = switch setup.authChoice {
        case .password: activePreset?.passwordHelp
        case .oauth2: activePreset?.oauthHelp ?? defaultOAuthHelp(for: setup.oauthProvider)
        }
        let helpURL: URL? = switch setup.authChoice {
        case .password: activePreset?.passwordHelpURL
        case .oauth2: activePreset?.oauthHelpURL ?? defaultOAuthHelpURL(for: setup.oauthProvider)
        }

        if let helpText {
            VStack(alignment: .leading, spacing: 4) {
                Text(helpText)
                if let helpURL {
                    Link("Open provider settings ↗", destination: helpURL)
                        .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func defaultOAuthHelp(for provider: OAuth2ProviderID) -> String? {
        switch provider {
        case .fastmail: MailProviderCatalog.fastmail.oauthHelp
        case .microsoft: MailProviderCatalog.outlook.oauthHelp
        case .google: MailProviderCatalog.gmail.oauthHelp
        case .custom: "Uses Authorization Code + PKCE and authenticates IMAP and SMTP with XOAUTH2."
        }
    }

    private func defaultOAuthHelpURL(for provider: OAuth2ProviderID) -> URL? {
        switch provider {
        case .fastmail: MailProviderCatalog.fastmail.oauthHelpURL
        case .microsoft: MailProviderCatalog.outlook.oauthHelpURL
        case .google: MailProviderCatalog.gmail.oauthHelpURL
        case .custom: nil
        }
    }

    // MARK: Actions & bindings

    private func applyPreset(_ preset: MailProviderPreset) {
        var filled = setup
        let defaultID = preset.authSupport.oauthProvider.flatMap(AppServices.defaultOAuthClientID(for:))
        filled.apply(preset: preset, defaultClientID: defaultID)
        onChange(filled)
        showsServers = false
    }

    #if os(macOS)
    /// Bridge's server settings, keeping whatever has been typed about the person.
    /// Bridge runs on a Mac, so the button is only there.
    private func fillInBridgeSettings() {
        var filled = AccountSetup.protonBridge
        filled.name = setup.name
        filled.address = setup.address
        filled.username = setup.username
        filled.password = setup.password
        onChange(filled)
        showsServers = false
    }
    #endif

    private var authChoiceBinding: Binding<AccountSetup.AuthChoice> {
        Binding(
            get: { setup.authChoice },
            set: { newChoice in
                var changed = setup
                changed.authChoice = newChoice
                if newChoice == .oauth2, changed.oauthClientID.isEmpty,
                   let defaultID = AppServices.defaultOAuthClientID(for: changed.oauthProvider) {
                    changed.oauthClientID = defaultID
                }
                onChange(changed)
            }
        )
    }

    private var oauthProviderBinding: Binding<OAuth2ProviderID> {
        Binding(
            get: { setup.oauthProvider },
            set: { newProvider in
                var changed = setup
                changed.oauthProvider = newProvider
                if let defaultID = AppServices.defaultOAuthClientID(for: newProvider) {
                    changed.oauthClientID = defaultID
                } else {
                    changed.oauthClientID = ""
                }
                changed.oauthClientSecret = ""
                onChange(changed)
            }
        )
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AccountSetup, Value>) -> Binding<Value> {
        Binding(
            get: { setup[keyPath: keyPath] },
            set: { newValue in
                var changed = setup
                changed[keyPath: keyPath] = newValue
                onChange(changed)
            }
        )
    }

    @ViewBuilder
    private func server(_ keyPath: WritableKeyPath<AccountSetup, ServerEndpoint>) -> some View {
        TextField("Server", text: binding(keyPath.appending(path: \.host)), prompt: Text(verbatim: "mail.example.com"))
            .typedAsAnAddress()
        TextField("Port", value: binding(keyPath.appending(path: \.port)), format: .number.grouping(.never))
            #if !os(macOS)
            .keyboardType(.numberPad)
            #endif
        Picker("Security", selection: binding(keyPath.appending(path: \.security))) {
            Text("TLS").tag(ConnectionSecurity.tls)
            Text("STARTTLS").tag(ConnectionSecurity.startTLS)
            Text("None").tag(ConnectionSecurity.none)
        }
    }
}

private extension View {
    /// For a field that takes an address or a host name: on a touch keyboard,
    /// nothing is capitalised or corrected.
    func typedAsAnAddress() -> some View {
        #if os(macOS)
        self
        #else
        textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.emailAddress)
        #endif
    }
}
