import UIKit

/// Base delle schermate: navigation bar iOS 6 a tutta larghezza + area contenuto sotto.
class ClassicViewController: UIViewController {
    let navBar = ClassicNavBar()
    let contentView = UIView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        contentView.translatesAutoresizingMaskIntoConstraints = false
        navBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentView)
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
        NotificationCenter.default.addObserver(self, selector: #selector(themeNotification),
                                               name: ThemeManager.didChange, object: nil)
    }

    @objc private func themeNotification() { applyTheme() }

    /// Da sovrascrivere per aggiornare ciò che non si ridisegna da solo.
    func applyTheme() {}

    @objc func goBack() {
        navigationController?.popViewController(animated: true)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var prefersStatusBarHidden: Bool { Preferences.shared.hideStatusBar }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }

    var rootController: RootViewController? {
        var vc: UIViewController? = self
        while let current = vc {
            if let root = current as? RootViewController { return root }
            vc = current.parent
        }
        return view.window?.rootViewController as? RootViewController
    }
}

class ClassicTableViewController: ClassicViewController, UITableViewDataSource, UITableViewDelegate {
    let tableView = UITableView(frame: .zero, style: .grouped)
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
        tableView.backgroundView = background
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(ClassicCell.self, forCellReuseIdentifier: "cell")
        tableView.sectionHeaderTopPadding = 0
        tableView.estimatedRowHeight = 0
        tableView.estimatedSectionHeaderHeight = 0
        tableView.estimatedSectionFooterHeight = 0
        tableView.cellLayoutMarginsFollowReadableWidth = false
        applyTheme()
    }

    override func applyTheme() {
        super.applyTheme()
        tableView.indicatorStyle = Theme.palette.isDark ? .white : .black
        tableView.reloadData()
    }

    func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath) as! ClassicCell
        let rows = sections[indexPath.section].rows
        let count = rows.count
        cell.position = count == 1 ? .single : indexPath.row == 0 ? .top : indexPath.row == count - 1 ? .bottom : .middle
        cell.configure(rows[indexPath.row])
        return cell
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        indexPath.row == sections[indexPath.section].rows.count - 1 ? 45 : 44
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let s = sections[section]
        guard s.header != nil else { return UIView() }
        return ClassicSectionHeaderView(text: s.header, spinning: s.headerSpinner)
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        if sections[section].header != nil { return section == 0 ? 46 : 40 }
        return section == 0 ? 20 : 10
    }

    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        guard let text = sections[section].footer else { return UIView() }
        return ClassicSectionHeaderView(text: text, footer: true)
    }

    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        guard let text = sections[section].footer else { return 10 }
        return ClassicSectionHeaderView.footerHeight(text, width: tableView.bounds.width)
    }

    func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        sections[indexPath.section].rows[indexPath.row].onSelect != nil
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let action = sections[indexPath.section].rows[indexPath.row].onSelect
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            tableView.deselectRow(at: indexPath, animated: true)
            if let cell = tableView.cellForRow(at: indexPath) { cell.setHighlighted(false, animated: true) }
        }
        action?()
    }
}
