// SPDX-License-Identifier: GPL-2.0-or-later

#if FEEDBACK_MAIL

import AndariumCore
import SwiftUI

/// The line at the top of Send feedback's mail, before anything is written:
/// the question a person asks when Android has no Google apps ("Missing Google
/// apps?") and the answer one tap away, opened in place. It is there, closed,
/// whenever the sheet opens, goes from that sheet when the person closes it, and
/// never stands in the way of the mail. Its words are in the `Feedback` table, and the Google name
/// is the notice's own (`NoGoogleBootNote`).
struct NoGoogleFeedbackLine: View {
    /// The sheet's model, which holds whether the line is open (`SendFeedbackModel.noGoogleAnswerOpen`).
    let model: SendFeedbackModel

    private enum Words {
        static let question = String(localized: "Missing Google apps?", table: "Feedback")
        static let short = String(localized: "That\u{2019}s on purpose.", table: "Feedback")
        static let answer = String(
            localized: "Google licenses its apps and Google Play services only to makers of certified devices. Install apps from files you have; many work without them.",
            table: "Feedback")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "shippingbox.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                if model.noGoogleAnswerOpen {
                    Text(Words.question.keepingTogether)
                        .font(.subheadline.weight(.semibold))
                    Text(Words.short.keepingTogether)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(Words.answer.keepingTogether)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Button {
                        withAnimation(.snappy) { model.openNoGoogleAnswer() }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(Words.question.keepingTogether)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(Self.collapsed)
                                .font(.footnote)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Shows the answer", tableName: "Feedback"))
                    .accessibilityIdentifier("no-google-feedback-open")
                }
            }
            .accessibilityElement(children: model.noGoogleAnswerOpen ? .combine : .contain)
            Spacer(minLength: 0)
            Button {
                withAnimation(.snappy) { model.closeNoGoogleLine() }
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
                    // The target is 44 pt; the layout keeps the 28 pt the glyph's slot had.
                    .padding(-8)
            }
            .buttonStyle(.plain)
            // Not "Dismiss" alone: the bug-report card in the same sheet has that one.
            .accessibilityLabel(Text("Dismiss Google apps note", tableName: "Feedback"))
            .accessibilityIdentifier("no-google-feedback-close")
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.10), in: .rect(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("no-google-feedback-line")
    }

    /// "That's on purpose. Why": the answer's first words and the way to the
    /// rest, in the accent colour. One string, so each language keeps its own
    /// punctuation and spacing between the two; the way to the rest is the
    /// "Why" inside it.
    static var collapsed: AttributedString {
        let way = String(localized: "Why", table: "Feedback")
        var line = AttributedString(String(localized: "That\u{2019}s on purpose. Why", table: "Feedback"))
        line.foregroundColor = .secondary
        if let range = line.range(of: way, options: .backwards) {
            line[range].foregroundColor = .accentColor
            line[range].font = .footnote.weight(.semibold)
        }
        return line
    }
}

#endif
