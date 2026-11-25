import UIKit

/// Pannello di dettatura in stile alert iOS 6, con microfono cromato e indicatore di livello.
private final class MicrophoneView: UIView {
    var level: CGFloat = 0 { didSet { setNeedsDisplay() } }
    var listening = false { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) / 2 - 10
        if listening {
            let glowRadius = radius + 4 + level * 10
            ctx.drawRadialGradient(Draw.gradient([UIColor(110, 180, 255, 0.85), UIColor(110, 180, 255, 0)]),
                                   startCenter: c, startRadius: radius - 2, endCenter: c, endRadius: glowRadius + 6,
                                   options: [])
        }
        let disc = CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 4, color: UIColor(0, 0, 0, 0.6).cgColor)
        UIColor(40, 40, 44).setFill()
        UIBezierPath(ovalIn: disc).fill()
        ctx.restoreGState()
        let body = disc.insetBy(dx: 2, dy: 2)
        Draw.fillVertical(UIBezierPath(ovalIn: body), body,
                          [UIColor(250, 250, 252), UIColor(196, 200, 208), UIColor(150, 154, 162)], [0, 0.5, 1])
        ctx.saveGState()
        UIBezierPath(ovalIn: body).addClip()
        Draw.glossEllipse(in: body, top: 0.7, bottom: 0.1, heightFactor: 0.5)
        ctx.restoreGState()
        if let mic = Draw.symbol("mic.fill", pointSize: radius * 0.8, weight: .regular,
                                 color: listening ? UIColor(20, 100, 220) : UIColor(70, 74, 82)) {
            Draw.image(mic, centeredIn: body, shadow: UIColor(255, 255, 255, 0.8), offset: CGSize(width: 0, height: 1))
        }
    }
}

final class VoiceSearchViewController: UIViewController {
    var onResult: ((String) -> Void)?

    private let dim = ClassicAlertDimView()
    private let glassMode = InterfaceStyle.isGlass
    private lazy var box: UIView = glassMode ? (GlassView(cornerRadius: 30) as UIView) : (ClassicAlertBoxView() as UIView)
    private let titleLabel = UILabel()
    private let transcript = UILabel()
    private let mic = MicrophoneView()
    private let voice = VoiceInput()
    private var text = ""

    init() {
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    override var preferredStatusBarStyle: UIStatusBarStyle { glassMode ? .default : .lightContent }
    override var prefersStatusBarHidden: Bool { Preferences.shared.hideStatusBar }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        dim.frame = view.bounds
        dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dim.alpha = 0
        view.addSubview(dim)
        if glassMode { box.isUserInteractionEnabled = true }

        box.translatesAutoresizingMaskIntoConstraints = false
        box.alpha = 0
        view.addSubview(box)

        titleLabel.text = "Parla ora"
        transcript.text = "Di' il nome di un film, di una serie o di un'app…"
        [titleLabel, transcript].forEach {
            $0.textAlignment = .center
            $0.numberOfLines = 0
            if glassMode {
                $0.textColor = .label
            } else {
                $0.textColor = .white
                $0.shadowColor = UIColor(0, 0, 0, 0.6)
                $0.shadowOffset = CGSize(width: 0, height: -1)
            }
        }
        titleLabel.font = glassMode ? .systemFont(ofSize: 20, weight: .bold) : Fonts.bold(18)
        transcript.font = glassMode ? .systemFont(ofSize: 16) : Fonts.regular(16)
        mic.heightAnchor.constraint(equalToConstant: 110).isActive = true
        mic.isUserInteractionEnabled = true
        mic.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(micTapped)))

        let cancel: UIControl
        let send: UIControl
        if glassMode {
            var cancelConfig = UIButton.Configuration.gray()
            cancelConfig.title = "Annulla"
            cancelConfig.cornerStyle = .capsule
            var sendConfig = UIButton.Configuration.filled()
            sendConfig.title = "Invia"
            sendConfig.cornerStyle = .capsule
            cancel = UIButton(configuration: cancelConfig)
            send = UIButton(configuration: sendConfig)
        } else {
            cancel = ClassicAlertButton(title: "Annulla", cancel: true)
            send = ClassicAlertButton(title: "Invia", cancel: false)
        }
        cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        send.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        let buttons = UIStackView(arrangedSubviews: [cancel, send])
        buttons.axis = .horizontal
        buttons.spacing = 9
        buttons.distribution = .fillEqually
        buttons.heightAnchor.constraint(equalToConstant: 43).isActive = true

        let stack = UIStackView(arrangedSubviews: [titleLabel, mic, transcript, buttons])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            box.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            box.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            box.widthAnchor.constraint(equalToConstant: 288),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -15)
        ])

        voice.onText = { [weak self] text, isFinal in
            guard let self = self else { return }
            self.text = text
            self.transcript.text = text
            if isFinal { self.mic.listening = false }
        }
        voice.onLevel = { [weak self] level in self?.mic.level = CGFloat(level) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        box.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
        UIView.animate(withDuration: 0.16, animations: {
            self.box.alpha = 1
            self.dim.alpha = 1
            self.box.transform = CGAffineTransform(scaleX: 1.08, y: 1.08)
        }, completion: { _ in
            UIView.animate(withDuration: 0.1, animations: {
                self.box.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
            }, completion: { _ in
                UIView.animate(withDuration: 0.08) { self.box.transform = .identity }
            })
        })
        VoiceInput.requestAuthorization { [weak self] granted in
            guard let self = self else { return }
            if granted {
                self.startListening()
            } else {
                self.transcript.text = "Consenti l'accesso a microfono e riconoscimento vocale in Impostazioni."
            }
        }
    }

    private func startListening() {
        do {
            try voice.start()
            mic.listening = true
        } catch {
            transcript.text = "Il microfono non è disponibile."
        }
    }

    @objc private func micTapped() {
        Feedback.tap()
        if mic.listening {
            voice.finish()
            mic.listening = false
        } else {
            text = ""
            transcript.text = "Ti ascolto…"
            startListening()
        }
    }

    @objc private func cancelTapped() {
        close(sending: false)
    }

    @objc private func sendTapped() {
        close(sending: true)
    }

    private func close(sending: Bool) {
        Feedback.tap()
        voice.cleanup()
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        UIView.animate(withDuration: 0.2, animations: {
            self.box.alpha = 0
            self.dim.alpha = 0
            self.box.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        }, completion: { _ in
            self.dismiss(animated: false) {
                if sending, !result.isEmpty { self.onResult?(result) }
            }
        })
    }
}
