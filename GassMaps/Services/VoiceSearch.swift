import Foundation
import Speech
import AVFoundation

/// Ricerca vocale (il microfono nella barra di ricerca di Google Maps), riconoscimento in italiano.
final class VoiceSearch: ObservableObject {
    @Published var isListening = false
    @Published var transcript = ""
    @Published var error: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "it-IT"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var onFinish: ((String) -> Void)?

    /// Avvia l'ascolto; quando l'utente smette di parlare richiama `finished` con il testo riconosciuto
    func start(finished: @escaping (String) -> Void) {
        error = nil
        onFinish = finished
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    self.error = "Consenti il riconoscimento vocale nelle Impostazioni di iOS."
                    return
                }
                AVAudioApplication.requestRecordPermission { granted in
                    DispatchQueue.main.async {
                        if granted { self.begin() } else { self.error = "Consenti l'uso del microfono nelle Impostazioni di iOS." }
                    }
                }
            }
        }
    }

    private func begin() {
        guard let recognizer = recognizer, recognizer.isAvailable else {
            error = "Riconoscimento vocale non disponibile al momento."
            return
        }
        stop(deliver: false)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            self.error = "Microfono non disponibile."
            return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = false }
        request = req

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        engine.prepare()
        do { try engine.start() } catch {
            self.error = "Microfono non disponibile."
            return
        }
        transcript = ""
        isListening = true
        restartSilenceTimer(4)

        task = recognizer.recognitionTask(with: req) { [weak self] result, err in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let result = result {
                    self.transcript = result.bestTranscription.formattedString
                    self.restartSilenceTimer(1.4)   // fine frase dopo una breve pausa
                    if result.isFinal { self.stop(deliver: true) }
                } else if err != nil {
                    self.stop(deliver: true)
                }
            }
        }
    }

    private func restartSilenceTimer(_ seconds: TimeInterval) {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.stop(deliver: true)
        }
    }

    func stop(deliver: Bool = true) {
        silenceTimer?.invalidate()
        silenceTimer = nil
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        let wasListening = isListening
        isListening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if deliver && wasListening {
            let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            let done = onFinish
            onFinish = nil
            if !text.isEmpty { done?(text) }
        }
    }
}
