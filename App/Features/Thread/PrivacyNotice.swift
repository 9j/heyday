import HeydayKit
import SwiftUI

/// What was done about an email's tracking, as a row of counts: pixels blocked,
/// links left tracked, links cleaned, images held back. The words behind each count
/// are a click away, with the way to see the email as it was sent after all. Shown
/// over the body only when there is something to count.
struct PrivacyNotice: View {
    let report: PrivacyReport
    /// Remote images waiting to be asked for.
    let heldBackImages: Int
    let onShowAllImages: () -> Void
    let onLoadAsSent: () -> Void

    @State private var showsDetails = false

    var body: some View {
        if !report.isEmpty || heldBackImages > 0 {
            HStack(spacing: 14) {
                Button {
                    showsDetails = true
                } label: {
                    HStack(spacing: 14) {
                        if !report.pixels.isEmpty {
                            count(report.pixels.count, symbol: "eye.slash.fill", meaning: pixelsLine)
                        }
                        if !report.trackedLinks.isEmpty {
                            count(report.trackedLinks.count, symbol: "link", meaning: trackedLinksLine)
                        }
                        if report.cleanedLinks > 0 {
                            count(report.cleanedLinks, symbol: "scissors", meaning: cleanedLinksLine)
                        }
                        if heldBackImages > 0 {
                            count(heldBackImages, symbol: "photo", meaning: heldImagesLine)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("What was blocked in this email")
                // Below the row: over an email's first lines there is room, above it often none.
                .popover(isPresented: $showsDetails, arrowEdge: .top) {
                    details
                        .presentationCompactAdaptation(.popover)
                }

                Spacer(minLength: 8)

                if heldBackImages > 0 {
                    Button(action: onShowAllImages) {
                        Label("Load Images", systemImage: "photo.badge.arrow.down")
                            .labelStyle(.iconOnly)
                    }
                    .controlSize(.small)
                    .help(heldBackImages == 1 ? "Load the image" : "Load the \(heldBackImages) images")
                }
            }
            .messageNotice()
        }
    }

    /// One count beside its symbol. The sentence it stands for is what a screen
    /// reader says, and what the popover spells out.
    private func count(_ number: Int, symbol: String, meaning: String) -> some View {
        Label(String(number), systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .monospacedDigit()
            .accessibilityLabel(meaning)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if !report.pixels.isEmpty {
                    Label(pixelsLine, systemImage: "eye.slash.fill")
                }
                if !report.trackedLinks.isEmpty {
                    Label(trackedLinksLine, systemImage: "link")
                }
                if report.cleanedLinks > 0 {
                    Label(cleanedLinksLine, systemImage: "scissors")
                }
                if heldBackImages > 0 {
                    Label(heldImagesLine, systemImage: "photo")
                }
            }
            // Each line wraps to the popover's width and takes the height it needs.
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            Button("Load as Sent…") {
                showsDetails = false
                onLoadAsSent()
            }
        }
        .font(.subheadline)
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }

    private var pixelsLine: String {
        "Blocked \(count(report.pixels.count, "tracking pixel")) from \(names(of: report.pixels))."
    }

    private var trackedLinksLine: String {
        let links = report.trackedLinks.count
        return "\(count(links, "link")) \(links == 1 ? "goes" : "go") through \(names(of: report.trackedLinks)) click tracking."
    }

    private var cleanedLinksLine: String {
        "Took the tracking off \(count(report.cleanedLinks, "link"))."
    }

    private var heldImagesLine: String {
        "\(count(heldBackImages, "image")) not loaded: \(heldBackImages == 1 ? "its address" : "their addresses") could identify you."
    }

    /// Whose trackers they are, each named once, in the order found.
    private func names(of trackers: [MailTracker]) -> String {
        var seen = Set<String>()
        return trackers.map(\.name).filter { seen.insert($0).inserted }.formatted(.list(type: .and))
    }

    private func count(_ number: Int, _ noun: String) -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
    }
}

/// Says that an email is on screen as it was sent, with nothing blocked, and offers
/// the way back.
struct AsSentNotice: View {
    let onProtect: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label("As Sent", systemImage: "eye")
                .help("Nothing in this email is blocked. The sender can tell that you opened it.")
            Spacer(minLength: 8)
            Button("Protect Again", action: onProtect)
                .controlSize(.small)
        }
        .messageNotice()
    }
}
