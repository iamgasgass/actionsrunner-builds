import SwiftUI
import UIKit

// MARK: - Parser Markdown leggero (titoli, elenchi, citazioni, tabelle, blocchi di codice)

enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(marker: String, text: String, indent: Int)
    case quote(String)
    case code(language: String, code: String)
    case table([[String]])
    case rule
}

enum MarkdownParser {
    static func blocks(from text: String) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        var paragraph: [String] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0

        func flushParagraph() {
            if !paragraph.isEmpty {
                result.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph.removeAll()
            }
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Blocco di codice
            if trimmed.hasPrefix("```") {
                flushParagraph()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i])
                    i += 1
                }
                result.append(.code(language: language, code: code.joined(separator: "\n")))
                i += 1
                continue
            }

            // Riga vuota
            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // Separatore
            if ["---", "***", "___"].contains(trimmed) {
                flushParagraph()
                result.append(.rule)
                i += 1
                continue
            }

            // Titolo
            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix { $0 == "#" }.count
                let rest = trimmed.dropFirst(hashes)
                if hashes <= 6, rest.hasPrefix(" ") {
                    flushParagraph()
                    result.append(.heading(level: hashes, text: rest.trimmingCharacters(in: .whitespaces)))
                    i += 1
                    continue
                }
            }

            // Tabella
            if trimmed.hasPrefix("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushParagraph()
                var rows: [[String]] = [cells(of: trimmed)]
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(of: lines[i].trimmingCharacters(in: .whitespaces)))
                    i += 1
                }
                result.append(.table(rows))
                continue
            }

            // Citazione
            if trimmed.hasPrefix(">") {
                flushParagraph()
                result.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
                i += 1
                continue
            }

            // Elenchi
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count / 2
            if let first = trimmed.first, "-*+".contains(first), trimmed.dropFirst().hasPrefix(" ") {
                flushParagraph()
                result.append(.bullet(marker: "•", text: String(trimmed.dropFirst(2)), indent: indent))
                i += 1
                continue
            }
            let digits = trimmed.prefix { $0.isNumber }
            if !digits.isEmpty {
                let after = trimmed.dropFirst(digits.count)
                if let sep = after.first, sep == "." || sep == ")", after.dropFirst().hasPrefix(" ") {
                    flushParagraph()
                    result.append(.bullet(marker: "\(digits).",
                                          text: after.dropFirst(2).trimmingCharacters(in: .whitespaces),
                                          indent: indent))
                    i += 1
                    continue
                }
            }

            paragraph.append(line)
            i += 1
        }
        flushParagraph()
        return result
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(of line: String) -> [String] {
        var t = line
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

// MARK: - Vista

struct MarkdownText: View {
    let text: String

    var body: some View {
        let blocks = MarkdownParser.blocks(from: text)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, 4)
                .textSelection(.enabled)

        case .paragraph(let text):
            Text(inline(text))
                .font(.body)
                .lineSpacing(3)
                .textSelection(.enabled)

        case .bullet(let marker, let text, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker)
                    .font(.body.weight(marker == "•" ? .bold : .regular))
                    .frame(minWidth: 14, alignment: .leading)
                Text(inline(text))
                    .lineSpacing(3)
                    .textSelection(.enabled)
            }
            .padding(.leading, CGFloat(indent) * 18)

        case .quote(let text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                Text(inline(text))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .code(let language, let code):
            CodeBlockView(language: language, code: code)

        case .table(let rows):
            TableBlockView(rows: rows, inline: inline)

        case .rule:
            Divider()
        }
    }

    private func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

struct CodeBlockView: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    withAnimation { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation { copied = false } }
                } label: {
                    Label(copied ? "Copiato" : "Copia", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.tertiarySystemFill))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct TableBlockView: View {
    let rows: [[String]]
    let inline: (String) -> AttributedString

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(inline(cell))
                                .font(index == 0 ? .subheadline.bold() : .subheadline)
                        }
                    }
                    if index == 0 { Divider() }
                }
            }
            .padding(12)
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
    }
}
