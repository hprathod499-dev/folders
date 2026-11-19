import AppKit
import SwiftUI

/// Dragging files out of the list. SwiftUI's own drag only carries one file, so this starts an
/// AppKit drag with every selected file (like Explorer and Finder): drag one of three selected
/// files and all three go.
@MainActor
final class FileDragger: NSObject, NSDraggingSource {
    static let shared = FileDragger()

    private struct Target {
        var frame: CGRect
        let url: URL
        weak var browser: FileBrowser?
    }

    private var targets: [UUID: Target] = [:]
    private var monitor: Any?
    private var pending: (url: URL, browser: FileBrowser, start: NSPoint, window: NSWindow)?

    func set(_ id: UUID, frame: CGRect, url: URL, browser: FileBrowser) {
        targets[id] = Target(frame: frame, url: url, browser: browser)
        install()
    }

    func updateFrame(_ id: UUID, _ frame: CGRect) { targets[id]?.frame = frame }
    func remove(_ id: UUID) { targets[id] = nil }

    /// The files a drag starting on `url` should carry: the whole selection if it's part of it.
    static func filesToDrag(startingAt url: URL, in browser: FileBrowser) -> [URL] {
        guard browser.selection.contains(url), browser.selection.count > 1 else { return [url] }
        let ordered = browser.orderedURLs.filter(browser.selection.contains)
        return ordered.isEmpty ? Array(browser.selection) : ordered
    }

    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { event in
            MainActor.assumeIsolated { FileDragger.shared.handle(event) }
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDown:
            pending = nil
            guard !event.modifierFlags.contains(.control), let window = event.window, !(window is NSPanel),
                  !(window.firstResponder is NSTextView), let view = window.contentView else { return event }
            var p = view.convert(event.locationInWindow, from: nil)
            if !view.isFlipped { p.y = view.bounds.height - p.y }
            if let hit = targets.values.filter({ $0.frame.contains(p) && $0.browser != nil })
                .min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
               let browser = hit.browser {
                pending = (hit.url, browser, event.locationInWindow, window)
            }
            return event
        case .leftMouseDragged:
            guard let start = pending, event.window === start.window else { return event }
            let dx = event.locationInWindow.x - start.start.x, dy = event.locationInWindow.y - start.start.y
            guard dx * dx + dy * dy > 25 else { return event }
            pending = nil
            let urls = Self.filesToDrag(startingAt: start.url, in: start.browser)
            if !start.browser.selection.contains(start.url) { start.browser.selection = [start.url] }
            beginDrag(urls, event: event, window: start.window)
            return nil
        default:
            pending = nil
            return event
        }
    }

    private func beginDrag(_ urls: [URL], event: NSEvent, window: NSWindow) {
        guard let view = window.contentView, !urls.isEmpty else { return }
        let at = view.convert(event.locationInWindow, from: nil)
        let items: [NSDraggingItem] = urls.prefix(50).enumerated().map { index, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 48, height: 48)
            // A small stack: each extra file a little offset, like a pile of papers.
            let offset = CGFloat(min(index, 4)) * 4
            item.setDraggingFrame(NSRect(x: at.x - 24 + offset, y: at.y - 24 - offset, width: 48, height: 48),
                                  contents: icon)
            return item
        }
        let session = view.beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
    }

    // MARK: NSDraggingSource

    nonisolated func draggingSession(_ session: NSDraggingSession,
                                     sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.move, .copy, .generic] : [.copy, .move, .link, .generic]
    }
}

/// Makes an item draggable (with the rest of the selection).
struct FileDragSource: ViewModifier {
    let url: URL
    @EnvironmentObject private var browser: FileBrowser
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { geo in
                let frame = WinContextMenuModifier.visibleFrame(geo)
                Color.clear
                    .onAppear { FileDragger.shared.set(id, frame: frame, url: url, browser: browser) }
                    .onChange(of: frame) { _, new in FileDragger.shared.updateFrame(id, new) }
                    .onChange(of: url) { _, new in FileDragger.shared.set(id, frame: frame, url: new, browser: browser) }
                    .onDisappear { FileDragger.shared.remove(id) }
            }
        )
    }
}
