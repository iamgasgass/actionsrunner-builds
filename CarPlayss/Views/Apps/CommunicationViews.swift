import AVFoundation
import SwiftUI

// MARK: - Telefono

struct PhoneView: View {
    @State private var tab = 0
    @State private var number = ""
    @State private var activeCall: String?
    @State private var callStart = Date()

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                AppHeader(title: "Telefono") {
                    Picker("", selection: $tab) {
                        Text("Preferiti").tag(0)
                        Text("Recenti").tag(1)
                        Text("Tastiera").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 300)
                }

                switch tab {
                case 0: favorites
                case 1: recents
                default: keypad
                }
            }

            if let call = activeCall {
                CallScreen(name: call, start: callStart) {
                    withAnimation { activeCall = nil }
                }
                .transition(.opacity)
            }
        }
    }

    private func startCall(name: String, number: String) {
        callStart = Date()
        withAnimation { activeCall = name }
        PhoneDialer.call(number)
    }

    private var favorites: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 16) {
                ForEach(Contact.samples) { c in
                    Button { startCall(name: c.name, number: c.number) } label: {
                        VStack(spacing: 8) {
                            AvatarView(initials: c.initials, hue: c.hue, size: 64)
                            Text(c.name)
                                .font(.system(size: 14, weight: .medium))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .card(radius: 16)
                    }
                    .buttonStyle(PressableStyle())
                    .foregroundStyle(.primary)
                }
            }
            .padding(14)
        }
    }

    private var recents: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(RecentCall.samples) { r in
                    Button { startCall(name: r.contact.name, number: r.contact.number) } label: {
                        CarListRow(title: r.contact.name,
                                   subtitle: (r.outgoing ? "In uscita" : (r.missed ? "Persa" : "In entrata")) + " · " + r.when,
                                   trailingSymbol: "phone.fill") {
                            ZStack(alignment: .bottomTrailing) {
                                AvatarView(initials: r.contact.initials, hue: r.contact.hue, size: 40)
                                Image(systemName: r.outgoing ? "arrow.up.right" : "arrow.down.left")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(3)
                                    .background(Circle().fill(r.missed ? Color.red : Color.green))
                                    .foregroundColor(.white)
                            }
                        }
                        .foregroundColor(r.missed ? Color.red : Color.primary)
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 68)
                }
            }
            .card()
            .padding(14)
        }
    }

    private var keypad: some View {
        let keys: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["*", "0", "#"]]
        return HStack(spacing: 24) {
            VStack(spacing: 10) {
                Text(number.isEmpty ? "Inserisci numero" : number)
                    .font(.system(size: number.isEmpty ? 20 : 30, weight: .medium))
                    .foregroundColor(number.isEmpty ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: .infinity)
                HStack(spacing: 18) {
                    Button { if !number.isEmpty { number.removeLast() } } label: {
                        Image(systemName: "delete.left.fill")
                            .font(.system(size: 24))
                            .frame(width: 60, height: 60)
                    }
                    Button {
                        guard !number.isEmpty else { return }
                        startCall(name: number, number: number)
                    } label: {
                        Image(systemName: "phone.fill")
                            .font(.system(size: 26))
                            .frame(width: 70, height: 70)
                            .background(Color.green, in: Circle())
                            .foregroundColor(.white)
                    }
                }
                .buttonStyle(PressableStyle())
                .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 8) {
                ForEach(keys, id: \.self) { row in
                    HStack(spacing: 10) {
                        ForEach(row, id: \.self) { key in
                            Button { number.append(key) } label: {
                                Text(key)
                                    .font(.system(size: 26, weight: .medium))
                                    .frame(width: 64, height: 50)
                                    .background(Color.white.opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(PressableStyle())
                            .foregroundStyle(.primary)
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(maxHeight: .infinity)
    }
}

struct CallScreen: View {
    let name: String
    let start: Date
    let onEnd: () -> Void
    @State private var muted = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            VStack(spacing: 18) {
                Text(name)
                    .font(.system(size: 30, weight: .bold))
                TimelineView(.periodic(from: start, by: 1)) { ctx in
                    Text(Formatters.time(ctx.date.timeIntervalSince(start)))
                        .font(.system(size: 18))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 30) {
                    Button { muted.toggle() } label: {
                        Image(systemName: muted ? "mic.slash.fill" : "mic.fill")
                            .font(.system(size: 24))
                            .frame(width: 64, height: 64)
                            .background(Color.white.opacity(muted ? 0.9 : 0.15), in: Circle())
                            .foregroundColor(muted ? Color.black : Color.white)
                    }
                    Button(action: onEnd) {
                        Image(systemName: "phone.down.fill")
                            .font(.system(size: 26))
                            .frame(width: 72, height: 72)
                            .background(Color.red, in: Circle())
                            .foregroundColor(.white)
                    }
                }
                .buttonStyle(PressableStyle())
                Text("La chiamata reale viene passata all'app Telefono di iOS, se disponibile.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .foregroundColor(.white)
        }
    }
}

// MARK: - Messaggi

struct MessagesView: View {
    @EnvironmentObject var assistant: VoiceAssistant
    @State private var conversations = Conversation.samples
    @State private var openID: UUID?

    private let quickReplies = ["Sto guidando, ti richiamo 🚗", "Arrivo tra 10 minuti", "Ok 👍", "Ci vediamo dopo!"]

    var body: some View {
        if let id = openID, let index = conversations.firstIndex(where: { $0.id == id }) {
            detail(index)
        } else {
            list
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            AppHeader(title: "Messaggi")
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(conversations) { c in
                        Button {
                            openID = c.id
                            read(c)
                            if let i = conversations.firstIndex(where: { $0.id == c.id }) { conversations[i].unread = false }
                        } label: {
                            CarListRow(title: c.contact, subtitle: c.messages.last?.text, trailingSymbol: "speaker.wave.2.fill") {
                                ZStack(alignment: .topLeading) {
                                    AvatarView(initials: String(c.contact.prefix(1)), hue: c.hue, size: 40)
                                    if c.unread {
                                        Circle().fill(Color.blue).frame(width: 12, height: 12).offset(x: -4, y: -2)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 68)
                    }
                }
                .card()
                .padding(14)
            }
        }
    }

    private func detail(_ index: Int) -> some View {
        let c = conversations[index]
        return VStack(spacing: 0) {
            AppHeader(title: c.contact, back: { openID = nil })
            HStack(alignment: .top, spacing: 12) {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(c.messages) { m in
                            HStack {
                                if m.fromMe { Spacer(minLength: 40) }
                                Text(m.text)
                                    .font(.system(size: 16))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 9)
                                    .background(m.fromMe ? Color.blue : Color.white.opacity(0.15),
                                                in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                    .foregroundColor(.white)
                                if !m.fromMe { Spacer(minLength: 40) }
                            }
                        }
                    }
                    .padding(12)
                }
                .frame(maxWidth: .infinity)
                .card()

                VStack(spacing: 8) {
                    Button { read(c) } label: {
                        Label("Leggi", systemImage: "speaker.wave.2.fill")
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                    }
                    ForEach(quickReplies, id: \.self) { reply in
                        Button {
                            conversations[index].messages.append(ChatMessage(text: reply, fromMe: true))
                            assistant.speak("Messaggio inviato.")
                        } label: {
                            Text(reply)
                                .font(.system(size: 14, weight: .medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .frame(maxWidth: .infinity, minHeight: 40)
                                .background(Color.blue.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
                .buttonStyle(PressableStyle())
                .foregroundColor(.white)
                .frame(width: 220)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
    }

    private func read(_ c: Conversation) {
        let incoming = c.messages.filter { !$0.fromMe }.map { $0.text }
        guard !incoming.isEmpty else { return }
        assistant.speak("\(c.contact) dice: " + incoming.joined(separator: ". "))
    }
}
