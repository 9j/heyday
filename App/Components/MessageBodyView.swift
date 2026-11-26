import HeydayKit
import os
import SwiftUI
import WebKit

/// Renders one email's HTML body.
///
/// The email is someone else's HTML, so it is treated as hostile. Its scripts never
/// run, it cannot navigate the view, and its Content-Security-Policy lets nothing
/// through from the network at all: the only pictures it can show are ones carried
/// in the page itself. A remote image appears as a placeholder, and is put in its
/// place only after the app has fetched it.
///
/// The page is also where a translation is shown, paragraph by paragraph, and the
/// only place that knows what the email's paragraphs are: asked for a translation,
/// it reports them, and the translations come back to be put under or in place of
/// each.
///
/// The view is as tall as its content and leaves scrolling to the thread around it.
/// Until the page has said how tall that is, grey lines stand in for the text; the
/// email then fades in over them, and later changes of height (an image arriving, a
/// translation going in) are eased.
struct MessageBodyView: View {
    /// The email's HTML. Under `.protected` it is HTML whose remote images are
    /// placeholders, as `ProtectedBody.displayHTML` is; under `.asSent`, the
    /// email as it arrived.
    let html: String
    var policy: MessageDocument.Policy = .protected
    /// The email's held-back images, by the index their placeholders carry.
    var blocked: [HeldImage] = []
    /// How fetching the images asked for so far is going.
    var images: [Int: ImageLoad] = [:]
    /// How far the email's translation is, if one was asked for.
    var translation: MessageTranslation?
    /// Whether a translation takes its paragraph's place, rather than following it.
    var translationReplacesOriginal = false
    var onShowImage: (Int) -> Void = { _ in }
    /// Receives a link the reader followed. Nothing is opened unless this opens it.
    var onOpenLink: (URL) -> Void = { _ in }
    /// Receives the email's paragraphs when a translation waits for them.
    var onParagraphs: ([String]) -> Void = { _ in }

    /// The page's height, once it has reported one.
    @State private var contentHeight: CGFloat?

    /// Room for the lines that stand in for an email not yet laid out.
    private static let waitingHeight: CGFloat = 76

    var body: some View {
        MessageWebView(
            html: html,
            policy: policy,
            blocked: blocked,
            images: images,
            translation: translation,
            translationReplacesOriginal: translationReplacesOriginal,
            onShowImage: onShowImage,
            onOpenLink: onOpenLink,
            onParagraphs: onParagraphs,
            contentHeight: $contentHeight
        )
        .frame(height: contentHeight ?? Self.waitingHeight)
        .opacity(contentHeight == nil ? 0 : 1)
        .overlay(alignment: .topLeading) {
            if contentHeight == nil {
                MessageBodyPlaceholder()
                    .transition(.opacity)
            }
        }
        .motion(Motion.layout, value: contentHeight)
    }
}

/// A few grey lines where an email's text will be.
struct MessageBodyPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PlaceholderBar()
            PlaceholderBar()
            PlaceholderBar(width: 320)
            PlaceholderBar(width: 180)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shimmering()
        .accessibilityElement()
        .accessibilityLabel("Loading")
    }
}

#if os(macOS)
private typealias PlatformViewRepresentable = NSViewRepresentable
#else
private typealias PlatformViewRepresentable = UIViewRepresentable
#endif

private struct MessageWebView: PlatformViewRepresentable {
    let html: String
    let policy: MessageDocument.Policy
    let blocked: [HeldImage]
    let images: [Int: ImageLoad]
    let translation: MessageTranslation?
    let translationReplacesOriginal: Bool
    let onShowImage: (Int) -> Void
    let onOpenLink: (URL) -> Void
    let onParagraphs: ([String]) -> Void
    @Binding var contentHeight: CGFloat?

    func makeCoordinator() -> Coordinator {
        Coordinator(contentHeight: $contentHeight)
    }

    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateNSView(_ webView: WKWebView, context: Context) { update(webView, context: context) }
    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) { dismantle(webView) }
    #else
    func makeUIView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateUIView(_ webView: WKWebView, context: Context) { update(webView, context: context) }
    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) { dismantle(webView) }
    #endif

    private func makeWebView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        for message in Coordinator.Message.allCases {
            configuration.userContentController.add(context.coordinator, name: message.rawValue)
        }
        for script in [Coordinator.pageScript, MessageTranslationScript.source] {
            configuration.userContentController.addUserScript(
                WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            )
        }

        // The view is as tall as the email, and the thread around it does the scrolling.
        #if os(macOS)
        let webView = PassthroughScrollWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        #else
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        #endif
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        return webView
    }

    private func update(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onShowImage = onShowImage
        coordinator.onOpenLink = onOpenLink
        coordinator.onParagraphs = onParagraphs
        coordinator.blocked = blocked
        coordinator.images = images
        coordinator.translation = translation
        coordinator.translationReplacesOriginal = translationReplacesOriginal
        if coordinator.loadedHTML != html || coordinator.loadedPolicy != policy {
            coordinator.load(html, policy: policy)
        } else {
            coordinator.showImageProgress()
            coordinator.showTranslation()
        }
    }

    private static func dismantle(_ webView: WKWebView) {
        for message in Coordinator.Message.allCases {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: message.rawValue)
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        /// What the page script tells the app.
        enum Message: String, CaseIterable {
            case contentHeight
            case showImage
        }

        /// The app's own script. The page's scripts are off; this one still runs.
        ///
        /// It shrinks an email laid out wider than the view until it fits, as mail
        /// apps do with a newsletter on a phone; reports the content's height now
        /// and whenever its layout changes, which covers images arriving after the
        /// first paint; passes on a click on an image placeholder, taking it away
        /// from any link the image sits in; and gives the app the two things it does
        /// to a placeholder.
        ///
        /// The height is the root element's own box, which follows the content down
        /// as well as up. Its scroll height never reads less than the view, so it
        /// is used only for what overflows that box.
        static let pageScript = """
        (() => {
          const tell = (name, body) => window.webkit.messageHandlers[name].postMessage(body);
          const fit = () => {
            document.body.style.zoom = '';
            const wide = document.documentElement.scrollWidth;
            const room = document.documentElement.clientWidth;
            if (room > 0 && wide > room + 1) document.body.style.zoom = room / wide;
          };
          const report = () => {
            fit();
            const root = document.documentElement;
            const overflowing = root.scrollHeight > root.clientHeight ? root.scrollHeight : 0;
            tell('\(Message.contentHeight.rawValue)', Math.ceil(Math.max(root.getBoundingClientRect().height, overflowing)));
          };
          new ResizeObserver(report).observe(document.documentElement);
          report();

          const placeholder = (index) => document.querySelector(`[data-heyday-image="${index}"]`);
          document.addEventListener('click', (event) => {
            const target = event.target.closest('[data-heyday-image]');
            if (!target) return;
            event.preventDefault();
            event.stopPropagation();
            tell('\(Message.showImage.rawValue)', Number(target.dataset.heydayImage));
          }, true);

          window.heydaySetImageLabel = (index, text) => {
            const label = placeholder(index)?.querySelector('.heyday-image-label');
            if (label) label.textContent = text;
          };
          window.heydayPutImage = (index, html) => {
            const element = placeholder(index);
            if (element) element.outerHTML = html;
          };
        })();
        """

        weak var webView: WKWebView?
        var loadedHTML: String?
        var loadedPolicy: MessageDocument.Policy?
        var blocked: [HeldImage] = []
        var images: [Int: ImageLoad] = [:]
        var translation: MessageTranslation?
        var translationReplacesOriginal = false
        var onShowImage: (Int) -> Void = { _ in }
        var onOpenLink: (URL) -> Void = { _ in }
        var onParagraphs: ([String]) -> Void = { _ in }

        /// Whether the page is ready to have its placeholders changed.
        private var isLoaded = false
        /// What each placeholder was last told, so it is told only of changes.
        private var shown: [Int: ImageLoad] = [:]
        /// Whether the page has been asked for its paragraphs and has yet to answer.
        private var isReadingParagraphs = false
        /// The translations the page has been given, so it is given only new ones.
        private var givenTranslations: [Int: String] = [:]
        /// How the page shows translations now. Nil while it shows the email as written.
        private var shownReplacingOriginal: Bool?
        private let contentHeight: Binding<CGFloat?>

        init(contentHeight: Binding<CGFloat?>) {
            self.contentHeight = contentHeight
        }

        func load(_ html: String, policy: MessageDocument.Policy) {
            loadedHTML = html
            loadedPolicy = policy
            isLoaded = false
            shown = [:]
            isReadingParagraphs = false
            givenTranslations = [:]
            shownReplacingOriginal = nil
            webView?.loadHTMLString(MessageDocument.wrap(html, policy: policy), baseURL: nil)
        }

        /// Brings the page up to date with the translation: reports its paragraphs
        /// when they are waited for, shows what has arrived, or shows the email as
        /// written.
        func showTranslation() {
            guard isLoaded, let webView else { return }
            guard let translation, translation.isShown else {
                if shownReplacingOriginal != nil {
                    shownReplacingOriginal = nil
                    run("heydayShowOriginal()", [:], in: webView)
                }
                return
            }
            if translation.phase == .reading {
                guard !isReadingParagraphs else { return }
                if !givenTranslations.isEmpty {
                    // Asked for afresh, in another language say: what the page
                    // holds belongs to the translation before.
                    givenTranslations = [:]
                    shownReplacingOriginal = nil
                    run("heydayForgetTranslations()", [:], in: webView)
                }
                isReadingParagraphs = true
                webView.callAsyncJavaScript("return heydayReadParagraphs()", arguments: [:], in: nil, in: .page) { [weak self] result in
                    guard let self, self.isReadingParagraphs else { return }
                    self.isReadingParagraphs = false
                    // A page that cannot be read has nothing to translate.
                    self.onParagraphs((try? result.get()) as? [String] ?? [])
                }
                return
            }
            let fresh = translation.translations.filter { givenTranslations[$0.key] != $0.value }
            guard !fresh.isEmpty || shownReplacingOriginal != translationReplacesOriginal else { return }
            givenTranslations.merge(fresh) { _, new in new }
            shownReplacingOriginal = translationReplacesOriginal
            run(
                "heydayShowTranslations(translations, replacing)",
                // JavaScript object keys are strings.
                ["translations": Dictionary(uniqueKeysWithValues: fresh.map { (String($0.key), $0.value) }), "replacing": translationReplacesOriginal],
                in: webView
            )
        }

        /// Brings the page's placeholders up to date with the fetches.
        func showImageProgress() {
            guard isLoaded, let webView else { return }
            for (index, load) in images where shown[index] != load {
                shown[index] = load
                switch load {
                case .loading:
                    run("heydaySetImageLabel(index, text)", ["index": index, "text": "Loading…"], in: webView)
                case .failed:
                    run("heydaySetImageLabel(index, text)", ["index": index, "text": "Couldn’t load. Click to try again."], in: webView)
                case .loaded(let image):
                    guard blocked.indices.contains(index) else { continue }
                    run("heydayPutImage(index, html)", ["index": index, "html": blocked[index].html(showing: image)], in: webView)
                }
            }
        }

        private func run(_ script: String, _ arguments: [String: Any], in webView: WKWebView) {
            // The arguments travel as values, never as script text.
            webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { result in
                // A page script that fails does so out of sight; say so where it can be found.
                if case .failure(let error) = result {
                    Self.log.error("\(script, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                }
            }
        }

        private static let log = Logger(subsystem: "app.heyday.mac", category: "page")

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            showImageProgress()
            showTranslation()
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            switch Message(rawValue: message.name) {
            case .contentHeight:
                // Nothing at all is a height too: an email with no text has none,
                // and must not be left looking as if it were still on its way.
                guard let height = message.body as? Double, height >= 0 else { return }
                if abs((contentHeight.wrappedValue ?? 0) - height) > 0.5 {
                    contentHeight.wrappedValue = height
                }
            case .showImage:
                if let index = message.body as? Int { onShowImage(index) }
            case nil:
                break
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            // The one navigation the view makes is loading the email, which arrives
            // as `about:blank`. Anything else is the email trying to go somewhere: a
            // link the reader clicked is handed over, and the rest (a form, a
            // refresh) goes nowhere.
            if navigationAction.request.url?.scheme == "about" { return .allow }
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url, ["http", "https", "mailto"].contains(url.scheme?.lowercased()) {
                onOpenLink(url)
            }
            return .cancel
        }
    }
}

#if os(macOS)
/// A web view that never scrolls on its own, so wheel events reach the enclosing
/// SwiftUI scroll view instead of stopping at the email.
final class PassthroughScrollWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}
#endif

/// The HTML shell an email body is placed in.
enum MessageDocument {
    /// What the page may fetch for itself.
    enum Policy: Equatable {
        /// Nothing. Pictures and styles must be in the page itself; the app
        /// fetches the remote images and puts them in.
        case protected
        /// The email's own pictures, style sheets, fonts and media, straight from
        /// where the sender put them: the email as it was sent, with its tracking.
        /// Scripts, frames and forms stay off, as in every mail program, and only
        /// encrypted addresses are fetched.
        case asSent

        fileprivate var contentSecurityPolicy: String {
            switch self {
            case .protected:
                "default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:; form-action 'none'; base-uri 'none'"
            case .asSent:
                "default-src 'none'; img-src data: https:; style-src 'unsafe-inline' https:; font-src data: https:; media-src https:; form-action 'none'; base-uri 'none'"
            }
        }
    }

    static func wrap(_ body: String, policy: Policy) -> String {
        // An email with no colours of its own takes the app's, light or dark.
        let rootClass = MailBodyColours.areSet(in: body) ? "" : "heyday-adaptive"
        return """
        <!doctype html>
        <html class="\(rootClass)">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="\(policy.contentSecurityPolicy)">
        <style>\(stylesheet)</style>
        </head>
        <body>\(body)</body>
        </html>
        """
    }

    /// Email is written for a white page, so one that sets any colour of its own
    /// gets one in both colour schemes: plenty of it sets dark text and no
    /// background. An email that sets none is marked `heyday-adaptive` and is drawn
    /// straight onto whatever it sits in, in that surface's colours.
    private static let stylesheet = """
    html {
      background: #fff; color: #1d1d1f; overflow: hidden;
      /* A phone enlarges the text of wide columns by itself, which leaves an email
         shrunk to fit with giant paragraphs under small headings. */
      -webkit-text-size-adjust: 100%; text-size-adjust: 100%;
    }
    /* As tall as its content, whatever the email asks for: the view takes its
       height from the page, so a page as tall as the view could never get shorter. */
    html, body { height: auto !important; min-height: 0 !important; }
    body {
      margin: 0;
      font: 14px/1.45 -apple-system, BlinkMacSystemFont, sans-serif;
      overflow-wrap: break-word;
    }
    a { color: #0a64d6; }
    img { max-width: 100%; height: auto; }
    table { max-width: 100%; }
    pre { white-space: pre-wrap; font: 0.9em/1.4 ui-monospace, Menlo, monospace; }
    blockquote {
      margin: 0.75em 0;
      padding-left: 1em;
      border-left: 0.25em solid rgba(0, 0, 0, 0.15);
      color: rgba(0, 0, 0, 0.6);
    }
    .heyday-image {
      display: inline-flex; align-items: center; justify-content: center;
      box-sizing: border-box; max-width: 100%; min-width: 16px; min-height: 24px;
      vertical-align: middle; overflow: hidden; cursor: pointer;
      border: 1px dashed rgba(0, 0, 0, 0.25); border-radius: 6px;
      background: rgba(0, 0, 0, 0.04); color: rgba(0, 0, 0, 0.6);
      font: 12px/1.3 -apple-system, BlinkMacSystemFont, sans-serif; text-decoration: none;
    }
    .heyday-image:hover { background: rgba(0, 0, 0, 0.08); color: rgba(0, 0, 0, 0.85); }
    .heyday-image-label { padding: 0 10px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .heyday-translation { display: none; }
    [data-heyday-translation] .heyday-translation.heyday-shown { display: inline; }
    [data-heyday-translation="beside"] .heyday-translation.heyday-block.heyday-shown { display: block; margin-top: 0.3em; }
    [data-heyday-translation="beside"] .heyday-translation.heyday-inline.heyday-shown { margin-left: 0.5em; }
    [data-heyday-hidden] { display: none !important; }
    html.heyday-adaptive { background: transparent; }
    @media (prefers-color-scheme: dark) {
      html.heyday-adaptive { color: #f2f2f7; color-scheme: dark; }
      html.heyday-adaptive a { color: #6ab0ff; }
      html.heyday-adaptive blockquote { border-left-color: rgba(255, 255, 255, 0.25); color: rgba(255, 255, 255, 0.6); }
      html.heyday-adaptive .heyday-image {
        border-color: rgba(255, 255, 255, 0.3); background: rgba(255, 255, 255, 0.06); color: rgba(255, 255, 255, 0.65);
      }
      html.heyday-adaptive .heyday-image:hover { background: rgba(255, 255, 255, 0.12); color: rgba(255, 255, 255, 0.9); }
      /* A white page on a dark card shows its edges, so its words keep off them. */
      html:not(.heyday-adaptive) body { padding: 12px; }
    }
    a[data-heyday-tracker]::after {
      content: "tracked"; margin-left: 0.35em; padding: 0 0.4em; border-radius: 0.8em;
      background: #fde68a; color: #7c4a03; font: 600 0.72em/1.5 -apple-system, sans-serif;
      text-decoration: none; display: inline-block; vertical-align: 0.1em;
    }
    """
}
