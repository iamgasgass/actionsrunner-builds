// SPDX-License-Identifier: GPL-2.0-or-later

#if TIP_JAR

import SwiftUI

// Buy me tokens. The sheet is a short conversation with Andarium's developer:
// the joke in three bubbles, the plain statement as the centred note a chat
// uses for what is not a message, and the four tiers as reply chips under the
// thumb. A tip is the person's reply and the thank-you the developer's answer;
// after it the tiers are not offered again and Done is the one control.
// Problems are centred notes, never the developer's voice. Nothing here is
// kept when the sheet closes.

#if !APP_STORE
/// The Simulator preview opens the sheet at the full height of a page, taller than its conversation, to
/// show where a short conversation stands.
private struct TipJarFullHeightKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var tipJarFullHeight: Bool {
        get { self[TipJarFullHeightKey.self] }
        set { self[TipJarFullHeightKey.self] = newValue }
    }
}
#endif

struct TipJarSheet: View {
    let jar: TipJarModel
    /// The developer the header shows.
    let sender: TipJarSenderContent
    /// "iPhone" or "iPad", for the note when purchases are not allowed.
    let device: String
    let close: () -> Void
    #if !APP_STORE
    @Environment(\.tipJarFullHeight) private var fullHeight
    #else
    private let fullHeight = false
    #endif
    /// The conversation's and the bar's heights: the sheet is as tall as they
    /// are, and grows as the conversation does.
    @State private var conversationHeight: CGFloat = 400
    @State private var barHeight: CGFloat = 130
    /// Where the conversation is scrolled: left to the anchors until the conversation grows.
    @State private var position = ScrollPosition()

    /// The conversation, the bar, the navigation bar and the grabber.
    private var fittedHeight: CGFloat { conversationHeight + barHeight + 78 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    TipJarSender(content: sender)
                        .padding(.bottom, 2)
                    TipJarBubble(text: TipJarWords.coffee, first: true)
                    TipJarBubble(text: TipJarWords.tokens)
                    TipJarBubble(text: TipJarWords.invitation)
                    TipJarNote(text: Text(TipJarWords.statement))
                        .padding(.vertical, 12)
                    replies
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
                .animation(.snappy, value: jar.outcome)
                .animation(.snappy, value: jar.purchasing)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    conversationHeight = height
                }
            }
            // A conversation longer than the sheet opens at its end and follows it as it grows; one
            // shorter than the sheet stands at the top, under the title, and is not centred or pushed
            // down to the bar.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .defaultScrollAnchor(.top, for: .alignment)
            // A conversation that fitted and now overflows (the person's reply, then the thank-you)
            // follows its newest bubble: the anchors above only keep a bottom that was already in
            // view, and do not act on a conversation that began shorter than the sheet.
            .scrollPosition($position)
            .onChange(of: jar.outcome) { followTheEnd() }
            .onChange(of: jar.purchasing) { followTheEnd() }
            .background(Color(.systemBackground))
            .navigationTitle(Text(TipJarWords.name))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { TipJarTitle() }
                // The system's close button, with no label of ours: the system draws the cross and
                // names it in the person's language. A full-height sheet on the folding iPhone's cover
                // has such buttons moved into the column beside the camera by itself.
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close, action: close)
                        .accessibilityIdentifier("tipjar-close-bar")
                }
            }
            .safeAreaBar(edge: .bottom) {
                TipJarBar(jar: jar, close: close)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        barHeight = height
                    }
            }
        }
        .presentationDetents(fullHeight ? [.large] : [.height(fittedHeight)])
        .presentationSizing(FixedSheetSizing(width: 600, height: fullHeight ? 2000 : fittedHeight))
        .accessibilityIdentifier("tipjar-sheet")
        .task { jar.start() }
    }

    private func followTheEnd() {
        position.scrollTo(edge: .bottom)
    }

    /// What follows the person's choice, and the problems, which are notes.
    @ViewBuilder
    private var replies: some View {
        if let tier = jar.purchasing ?? jar.outcome?.tier, let offer = jar.offer(for: tier) {
            TipJarReply(offer: offer, sending: jar.purchasing == tier)
                .padding(.bottom, 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        switch jar.outcome {
        case .thanks?:
            TipJarSender(content: sender, links: false).padding(.top, 4)
            TipJarBubble(text: TipJarWords.thanksTitle, first: true)
                .transition(.opacity)
            TipJarBubble(text: TipJarWords.thanksText)
                .transition(.opacity)
        case .pending?:
            TipJarNote(
                text: Text(TipJarWords.pendingText), title: Text(TipJarWords.pendingTitle), symbol: "clock.fill",
                color: .orange)
        case .failed(_, let message)?:
            TipJarNote(
                text: Text(verbatim: message), title: Text(TipJarWords.failedTitle),
                symbol: "exclamationmark.triangle.fill", color: .red)
        case nil:
            if !jar.canMakePayments {
                TipJarNote(
                    title: Text(TipJarWords.restrictedTitle(device: device)), symbol: "hand.raised.fill",
                    color: .secondary)
            } else if jar.phase == .unavailable {
                TipJarNote(
                    text: Text(TipJarWords.unavailableText), title: Text(TipJarWords.unavailableTitle),
                    symbol: "icloud.slash", color: .secondary)
            }
        }
    }
}

/// The developer's bubble.
private struct TipJarBubble: View {
    let text: LocalizedStringResource
    var first = false

    var body: some View {
        Text(text)
            .font(.body)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color(.secondarySystemBackground), in: bubbleShape(leadingTail: first))
            .frame(maxWidth: 520, alignment: .leading)
            .padding(.trailing, 48)
    }

    /// A sharper top leading corner on the first of a run, as a chat draws the
    /// bubble nearest its sender.
    private func bubbleShape(leadingTail: Bool) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: leadingTail ? 6 : 18, bottomLeadingRadius: 18, bottomTrailingRadius: 18,
            topTrailingRadius: 18, style: .continuous)
    }
}

/// The person's reply: the tier they chose and its price, with a spinner while
/// the store works.
private struct TipJarReply: View {
    let offer: TipJarOffer
    let sending: Bool

    var body: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 48)
            if sending {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text(TipJarWords.waiting))
            }
            Text(verbatim: "\(offer.tier.name) \u{00B7} \(offer.price)")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color.accentColor, in: .rect(cornerRadius: 18))
                .opacity(sending ? 0.7 : 1)
                .accessibilityLabel(Text(verbatim: "\(offer.tier.name), \(offer.price)"))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityIdentifier("tipjar-reply")
    }
}

/// A centred note: the plain statement, and every problem or wait.
private struct TipJarNote: View {
    var text: Text?
    var title: Text?
    var symbol: String?
    var color: Color = .secondary

    var body: some View {
        VStack(spacing: 3) {
            if let title {
                HStack(spacing: 5) {
                    if let symbol {
                        Image(systemName: symbol)
                            .foregroundStyle(color)
                            .accessibilityHidden(true)
                    }
                    title
                }
                .font(.footnote.weight(.semibold))
            }
            if let text {
                text
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// What stands under the conversation: the four tiers as reply chips, two by
/// two; Try again when the store gave
/// nothing; Done alone after the thank-you; nothing when purchases are not
/// allowed and no prices came.
private struct TipJarBar: View {
    let jar: TipJarModel
    let close: () -> Void

    var body: some View {
        Group {
            if jar.thanked {
                Button(action: close) {
                    Text(TipJarWords.done).frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .accessibilityIdentifier("tipjar-done")
            } else if jar.canRetry {
                Button { jar.retry() } label: {
                    Text(TipJarWords.retry).frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .accessibilityIdentifier("tipjar-retry")
            } else {
                let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 2)
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(jar.shownTiers) { tier in
                        chip(tier)
                    }
                }
            }
        }
        .frame(maxWidth: 600)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .background {
            TipJarBarFade(color: Color(.systemBackground))
        }
    }

    private func chip(_ tier: TipJarTier) -> some View {
        let offer = jar.offer(for: tier)
        let enabled = jar.canBuy(tier) || jar.purchasing == tier
        let name = Text(verbatim: tier.name).font(.body.weight(.semibold))
        let price = Group {
            if let offer {
                Text(verbatim: offer.price)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text(TipJarWords.loadingPrice))
            }
        }
        return Button { jar.purchase(tier) } label: {
            // A long price goes under the name rather than being cut.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    name
                    Spacer(minLength: 4)
                    price
                }
                .lineLimit(1)
                VStack(alignment: .leading, spacing: 0) {
                    name
                    price.font(.subheadline)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .frame(minHeight: 48)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(enabled ? .regular.interactive() : .regular, in: .capsule)
        .opacity(enabled ? 1 : 0.45)
        .disabled(!enabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: offer.map { "\(tier.name), \($0.price)" } ?? tier.name))
        .accessibilityHint(Text(TipJarWords.chipHint))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("tipjar-tier-\(tier.rawValue)")
    }
}

/// What a bar at the foot of a sheet stands on, as Start does on Home: the page
/// fades out under it instead of showing through.
private struct TipJarBarFade: View {
    let color: Color

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: color.opacity(0), location: 0),
                .init(color: color.opacity(0.92), location: 0.3),
                .init(color: color, location: 1),
            ],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(false)
    }
}

/// The sheet's title with the menu item's icon before it.
private struct TipJarTitle: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: TipJarSymbols.menuItem)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(TipJarWords.name)
                .font(.headline)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

#endif
