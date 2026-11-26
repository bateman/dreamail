import AppKit

/// Whether a sheet, alert or confirmation dialog owns the keyboard: the key
/// monitor of the main window then lets every key through (Escape included)
/// instead of running the mailbox shortcuts behind it.
@MainActor
enum DialogKeyOwnership {
    /// `window` is the event's window: the sheet itself (`sheetParent`), the
    /// window holding one (`attachedSheet`), or a popover opened from a
    /// sheet (its `parent` chain leads to the sheet).
    static func owns(_ window: NSWindow?) -> Bool {
        var current = window
        while let w = current {
            if w.attachedSheet != nil || w.sheetParent != nil { return true }
            current = w.parent
        }
        return false
    }
}
