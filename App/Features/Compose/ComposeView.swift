import HeydayKit
import SwiftUI

/// One draft, for a new email, a reply or a forward: a window on a Mac, a sheet on
/// iPhone and iPad. Closing it discards the draft.
struct ComposeWindow: View {
    let request: ComposeRequest
    let services: AppServices

    var body: some View {
        if let workspace = services.activeWorkspace {
            ComposeView(intent: request.intent, workspace: workspace)
        } else {
            ContentUnavailableView("No Account Connected", systemImage: "envelope.badge")
        }
    }
}

private struct ComposeView: View {
    let intent: ComposeIntent
    let workspace: Workspace

    @State private var store: Store<ComposeFeature>?
    #if !os(macOS)
    @State private var isConfirmingDiscard = false
    #endif
    /// How many times sending was refused, for the device to answer each one.
    @State private var problemCount = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            switch store?.state.phase {
            case nil, .preparing:
                WaitingIndicator()
            case .preparationFailed(let error):
                ContentUnavailableView {
                    Label("Can’t Load the Original Message", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.userMessage)
                } actions: {
                    Button("Try Again") { store?.send(.opened) }
                }
            case .editing, .sending, .sent:
                if let store {
                    ComposeForm(store: store)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, maxWidth: .infinity, minHeight: 360, maxHeight: .infinity)
        #endif
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // The button stays where it is while the email goes, so nothing
                // in the bar jumps; its arrow gives way to the wait.
                Button {
                    store?.send(.sendRequested)
                } label: {
                    ZStack {
                        Label("Send", systemImage: Self.sendSymbol)
                            .opacity(isSending ? 0 : 1)
                        if isSending {
                            ProgressView()
                                .controlSize(.small)
                                .transition(.opacity)
                        }
                    }
                }
                .sendButtonStyled()
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send (⌘↩)")
                .disabled(!canSend)
                .motion(Motion.response, value: isSending)
            }
        }
        .sensoryFeedback(.success, trigger: store?.state.phase == .sent)
        .sensoryFeedback(.error, trigger: problemCount)
        .task {
            guard store == nil else { return }
            let store = workspace.makeComposer(intent)
            self.store = store
            store.send(.opened)
        }
        .onChange(of: store?.state.phase) { _, phase in
            if phase == .sent { dismiss() }
            if case .editing(_?) = phase { problemCount += 1 }
        }
        // Closing is how a draft is discarded, so ask first when there is writing to lose.
        #if os(macOS)
        .dismissalConfirmationDialog("Discard this draft?", shouldPresent: hasUnsentWriting) {
            Button("Discard Draft", role: .destructive) { dismiss() }
            Button("Keep Writing", role: .cancel) {}
        }
        #else
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    if hasUnsentWriting { isConfirmingDiscard = true } else { dismiss() }
                }
            }
        }
        .confirmationDialog("Discard this draft?", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
            Button("Discard Draft", role: .destructive) { dismiss() }
            Button("Keep Writing", role: .cancel) {}
        }
        // Swiping the sheet away would discard without asking.
        .interactiveDismissDisabled(hasUnsentWriting)
        #endif
    }

    private var canSend: Bool {
        if case .editing = store?.state.phase { true } else { false }
    }

    private var isSending: Bool {
        store?.state.phase == .sending
    }

    /// An arrow going up on iPhone and iPad, as their own Mail has it; a paper
    /// plane in a Mac's toolbar.
    private static var sendSymbol: String {
        #if os(macOS)
        "paperplane.fill"
        #else
        "arrow.up"
        #endif
    }

    private var hasUnsentWriting: Bool {
        guard let state = store?.state, state.phase != .sent else { return false }
        return !state.draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var title: String {
        if let subject = store?.state.draft.subject, !subject.isEmpty { return subject }
        return switch intent {
        case .newMessage: "New Message"
        case .reply: "Reply"
        case .forward: "Forward"
        }
    }
}

/// The address rows, the message, and under it the original a reply or forward carries.
private struct ComposeForm: View {
    let store: Store<ComposeFeature>

    @State private var showsCarbonCopies = false
    @FocusState private var focus: ComposeFeature.Field?

    private var state: ComposeFeature.State { store.state }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                row("To:") {
                    field(.to, text: state.draft.to)
                    if !showsCopyRows {
                        Button("Cc/Bcc") {
                            showsCarbonCopies = true
                            focus = .cc
                        }
                        .linkStyled()
                    }
                }
                if showsCopyRows {
                    Group {
                        row("Cc:") { field(.cc, text: state.draft.cc) }
                        row("Bcc:") { field(.bcc, text: state.draft.bcc) }
                    }
                    .transition(.opacity)
                }
                row("Subject:") { field(.subject, text: state.draft.subject) }
                row("From:") {
                    Text(state.sender.formatted)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 16)

            if case .editing(let problem?) = state.phase {
                VStack(spacing: 0) {
                    Label(problem.userMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    Divider()
                }
                .transition(.opacity)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    bodyEditor
                    if let quoted = state.draft.quotedHTML, !quoted.isEmpty {
                        // The original travels with a reply or forward; show what will be sent.
                        MessageBodyView(html: quoted)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .allowsHitTesting(false)
                    }
                }
                .padding(16)
            }
            #if !os(macOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
        }
        .motion(Motion.layout, value: showsCopyRows)
        .motion(Motion.layout, value: state.phase)
        .background(Color.textBackground)
        .disabled(state.phase == .sending)
        .task {
            // Wait a beat: the click or keystroke that opened the window is still
            // settling focus, and would otherwise take it straight back.
            try? await Task.sleep(for: .milliseconds(50))
            focus = state.draft.to.isEmpty ? .to : .body
        }
    }

    private var showsCopyRows: Bool {
        showsCarbonCopies || !state.draft.cc.isEmpty || !state.draft.bcc.isEmpty
    }

    /// Wide enough for "Subject:" in the platform's body text, which is larger on a phone.
    private static var labelWidth: CGFloat {
        #if os(macOS)
        56
        #else
        72
        #endif
    }

    private func row(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label)
                    .foregroundStyle(.secondary)
                    .frame(width: Self.labelWidth, alignment: .trailing)
                content()
            }
            .padding(.vertical, 9)
            Divider()
        }
    }

    private func field(_ field: ComposeFeature.Field, text: String) -> some View {
        TextField("", text: Binding(get: { text }, set: { store.send(.edited(field, $0)) }))
            .textFieldStyle(.plain)
            .focused($focus, equals: field)
            // Return goes on to the next thing to fill in.
            .submitLabel(.next)
            .onSubmit { focus = nextField(after: field) }
            #if !os(macOS)
            // An address is not a sentence.
            .textInputAutocapitalization(field == .subject ? .sentences : .never)
            .autocorrectionDisabled(field != .subject)
            .keyboardType(field == .subject ? .default : .emailAddress)
            #endif
    }

    /// Where Return takes the cursor from an address or subject field.
    private func nextField(after field: ComposeFeature.Field) -> ComposeFeature.Field {
        switch field {
        case .to: showsCopyRows ? .cc : .subject
        case .cc: .bcc
        case .bcc: .subject
        case .subject, .body: .body
        }
    }

    private var bodyEditor: some View {
        TextEditor(text: Binding(get: { state.draft.body }, set: { store.send(.edited(.body, $0)) }))
            .font(.body)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .focused($focus, equals: .body)
            .frame(minHeight: state.draft.quotedHTML == nil ? 280 : 120)
            // TextEditor insets its text by 5pt; pull it back in line with the rows above.
            .padding(.leading, -5)
    }
}

private extension View {
    /// On iPhone and iPad the send button is a filled circle in the bar, which is
    /// how the system marks the one action a sheet is for.
    @ViewBuilder
    func sendButtonStyled() -> some View {
        #if os(macOS)
        self
        #else
        labelStyle(.iconOnly)
            .fontWeight(.semibold)
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
        #endif
    }
}
