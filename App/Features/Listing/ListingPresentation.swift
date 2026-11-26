import HeydayKit
import SwiftUI

/// The words and symbol that go with each list: its name in the sidebar and what to
/// say when it is empty.
struct ListingPresentation {
    let title: String
    let symbol: String
    var emptyTitle = "No Mail"

    init(_ listing: Listing, directory: MailboxDirectory) {
        switch listing {
        case .box(.mebox):
            title = "Mebox"
            symbol = "tray.full"
            emptyTitle = "Nothing Here Yet"
        case .box(.feed):
            title = "The Feed"
            symbol = "newspaper"
            emptyTitle = "No Newsletters"
        case .box(.paperTrail):
            title = "Paper Trail"
            symbol = "scroll"
            emptyTitle = "No Receipts"
        case .screener:
            title = "The Screener"
            symbol = "hand.thumbsup"
            emptyTitle = "Nobody Is Waiting"
        case .screenedOut:
            title = "Screened Out"
            symbol = "hand.thumbsdown"
            emptyTitle = "Nobody Screened Out"
        case .appFolder(.replyLater):
            title = "Reply Later"
            symbol = "clock"
            emptyTitle = "Nothing to Reply To"
        case .appFolder(.setAside):
            title = "Set Aside"
            symbol = "pin"
            emptyTitle = "Nothing Set Aside"
        case .mailbox(let path):
            let mailbox = directory.mailboxes.first { $0.path == path }
            switch mailbox?.role {
            case .sent: (title, symbol) = ("Sent", "paperplane")
            case .drafts: (title, symbol) = ("Drafts", "doc")
            case .archive: (title, symbol) = ("Archive", "archivebox")
            case .spam: (title, symbol) = ("Spam", "xmark.bin")
            case .trash: (title, symbol) = ("Trash", "trash")
            case .all: (title, symbol) = ("All Mail", "tray.2")
            case .inbox, nil: (title, symbol) = (mailbox?.name ?? path, "folder")
            }
        }
    }
}
