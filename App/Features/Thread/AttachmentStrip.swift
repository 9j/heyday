import HeydayKit
import ImageIO
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#endif

/// An email's attachments, each a small card with its picture or its kind, its name
/// and its size. A click looks at one without saving it; on a Mac its menu saves it
/// to Downloads, and it can be dragged out to wherever it should go.
struct AttachmentStrip: View {
    let attachments: [Attachment]
    let onProblem: (String) -> Void

    /// The attachment being looked at, as a file written out for the purpose.
    @State private var previewed: URL?
    /// The temporary copies made so far, so each attachment is written out once.
    @State private var copies: [Attachment.ID: URL] = [:]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(attachments) { attachment in
                AttachmentChip(attachment: attachment) {
                    previewed = temporaryCopy(of: attachment)
                }
                #if os(macOS)
                .contextMenu {
                    Button("Quick Look", systemImage: "eye") { previewed = temporaryCopy(of: attachment) }
                    Button("Save to Downloads", systemImage: "arrow.down.circle") { saveToDownloads(attachment) }
                }
                .onDrag {
                    temporaryCopy(of: attachment).flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider()
                }
                #endif
            }
        }
        .quickLookPreview($previewed)
    }

    /// The attachment as a file, for a preview or a drag to read. It is temporary,
    /// and in a folder of its own so that two attachments of one name do not collide.
    private func temporaryCopy(of attachment: Attachment) -> URL? {
        if let copy = copies[attachment.id] { return copy }
        do {
            let folder = FileManager.default.temporaryDirectory.appending(path: "attachment-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: attachment.safeFilename)
            try attachment.data.write(to: file, options: .atomic)
            copies[attachment.id] = file
            return file
        } catch {
            onProblem("\(attachment.filename): \(error.localizedDescription)")
            return nil
        }
    }

    #if os(macOS)
    /// Writes the file to Downloads without overwriting anything, and shows it in Finder.
    private func saveToDownloads(_ attachment: Attachment) {
        do {
            let downloads = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let name = attachment.safeFilename
            let stem = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            var destination = downloads.appending(path: name)
            var copy = 2
            while FileManager.default.fileExists(atPath: destination.path) {
                destination = downloads.appending(path: ext.isEmpty ? "\(stem) \(copy)" : "\(stem) \(copy).\(ext)")
                copy += 1
            }
            try attachment.data.write(to: destination, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            onProblem("\(attachment.filename): \(error.localizedDescription)")
        }
    }
    #endif
}

private extension Attachment {
    /// The name as one path component: a sender can put a slash in it.
    var safeFilename: String {
        filename.replacingOccurrences(of: "/", with: "-")
    }
}

/// One attachment: a picture of it when it is a picture, a symbol for its kind
/// otherwise, then its name and size.
private struct AttachmentChip: View {
    let attachment: Attachment
    let onOpen: () -> Void

    @State private var thumbnail: CGImage?
    @State private var isUnderPointer = false

    private static let pictureSize: CGFloat = 36

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                picture
                VStack(alignment: .leading, spacing: 1) {
                    Text(attachment.filename)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(.quaternary.opacity(isUnderPointer ? 0.9 : 0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.pressable)
        .onHover { isUnderPointer = $0 }
        .motion(Motion.response, value: isUnderPointer)
        .help("Look at \(attachment.filename)")
        .task(id: attachment.id) {
            thumbnail = await Self.thumbnail(of: attachment)
        }
    }

    @ViewBuilder
    private var picture: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        if let thumbnail {
            Image(decorative: thumbnail, scale: 1)
                .resizable()
                .scaledToFill()
                .frame(width: Self.pictureSize, height: Self.pictureSize)
                .clipShape(shape)
                .overlay(shape.strokeBorder(.separator))
                .transition(.opacity)
        } else {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .frame(width: Self.pictureSize, height: Self.pictureSize)
                .background(.background, in: shape)
                .overlay(shape.strokeBorder(.separator))
                .accessibilityHidden(true)
        }
    }

    /// A symbol for the kind of file, going by what the sender said it is and
    /// failing that by its name.
    private var symbol: String {
        let type = UTType(mimeType: attachment.mimeType) ?? UTType(filenameExtension: (attachment.filename as NSString).pathExtension)
        guard let type else { return "doc" }
        let symbols: [(UTType, String)] = [
            (.image, "photo"), (.pdf, "doc.richtext"), (.audio, "waveform"), (.movie, "film"),
            (.archive, "doc.zipper"), (.spreadsheet, "tablecells"), (.presentation, "rectangle.on.rectangle"),
            (.calendarEvent, "calendar"), (.vCard, "person.crop.rectangle"), (.text, "doc.text"),
        ]
        return symbols.first { type.conforms(to: $0.0) }?.1 ?? "doc"
    }

    /// A small picture of an image attachment, decoded at the size it is shown and
    /// away from the main thread: a photo can be many megabytes.
    private static func thumbnail(of attachment: Attachment) async -> CGImage? {
        guard UTType(mimeType: attachment.mimeType)?.conforms(to: .image) == true else { return nil }
        let data = attachment.data
        // Three times the points it is drawn at, for the sharpest screens.
        let pixels = pictureSize * 3
        return await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
    }
}
