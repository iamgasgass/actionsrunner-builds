import SwiftUI
import UIKit

// MARK: - Panel pointer (verbatim from the OldSafari project)

/// Little triangle under the history panel, pointing at the control that
/// opened it. Copied 1:1 from OldSafari's `OldOSPanelPointer`.
struct OldOSPanelPointer: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - iOS 6 "…" toolbar button (OldSafari chrome)

/// The top-right "…" button in OldOS mode, drawn with the OldSafari iOS 6
/// sheet-metal button treatment (`OldOSRectangleButton` look: recessed bevel,
/// hard dark glyph shadow, white bottom highlight) instead of Liquid Glass.
struct OldOSEllipsisButton: View {
    var action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    /// Classic OldSafari aluminium in light mode, graphite in dark.
    private var type: OldOSButtonType { colorScheme == .dark ? .black : .gray }

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Text("•••")
                .font(OldOSFont.bold(15))
                .tracking(1)
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.75), radius: 1, x: 0, y: -0.25)
                .frame(width: 52, height: 32)
                .oldOSInnerShadowBackground(
                    RoundedRectangle(cornerRadius: 5.5),
                    oldOSButtonGradient(type),
                    radius: 0.8,
                    offset: CGPoint(x: 0, y: 0.6),
                    intensity: 0.7
                )
                .shadow(color: .white.opacity(0.28), radius: 0, x: 0, y: 0.8)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - iOS 6 dropdown (OldSafari history-panel style)

/// A dropdown styled exactly like OldSafari's back/forward history preview
/// panel (`SafariHistoryPreviewPanel`): the dark 2012 sheet-metal body, a
/// header strip, hairline-separated rows and a pointer triangle — here the
/// pointer sits at the top, aimed up at the "…" button that opened it.
struct OldOSThemeMenuPanel: View {
    let current: AppTheme
    let onSelect: (AppTheme) -> Void
    let onDismiss: () -> Void

    private let theme = OldOSSafariTheme.standard
    private let rowHeight: CGFloat = 46
    private let headerHeight: CGFloat = 30
    private let panelWidth: CGFloat = 248

    var body: some View {
        GeometryReader { geometry in
            let topInset = max(OldOSScreen.safeArea.top, 20)
            // Anchor the panel under the top-right "…" button.
            let right = geometry.size.width - 18
            let left = max(right - panelWidth, 12)
            let pointerX = right - 26 // roughly the button centre
            let top = topInset + 8 + 32 + 6 // below the button

            ZStack(alignment: .topLeading) {
                theme.scrim.opacity(0.4)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { onDismiss() }

                VStack(spacing: 0) {
                    // Pointer at the top, aimed up at the button.
                    OldOSPanelPointer()
                        .rotation(.degrees(180))
                        .fill(LinearGradient(oldOS: theme.shareStrip))
                        .frame(width: 20, height: 9)
                        .offset(x: pointerX - left - 10)
                        .frame(width: panelWidth, alignment: .leading)

                    panelBody
                }
                .frame(width: panelWidth)
                .offset(x: left, y: top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .ignoresSafeArea()
    }

    private var panelBody: some View {
        VStack(spacing: 0) {
            ZStack {
                Rectangle()
                    .fill(LinearGradient(oldOS: theme.shareStrip))
                    .oldOSInnerShadowBottom(color: Color.white.opacity(0.98), radius: 0.1)
                Text("Aspetto")
                    .font(OldOSFont.bold(13.25))
                    .foregroundColor(theme.panelTitleText)
                    .shadow(color: theme.panelTitleShadow, radius: 0, x: 0, y: theme.panelTitleShadowY)
            }
            .frame(height: headerHeight)

            ForEach(Array(AppTheme.allCases.enumerated()), id: \.element.id) { index, item in
                row(item, isLast: index == AppTheme.allCases.count - 1)
            }
        }
        .background(LinearGradient(oldOS: theme.shareBody))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .oldOSAddBorder(
            LinearGradient(oldOS: theme.shareButtonOuterStroke),
            width: 0.5,
            cornerRadius: 12
        )
        .shadow(color: Color.black.opacity(0.5), radius: 14, x: 0, y: 5)
    }

    private func row(_ item: AppTheme, isLast: Bool) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onSelect(item)
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: item.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Color.white.opacity(0.5))
                        .frame(width: 20)

                    Text(item.title)
                        .font(OldOSFont.bold(16))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Image(systemName: item == current ? "checkmark" : "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Color.white.opacity(item == current ? 0.95 : 0.35))
                }
                .padding([.leading, .trailing], 14)
                .frame(height: rowHeight - 1)

                Rectangle()
                    .fill(Color.white.opacity(isLast ? 0 : 0.09))
                    .frame(height: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - OldOS skeuomorphic alert (ported code-for-code from OldOS `skeumorphic_alert`)

/// A faithful port of OldOS' `skeumorphic_alert` (OldOS/Common.swift): the same
/// navy rounded panel, aluminium 2pt stroke, `top_gloss` sheen, Helvetica Neue
/// title/subtitle and glossy button — the only additions are a second button
/// (styled identically to the original OK button) so the respring can be
/// confirmed/cancelled, and the OldSafari dark-mode graphite variant, applied
/// when dark mode is active.
struct OldOSAlertView: View {
    let title: String
    let message: String
    let cancelTitle: String
    let confirmTitle: String
    var isDark: Bool = true           // OldSafari dark mode, active here.
    let onCancel: () -> Void
    let onConfirm: () -> Void

    /// OldOS navy, or the OldSafari private-browsing graphite in dark mode.
    private var panelFill: Color {
        isDark ? .oldOS(26, 27, 30) : .oldOS(11, 27, 68)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.55).ignoresSafeArea()

                VStack {
                    Spacer()
                    ZStack {
                        // Panel: fill + aluminium stroke + drop shadow (OldOS values).
                        RoundedRectangle(cornerRadius: 12)
                            .fill(panelFill)
                            .opacity(0.85)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(
                                        LinearGradient(oldOS: [
                                            OldOSStop(.oldOS(226, 227, 228), 0),
                                            OldOSStop(.oldOS(178, 183, 194), 0.19)
                                        ]),
                                        lineWidth: 2
                                    )
                            )
                            .shadow(color: Color.black.opacity(0.75), radius: 3, x: 0, y: 2)

                        // Top gloss (OldOS `top_gloss`), clipped to the top corners.
                        VStack {
                            OldOSTopGloss(length: geometry.size.width - 60)
                                .fill(LinearGradient(oldOS: [
                                    OldOSStop(.white, 0.2),
                                    OldOSStop(.oldOS(80, 84, 89), 1)
                                ]))
                                .frame(height: 45)
                                .clipShape(OldOSRoundedCorner(radius: 12, corners: [.topLeft, .topRight]))
                                .opacity(0.30)
                            Spacer()
                        }

                        VStack(alignment: .center) {
                            Text(title)
                                .font(OldOSFont.bold(18))
                                .foregroundColor(.white)
                                .shadow(color: Color.black.opacity(0.80), radius: 0, x: 0, y: -1.2)
                                .multilineTextAlignment(.center)
                                .padding(.top, 15)

                            Spacer()

                            Text(message)
                                .font(OldOSFont.regular(14.5))
                                .foregroundColor(.white)
                                .shadow(color: Color.black.opacity(0.80), radius: 0, x: 0, y: -1.2)
                                .multilineTextAlignment(.center)
                                .padding([.leading, .trailing], 10)
                                .padding(.bottom, 5)

                            Spacer()

                            // Two buttons, each in the exact original OK-button style.
                            HStack(spacing: 8) {
                                okStyleButton(cancelTitle, action: onCancel)
                                okStyleButton(confirmTitle, action: onConfirm)
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding([.leading, .trailing], 30)
                    Spacer()
                }
            }
        }
        .clipped()
    }

    /// Verbatim styling of OldOS' alert OK button, reused for both actions.
    private func okStyleButton(_ text: String, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(LinearGradient(oldOS: [
                        OldOSStop(.oldOS(214, 214, 214), 0),
                        OldOSStop(.oldOS(113, 115, 119), 0.49),
                        OldOSStop(.oldOS(74, 75, 78), 0.50),
                        OldOSStop(.oldOS(102, 103, 106), 1)
                    ]))
                    .shadow(color: Color.white.opacity(0.2), radius: 0, x: 0, y: 0.5)
                    .opacity(0.80)
                    .blendMode(.screen)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.oldOS(19, 30, 58), lineWidth: 1)
                    )
                    .frame(height: 40)
                    .padding(.bottom, 8)
                    .padding([.leading, .trailing], 8)

                Text(text)
                    .font(OldOSFont.bold(18))
                    .foregroundColor(.white)
                    .shadow(color: Color.black.opacity(0.80), radius: 0, x: 0, y: -1.2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .padding(.bottom, 8)
                    .padding([.leading, .trailing], 10)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - OldOS alert shape helpers (ported)

/// Port of OldOS' `top_gloss` shape.
struct OldOSTopGloss: Shape {
    var length: CGFloat
    var startX: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let midPoint: CGFloat = (startX + length) / 2
        path.move(to: CGPoint(x: midPoint, y: 0))
        path.addLine(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: 20))
        path.addQuadCurve(to: CGPoint(x: length, y: 20), control: CGPoint(x: midPoint, y: 40))
        path.addLine(to: CGPoint(x: length, y: 0))
        path.closeSubpath()
        return path
    }
}

/// Rounds only the given corners, replacing OldOS' `cornerRadiusSpecific`.
struct OldOSRoundedCorner: Shape {
    var radius: CGFloat
    var corners: UIRectCorner

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}
