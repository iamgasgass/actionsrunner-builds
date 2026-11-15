//
//  LiveContainerOverlay.swift
//  StikDebug (LiveContainer fork)
//
//  LiveContainer draws its Multitask windows on top of the guest app's views, so a capsule
//  placed in StikDebug's own view hierarchy ends up hidden behind them. The JIT status
//  capsule and the running-session pills therefore live in a separate, touch-transparent
//  UIWindow above everything, styled with the native Liquid Glass effect (iOS 26+).
//

import SwiftUI
import UIKit

// MARK: - Window

@MainActor
final class LiveContainerOverlayWindow {
    static let shared = LiveContainerOverlayWindow()

    private var window: PassthroughWindow?

    private init() {}

    /// Creates the overlay window once (no-op when it already exists).
    func install() {
        if let window, window.windowScene?.activationState != .unattached {
            window.isHidden = false
            return
        }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
            return
        }

        let window = PassthroughWindow(windowScene: scene)
        // Above LiveContainer's floating Multitask windows (which live in the app's main window).
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        let host = UIHostingController(rootView: LiveContainerOverlayView())
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = false
        self.window = window
    }
}

/// Lets touches through everywhere except on the overlay's own controls (and presented sheets).
private final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        return hit === rootViewController?.view ? nil : hit
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

// MARK: - Overlay content

struct LiveContainerOverlayView: View {
    @ObservedObject private var controller = LiveContainerJITController.shared

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            glassGroup {
                VStack(spacing: 8) {
                    ForEach(controller.sessions) { session in
                        LiveContainerSessionPill(session: session)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if let feedback = controller.feedback {
                        LiveContainerFeedbackCapsule(feedback: feedback)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 92) // above the tab bar
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: controller.sessions.map(\.id))
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
        .liveContainerGlassCapsule()
        .accessibilityElement(children: .combine)
    }
}

private struct LiveContainerSessionPill: View {
    @ObservedObject var session: LiveContainerJITSession
    @ObservedObject private var controller = LiveContainerJITController.shared

    var body: some View {
        Button {
            controller.showLog(session)
        } label: {
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
        }
        .buttonStyle(.plain)
        .liveContainerGlassCapsule(tint: tint)
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
            return "JIT is on. \(session.app.displayName) keeps the script attached to request JIT memory while it runs, so the log stays on \"Handling signal\" — that's expected. Closing this log does not stop it; the session ends when you close the app."
        case .attaching:
            return "Attaching to \(session.app.displayName)…"
        case .finished:
            return "\(session.app.displayName) finished the JIT handshake and detached."
        case .appClosed:
            return "\(session.app.displayName) was closed, so the JIT session ended."
        }
    }
}
