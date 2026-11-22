import SwiftUI

struct Contact: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let number: String
    let hue: Double

    var initials: String {
        name.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init).joined()
    }

    static let samples: [Contact] = [
        Contact(name: "Marco Rossi", number: "+39 333 123 4567", hue: 0.58),
        Contact(name: "Giulia Bianchi", number: "+39 347 765 4321", hue: 0.92),
        Contact(name: "Casa", number: "+39 06 1234 5678", hue: 0.33),
        Contact(name: "Luca Verdi", number: "+39 320 111 2233", hue: 0.08),
        Contact(name: "Officina", number: "+39 02 9876 5432", hue: 0.75),
        Contact(name: "Sara Neri", number: "+39 349 555 0101", hue: 0.15)
    ]
}

struct RecentCall: Identifiable {
    let id = UUID()
    let contact: Contact
    let missed: Bool
    let outgoing: Bool
    let when: String

    static let samples: [RecentCall] = [
        RecentCall(contact: Contact.samples[1], missed: true, outgoing: false, when: "10:42"),
        RecentCall(contact: Contact.samples[0], missed: false, outgoing: true, when: "09:15"),
        RecentCall(contact: Contact.samples[2], missed: false, outgoing: false, when: "Ieri"),
        RecentCall(contact: Contact.samples[4], missed: false, outgoing: true, when: "Ieri"),
        RecentCall(contact: Contact.samples[3], missed: true, outgoing: false, when: "Lunedì")
    ]
}

struct ChatMessage: Identifiable, Hashable {
    let id = UUID()
    let text: String
    let fromMe: Bool
}

struct Conversation: Identifiable, Hashable {
    let id = UUID()
    let contact: String
    let hue: Double
    var unread: Bool
    var messages: [ChatMessage]

    static let samples: [Conversation] = [
        Conversation(contact: "Giulia Bianchi", hue: 0.92, unread: true, messages: [
            ChatMessage(text: "Ciao! A che ora arrivi?", fromMe: false),
            ChatMessage(text: "Ricordati di prendere il pane 🥖", fromMe: false)
        ]),
        Conversation(contact: "Marco Rossi", hue: 0.58, unread: true, messages: [
            ChatMessage(text: "Partita stasera alle 21, ci sei?", fromMe: false)
        ]),
        Conversation(contact: "Officina", hue: 0.75, unread: false, messages: [
            ChatMessage(text: "La sua auto è pronta per il ritiro.", fromMe: false),
            ChatMessage(text: "Perfetto, passo domani mattina.", fromMe: true)
        ]),
        Conversation(contact: "Sara Neri", hue: 0.15, unread: false, messages: [
            ChatMessage(text: "Grazie per il passaggio!", fromMe: false),
            ChatMessage(text: "Figurati 😊", fromMe: true)
        ])
    ]
}

struct CalendarEvent: Identifiable {
    let id = UUID()
    let title: String
    let location: String
    let start: Date
    let minutes: Int
    let hue: Double

    static var today: [CalendarEvent] {
        let cal = Calendar.current
        let base = cal.startOfDay(for: Date())
        func at(_ h: Int, _ m: Int) -> Date { cal.date(byAdding: .minute, value: h * 60 + m, to: base) ?? base }
        return [
            CalendarEvent(title: "Riunione di team", location: "Ufficio, Via Roma 10", start: at(9, 30), minutes: 60, hue: 0.58),
            CalendarEvent(title: "Pranzo con Giulia", location: "Trattoria da Mario", start: at(13, 0), minutes: 90, hue: 0.92),
            CalendarEvent(title: "Tagliando auto", location: "Officina Centrale", start: at(16, 15), minutes: 45, hue: 0.08),
            CalendarEvent(title: "Palestra", location: "Fitness Club", start: at(19, 0), minutes: 60, hue: 0.33)
        ]
    }
}

struct WeatherSample {
    let city: String
    let temperature: Int
    let condition: String
    let symbol: String
    let high: Int
    let low: Int
    let hourly: [(String, String, Int)]

    static var current: WeatherSample {
        let hour = Calendar.current.component(.hour, from: Date())
        let night = hour < 6 || hour >= 20
        var hourly: [(String, String, Int)] = []
        for i in 0..<6 {
            let h = (hour + i) % 24
            let isNight = h < 6 || h >= 20
            hourly.append((i == 0 ? "Ora" : String(format: "%02d", h),
                           isNight ? "moon.stars.fill" : (i % 3 == 2 ? "cloud.sun.fill" : "sun.max.fill"),
                           18 + (isNight ? -3 : 2) + (i % 2)))
        }
        return WeatherSample(city: "La tua posizione",
                             temperature: night ? 15 : 21,
                             condition: night ? "Sereno" : "Parzialmente nuvoloso",
                             symbol: night ? "moon.stars.fill" : "cloud.sun.fill",
                             high: 24, low: 13, hourly: hourly)
    }
}

enum PhoneDialer {
    static func call(_ number: String) {
        let digits = number.filter { $0.isNumber || $0 == "+" }
        guard let url = URL(string: "tel://\(digits)") else { return }
        DispatchQueue.main.async {
            UIApplication.shared.open(url)
        }
    }
}

extension Color {
    static func hue(_ h: Double, s: Double = 0.65, b: Double = 0.85) -> Color {
        Color(hue: h, saturation: s, brightness: b)
    }
}
