import UIKit

private final class AppIconCell: UICollectionViewCell {
    let icon = AppIconView()
    let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = Fonts.bold(11)
        label.textAlignment = .center
        label.lineBreakMode = .byTruncatingTail
        contentView.addSubview(icon)
        contentView.addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = min(bounds.width, 66)
        icon.frame = CGRect(x: (bounds.width - side) / 2, y: 0, width: side, height: side)
        label.frame = CGRect(x: 0, y: side + 2, width: bounds.width, height: 15)
    }

    override var isHighlighted: Bool { didSet { icon.pressed = isHighlighted } }

    func applyTheme() {
        let p = Theme.palette
        label.textColor = p.isDark ? .white : p.surfaceText
        label.shadowColor = p.surfaceTextShadow
        label.shadowOffset = p.surfaceTextShadowOffset
    }
}

final class AppsViewController: ClassicViewController, UICollectionViewDataSource, UICollectionViewDelegate {
    private let surface = TexturedView(kind: .surface)
    private let layout = UICollectionViewFlowLayout()
    private lazy var collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
    private let emptyLabel = UILabel()
    private let refreshButton = ClassicBarButton(symbol: "arrow.clockwise")
    private var apps: [TVApp] = []
    private var loadedForDevice: UUID?

    init() {
        super.init(nibName: nil, bundle: nil)
        title = "App"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    override func viewDidLoad() {
        super.viewDidLoad()
        surface.translatesAutoresizingMaskIntoConstraints = false
        collection.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(surface)
        contentView.addSubview(collection)
        contentView.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: contentView.topAnchor),
            surface.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            surface.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            collection.topAnchor.constraint(equalTo: contentView.topAnchor),
            collection.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            collection.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            collection.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 30),
            emptyLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -30)
        ])
        collection.backgroundColor = .clear
        collection.dataSource = self
        collection.delegate = self
        collection.alwaysBounceVertical = true
        collection.register(AppIconCell.self, forCellWithReuseIdentifier: "app")
        layout.minimumLineSpacing = 18
        layout.minimumInteritemSpacing = 4
        layout.sectionInset = UIEdgeInsets(top: 20, left: 12, bottom: 20, right: 12)

        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyLabel.font = Fonts.bold(17)

        refreshButton.addTarget(self, action: #selector(reload), for: .touchUpInside)
        navBar.rightView = refreshButton

        NotificationCenter.default.addObserver(self, selector: #selector(stateChanged),
                                               name: ConnectionManager.stateDidChange, object: nil)
        applyTheme()
        updateEmpty()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if apps.isEmpty || loadedForDevice != DeviceStore.shared.selectedID { reload() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = collection.bounds.width - layout.sectionInset.left - layout.sectionInset.right
        guard width > 0 else { return }
        let columns = max(4, Int(width / 92))
        let itemWidth = floor((width - CGFloat(columns - 1) * layout.minimumInteritemSpacing) / CGFloat(columns))
        let size = CGSize(width: itemWidth, height: min(itemWidth, 66) + 20)
        if layout.itemSize != size { layout.itemSize = size }
    }

    override func applyTheme() {
        let p = Theme.palette
        emptyLabel.textColor = p.surfaceText
        emptyLabel.shadowColor = p.surfaceTextShadow
        emptyLabel.shadowOffset = p.surfaceTextShadowOffset
        collection.indicatorStyle = p.isDark ? .white : .black
        collection.reloadData()
    }

    @objc private func stateChanged() {
        if ConnectionManager.shared.state == .connected, loadedForDevice != DeviceStore.shared.selectedID || apps.isEmpty {
            reload()
        } else {
            updateEmpty()
        }
    }

    @objc private func reload() {
        guard let controller = ConnectionManager.shared.controller, controller.state == .connected else {
            apps = []
            collection.reloadData()
            updateEmpty()
            return
        }
        refreshButton.isSpinning = true
        let deviceID = DeviceStore.shared.selectedID
        controller.fetchApps { [weak self] apps in
            guard let self = self else { return }
            self.refreshButton.isSpinning = false
            self.apps = apps
            self.loadedForDevice = deviceID
            self.collection.reloadData()
            self.updateEmpty()
        }
    }

    private func updateEmpty() {
        if DeviceStore.shared.selected == nil {
            emptyLabel.text = "Nessuna TV selezionata.\nAggiungine una in Dispositivi."
        } else if ConnectionManager.shared.state != .connected {
            emptyLabel.text = "TV non connessa."
        } else {
            emptyLabel.text = apps.isEmpty ? "Nessuna app trovata." : nil
        }
        emptyLabel.isHidden = !apps.isEmpty
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { apps.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "app", for: indexPath) as! AppIconCell
        let app = apps[indexPath.item]
        cell.label.text = app.name
        cell.icon.placeholderName = app.name
        cell.icon.image = nil
        cell.applyTheme()
        if let url = app.iconURL {
            ImageLoader.shared.load(url) { [weak collectionView] image in
                guard let image = image,
                      let visible = collectionView?.cellForItem(at: indexPath) as? AppIconCell,
                      visible.label.text == app.name else { return }
                visible.icon.image = image
            }
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        Feedback.tap()
        ConnectionManager.shared.controller?.launch(apps[indexPath.item])
        collectionView.deselectItem(at: indexPath, animated: true)
    }
}
