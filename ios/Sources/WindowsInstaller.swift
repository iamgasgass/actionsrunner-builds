// SPDX-License-Identifier: GPL-2.0-or-later
//
// WindowsiOS Universal: install Windows 11 on the iPhone itself, the way Henge installs macOS.
// No Mac, no PC: download Microsoft's ARM64 ESD, build the installer disk on the device
// (host/win_installer.c), then let Windows PE and Windows' own unattended setup run in the VM.
import CryptoKit
import Foundation
import UIKit

/// One Windows 11 ARM64 ESD from Microsoft's catalog (Resources/generated/windows-catalog.json, made by CI).
struct WindowsRelease: Identifiable, Codable, Hashable {
    let language: String
    let code: String      // "it-it"
    let file: String
    let url: String
    let size: Int64
    let sha1: String
    let build: String
    var id: String { code }

    /// Windows' locale name for this language ("it-IT").
    var locale: String {
        let parts = code.split(separator: "-")
        guard parts.count == 2 else { return code }
        return "\(parts[0].lowercased())-\(parts[1].uppercased())"
    }
    var title: String { "Windows 11 Pro \(build.isEmpty ? "" : "(\(build))")" }
}

enum WindowsCatalog {
    static let all: [WindowsRelease] = {
        guard let url = Bundle.main.url(forResource: "windows-catalog", withExtension: "json", subdirectory: "generated"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([WindowsRelease].self, from: data) else { return [] }
        return list
    }()

    /// The release in the iPhone's language, else English (US), else the first.
    static var recommended: WindowsRelease? {
        let preferred = Locale.preferredLanguages.map { $0.lowercased() }
        for p in preferred {
            if let r = all.first(where: { $0.code == p }) { return r }
            let lang = String(p.prefix(2))
            if let r = all.first(where: { $0.code.hasPrefix(lang + "-") }) { return r }
        }
        return all.first { $0.code == "en-us" } ?? all.first
    }
}

@MainActor
final class WindowsInstaller: NSObject, ObservableObject {
    static let shared = WindowsInstaller()

    enum Phase: Equatable {
        case idle
        case downloading
        case verifying
        case preparing
        case waitingForJIT
        case installing
        case done(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var received: Int64 = 0
    @Published private(set) var expected: Int64 = 0
    @Published private(set) var fraction: Double = 0
    @Published private(set) var stage: String = ""
    @Published private(set) var log: [String] = []

    /// The system disk's size; startnet.cmd finds the disk by it.
    static let systemDiskGB = 40
    private static let installingKey = "winios.installing"
    private var grace = UIBackgroundTaskIdentifier.invalid
    private var downloadTask: Task<Void, Never>?

    var busy: Bool {
        switch phase {
        case .downloading, .verifying, .preparing, .installing: return true
        default: return false
        }
    }

    // MARK: Paths

    nonisolated static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    nonisolated static var downloads: URL { documents.appendingPathComponent("Machines/Downloads", isDirectory: true) }
    nonisolated static var machine: URL { documents.appendingPathComponent("Machines/Win11", isDirectory: true) }
    nonisolated static var installerDisk: URL { machine.appendingPathComponent("installer.img") }
    nonisolated static var systemDisk: URL { machine.appendingPathComponent("windows11.img") }
    nonisolated static func esdPath(_ r: WindowsRelease) -> URL { downloads.appendingPathComponent(r.file) }
    nonisolated static func partPath(_ r: WindowsRelease) -> URL { downloads.appendingPathComponent(r.file + ".part") }
    nonisolated static var importedESD: URL { downloads.appendingPathComponent("imported.esd") }

    static var hasBundledFirmware: Bool {
        Bundle.main.url(forResource: "code", withExtension: "fd", subdirectory: "generated/firmware") != nil
    }

    static func haveImage(_ r: WindowsRelease) -> Bool {
        let size = (try? esdPath(r).resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
        return size > 0 && (r.size == 0 || size == r.size)
    }

    static func partSize(_ r: WindowsRelease) -> Int64 {
        Int64((try? partPath(r).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    static func deleteDownload(_ r: WindowsRelease) {
        try? FileManager.default.removeItem(at: esdPath(r))
        try? FileManager.default.removeItem(at: partPath(r))
    }

    /// Room an install takes: the rest of the download, a copy of it on the installer disk, and Windows itself.
    static func spaceNeeded(_ r: WindowsRelease?) -> Int64 {
        let esd = r?.size ?? (5 << 30)
        let toDownload = r.map { haveImage($0) ? 0 : max(esd - partSize($0), 0) } ?? 0
        return toDownload + esd + (2 << 30) + (22 << 30)
    }

    static var freeSpace: Int64 {
        let values = try? documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// True while an install that already reached the VM is not finished (the app was closed meanwhile).
    static var installPending: Bool {
        UserDefaults.standard.bool(forKey: installingKey) && FileManager.default.fileExists(atPath: installerDisk.path)
    }

    private func say(_ line: String) {
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    // MARK: Start

    nonisolated static var toolsDisk: URL { machine.appendingPathComponent("winios-tools.img") }

    /// The "WindowsiOS X Tools" drive Windows sees at every boot (D:): the drivers from this build and
    /// Installa-driver.cmd. Rebuilt when the app's build changes. Takes well under a second.
    static func ensureToolsDisk() {
        let fm = FileManager.default
        guard let res = Bundle.main.resourceURL else { return }
        let drivers = res.appendingPathComponent("generated/install/drivers", isDirectory: true)
        let scripts = res.appendingPathComponent("install/tools", isDirectory: true)
        guard fm.fileExists(atPath: drivers.path) else { return }
        let stamp = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") + "-" +
            String((try? fm.attributesOfItem(atPath: Bundle.main.bundlePath)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        let key = "winios.toolsDiskStamp"
        if fm.fileExists(atPath: toolsDisk.path) && UserDefaults.standard.string(forKey: key) == stamp { return }
        let tmp = fm.temporaryDirectory.appendingPathComponent("winios-tools", isDirectory: true)
        try? fm.removeItem(at: tmp)
        do {
            try fm.createDirectory(at: machine, withIntermediateDirectories: true)
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            try fm.copyItem(at: drivers, to: tmp.appendingPathComponent("drivers"))
            for item in (try? fm.contentsOfDirectory(at: scripts, includingPropertiesForKeys: nil)) ?? [] {
                try fm.copyItem(at: item, to: tmp.appendingPathComponent(item.lastPathComponent))
            }
            var err: NSString?
            if WinIOSBridge.shared.buildDataDisk(source: tmp.path, output: toolsDisk.path, label: "WINIOSTOOLS", error: &err) {
                UserDefaults.standard.set(stamp, forKey: key)
            }
        } catch {}
        try? fm.removeItem(at: tmp)
    }

    /// Called at launch: an install interrupted after it reached the VM goes on with the installer disk attached.
    func restore() {
        Self.ensureToolsDisk()
        guard Self.installPending else { return }
        WinIOSBridge.shared.installerDiskPath = Self.installerDisk.path
        hookExit()
        phase = .installing
        say("Resuming the install: Windows PE or Windows setup goes on where it stopped.")
    }

    func reset() { if !busy { phase = .idle } }

    func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        if phase == .downloading || phase == .verifying { phase = .idle }
    }

    /// release == nil: use an ESD imported into Machines/Downloads/imported.esd.
    func start(_ release: WindowsRelease?, user: String, lite: Bool, deleteAfter: Bool) {
        guard !busy else { return }
        log.removeAll()
        UIApplication.shared.isIdleTimerDisabled = true
        grace = UIApplication.shared.beginBackgroundTask(withName: "Windows install") {
            MainActor.assumeIsolated { WindowsInstaller.shared.endGrace() }
        }
        downloadTask = Task {
            do {
                try FileManager.default.createDirectory(at: Self.downloads, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: Self.machine, withIntermediateDirectories: true)
                guard Self.hasBundledFirmware else {
                    throw InstallError("This build has no UEFI firmware. Build the app with the GitHub workflow (it adds it), or place code.fd, vars.fd and a Windows disk in Machines/Win11.")
                }
                let need = Self.spaceNeeded(release)
                if Self.freeSpace > 0 && Self.freeSpace < need {
                    throw InstallError("Not enough free space: about \(ByteCountFormatter.string(fromByteCount: need, countStyle: .file)) is needed, \(ByteCountFormatter.string(fromByteCount: Self.freeSpace, countStyle: .file)) is free.")
                }
                let esd: URL
                if let r = release {
                    if !Self.haveImage(r) { try await download(r) }
                    esd = Self.esdPath(r)
                    if !r.sha1.isEmpty { try await verify(esd, sha1: r.sha1) }
                } else {
                    esd = Self.importedESD
                    guard FileManager.default.fileExists(atPath: esd.path) else { throw InstallError("No Windows image was imported.") }
                }
                try await prepare(esd: esd, release: release, user: user, lite: lite, deleteAfter: deleteAfter)
                launchInstall()
            } catch is CancellationError {
                phase = .idle
            } catch {
                say("Failed: \(error.localizedDescription)")
                phase = .failed(error.localizedDescription)
            }
            endGrace()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func endGrace() {
        guard grace != .invalid else { return }
        UIApplication.shared.endBackgroundTask(grace)
        grace = .invalid
    }

    // MARK: Download (resumable, straight from Microsoft's CDN)

    private func download(_ r: WindowsRelease) async throws {
        phase = .downloading
        stage = "Downloading \(r.title), \(r.language)"
        say(stage)
        guard let url = Self.downloadURL(r.url) else { throw InstallError("Bad download address") }
        let part = Self.partPath(r)
        if !FileManager.default.fileExists(atPath: part.path) { FileManager.default.createFile(atPath: part.path, contents: nil) }
        var have = Self.partSize(r)
        expected = r.size
        received = have
        var attempts = 0
        while r.size == 0 || have < r.size {
            try Task.checkCancellation()
            do {
                have = try await RangeDownload.run(url: url, file: part, from: have) { bytes in
                    Task { @MainActor in
                        let i = WindowsInstaller.shared
                        i.received = bytes
                        i.fraction = i.expected > 0 ? Double(bytes) / Double(i.expected) : 0
                    }
                }
                if r.size == 0 { expected = have; break }
                if have < r.size { throw InstallError("The connection closed early") }
            } catch is CancellationError {
                throw CancellationError()
            } catch let e as InstallError where e.fatal {
                throw e
            } catch let e as URLError where [.serverCertificateUntrusted, .serverCertificateHasBadDate,
                                              .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                                              .secureConnectionFailed, .appTransportSecurityRequiresSecureConnection].contains(e.code) {
                throw InstallError("Secure connection to Microsoft's server failed: \(e.localizedDescription)")
            } catch {
                attempts += 1
                have = Self.partSize(r)
                say("Download interrupted (\(error.localizedDescription)); going on from \(ByteCountFormatter.string(fromByteCount: have, countStyle: .file))")
                if attempts > 30 { throw error }
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        received = have
        try? FileManager.default.removeItem(at: Self.esdPath(r))
        try FileManager.default.moveItem(at: part, to: Self.esdPath(r))
        say("Downloaded \(ByteCountFormatter.string(fromByteCount: have, countStyle: .file))")
    }

    /// Microsoft's ESD CDN (dl.delivery.mp.microsoft.com) answers HTTPS with a certificate for another name, so
    /// iOS rejects it: download over HTTP as Microsoft's own Media Creation Tool does (Info.plist allows that one
    /// host) and rely on the SHA-1 from Microsoft's catalog, checked before anything is installed.
    nonisolated static func downloadURL(_ string: String) -> URL? {
        guard var c = URLComponents(string: string) else { return nil }
        if let host = c.host?.lowercased(), host.hasSuffix("delivery.mp.microsoft.com") { c.scheme = "http" }
        return c.url
    }

    private func verify(_ file: URL, sha1 expectedHash: String) async throws {
        phase = .verifying
        stage = "Checking the download"
        say(stage)
        let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let hash: String = try await Task.detached(priority: .userInitiated) { () -> String in
            let h = try FileHandle(forReadingFrom: file)
            defer { try? h.close() }
            var sha = Insecure.SHA1()
            var done: Int64 = 0
            while let chunk = try h.read(upToCount: 8 << 20), !chunk.isEmpty {
                sha.update(data: chunk)
                done += Int64(chunk.count)
                let f = size > 0 ? Double(done) / Double(size) : 0
                await MainActor.run { WindowsInstaller.shared.fraction = f }
            }
            return sha.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
        guard hash == expectedHash.lowercased() else {
            try? FileManager.default.removeItem(at: file)
            throw InstallError("The download is damaged (checksum mismatch) and was deleted. Try again.")
        }
        say("Checksum OK")
    }

    // MARK: Prepare the installer disk, the firmware and the system disk

    private func prepare(esd: URL, release: WindowsRelease?, user: String, lite: Bool, deleteAfter: Bool) async throws {
        phase = .preparing
        fraction = 0
        stage = "Preparing the installer"
        say(stage)
        let bridge = WinIOSBridge.shared
        var inspectError: NSString?
        guard let info = bridge.inspectWindowsImage(esd.path, error: &inspectError) else {
            throw InstallError((inspectError as String?) ?? "This is not a Windows 11 ARM64 image.")
        }
        say("Image: \(info["name"] as? String ?? "Windows") build \(info["build"] as? String ?? "?")")

        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("winios-install", isDirectory: true)
        try? fm.removeItem(at: tmp)
        let payload = tmp.appendingPathComponent("payload", isDirectory: true)
        try fm.createDirectory(at: payload, withIntermediateDirectories: true)

        // Payload: \winios on the installer's FAT32 partition
        let installRes = Bundle.main.resourceURL!.appendingPathComponent("install", isDirectory: true)
        let generatedInstall = Bundle.main.resourceURL!.appendingPathComponent("generated/install", isDirectory: true)
        for name in ["lite_soft.reg", "lite_user.reg", "lite_appx.txt"] {
            let src = installRes.appendingPathComponent(name)
            if fm.fileExists(atPath: src.path) { try fm.copyItem(at: src, to: payload.appendingPathComponent(name)) }
        }
        if let items = try? fm.contentsOfDirectory(at: generatedInstall, includingPropertiesForKeys: nil) {
            for item in items { try fm.copyItem(at: item, to: payload.appendingPathComponent(item.lastPathComponent)) }
        }
        let locale = release?.locale ?? Self.localeFromImageName(esd.lastPathComponent)
        let unattend = try String(contentsOf: installRes.appendingPathComponent("unattend.xml"), encoding: .utf8)
            .replacingOccurrences(of: "{{USER}}", with: Self.accountName(user))
            .replacingOccurrences(of: "{{COMPUTER}}", with: Self.computerName())
            .replacingOccurrences(of: "{{LOCALE}}", with: locale)
            .replacingOccurrences(of: "{{TIMEZONE}}", with: Self.windowsTimeZone())
        try Data(unattend.utf8).write(to: payload.appendingPathComponent("unattend.xml"))

        let startnet = try String(contentsOf: installRes.appendingPathComponent("startnet.cmd"), encoding: .utf8)
            .replacingOccurrences(of: "{{DISK_GB}}", with: String(Self.systemDiskGB))
            .replacingOccurrences(of: "{{LITE}}", with: lite ? "1" : "0")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
        let startnetURL = tmp.appendingPathComponent("startnet.cmd")
        try Data(startnet.utf8).write(to: startnetURL)

        // The installer disk (minutes: boot.wim, then a ~5 GB copy)
        let out = Self.installerDisk
        let work = tmp.appendingPathComponent("work", isDirectory: true)
        let ok: (Bool, String?) = await Task.detached(priority: .userInitiated) {
            var err: NSString?
            let ok = WinIOSBridge.shared.buildInstallerDisk(
                image: esd.path, startnet: startnetURL.path, payload: payload.path, output: out.path,
                workDir: work.path, deleteESD: deleteAfter,
                progress: { f, s in
                    Task { @MainActor in
                        let i = WindowsInstaller.shared
                        i.fraction = f
                        if i.stage != s { i.stage = s; i.say(s) }
                    }
                }, error: &err)
            return (ok, err as String?)
        }.value
        try? fm.removeItem(at: tmp)
        guard ok.0 else { throw InstallError(ok.1 ?? "Could not build the installer disk.") }

        // Fresh firmware, NVRAM and system disk
        let machine = Self.machine
        for old in ["windows11.img", "windows11.hvsparse", "code.fd", "vars.fd"] {
            try? fm.removeItem(at: machine.appendingPathComponent(old))
        }
        let firmware = Bundle.main.resourceURL!.appendingPathComponent("generated/firmware", isDirectory: true)
        try fm.copyItem(at: firmware.appendingPathComponent("code.fd"), to: machine.appendingPathComponent("code.fd"))
        try fm.copyItem(at: firmware.appendingPathComponent("vars.fd"), to: machine.appendingPathComponent("vars.fd"))
        var diskError: NSString?
        guard bridge.createSystemDisk(path: Self.systemDisk.path, gigabytes: Self.systemDiskGB, error: &diskError) else {
            throw InstallError((diskError as String?) ?? "Could not create the Windows disk.")
        }
        say("Installer disk, firmware and a \(Self.systemDiskGB) GB Windows disk are ready")
    }

    // MARK: Install in the VM

    private func hookExit() {
        WinIOSBridge.shared.onVMExit = { reason in
            Task { @MainActor in WindowsInstaller.shared.vmStopped(reason) }
        }
    }

    /// Starts the VM with the installer attached: Windows PE applies Windows and reboots into Windows'
    /// unattended setup, which turns the VM off when the first desktop has settled.
    func launchInstall() {
        let bridge = WinIOSBridge.shared
        bridge.installerDiskPath = Self.installerDisk.path
        UserDefaults.standard.set(true, forKey: Self.installingKey)
        hookExit()
        if !bridge.isJITLive { _ = bridge.tryAcquireJIT(true) }
        guard bridge.isJITLive else {
            phase = .waitingForJIT
            stage = "Enable JIT to install"
            say("Waiting for JIT (StikDebug)")
            return
        }
        phase = .installing
        stage = "Installing Windows 11"
        say("Starting the VM: Windows PE installs Windows, then Windows finishes its own setup and turns off.")
        bridge.prepareAndStart(with: nil)
    }

    private func vmStopped(_ reason: String) {
        guard phase == .installing || UserDefaults.standard.bool(forKey: Self.installingKey) else { return }
        WinIOSBridge.shared.onVMExit = nil
        WinIOSBridge.shared.installerDiskPath = nil
        UserDefaults.standard.set(false, forKey: Self.installingKey)
        try? FileManager.default.removeItem(at: Self.installerDisk)
        say("The VM turned off (\(reason)): install finished")
        phase = .done("Windows 11 is installed. Close WindowsiOS X (swipe it away), open it again with JIT, and tap Boot Windows 11.")
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    // MARK: Names

    static func accountName(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let clean = String(s.unicodeScalars.filter { allowed.contains($0) && $0.isASCII }.prefix(20))
        let reserved = ["administrator", "guest", "defaultaccount", "system", "wdagutilityaccount"]
        if clean.isEmpty { return "iPhone" }
        return reserved.contains(clean.lowercased()) ? clean + "1" : clean
    }

    static func computerName() -> String {
        let base = DeviceSupport.marketingName.uppercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
        let name = String(String.UnicodeScalarView(base).prefix(15))
        return name.isEmpty ? "IPHONE" : name
    }

    static func localeFromImageName(_ name: String) -> String {
        // "...A64FRE_it-it.esd"
        if let r = name.range(of: #"[a-z]{2}-[a-z]{2}(?=\.esd$)"#, options: [.regularExpression, .caseInsensitive]) {
            let p = name[r].split(separator: "-")
            return "\(p[0].lowercased())-\(p[1].uppercased())"
        }
        return "en-US"
    }

    /// The iPhone's time zone as a Windows time zone name (the common ones; UTC otherwise).
    static func windowsTimeZone() -> String {
        let map: [String: String] = [
            "Europe/Rome": "W. Europe Standard Time", "Europe/Berlin": "W. Europe Standard Time",
            "Europe/Zurich": "W. Europe Standard Time", "Europe/Vienna": "W. Europe Standard Time",
            "Europe/Amsterdam": "W. Europe Standard Time", "Europe/Stockholm": "W. Europe Standard Time",
            "Europe/Oslo": "W. Europe Standard Time", "Europe/Paris": "Romance Standard Time",
            "Europe/Madrid": "Romance Standard Time", "Europe/Brussels": "Romance Standard Time",
            "Europe/Copenhagen": "Romance Standard Time", "Europe/London": "GMT Standard Time",
            "Europe/Dublin": "GMT Standard Time", "Europe/Lisbon": "GMT Standard Time",
            "Europe/Athens": "GTB Standard Time", "Europe/Bucharest": "GTB Standard Time",
            "Europe/Helsinki": "FLE Standard Time", "Europe/Kiev": "FLE Standard Time", "Europe/Kyiv": "FLE Standard Time",
            "Europe/Warsaw": "Central European Standard Time", "Europe/Prague": "Central Europe Standard Time",
            "Europe/Budapest": "Central Europe Standard Time", "Europe/Moscow": "Russian Standard Time",
            "Europe/Istanbul": "Turkey Standard Time", "America/New_York": "Eastern Standard Time",
            "America/Chicago": "Central Standard Time", "America/Denver": "Mountain Standard Time",
            "America/Phoenix": "US Mountain Standard Time", "America/Los_Angeles": "Pacific Standard Time",
            "America/Anchorage": "Alaskan Standard Time", "Pacific/Honolulu": "Hawaiian Standard Time",
            "America/Toronto": "Eastern Standard Time", "America/Vancouver": "Pacific Standard Time",
            "America/Mexico_City": "Central Standard Time (Mexico)", "America/Sao_Paulo": "E. South America Standard Time",
            "America/Argentina/Buenos_Aires": "Argentina Standard Time", "Asia/Tokyo": "Tokyo Standard Time",
            "Asia/Seoul": "Korea Standard Time", "Asia/Shanghai": "China Standard Time",
            "Asia/Hong_Kong": "China Standard Time", "Asia/Taipei": "Taipei Standard Time",
            "Asia/Singapore": "Singapore Standard Time", "Asia/Kolkata": "India Standard Time",
            "Asia/Dubai": "Arabian Standard Time", "Asia/Jerusalem": "Israel Standard Time",
            "Australia/Sydney": "AUS Eastern Standard Time", "Australia/Melbourne": "AUS Eastern Standard Time",
            "Australia/Perth": "W. Australia Standard Time", "Pacific/Auckland": "New Zealand Standard Time",
            "Africa/Johannesburg": "South Africa Standard Time", "Africa/Cairo": "Egypt Standard Time",
        ]
        return map[TimeZone.current.identifier] ?? "UTC"
    }
}

struct InstallError: LocalizedError {
    let message: String
    var fatal = false
    init(_ message: String, fatal: Bool = false) { self.message = message; self.fatal = fatal }
    var errorDescription: String? { message }
}

/// One HTTP request that appends to a file from a byte offset (Range), written as it arrives.
final class RangeDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let file: URL
    private var handle: FileHandle?
    private var size: Int64
    private let start: Int64
    private let progress: (Int64) -> Void
    private var lastReport = Date.distantPast
    private var continuation: CheckedContinuation<RangeDownload, Error>?
    private var failure: Error?

    private init(file: URL, from: Int64, progress: @escaping (Int64) -> Void) {
        self.file = file
        self.size = from
        self.start = from
        self.progress = progress
    }

    static func run(url: URL, file: URL, from: Int64, progress: @escaping (Int64) -> Void) async throws -> Int64 {
        let d = RangeDownload(file: file, from: from, progress: progress)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config, delegate: d, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        if from > 0 { request.setValue("bytes=\(from)-", forHTTPHeaderField: "Range") }
        let task = session.dataTask(with: request)
        let done = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<RangeDownload, Error>) in
                d.continuation = c
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        return done.size
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        do {
            if status == 200 || status == 206 {
                let h = try FileHandle(forWritingTo: file)
                if status == 200 && start > 0 { // the server ignored the range: start over
                    try h.truncate(atOffset: 0)
                    size = 0
                }
                try h.seekToEnd()
                handle = h
                completionHandler(.allow)
                return
            }
            failure = InstallError("Microsoft's server answered \(status)", fatal: status == 404 || status == 403)
        } catch {
            failure = error
        }
        completionHandler(.cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
            size += Int64(data.count)
            let now = Date()
            if now.timeIntervalSince(lastReport) > 0.25 {
                lastReport = now
                progress(size)
            }
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        progress(size)
        if let f = failure ?? error {
            if (f as? URLError)?.code == .cancelled && failure == nil {
                continuation?.resume(throwing: CancellationError())
            } else {
                continuation?.resume(throwing: f)
            }
        } else {
            continuation?.resume(returning: self)
        }
        continuation = nil
    }
}
