import UIKit
import AVFoundation
import MediaPlayer

/// Usa i tasti volume dell'iPhone per regolare il volume della TV.
final class HardwareVolume: NSObject {
    static let shared = HardwareVolume()

    var onPress: ((RemoteKey) -> Void)?

    private var observation: NSKeyValueObservation?
    private let volumeView = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 10, height: 10))
    private var lastVolume: Float = 0.5
    private var ignoreNext = false
    private weak var window: UIWindow?

    var isRunning: Bool { observation != nil }

    func start(in window: UIWindow) {
        self.window = window
        guard observation == nil else { refresh(); return }
        volumeView.alpha = 0.01
        volumeView.isUserInteractionEnabled = false
        window.addSubview(volumeView)
        activateSession()
        let session = AVAudioSession.sharedInstance()
        lastVolume = session.outputVolume
        observation = session.observe(\.outputVolume, options: [.new]) { [weak self] session, _ in
            let value = session.outputVolume
            DispatchQueue.main.async { self?.changed(value) }
        }
        recenterIfNeeded()
    }

    func stop() {
        observation?.invalidate()
        observation = nil
        volumeView.removeFromSuperview()
    }

    /// Riattiva la sessione audio (dopo la dettatura o al ritorno in primo piano).
    func refresh() {
        guard observation != nil else { return }
        activateSession()
        lastVolume = AVAudioSession.sharedInstance().outputVolume
        recenterIfNeeded()
    }

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, options: .mixWithOthers)
        try? session.setActive(true)
    }

    private func changed(_ volume: Float) {
        if ignoreNext {
            ignoreNext = false
            lastVolume = volume
            return
        }
        if volume > lastVolume {
            onPress?(.volumeUp)
        } else if volume < lastVolume {
            onPress?(.volumeDown)
        }
        lastVolume = volume
        recenterIfNeeded()
    }

    /// Riporta il volume dell'iPhone a metà, così i tasti funzionano sempre in entrambe le direzioni.
    private func recenterIfNeeded() {
        guard lastVolume <= 0.15 || lastVolume >= 0.85,
              let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.ignoreNext = true
            slider.value = 0.5
        }
    }
}
