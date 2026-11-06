import SwiftUI
import UIKit

/// The "OldOS" skin: the iOS 6 slider ported from OldOS' `lock_footer`
/// (OldOS/LockScreen.swift) — the rounded track with its `[83…143]` gradient
/// border and the metallic knob with the `⮕` glyph — but the whole slider is
/// rendered in red (track and knob). A single "Scorri per respring" label
/// shines continuously. Light and dark versions follow the app appearance.
struct OldOSPowerOffView: View {
    let isRunning: Bool
    let onArmed: () -> Void

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    @State private var sliderOffset: CGFloat = 0
    @State private var showingAlert = false

    private var isDark: Bool { colorScheme == .dark }
    /// Classic OldSafari aluminium buttons in light mode, graphite in dark.
    private var buttonType: OldOSButtonType { isDark ? .black : .gray }
    private var barTheme: OldOSSafariTheme { OldOSSafariTheme.theme(isPrivate: isDark) }

    /// The dark half-transparent "sheet" band — same full-width dimensions as
    /// before, with the translucent look. Dark in both appearances; the
    /// background shows faintly through.
    private var translucentBand: some View {
        Rectangle()
            .fill(Color.black.opacity(0.72))
            .overlay(
                Rectangle()
                    .fill(LinearGradient(colors: [Color.white.opacity(0.10), .clear],
                                         startPoint: .top, endPoint: .center))
                    .allowsHitTesting(false)
            )
            .oldOSBorder(width: 1, edges: [.top], color: Color.white.opacity(0.18))
            .oldOSBorder(width: 1, edges: [.bottom], color: Color.black.opacity(0.6))
    }

    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            let trackWidth = min(w - 44, 560)
            let trackHeight: CGFloat = 86

            ZStack {
                // Same grouped pinstripe background as the OldOS Settings.
                barTheme.groupedBackground.ignoresSafeArea()
                OldOSPinstripeBackground(line: barTheme.groupedPinstripe)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    OldOSTitleBar(
                        title: "RespringSlide",
                        theme: barTheme,
                        topInset: max(geometry.safeAreaInsets.top, 20)
                    )

                    // Top full-width translucent band (same size as before).
                    VStack(spacing: 0) {
                        respringIndicator
                            .padding(.top, 18)
                        slideToPowerOff(width: trackWidth, height: trackHeight)
                            .padding(.top, 20)
                            .padding(.bottom, 22)
                    }
                    .frame(maxWidth: .infinity)
                    .background(translucentBand)

                    Spacer(minLength: 0)

                    // Bottom full-width translucent band, extended to the bottom.
                    VStack(spacing: 0) {
                        cancelButton(width: trackWidth)
                            .padding(.top, 16)
                            .padding(.bottom, max(geometry.safeAreaInsets.bottom, 12) + 62)
                    }
                    .frame(maxWidth: .infinity)
                    .background(translucentBand)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(edges: [.top, .bottom])
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if showingAlert {
                    OldOSAlertView(
                        title: "Avviare il respring?",
                        message: "La tecnica può bloccare WebKit o riavviare SpringBoard, ma non è garantita su ogni versione di iOS. Salva prima il tuo lavoro.",
                        cancelTitle: "Annulla",
                        confirmTitle: "Avvia respring",
                        isDark: isDark,
                        onCancel: {
                            showingAlert = false
                            resetSlider()
                        },
                        onConfirm: {
                            showingAlert = false
                            onArmed()
                        }
                    )
                    .transition(.opacity)
                }
            }
        }
    }

    // MARK: - Top indicator ("the whole bubble" in iOS 6 gloss)

    private var respringIndicator: some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.clockwise")
                .font(OldOSFont.bold(13))
                .foregroundColor(.white)
            Text("Respring")
                .font(OldOSFont.bold(15))
                .foregroundColor(.white)
        }
        .shadow(color: .black.opacity(0.65), radius: 0, x: 0, y: -0.9)
        .padding(.horizontal, 20)
        .frame(height: 38)
        .background(iOS6GlossCapsule(type: buttonType))
    }

    // MARK: - Slide to power off (authentic iOS 6: dark skeuo band + red arrow)

    private func slideToPowerOff(width: CGFloat, height: CGFloat) -> some View {
        let inset: CGFloat = 4
        let knobSize = height - inset * 2
        let travel = max(0, width - knobSize - inset * 2)

        return ZStack(alignment: .leading) {
            // Track exactly as before: lock_footer dark rounded rect + [83…143].
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(oldOS: [
                    OldOSStop(.oldOS(3, 3, 3), 0),
                    OldOSStop(.oldOS(21, 21, 21), 0.5),
                    OldOSStop(.oldOS(32, 32, 32), 1)
                ]))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(LinearGradient(oldOS: [
                            OldOSStop(.oldOS(83, 83, 83), 0),
                            OldOSStop(.oldOS(143, 143, 143), 1)
                        ]), lineWidth: 0.5)
                )

            // Single "Scorri per respring" label, centred, continuous shine.
            Group {
                if isRunning {
                    Text("Respring in corso")
                        .font(OldOSFont.bold(23))
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.6), radius: 1, x: 0, y: 1)
                } else {
                    ShineText(text: "Scorri per respring", font: OldOSFont.bold(23), baseOpacity: 0.5)
                        .shadow(color: .black.opacity(0.6), radius: 1, x: 0, y: 1)
                }
            }
            .frame(width: width, height: height)
            .allowsHitTesting(false)

            // Red glossy knob with the white arrow (the whole "freccia" component).
            redArrowKnob(size: knobSize)
                .padding(inset)
                .offset(x: sliderOffset)
                .accessibilityLabel("Scorri per respring")
                .accessibilityHint("Trascina fino all'estremità destra per avviare il respring")
        }
        .frame(width: width, height: height)
        // Gesture on the whole track so it works reliably, including on launch.
        .contentShape(Rectangle())
        .highPriorityGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard !isRunning else { return }
                    let x = value.location.x - inset - knobSize / 2
                    sliderOffset = min(max(x, 0), travel)
                }
                .onEnded { _ in
                    guard !isRunning else { return }
                    if travel > 0 && sliderOffset >= travel * CGFloat(settings.threshold) {
                        settings.tap(.medium)
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                            sliderOffset = travel
                        }
                        armOrConfirm()
                    } else {
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.76)) {
                            sliderOffset = 0
                        }
                    }
                }
        )
    }

    /// The red glossy knob with the white arrow, as on the iOS 6 slide to power
    /// off. Glossy top half + darker bottom, dark red border, white arrow.
    private func redArrowKnob(size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(oldOS: [
                    OldOSStop(.oldOS(236, 96, 100), 0),
                    OldOSStop(.oldOS(212, 42, 48), 0.49),
                    OldOSStop(.oldOS(186, 16, 24), 0.5),
                    OldOSStop(.oldOS(200, 28, 34), 1)
                ]))
                .overlay(
                    // Glossy top-half sheen.
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LinearGradient(colors: [Color.white.opacity(0.45), .clear],
                                             startPoint: .top, endPoint: .center))
                        .padding(1)
                )
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.oldOS(130, 10, 16), lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 1.5, x: 0, y: 1)

            Text("⮕")
                .font(.custom("Helvetica Neue", fixedSize: size * 0.56))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 0, x: 0, y: -1)
        }
        .frame(width: size, height: size)
    }

    // MARK: - Cancel

    private func cancelButton(width: CGFloat) -> some View {
        Button {
            settings.tap()
            resetSlider()
        } label: {
            Text("Annulla")
                .font(OldOSFont.bold(20))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.7), radius: 0, x: 0, y: -1)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(iOS6GlossButton(type: buttonType))
        }
        .buttonStyle(.plain)
        .frame(width: width)
        .disabled(isRunning)
        .opacity(isRunning ? 0.4 : 1)
        .accessibilityLabel("Annulla e ripristina il cursore")
    }

    // MARK: - Behaviour

    private func armOrConfirm() {
        if settings.requireConfirmation {
            withAnimation(.easeIn(duration: 0.15)) { showingAlert = true }
        } else {
            onArmed()
        }
    }

    private func resetSlider() {
        guard !isRunning else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.76)) {
            sliderOffset = 0
        }
    }
}

// MARK: - iOS 6 glossy building blocks (drawn from the OldSafari palette)

/// iOS 6 glossy pill used for the cancel button — rounded rectangle.
private struct iOS6GlossButton: View {
    let type: OldOSButtonType
    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(oldOSButtonGradient(type))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .fill(LinearGradient(
                        colors: [Color.white.opacity(0.28), .clear],
                        startPoint: .top, endPoint: .center))
                    .padding(1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.black.opacity(0.65), lineWidth: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.75)
                    .padding(1)
            )
            .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 1)
    }
}

/// Same gloss, capsule shaped, used for the top "Respring" indicator.
private struct iOS6GlossCapsule: View {
    let type: OldOSButtonType
    var body: some View {
        Capsule()
            .fill(oldOSButtonGradient(type))
            .overlay(
                Capsule()
                    .fill(LinearGradient(
                        colors: [Color.white.opacity(0.26), .clear],
                        startPoint: .top, endPoint: .center))
                    .padding(1)
            )
            .overlay(Capsule().strokeBorder(Color.black.opacity(0.6), lineWidth: 1))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.75).padding(1))
            .shadow(color: .black.opacity(0.45), radius: 1, x: 0, y: 1)
    }
}

