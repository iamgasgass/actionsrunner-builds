//
//  LiveContainerJIT.swift
//  StikDebug (LiveContainer fork)
//
//  Shared flow that enables JIT for an app installed in the same LiveContainer:
//  start it in a Multitask (LiveProcess) window, attach to its PID, run the JIT
//  script on TXM devices and verify that the target really became debuggable.
//  Used by the LiveContainer tab and by stikjit:// requests for LiveContainer guests.
//

import Foundation
import SwiftUI

private typealias CsopsFunction = @convention(c) (pid_t, UInt32, UnsafeMutableRawPointer?, Int) -> Int32

/// csops(2) is not exported in the iOS SDK headers; resolve it at runtime (RTLD_DEFAULT = -2).
private let lcCsops: CsopsFunction? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "csops")
    .map { unsafeBitCast($0, to: CsopsFunction.self) }

enum LiveContainerJITScript {
    /// Script for a LiveContainer guest app, in order of preference:
    /// 1. the per-app JIT script configured in LiveContainer,
    /// 2. a script the user assigned to the bundle ID in StikDebug,
    /// 3. StikDebug's automatic assignment, matched by the guest's *name*
    ///    (upstream matches names from the device app list, where LiveContainer guests never appear),
    /// 4. on TXM devices, universal.js (attaching without a script does not enable JIT there).
    static func script(for app: LiveContainerGuestApp) -> (data: Data, name: String)? {
        if let data = app.jitLaunchScript {
            return (data, "\(app.displayName) (LiveContainer).js")
        }
        if let name = ScriptStore.assignedScriptName(for: app.bundleIdentifier),
           let assigned = ScriptStore.script(named: name) {
            return assigned
        }
        guard ProcessInfo.processInfo.hasTXM else { return nil }
        if let resource = ScriptStore.autoScriptResource(for: app.displayName),
           let auto = bundledScript(resource) {
            return auto
        }
        return bundledScript(ScriptResource(resourceName: "universal", fileName: "universal.js"))
    }

    static func bundledScript(_ resource: ScriptResource) -> (data: Data, name: String)? {
        if let userCopy = ScriptStore.script(named: resource.fileName) {
            return userCopy
        }
        guard let url = Bundle.main.url(forResource: resource.resourceName, withExtension: "js"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return (data, resource.fileName)
    }
}

enum LiveContainerJITVerification {
    case enabled
    case notEnabled
    case unknown

    /// Reads the target's code-signing flags; CS_DEBUGGED means JIT (RX mappings) is allowed.
    static func check(pid: Int32) -> LiveContainerJITVerification {
        guard let lcCsops else { return .unknown }
        var flags: UInt32 = 0
        let result = lcCsops(pid, 0 /* CS_OPS_STATUS */, &flags, MemoryLayout<UInt32>.size)
        guard result == 0 else { return .unknown }
        return (flags & 0x1000_0000 /* CS_DEBUGGED */) != 0 ? .enabled : .notEnabled
    }
}

@MainActor
final class LiveContainerJITController: ObservableObject {
    static let shared = LiveContainerJITController()

    @Published private(set) var busyAppID: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var lastResultIsError = false
    @Published var scriptRunModel: RunJSViewModel?

    private init() {}

    var isBusy: Bool { busyAppID != nil }

    /// Finds the LiveContainer guest app with this bundle identifier (used for stikjit:// requests).
    static func guestApp(bundleID: String) -> LiveContainerGuestApp? {
        guard LiveContainerBridge.isRunningInLiveContainer,
              !LiveContainerBridge.isOwnHost(bundleID: bundleID) else { return nil }
        return LiveContainerBridge.installedGuestApps(includeHidden: true).first {
            $0.bundleIdentifier.caseInsensitiveCompare(bundleID) == .orderedSame
        }
    }

    func enableJIT(for app: LiveContainerGuestApp, scriptOverride: (data: Data, name: String)? = nil) {
        guard busyAppID == nil else { return }
        busyAppID = app.id
        lastResultIsError = false
        statusMessage = "Waiting for device connection…"
        Haptics.medium()
        LogManager.shared.addInfoLog("[LiveContainer] Launching \(app.displayName) (\(app.relativeBundlePath)) with JIT in the same LiveContainer")

        Task { @MainActor in
            startTunnelInBackground(showErrorUI: false)
            let ready = await Task.detached(priority: .userInitiated) {
                Self.waitForJITPrerequisites()
            }.value
            guard ready else {
                finish(error: "The device connection or Developer Disk Image wasn't ready in time. Make sure LocalDevVPN is on and the pairing file is imported, then try again.")
                return
            }

            statusMessage = "Starting \(app.displayName) in Multitask…"
            let pid: Int32
            do {
                pid = try await LiveContainerBridge.launchInMultitask(app)
            } catch {
                finish(error: error.localizedDescription)
                return
            }

            guard !LiveContainerBridge.isOwnProcess(pid: pid) else {
                finish(error: "LiveContainer returned StikDebug's own process. Enable Multitask in LiveContainer settings and try again.")
                return
            }

            statusMessage = "Attaching to \(app.displayName) (PID \(pid))…"
            LogManager.shared.addInfoLog("[LiveContainer] \(app.displayName) is running as PID \(pid)")
            attach(pid: pid, app: app, script: scriptOverride ?? LiveContainerJITScript.script(for: app))
        }
    }

    private func attach(pid: Int32, app: LiveContainerGuestApp, script: (data: Data, name: String)?) {
        let hasTXM = ProcessInfo.processInfo.hasTXM
        var callback: DebugAppCallback?

        if hasTXM, let script {
            LogManager.shared.addInfoLog("[LiveContainer] Running \(script.name) for \(app.displayName)")
            callback = { pid, debugProxy, remoteServer, semaphore in
                // No resumeBundleID: the target lives in this LiveContainer and relaunching
                // the host bundle would terminate StikDebug.
                let model = RunJSViewModel(pid: Int(pid), debugProxy: debugProxy,
                                           remoteServer: remoteServer, semaphore: semaphore,
                                           resumeBundleID: nil)
                DispatchQueue.main.async {
                    LiveContainerJITController.shared.scriptRunModel = model
                }
                do {
                    try model.runScript(data: script.data, name: script.name)
                } catch {
                    semaphore.signal()
                    DispatchQueue.main.async {
                        showAlert(title: "Error Occurred While Executing Script.".localized,
                                  message: error.localizedDescription, showOk: true)
                    }
                }
            }
        } else if hasTXM {
            LogManager.shared.addWarningLog("[LiveContainer] No JIT script found for \(app.displayName); on this device JIT usually needs one.")
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let keepAlive = DebugKeepAliveLease()
            defer { keepAlive.invalidate() }

            var lastMessage: String?
            let logger: LogFunc = { message in
                if let message {
                    lastMessage = message
                    LogManager.shared.addInfoLog(message)
                }
            }
            let success = JITEnableContext.shared.debugApp(withPID: pid, logger: logger, jsCallback: callback)
            let verification = success ? LiveContainerJITVerification.check(pid: pid) : .unknown

            DispatchQueue.main.async {
                let controller = LiveContainerJITController.shared
                guard success else {
                    controller.finish(error: lastMessage ?? "StikDebug could not attach to \(app.displayName).")
                    return
                }
                switch verification {
                case .enabled:
                    controller.finish(message: "JIT enabled for \(app.displayName). Switch to its Multitask window.")
                case .unknown:
                    controller.finish(message: "Debug session for \(app.displayName) completed. Check JIT status in the app's Multitask window.")
                case .notEnabled:
                    let hint = hasTXM
                        ? "This device needs a JIT script: set one for \(app.displayName) in LiveContainer (JIT launch script) or assign one in StikDebug → Scripts."
                        : "Close the app's Multitask window and try again."
                    controller.finish(error: "StikDebug attached to \(app.displayName) (PID \(pid)), but JIT is still off. \(hint)")
                }
            }
        }
    }

    private func finish(message: String) {
        busyAppID = nil
        lastResultIsError = false
        statusMessage = message
        Haptics.light()
        AccessibilityAnnouncer.announce(message)
    }

    private func finish(error: String) {
        busyAppID = nil
        lastResultIsError = true
        statusMessage = error
        LogManager.shared.addErrorLog("[LiveContainer] \(error)")
        showAlert(title: "Failed to Enable JIT".localized, message: error, showOk: true)
    }

    nonisolated private static func waitForJITPrerequisites(timeout: TimeInterval = 25) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if TunnelManager.shared.isConnected && MountingProgress.shared.coolisMounted {
                return true
            }
            usleep(250_000)
        }
        return TunnelManager.shared.isConnected && MountingProgress.shared.coolisMounted
    }
}
