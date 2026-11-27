import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension Color {
    /// What sits behind a window's content.
    static var windowBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemGroupedBackground)
        #endif
    }

    /// What text is written on: a card, a page, a field.
    static var textBackground: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(uiColor: .secondarySystemGroupedBackground)
        #endif
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

extension Notification.Name {
    /// Posted when the app comes to the front.
    static var appBecameActive: Notification.Name {
        #if os(macOS)
        NSApplication.didBecomeActiveNotification
        #else
        UIApplication.didBecomeActiveNotification
        #endif
    }
}

extension View {
    /// A button that reads as a link in running text.
    func linkStyled() -> some View {
        #if os(macOS)
        buttonStyle(.link)
        #else
        buttonStyle(.borderless)
        #endif
    }

    /// A second line under the window's title. Only a Mac has a place for one that
    /// leaves the title alone: on iPhone a subtitle shrinks the large title of the
    /// list it is on, so one list would look unlike the next.
    func subtitled(_ subtitle: String) -> some View {
        #if os(macOS)
        navigationSubtitle(subtitle)
        #else
        self
        #endif
    }

    /// What floats over the content under it: the system's glass where it has
    /// glass, and before that a material with an edge and a little shadow.
    @ViewBuilder
    func floatingSurface(in shape: some Shape) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.stroke(.separator, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        }
    }

    /// A choice between two or three sentences, all of them in view.
    func choiceOfSentences() -> some View {
        #if os(macOS)
        pickerStyle(.radioGroup)
        #else
        pickerStyle(.inline)
        #endif
    }

    /// Works around a macOS `NavigationSplitView` bug where a `List` row inserted
    /// at the top stays at the table view's default 24pt row height instead of its
    /// measured height, clipping the row until the list is reloaded.
    func keepsMacListRowHeights<Value: Equatable>(when value: Value) -> some View {
        #if os(macOS)
        background(MacListRowHeightRepair(trigger: value))
        #else
        self
        #endif
    }

    /// Collapses the detail column of a 3-column macOS `NavigationSplitView` so the
    /// content column fills the space beside the sidebar (used by The Feed), and
    /// restores the previous divider position without resizing the window.
    func collapsesMacDetailColumn(_ isCollapsed: Bool) -> some View {
        #if os(macOS)
        background(MacDetailColumnCollapse(isCollapsed: isCollapsed))
        #else
        self
        #endif
    }
}

#if os(macOS)
private final class SplitCollapseAnchorView: NSView {
    var onAttach: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onAttach?() }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if window != nil { onAttach?() }
    }
}

private struct MacDetailColumnCollapse: NSViewRepresentable {
    let isCollapsed: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = SplitCollapseAnchorView()
        let coordinator = context.coordinator
        view.onAttach = { [weak view] in
            MainActor.assumeIsolated {
                guard let view else { return }
                coordinator.scheduleApply(for: view)
            }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.desiredCollapsed = isCollapsed
        context.coordinator.scheduleApply(for: view)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    @MainActor
    final class Coordinator {
        var desiredCollapsed = false
        var savedDividerX: CGFloat?
        private var pendingWork: DispatchWorkItem?
        private var collapseObservation: NSKeyValueObservation?
        private weak var observedDetail: NSSplitViewItem?
        private var isApplying = false

        func tearDown() {
            pendingWork?.cancel()
            pendingWork = nil
            collapseObservation?.invalidate()
            collapseObservation = nil
            observedDetail = nil
        }

        func scheduleApply(for view: NSView) {
            pendingWork?.cancel()
            let work = DispatchWorkItem { [weak self, weak view] in
                MainActor.assumeIsolated {
                    guard let self, let view else { return }
                    self.apply(for: view)
                }
            }
            pendingWork = work
            // Defer out of SwiftUI's synchronous update pass to avoid AttributeGraph
            // cycles and ensure NavigationSplitView finishes updating column widths first.
            DispatchQueue.main.async(execute: work)
        }

        private func apply(for view: NSView) {
            guard !isApplying,
                  let splitViewController = Self.splitViewController(from: view),
                  splitViewController.splitViewItems.count == 3
            else { return }

            let content = splitViewController.splitViewItems[1]
            let detail = splitViewController.splitViewItems[2]

            ensureObserving(detail: detail, view: view)

            isApplying = true
            defer { isApplying = false }

            if desiredCollapsed {
                content.maximumThickness = NSSplitViewItem.unspecifiedDimension
                detail.canCollapse = true
                detail.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
                if !detail.isCollapsed {
                    let middleMaxX = splitViewController.splitView.arrangedSubviews[1].frame.maxX
                    if middleMaxX > 0 { savedDividerX = middleMaxX }
                    detail.isCollapsed = true
                }
                splitViewController.splitView.adjustSubviews()
            } else {
                if detail.isCollapsed {
                    let targetX = savedDividerX ?? 580
                    detail.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
                    detail.isCollapsed = false
                    detail.canCollapse = false
                    content.maximumThickness = 520
                    splitViewController.splitView.setPosition(targetX, ofDividerAt: 1)
                    DispatchQueue.main.async { [weak splitViewController] in
                        MainActor.assumeIsolated {
                            splitViewController?.splitView.setPosition(targetX, ofDividerAt: 1)
                        }
                    }
                } else {
                    detail.canCollapse = false
                    content.maximumThickness = 520
                }
            }
        }

        private func ensureObserving(detail: NSSplitViewItem, view: NSView) {
            guard observedDetail !== detail else { return }
            collapseObservation?.invalidate()
            observedDetail = detail
            collapseObservation = detail.observe(\.isCollapsed, options: [.new]) { [weak self, weak view] _, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, let view, !self.isApplying, let currentDetail = self.observedDetail else { return }
                        if self.desiredCollapsed != currentDetail.isCollapsed {
                            self.scheduleApply(for: view)
                        }
                    }
                }
            }
        }

        private static func splitViewController(from view: NSView) -> NSSplitViewController? {
            var responder: NSResponder? = view
            while let current = responder {
                if let splitViewController = current as? NSSplitViewController { return splitViewController }
                responder = current.nextResponder
            }
            return nil
        }
    }
}
/// Watches a `List`'s row order and asks its backing `NSTableView` to re-measure any
/// visible row whose cached height disagrees with its hosted cell view.
private struct MacListRowHeightRepair<Trigger: Equatable>: NSViewRepresentable {
    let trigger: Trigger

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        guard context.coordinator.lastTrigger != trigger else { return }
        context.coordinator.lastTrigger = trigger
        context.coordinator.scheduleRepair(for: view)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.cancel()
    }

    @MainActor
    final class Coordinator {
        var lastTrigger: Trigger?
        private var pendingWork: DispatchWorkItem?

        func cancel() {
            pendingWork?.cancel()
            pendingWork = nil
        }

        func scheduleRepair(for view: NSView) {
            pendingWork?.cancel()
            let work = DispatchWorkItem { [weak view] in
                MainActor.assumeIsolated {
                    guard let view else { return }
                    Self.repairMismatchedRows(near: view)
                }
            }
            pendingWork = work
            DispatchQueue.main.async(execute: work)
        }

        private static func repairMismatchedRows(near view: NSView) {
            guard let tableView = ownTableView(for: view) else { return }
            let count = tableView.numberOfRows
            guard count > 0 else { return }

            let visible = tableView.rows(in: tableView.visibleRect)
            var candidates = IndexSet(integer: 0)
            if visible.length > 0 {
                candidates.insert(integersIn: visible.location..<(visible.location + visible.length))
            }

            var stale = IndexSet()
            for row in candidates where row < count {
                let rowHeight = tableView.rect(ofRow: row).height
                if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) {
                    let measured = cell.fittingSize.height
                    let expected = measured > 0 ? measured : cell.frame.height
                    if expected > 0, abs(expected - rowHeight) > 1 {
                        stale.insert(row)
                    }
                } else if row == 0, rowHeight <= tableView.rowHeight + 1 {
                    stale.insert(row)
                }
            }
            guard !stale.isEmpty else { return }

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                tableView.noteHeightOfRows(withIndexesChanged: stale)
            }
        }

        /// Finds the `NSTableView` belonging to this `List`, stopping at `NSSplitView`
        /// so it never reaches into a sibling column.
        private static func ownTableView(for view: NSView) -> NSTableView? {
            var current: NSView? = view
            while let node = current {
                if node is NSSplitView { return nil }
                if let tableView = firstTableView(in: node) { return tableView }
                current = node.superview
            }
            return nil
        }

        private static func firstTableView(in view: NSView) -> NSTableView? {
            if let tableView = view as? NSTableView { return tableView }
            for subview in view.subviews {
                if let tableView = firstTableView(in: subview) { return tableView }
            }
            return nil
        }
    }
}
#endif
