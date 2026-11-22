import AVFoundation
import Speech
import SwiftUI

/// Assistente vocale: riconoscimento vocale (Speech) + sintesi (AVSpeechSynthesizer).
/// Se il microfono non è disponibile (es. dentro LiveContainer) si può scrivere il comando.
final class VoiceAssistant: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    enum Phase: Equatable {
        case idle
        case listening
        case thinking
        case speaking
        case unavailable(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var transcript = ""
    @Published private(set) var response = ""
    @Published private(set) var level: Float = 0

    /// Chiamato con il testo finale riconosciuto; restituisce la risposta da pronunciare.
    var handler: ((String) -> String)?
    var speakResponses = true

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "it-IT"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let synth = AVSpeechSynthesizer()
    private var silenceWork: DispatchWorkItem?
    private var finished = false

    override init() {
        super.init()
        synth.delegate = self
    }

    // MARK: - Ascolto

    func startListening() {
        transcript = ""
        response = ""
        finished = false
        synth.stopSpeaking(at: .immediate)
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    self.phase = .unavailable("Riconoscimento vocale non autorizzato. Scrivi il comando qui sotto.")
                    return
                }
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    DispatchQueue.main.async {
                        guard granted else {
                            self.phase = .unavailable("Microfono non disponibile. Scrivi il comando qui sotto.")
                            return
                        }
                        do {
                            try self.beginRecording()
                        } catch {
                            self.phase = .unavailable("Impossibile avviare il microfono. Scrivi il comando qui sotto.")
                        }
                    }
                }
            }
        }
    }

    private func beginRecording() throws {
        guard let recognizer = recognizer, recognizer.isAvailable else {
            phase = .unavailable("Riconoscimento vocale non disponibile. Scrivi il comando qui sotto.")
            return
        }
        stopEngine()

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        request = req

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "VoiceAssistant", code: 1)
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            req.append(buffer)
            guard let data = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += data[i] * data[i] }
            let rms = n > 0 ? sqrt(sum / Float(n)) : 0
            DispatchQueue.main.async { self?.level = min(1, rms * 12) }
        }
        engine.prepare()
        try engine.start()
        phase = .listening

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let result = result {
                    self.transcript = result.bestTranscription.formattedString
                    self.scheduleSilenceTimeout()
                    if result.isFinal { self.finish() }
                } else if error != nil {
                    self.finish()
                }
            }
        }
        scheduleSilenceTimeout(initial: true)
    }

    private func scheduleSilenceTimeout(initial: Bool = false) {
        silenceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finish() }
        silenceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (initial ? 6 : 1.6), execute: work)
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        silenceWork?.cancel()
        stopEngine()
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            phase = .idle
            respond("Non ho sentito nulla.")
        } else {
            submit(text)
        }
    }

    private func stopEngine() {
        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        level = 0
    }

    func cancel() {
        finished = true
        silenceWork?.cancel()
        stopEngine()
        synth.stopSpeaking(at: .immediate)
        phase = .idle
        restorePlaybackSession()
    }

    // MARK: - Comando testuale

    func submit(_ text: String) {
        transcript = text
        phase = .thinking
        let answer = handler?(text) ?? "Non so come aiutarti."
        respond(answer)
    }

    func respond(_ text: String) {
        response = text
        guard speakResponses else {
            phase = .idle
            restorePlaybackSession()
            return
        }
        speak(text)
    }

    func speak(_ text: String) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
        try? session.setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "it-IT")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        phase = .speaking
        synth.speak(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            if self.phase == .speaking { self.phase = .idle }
            self.restorePlaybackSession()
        }
    }

    private func restorePlaybackSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
    }
}

/// Interpreta i comandi (in italiano, con qualche sinonimo inglese).
enum CommandBrain {
    static func handle(_ raw: String, state: AppState, media: MediaController, nav: NavigationModel) -> String {
        let text = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        func after(_ prefixes: [String]) -> String? {
            for p in prefixes {
                if let r = text.range(of: p) {
                    let rest = text[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !rest.isEmpty { return rest }
                }
            }
            return nil
        }

        // Navigazione
        if let place = after(["portami a ", "portami al ", "portami in ", "naviga verso ", "naviga a ", "vai a ", "vai al ", "vai in ", "indicazioni per ", "navigate to ", "take me to "]) {
            state.open(.maps)
            nav.searchAndRoute(place) { name in
                if let name = name {
                    state.showBanner("Percorso verso \(name)")
                } else {
                    state.showBanner("Nessun risultato per \(place)")
                }
            }
            return "Cerco un percorso verso \(place)."
        }
        if text.contains("termina navigazione") || text.contains("ferma navigazione") || text.contains("annulla percorso") {
            nav.endNavigation()
            return "Navigazione terminata."
        }
        if text.contains("cerca ") , let q = after(["cerca "]) {
            state.open(.maps)
            nav.query = q
            nav.performSearch(q)
            return "Ecco cosa ho trovato per \(q)."
        }

        // Telefono
        if let who = after(["chiama ", "telefona a ", "call "]) {
            state.open(.phone)
            if let contact = Contact.samples.first(where: { $0.name.lowercased().contains(who) }) {
                PhoneDialer.call(contact.number)
                return "Chiamo \(contact.name)."
            }
            let digits = who.filter { $0.isNumber || $0 == "+" }
            if digits.count >= 3 {
                PhoneDialer.call(digits)
                return "Chiamo \(digits)."
            }
            return "Non trovo \(who) tra i contatti."
        }

        // Radio
        if text.contains("radio") {
            let station = MediaController.stations.first { text.contains($0.name.lowercased()) } ?? MediaController.stations[0]
            media.play(station: station)
            state.open(.nowPlaying)
            return "Ecco \(station.name)."
        }

        // Musica
        if text.contains("pausa") || text.contains("stop") || text.contains("ferma") || text == "pause" {
            media.pause()
            return "Musica in pausa."
        }
        if text.contains("prossim") || text.contains("successiv") || text.contains("avanti") || text.contains("next") || text.contains("salta") {
            media.next()
            return "Brano successivo."
        }
        if text.contains("precedente") || text.contains("indietro") || text.contains("previous") {
            media.previous()
            return "Brano precedente."
        }
        if text.contains("riproduci") || text.contains("metti") || text.contains("musica") || text.contains("play") || text.contains("riprendi") {
            if media.source == .none {
                media.playLibrary()
            } else {
                media.resume()
            }
            state.open(.nowPlaying)
            return "Va bene, ecco la musica."
        }

        // Messaggi
        if text.contains("messaggi") || text.contains("leggi") {
            state.open(.messages)
            let unread = Conversation.samples.filter { $0.unread }
            if let first = unread.first {
                return "Hai \(unread.count) messaggi non letti. \(first.contact) dice: \(first.messages.last?.text ?? "")"
            }
            return "Non hai messaggi nuovi."
        }

        // Info
        if text.contains("che ore") || text.contains("ora è") || text.contains("what time") {
            let f = DateFormatter()
            f.locale = Locale(identifier: "it_IT")
            f.dateFormat = "HH:mm"
            return "Sono le \(f.string(from: Date()))."
        }
        if text.contains("meteo") || text.contains("tempo fa") || text.contains("weather") {
            state.open(.weather)
            let w = WeatherSample.current
            return "Ci sono \(w.temperature) gradi, \(w.condition.lowercased())."
        }
        if text.contains("quanto manca") || text.contains("arrivo") {
            if nav.phase == .navigating {
                return "Mancano \(Formatters.distance(nav.remainingDistance)), arrivo alle \(Formatters.arrival(after: nav.remainingTime))."
            }
            return "Nessuna navigazione attiva."
        }

        // Apri app
        for app in CarApp.allCases where text.contains(app.title.lowercased()) {
            state.open(app)
            return "Apro \(app.title)."
        }
        if text.contains("home") || text.contains("schermata principale") {
            state.screen = .home
            return "Ecco la schermata principale."
        }

        return "Scusa, non ho capito. Prova con \"portami a Roma\", \"metti la radio\" o \"chiama Marco\"."
    }
}
