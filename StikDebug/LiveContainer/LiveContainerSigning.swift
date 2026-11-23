//
//  LiveContainerSigning.swift
//  StikDebug (LiveContainer fork)
//
//  Before every launch LiveContainer checks the guest app's code signature and re-signs it
//  with the imported certificate when needed (JITLess mode). Launching straight into a
//  Multitask window skips that step, and an app that needs re-signing (new install, update,
//  changed certificate) then fails with "dlopen … code signature invalid".
//
//  LiveContainer's own helper can't simply be called from a guest: inside a guest every
//  non-Apple preference domain is redirected to the guest's container (so the certificate
//  isn't found) and it signs with NSBundle.mainBundle's ID, which is StikDebug's there.
//  This reproduces the same steps with the host's real data:
//    1. skip when LiveContainer isn't in JITLess mode, or the app is 32-bit / "Don't Sign";
//    2. check the signature with LiveContainer's checkCodeSignature();
//    3. if invalid, sign the bundle with ZSign using the certificate from LiveContainer's
//       shared defaults, its password and LiveContainer's bundle ID, then check again.
//

import Foundation
import ObjectiveC.runtime

enum LiveContainerSigningError: LocalizedError {
    case notPatched(String)
    case noCertificate
    case zsignUnavailable(String)
    case signFailed(String, String)
    case stillInvalid(String)

    var errorDescription: String? {
        switch self {
        case .notPatched(let app):
            return "\(app) hasn't been prepared by LiveContainer yet. Open it once from LiveContainer, then try again from StikDebug."
        case .noCertificate:
            return "LiveContainer's signing certificate wasn't found. Import it again in LiveContainer settings (JITLess), then try again."
        case .zsignUnavailable(let detail):
            return "LiveContainer's signer (ZSign) couldn't be loaded: \(detail)"
        case .signFailed(let app, let detail):
            return "Signing \(app) failed: \(detail)"
        case .stillInvalid(let app):
            return "\(app) is still not validly signed. The certificate imported in LiveContainer may be revoked or expired: import a new one in LiveContainer settings."
        }
    }
}

enum LiveContainerSigning {
    /// LiveContainer's current executable patch revision (LCAppInfo.m).
    private static let requiredPatchRevision = 7

    private typealias CheckSignatureFunction = @convention(c) (UnsafePointer<CChar>) -> Bool
    /// checkCodeSignature() from LiveContainerShared.framework (loaded with LiveContainer).
    private static var checkCodeSignature: CheckSignatureFunction? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "checkCodeSignature")
            .map { unsafeBitCast($0, to: CheckSignatureFunction.self) }
    }

    /// Makes sure LiveContainer can load `app`, signing it like LiveContainer does before a launch.
    /// Returns true when the app had to be (re)signed.
    @discardableResult
    static func ensureSigned(_ app: LiveContainerGuestApp, onSigning: @escaping @MainActor () -> Void = {}) async throws -> Bool {
        guard LiveContainerBridge.isRunningInLiveContainer,
              let password = LiveContainerBridge.certificatePassword, !password.isEmpty else {
            // Not in JITLess mode: LiveContainer doesn't sign apps (JIT bypasses library validation).
            return false
        }

        let lcInfo = NSDictionary(contentsOf: app.bundleURL.appendingPathComponent("LCAppInfo.plist")) as? [String: Any] ?? [:]
        if (lcInfo["dontSign"] as? Bool) == true || (lcInfo["is32bit"] as? Bool) == true {
            return false
        }
        if ((lcInfo["LCPatchRevision"] as? NSNumber)?.intValue ?? 0) < requiredPatchRevision {
            throw LiveContainerSigningError.notPatched(app.displayName)
        }

        let infoPlist = NSDictionary(contentsOf: app.bundleURL.appendingPathComponent("Info.plist")) as? [String: Any] ?? [:]
        guard let executable = infoPlist["CFBundleExecutable"] as? String else { return false }
        let executableURL = app.bundleURL.appendingPathComponent(executable)

        if signatureIsValid(at: executableURL) != false {
            // Valid, or the check isn't available (older LiveContainer): leave it to LiveContainer.
            return false
        }

        guard let certificate = LiveContainerBridge.certificateData else {
            throw LiveContainerSigningError.noCertificate
        }
        guard let hostBundleID = LiveContainerBridge.hostBundleIdentifier else {
            throw LiveContainerSigningError.zsignUnavailable("LiveContainer bundle not found")
        }

        await onSigning()
        LogManager.shared.addInfoLog("[LiveContainer] Signing \(app.displayName) with LiveContainer's certificate")

        // Same as LiveContainer: copy-delete-move so the kernel doesn't keep the old signature
        // cached for this file (EXC_BAD_ACCESS / SIGKILL - CODESIGNING otherwise).
        refreshFile(at: executableURL)

        try await sign(bundleURL: app.bundleURL, hostBundleID: hostBundleID,
                       certificate: certificate, password: password, appName: app.displayName)

        if signatureIsValid(at: executableURL) == false {
            throw LiveContainerSigningError.stillInvalid(app.displayName)
        }
        LogManager.shared.addInfoLog("[LiveContainer] \(app.displayName) signed")
        return true
    }

    /// nil when LiveContainer's checkCodeSignature() isn't available.
    static func signatureIsValid(at url: URL) -> Bool? {
        guard let checkCodeSignature else { return nil }
        return url.path.withCString { checkCodeSignature($0) }
    }

    private static func refreshFile(at url: URL) {
        let fm = FileManager.default
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + "_LiveContainerPatchBackUp")
        try? fm.removeItem(at: backup)
        guard (try? fm.copyItem(at: url, to: backup)) != nil else { return }
        try? fm.removeItem(at: url)
        try? fm.moveItem(at: backup, to: url)
    }

    private static func sign(bundleURL: URL, hostBundleID: String, certificate: Data,
                             password: String, appName: String) async throws {
        let signer = try loadZSigner()
        let selector = NSSelectorFromString("signWithAppPath:bundleId:cert:pass:completionHandler:")
        guard let method = class_getClassMethod(signer, selector) else {
            throw LiveContainerSigningError.zsignUnavailable("signWithAppPath missing")
        }
        typealias Completion = @convention(block) (Bool, NSError?) -> Void
        typealias SignIMP = @convention(c) (AnyClass, Selector, NSString, NSString, NSData, NSString, @escaping Completion) -> Unmanaged<AnyObject>?
        let imp = unsafeBitCast(method_getImplementation(method), to: SignIMP.self)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion: Completion = { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: LiveContainerSigningError.signFailed(
                        appName, error?.localizedDescription ?? "unknown error"))
                }
            }
            _ = imp(signer, selector, bundleURL.path as NSString, hostBundleID as NSString,
                    certificate as NSData, password as NSString, completion)
        }
    }

    private static func loadZSigner() throws -> AnyClass {
        if let cls = NSClassFromString("ZSigner") { return cls }
        guard let host = LiveContainerBridge.hostBundle else {
            throw LiveContainerSigningError.zsignUnavailable("LiveContainer bundle not found")
        }
        let frameworks = host.bundleURL.appendingPathComponent("Frameworks", isDirectory: true)
        let zsignPath = frameworks.appendingPathComponent("ZSign.dylib").path
        guard FileManager.default.fileExists(atPath: zsignPath) else {
            throw LiveContainerSigningError.zsignUnavailable("ZSign.dylib not found")
        }

        // ZSign links "@rpath/OpenSSL.framework/OpenSSL". Inside a guest, @rpath and
        // @executable_path resolve against the guest (StikDebug), so dyld can't find it.
        // Load each @rpath dependency from LiveContainer's Frameworks folder by absolute path
        // first; dyld then reuses the already-loaded image, matched by its install name.
        var dependencies = rpathDependencies(ofMachOAt: zsignPath)
        if !dependencies.contains("OpenSSL.framework/OpenSSL") {
            dependencies.insert("OpenSSL.framework/OpenSSL", at: 0)
        }
        for dependency in dependencies {
            let path = frameworks.appendingPathComponent(dependency).path
            guard FileManager.default.fileExists(atPath: path) else { continue }
            if dlopen(path, RTLD_LAZY | RTLD_GLOBAL) == nil {
                let reason = dlerror().map { String(cString: $0) } ?? "dlopen failed"
                throw LiveContainerSigningError.zsignUnavailable("\(dependency): \(reason)")
            }
        }

        if dlopen(zsignPath, RTLD_LAZY | RTLD_GLOBAL) == nil {
            throw LiveContainerSigningError.zsignUnavailable(dlerror().map { String(cString: $0) } ?? "dlopen failed")
        }
        guard let cls = NSClassFromString("ZSigner") else {
            throw LiveContainerSigningError.zsignUnavailable("ZSigner class missing")
        }
        return cls
    }

    /// Install names starting with "@rpath/" that the arm64 slice of a Mach-O file links,
    /// returned without the prefix (e.g. "OpenSSL.framework/OpenSSL").
    static func rpathDependencies(ofMachOAt path: String) -> [String] {
        guard let data = FileManager.default.contents(atPath: path), data.count >= 32 else { return [] }

        func u32(_ offset: Int, bigEndian: Bool = false) -> UInt32? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            let value = data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            return bigEndian ? UInt32(bigEndian: value) : UInt32(littleEndian: value)
        }

        // Find the 64-bit arm64 slice (thin file or fat/universal file).
        var sliceOffset = 0
        guard let magic = u32(0) else { return [] }
        if magic == 0xBEBA_FECA /* FAT_CIGAM, read little-endian */ {
            guard let count = u32(4, bigEndian: true) else { return [] }
            var found: Int?
            for index in 0..<Int(count) {
                let entry = 8 + index * 20
                guard let cpuType = u32(entry, bigEndian: true),
                      let offset = u32(entry + 8, bigEndian: true) else { break }
                if cpuType == 0x0100_000C /* CPU_TYPE_ARM64 */ {
                    found = Int(offset)
                    break
                }
            }
            guard let found else { return [] }
            sliceOffset = found
        }
        guard u32(sliceOffset) == 0xFEED_FACF /* MH_MAGIC_64 */,
              let commandCount = u32(sliceOffset + 16) else { return [] }

        let dylibCommands: Set<UInt32> = [0xC /* LC_LOAD_DYLIB */, 0x8000_0018 /* LC_LOAD_WEAK_DYLIB */,
                                          0x8000_001F /* LC_REEXPORT_DYLIB */, 0x8000_0023 /* LC_LOAD_UPWARD_DYLIB */]
        var result: [String] = []
        var cursor = sliceOffset + 32 // sizeof(mach_header_64)
        for _ in 0..<Int(commandCount) {
            guard let command = u32(cursor), let size = u32(cursor + 4), size >= 8 else { break }
            if dylibCommands.contains(command), let nameOffset = u32(cursor + 8) {
                let start = cursor + Int(nameOffset)
                let end = min(cursor + Int(size), data.count)
                if start < end {
                    let bytes = data.subdata(in: start..<end).prefix { $0 != 0 }
                    if let name = String(data: bytes, encoding: .utf8), name.hasPrefix("@rpath/") {
                        result.append(String(name.dropFirst("@rpath/".count)))
                    }
                }
            }
            cursor += Int(size)
        }
        return result
    }
}
