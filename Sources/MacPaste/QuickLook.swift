import Quartz

/// 系统快速预览（QLPreviewPanel）：图片右键「预览」直接查看大图（可缩放）
final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookController()
    private var url: URL?

    func show(url: URL) {
        self.url = url
        NSApp.activate(ignoringOtherApps: true)
        let panel = QLPreviewPanel.shared()!
        panel.dataSource = self
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        url! as NSURL as QLPreviewItem
    }
}
