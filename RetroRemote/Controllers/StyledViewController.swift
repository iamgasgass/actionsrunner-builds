import UIKit

/// Navigation controller iOS 6: la barra di sistema è nascosta, ogni schermata disegna la propria.
final class ClassicNavigationController: UINavigationController, UIGestureRecognizerDelegate {
    override func viewDidLoad() {
        super.viewDidLoad()
        setNavigationBarHidden(true, animated: false)
        interactivePopGestureRecognizer?.delegate = self
        view.backgroundColor = .black
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }

    override var childForStatusBarStyle: UIViewController? { topViewController }
    override var childForStatusBarHidden: UIViewController? { topViewController }
}

/// Navigation controller Liquid Glass: barra di sistema (in vetro su iOS 26).
final class GlassNavigationController: UINavigationController {
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationBar.prefersLargeTitles = false
    }

    override var childForStatusBarStyle: UIViewController? { topViewController }
    override var childForStatusBarHidden: UIViewController? { topViewController }
}

/// Base delle schermate. Nello stile iOS 6 disegna la navigation bar classica,
/// in Liquid Glass usa la barra di sistema.
class StyledViewController: UIViewController {
    enum Side { case left, right }

    let isGlass = InterfaceStyle.isGlass
    let navBar = ClassicNavBar()
    let contentView = UIView()
    private var glassItems: [Side: UIBarButtonItem] = [:]

    /// La schermata principale nasconde la barra di sistema e disegna la propria testata.
    var hidesSystemNavigationBar: Bool { false }

    override func viewDidLoad() {
        super.viewDidLoad()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentView)
        if isGlass {
            view.backgroundColor = .systemGroupedBackground
            navigationItem.title = title
            navigationItem.leftItemsSupplementBackButton = true
            NSLayoutConstraint.activate([
                contentView.topAnchor.constraint(equalTo: view.topAnchor),
                contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                contentView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
        } else {
            view.backgroundColor = .black
            navBar.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(navBar)
            NSLayoutConstraint.activate([
                navBar.topAnchor.constraint(equalTo: view.topAnchor),
                navBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                navBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                navBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: ClassicNavBar.barHeight),
                contentView.topAnchor.constraint(equalTo: navBar.bottomAnchor),
                contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                contentView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
            navBar.title = title
            if let nav = navigationController, nav.viewControllers.count > 1, nav.viewControllers.last === self {
                let previous = nav.viewControllers[nav.viewControllers.count - 2]
                let back = ClassicBarButton(title: previous.title ?? "Indietro", style: .back)
                back.addTarget(self, action: #selector(goBack), for: .touchUpInside)
                navBar.leftView = back
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(themeNotification),
                                               name: ThemeManager.didChange, object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if isGlass {
            navigationController?.setNavigationBarHidden(hidesSystemNavigationBar, animated: animated)
        }
    }

    @objc private func themeNotification() { applyTheme() }

    /// Da sovrascrivere per aggiornare ciò che non si ridisegna da solo.
    func applyTheme() {}

    @objc func goBack() {
        navigationController?.popViewController(animated: true)
    }

    func setTitleText(_ text: String?) {
        title = text
        if isGlass { navigationItem.title = text } else { navBar.title = text }
    }

    /// Pulsante della barra: testo, simbolo o menu, nello stile corrente.
    func setBarButton(_ side: Side, title: String? = nil, symbol: String? = nil, done: Bool = false,
                      menu: UIMenu? = nil, action: Selector? = nil) {
        if isGlass {
            let item: UIBarButtonItem
            let image = symbol.flatMap { systemSymbol($0, size: 17, weight: .semibold) }
            if let menu = menu {
                item = UIBarButtonItem(title: title, image: image, primaryAction: nil, menu: menu)
            } else if let image = image {
                item = UIBarButtonItem(image: image, style: .plain, target: self, action: action)
            } else {
                item = UIBarButtonItem(title: title, style: done ? .done : .plain, target: self, action: action)
            }
            glassItems[side] = item
            if side == .left { navigationItem.leftBarButtonItem = item } else { navigationItem.rightBarButtonItem = item }
        } else {
            let control: UIView
            if let menu = menu {
                let button = ClassicMenuButton(title: title, symbol: symbol)
                button.menu = menu
                button.showsMenuAsPrimaryAction = true
                control = button
            } else {
                let button = ClassicBarButton(title: title, symbol: symbol, style: done ? .done : .plain)
                if let action = action { button.addTarget(self, action: action, for: .touchUpInside) }
                control = button
            }
            if side == .left { navBar.leftView = control } else { navBar.rightView = control }
        }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { isGlass ? .default : .lightContent }
    override var prefersStatusBarHidden: Bool { Preferences.shared.hideStatusBar }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }
}

/// Cella di sistema usata in Liquid Glass.
final class ModernCell: UITableViewCell {
    private let toggle = UISwitch()
    private var onToggle: ((Bool) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .value1, reuseIdentifier: reuseIdentifier)
        toggle.addTarget(self, action: #selector(toggled), for: .valueChanged)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    @objc private func toggled() {
        Feedback.selection()
        onToggle?(toggle.isOn)
    }

    func configure(_ row: TableRow) {
        var content = UIListContentConfiguration.valueCell()
        content.text = row.title
        content.secondaryText = row.value
        content.image = row.icon
        content.textProperties.numberOfLines = 0
        switch row.style {
        case .normal:
            content.textProperties.color = .label
        case .button:
            content.textProperties.color = .tintColor
            content.textProperties.alignment = .center
        case .destructive:
            content.textProperties.color = .systemRed
            content.textProperties.alignment = .center
        case .placeholder:
            content.textProperties.color = .secondaryLabel
            content.textProperties.alignment = .center
            content.textProperties.font = .preferredFont(forTextStyle: .subheadline)
        }
        contentConfiguration = content
        onToggle = row.onToggle
        accessoryView = nil
        accessoryType = .none
        if let isOn = row.toggle {
            toggle.isOn = isOn
            accessoryView = toggle
        } else {
            switch row.accessory {
            case .none: accessoryType = .none
            case .chevron: accessoryType = .disclosureIndicator
            case .checkmark: accessoryType = .checkmark
            case .detail: accessoryType = .detailButton
            }
        }
        selectionStyle = row.onSelect == nil ? .none : .default
    }
}

/// Tabella raggruppata nei due stili: celle iOS 6 disegnate a mano o celle di sistema.
class StyledTableViewController: StyledViewController, UITableViewDataSource, UITableViewDelegate {
    private(set) lazy var tableView = UITableView(frame: .zero, style: isGlass ? .insetGrouped : .grouped)
    private let background = TexturedView(kind: .pinstripe)

    var sections: [TableSection] = [] {
        didSet { if isViewLoaded { tableView.reloadData() } }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: contentView.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        tableView.dataSource = self
        tableView.delegate = self
        tableView.cellLayoutMarginsFollowReadableWidth = false
        if isGlass {
            tableView.register(ModernCell.self, forCellReuseIdentifier: "modern")
            tableView.backgroundColor = .systemGroupedBackground
        } else {
            tableView.register(ClassicCell.self, forCellReuseIdentifier: "cell")
            tableView.backgroundView = background
            tableView.backgroundColor = .clear
            tableView.separatorStyle = .none
            tableView.sectionHeaderTopPadding = 0
            tableView.estimatedRowHeight = 0
            tableView.estimatedSectionHeaderHeight = 0
            tableView.estimatedSectionFooterHeight = 0
        }
        applyTheme()
    }

    override func applyTheme() {
        super.applyTheme()
        if !isGlass { tableView.indicatorStyle = Theme.palette.isDark ? .white : .black }
        tableView.reloadData()
    }

    func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = sections[indexPath.section].rows[indexPath.row]
        if isGlass {
            let cell = tableView.dequeueReusableCell(withIdentifier: "modern", for: indexPath) as! ModernCell
            cell.configure(row)
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath) as! ClassicCell
        let count = sections[indexPath.section].rows.count
        cell.position = count == 1 ? .single : indexPath.row == 0 ? .top : indexPath.row == count - 1 ? .bottom : .middle
        cell.configure(row)
        return cell
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if isGlass { return UITableView.automaticDimension }
        return indexPath.row == sections[indexPath.section].rows.count - 1 ? 45 : 44
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        isGlass ? sections[section].header : nil
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        isGlass ? sections[section].footer : nil
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard !isGlass else { return nil }
        let s = sections[section]
        guard s.header != nil else { return UIView() }
        return ClassicSectionHeaderView(text: s.header, spinning: s.headerSpinner)
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        if isGlass { return UITableView.automaticDimension }
        if sections[section].header != nil { return section == 0 ? 46 : 40 }
        return section == 0 ? 20 : 10
    }

    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        guard !isGlass else { return nil }
        guard let text = sections[section].footer else { return UIView() }
        return ClassicSectionHeaderView(text: text, footer: true)
    }

    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        if isGlass { return UITableView.automaticDimension }
        guard let text = sections[section].footer else { return 10 }
        return ClassicSectionHeaderView.footerHeight(text, width: tableView.bounds.width)
    }

    func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        sections[indexPath.section].rows[indexPath.row].onSelect != nil
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let action = sections[indexPath.section].rows[indexPath.row].onSelect
        if isGlass {
            tableView.deselectRow(at: indexPath, animated: true)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                tableView.deselectRow(at: indexPath, animated: true)
                tableView.cellForRow(at: indexPath)?.setHighlighted(false, animated: true)
            }
        }
        action?()
    }

    func tableView(_ tableView: UITableView, accessoryButtonTappedForRowWith indexPath: IndexPath) {
        sections[indexPath.section].rows[indexPath.row].onDetail?()
    }
}
