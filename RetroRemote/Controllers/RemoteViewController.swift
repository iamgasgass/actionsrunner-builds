import UIKit

final class RemoteViewController: ClassicViewController, UIScrollViewDelegate {
    private let surface = TexturedView(kind: .surface)
    private let scroll = UIScrollView()
    private let pageControl = UIPageControl()
    private let page1 = UIView()
    private let page2 = UIView()
    private let led = StatusLEDView()
    private let keyboardButton = ClassicBarButton(symbol: "keyboard")

    init() {
        super.init(nibName: nil, bundle: nil)
        title = "Telecomando"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    override func viewDidLoad() {
        super.viewDidLoad()
        surface.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(surface)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.isPagingEnabled = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceVertical = false
        scroll.delaysContentTouches = false
        scroll.delegate = self
        contentView.addSubview(scroll)

        pageControl.translatesAutoresizingMaskIntoConstraints = false
        pageControl.numberOfPages = 2
        pageControl.isUserInteractionEnabled = true
        pageControl.addTarget(self, action: #selector(pageChanged), for: .valueChanged)
        contentView.addSubview(pageControl)

        [page1, page2].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            scroll.addSubview($0)
        }

        let content = scroll.contentLayoutGuide
        let frame = scroll.frameLayoutGuide
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: contentView.topAnchor),
            surface.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            surface.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            scroll.topAnchor.constraint(equalTo: contentView.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: pageControl.topAnchor),

            pageControl.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            pageControl.bottomAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.bottomAnchor, constant: -2),
            pageControl.heightAnchor.constraint(equalToConstant: 24),

            page1.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            page1.topAnchor.constraint(equalTo: content.topAnchor),
            page1.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            page1.widthAnchor.constraint(equalTo: frame.widthAnchor),
            page1.heightAnchor.constraint(equalTo: frame.heightAnchor),

            page2.leadingAnchor.constraint(equalTo: page1.trailingAnchor),
            page2.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            page2.topAnchor.constraint(equalTo: content.topAnchor),
            page2.widthAnchor.constraint(equalTo: frame.widthAnchor),
            page2.heightAnchor.constraint(equalTo: frame.heightAnchor)
        ])

        keyboardButton.addTarget(self, action: #selector(showKeyboard), for: .touchUpInside)
        navBar.leftView = keyboardButton
        led.addTarget(self, action: #selector(reconnect), for: .touchUpInside)
        navBar.rightView = led

        buildMainPage()
        buildNumberPage()

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(updateStatus), name: ConnectionManager.stateDidChange, object: nil)
        center.addObserver(self, selector: #selector(updateStatus), name: DeviceStore.didChange, object: nil)
        center.addObserver(self, selector: #selector(updateStatus), name: DeviceStore.selectionDidChange, object: nil)
        applyTheme()
        updateStatus()
    }

    override func applyTheme() {
        let p = Theme.palette
        pageControl.pageIndicatorTintColor = p.pageDot
        pageControl.currentPageIndicatorTintColor = p.pageDotCurrent
    }

    // MARK: - Costruzione

    private func key(_ k: RemoteKey, title: String? = nil, symbol: String? = nil,
                     shape: RemoteKeyButton.Shape = .circle, tint: RemoteKeyButton.Tint = .normal,
                     size: CGSize, repeats: Bool = false, fontSize: CGFloat = 13, symbolSize: CGFloat = 17) -> RemoteKeyButton {
        let b = RemoteKeyButton(key: k, title: title, symbol: symbol, shape: shape, tint: tint, repeats: repeats)
        b.fontSize = fontSize
        b.symbolSize = symbolSize
        b.onPress = { ConnectionManager.shared.press($0) }
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: size.width).isActive = true
        b.heightAnchor.constraint(equalToConstant: size.height).isActive = true
        return b
    }

    private func row(_ views: [UIView], spacing: CGFloat? = nil) -> UIStackView {
        let s = UIStackView(arrangedSubviews: views)
        s.axis = .horizontal
        s.alignment = .center
        if let spacing = spacing {
            s.spacing = spacing
            s.distribution = .fill
        } else {
            s.distribution = .equalSpacing
        }
        return s
    }

    private func column(in page: UIView) -> UIStackView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.distribution = .equalSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(stack)
        let preferredWidth = stack.widthAnchor.constraint(equalTo: page.widthAnchor, constant: -36)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: page.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -6),
            stack.centerXAnchor.constraint(equalTo: page.centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
            preferredWidth
        ])
        return stack
    }

    private func buildMainPage() {
        let stack = column(in: page1)
        let wide = CGSize(width: 88, height: 40)
        let round = CGSize(width: 56, height: 56)

        let top = row([
            key(.power, symbol: "power", tint: .power, size: round, symbolSize: 20),
            key(.input, title: "INPUT", shape: .pill, size: CGSize(width: 96, height: 36), fontSize: 13),
            key(.mute, symbol: "speaker.slash.fill", size: round)
        ])
        let nav = row([
            key(.back, symbol: "arrow.uturn.backward", shape: .rounded, size: wide),
            key(.home, symbol: "house.fill", shape: .rounded, size: wide),
            key(.menu, symbol: "line.3.horizontal", shape: .rounded, size: wide)
        ])

        let volume = RockerView(up: .volumeUp, down: .volumeDown, label: "VOL")
        let channel = RockerView(up: .channelUp, down: .channelDown, label: "CH")
        let dpad = DPadView()
        for rocker in [volume, channel] { rocker.onPress = { ConnectionManager.shared.press($0) } }
        dpad.onPress = { ConnectionManager.shared.press($0) }
        let middle = row([volume, dpad, channel])
        [volume, channel, dpad].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        let dpadWidth = dpad.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.62)
        dpadWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            dpad.heightAnchor.constraint(equalTo: dpad.widthAnchor),
            dpadWidth,
            dpad.heightAnchor.constraint(lessThanOrEqualTo: page1.heightAnchor, multiplier: 0.44),
            volume.widthAnchor.constraint(equalToConstant: 58),
            channel.widthAnchor.constraint(equalToConstant: 58),
            volume.heightAnchor.constraint(equalTo: dpad.heightAnchor, multiplier: 0.9),
            channel.heightAnchor.constraint(equalTo: dpad.heightAnchor, multiplier: 0.9)
        ])

        let media = row([
            key(.rewind, symbol: "backward.fill", size: round, repeats: true),
            key(.playPause, symbol: "playpause.fill", size: CGSize(width: 64, height: 64), symbolSize: 20),
            key(.fastForward, symbol: "forward.fill", size: round, repeats: true)
        ])

        [top, nav, middle, media].forEach {
            stack.addArrangedSubview($0)
            $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func buildNumberPage() {
        let stack = column(in: page2)
        let size = CGSize(width: 62, height: 62)
        var rows: [UIView] = []
        for r in 0..<3 {
            rows.append(row((1...3).map { c in
                let n = r * 3 + c
                return key(.digit(n), title: "\(n)", size: size, fontSize: 24)
            }))
        }
        rows.append(row([
            key(.info, symbol: "info", size: size, symbolSize: 20),
            key(.digit(0), title: "0", size: size, fontSize: 24),
            key(.exit, title: "EXIT", size: size, fontSize: 13)
        ]))
        let pill = CGSize(width: 64, height: 30)
        rows.append(row([
            key(.red, shape: .pill, tint: .red, size: pill),
            key(.green, shape: .pill, tint: .green, size: pill),
            key(.yellow, shape: .pill, tint: .yellow, size: pill),
            key(.blue, shape: .pill, tint: .blue, size: pill)
        ]))
        let wide = CGSize(width: 100, height: 40)
        rows.append(row([
            key(.guide, title: "GUIDA", shape: .rounded, size: wide),
            key(.stop, symbol: "stop.fill", shape: .rounded, size: wide)
        ]))
        rows.forEach {
            stack.addArrangedSubview($0)
            $0.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        }
    }

    // MARK: - Stato

    @objc private func updateStatus() {
        let device = DeviceStore.shared.selected
        navBar.title = device?.name ?? "Telecomando"
        let state = ConnectionManager.shared.state
        navBar.subtitle = device == nil ? "Nessun dispositivo" : state.label
        switch (device, state) {
        case (nil, _): led.led = .off
        case (_, .connected): led.led = .green
        case (_, .connecting), (_, .pairing): led.led = .amber
        case (_, .failed): led.led = .red
        default: led.led = .off
        }
    }

    @objc private func reconnect() {
        Feedback.tap()
        if DeviceStore.shared.selected == nil {
            rootController?.selectTab(2)
        } else {
            ConnectionManager.shared.reconnect()
        }
    }

    @objc private func showKeyboard() {
        guard DeviceStore.shared.selected != nil else {
            let alert = ClassicAlertController(title: "Nessuna TV",
                                               message: "Aggiungi una TV nella sezione Dispositivi per usare la tastiera.")
            alert.addAction("Annulla", style: .cancel)
            alert.addAction("Dispositivi") { [weak self] _ in self?.rootController?.selectTab(2) }
            alert.show(from: self)
            return
        }
        let alert = ClassicAlertController(title: "Invia testo", message: "Il testo verrà scritto nel campo attivo sulla TV.")
        alert.addTextField(placeholder: "Testo")
        alert.addAction("Annulla", style: .cancel)
        alert.addAction("Invia") { a in
            guard let text = a.textFields.first?.text, !text.isEmpty else { return }
            ConnectionManager.shared.controller?.sendText(text)
        }
        alert.show(from: self)
    }

    @objc private func pageChanged() {
        let x = CGFloat(pageControl.currentPage) * scroll.bounds.width
        scroll.setContentOffset(CGPoint(x: x, y: 0), animated: true)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView.bounds.width > 0 else { return }
        pageControl.currentPage = Int((scrollView.contentOffset.x / scrollView.bounds.width).rounded())
    }
}
