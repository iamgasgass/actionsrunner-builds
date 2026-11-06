import SwiftUI
import UIKit

struct MessageRow: View {
    @Environment(AppState.self) private var app
    let message: ChatMessage
    let isLast: Bool

    @State private var copied = false
    @State private var editing = false
    @State private var editText = ""

    private var isGenerating: Bool { isLast && app.isStreaming && message.role == .assistant }

    var body: some View {
        switch message.role {
        case .user: userBubble
        case .assistant: assistantBody
        }
    }

    // MARK: - Utente (bolla a destra)

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let data = message.imageData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: 220, maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            if !message.content.isEmpty {
                Text(message.content)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 56)
        .contextMenu {
            Button { copy(message.content) } label: { Label("Copia", systemImage: "doc.on.doc") }
            if !app.isStreaming {
                Button {
                    editText = message.content
                    editing = true
                } label: { Label("Modifica", systemImage: "pencil") }
            }
        }
        .sheet(isPresented: $editing) {
            EditMessageSheet(text: $editText) {
                app.edit(message: message, newText: editText)
            }
        }
    }

    // MARK: - Assistente (testo a tutta larghezza)

    private var assistantBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if message.isError {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message.content)
                        .font(.subheadline)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                if isLast {
                    Button {
                        app.regenerate()
                    } label: {
                        Label("Riprova", systemImage: "arrow.clockwise")
                            .font(.subheadline.weight(.medium))
                    }
                    .foregroundStyle(.primary)
                }
            } else if message.content.isEmpty && isGenerating {
                ThinkingDot()
                    .padding(.vertical, 6)
            } else {
                MarkdownText(text: message.content)
            }

            if !message.isError && !message.content.isEmpty && !isGenerating {
                actionBar
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionBar: some View {
        HStack(spacing: 18) {
            Button { copy(message.content) } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            ShareLink(item: message.content) {
                Image(systemName: "square.and.arrow.up")
            }
            if isLast {
                Button { app.regenerate() } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            Spacer()
            if let name = message.modelName {
                Text(name)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 15))
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
    }

    private func copy(_ text: String) {
        UIPasteboard.general.string = text
        app.haptic(.light)
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { copied = false }
        }
    }
}

/// Puntino pulsante mostrato mentre il modello "pensa".
struct ThinkingDot: View {
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(Color.primary)
            .frame(width: 14, height: 14)
            .scaleEffect(pulse ? 1.0 : 0.6)
            .opacity(pulse ? 1.0 : 0.5)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
    }
}

private struct EditMessageSheet: View {
    @Binding var text: String
    var onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .padding(12)
                .navigationTitle("Modifica messaggio")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Annulla") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Invia") {
                            onSave()
                            dismiss()
                        }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}
