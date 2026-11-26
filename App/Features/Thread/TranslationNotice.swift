import HeydayKit
import SwiftUI

/// How an email's translation is going: a count while it is made, then the language
/// and who translated, with the way back to the original. The language is a menu:
/// choosing another translates the email into it there and then. Says nothing while
/// the original is on screen.
struct TranslationNotice: View {
    let translation: MessageTranslation
    /// Asks for the translation again, after a failure.
    let onTranslate: () -> Void
    let onShowOriginal: () -> Void
    /// Receives the code of the language chosen in place of the one shown.
    let onChooseLanguage: (String) -> Void

    @Environment(\.showSettings) private var showSettings

    var body: some View {
        switch translation.phase {
        case .failed(let error):
            HStack(spacing: 8) {
                Label(error.userMessage, systemImage: "exclamationmark.triangle")
                Spacer(minLength: 8)
                Group {
                    if error.kind == .notSetUp {
                        Button("Settings…") { showSettings() }
                    }
                    Button("Try Again", action: onTranslate)
                }
                .controlSize(.small)
            }
            .messageNotice()

        case .reading, .translating:
            if translation.isShown {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    if !translation.paragraphs.isEmpty {
                        Text("\(translation.translations.count)/\(translation.paragraphs.count)")
                            .monospacedDigit()
                            .contentTransition(.numericText(value: Double(translation.translations.count)))
                            .motion(Motion.response, value: translation.translations.count)
                            .accessibilityLabel("\(translation.translations.count) of \(translation.paragraphs.count) paragraphs translated")
                    }
                    Spacer(minLength: 8)
                }
                .messageNotice()
            }

        case .finished:
            if translation.paragraphs.isEmpty {
                Label("Nothing to Translate", systemImage: "translate")
                    .messageNotice()
            } else if translation.readsAsWritten {
                // Nothing changed on screen, so say why, and offer another language.
                HStack(spacing: 6) {
                    Label("Already in", systemImage: "translate")
                    languageMenu
                    Spacer(minLength: 8)
                }
                .messageNotice()
            } else if translation.isShown {
                // Who translated is named where there is room; on a narrow screen
                // the language and the way back come first.
                ViewThatFits(in: .horizontal) {
                    shownRow(naming: translation.credit?.service)
                    shownRow(naming: nil)
                }
                .messageNotice()
            }
        }
    }

    private func shownRow(naming service: String?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "translate")
                .accessibilityHidden(true)
            languageMenu
            if let service {
                Text(service)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
            Spacer(minLength: 8)
            Button("Show Original", action: onShowOriginal)
                .controlSize(.small)
                .fixedSize()
        }
    }

    /// The language the email was translated into, and every other one to choose from.
    @ViewBuilder
    private var languageMenu: some View {
        if let language = translation.credit?.language {
            Picker("Translate Into", selection: Binding(
                get: { language.code },
                set: { code in
                    if code != language.code { onChooseLanguage(code) }
                }
            )) {
                ForEach(TranslationLanguages.all) { choice in
                    Text(choice.nativeName).tag(choice.code)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
        }
    }
}
