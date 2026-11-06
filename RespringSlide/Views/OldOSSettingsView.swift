import SwiftUI
import UIKit

/// The Settings section in classic iOS 6 / OldOS style (used when the OldOS
/// skin is active). It follows the app appearance (light = OldSafari standard
/// aluminium, dark = OldSafari private-browsing graphite), has a full-screen
/// title bar that extends under the status bar (optimised for modern iOS), and
/// uses the OldOS switch (`toggle`) and an iOS 6 slider.
struct OldOSSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    private var theme: OldOSSafariTheme {
        OldOSSafariTheme.theme(isPrivate: colorScheme == .dark)
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        let topInset = max(OldOSScreen.safeArea.top, 20)

        ZStack {
            theme.groupedBackground.ignoresSafeArea()
            OldOSPinstripeBackground(line: theme.groupedPinstripe)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                OldOSTitleBar(title: "Impostazioni", theme: theme, topInset: topInset)

                ScrollView {
                    VStack(spacing: 0) {
                        appearanceSection
                        interfaceSection
                        respringSection
                        resetSection
                        infoSection
                    }
                    .padding(.vertical, 14)
                }
                .scrollIndicators(.hidden)
            }
            .ignoresSafeArea(edges: .top)
        }
    }

    // MARK: Sections

    private var appearanceSection: some View {
        section(header: "ASPETTO", footer: "“Sistema” segue iOS; “Chiaro” e “Scuro” forzano l'aspetto dell'app.") {
            ForEach(Array(AppAppearance.allCases.enumerated()), id: \.element.id) { index, option in
                checkRow(title: option.title,
                         selected: settings.appearance == option,
                         isLast: index == AppAppearance.allCases.count - 1) {
                    settings.tap()
                    settings.appearance = option
                }
            }
        }
    }

    private var interfaceSection: some View {
        section(header: "INTERFACCIA", footer: settings.skin == .oldOS
                ? "OldOS: UI iOS 6 in tutta l'app."
                : "Liquid Glass: l'interfaccia nativa di iOS 27.") {
            ForEach(Array(AppTheme.allCases.enumerated()), id: \.element.id) { index, skin in
                checkRow(title: skin.title,
                         selected: settings.skin == skin,
                         isLast: index == AppTheme.allCases.count - 1) {
                    settings.tap()
                    settings.skin = skin
                }
            }
        }
    }

    private var respringSection: some View {
        section(header: "RESPRING", footer: "Quanto lontano trascinare per attivare il respring. Con la conferma, dopo lo slider appare un avviso.") {
            toggleRow(title: "Chiedi conferma", isOn: $settings.requireConfirmation, isLast: false)
            toggleRow(title: "Feedback aptico", isOn: $settings.haptics, isLast: false)
            sliderRow(isLast: true)
        }
    }

    private var resetSection: some View {
        VStack(spacing: 0) {
            Button {
                settings.tap(.medium)
                settings.requireConfirmation = true
                settings.haptics = true
                settings.threshold = 0.84
                settings.appearance = .system
                settings.skin = .liquidGlass
            } label: {
                Text("Ripristina impostazioni")
                    .font(OldOSFont.bold(17))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.4), radius: 0, x: 0, y: -0.5)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(oldOSButtonGradient(.red))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(LinearGradient(colors: [Color.white.opacity(0.28), .clear],
                                                         startPoint: .top, endPoint: .center))
                                    .padding(1)
                            )
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.oldOS(120, 10, 16), lineWidth: 1))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
        }
        .padding(.bottom, 22)
    }

    private var infoSection: some View {
        section(header: "INFORMAZIONI", footer: "La tecnica di respring è sperimentale (WebKit): può bloccare WebKit, riavviare SpringBoard o non fare nulla, e non è garantita. Salva il tuo lavoro. Non è un'API supportata da Apple.") {
            valueRow(title: "Versione", value: appVersion, isLast: false)
            valueRow(title: "Autore", value: "iamgasgass", isLast: true)
        }
    }

    // MARK: Building blocks

    @ViewBuilder
    private func section<Content: View>(header: String?, footer: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header {
                Text(header)
                    .font(OldOSFont.bold(13))
                    .foregroundColor(theme.sectionHeader)
                    .shadow(color: colorScheme == .dark ? .black.opacity(0.6) : .white.opacity(0.6),
                            radius: 0, x: 0, y: colorScheme == .dark ? -1 : 1)
                    .padding(.leading, 26)
                    .padding(.bottom, 6)
            }

            VStack(spacing: 0) { content() }
                .background(theme.cardFill)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .oldOSStrokeRoundedRectangle(10, theme.cardStroke, lineWidth: 1)
                .padding(.horizontal, 14)

            if let footer {
                Text(footer)
                    .font(OldOSFont.regular(12))
                    .foregroundColor(theme.sectionHeader.opacity(0.9))
                    .shadow(color: colorScheme == .dark ? .black.opacity(0.5) : .white.opacity(0.5),
                            radius: 0, x: 0, y: colorScheme == .dark ? -1 : 1)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 26)
                    .padding(.top, 6)
            }
        }
        .padding(.bottom, 22)
    }

    private func rowSeparator(_ isLast: Bool) -> some View {
        Rectangle().fill(theme.listSeparator).frame(height: isLast ? 0 : 1)
    }

    private func checkRow(title: String, selected: Bool, isLast: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 0) {
                HStack {
                    Text(title).font(OldOSFont.bold(17)).foregroundColor(theme.listRowText)
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(theme.cardFieldText)
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                rowSeparator(isLast)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleRow(title: String, isOn: Binding<Bool>, isLast: Bool) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(OldOSFont.bold(17)).foregroundColor(theme.listRowText)
                Spacer()
                OldOSToggle(isOn: isOn)
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            rowSeparator(isLast)
        }
    }

    private func sliderRow(isLast: Bool) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text("Soglia di scorrimento").font(OldOSFont.bold(17)).foregroundColor(theme.listRowText)
                Spacer()
                Text("\(Int(settings.threshold * 100))%")
                    .font(OldOSFont.regular(15)).foregroundColor(theme.listRowDetail).monospacedDigit()
            }
            OldOSSlider(value: $settings.threshold, in: 0.6...0.95)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func valueRow(title: String, value: String, isLast: Bool) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(OldOSFont.bold(17)).foregroundColor(theme.listRowText)
                Spacer()
                Text(value).font(OldOSFont.regular(16)).foregroundColor(theme.listRowDetail)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            rowSeparator(isLast)
        }
    }
}

// MARK: - OldOS switch (ported from OldOS `toggle`, Common.swift)

/// The classic iOS 6 ON/OFF switch, with the exact OldOS gradients: a blue "ON"
/// side, a grey "OFF" side, the metallic sliding knob and the ON/OFF labels.
struct OldOSToggle: View {
    @Binding var isOn: Bool

    private let w: CGFloat = 104
    private let h: CGFloat = 30
    private let knobW: CGFloat = 46

    private let blue = LinearGradient(oldOS: [
        OldOSStop(.oldOS(52, 123, 245), 0.0),
        OldOSStop(.oldOS(53, 126, 247), 0.5),
        OldOSStop(.oldOS(101, 161, 249), 1.0)
    ])
    private let grey = LinearGradient(oldOS: [
        OldOSStop(.oldOS(232, 232, 232), 0.0),
        OldOSStop(.oldOS(235, 235, 235), 0.5),
        OldOSStop(.oldOS(251, 251, 251), 1.0)
    ])
    private let knobFill = LinearGradient(oldOS: [
        OldOSStop(.oldOS(254, 254, 254), 0),
        OldOSStop(.oldOS(208, 208, 208), 1)
    ])
    private let knobBorder = LinearGradient(oldOS: [
        OldOSStop(.oldOS(136, 135, 135), 0),
        OldOSStop(.oldOS(183, 182, 182), 1)
    ])

    var body: some View {
        let travel = w - knobW
        let x: CGFloat = isOn ? travel : 0

        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4).fill(grey)

            // Blue fills from the left up to the knob's right edge.
            Rectangle().fill(blue)
                .frame(width: x + knobW)

            Text("ON")
                .font(.custom("Helvetica Neue Bold", fixedSize: 18))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.45), radius: 0.34, x: 0, y: -1.25)
                .padding(.leading, 13)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("OFF")
                .font(.custom("Helvetica Neue Bold", fixedSize: 18))
                .foregroundColor(.oldOS(125, 125, 125))
                .shadow(color: .white.opacity(0.84), radius: 2, x: 0, y: 2)
                .padding(.trailing, 12)
                .frame(maxWidth: .infinity, alignment: .trailing)

            RoundedRectangle(cornerRadius: 4)
                .fill(knobFill)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(knobBorder, lineWidth: 0.5))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.gray.opacity(0.4), lineWidth: 0.25))
                .frame(width: knobW, height: h)
                .offset(x: x)
        }
        .frame(width: w, height: h)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray, lineWidth: 0.25))
        .contentShape(Rectangle())
        .onTapGesture {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) { isOn.toggle() }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? "Attivo" : "Disattivo")
    }
}

// MARK: - iOS 6 slider

/// An iOS 6 / OldOS-style slider: a recessed grey track with a blue left fill
/// and a metallic round knob.
struct OldOSSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    init(value: Binding<Double>, in range: ClosedRange<Double>) {
        self._value = value
        self.range = range
    }

    private let knob: CGFloat = 28
    private let trackHeight: CGFloat = 11

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let span = range.upperBound - range.lowerBound
            let frac = span > 0 ? CGFloat((value - range.lowerBound) / span) : 0
            let x = frac * (w - knob)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(oldOS: [OldOSStop(.oldOS(150, 150, 152), 0), OldOSStop(.oldOS(196, 196, 198), 1)]))
                    .overlay(Capsule().strokeBorder(Color.black.opacity(0.22), lineWidth: 0.75))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(LinearGradient(oldOS: [OldOSStop(.oldOS(92, 170, 236), 0), OldOSStop(.oldOS(42, 128, 226), 1)]))
                    .frame(width: max(trackHeight, x + knob / 2), height: trackHeight)

                Circle()
                    .fill(LinearGradient(oldOS: [OldOSStop(.white, 0), OldOSStop(.oldOS(214, 214, 216), 1)]))
                    .overlay(Circle().strokeBorder(Color.oldOS(120, 122, 128), lineWidth: 0.75))
                    .shadow(color: .black.opacity(0.35), radius: 1, x: 0, y: 1)
                    .frame(width: knob, height: knob)
                    .offset(x: x)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let nx = min(max(0, v.location.x - knob / 2), w - knob)
                        let f = (w - knob) > 0 ? Double(nx / (w - knob)) : 0
                        value = range.lowerBound + f * span
                    }
            )
        }
        .frame(height: 30)
    }
}
