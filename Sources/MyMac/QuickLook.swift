import AppKit
import Quartz

/// Space bar preview (Quick Look) for the selected files, like Windows "Peek".
@MainActor
final class QuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLook()
    private(set) var urls: [URL] = []
    /// The tab that opened the preview; only its selection changes what's shown.
    private(set) var owner: ObjectIdentifier?

    var isOpen: Bool { QLPreviewPanel.sharedPreviewPanelExists() && (QLPreviewPanel.shared()?.isVisible ?? false) }

    func show(_ list: [URL], owner: AnyObject? = nil) {
        guard !list.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        urls = list
        self.owner = owner.map(ObjectIdentifier.init)
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        // orderFront (not makeKey) so the file list keeps the keyboard: arrows, Space and Esc still work.
        panel.orderFront(nil)
    }

    /// Follows the selection while the preview is open.
    func update(_ list: [URL], from source: AnyObject) {
        guard isOpen, owner == ObjectIdentifier(source), !list.isEmpty, list != urls, let panel = QLPreviewPanel.shared() else { return }
        urls = list
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
    }

    func close() {
        guard isOpen else { return }
        QLPreviewPanel.shared()?.orderOut(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { urls.indices.contains(index) ? urls[index] as NSURL : nil }
    }
}
