// swift-tools-version: 6.0
import PackageDescription

/// HeydayKit holds everything that is not a view: the IMAP and SMTP clients, the MIME
/// parser, the rules that sort mail the way HEY does, and the state machines the
/// app's screens are driven by. The SwiftUI app target (see `project.yml`) depends
/// on it; `swift test` exercises it without a UI.
let package = Package(
    name: "HeydayKit",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "HeydayKit", targets: ["HeydayKit"]),
    ],
    targets: [
        .target(name: "HeydayKit"),
        .testTarget(name: "HeydayKitTests", dependencies: ["HeydayKit"]),
    ]
)
