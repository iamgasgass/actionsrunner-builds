//
//  LiveContainerOverlay.swift
//  StikDebug (LiveContainer fork)
//
//  LiveContainer draws its floating Multitask windows on top of the guest app's views, so a
//  capsule placed in StikDebug's own view hierarchy is hidden behind them. The JIT status
//  capsule and the running-session pills therefore live in a separate UIWindow above
//  everything, styled with the native Liquid Glass effect (iOS 26+).
//
//  That window only accepts touches inside the capsule/pill frames (measured by SwiftUI and
//  stored in `LiveContainerOverlayHitRegions`) or while the script log sheet is presented;
//  every other touch falls through to StikDebug and to the Multitask windows below.
//

import SwiftUI
import UIKit

// MARK: - Window

@MainActor
final class LiveContainerOverlayWindow {
    static let shared = LiveContainerOverlayWindow()

    private var window: LiveContainerPassthroughWindow?

    private init() {}

    /// Creates the overlay window once and keeps it visible.
    func install() {
        if let window, window.windowScene != nil {
            window.isHidden = false
            return
        }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
            return
        }

        let window = LiveContainerPassthroughWindow(windowScene: scene)
        // Above LiveContainer's floating Multitask windows (they live inside the app's main window).
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        window.backgroundColor = .clear
        let host = UIHostingController(rootView: LiveContainerOverlayView())
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = false
        self.window = window
    }
}

/// Frames (window coordinates) of the overlay's tappable capsules.
@MainActor
enum LiveContainerOverlayHitRegions {
    static var frames: [CGRect] = []
}

final class LiveContainerPassthroughWindow: UIWindow {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // While the log sheet (or anything else) is presented from this window, take all touches.
        if rootViewController?.presentedViewController != nil {
            return super.point(inside: point, with: event)
        }
        let frames = MainActor.assumeIsolated { LiveContainerOverlayHitRegions.frames }
        return frames.contains { $0.insetBy(dx: -4, dy: -4).contains(point) }
    }
}

private struct LiveContainerHitFramesKey: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

private extension View {
    /// Reports this view's frame so the overlay window accepts touches on it.
    func liveContainerHitRegion() -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: LiveContainerHitFramesKey.self,
                                       value: [proxy.frame(in: .global)])
            }
        )
    }
}

// MARK: - Liquid Glass

extension View {
    /// Native Liquid Glass on iOS 26+, material fallback on earlier versions.
    @ViewBuilder
    func liveContainerGlassCapsule(tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            if let tint {
                self.glassEffect(.regular.tint(tint.opacity(0.35)).interactive(), in: .capsule)
            } else {
                self.glassEffect(.regular.interactive(), in: .capsule)
            }
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
        }
    }
}

// MARK: - Swipe to dismiss

/// Swipe left or right to hide a capsule. Follows the finger, flies off past a threshold,
/// springs back otherwise. Taps still reach the button underneath.
private struct LiveContainerSwipeToDismiss: ViewModifier {
    let onDismiss: () -> Void

    @State private var offset: CGFloat = 0
    @State private var isDismissing = false

    private static let threshold: CGFloat = 80

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .opacity(1 - min(abs(offset) / 260, 0.7))
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        guard !isDismissing else { return }
                        // Only horizontal swipes; ignore mostly vertical drags.
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        offset = value.translation.width
                    }
                    .onEnded { value in
                        guard !isDismissing else { return }
                        let projected = value.predictedEndTranslation.width
                        if abs(offset) > Self.threshold || abs(projected) > Self.threshold * 2.5 {
                            isDismissing = true
                            let direction: CGFloat = (projected == 0 ? offset : projected) < 0 ? -1 : 1
                            Haptics.light()
                            withAnimation(.easeOut(duration: 0.2)) {
                                offset = direction * 600
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                onDismiss()
                            }
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                offset = 0
                            }
                        }
                    }
            )
            .accessibilityAction(named: Text("Hide")) { onDismiss() }
    }
}

private extension View {
    func liveContainerSwipeToDismiss(_ onDismiss: @escaping () -> Void) -> some View {
        modifier(LiveContainerSwipeToDismiss(onDismiss: onDismiss))
    }
}

// MARK: - Overlay content

struct LiveContainerOverlayView: View {
    @ObservedObject private var controller = LiveContainerJITController.shared

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            glassGroup {
                VStack(spacing: 8) {
                    ForEach(controller.visibleSessions) { session in
                        LiveContainerSessionPill(session: session)
                            .liveContainerSwipeToDismiss { controller.dismiss(session) }
                            .liveContainerHitRegion()
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if let feedback = controller.feedback {
                        LiveContainerFeedbackCapsule(feedback: feedback)
                            .id(feedback.id)
                            .liveContainerSwipeToDismiss { controller.dismissFeedback() }
                            .liveContainerHitRegion()
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 92) // above the tab bar (the window's safe area covers the home indicator)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onPreferenceChange(LiveContainerHitFramesKey.self) { frames in
            MainActor.assumeIsolated { LiveContainerOverlayHitRegions.frames = frames }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: controller.visibleSessions.map(\.id))
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: controller.feedback?.id)
        .sheet(item: $controller.presentedSession) { session in
            LiveContainerSessionLogSheet(session: session)
        }
    }

    @ViewBuilder
    private func glassGroup<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 8) { content() }
        } else {
            content()
        }
    }
}

private struct LiveContainerFeedbackCapsule: View {
    let feedback: LiveContainerJITFeedback
    @ObservedObject private var controller = LiveContainerJITController.shared

    var body: some View {
        HStack(spacing: 10) {
            switch feedback.kind {
            case .working:
                ProgressView().controlSize(.small)
            case .success:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failure:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            Text(feedback.message)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.leading)
                .lineLimit(3)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .contentShape(Capsule())
        .liveContainerGlassCapsule()
        // A tap gesture (not a Button) so a swipe never also counts as a tap.
        .onTapGesture {
            // Opens the log of the current (or most recent) JIT session, if there is one.
            if !controller.sessions.isEmpty { controller.showLog() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

private struct LiveContainerSessionPill: View {
    @ObservedObject var session: LiveContainerJITSession
    @ObservedObject private var controller = LiveContainerJITController.shared

    var body: some View {
        HStack(spacing: 10) {
            LiveContainerAppIconView(app: session.app, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: "text.alignleft")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 8)
        .padding(.trailing, 16)
        .padding(.vertical, 8)
        .contentShape(Capsule())
        .liveContainerGlassCapsule(tint: tint)
        // A tap gesture (not a Button) so a swipe never also counts as a tap.
        .onTapGesture { controller.showLog(session) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(title). \(subtitle). Show script log")
    }

    private var title: String {
        switch session.state {
        case .attaching: return "Attaching to \(session.app.displayName)…"
        case .serving: return "JIT on · \(session.app.displayName)"
        case .finished: return "JIT on · \(session.app.displayName)"
        case .appClosed: return "\(session.app.displayName) closed"
        }
    }

    private var subtitle: String {
        switch session.state {
        case .attaching: return session.scriptName
        case .serving: return "\(session.scriptName) attached · keep StikDebug open"
        case .finished: return "\(session.scriptName) completed"
        case .appClosed: return "JIT session ended"
        }
    }

    private var tint: Color? {
        switch session.state {
        case .serving, .finished: return .green
        case .appClosed: return .gray
        case .attaching: return nil
        }
    }
}

private struct LiveContainerSessionLogSheet: View {
    @ObservedObject var session: LiveContainerJITSession
    @ObservedObject private var controller = LiveContainerJITController.shared

    var body: some View {
        NavigationStack {
            Group {
                if let model = session.model {
                    RunJSView(model: model)
                } else {
                    ProgressView("Attaching…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .safeAreaInset(edge: .top) {
                if let note {
                    Label(note, systemImage: session.state == .serving ? "bolt.fill" : "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.bar)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { controller.presentedSession = nil }
                }
            }
        }
    }

    private var note: String? {
        switch session.state {
        case .serving:
            return "JIT is on. \(session.app.displayName) keeps the script attached to request JIT memory while it runs, so the log stays on \"Handling signal\" — that's expected. Closing this log or swiping the pill away does not stop it; the session ends when you close the app."
        case .attaching:
            return "Attaching to \(session.app.displayName)…"
        case .finished:
            return "\(session.app.displayName) finished the JIT handshake and detached."
        case .appClosed:
            return "\(session.app.displayName) was closed, so the JIT session ended."
        }
    }
}
