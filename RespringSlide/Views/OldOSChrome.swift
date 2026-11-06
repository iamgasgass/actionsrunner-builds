import SwiftUI

/// Ported code-for-code from OldSafari's `OldOSTitleBar` (SafariControls.swift):
/// the bar gradient, the 1pt bottom hairline, the top inner-shadow highlight,
/// and the Helvetica Neue Bold 22 title with its hard `titleBarTitleShadow`.
///
/// The only addition is `topInset`, which lets the bar extend full-screen up
/// under the status bar / Dynamic Island on modern iOS, with the title kept
/// centred in the bottom 60pt (exactly OldSafari's bar height).
struct OldOSTitleBar: View {
    let title: String
    let theme: OldOSSafariTheme
    var topInset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(oldOS: theme.barGradient)
                .oldOSBorder(width: 1, edges: [.bottom], color: theme.barHairline)
                .oldOSInnerShadowBottom(color: theme.barHighlight, radius: 0.025)
                // Share-sheet style hairlines: white on top, black on bottom.
                .oldOSBorder(width: 1, edges: [.top], color: Color.white.opacity(0.22))
                .oldOSBorder(width: 1, edges: [.bottom], color: Color.black.opacity(0.7))

            // Hairline at the top of the visible bar (just below the status
            // bar), white over black — the same as elsewhere, above the title.
            VStack(spacing: 0) {
                Rectangle().fill(Color.white.opacity(0.22)).frame(height: 1)
                Rectangle().fill(Color.black.opacity(0.6)).frame(height: 1)
                Spacer(minLength: 0)
            }
            .frame(height: 60)

            Text(title)
                .font(OldOSFont.bold(22))
                .foregroundColor(theme.titleBarTitle)
                // Emboss (OldOS `ps_innerShadow(white, …0.07)`) + hard shadow.
                .shadow(color: theme.titleBarTitleEmboss, radius: 0, x: 0, y: 1)
                .shadow(color: theme.titleBarTitleShadow, radius: 0, x: 0, y: -1)
                .lineLimit(1)
                .frame(height: 60)
        }
        .frame(height: topInset + 60)
    }
}
