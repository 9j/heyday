import HeydayKit
import SwiftUI

/// The form an account is added with: who you are, and where your IMAP and SMTP
/// servers are. On a Mac, one button fills in Proton Mail Bridge's local settings.
struct AccountSetupView: View {
    let setup: AccountSetup
    let problem: String?
    let onChange: (AccountSetup) -> Void
    let onConnect: () -> Void

    var body: some View {
        Form {
            Section {
                TextField("Name", text: binding(\.name), prompt: Text("Jane Doe"))
                // Verbatim: left to itself, the system turns an address into a link.
                TextField("Email Address", text: binding(\.address), prompt: Text(verbatim: "you@example.com"))
                    .typedAsAnAddress()
            } header: {
                Text("Add Your Mail Account")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
                    .padding(.bottom, 8)
            }

            Section("Sign In") {
                TextField("Username", text: binding(\.username), prompt: Text("Usually your email address"))
                    .typedAsAnAddress()
                SecureField("Password", text: binding(\.password))
                    .onSubmit(onConnect)
            }

            Section("Incoming Mail (IMAP)") {
                server(\.imap)
            }

            Section {
                server(\.smtp)
                Toggle("The server keeps a copy of what I send", isOn: binding(\.serverSavesSentMail))
            } header: {
                Text("Outgoing Mail (SMTP)")
            } footer: {
                Text("The password is kept in your keychain.")
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
        .safeAreaInset(edge: .bottom) {
            HStack {
                #if os(macOS)
                Button("Use Proton Mail Bridge Settings", action: fillInBridgeSettings)
                    .help("Fills in 127.0.0.1 with ports 1143 and 1025. Copy the username and password from Bridge’s Mailbox details.")
                Spacer()
                #endif
                Button(action: onConnect) {
                    Text("Connect")
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
    }
    #endif

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
