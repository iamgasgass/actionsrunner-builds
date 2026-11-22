import SwiftUI

/// Overlay dell'assistente vocale, con campo di testo di riserva.
struct AssistantOverlay: View {
    @EnvironmentObject var assistant: VoiceAssistant
    @EnvironmentObject var state: AppState
    @State private var typed = ""
    @FocusState private var focused: Bool
    @State private var pulse = false

    private let suggestions = ["Portami al Colosseo", "Metti la radio", "Chiama Marco", "Leggi i messaggi", "Che tempo fa?"]

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 14) {
                Spacer(minLength: 0)

                if !assistant.transcript.isEmpty {
                    Text("“\(assistant.transcript)”")
                        .font(.system(size: 22, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .foregroundColor(.white)
                }
                if !assistant.response.isEmpty {
                    Text(assistant.response)
                        .font(.system(size: 18))
                        .multilineTextAlignment(.center)
                        .foregroundColor(.white.opacity(0.8))
                }
                if let msg = unavailableMessage {
                    Text(msg)
                        .font(.system(size: 15))
                        .multilineTextAlignment(.center)
                        .foregroundColor(.orange)
                }
                if assistant.transcript.isEmpty && assistant.response.isEmpty && assistant.phase == .listening {
                    Text("Ti ascolto…")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.white)
                }

                orb
                    .onTapGesture {
                        if assistant.phase == .listening { assistant.cancel() } else { assistant.startListening() }
                    }

                HStack(spacing: 8) {
                    TextField("Oppure scrivi un comando…", text: $typed)
                        .focused($focused)
                        .submitLabel(.send)
                        .onSubmit(send)
                        .padding(.horizontal, 14)
                        .frame(height: 42)
                        .background(Color.white.opacity(0.15), in: Capsule())
                        .foregroundColor(.white)
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 34))
                    }
                    .foregroundColor(.white)
                    Button(action: close) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 34))
                    }
                    .foregroundColor(.white.opacity(0.7))
                }
                .frame(maxWidth: 520)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(suggestions, id: \.self) { s in
                            Button {
                                assistant.cancel()
                                assistant.submit(s)
                                closeSoon()
                            } label: {
                                Text(s)
                                    .font(.system(size: 14, weight: .medium))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Color.white.opacity(0.12), in: Capsule())
                                    .foregroundColor(.white)
                            }
                            .buttonStyle(PressableStyle())
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.bottom, 12)
            }
            .padding(.horizontal, 20)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { pulse = true }
        }
        .onChange(of: assistant.phase) { phase in
            if phase == .idle && !assistant.response.isEmpty && !assistant.transcript.isEmpty {
                closeSoon()
            }
        }
    }

    private var unavailableMessage: String? {
        if case let .unavailable(msg) = assistant.phase { return msg }
        return nil
    }

    private var orb: some View {
        let level = CGFloat(assistant.level)
        let active = assistant.phase == .listening || assistant.phase == .speaking || assistant.phase == .thinking
        return ZStack {
            Circle()
                .fill(AngularGradient(colors: [.pink, .purple, .blue, .cyan, .pink], center: .center))
                .frame(width: 70, height: 70)
                .blur(radius: 14)
                .scaleEffect(active ? (pulse ? 1.25 : 0.95) + level * 0.6 : 0.9)
            Circle()
                .fill(AngularGradient(colors: [.pink, .purple, .blue, .cyan, .pink], center: .center))
                .frame(width: 62, height: 62)
                .rotationEffect(.degrees(pulse ? 180 : 0))
            Image(systemName: assistant.phase == .listening ? "waveform" : "mic.fill")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.white)
        }
        .frame(width: 110, height: 110)
        .animation(.easeOut(duration: 0.12), value: assistant.level)
    }

    private func send() {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        typed = ""
        focused = false
        assistant.cancel()
        assistant.submit(t)
        closeSoon()
    }

    private func closeSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if assistant.phase != .listening {
                withAnimation { state.showAssistant = false }
            }
        }
    }

    private func close() {
        assistant.cancel()
        withAnimation { state.showAssistant = false }
    }
}
