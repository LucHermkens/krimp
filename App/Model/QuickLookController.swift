import AppKit
import QuickLookUI

/// Drives the system Quick Look panel for the focused item. While the panel is key it gets
/// the keyboard, so arrow keys are forwarded to the list (the preview follows the selection,
/// like Finder) and space closes it.
@MainActor
final class QuickLookController: NSObject {
    weak var model: AppModel?

    private var panel: QLPreviewPanel? {
        QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared() : nil
    }

    var isOpen: Bool { panel?.isVisible == true }

    func toggle() {
        if isOpen {
            panel?.orderOut(nil)
        } else if model?.focusedURL != nil, let panel = QLPreviewPanel.shared() {
            take(panel)
            panel.makeKeyAndOrderFront(nil)
            panel.reloadData()
        }
    }

    /// Shows the newly focused item if the panel is open.
    func reload() {
        guard isOpen, let panel, panel.dataSource === self else { return }
        if model?.focusedURL == nil {
            panel.orderOut(nil)
        } else {
            panel.reloadData()
        }
    }

    /// Called from the responder chain (`AppDelegate`) and when opening the panel ourselves.
    func take(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
    }

    func release(_ panel: QLPreviewPanel) {
        if panel.dataSource === self { panel.dataSource = nil }
        if panel.delegate === self { panel.delegate = nil }
    }
}

extension QuickLookController: @preconcurrency QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        model?.focusedURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        model?.focusedURL.map { $0 as NSURL }
    }
}

extension QuickLookController: @preconcurrency QLPreviewPanelDelegate {
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown, let model else { return false }
        let extend = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 123: model.moveFocus(.left, extend: extend)
        case 124: model.moveFocus(.right, extend: extend)
        case 125: model.moveFocus(.down, extend: extend)
        case 126: model.moveFocus(.up, extend: extend)
        case 49: panel.orderOut(nil)  // space
        default: return false
        }
        return true
    }
}
