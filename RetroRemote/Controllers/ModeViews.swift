import UIKit

/// Crea un tasto collegato alla TV corrente.
func makeRemoteKey(_ key: RemoteKey, title: String? = nil, symbol: String? = nil,
                   shape: RemoteKeyButton.Shape = .circle, tint: RemoteKeyButton.Tint = .normal,
                   repeats: Bool = false, fontSize: CGFloat = 13, symbolSize: CGFloat = 18) -> RemoteKeyButton {
    let button = RemoteKeyButton(key: key, title: title, symbol: symbol, shape: shape, tint: tint, repeats: repeats)
    button.fontSize = fontSize
    button.symbolSize = symbolSize
    button.onPress = { ConnectionManager.shared.press($0) }
    return button
}

/// Distribuisce le viste in una riga larga `width`, centrata in `x0`, alla quota `y`.
private func layoutRow(_ views: [UIView], x0: CGFloat, width: CGFloat, y: CGFloat,
                       itemWidth: CGFloat, height: CGFloat) {
    guard !views.isEmpty else { return }
    if views.count == 1 {
        views[0].frame = CGRect(x: x0 + (width - itemWidth) / 2, y: y, width: itemWidth, height: height)
        return
    }
    let gap = (width - itemWidth * CGFloat(views.count)) / CGFloat(views.count - 1)
    for (index, view) in views.enumerated() {
        view.frame = CGRect(x: x0 + CGFloat(index) * (itemWidth + gap), y: y, width: itemWidth, height: height)
    }
}

// MARK: - Telecomando

final class RemoteModeView: UIView {
    var onKeyboard: (() -> Void)?

    private let power = makeRemoteKey(.power, symbol: "power", tint: .power, symbolSize: 19)
    private let settingsKey = makeRemoteKey(.settings, symbol: "gearshape.fill")
    private let infoKey = makeRemoteKey(.info, symbol: "info", symbolSize: 18)
    private let mute = makeRemoteKey(.mute, symbol: "speaker.slash.fill")
    private let dpad = DPadView()
    private let back = makeRemoteKey(.back, symbol: "arrow.uturn.backward", shape: .rounded)
    private let home = makeRemoteKey(.home, symbol: "house.fill", shape: .rounded)
    private let menu = makeRemoteKey(.menu, symbol: "line.3.horizontal", shape: .rounded)
    private let exit = makeRemoteKey(.exit, title: "EXIT", shape: .rounded, fontSize: 13)
    private let rewind = makeRemoteKey(.rewind, symbol: "backward.fill", shape: .pill, repeats: true)
    private let playPause = makeRemoteKey(.playPause, symbol: "playpause.fill", shape: .pill, symbolSize: 19)
    private let forward = makeRemoteKey(.fastForward, symbol: "forward.fill", shape: .pill, repeats: true)
    private let volume = RockerView(up: .volumeUp, down: .volumeDown, label: "VOL")
    private let channel = RockerView(up: .channelUp, down: .channelDown, label: "CH")
    private let input = makeRemoteKey(.input, symbol: "rectangle.portrait.and.arrow.right", symbolSize: 17)
    private let guide = makeRemoteKey(.guide, title: "GUIDE", fontSize: 12)
    private let keyboard = makeRemoteKey(.ok, symbol: "keyboard", symbolSize: 17)
    private let previous = makeRemoteKey(.previousChannel, title: "PRE-CH", fontSize: 11)

    override init(frame: CGRect) {
        super.init(frame: frame)
        dpad.onPress = { ConnectionManager.shared.press($0) }
        volume.onPress = { ConnectionManager.shared.press($0) }
        channel.onPress = { ConnectionManager.shared.press($0) }
        keyboard.onPress = { [weak self] _ in self?.onKeyboard?() }
        input.accessibilityLabel = "Sorgente"
        [power, settingsKey, infoKey, mute, dpad, back, home, menu, exit, rewind, playPause, forward,
         volume, channel, input, guide, keyboard, previous].forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = min(bounds.width - 32, 420)
        let x0 = (bounds.width - width) / 2
        let base: [CGFloat] = [52, min(width * 0.6, 236), 44, 46, 134]
        let gap: CGFloat = 14
        let required = base.reduce(0, +) + gap * CGFloat(base.count - 1) + 12
        let s = min(1, bounds.height / required)
        var y = 6 * s
        let key = 52 * s
        layoutRow([power, settingsKey, infoKey, mute], x0: x0, width: width, y: y, itemWidth: key, height: key)
        y += key + gap * s
        let pad = base[1] * s
        dpad.frame = CGRect(x: bounds.midX - pad / 2, y: y, width: pad, height: pad)
        y += pad + gap * s
        let small = (width - 3 * 10) / 4
        layoutRow([back, home, menu, exit], x0: x0, width: width, y: y, itemWidth: small, height: 44 * s)
        y += 44 * s + gap * s
        let third = (width - 2 * 12) / 3
        layoutRow([rewind, playPause, forward], x0: x0, width: width, y: y, itemWidth: third, height: 46 * s)
        y += 46 * s + gap * s
        let block = 134 * s
        let rockerWidth: CGFloat = 60
        volume.frame = CGRect(x: x0, y: y, width: rockerWidth, height: block)
        channel.frame = CGRect(x: x0 + width - rockerWidth, y: y, width: rockerWidth, height: block)
        let middleX = x0 + rockerWidth + 10
        let middleWidth = width - (rockerWidth + 10) * 2
        let cell = min(56 * s, (block - 8) / 2, (middleWidth - 10) / 2)
        let gridWidth = min(middleWidth, cell * 2 + 40)
        let gx = middleX + (middleWidth - gridWidth) / 2
        layoutRow([input, guide], x0: gx, width: gridWidth, y: y + (block / 2 - cell) / 2, itemWidth: cell, height: cell)
        layoutRow([keyboard, previous], x0: gx, width: gridWidth, y: y + block / 2 + (block / 2 - cell) / 2,
                  itemWidth: cell, height: cell)
    }
}

// MARK: - Touchpad

final class TouchModeView: UIView {
    let touchpad = TouchpadView()
    private let back = makeRemoteKey(.back, symbol: "arrow.uturn.backward", shape: .rounded)
    private let home = makeRemoteKey(.home, symbol: "house.fill", shape: .rounded)
    private let menu = makeRemoteKey(.menu, symbol: "line.3.horizontal", shape: .rounded)
    private let rewind = makeRemoteKey(.rewind, symbol: "backward.fill", shape: .pill, repeats: true)
    private let playPause = makeRemoteKey(.playPause, symbol: "playpause.fill", shape: .pill)
    private let forward = makeRemoteKey(.fastForward, symbol: "forward.fill", shape: .pill, repeats: true)
    private let volumeDown = makeRemoteKey(.volumeDown, symbol: "speaker.wave.1.fill", shape: .rounded, repeats: true)
    private let volumeUp = makeRemoteKey(.volumeUp, symbol: "speaker.wave.3.fill", shape: .rounded, repeats: true)
    private let pointerLabel = UILabel()
    private let pointerToggle: UIControl
    private var pointerAvailable = false

    override init(frame: CGRect) {
        pointerToggle = InterfaceStyle.isGlass ? (UISwitch() as UIControl) : (ClassicSwitch(frame: .zero) as UIControl)
        super.init(frame: frame)
        touchpad.onKey = { ConnectionManager.shared.press($0) }
        touchpad.onPointerMove = { dx, dy in ConnectionManager.shared.controller?.pointerMove(dx: dx, dy: dy) }
        touchpad.onPointerClick = { ConnectionManager.shared.controller?.pointerClick() }
        pointerLabel.text = "Modalità mouse"
        pointerLabel.font = InterfaceStyle.isGlass ? .systemFont(ofSize: 15, weight: .semibold) : Fonts.bold(15)
        pointerToggle.addTarget(self, action: #selector(pointerChanged), for: .valueChanged)
        [touchpad, back, home, menu, volumeDown, volumeUp, rewind, playPause, forward, pointerLabel, pointerToggle].forEach {
            addSubview($0)
        }
        applyTheme()
        NotificationCenter.default.addObserver(self, selector: #selector(applyTheme), name: ThemeManager.didChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    @objc private func applyTheme() {
        if InterfaceStyle.isGlass {
            pointerLabel.textColor = .label
        } else {
            let p = Theme.palette
            pointerLabel.textColor = p.surfaceText
            pointerLabel.shadowColor = p.surfaceTextShadow
            pointerLabel.shadowOffset = p.surfaceTextShadowOffset
        }
    }

    private var pointerOn: Bool {
        (pointerToggle as? UISwitch)?.isOn ?? (pointerToggle as? ClassicSwitch)?.isOn ?? false
    }

    @objc private func pointerChanged() {
        touchpad.pointerMode = pointerOn
    }

    func updateCapabilities() {
        pointerAvailable = ConnectionManager.shared.controller?.supportsPointer ?? false
        pointerLabel.isHidden = !pointerAvailable
        pointerToggle.isHidden = !pointerAvailable
        if !pointerAvailable {
            touchpad.pointerMode = false
            (pointerToggle as? UISwitch)?.setOn(false, animated: false)
            (pointerToggle as? ClassicSwitch)?.setOn(false, animated: false)
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = min(bounds.width - 32, 440)
        let x0 = (bounds.width - width) / 2
        let rowH: CGFloat = 44
        let gap: CGFloat = 12
        var bottom = bounds.height - 4
        let third = (width - 2 * 12) / 3
        layoutRow([rewind, playPause, forward], x0: x0, width: width, y: bottom - 46, itemWidth: third, height: 46)
        bottom -= 46 + gap
        let fifth = (width - 4 * 10) / 5
        layoutRow([volumeDown, back, home, menu, volumeUp], x0: x0, width: width, y: bottom - rowH, itemWidth: fifth, height: rowH)
        bottom -= rowH + gap
        if pointerAvailable {
            let toggleSize = pointerToggle.sizeThatFits(.zero)
            pointerToggle.frame = CGRect(x: x0 + width - toggleSize.width, y: bottom - 31, width: toggleSize.width, height: toggleSize.height)
            pointerLabel.frame = CGRect(x: x0, y: bottom - 31, width: width - toggleSize.width - 10, height: 31)
            bottom -= 31 + gap
        }
        touchpad.frame = CGRect(x: x0, y: 6, width: width, height: max(120, bottom - 6))
    }
}

// MARK: - Tastierino

final class NumberModeView: UIView {
    private var digits: [RemoteKeyButton] = []
    private let dash = makeRemoteKey(.dash, title: "–", fontSize: 22)
    private let exit = makeRemoteKey(.exit, title: "EXIT", fontSize: 13)
    private let colors = [makeRemoteKey(.red, shape: .pill, tint: .red),
                          makeRemoteKey(.green, shape: .pill, tint: .green),
                          makeRemoteKey(.yellow, shape: .pill, tint: .yellow),
                          makeRemoteKey(.blue, shape: .pill, tint: .blue)]
    private let guide = makeRemoteKey(.guide, title: "GUIDE", shape: .pill, fontSize: 13)
    private let info = makeRemoteKey(.info, title: "INFO", shape: .pill, fontSize: 13)
    private let previous = makeRemoteKey(.previousChannel, title: "PRE-CH", shape: .pill, fontSize: 13)

    override init(frame: CGRect) {
        super.init(frame: frame)
        for n in 0...9 {
            let key = makeRemoteKey(.digit(n), title: "\(n)", fontSize: 26)
            key.accessibilityLabel = "\(n)"
            digits.append(key)
            addSubview(key)
        }
        ([dash, exit, guide, info, previous] + colors).forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = min(bounds.width - 48, 340)
        let x0 = (bounds.width - width) / 2
        let gap: CGFloat = 14
        let fromWidth = (width - 2 * 24) / 3
        let fromHeight = (bounds.height - 6 - 30 - 44 - gap * 6) / 4
        let key = max(40, min(76, fromWidth, fromHeight))
        var y: CGFloat = 6
        for row in 0..<3 {
            let views = (1...3).map { digits[row * 3 + $0] }
            layoutRow(views, x0: x0, width: width, y: y, itemWidth: key, height: key)
            y += key + gap
        }
        layoutRow([dash, digits[0], exit], x0: x0, width: width, y: y, itemWidth: key, height: key)
        y += key + gap * 1.5
        let wide = min(bounds.width - 32, 420)
        let wx = (bounds.width - wide) / 2
        layoutRow(colors, x0: wx, width: wide, y: y, itemWidth: (wide - 3 * 10) / 4, height: 30)
        y += 30 + gap
        layoutRow([guide, info, previous], x0: wx, width: wide, y: y, itemWidth: (wide - 2 * 12) / 3, height: 44)
    }
}

// MARK: - App

private final class AppTileCell: UICollectionViewCell {
    private let glassMode = InterfaceStyle.isGlass
    private let tile = UIView()
    private let tileGradient = CAGradientLayer()
    private let tileImage = UIImageView()
    private let tileTitle = UILabel()
    let icon = AppIconView()
    let label = UILabel()
    private(set) var appName = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        if glassMode {
            tile.layer.cornerRadius = 20
            tile.layer.cornerCurve = .continuous
            tile.clipsToBounds = true
            tile.layer.addSublayer(tileGradient)
            tileImage.contentMode = .scaleAspectFit
            tileTitle.font = .systemFont(ofSize: 17, weight: .bold)
            tileTitle.textColor = .white
            tileTitle.textAlignment = .center
            tileTitle.numberOfLines = 2
            tileTitle.adjustsFontSizeToFitWidth = true
            tileTitle.minimumScaleFactor = 0.6
            tile.addSubview(tileImage)
            tile.addSubview(tileTitle)
            contentView.addSubview(tile)
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.textColor = .label
        } else {
            contentView.addSubview(icon)
            label.font = Fonts.bold(11)
        }
        label.textAlignment = .center
        label.lineBreakMode = .byTruncatingTail
        contentView.addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    func configure(_ app: TVApp) {
        appName = app.name
        label.text = app.name
        if glassMode {
            tileGradient.colors = QuickApps.tileColors(for: app.name).map { $0.cgColor }
            tileTitle.text = app.name
            tileImage.image = nil
            tileTitle.isHidden = false
        } else {
            icon.placeholderName = app.name
            icon.image = nil
            let p = Theme.palette
            label.textColor = p.isDark ? .white : p.surfaceText
            label.shadowColor = p.surfaceTextShadow
            label.shadowOffset = p.surfaceTextShadowOffset
        }
    }

    func setImage(_ image: UIImage) {
        if glassMode {
            tileImage.image = image
            tileTitle.isHidden = true
        } else {
            icon.image = image
        }
    }

    override var isHighlighted: Bool {
        didSet {
            if glassMode { animatePress(tile, pressed: isHighlighted) } else { icon.pressed = isHighlighted }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if glassMode {
            let h = bounds.height - 20
            tile.frame = CGRect(x: 0, y: 0, width: bounds.width, height: h)
            tileGradient.frame = tile.bounds
            tileGradient.startPoint = CGPoint(x: 0, y: 0)
            tileGradient.endPoint = CGPoint(x: 1, y: 1)
            tileImage.frame = tile.bounds.insetBy(dx: 14, dy: 14)
            tileTitle.frame = tile.bounds.insetBy(dx: 8, dy: 8)
            label.frame = CGRect(x: 0, y: h + 3, width: bounds.width, height: 16)
        } else {
            let side = min(bounds.width, 66)
            icon.frame = CGRect(x: (bounds.width - side) / 2, y: 0, width: side, height: side)
            label.frame = CGRect(x: 0, y: side + 2, width: bounds.width, height: 15)
        }
    }
}

final class AppsModeView: UIView, UICollectionViewDataSource, UICollectionViewDelegate {
    private let layout = UICollectionViewFlowLayout()
    private lazy var collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
    private let emptyLabel = UILabel()
    private let refresh = UIRefreshControl()
    private var apps: [TVApp] = []
    private var loadedFor: UUID?
    private var loading = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        collection.backgroundColor = .clear
        collection.dataSource = self
        collection.delegate = self
        collection.alwaysBounceVertical = true
        collection.register(AppTileCell.self, forCellWithReuseIdentifier: "app")
        collection.refreshControl = refresh
        refresh.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        layout.minimumLineSpacing = 16
        layout.minimumInteritemSpacing = 12
        layout.sectionInset = UIEdgeInsets(top: 8, left: 18, bottom: 20, right: 18)
        addSubview(collection)
        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyLabel.font = InterfaceStyle.isGlass ? .systemFont(ofSize: 16, weight: .medium) : Fonts.bold(16)
        addSubview(emptyLabel)
        applyTheme()
        NotificationCenter.default.addObserver(self, selector: #selector(applyTheme), name: ThemeManager.didChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    @objc private func applyTheme() {
        if InterfaceStyle.isGlass {
            emptyLabel.textColor = .secondaryLabel
        } else {
            let p = Theme.palette
            emptyLabel.textColor = p.surfaceText
            emptyLabel.shadowColor = p.surfaceTextShadow
            emptyLabel.shadowOffset = p.surfaceTextShadowOffset
        }
        collection.reloadData()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        collection.frame = bounds
        emptyLabel.frame = bounds.insetBy(dx: 30, dy: 0)
        let width = bounds.width - layout.sectionInset.left - layout.sectionInset.right
        guard width > 0 else { return }
        let glass = InterfaceStyle.isGlass
        let columns = glass ? max(2, Int(width / 150)) : max(4, Int(width / 88))
        let itemWidth = floor((width - CGFloat(columns - 1) * layout.minimumInteritemSpacing) / CGFloat(columns))
        let size = glass ? CGSize(width: itemWidth, height: itemWidth * 0.62 + 20) : CGSize(width: itemWidth, height: min(itemWidth, 66) + 20)
        if layout.itemSize != size { layout.itemSize = size }
    }

    @objc private func pullToRefresh() { reload(force: true) }

    /// Carica le app installate dalla TV; senza connessione mostra il catalogo per la piattaforma.
    func reload(force: Bool = false) {
        let device = DeviceStore.shared.selected
        guard let controller = ConnectionManager.shared.controller, let current = device else {
            apps = []
            finishLoading()
            return
        }
        let fallback = QuickApps.apps(for: current.brand)
        guard controller.state == .connected else {
            apps = fallback
            finishLoading()
            return
        }
        if !force, loadedFor == current.id, !apps.isEmpty { return }
        guard !loading else { return }
        loading = true
        controller.fetchApps { [weak self] list in
            guard let self = self else { return }
            self.loading = false
            self.loadedFor = current.id
            self.apps = list.isEmpty ? fallback : list
            self.finishLoading()
        }
    }

    private func finishLoading() {
        refresh.endRefreshing()
        collection.reloadData()
        if DeviceStore.shared.selected == nil {
            emptyLabel.text = "Scegli una TV per vedere le sue app."
        } else {
            emptyLabel.text = apps.isEmpty ? "Nessuna app disponibile per questa TV." : nil
        }
        emptyLabel.isHidden = !apps.isEmpty
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { apps.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "app", for: indexPath) as! AppTileCell
        let app = apps[indexPath.item]
        cell.configure(app)
        if let url = app.iconURL {
            ImageLoader.shared.load(url) { [weak cell] image in
                guard let image = image, let cell = cell, cell.appName == app.name else { return }
                cell.setImage(image)
            }
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        ConnectionManager.shared.launch(apps[indexPath.item])
        collectionView.deselectItem(at: indexPath, animated: true)
    }
}

// MARK: - Testo

/// Campo di testo bianco incassato dello stile iOS 6.
private final class ClassicFieldBackground: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = UIBezierPath(roundedRect: r, cornerRadius: 6)
        UIColor.white.setFill()
        path.fill()
        ctx.saveGState()
        path.addClip()
        let shade = CGRect(x: r.minX, y: r.minY, width: r.width, height: 7)
        Draw.fillVertical(UIBezierPath(rect: shade), shade, [UIColor(0, 0, 0, 0.25), UIColor(0, 0, 0, 0)])
        ctx.restoreGState()
        UIColor(90, 90, 96).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

final class TextModeView: UIView, UITextFieldDelegate {
    var onVoice: (() -> Void)?

    private let fieldBackground: UIView
    let field = UITextField()
    private let hint = UILabel()
    private let liveLabel = UILabel()
    private let liveToggle: UIControl
    private let backspace = makeRemoteKey(.backspace, symbol: "delete.left.fill", shape: .rounded, repeats: true)
    private let enter = makeRemoteKey(.enter, symbol: "return", shape: .rounded)
    private let voice = makeRemoteKey(.ok, symbol: "mic.fill", shape: .rounded)
    private let send = makeRemoteKey(.ok, title: "Invia", shape: .rounded, tint: .accent, fontSize: 16)
    private let clear = makeRemoteKey(.ok, symbol: "xmark", shape: .rounded)

    override init(frame: CGRect) {
        let glass = InterfaceStyle.isGlass
        fieldBackground = glass ? (GlassView(cornerRadius: 22) as UIView) : (ClassicFieldBackground() as UIView)
        liveToggle = glass ? (UISwitch() as UIControl) : (ClassicSwitch(frame: .zero) as UIControl)
        super.init(frame: frame)
        addSubview(fieldBackground)
        field.placeholder = "Scrivi qui per digitare sulla TV"
        field.font = glass ? .systemFont(ofSize: 18) : Fonts.regular(18)
        field.textColor = glass ? .label : .black
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.returnKeyType = .send
        field.clearButtonMode = .never
        field.delegate = self
        field.keyboardAppearance = glass ? .default : .dark
        addSubview(field)
        hint.numberOfLines = 0
        hint.textAlignment = .center
        hint.font = glass ? .systemFont(ofSize: 13) : Fonts.regular(13)
        addSubview(hint)
        liveLabel.text = "Digitazione dal vivo"
        liveLabel.font = glass ? .systemFont(ofSize: 15, weight: .semibold) : Fonts.bold(15)
        addSubview(liveLabel)
        liveToggle.addTarget(self, action: #selector(liveChanged), for: .valueChanged)
        addSubview(liveToggle)
        voice.onPress = { [weak self] _ in self?.onVoice?() }
        send.onPress = { [weak self] _ in self?.sendField() }
        clear.onPress = { [weak self] _ in
            self?.field.text = ""
            Feedback.selection()
        }
        [backspace, enter, voice, send, clear].forEach { addSubview($0) }
        syncLive()
        applyTheme()
        NotificationCenter.default.addObserver(self, selector: #selector(applyTheme), name: ThemeManager.didChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    @objc private func applyTheme() {
        if InterfaceStyle.isGlass {
            hint.textColor = .secondaryLabel
            liveLabel.textColor = .label
        } else {
            let p = Theme.palette
            [hint, liveLabel].forEach {
                $0.textColor = p.surfaceText
                $0.shadowColor = p.surfaceTextShadow
                $0.shadowOffset = p.surfaceTextShadowOffset
            }
        }
    }

    private var liveOn: Bool {
        (liveToggle as? UISwitch)?.isOn ?? (liveToggle as? ClassicSwitch)?.isOn ?? false
    }

    private func syncLive() {
        let on = Preferences.shared.liveTyping
        (liveToggle as? UISwitch)?.setOn(on, animated: false)
        (liveToggle as? ClassicSwitch)?.setOn(on, animated: false)
        send.isHidden = on
        updateHint()
        setNeedsLayout()
    }

    @objc private func liveChanged() {
        Preferences.shared.liveTyping = liveOn
        send.isHidden = liveOn
        updateHint()
        setNeedsLayout()
    }

    func updateHint() {
        let supported = ConnectionManager.shared.controller?.supportsText ?? false
        if DeviceStore.shared.selected == nil {
            hint.text = "Scegli una TV per digitare."
        } else if !supported {
            hint.text = "Questa TV non accetta testo dalla rete. Usa le frecce del telecomando."
        } else if liveOn {
            hint.text = "Ogni lettera viene scritta subito nel campo attivo della TV (ricerca, login…)."
        } else {
            hint.text = "Scrivi il testo e premi «Invia» per inserirlo nel campo attivo della TV."
        }
    }

    private func sendField() {
        guard let text = field.text, !text.isEmpty else { return }
        ConnectionManager.shared.controller?.sendText(text)
        field.text = ""
    }

    func sendDictation(_ text: String) {
        ConnectionManager.shared.controller?.sendText(text)
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        guard liveOn, let controller = ConnectionManager.shared.controller else { return true }
        if string.isEmpty {
            for _ in 0..<max(1, range.length) { controller.send(.backspace) }
        } else {
            controller.sendText(string)
        }
        return true
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if liveOn {
            ConnectionManager.shared.press(.enter)
            field.text = ""
        } else {
            sendField()
        }
        return false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = min(bounds.width - 32, 440)
        let x0 = (bounds.width - width) / 2
        var y: CGFloat = 10
        fieldBackground.frame = CGRect(x: x0, y: y, width: width, height: 50)
        field.frame = fieldBackground.frame.insetBy(dx: 16, dy: 4)
        y += 50 + 14
        let toggleSize = liveToggle.sizeThatFits(.zero)
        liveToggle.frame = CGRect(x: x0 + width - toggleSize.width, y: y, width: toggleSize.width, height: toggleSize.height)
        liveLabel.frame = CGRect(x: x0, y: y, width: width - toggleSize.width - 10, height: max(31, toggleSize.height))
        y += max(31, toggleSize.height) + 14
        let keys: [UIView] = send.isHidden ? [clear, backspace, enter, voice] : [clear, backspace, enter, voice, send]
        let itemWidth = (width - CGFloat(keys.count - 1) * 10) / CGFloat(keys.count)
        layoutRow(keys, x0: x0, width: width, y: y, itemWidth: itemWidth, height: 48)
        y += 48 + 14
        hint.frame = CGRect(x: x0, y: y, width: width, height: 54)
    }
}
