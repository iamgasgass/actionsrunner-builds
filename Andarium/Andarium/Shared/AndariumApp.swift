// SPDX-License-Identifier: GPL-2.0-or-later

import AndariumCore
import SwiftUI
import UIKit

@main
final class AndariumApp: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Mesa reads its disk cache's location and limit from the process
        // environment when the runtime thread creates the guest's screen.
        // Set them here, before any scene or runtime exists.
        MesaShaderCache.configureBeforeFirstUse()
        return true
    }

    func application(
        _ application: UIApplication, configurationForConnecting session: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Andarium", sessionRole: session.role)
        configuration.delegateClass = AndariumSceneDelegate.self
        return configuration
    }
}

/// The entry, model and runtime of the process. A scene shows them and owns
/// only its window: UIKit disconnects a scene it releases and connects one
/// again, and the runtime holds a guest that a new scene cannot be handed.
@MainActor
final class AndariumProcess {
    static let shared = AndariumProcess()

    let entry: AppEntry
    let model: AppModel

    private init() {
        entry = AppEntry.fromArguments()
        entry.configureTips()
        // A report staged for sharing by a process that ended is of no use.
        // This is the process's launch: a test that builds a model does not
        // sweep the folder a running test stages its files in.
        BugReportStaging.sweep()
        GuestFileStaging.sweep()
        PickedFolder.sweep()
        #if FEEDBACK_MAIL
        SendFeedbackStaging().sweep()
        #endif
        model = entry.makeModel()
        #if TIP_JAR
        // From launch: a purchase the store delivers outside the sheet (an
        // approval, an interrupted purchase) is finished, whether or not the
        // sheet is ever opened.
        #if !APP_STORE
        // A hosted test owns StoreKit's queue, and the launch's own listener
        // would finish its transactions before the test looks.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            TipJarUpdates.listen(model.tipJarServices.store)
        }
        #else
        TipJarUpdates.listen(model.tipJarServices.store)
        #endif
        #endif
    }
}

final class AndariumSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    /// The process's model, which this scene shows.
    private(set) var model: AppModel?

    func windowScene(_ windowScene: UIWindowScene, didUpdateEffectiveGeometry previousGeometry: UIWindowScene.Geometry) {
        (window?.rootViewController as? SceneGeometryObserver)?.sceneGeometryDidChange()
    }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        connect(scene)
    }

    func connect(_ scene: UIWindowScene) {
        guard window == nil else { return }
        let process = AndariumProcess.shared
        let entry = process.entry
        let model = process.model
        self.model = model
        model.screenDidChange(nativeScale: Double(scene.screen.nativeScale))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = AndariumHostingController(
            rootView: RootView(entry: entry).environment(model), model: model)
        self.window = window
        window.makeKeyAndVisible()
    }
}

/// Clean power-off returns to Home; a failed run waits for a fresh process.
struct RootView: View {
    @Environment(AppModel.self) private var model
    let entry: AppEntry

    /// What VoiceOver says as a run begins; other screens speak for
    /// themselves from their first element.
    static func spoken(_ phase: Phase) -> String? {
        switch phase {
        case .running(.normal):
            String(localized: "Android is running. The side keys on the screen edge have Back, Home and Settings.")
        case .running(.recovery):
            String(localized: "Recovery is running. The side keys have Up and Down to move, and Power to choose.")
        case .home, .booting, .failed:
            nil
        }
    }

    var body: some View {
        @Bindable var model = model
        ZStack {
            // The guest's display lives under the screens of the boot and the
            // run, so it is one view from the first frame to the last.
            GuestLayer()
                // The keyboard of the text message bar goes over Android; it
                // does not move it.
                .ignoresSafeArea(.keyboard)
            Group {
                switch model.phase {
                case .home:
                    HomeView(hints: entry.hints)
                case .booting(let kind):
                    BootView(kind: kind)
                        .id(kind)
                case .running(let mode):
                    SessionView(mode: mode)
                case .failed:
                    EndView()
                }
            }
            .transition(.opacity)
            if let busy = model.busy, !model.busyOverSheet {
                BusyOverlay(state: busy)
            }
            // While VoiceOver runs and Android's screen reader is off, the
            // card that asks about it; the model puts it away as it ends.
            if let card = model.session.reader.card, case .running = model.phase {
                ScreenReaderCard(card: card)
            }
            // Over everything the session shows, a Settings sheet aside: the
            // model closes it when the guest pauses.
            if let pause = model.spacePause {
                LowSpaceOverlay(
                    pause: pause, resume: { model.resumeAfterSpacePause() },
                    shutDown: { model.shutDownAfterSpacePause() },
                    checkAgain: { model.checkSpaceAfterPauseFailed() })
            }
        }
        // Toggles take the jade accent too, not the system green.
        .tint(Color.accentColor)
        .animation(.easeInOut(duration: 0.4), value: model.phase)
        // A new screen replaces the old one under VoiceOver's cursor: it
        // starts again at the top, and hears what the run now is.
        .onChange(of: model.phase) { _, phase in
            VoiceOver.screenChanged(Self.spoken(phase))
        }
        .animation(.easeInOut(duration: 0.2), value: model.busy != nil)
        .animation(.easeInOut(duration: 0.2), value: model.spacePause != nil)
        .animation(.easeInOut(duration: 0.2), value: model.session.reader.card)
        .alert(
            model.alert?.title ?? "",
            isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
            presenting: model.alert
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { alert in
            Text(alert.message.keepingTogether)
        }
        .legacyInstallAlert()
        #if FEEDBACK_MAIL
        // The sheet the boot screen's notice opens: over every phase, so a
        // draft survives the boot that ends.
        .sendFeedbackFromBootSheet(model)
        #endif
        #if !APP_STORE
        .task {
            // The launch's automation work happens once per model: a scene
            // that connects again must not create, erase or start the guest
            // a second time.
            guard !model.launchApplied else { return }
            model.launchApplied = true
            await entry.applyDeferred(to: model)
        }
        #endif
    }
}

/// Settings' Install APK, when Android refused an app for the version it was
/// built for: the question over the install's overlay. The buttons answer;
/// nothing else closes it. It sits on a view of its own, since a view that
/// carries two alerts presents only one of them reliably.
private struct LegacyInstallAlert: ViewModifier {
    @Environment(AppModel.self) private var model
    /// The alert is taken away for a moment so that it is presented again.
    @State private var withdrawn = false

    func body(content: Content) -> some View {
        content.background {
            Color.clear
                .accessibilityHidden(true)
                .task(id: model.legacyInstallQuestion?.id) { await presentUntilShown() }
                .alert(
                    LegacyInstallWords.title,
                    isPresented: Binding(get: { model.legacyInstallQuestion != nil && !withdrawn }, set: { _ in }),
                    presenting: model.legacyInstallQuestion
                ) { _ in
                    // Cancel is the alert's default: the bold button, and what Return does.
                    Button("Cancel", role: .cancel) { model.answerLegacyInstall(installAnyway: false) }
                        .keyboardShortcut(.defaultAction)
                    Button(LegacyInstallWords.install) { model.answerLegacyInstall(installAnyway: true) }
                } message: { question in
                    Text(LegacyInstallWords.message(for: question.target).keepingTogether)
                }
        }
    }
}

extension LegacyInstallAlert {
    /// UIKit refuses an alert while a popover (the side keys' tip) or a sheet is
    /// coming or going, and SwiftUI does not ask again: while the question
    /// stands and no alert is up, the alert is withdrawn and offered again. An
    /// alert that is up, whoever's it is, is left alone: UIKit shows ours after it.
    fileprivate func presentUntilShown() async {
        // The question's own life bounds the loop: its id is the task's, so an
        // answer, the overlay's Cancel or the guest ending cancels the task.
        defer { withdrawn = false }
        while model.legacyInstallQuestion != nil {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard model.legacyInstallQuestion != nil else { return }
            guard !Self.alertIsUp else { continue }
            withdrawn = true
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            withdrawn = false
        }
        await takeDownAlertOfGoneQuestion()
    }

    /// The question is gone and its alert goes with it. SwiftUI takes the alert down when its
    /// binding turns false, but one that was offered again (above) can stay up with nothing to
    /// answer, over the screens. After a moment, in which SwiftUI's own take-down ends, the alert
    /// still up under the question's title is taken down here, until a question stands again.
    private func takeDownAlertOfGoneQuestion() async {
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
        for _ in 0..<50 {
            guard model.legacyInstallQuestion == nil, let alert = Self.topAlert, alert.title == LegacyInstallWords.title else { return }
            if !alert.isBeingDismissed { alert.dismiss(animated: true) }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
    }

    private static var topAlert: UIAlertController? { PresentedAlert.top }
    private static var alertIsUp: Bool { PresentedAlert.isUp }
}

/// What UIKit shows of alerts now, for the questions that must not stand
/// without one.
enum PresentedAlert {
    /// The UIKit alert that is the topmost presentation of a window now, if one is.
    static var top: UIAlertController? {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                var top = window.rootViewController
                while let next = top?.presentedViewController { top = next }
                if let alert = top as? UIAlertController { return alert }
            }
        }
        return nil
    }

    /// Whether a UIKit alert is the topmost presentation of any window now.
    static var isUp: Bool { top != nil }
}

extension View {
    fileprivate func legacyInstallAlert() -> some View { modifier(LegacyInstallAlert()) }
}
