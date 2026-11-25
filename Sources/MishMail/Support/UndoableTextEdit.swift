import AppKit

/// Programmatic rewrites of an editable text view that behave like typing:
/// only the changed span is replaced, through shouldChangeText and
/// didChangeText, so the text view's undo manager records one step (⌘Z
/// restores the text) and earlier undo records keep pointing into the same
/// string. A plain `string =` assignment does neither.
enum UndoableTextEdit {
    /// Replaces `textView`'s text with `newText`. False when the text view
    /// refused the change.
    @discardableResult
    static func replace(in textView: NSTextView, with newText: String,
                        actionName: String? = nil) -> Bool {
        guard let storage = textView.textStorage else { return false }
        guard let (range, replacement) = changedSpan(from: textView.string, to: newText) else {
            return true
        }
        guard textView.shouldChangeText(in: range, replacementString: replacement) else {
            return false
        }
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: replacement)
        storage.endEditing()
        textView.didChangeText()
        if let actionName { textView.undoManager?.setActionName(actionName) }
        return true
    }

    /// Common-prefix/suffix diff in UTF-16 units: the smallest range of
    /// `old` to replace, and its replacement. Nil when nothing changed.
    static func changedSpan(from old: String, to new: String)
        -> (range: NSRange, replacement: String)? {
        let o = old as NSString, n = new as NSString
        if o.length == n.length, o.isEqual(to: new) { return nil }
        var start = 0
        let minLen = min(o.length, n.length)
        while start < minLen, o.character(at: start) == n.character(at: start) {
            start += 1
        }
        var oEnd = o.length, nEnd = n.length
        while oEnd > start, nEnd > start,
              o.character(at: oEnd - 1) == n.character(at: nEnd - 1) {
            oEnd -= 1
            nEnd -= 1
        }
        return (NSRange(location: start, length: oEnd - start),
                n.substring(with: NSRange(location: start, length: nEnd - start)))
    }
}
