import SwiftUI

struct ChatView: View {
    @Environment(AppState.self) private var app
    var openSidebar: () -> Void

    @State private var input = ""
    @State private var imageData: Data?
    @State private var showModelPicker = false
    @State private var showOptions = false
    @FocusState private var inputFocused: Bool

    private var messages: [ChatMessage] { app.currentConversation?.messages ?? [] }

    var body: some View {
        Group {
            if messages.isEmpty {
                emptyState
            } else {
                messageList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 10) {
                if messages.isEmpty { suggestions }
                InputBar(
                    text: $input,
                    imageData: $imageData,
                    focused: $inputFocused,
                    onSend: send,
                    onOptions: { showOptions = true }
                )
            }
            .background(Color(.systemBackground))
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .toolbarBackground(Color(.systemBackground), for: .navigationBar)
        .sheet(isPresented: $showModelPicker) {
            ModelPickerView()
        }
        .sheet(isPresented: $showOptions) {
            StyleOptionsView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(action: openSidebar) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 18, weight: .semibold))
            }
            .foregroundStyle(.primary)
        }

        ToolbarItem(placement: .principal) {
            Menu {
                Section("Modelli preferiti") {
                    ForEach(app.settings.favoriteModels) { model in
                        Button {
                            app.selectModel(model)
                        } label: {
                            if model.id == app.settings.selectedModelID {
                                Label(model.name, systemImage: "checkmark")
                            } else {
                                Text(model.name)
                            }
                        }
                    }
                }
                Button {
                    showModelPicker = true
                } label: {
                    Label("Tutti i modelli…", systemImage: "square.grid.2x2")
                }
            } label: {
                HStack(spacing: 4) {
                    Text(app.currentModelName)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
            }
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            if !messages.isEmpty {
                Button {
                    app.newChat()
                    input = ""
                    imageData = nil
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 17, weight: .medium))
                }
                .foregroundStyle(.primary)
            } else {
                Button {
                    showOptions = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 17, weight: .medium))
                }
                .foregroundStyle(.primary)
            }
        }
    }

    // MARK: - Stato vuoto

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Text("Come posso aiutarti?")
                .font(.system(size: 28, weight: .semibold))
                .multilineTextAlignment(.center)
            if !app.settings.hasAPIKey {
                Button {
                    app.showSettings = true
                } label: {
                    Label("Aggiungi la tua API key per iniziare", systemImage: "key.fill")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
                .foregroundStyle(.primary)
            } else {
                if !personaSummary.isEmpty {
                    Label(personaSummary, systemImage: AIRole.named(app.settings.roleName).icon)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .contentShape(Rectangle())
        .onTapGesture { inputFocused = false }
    }

    private var personaSummary: String {
        var parts: [String] = []
        if app.settings.personaName != AIPersonaName.all[0] { parts.append(app.settings.personaName) }
        if app.settings.roleName != AIRole.all[0].name { parts.append(app.settings.roleName) }
        return parts.joined(separator: " · ")
    }

    private var suggestions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(PromptSuggestion.all) { s in
                    Button {
                        input = s.prompt
                        inputFocused = true
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Image(systemName: s.icon).font(.caption)
                                Text(s.title).font(.subheadline.weight(.semibold))
                            }
                            Text(s.subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color(.secondarySystemBackground))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Lista messaggi

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(messages) { message in
                        MessageRow(message: message, isLast: message.id == messages.last?.id)
                            .id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: messages.count) {
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: messages.last?.content) {
                if app.isStreaming { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: app.currentConversationID) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    // MARK: - Azioni

    private func send() {
        let text = input
        let image = imageData
        input = ""
        imageData = nil
        app.send(text: text, imageData: image)
    }
}
