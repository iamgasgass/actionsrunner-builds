// SPDX-License-Identifier: GPL-2.0-or-later

#if FEEDBACK_MAIL

import UIKit

/// What Send feedback reads from a live run.
extension LiveRuntime {
    /// The picture the guest's display view presents now, rendered from the
    /// view alone: not the screens over it and not a sheet, at the pixels the
    /// runtime draws (the view's drawable). It is what the render server
    /// composites for that view, so it is the frame on the glass, whichever
    /// path drew it.
    func captureGuestDisplay() -> UIImage? {
        guard let view, view.window != nil, !view.isHidden,
              view.bounds.width > 0, view.bounds.height > 0,
              view.drawableSize.width >= 1, view.drawableSize.height >= 1 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        // One image pixel for each drawable pixel.
        format.scale = view.drawableSize.width / view.bounds.width
        format.preferredRange = .standard
        var drawn = false
        let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { _ in
            drawn = view.drawHierarchy(in: view.bounds, afterScreenUpdates: false)
        }
        return drawn ? image : nil
    }

    func runningSeconds() -> Int? {
        runStartedAt.map { max(0, Int(Date().timeIntervalSince($0))) }
    }
}

#endif
