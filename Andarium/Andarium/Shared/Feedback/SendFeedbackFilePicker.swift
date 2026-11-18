// SPDX-License-Identifier: GPL-2.0-or-later

#if FEEDBACK_MAIL

import ObjectiveC
import UIKit
import UniformTypeIdentifiers

/// The system's document picker over whatever is on screen, which opens the
/// files the person chooses where they are kept: no copy is made first, and
/// the URLs it returns carry an access the receiver starts and stops
/// (`SendFeedbackScopes`). Not SwiftUI's `fileImporter`: this sheet owns the
/// presentation and the delegate.
@MainActor
enum SendFeedbackFilePicker {
    /// Shows the picker and reports once what the person chose; not at all
    /// when they cancel. Returns false when there is no window to present from.
    static func present(picked: @escaping @MainActor ([URL]) -> Void) -> Bool {
        guard let top = SendFeedbackComposer.topViewController() else { return false }
        let picker = makePicker()
        let delegate = Delegate(picked: picked)
        picker.delegate = delegate
        // The picker holds its delegate weakly.
        objc_setAssociatedObject(picker, &Delegate.key, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        top.present(picker, animated: true)
        return true
    }

    /// The picker: any item, several at once, opened in place (`asCopy: false`).
    static func makePicker() -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false)
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        return picker
    }

    private final class Delegate: NSObject, UIDocumentPickerDelegate {
        nonisolated(unsafe) static var key = 0
        let picked: @MainActor ([URL]) -> Void

        init(picked: @escaping @MainActor ([URL]) -> Void) {
            self.picked = picked
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            picked(urls)
        }
    }
}

#endif
