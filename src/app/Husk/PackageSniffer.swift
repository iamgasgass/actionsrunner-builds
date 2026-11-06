// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// What a file handed to Husk is, by its name when that says, and by what is in it when it does not.
///
/// The name alone was the whole test, so an APK whose name had been bent on the way -- "GassPlayer-release.apk_13" from a chat
/// app, "game.apk (1)" or "game (2).apk" from a second download, "game.apk.zip" from a browser, "game.apk.download" from a
/// download cut short and resumed -- was dropped without a word by Open in Husk, the share sheet, the file picker and the Husk
/// folder alike. Now a name that is an APK's with something stuck on is taken as one, and a file with no telling name is opened:
/// a zip with AndroidManifest.xml at its top is an APK, a zip of APKs is a bundle (.xapk, .apkm, .apks). Only the zip's end
/// record and central directory are read (at most a few hundred KB, whatever the file's size).
enum PackageSniffer {
    enum Kind: Equatable {
        case apk
        case bundle                 // a zip of an app's APKs: .xapk (APKPure), .apkm (APKMirror), .apks (bundletool)
        case obb                    // an expansion file
    }

    /// The kinds by extension, as Husk always took them.
    private static let byExtension: [String: Kind] = ["apk": .apk, "xapk": .bundle, "apkm": .bundle, "apks": .bundle, "obb": .obb]

    /// "name.apk_13", "name.apk (1)", "name.apk-2", "name.apk.zip", "name.apk.download", "name.APK.crdownload": the package
    /// extension, then what a chat app, a browser or a second download added. Group 1 is the name up to and with the extension.
    private static let bentName = try! NSRegularExpression(
        pattern: #"^(.+\.(?:apk|xapk|apkm|apks|obb))(?:[ _\-~.]*\(?\d{1,4}\)?|\.(?:zip|download|crdownload|part|tmp|bin|file|octet-stream))+$"#,
        options: [.caseInsensitive])

    /// What the file is, or nil when it is none of these (folders are nil: a PS4 game folder is not a package).
    static func kind(of url: URL) -> Kind? {
        if let k = byExtension[url.pathExtension.lowercased()] { return k }
        if let k = kindFromBentName(url.lastPathComponent) { return k }
        return sniff(url)
    }

    /// By name only (never opens the file): for listings of many files, such as the Husk folder.
    static func kindByName(_ name: String) -> Kind? {
        if let k = byExtension[(name as NSString).pathExtension.lowercased()] { return k }
        return kindFromBentName(name)
    }

    /// The name Husk keeps it under: the package's own extension where it was bent ("x.apk_13" -> "x.apk"), and one added
    /// where there was none at all ("download" -> "download.apk").
    static func canonicalName(_ name: String, kind: Kind) -> String {
        if let k = byExtension[(name as NSString).pathExtension.lowercased()], k == kind { return name }
        let range = NSRange(name.startIndex..., in: name)
        if let m = bentName.firstMatch(in: name, range: range), let r = Range(m.range(at: 1), in: name) {
            let fixed = String(name[r])
            if byExtension[(fixed as NSString).pathExtension.lowercased()] == kind { return fixed }
        }
        let stem = name.isEmpty ? "package" : name
        switch kind {
        case .apk: return stem + ".apk"
        case .bundle: return stem + ".apks"
        case .obb: return stem + ".obb"
        }
    }

    private static func kindFromBentName(_ name: String) -> Kind? {
        let range = NSRange(name.startIndex..., in: name)
        guard let m = bentName.firstMatch(in: name, range: range), let r = Range(m.range(at: 1), in: name) else { return nil }
        return byExtension[(String(name[r]) as NSString).pathExtension.lowercased()]
    }

    // MARK: - by content

    /// Opens the file and reads its zip directory: AndroidManifest.xml at the top is an APK; APKs at the top (with no manifest
    /// of its own) a bundle. Anything unreadable, or not a zip, is nil.
    static func sniff(_ url: URL) -> Kind? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var isDir: ObjCBool = false
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
              let names = zipNames(url) else { return nil }
        var manifest = false, apks = 0
        for n in names {
            if n == "AndroidManifest.xml" { manifest = true }
            else if !n.contains("/"), n.lowercased().hasSuffix(".apk") { apks += 1 }
        }
        if manifest { return .apk }
        if apks > 0 { return .bundle }
        return nil
    }

    /// The names in a zip's central directory (Zip64 included), or nil when it is not a zip.
    static func zipNames(_ url: URL, maxEntries: Int = 200_000) -> [String]? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        // a zip starts with a local header (or, for an empty one, the end record)
        guard let head = try? file.read(upToCount: 4), head.count == 4,
              head[0] == 0x50, head[1] == 0x4b, (head[2] == 3 && head[3] == 4) || (head[2] == 5 && head[3] == 6) else { return nil }
        guard let size = try? file.seekToEnd(), size >= 22 else { return nil }
        let tail = min(size, 70_000)
        guard (try? file.seek(toOffset: size - tail)) != nil, let endData = try? file.read(upToCount: Int(tail)), endData.count >= 22 else { return nil }
        let b = [UInt8](endData)
        var e = b.count - 22
        while e >= 0, !(b[e] == 0x50 && b[e + 1] == 0x4b && b[e + 2] == 5 && b[e + 3] == 6) { e -= 1 }
        guard e >= 0 else { return nil }
        var count = UInt64(le16(b, e + 10)), dirSize = UInt64(le32(b, e + 12)), dirOffset = UInt64(le32(b, e + 16))
        if dirOffset == 0xffff_ffff || count == 0xffff || dirSize == 0xffff_ffff {
            guard e >= 20, le32(b, e - 20) == 0x0706_4b50 else { return nil }
            guard (try? file.seek(toOffset: le64(b, e - 20 + 8))) != nil, let rec = try? file.read(upToCount: 56), rec.count == 56 else { return nil }
            let r = [UInt8](rec)
            guard le32(r, 0) == 0x0606_4b50 else { return nil }
            count = le64(r, 32); dirSize = le64(r, 40); dirOffset = le64(r, 48)
        }
        // a directory bigger than any APK's is a sign of a damaged file: read no more than 32 MB of it
        guard dirOffset < size, dirSize <= 32 << 20, (try? file.seek(toOffset: dirOffset)) != nil,
              let dirData = try? file.read(upToCount: Int(dirSize)), dirData.count == Int(dirSize) else { return nil }
        let cd = [UInt8](dirData)
        var names: [String] = []
        var p = 0
        for _ in 0..<min(count, UInt64(maxEntries)) {
            guard p + 46 <= cd.count, le32(cd, p) == 0x0201_4b50 else { break }
            let nameLen = Int(le16(cd, p + 28)), extraLen = Int(le16(cd, p + 30)), commentLen = Int(le16(cd, p + 32))
            guard p + 46 + nameLen <= cd.count else { break }
            names.append(String(decoding: cd[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self))
            p += 46 + nameLen + extraLen + commentLen
        }
        return names.isEmpty ? nil : names
    }

    private static func le16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
    private static func le32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }
    private static func le64(_ b: [UInt8], _ o: Int) -> UInt64 { UInt64(le32(b, o)) | UInt64(le32(b, o + 4)) << 32 }
}
