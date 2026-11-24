import Foundation
import Speech
import AVFoundation

/// Dettatura vocale (italiano) per cercare sulla TV.
final class VoiceInput {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "it-IT")) ?? SFSpeechRecognizer()
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapInstalled = false

    var onText: ((String, Bool) -> Void)?
    var onLevel: ((Float) -> Void)?

    static func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async { completion(status == .authorized && granted) }
            }
        }
    }

    func start() throws {
        cleanup()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self, weak request] buffer, _ in
            request?.append(buffer)
            guard let channel = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<count { sum += channel[i] * channel[i] }
            let rms = count > 0 ? sqrt(sum / Float(count)) : 0
            let level = min(1, rms * 12)
            DispatchQueue.main.async { self?.onLevel?(level) }
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()

        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let result = result {
                    self.onText?(result.bestTranscription.formattedString, result.isFinal)
                }
                if error != nil || (result?.isFinal ?? false) { self.cleanup() }
            }
        }
    }

    /// Termina l'ascolto e attende il risultato finale.
    func finish() {
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        request?.endAudio()
    }

    func cleanup() {
        finish()
        task?.cancel()
        task = nil
        request = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        HardwareVolume.shared.refresh()
    }
}
