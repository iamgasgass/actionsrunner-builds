// SPDX-License-Identifier: GPL-2.0-or-later

#if FEEDBACK_MAIL && !APP_STORE

import AndariumCore
import CoreGraphics
import Foundation
import ImageIO

/// A bug report made up for the Simulator preview and the UI tests, which have no guest to make one: the
/// shape of Android's (a long log, short files, folders that hold one folder, a picture named
/// `screenshot.png`, a file that is not text, a stored archive inside) with the record Andarium appends, every
/// line invented. It is a real zip, written the way the app writes its own entries, so the viewer reads it as
/// it reads a real report. The App Store product has none of it.
nonisolated enum SendFeedbackSampleReport {
    /// The name of the log, the longest text of the report.
    static let logName = "bugreport-lineage-2026-11-17-15-00-00.txt"

    /// Writes the report to `url`.
    static func write(to url: URL) throws {
        try Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18)).write(to: url)
        let inner = url.deletingLastPathComponent().appendingPathComponent(".inner-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: inner) }
        try Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18)).write(to: inner)
        try BugReportArchive.append(
            [
                .init(name: "window_0_status_bar.txt", data: Data("StatusBar#0 frame=[0,0][1080,96] visible=true\n".utf8)),
                .init(name: "window_1_launcher.txt", data: Data("Launcher#1 frame=[0,0][1080,2340] visible=true\n".utf8)),
                .init(name: "window_2_example_app.txt", data: Data("com.example.game/.MainActivity#2 frame=[0,0][1080,2340] focused\n".utf8)),
            ], to: inner)
        try BugReportArchive.append(
            [
                .init(name: logName, data: Data(log().utf8)),
                .init(name: "main_entry.txt", data: Data("\(logName)\n".utf8)),
                .init(name: "version.txt", data: Data("3.0\n".utf8)),
                .init(name: "dumpstate_log.txt", data: Data("1 2026-11-17 15:00:00 dumpstate: begin\n2 2026-11-17 15:00:41 dumpstate: done\n".utf8)),
                .init(name: "dumpstate_board.bin", data: Data((0..<2_048).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 0x80) })),
                .init(name: "FS/data/misc/example.conf", data: Data("# an example file\nkey=value\n".utf8)),
                .init(name: "FS/data/anr/anr_2026-11-17-15-00-02.txt", data: Data("\"main\" prio=5 tid=1 Sleeping\n  at java.lang.Thread.sleep(Native Method)\n".utf8)),
                .init(name: "FS/data/tombstones/tombstone_00.txt", data: Data("*** *** *** *** ***\nBuild fingerprint: 'example/lineage/example:17/example'\npid: 4121, tid: 4121, name: example.game\n".utf8)),
                .init(name: "FS/data/tombstones/tombstone_01.txt", data: Data("*** *** *** *** ***\npid: 4388, tid: 4388, name: example.service\n".utf8)),
                .init(name: "screenshot.png", data: screenshot()),
                .init(name: "visible_windows.zip", data: (try? Data(contentsOf: inner)) ?? Data()),
                .init(name: "andarium/session-current.txt", data: Data("uml-session 7\nstate running\nend running\n".utf8)),
            ], to: url)
    }

    /// The report cut short, as one whose transfer ended too soon: the end of the zip is gone.
    static func writeDamaged(to url: URL) throws {
        try write(to: url)
        let whole = try Data(contentsOf: url)
        try whole.prefix(whole.count - 600).write(to: url)
    }

    /// A few thousand lines of a log, invented and numbered.
    private static func log() -> String {
        let tags = ["ActivityManager", "WindowManager", "SurfaceFlinger", "AudioFlinger", "PackageManager", "netd", "zygote"]
        let messages = [
            "Start proc com.example.game for top-activity {com.example.game/com.example.game.MainActivity}",
            "Relayout window Window{3a1f u0 com.example.game/com.example.game.MainActivity}",
            "setTransactionState: frame 2840 displayed",
            "Output stream underrun on usb:0",
            "Verified package com.example.game against its signature",
            "Interface wlan0 changed state to up",
            "Zygote forked a process for com.example.game",
        ]
        var lines = ["------ SYSTEM LOG (logcat -v threadtime -d) ------"]
        for index in 0..<2_400 {
            let second = 1 + index / 40
            let stamp = String(format: "11-17 15:%02d:%02d.%03d", second / 60, second % 60, (index * 137) % 1_000)
            let pid = 1_200 + (index % 7) * 31
            lines.append("\(stamp)  \(pid)  \(pid + 4) I \(tags[index % tags.count]): \(messages[index % messages.count]) [\(index)]")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A picture the size of a phone's screen, drawn: a made-up home screen as the guest would have shown.
    private static func screenshot() -> Data {
        let width = 540, height = 1_170
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return Data() }
        let space = CGColorSpaceCreateDeviceRGB()
        if let gradient = CGGradient(
            colorsSpace: space, colors: [CGColor(red: 0.16, green: 0.32, blue: 0.62, alpha: 1), CGColor(red: 0.55, green: 0.32, blue: 0.62, alpha: 1)] as CFArray,
            locations: [0, 1])
        {
            context.drawLinearGradient(
                gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: CGFloat(width), y: 0), options: [])
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
        for row in 0..<5 {
            for column in 0..<4 {
                let rect = CGRect(x: 36 + column * 124, y: 330 + row * 150, width: 84, height: 84)
                context.addPath(CGPath(roundedRect: rect, cornerWidth: 22, cornerHeight: 22, transform: nil))
                context.fillPath()
            }
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.55))
        context.addPath(CGPath(
            roundedRect: CGRect(x: 40, y: 1_010, width: 460, height: 110), cornerWidth: 34, cornerHeight: 34, transform: nil))
        context.fillPath()
        guard let image = context.makeImage() else { return Data() }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return Data() }
        return data as Data
    }
}

#endif
