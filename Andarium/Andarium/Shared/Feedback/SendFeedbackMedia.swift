// SPDX-License-Identifier: GPL-2.0-or-later

#if FEEDBACK_MAIL

import AVFoundation
import CoreTransferable
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// A photo or video the system's picker returned, copied to a file of ours
/// (the picker's own copy is deleted as its handler returns). The picker needs
/// no photo-library permission: the person hands over only what they pick.
nonisolated struct SendFeedbackPickedFile: Transferable, Sendable {
    var url: URL
    var isVideo: Bool

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            try Self.copy(received.file, isVideo: true)
        }
        FileRepresentation(importedContentType: .image) { received in
            try Self.copy(received.file, isVideo: false)
        }
    }

    private static func copy(_ file: URL, isVideo: Bool) throws -> SendFeedbackPickedFile {
        let folder = SendFeedbackStaging().incoming.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(SendFeedbackFolder.safeName(file.lastPathComponent))
        try FileManager.default.copyItem(at: file, to: target)
        return SendFeedbackPickedFile(url: target, isVideo: isVideo)
    }
}

/// What the sheet shows of a picture or a video: its size in pixels, a
/// video's length and a small picture, read without decoding the whole file.
nonisolated enum SendFeedbackMedia {
    struct Inspection: Sendable {
        var pixels: SendFeedbackPixels?
        var durationSeconds: Int?
        /// A JPEG of at most `thumbnailPixels` on a side.
        var thumbnail: Data?
    }

    static let thumbnailPixels = 160

    static func inspect(_ url: URL, isVideo: Bool) async -> Inspection {
        isVideo ? await inspectVideo(url) : inspectImage(url)
    }

    private static func inspectImage(_ url: URL) -> Inspection {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return Inspection() }
        var result = Inspection()
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int {
            // Orientations 5 to 8 turn the picture on its side.
            let turned = (properties[kCGImagePropertyOrientation] as? Int).map { (5...8).contains($0) } ?? false
            result.pixels = turned ? SendFeedbackPixels(width: height, height: width)
                : SendFeedbackPixels(width: width, height: height)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
        ]
        if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            result.thumbnail = UIImage(cgImage: image).jpegData(compressionQuality: 0.8)
        }
        return result
    }

    private static func inspectVideo(_ url: URL) async -> Inspection {
        let asset = AVURLAsset(url: url)
        var result = Inspection()
        if let duration = try? await asset.load(.duration), duration.isNumeric {
            result.durationSeconds = Int(duration.seconds.rounded())
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: thumbnailPixels * 2, height: thumbnailPixels * 2)
        if let (image, _) = try? await generator.image(at: .zero) {
            result.thumbnail = UIImage(cgImage: image).jpegData(compressionQuality: 0.8)
        }
        return result
    }
}

#endif
