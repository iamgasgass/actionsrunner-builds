// SPDX-License-Identifier: GPL-2.0-or-later

#if FEEDBACK_MAIL

import Foundation
import UniformTypeIdentifiers

/// An Android package: a file no mail service delivers, so the sheet never
/// attaches one. The `.apk` of an app and the bundle formats that hold APKs
/// (`.apks`, `.xapk`, `.apkm`) are refused alike, by the end of the name,
/// whatever its letters' case, or by a content type that names a package.
/// Nothing is opened to find out: a bundle is told from another archive by
/// its extension alone, and an archive named otherwise is an ordinary file.
nonisolated enum SendFeedbackAndroidPackage {
    /// The extensions, without the dot.
    static let extensions = ["apk", "apks", "xapk", "apkm"]
    /// The content type a provider gives a package.
    static let mimeType = "application/vnd.android.package-archive"

    /// `name` ends in one of the extensions after a dot (a name that is only
    /// ".apk" included), or `contentType` is the package type.
    static func matches(name: String, contentType: UTType? = nil) -> Bool {
        let lowered = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if extensions.contains(where: { lowered.hasSuffix("." + $0) }) { return true }
        guard let contentType else { return false }
        return contentType.preferredMIMEType?.lowercased() == mimeType
            || (contentType.tags[.mimeType] ?? []).contains { $0.lowercased() == mimeType }
    }
}

#endif
