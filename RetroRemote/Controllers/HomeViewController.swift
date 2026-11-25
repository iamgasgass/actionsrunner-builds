import UIKit

/// Schermata principale: TV corrente, connessione, cinque modalità di controllo e app rapide.
final class HomeViewController: StyledViewController {
    private enum Mode: Int, CaseIterable {
        case remote, touch, numbers, apps, text

        var title: String {
            switch self {
            case .remote: return "Tasti"
            case .touch: return "Touchpad"
            case .numbers: return "Numeri"
            case .apps: return "App"
            case .text: return "Testo"
            }
        }

        var symbol: String {
            switch self {
            case .remote: return "circle.grid.cross.fill"
            case .touch: return "hand.point.up.left.fill"
            case .numbers: return "circle.grid.3x3.fill"
            case .apps: return "square.grid.2x2.fill"
            case .text: return "keyboard"
            }
        }

        /// La riga delle app rapide appare sotto queste modalità.
        var showsQuickRow: Bool { self == .remote || self == .touch || self == .numbers }
    }

    override var hidesSystemNavigationBar: Bool { true }

    private var mode: Mode = Mode(rawValue: Preferences.shared.lastMode) ?? .remote

    private let remotePage = RemoteModeView()
    private let touchPage = TouchModeView()
    private let numberPage = NumberModeView()
    private let appsPage = AppsModeView()
    private let textPage = TextModeView()
    private var pages: [UIView] { [remotePage, touchPage, numberPage, appsPage, textPage] }

    private let pageContainer = UIView()
    private let quickRow = UIStackView()
    private var pageBottomToQuick: NSLayoutConstraint?
    private var pageBottomToBar: NSLayoutConstraint?
    private var connectHeight: NSLayoutConstraint?
    private var connectTop: NSLayoutConstraint?

    // Liquid Glass
    private let backdrop = GlassBackdropView()
    private let header = UIView()
    private let headerGlass = GlassView(cornerRadius: 28)
    private let deviceButton = UIControl()
    private let dot = UIView()
    private let deviceLabel = UILabel()
    private let statusLabel = UILabel()
    private let chevron = UIImageView()
    private let glassMenuButton = GlassCircleButton(symbol: "ellipsis")
    private let connectButton = GlassTextButton(tint: .systemBlue)
    private lazy var modeBar = GlassModeBar(items: Mode.allCases.map { (title: $0.title, symbol: $0.symbol) })

    // iOS 6
    private let surface = TexturedView(kind: .surface)
    private let led = StatusLEDView()
    private let classicMenuButton = ClassicMenuButton(symbol: "ellipsis")
    private let connectStrip = UIView()
    private let classicConnect = RemoteKeyButton(key: .ok, title: "Tocca per connetterti", shape: .pill, tint: .blue)
    private var stripHeight: NSLayoutConstraint?
    private let classicTabBar = ClassicTabBar()

    init() {
        super.init(nibName: nil, bundle: nil)
        title = "Telecomando"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    override func viewDidLoad() {
        super.viewDidLoad()
        if isGlass { buildGlass() } else { buildClassic() }

        pages.forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            pageContainer.addSubview($0)
            NSLayoutConstraint.activate([
                $0.topAnchor.constraint(equalTo: pageContainer.topAnchor),
                $0.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor),
                $0.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor),
                $0.bottomAnchor.constraint(equalTo: pageContainer.bottomAnchor)
            ])
        }
        remotePage.onKeyboard = { [weak self] in self?.select(.text) }
        textPage.onVoice = { [weak self] in self?.showVoice() }

        quickRow.axis = .horizontal
        quickRow.spacing = 10
        quickRow.distribution = .fillEqually

        ConnectionManager.shared.pinPrompt = { [weak self] title, message, hex, reply in
            guard let self = self else { reply(nil); return }
            let alert = StyledAlert(title: title, message: message)
            alert.addTextField(placeholder: hex ? "Es. A1B2C3" : "PIN",
                               keyboard: hex ? .asciiCapable : .numberPad,
                               capitalization: hex ? .allCharacters : .none)
            alert.addAction("Annulla", style: .cancel) { _ in reply(nil) }
            alert.addAction("Associa") { a in reply(a.value(0)) }
            alert.show(from: self)
        }

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(updateStatus), name: ConnectionManager.stateDidChange, object: nil)
        center.addObserver(self, selector: #selector(updateStatus), name: DeviceStore.didChange, object: nil)
        center.addObserver(self, selector: #selector(updateStatus), name: DeviceStore.selectionDidChange, object: nil)
        center.addObserver(self, selector: #selector(preferencesChanged), name: Preferences.didChange, object: nil)

        select(mode, animated: false)
        updateStatus()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateStatus()
    }

    // MARK: - Costruzione Liquid Glass

    private func buildGlass() {
        view.backgroundColor = .systemBackground
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(backdrop, at: 0)

        header.translatesAutoresizingMaskIntoConstraints = false
        headerGlass.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerGlass)

        dot.layer.cornerRadius = 5
        dot.isUserInteractionEnabled = false
        deviceLabel.font = .systemFont(ofSize: 19, weight: .bold)
        deviceLabel.textColor = .label
        deviceLabel.isUserInteractionEnabled = false
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = .secondaryLabel
        statusLabel.isUserInteractionEnabled = false
        chevron.image = systemSymbol("chevron.right", size: 13, weight: .bold)
        chevron.tintColor = .tertiaryLabel
        chevron.isUserInteractionEnabled = false
        [dot, deviceLabel, statusLabel, chevron].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            deviceButton.addSubview($0)
        }
        deviceButton.addTarget(self, action: #selector(openDevices), for: .touchUpInside)
        deviceButton.accessibilityLabel = "Scegli una TV"
        deviceButton.translatesAutoresizingMaskIntoConstraints = false
        glassMenuButton.translatesAutoresizingMaskIntoConstraints = false
        glassMenuButton.showsMenuAsPrimaryAction = true
        glassMenuButton.accessibilityLabel = "Altro"
        connectButton.translatesAutoresizingMaskIntoConstraints = false
        connectButton.addTarget(self, action: #selector(connectTapped), for: .touchUpInside)
        [deviceButton, glassMenuButton, connectButton].forEach { header.addSubview($0) }

        modeBar.translatesAutoresizingMaskIntoConstraints = false
        modeBar.onSelect = { [weak self] index in
            guard let self = self, let mode = Mode(rawValue: index) else { return }
            self.select(mode)
        }

        [header, pageContainer, quickRow, modeBar].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview($0)
        }

        let safe = view.safeAreaLayoutGuide
        let height = connectButton.heightAnchor.constraint(equalToConstant: 50)
        let top = connectButton.topAnchor.constraint(equalTo: deviceButton.bottomAnchor, constant: 6)
        connectHeight = height
        connectTop = top
        pageBottomToQuick = pageContainer.bottomAnchor.constraint(equalTo: quickRow.topAnchor, constant: -10)
        pageBottomToBar = pageContainer.bottomAnchor.constraint(equalTo: modeBar.topAnchor, constant: -10)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            header.topAnchor.constraint(equalTo: safe.topAnchor, constant: 6),
            header.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -14),
            headerGlass.topAnchor.constraint(equalTo: header.topAnchor),
            headerGlass.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            headerGlass.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            headerGlass.bottomAnchor.constraint(equalTo: header.bottomAnchor),

            deviceButton.topAnchor.constraint(equalTo: header.topAnchor, constant: 8),
            deviceButton.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            deviceButton.trailingAnchor.constraint(equalTo: glassMenuButton.leadingAnchor, constant: -10),
            deviceButton.heightAnchor.constraint(equalToConstant: 46),
            dot.leadingAnchor.constraint(equalTo: deviceButton.leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: deviceLabel.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
            deviceLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            deviceLabel.topAnchor.constraint(equalTo: deviceButton.topAnchor, constant: 2),
            chevron.leadingAnchor.constraint(equalTo: deviceLabel.trailingAnchor, constant: 6),
            chevron.centerYAnchor.constraint(equalTo: deviceLabel.centerYAnchor),
            chevron.trailingAnchor.constraint(lessThanOrEqualTo: deviceButton.trailingAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: deviceLabel.leadingAnchor),
            statusLabel.topAnchor.constraint(equalTo: deviceLabel.bottomAnchor, constant: 1),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: deviceButton.trailingAnchor),

            glassMenuButton.centerYAnchor.constraint(equalTo: deviceButton.centerYAnchor),
            glassMenuButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            glassMenuButton.widthAnchor.constraint(equalToConstant: 38),
            glassMenuButton.heightAnchor.constraint(equalToConstant: 38),

            top,
            connectButton.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            connectButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            height,
            connectButton.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -10),

            pageContainer.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            pageContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pageContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            quickRow.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 18),
            quickRow.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -18),
            quickRow.heightAnchor.constraint(equalToConstant: 46),
            quickRow.bottomAnchor.constraint(equalTo: modeBar.topAnchor, constant: -10),

            modeBar.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 18),
            modeBar.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -18),
            modeBar.heightAnchor.constraint(equalToConstant: 62),
            modeBar.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -4)
        ])
    }

    // MARK: - Costruzione iOS 6

    private func buildClassic() {
        surface.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(surface)

        classicMenuButton.showsMenuAsPrimaryAction = true
        classicMenuButton.accessibilityLabel = "Altro"
        navBar.leftView = classicMenuButton
        led.addTarget(self, action: #selector(connectTapped), for: .touchUpInside)
        navBar.rightView = led
        navBar.onTitleTap = { [weak self] in self?.openDevices() }

        connectStrip.clipsToBounds = true
        connectStrip.backgroundColor = UIColor(0, 0, 0, 0.18)
        classicConnect.fontSize = 16
        classicConnect.onPress = { [weak self] _ in self?.connectTapped() }
        classicConnect.translatesAutoresizingMaskIntoConstraints = false
        connectStrip.addSubview(classicConnect)

        classicTabBar.items = Mode.allCases.map { TabItem(title: $0.title, symbol: $0.symbol) }
        classicTabBar.onSelect = { [weak self] index in
            guard let self = self, let mode = Mode(rawValue: index) else { return }
            Feedback.selection()
            self.select(mode)
        }

        [connectStrip, pageContainer, quickRow].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview($0)
        }
        classicTabBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(classicTabBar)

        let strip = connectStrip.heightAnchor.constraint(equalToConstant: 0)
        stripHeight = strip
        pageBottomToQuick = pageContainer.bottomAnchor.constraint(equalTo: quickRow.topAnchor, constant: -8)
        pageBottomToBar = pageContainer.bottomAnchor.constraint(equalTo: classicTabBar.topAnchor, constant: -8)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: contentView.topAnchor),
            surface.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            surface.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            classicTabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            classicTabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            classicTabBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            classicTabBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -ClassicTabBar.barHeight),

            connectStrip.topAnchor.constraint(equalTo: contentView.topAnchor),
            connectStrip.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            connectStrip.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            strip,
            classicConnect.centerXAnchor.constraint(equalTo: connectStrip.centerXAnchor),
            classicConnect.centerYAnchor.constraint(equalTo: connectStrip.centerYAnchor),
            classicConnect.widthAnchor.constraint(equalTo: connectStrip.widthAnchor, constant: -40),
            classicConnect.heightAnchor.constraint(equalToConstant: 46),

            pageContainer.topAnchor.constraint(equalTo: connectStrip.bottomAnchor, constant: 8),
            pageContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            pageContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            quickRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            quickRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            quickRow.heightAnchor.constraint(equalToConstant: 40),
            quickRow.bottomAnchor.constraint(equalTo: classicTabBar.topAnchor, constant: -8)
        ])
    }

    // MARK: - Modalità

    private func select(_ newMode: Mode, animated: Bool = true) {
        mode = newMode
        Preferences.shared.lastMode = newMode.rawValue
        modeBar.selectedIndex = newMode.rawValue
        classicTabBar.selectedIndex = newMode.rawValue
        for (index, page) in pages.enumerated() {
            page.isHidden = index != newMode.rawValue
        }
        if newMode != .text { textPage.field.resignFirstResponder() }
        if newMode == .apps { appsPage.reload() }
        if newMode == .text { textPage.updateHint() }
        updateQuickRowVisibility()
        if animated, let page = pages.dropFirst(newMode.rawValue).first {
            page.alpha = 0
            UIView.animate(withDuration: 0.2) { page.alpha = 1 }
        }
    }

    private func updateQuickRowVisibility() {
        let show = mode.showsQuickRow && !quickRow.arrangedSubviews.isEmpty
        quickRow.isHidden = !show
        pageBottomToQuick?.isActive = show
        pageBottomToBar?.isActive = !show
        view.setNeedsLayout()
    }

    private func rebuildQuickRow() {
        quickRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let brand = DeviceStore.shared.selected?.brand {
            for app in QuickApps.favorites(for: brand) {
                let button = RemoteKeyButton(key: .ok, title: app.name, shape: .pill)
                button.fontSize = isGlass ? 15 : 13
                button.onPress = { _ in ConnectionManager.shared.launch(app) }
                quickRow.addArrangedSubview(button)
            }
        }
        updateQuickRowVisibility()
    }

    // MARK: - Stato

    @objc private func preferencesChanged() {
        rebuildQuickRow()
        textPage.updateHint()
    }

    @objc private func updateStatus() {
        let device = DeviceStore.shared.selected
        let state = ConnectionManager.shared.state
        let name = device?.name ?? "Scegli una TV"
        let status: String
        let connectTitle: String
        var connectSymbol: String? = "play.tv.fill"
        var spinning = false
        var showConnect = true
        switch (device, state) {
        case (nil, _):
            status = "Nessuna TV selezionata"
            connectTitle = "Scegli una TV"
            connectSymbol = "magnifyingglass"
        case (_, .connected):
            status = "Connessa · \(device?.brand.shortName ?? "")"
            connectTitle = ""
            showConnect = false
        case (_, .connecting):
            status = "Connessione in corso…"
            connectTitle = "Connessione…"
            spinning = true
        case (_, .pairing):
            status = "Accetta la richiesta sulla TV"
            connectTitle = "In attesa della TV…"
            spinning = true
        case (_, .failed(let message)):
            status = message
            connectTitle = "Riprova a connetterti"
            connectSymbol = "arrow.clockwise"
        default:
            status = "Non connessa"
            connectTitle = "Tocca per connetterti"
        }

        if isGlass {
            deviceLabel.text = name
            statusLabel.text = status
            dot.backgroundColor = dotColor(device: device, state: state)
            connectButton.configure(title: connectTitle, symbol: connectSymbol, spinning: spinning)
            let targetHeight: CGFloat = showConnect ? 50 : 0
            if connectHeight?.constant != targetHeight {
                connectHeight?.constant = targetHeight
                connectTop?.constant = showConnect ? 6 : 0
                UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
                    self.connectButton.alpha = showConnect ? 1 : 0
                    self.view.layoutIfNeeded()
                }
            }
            connectButton.isUserInteractionEnabled = showConnect
            glassMenuButton.menu = buildMenu()
        } else {
            navBar.title = name
            navBar.subtitle = status + "  ▾"
            switch (device, state) {
            case (nil, _): led.led = .off
            case (_, .connected): led.led = .green
            case (_, .connecting), (_, .pairing): led.led = .amber
            case (_, .failed): led.led = .red
            default: led.led = .off
            }
            classicConnect.title = connectTitle
            stripHeight?.constant = showConnect ? 62 : 0
            UIView.animate(withDuration: 0.25) { self.view.layoutIfNeeded() }
            classicMenuButton.menu = buildMenu()
        }
        rebuildQuickRow()
        touchPage.updateCapabilities()
        textPage.updateHint()
        if mode == .apps { appsPage.reload() }
    }

    private func dotColor(device: TVDevice?, state: ConnectionState) -> UIColor {
        guard device != nil else { return .systemGray }
        switch state {
        case .connected: return .systemGreen
        case .connecting, .pairing: return .systemOrange
        default: return .systemRed
        }
    }

    // MARK: - Menu "…"

    private func buildMenu() -> UIMenu {
        let current = InterfaceStyle.current
        let styleActions = InterfaceStyle.allCases.map { style in
            UIAction(title: style.title, image: systemSymbol(style.symbol),
                     state: style == current ? .on : .off) { _ in
                Preferences.shared.interfaceStyle = style
            }
        }
        let styleMenu = UIMenu(title: "Interfaccia", image: systemSymbol("paintbrush.fill"), children: styleActions)

        let appearance = ThemeManager.shared.mode
        let appearanceActions = AppearanceMode.allCases.map { mode in
            UIAction(title: mode.title, state: mode == appearance ? .on : .off) { [weak self] _ in
                ThemeManager.shared.mode = mode
                self?.updateStatus()
            }
        }
        let appearanceMenu = UIMenu(title: "Aspetto", image: systemSymbol("circle.lefthalf.filled"), children: appearanceActions)

        var tvActions: [UIMenuElement] = [
            UIAction(title: "Scegli una TV", image: systemSymbol("tv")) { [weak self] _ in self?.openDevices() },
            UIAction(title: "Ricerca vocale", image: systemSymbol("mic.fill")) { [weak self] _ in self?.showVoice() }
        ]
        if DeviceStore.shared.selected != nil {
            if ConnectionManager.shared.isConnected {
                tvActions.append(UIAction(title: "Disconnetti", image: systemSymbol("xmark.circle")) { _ in
                    ConnectionManager.shared.disconnect()
                })
            } else {
                tvActions.append(UIAction(title: "Connetti", image: systemSymbol("bolt.horizontal.fill")) { _ in
                    ConnectionManager.shared.reconnect()
                })
            }
            if DeviceStore.shared.selected?.mac != nil {
                tvActions.append(UIAction(title: "Accendi la TV", image: systemSymbol("power")) { _ in
                    if let device = DeviceStore.shared.selected { ConnectionManager.shared.wake(device) }
                })
            }
        }
        let settings = UIAction(title: "Impostazioni", image: systemSymbol("gearshape.fill")) { [weak self] _ in
            self?.openSettings()
        }
        return UIMenu(title: "", children: [
            UIMenu(title: "", options: .displayInline, children: tvActions),
            UIMenu(title: "", options: .displayInline, children: [styleMenu, appearanceMenu]),
            UIMenu(title: "", options: .displayInline, children: [settings])
        ])
    }

    // MARK: - Azioni

    @objc private func connectTapped() {
        Feedback.tap()
        if DeviceStore.shared.selected == nil {
            openDevices()
        } else {
            ConnectionManager.shared.reconnect()
        }
    }

    @objc private func openDevices() {
        navigationController?.pushViewController(DevicesViewController(), animated: true)
    }

    private func openSettings() {
        navigationController?.pushViewController(SettingsViewController(), animated: true)
    }

    private func showVoice() {
        guard DeviceStore.shared.selected != nil else {
            openDevices()
            return
        }
        let voice = VoiceSearchViewController()
        voice.onResult = { [weak self] text in
            guard let self = self else { return }
            if ConnectionManager.shared.controller?.supportsText == true {
                self.textPage.sendDictation(text)
            } else {
                let alert = StyledAlert(title: "Non disponibile", message: "Questa TV non accetta testo dalla rete.")
                alert.addAction("OK", style: .cancel)
                alert.show(from: self)
            }
        }
        present(voice, animated: false)
    }
}
