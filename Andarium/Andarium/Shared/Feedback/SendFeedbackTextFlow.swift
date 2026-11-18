// SPDX-License-Identifier: GPL-2.0-or-later

#if FEEDBACK_MAIL

import AndariumCore
import SwiftUI

// A text read as one page that scrolls on: the windows of the reader come in as the person nears them, a few
// are held at a time, and a thumb on the trailing edge goes anywhere in the text and says where while it is
// held. The text is plain: lines of text and nothing a tap opens.

/// The windows of a text that are held, as lines, and how they move as the person scrolls or jumps.
@MainActor @Observable
final class SendFeedbackTextFlow {
    struct Line: Identifiable, Equatable, Sendable {
        /// The window the line is in and its place there: `window << shift | place`.
        let id: Int
        let text: String
    }

    nonisolated static let shift = 20

    let reader: SendFeedbackTextReader
    private(set) var lines: [Line] = []
    private(set) var failed = false
    private var blocks: [Int: [Line]] = [:]
    /// More windows than this held: the ones far from where the person is are let go.
    private static let heldMost = 6
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var wanted = 0
    /// Counts the jumps: what a read that began before a jump brings is not used.
    @ObservationIgnored private var epoch = 0

    init(reader: SendFeedbackTextReader) {
        self.reader = reader
    }

    var windowCount: Int { reader.windowCount }
    var byteCount: UInt64 { reader.byteCount }

    nonisolated static func window(of line: Int) -> Int { line >> shift }

    /// Whether the line is one of the lines held: a report of what is in view that was made before a jump names
    /// lines that are gone, and says nothing of where the person is.
    func holds(_ line: Int) -> Bool {
        let window = Self.window(of: line)
        return line & ((1 << Self.shift) - 1) < (blocks[window]?.count ?? 0)
    }

    /// The window and the ones next to it, held.
    func open() async {
        _ = await ensure(around: 0)
    }

    /// Holds the window `window` and the ones next to it. Returns true when lines above the ones that were
    /// in view came or went, so that the view puts what it showed back in place.
    func ensure(around window: Int) async -> Bool {
        wanted = window
        guard !busy, !failed else { return false }
        busy = true
        defer { busy = false }
        let mine = epoch
        let before = blocks.keys.min()
        while mine == epoch, !failed {
            let center = wanted
            let near = max(0, center - 1)...min(windowCount - 1, center + 1)
            guard let next = near.first(where: { blocks[$0] == nil }) else { break }
            do {
                let read = try await reader.window(next)
                guard mine == epoch else { return false }
                blocks[next] = Self.lines(of: read)
            } catch is CancellationError {
                return false
            } catch {
                failed = true
            }
        }
        guard mine == epoch else { return false }
        if blocks.count > Self.heldMost {
            for index in blocks.keys where index < wanted - 2 || index > wanted + 2 { blocks[index] = nil }
        }
        rebuild()
        return before != nil && blocks.keys.min() != before
    }

    /// Goes to `fraction` of the text, 0 to 1: holds the windows there and returns the line to scroll to.
    func jump(to fraction: Double) async -> Int? {
        epoch += 1
        let mine = epoch
        let at = min(max(0, fraction), 1) * Double(byteCount)
        let window = min(windowCount - 1, Int(at / Double(reader.windowBytes)))
        let place = (at - Double(window) * Double(reader.windowBytes)) / Double(span(of: window))
        var fresh: [Int: [Line]] = [:]
        do {
            for index in max(0, window - 1)...min(windowCount - 1, window + 1) {
                let read = try await reader.window(index)
                guard mine == epoch else { return nil }
                fresh[index] = Self.lines(of: read)
            }
        } catch is CancellationError {
            return nil
        } catch {
            failed = true
            return nil
        }
        blocks = fresh
        wanted = window
        rebuild()
        let here = fresh[window] ?? []
        if !here.isEmpty { return here[min(here.count - 1, max(0, Int(place * Double(here.count))))].id }
        // A window with no line of its own (one line that is longer): the line after it.
        return lines.first { Self.window(of: $0.id) > window }?.id ?? lines.last?.id
    }

    /// Where a line is in the whole text, 0 to 1, as bytes.
    func fraction(of line: Int) -> Double {
        guard byteCount > 0 else { return 0 }
        let window = Self.window(of: line)
        let count = max(1, blocks[window]?.count ?? 1)
        let place = Double(line & ((1 << Self.shift) - 1)) / Double(count)
        let bytes = Double(window) * Double(reader.windowBytes) + place * Double(span(of: window))
        return min(1, max(0, bytes / Double(byteCount)))
    }

    /// The bytes the window covers: all of `windowBytes`, less at the end.
    private func span(of window: Int) -> UInt64 {
        let start = UInt64(window) * UInt64(reader.windowBytes)
        return max(1, min(UInt64(reader.windowBytes), byteCount - min(byteCount, start)))
    }

    private func rebuild() {
        lines = blocks.keys.sorted().flatMap { blocks[$0] ?? [] }
    }

    /// The most elements a window makes: the lines held are all laid out (so that where a line is is exact, and
    /// the page can be scrolled to any of them), and a window of very short lines is made of groups of lines.
    nonisolated static let mostElements = 500

    private static func lines(of window: SendFeedbackTextWindow) -> [Line] {
        var parts = window.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if parts.last == "" { parts.removeLast() }
        let group = max(1, (parts.count + mostElements - 1) / mostElements)
        return stride(from: 0, to: parts.count, by: group).enumerated().map { place, start in
            Line(id: window.index << shift | place, text: parts[start..<min(parts.count, start + group)].joined(separator: "\n"))
        }
    }
}

/// An entry's text, or a plain file's, as one page.
struct SendFeedbackTextFlowPage: View {
    let name: String
    let size: UInt64
    @State private var flow: SendFeedbackTextFlow
    @State private var position = ScrollPosition(idType: Int.self)
    @State private var topLine = 0
    @State private var held: Double?
    @State private var jumping: Task<Void, Never>?
    /// After a jump, the line the page was scrolled to: what the scroll view says is in view is not heard until
    /// that line is, because what it said before the scroll took effect is about the place the person left.
    @State private var awaiting: Int?

    init(reader: SendFeedbackTextReader, name: String, size: UInt64) {
        self.name = name
        self.size = size
        _flow = State(initialValue: SendFeedbackTextFlow(reader: reader))
    }

    var body: some View {
        Group {
            if flow.failed {
                SendFeedbackViewerMessage(message: LocalizedStringResource(
                    "This file can\u{2019}t be read. It may be damaged or cut short.", table: "Feedback"))
            } else if flow.lines.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                text
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(verbatim: name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(verbatim: Formats.size(bytes: size))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .frame(maxWidth: 240)
                .accessibilityElement(children: .combine)
            }
        }
        .navigationTitle(Text(verbatim: name))
        .navigationBarTitleDisplayMode(.inline)
        .task { await flow.open() }
        .onDisappear { jumping?.cancel() }
    }

    /// Holds the windows at `fraction` of the text and scrolls to the line there.
    private func go(to fraction: Double) async {
        guard let line = await flow.jump(to: fraction) else { return }
        topLine = line
        awaiting = line
        position.scrollTo(id: line, anchor: .top)
        // A line that is never reported (the text ended before it) must not mute the page for good.
        try? await Task.sleep(for: .seconds(1))
        if awaiting == line { awaiting = nil }
    }

    private var text: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(flow.lines) { line in
                    Text(verbatim: line.text.isEmpty ? " " : line.text)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .scrollTargetLayout()
            .textSelection(.disabled)
            .padding(.leading, 16)
            .padding(.trailing, 30)
            .padding(.vertical, 12)
            .accessibilityIdentifier("feedback-viewer-text")
        }
        .scrollPosition($position, anchor: .top)
        .scrollIndicators(.hidden)
        .onScrollTargetVisibilityChange(idType: Int.self, threshold: 0.2) { visible in
            if let awaiting {
                guard visible.contains(awaiting) else { return }
                self.awaiting = nil
            }
            guard let top = visible.filter({ flow.holds($0) }).min() else { return }
            topLine = top
            let window = SendFeedbackTextFlow.window(of: top)
            Task {
                // Lines came or went above the ones in view: put the page back where it was.
                if await flow.ensure(around: window) { position.scrollTo(id: topLine, anchor: .top) }
            }
        }
        .overlay(alignment: .trailing) {
            SendFeedbackThumb(
                fraction: held ?? flow.fraction(of: topLine), total: flow.byteCount, isHeld: held != nil,
                move: { held = $0 }, release: { fraction in
                    held = nil
                    jumping?.cancel()
                    jumping = Task { await go(to: fraction) }
                })
        }
        #if !APP_STORE
        .task {
            // The Simulator preview shows the thumb held at a place.
            guard let thumb = SendFeedbackViewerPreview.thumb else { return }
            try? await Task.sleep(for: .milliseconds(900))
            await go(to: thumb)
            held = thumb
        }
        #endif
    }
}

/// What takes a touch on the thumb's strip: a band, or the whole strip when there is none.
nonisolated private struct SendFeedbackThumbGrab: Shape {
    let band: CGRect?

    func path(in rect: CGRect) -> Path { Path(band ?? rect) }
}

/// The thumb on the trailing edge: thin at rest, a grip with the place it points at while it is held.
struct SendFeedbackThumb: View {
    let fraction: Double
    let total: UInt64
    let isHeld: Bool
    let move: (Double) -> Void
    let release: (Double) -> Void

    private let inset: CGFloat = 12
    private let length: CGFloat = 44
    /// What the band that takes a touch at rest reaches above and below the thumb: 44 by 60 points in all.
    private let grabMargin: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            let travel = max(1, geometry.size.height - inset * 2 - length)
            let y = inset + travel * fraction
            ZStack(alignment: .topTrailing) {
                if isHeld {
                    Capsule()
                        .fill(Color(.tertiaryLabel).opacity(0.35))
                        .frame(width: 3)
                        .padding(.vertical, inset)
                        .frame(maxHeight: .infinity)
                        .padding(.trailing, 14.5)
                }
                Group {
                    if isHeld {
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: 30, height: length)
                            .overlay {
                                VStack(spacing: 3) {
                                    ForEach(0..<3, id: \.self) { _ in
                                        Capsule().fill(.white.opacity(0.85)).frame(width: 12, height: 2)
                                    }
                                }
                            }
                            .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                    } else {
                        Capsule()
                            .fill(Color(.secondaryLabel).opacity(0.55))
                            .frame(width: 5, height: length)
                    }
                }
                .padding(.trailing, isHeld ? 1 : 4)
                .offset(y: y)
                if isHeld { label.offset(y: y + length / 2 - 28) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .allowsHitTesting(false)
            .overlay {
                // At rest only a band around the thumb takes a touch, and the rest of the edge scrolls the text;
                // held, the whole strip follows the finger.
                Color.clear
                    .contentShape(SendFeedbackThumbGrab(band: isHeld ? nil : CGRect(
                        x: 0, y: y - grabMargin, width: geometry.size.width, height: length + 2 * grabMargin)))
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { move(place($0.location.y, travel: travel)) }
                            .onEnded { release(place($0.location.y, travel: travel)) })
            }
        }
        .frame(width: isHeld ? 260 : 44)
        .accessibilityElement()
        .accessibilityLabel(Text("Position", tableName: "Feedback"))
        .accessibilityValue(Text(verbatim: spoken))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: release(min(1, fraction + 0.1))
            case .decrement: release(max(0, fraction - 0.1))
            @unknown default: break
            }
        }
        .accessibilityIdentifier("feedback-viewer-thumb")
    }

    private func place(_ y: CGFloat, travel: CGFloat) -> Double {
        Double(min(1, max(0, (y - inset - length / 2) / travel)))
    }

    private var at: UInt64 { UInt64(Double(total) * fraction) }

    private var spoken: String {
        "\(Int((fraction * 100).rounded())) %, "
            + String(localized: "\(Formats.size(bytes: at)) of \(Formats.size(bytes: total))", table: "Feedback")
    }

    private var label: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(verbatim: "\(Int((fraction * 100).rounded())) %")
                .font(.title3.weight(.bold))
                .monospacedDigit()
            Text(String(localized: "\(Formats.size(bytes: at)) of \(Formats.size(bytes: total))", table: "Feedback"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(.systemBackground), in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color(.separator)))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        .padding(.trailing, 40)
        .allowsHitTesting(false)
    }
}

#endif
