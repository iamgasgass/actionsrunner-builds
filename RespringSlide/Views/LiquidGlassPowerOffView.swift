import SwiftUI

/// The "Liquid Glass" skin: the iOS 27-style slide-to-power-off control drawn
/// entirely with the native SwiftUI `glassEffect(…)` material. The track uses
/// the fully transparent `.clear` variant, so it is see-through like the
/// iOS 27.0.1 power-off slider. The label sits above the glass (not inside it)
/// so the glass does not refract/ghost the text onto the top and bottom edges.
///
/// A light and a dark version are provided (following the app appearance): the
/// background and glyph colours flip, while the glass adapts on its own.
struct LiquidGlassPowerOffView: View {
    let isRunning: Bool
    let onArmed: () -> Void

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    @State private var sliderOffset: CGFloat = 0
    @State private var showingConfirmation = false

    private let labelFont = Font.system(size: 22, weight: .regular, design: .default)

    private var isDark: Bool { colorScheme == .dark }
    private var background: Color { isDark ? .black : Color(white: 0.95) }
    private var glyphColor: Color { isDark ? .white : Color(white: 0.12) }
    private var vignette: Color { isDark ? Color.white.opacity(0.035) : Color.black.opacity(0.04) }

    var body: some View {
        // Same mechanism as the native Settings: a NavigationStack with a large
        // navigation title, so the "RespringSlide" header is literally the
        // native large title.
        NavigationStack {
            GeometryReader { geometry in
                let w = geometry.size.width
                let trackWidth = min(w - 44, 560)
                let trackHeight: CGFloat = 74

                ZStack {
                    background.ignoresSafeArea()

                    RadialGradient(
                        colors: [vignette, .clear],
                        center: .top,
                        startRadius: 12,
                        endRadius: geometry.size.height * 0.72
                    )
                    .ignoresSafeArea()

                    VStack(spacing: 0) {
                        respringIndicator
                            .padding(.top, 12)

                        slideControl(width: trackWidth, height: trackHeight)
                            .padding(.top, 26)

                        Spacer(minLength: 0)

                        cancelButton
                            .frame(width: 64, height: 64)
                            .padding(.bottom, 20)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .confirmationDialog(
                    "Avviare il respring?",
                    isPresented: $showingConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Avvia respring", role: .destructive) {
                        onArmed()
                    }
                    Button("Annulla", role: .cancel) {
                        resetSlider()
                    }
                } message: {
                    Text("La tecnica può bloccare WebKit o riavviare SpringBoard, ma non è garantita su ogni versione di iOS. Salva prima il tuo lavoro.")
                }
            }
            .navigationTitle("RespringSlide")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(.hidden, for: .navigationBar)
        }
    }

    /// The top bubble, same "⟳ Respring" content as the OldOS skin, rendered in
    /// the native Liquid Glass material.
    private var respringIndicator: some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 14, weight: .semibold))
            Text("Respring")
                .font(.system(size: 16, weight: .semibold))
        }
        .foregroundStyle(glyphColor.opacity(0.92))
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: Capsule())
        .accessibilityLabel("Respring")
    }

    private func slideControl(width: CGFloat, height: CGFloat) -> some View {
        let knobInset: CGFloat = 4
        let knobSize = height - knobInset * 2
        let travel = max(0, width - knobSize - knobInset * 2)

        return ZStack(alignment: .leading) {
            // Fully transparent Liquid Glass track (iOS 27-style clear glass).
            Capsule()
                .glassEffect(.clear, in: Capsule())
                .accessibilityHidden(true)

                // Single centred label with a continuous shine.
                Group {
                    if isRunning {
                        Text("Respring in corso")
                            .font(labelFont)
                            .foregroundStyle(glyphColor.opacity(0.86))
                            .lineLimit(1)
                    } else {
                        ShineText(
                            text: "Scorri per respring",
                            font: labelFont,
                            baseOpacity: isDark ? 0.38 : 0.45,
                            textColor: glyphColor,
                            shineColor: isDark ? .white : .white
                        )
                    }
                }
                .frame(width: width, height: height)
                .allowsHitTesting(false)

                ZStack {
                    Image(systemName: "power")
                        .font(.system(size: 28, weight: .regular))
                        .foregroundStyle(glyphColor)
                }
                .frame(width: knobSize, height: knobSize)
                .glassEffect(.regular.interactive(), in: Circle())
                .padding(knobInset)
                .offset(x: sliderOffset)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard !isRunning else { return }
                            sliderOffset = min(max(value.translation.width, 0), travel)
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
                .accessibilityLabel("Scorri per respring")
                .accessibilityHint("Trascina il pulsante circolare fino all'estremità destra")
        }
        .frame(width: width, height: height)
    }

    /// The glass X cancel button, identical Liquid Glass material as the thumb.
    private var cancelButton: some View {
        Button(action: resetSlider) {
            Image(systemName: "xmark")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(glyphColor.opacity(0.96))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(isRunning)
        .opacity(isRunning ? 0.35 : 1)
        .accessibilityLabel("Annulla e ripristina il cursore")
    }

    private func armOrConfirm() {
        if settings.requireConfirmation {
            showingConfirmation = true
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
