import UIKit

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

/// Contenitore con la tab bar iOS 6 disegnata a mano, estesa fino al bordo inferiore dello schermo.
final class RootViewController: UIViewController {
    private let tabBar = ClassicTabBar()
    private var navs: [ClassicNavigationController] = []
    private var selected = -1

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        navs = [
            ClassicNavigationController(rootViewController: RemoteViewController()),
            ClassicNavigationController(rootViewController: AppsViewController()),
            ClassicNavigationController(rootViewController: DevicesViewController()),
            ClassicNavigationController(rootViewController: SettingsViewController())
        ]
        tabBar.items = [
            TabItem(title: "Telecomando", symbol: "tv.fill"),
            TabItem(title: "App", symbol: "square.grid.2x2.fill"),
            TabItem(title: "Dispositivi", symbol: "wifi"),
            TabItem(title: "Impostazioni", symbol: "gearshape.fill")
        ]
        tabBar.onSelect = { [weak self] index in
            Feedback.selection()
            self?.selectTab(index)
        }
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tabBar)
        NSLayoutConstraint.activate([
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tabBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -ClassicTabBar.barHeight)
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(prefsChanged),
                                               name: Preferences.didChange, object: nil)
        selectTab(DeviceStore.shared.devices.isEmpty ? 2 : 0)
    }

    @objc private func prefsChanged() {
        UIView.animate(withDuration: 0.25) { self.setNeedsStatusBarAppearanceUpdate() }
    }

    func selectTab(_ index: Int) {
        guard navs.indices.contains(index) else { return }
        if index == selected {
            navs[index].popToRootViewController(animated: true)
            return
        }
        if navs.indices.contains(selected) {
            let old = navs[selected]
            old.willMove(toParent: nil)
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        selected = index
        tabBar.selectedIndex = index
        let nav = navs[index]
        nav.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 0, bottom: ClassicTabBar.barHeight, right: 0)
        addChild(nav)
        nav.view.frame = view.bounds
        nav.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.insertSubview(nav.view, belowSubview: tabBar)
        nav.didMove(toParent: self)
        setNeedsStatusBarAppearanceUpdate()
    }

    override var childForStatusBarStyle: UIViewController? { navs.indices.contains(selected) ? navs[selected] : nil }
    override var childForStatusBarHidden: UIViewController? { navs.indices.contains(selected) ? navs[selected] : nil }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            ThemeManager.shared.refresh()
        }
    }
}
