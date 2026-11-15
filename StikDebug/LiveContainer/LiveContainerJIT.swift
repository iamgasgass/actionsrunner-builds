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
    enum Source: Equatable {
        case chosen          // picked for this app in the LiveContainer tab
        case liveContainer   // LiveContainer's per-app "JIT launch script"
        case assigned        // assigned to the bundle ID in the JIT tab
        case automatic       // StikDebug's automatic assignment (by app name)
        case universal       // universal.js fallback on TXM devices
        case none

        var label: String {
            switch self {
            case .chosen: return "Chosen"
            case .liveContainer: return "LiveContainer"
            case .assigned: return "Assigned in JIT tab"
            case .automatic: return "Automatic"
            case .universal: return "Default"
            case .none: return "None"
            }
        }
    }

    private static let choiceKey = "lcScriptChoices"
    /// Stored choice meaning "attach without any script".
    static let noScriptChoice = "__none__"

    /// Script explicitly chosen for this app in the LiveContainer tab (file name, or `noScriptChoice`).
    static func choice(for app: LiveContainerGuestApp) -> String? {
        (UserDefaults.standard.dictionary(forKey: choiceKey) as? [String: String])?[app.id]
    }

    static func setChoice(_ value: String?, for app: LiveContainerGuestApp) {
        var map = (UserDefaults.standard.dictionary(forKey: choiceKey) as? [String: String]) ?? [:]
        map[app.id] = value
        UserDefaults.standard.set(map, forKey: choiceKey)
    }

    /// Script for a LiveContainer guest app. A script chosen in the LiveContainer tab wins;
    /// otherwise the default order is:
    /// 1. the per-app JIT script configured in LiveContainer,
    /// 2. a script assigned to the bundle ID in the JIT tab,
    /// 3. StikDebug's automatic assignment, matched by the guest's *name*
    ///    (upstream matches names from the device app list, where LiveContainer guests never appear),
    /// 4. on TXM devices, universal.js for every other app (attaching without a script does not
    ///    enable JIT there) — the same handling that makes Henge and Husk work.
    static func script(for app: LiveContainerGuestApp) -> (data: Data, name: String)? {
        resolve(for: app).script
    }

    static func resolve(for app: LiveContainerGuestApp) -> (script: (data: Data, name: String)?, source: Source) {
        if let choice = choice(for: app) {
            if choice == noScriptChoice { return (nil, .none) }
            if let chosen = ScriptStore.script(named: choice) { return (chosen, .chosen) }
        }
        return defaultScript(for: app)
    }

    static func defaultScript(for app: LiveContainerGuestApp) -> (script: (data: Data, name: String)?, source: Source) {
        if let data = app.jitLaunchScript {
            return ((data, "\(app.displayName) (LiveContainer).js"), .liveContainer)
        }
        if let name = ScriptStore.assignedScriptName(for: app.bundleIdentifier),
           let assigned = ScriptStore.script(named: name) {
            return (assigned, .assigned)
        }
        guard ProcessInfo.processInfo.hasTXM else { return (nil, .none) }
        if let resource = ScriptStore.autoScriptResource(for: app.displayName),
           let auto = bundledScript(resource) {
            return (auto, .automatic)
        }
        return (bundledScript(universal), .universal)
    }

    static let universal = ScriptResource(resourceName: "universal", fileName: "universal.js")

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

    /// Reads the target's code-signing flags; CS_DEBUGGED means a debugger enabled JIT for it.
    static func check(pid: Int32) -> LiveContainerJITVerification {
        guard let lcCsops else { return .unknown }
        var flags: UInt32 = 0
        let result = lcCsops(pid, 0 /* CS_OPS_STATUS */, &flags, MemoryLayout<UInt32>.size)
        guard result == 0 else { return .unknown }
        return (flags & 0x1000_0000 /* CS_DEBUGGED */) != 0 ? .enabled : .notEnabled
    }
}

struct LiveContainerJITFeedback: Identifiable, Equatable {
    enum Kind { case working, success, failure }

    let id = UUID()
    let message: String
    let kind: Kind
}

/// A JIT script session that stays attached to a LiveContainer app (universal.js keeps serving
/// the app's JIT requests until the app detaches or closes, e.g. Husk never detaches).
final class LiveContainerJITSession: ObservableObject, Identifiable {
    enum State: Equatable {
        case attaching
        case serving        // JIT on; the script waits for the app's next JIT request
        case finished       // the app detached itself (e.g. Henge) or the script ended
        case appClosed
    }

    let id = UUID()
    let app: LiveContainerGuestApp
    let pid: Int32
    let scriptName: String
    @Published var state: State = .attaching
    @Published var model: RunJSViewModel?

    init(app: LiveContainerGuestApp, pid: Int32, scriptName: String) {
        self.app = app
        self.pid = pid
        self.scriptName = scriptName
    }

    var isRunning: Bool { state == .attaching || state == .serving }
}

@MainActor
final class LiveContainerJITController: ObservableObject {
    static let shared = LiveContainerJITController()

    @Published private(set) var busyAppID: String?
    @Published private(set) var feedback: LiveContainerJITFeedback?
    /// Script sessions that are still attached (shown as Liquid Glass pills above every window).
    @Published private(set) var sessions: [LiveContainerJITSession] = []
    /// Set to show a session's script log in a sheet.
    @Published var presentedSession: LiveContainerJITSession?

    private init() {}

    var isBusy: Bool { busyAppID != nil }
    var runningSessions: [LiveContainerJITSession] { sessions.filter(\.isRunning) }

    /// Finds the LiveContainer guest app with this bundle identifier (used for stikjit:// requests).
    static func guestApp(bundleID: String) -> LiveContainerGuestApp? {
        guard LiveContainerBridge.isRunningInLiveContainer,
              !LiveContainerBridge.isOwnHost(bundleID: bundleID) else { return nil }
        return LiveContainerBridge.installedGuestApps(includeHidden: true).first {
            $0.bundleIdentifier.caseInsensitiveCompare(bundleID) == .orderedSame
        }
    }

    func showLog(_ session: LiveContainerJITSession? = nil) {
        presentedSession = session ?? runningSessions.last ?? sessions.last
    }

    func enableJIT(for app: LiveContainerGuestApp, scriptOverride: (data: Data, name: String)? = nil) {
        guard busyAppID == nil else { return }
        busyAppID = app.id
        Haptics.medium()
        LiveContainerOverlayWindow.shared.install()
        show(String(format: "Starting JIT for %@".localized, app.displayName), .working)
        LogManager.shared.addInfoLog("[LiveContainer] Launching \(app.displayName) (\(app.relativeBundlePath)) with JIT in the same LiveContainer")

        // Resolve the script now (file I/O) so nothing slows down the attach later.
        let script = scriptOverride ?? LiveContainerJITScript.script(for: app)

        Task { @MainActor in
            // Start the app right away and get the device connection ready at the same time,
            // instead of waiting for the tunnel before LiveContainer opens the window.
            if !TunnelManager.shared.isConnected {
                startTunnelInBackground(showErrorUI: false)
            }
            let prerequisites = Task.detached(priority: .userInitiated) {
                Self.waitForJITPrerequisites()
            }

            let pid: Int32
            do {
                pid = try await LiveContainerBridge.launchInMultitask(app)
            } catch {
                prerequisites.cancel()
                finish(error: error.localizedDescription)
                return
            }

            guard !LiveContainerBridge.isOwnProcess(pid: pid) else {
                finish(error: "LiveContainer returned StikDebug's own process. Enable Multitask in LiveContainer settings and try again.")
                return
            }
            LogManager.shared.addInfoLog("[LiveContainer] \(app.displayName) is running as PID \(pid)")

            guard await prerequisites.value else {
                finish(error: "The device connection or Developer Disk Image wasn't ready in time. Make sure LocalDevVPN is on and the pairing file is imported, then try again.")
                return
            }

            attach(pid: pid, app: app, script: script)
        }
    }

    private func attach(pid: Int32, app: LiveContainerGuestApp, script: (data: Data, name: String)?) {
        let hasTXM = ProcessInfo.processInfo.hasTXM
        var callback: DebugAppCallback?
        var session: LiveContainerJITSession?

        if hasTXM, let script {
            LogManager.shared.addInfoLog("[LiveContainer] Running \(script.name) for \(app.displayName)")
            // A new launch replaces older sessions of the same app (LiveContainer restarted it).
            sessions.removeAll { $0.app.id == app.id && !$0.isRunning }
            let newSession = LiveContainerJITSession(app: app, pid: pid, scriptName: script.name)
            sessions.append(newSession)
            session = newSession

            callback = { pid, debugProxy, remoteServer, semaphore in
                // No resumeBundleID: the target lives in this LiveContainer and relaunching
                // the host bundle would terminate StikDebug.
                let model = RunJSViewModel(pid: Int(pid), debugProxy: debugProxy,
                                           remoteServer: remoteServer, semaphore: semaphore,
                                           resumeBundleID: nil)
                DispatchQueue.main.async { newSession.model = model }
                LiveContainerJITController.watchProcessExit(pid: pid, session: newSession, model: model)
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
            // The debug session lasts as long as the app keeps it attached, so report success
            // as soon as the target becomes debuggable instead of waiting for the session to end.
            watchForJIT(pid: pid, app: app, session: newSession)
        } else if hasTXM {
            LogManager.shared.addWarningLog("[LiveContainer] No JIT script selected for \(app.displayName); on this device JIT usually needs one.")
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
                if let session {
                    if session.state != .appClosed { session.state = .finished }
                    controller.scheduleSessionCleanup(session)
                }
                if session != nil, controller.busyAppID != app.id {
                    // Success was already reported while the script was running.
                    return
                }
                guard success else {
                    controller.finish(error: lastMessage ?? "StikDebug could not attach to \(app.displayName).")
                    return
                }
                switch verification {
                case .enabled, .unknown:
                    controller.finish(success: app)
                case .notEnabled:
                    let hint = hasTXM
                        ? "This device needs a JIT script: choose one for \(app.displayName) in the LiveContainer tab (long-press the app)."
                        : "Close the app's Multitask window and try again."
                    controller.finish(error: "StikDebug attached to \(app.displayName) (PID \(pid)), but JIT is still off. \(hint)")
                }
            }
        }
    }

    /// Reports success as soon as the target is debuggable and marks the session as serving.
    private func watchForJIT(pid: Int32, app: LiveContainerGuestApp, session: LiveContainerJITSession) {
        Task.detached(priority: .userInitiated) {
            for _ in 0..<120 {   // up to ~30 s
                if LiveContainerJITVerification.check(pid: pid) == .enabled {
                    await MainActor.run {
                        if session.state == .attaching { session.state = .serving }
                        let controller = LiveContainerJITController.shared
                        if controller.busyAppID == app.id {
                            controller.finish(success: app)
                        }
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    /// When the app's Multitask window is closed the process exits; stop the script so it does
    /// not keep polling a dead process and the session ends cleanly.
    nonisolated private static func watchProcessExit(pid: Int32, session: LiveContainerJITSession, model: RunJSViewModel) {
        DispatchQueue.global(qos: .utility).async {
            while true {
                usleep(500_000)
                let finished = DispatchQueue.main.sync { !session.isRunning }
                if finished { return }
                if kill(pid, 0) != 0 && errno == ESRCH {
                    DispatchQueue.main.async {
                        session.state = .appClosed
                        model.executionInterrupted = true
                        model.logs.append("\(session.app.displayName) was closed. JIT session ended.")
                    }
                    return
                }
            }
        }
    }

    private func scheduleSessionCleanup(_ session: LiveContainerJITSession) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.presentedSession?.id != session.id else { return }
            withAnimation { self.sessions.removeAll { $0.id == session.id } }
        }
    }

    private func finish(success app: LiveContainerGuestApp) {
        busyAppID = nil
        Haptics.light()
        show(String(format: "JIT enabled for %@".localized, app.displayName), .success)
    }

    private func finish(error: String) {
        busyAppID = nil
        show(error, .failure)
        LogManager.shared.addErrorLog("[LiveContainer] \(error)")
        showAlert(title: "Failed to Enable JIT".localized, message: error, showOk: true)
    }

    private func show(_ message: String, _ kind: LiveContainerJITFeedback.Kind) {
        let feedback = LiveContainerJITFeedback(message: message, kind: kind)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            self.feedback = feedback
        }
        AccessibilityAnnouncer.announce(message)
        guard kind != .working else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.feedback?.id == feedback.id else { return }
            withAnimation { self.feedback = nil }
        }
    }

    nonisolated private static func waitForJITPrerequisites(timeout: TimeInterval = 25) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if TunnelManager.shared.isConnected && MountingProgress.shared.coolisMounted {
                return true
            }
            usleep(100_000)
        }
        return TunnelManager.shared.isConnected && MountingProgress.shared.coolisMounted
    }
}
