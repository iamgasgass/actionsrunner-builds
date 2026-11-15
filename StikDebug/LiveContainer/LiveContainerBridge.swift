//
//  LiveContainerBridge.swift
//  StikDebug (LiveContainer fork)
//
//  Lets StikDebug run as a guest app *inside* LiveContainer and enable JIT for
//  another app installed in the very same LiveContainer.
//
//  Why this is needed
//  ------------------
//  The classic flow ("Run with JIT" + StikDebug installed on the Home Screen)
//  relaunches the LiveContainer bundle under debugserver. When StikDebug itself
//  is a guest of that same LiveContainer, relaunching LiveContainer kills
//  StikDebug before it can attach, and the new process stays suspended forever.
//
//  The only process that can be debugged without killing StikDebug is a
//  *different* process of the same LiveContainer install: a LiveProcess
//  (LiveContainer "Multitask") extension process. So this bridge
//    1. asks LiveContainer (through its own LCUtils class) to start the guest app
//       in a LiveProcess window,
//    2. receives the PID of that process,
//    3. lets StikDebug attach to that PID (debugApp(withPID:)).
//
//  Everything here is resolved at runtime through the Objective-C runtime, so
//  the app still builds and runs normally when it is NOT inside LiveContainer.
//

import Foundation
import ObjectiveC.runtime
import UIKit

struct LiveContainerGuestApp: Identifiable, Hashable {
    /// Folder name of the .app inside LiveContainer (LiveContainer calls it "bundle-name"/"selected").
    let relativeBundlePath: String
    let bundleIdentifier: String
    let displayName: String
    let bundleURL: URL
    let isShared: Bool
    let isJITNeeded: Bool
    let isHidden: Bool
    let defaultContainerFolderName: String?
    /// Per-app JIT script configured in LiveContainer ("jitLaunchScriptJs", base64 JS).
    let jitLaunchScript: Data?

    var id: String { (isShared ? "shared/" : "private/") + relativeBundlePath }
}

enum LiveContainerBridgeError: LocalizedError {
    case notInLiveContainer
    case liveContainerSwiftUIUnavailable(String)
    case multitaskUnavailable
    case liveProcessExtensionMissing
    case missingContainer(String)
    case launchFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .notInLiveContainer:
            return "StikDebug is not running inside LiveContainer."
        case .liveContainerSwiftUIUnavailable(let detail):
            return "Unable to load LiveContainer's multitask support (\(detail)). Update LiveContainer to a version with Multitask support."
        case .multitaskUnavailable:
            return "LiveContainer Multitask is disabled or unavailable on this device."
        case .liveProcessExtensionMissing:
            return "LiveContainer's LiveProcess extension was not found. Reinstall LiveContainer with \"Keep Extensions\" enabled in SideStore/AltStore."
        case .missingContainer(let app):
            return "\(app) has no data container yet. Open it once from LiveContainer, then try again."
        case .launchFailed(let detail):
            return "LiveContainer could not start the app in Multitask: \(detail)"
        case .timedOut:
            return "LiveContainer did not report the PID of the multitask app in time."
        }
    }
}

enum LiveContainerBridge {

    // MARK: - Environment detection

    /// True when StikDebug is executing as a LiveContainer guest (main process or LiveProcess).
    static var isRunningInLiveContainer: Bool {
        if getenv("LC_HOME_PATH") != nil { return true }
        return NSClassFromString("LCSharedUtils") != nil
    }

    /// True when StikDebug itself runs inside a LiveProcess (Multitask) extension.
    static var isRunningInLiveProcess: Bool {
        guard isRunningInLiveContainer else { return false }
        if let value = callClassBool(on: UserDefaults.self, selector: "isLiveProcess") {
            return value
        }
        return getenv("LP_HOME_PATH") != nil
    }

    /// The real LiveContainer host bundle (NSBundle.mainBundle is hooked to the guest's bundle).
    static var hostBundle: Bundle? {
        guard isRunningInLiveContainer else { return nil }
        return callClassObject(on: UserDefaults.self, selector: "lcMainBundle") as? Bundle
    }

    static var hostBundleIdentifier: String? {
        hostBundle?.bundleIdentifier
    }

    /// URL scheme of this LiveContainer copy (livecontainer, livecontainer2, ...).
    static var hostURLScheme: String {
        (callClassObject(on: UserDefaults.self, selector: "lcAppUrlScheme") as? String) ?? "livecontainer"
    }

    static var liveContainerHomeURL: URL? {
        guard let path = getenv("LC_HOME_PATH") else { return nil }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    static var appGroupURL: URL? {
        guard let path = callClassObject(on: UserDefaults.self, selector: "lcAppGroupPath") as? String,
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// True when `bundleID` identifies the LiveContainer process StikDebug is running in.
    /// Launching/relaunching that bundle through debugserver would terminate StikDebug itself.
    static func isOwnHost(bundleID: String?) -> Bool {
        guard let bundleID, isRunningInLiveContainer, let host = hostBundleIdentifier else { return false }
        return bundleID.caseInsensitiveCompare(host) == .orderedSame
    }

    /// True when launching `bundleID` via debugserver would kill the process StikDebug lives in.
    static func launchWouldTerminateSelf(bundleID: String?) -> Bool {
        isOwnHost(bundleID: bundleID)
    }

    static func isOwnProcess(pid: Int32) -> Bool {
        pid == getpid()
    }

    static var multitaskJITSupported: Bool {
        if #available(iOS 17.4, *) { return true }
        return false
    }

    // MARK: - Installed guest apps

    static func installedGuestApps(includeHidden: Bool = false) -> [LiveContainerGuestApp] {
        guard isRunningInLiveContainer else { return [] }
        var apps: [LiveContainerGuestApp] = []
        if let home = liveContainerHomeURL {
            apps += scanApplications(in: home.appendingPathComponent("Documents/Applications", isDirectory: true), shared: false)
        }
        if let group = appGroupURL {
            apps += scanApplications(in: group.appendingPathComponent("LiveContainer/Applications", isDirectory: true), shared: true)
        }

        let ownBundleID = Bundle.main.bundleIdentifier
        let ownBundleName = Bundle.main.bundleURL.lastPathComponent
        var seen = Set<String>()
        return apps
            .filter { app in
                // Hide StikDebug itself: attaching to our own process would deadlock.
                if app.bundleIdentifier == ownBundleID && app.relativeBundlePath == ownBundleName { return false }
                return includeHidden || !app.isHidden
            }
            .filter { seen.insert($0.relativeBundlePath).inserted }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private static func scanApplications(in directory: URL, shared: Bool) -> [LiveContainerGuestApp] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return entries.compactMap { url -> LiveContainerGuestApp? in
            guard url.pathExtension == "app" else { return nil }
            let info = NSDictionary(contentsOf: url.appendingPathComponent("Info.plist")) as? [String: Any] ?? [:]
            let lcInfo = NSDictionary(contentsOf: url.appendingPathComponent("LCAppInfo.plist")) as? [String: Any] ?? [:]

            let bundleID = (lcInfo["LCOrignalBundleIdentifier"] as? String)
                ?? (info["CFBundleIdentifier"] as? String)
                ?? url.deletingPathExtension().lastPathComponent
            let name = (info["CFBundleDisplayName"] as? String)
                ?? (info["CFBundleName"] as? String)
                ?? url.deletingPathExtension().lastPathComponent

            return LiveContainerGuestApp(
                relativeBundlePath: url.lastPathComponent,
                bundleIdentifier: bundleID,
                displayName: name,
                bundleURL: url,
                isShared: shared,
                isJITNeeded: (lcInfo["isJITNeeded"] as? Bool) ?? false,
                isHidden: (lcInfo["isHidden"] as? Bool) ?? false,
                defaultContainerFolderName: defaultContainer(from: lcInfo),
                jitLaunchScript: (lcInfo["jitLaunchScriptJs"] as? String).flatMap { Data(base64Encoded: $0) }
            )
        }
    }

    private static func defaultContainer(from lcInfo: [String: Any]) -> String? {
        // LiveContainer treats LCDataUUID as the app's default data container.
        if let uuid = lcInfo["LCDataUUID"] as? String, !uuid.isEmpty {
            return uuid
        }
        let containers = lcInfo["LCContainers"] as? [[String: Any]] ?? []
        if let def = containers.first(where: { ($0["isDefault"] as? Bool) == true }),
           let folder = def["folderName"] as? String {
            return folder
        }
        if let first = containers.first?["folderName"] as? String {
            return first
        }
        return nil
    }

    // MARK: - Multitask launch (same LiveContainer)

    /// Starts `app` in a LiveContainer Multitask (LiveProcess) window and returns its PID.
    /// Must be called from the main thread.
    @MainActor
    static func launchInMultitask(_ app: LiveContainerGuestApp, timeout: TimeInterval = 30) async throws -> Int32 {
        guard isRunningInLiveContainer, let home = liveContainerHomeURL else {
            throw LiveContainerBridgeError.notInLiveContainer
        }
        guard let container = app.defaultContainerFolderName else {
            throw LiveContainerBridgeError.missingContainer(app.displayName)
        }

        let lcUtils = try loadLCUtilsClass()
        if callClassObject(on: lcUtils, selector: "liveProcessBundleIdentifier") == nil {
            throw LiveContainerBridgeError.liveProcessExtensionMissing
        }

        let launchSelector = NSSelectorFromString("launchMultitaskGuestApp:completionHandler:")
        guard let method = class_getClassMethod(lcUtils, launchSelector) else {
            throw LiveContainerBridgeError.liveContainerSwiftUIUnavailable("launchMultitaskGuestApp missing")
        }

        // LCUtils reads the target from +[NSUserDefaults standardUserDefaults]. Inside a
        // guest that is StikDebug's own defaults domain, so stage the values there.
        let defaults = UserDefaults.standard
        defaults.set(app.relativeBundlePath, forKey: "selected")
        defaults.set(container, forKey: "selectedContainer")

        // LiveContainer's multitask controller derives the LiveContainer home/Documents
        // from NSHomeDirectory(). For a guest, HOME points to the guest data container,
        // so temporarily expose the real LiveContainer home while the window is created.
        let override = HomeDirectoryOverride(path: home.path)
        override.apply()

        typealias LaunchIMP = @convention(c) (AnyClass, Selector, NSString, @escaping @convention(block) (NSNumber?, NSError?) -> Void) -> Void
        let imp = unsafeBitCast(method_getImplementation(method), to: LaunchIMP.self)

        return try await withCheckedThrowingContinuation { continuation in
            let box = ResumeOnce(continuation)

            imp(lcUtils, launchSelector, app.displayName as NSString) { pid, error in
                if let error {
                    box.resume(throwing: LiveContainerBridgeError.launchFailed(error.localizedDescription))
                } else if let pid, pid.int32Value > 0 {
                    box.resume(returning: pid.int32Value)
                } else {
                    box.resume(throwing: LiveContainerBridgeError.launchFailed("no PID returned"))
                }
            }

            // LCUtils creates the window in a dispatch_async on the main queue. Restore the
            // environment only after that block (queued before this one) has run.
            DispatchQueue.main.async {
                DispatchQueue.main.async {
                    override.restore()
                    defaults.removeObject(forKey: "selected")
                    defaults.removeObject(forKey: "selectedContainer")
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                box.resume(throwing: LiveContainerBridgeError.timedOut)
            }
        }
    }

    /// Opens the LiveContainer UI (only useful when StikDebug runs in a LiveProcess window
    /// or another LiveContainer copy; in the main process it replaces StikDebug).
    static func openLiveContainerHome() {
        guard let url = URL(string: "\(hostURLScheme)://livecontainer-launch?bundle-name=ui") else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Runtime helpers

    private static func loadLCUtilsClass() throws -> AnyClass {
        if let cls = NSClassFromString("LCUtils") { return cls }
        guard let hostBundle else {
            throw LiveContainerBridgeError.liveContainerSwiftUIUnavailable("host bundle unknown")
        }
        let frameworkPath = hostBundle.bundleURL
            .appendingPathComponent("Frameworks/LiveContainerSwiftUI.framework/LiveContainerSwiftUI").path
        guard FileManager.default.fileExists(atPath: frameworkPath) else {
            throw LiveContainerBridgeError.liveContainerSwiftUIUnavailable("framework not found")
        }
        if dlopen(frameworkPath, RTLD_LAZY | RTLD_GLOBAL) == nil {
            let reason = dlerror().map { String(cString: $0) } ?? "dlopen failed"
            throw LiveContainerBridgeError.liveContainerSwiftUIUnavailable(reason)
        }
        guard let cls = NSClassFromString("LCUtils") else {
            throw LiveContainerBridgeError.liveContainerSwiftUIUnavailable("LCUtils class missing")
        }
        return cls
    }

    private static func callClassObject(on cls: AnyClass, selector name: String) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard let method = class_getClassMethod(cls, selector) else { return nil }
        typealias Getter = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
        let imp = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        return imp(cls, selector)?.takeUnretainedValue()
    }

    private static func callClassBool(on cls: AnyClass, selector name: String) -> Bool? {
        let selector = NSSelectorFromString(name)
        guard let method = class_getClassMethod(cls, selector) else { return nil }
        typealias Getter = @convention(c) (AnyClass, Selector) -> Bool
        let imp = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        return imp(cls, selector)
    }
}

// MARK: - Private helpers

private final class ResumeOnce: @unchecked Sendable {
    private var continuation: CheckedContinuation<Int32, Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<Int32, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Int32) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Int32, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let current = continuation
        continuation = nil
        return current
    }
}

private final class HomeDirectoryOverride {
    private static let keys = ["HOME", "CFFIXED_USER_HOME"]
    private let path: String
    private var saved: [String: String?] = [:]

    init(path: String) {
        self.path = path
    }

    func apply() {
        for key in Self.keys {
            saved[key] = getenv(key).map { String(cString: $0) }
            setenv(key, path, 1)
        }
    }

    func restore() {
        for key in Self.keys {
            if let value = saved[key] ?? nil {
                setenv(key, value, 1)
            } else {
                unsetenv(key)
            }
        }
        saved.removeAll()
    }
}
