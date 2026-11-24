import UIKit

extension UIColor {
    /// Colore da componenti 0–255 (come nei vecchi file di design di iOS 6).
    convenience init(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) {
        self.init(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }

    func scaled(_ factor: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return UIColor(red: min(1, max(0, r * factor)),
                       green: min(1, max(0, g * factor)),
                       blue: min(1, max(0, b * factor)),
                       alpha: a)
    }
}

enum Fonts {
    static func regular(_ size: CGFloat) -> UIFont { UIFont(name: "Helvetica", size: size) ?? .systemFont(ofSize: size) }
    static func bold(_ size: CGFloat) -> UIFont { UIFont(name: "Helvetica-Bold", size: size) ?? .boldSystemFont(ofSize: size) }
}

enum AppearanceMode: Int, CaseIterable {
    case automatic, light, dark

    var title: String {
        switch self {
        case .automatic: return "Automatico"
        case .light: return "Chiaro"
        case .dark: return "Scuro"
        }
    }
}

/// Tutti i colori dell'interfaccia. I valori di default sono il tema chiaro iOS 6.
struct Palette {
    var isDark = false

    // Barra di stato (zona superiore, tinta come in iOS 6 sopra la navigation bar)
    var statusTop = UIColor(118, 136, 162)
    var statusBottom = UIColor(150, 166, 188)

    // Navigation bar
    var navTop = UIColor(176, 188, 205)
    var navBottom = UIColor(109, 132, 162)
    var navHighlight = UIColor(255, 255, 255, 0.42)
    var navBorder = UIColor(45, 53, 63)
    var navTitle = UIColor.white
    var navTitleShadow = UIColor(0, 0, 0, 0.5)
    var navSubtitle = UIColor(240, 244, 250)

    // Pulsanti della barra
    var barButtonTop = UIColor(130, 151, 179)
    var barButtonBottom = UIColor(80, 104, 138)
    var barButtonBorder = UIColor(52, 66, 87)
    var barButtonGlow = UIColor(255, 255, 255, 0.28)
    var doneTop = UIColor(108, 155, 236)
    var doneBottom = UIColor(32, 87, 200)
    var doneBorder = UIColor(25, 52, 118)

    // Sfondo "pinstripe" delle tabelle raggruppate
    var stripeBase = UIColor(197, 204, 212)
    var stripeLine = UIColor(203, 210, 216)

    // Celle raggruppate
    var cellBackground = UIColor.white
    var cellBorder = UIColor(171, 171, 171)
    var cellSeparator = UIColor(224, 224, 224)
    var cellShadow = UIColor(255, 255, 255, 0.9)
    var cellText = UIColor.black
    var cellDetail = UIColor(56, 84, 135)
    var cellSubtle = UIColor(128, 128, 128)
    var selectTop = UIColor(5, 140, 245)
    var selectBottom = UIColor(1, 93, 230)
    var headerText = UIColor(76, 86, 108)
    var headerShadow = UIColor.white
    var headerShadowOffset = CGSize(width: 0, height: 1)
    var chevron = UIColor(128, 128, 128)
    var checkmark = UIColor(50, 79, 133)

    // Switch
    var switchOffTop = UIColor(222, 222, 222)
    var switchOffBottom = UIColor(253, 253, 253)
    var switchOffText = UIColor(128, 128, 128)
    var switchOffTextShadow = UIColor.white
    var switchBorder = UIColor(140, 140, 140)
    var knobTop = UIColor(206, 206, 206)
    var knobBottom = UIColor(252, 252, 252)
    var knobBorder = UIColor(150, 150, 150)

    // Superficie del telecomando
    var surfaceIsLinen = false
    var surfaceBase = UIColor(198, 201, 207)
    var surfaceText = UIColor(58, 62, 70)
    var surfaceTextShadow = UIColor(255, 255, 255, 0.8)
    var surfaceTextShadowOffset = CGSize(width: 0, height: 1)

    // Tasti del telecomando
    var keyTop = UIColor(252, 252, 253)
    var keyBottom = UIColor(206, 209, 215)
    var keyPressedTop = UIColor(184, 188, 195)
    var keyPressedBottom = UIColor(222, 224, 228)
    var keyBorder = UIColor(118, 122, 131)
    var keyGloss: CGFloat = 0.55
    var keyDropShadow = UIColor(0, 0, 0, 0.38)
    var keyText = UIColor(68, 72, 80)
    var keyTextShadow = UIColor(255, 255, 255, 0.9)
    var keyTextShadowOffset = CGSize(width: 0, height: 1)
    var keyGroove = UIColor(150, 154, 162)

    // Alert
    var alertFill = UIColor(4, 24, 74, 0.84)
    var alertBorder = UIColor(255, 255, 255, 0.82)

    // Page control
    var pageDot = UIColor(0, 0, 0, 0.25)
    var pageDotCurrent = UIColor(60, 64, 72)

    static let light = Palette()

    static let dark: Palette = {
        var p = Palette()
        p.isDark = true
        p.statusTop = UIColor(10, 10, 11)
        p.statusBottom = UIColor(24, 24, 26)
        p.navTop = UIColor(76, 76, 79)
        p.navBottom = UIColor(20, 20, 22)
        p.navHighlight = UIColor(255, 255, 255, 0.2)
        p.navBorder = UIColor(0, 0, 0)
        p.navSubtitle = UIColor(200, 200, 205)
        p.barButtonTop = UIColor(74, 74, 78)
        p.barButtonBottom = UIColor(26, 26, 28)
        p.barButtonBorder = UIColor(0, 0, 0)
        p.barButtonGlow = UIColor(255, 255, 255, 0.12)
        p.stripeBase = UIColor(30, 32, 36)
        p.stripeLine = UIColor(36, 38, 43)
        p.cellBackground = UIColor(42, 43, 46)
        p.cellBorder = UIColor(10, 10, 12)
        p.cellSeparator = UIColor(58, 59, 63)
        p.cellShadow = UIColor(255, 255, 255, 0.06)
        p.cellText = UIColor(236, 236, 238)
        p.cellDetail = UIColor(122, 162, 226)
        p.cellSubtle = UIColor(140, 140, 146)
        p.headerText = UIColor(168, 174, 186)
        p.headerShadow = UIColor(0, 0, 0, 0.9)
        p.headerShadowOffset = CGSize(width: 0, height: -1)
        p.chevron = UIColor(150, 150, 156)
        p.checkmark = UIColor(112, 162, 236)
        p.switchOffTop = UIColor(48, 48, 51)
        p.switchOffBottom = UIColor(74, 74, 78)
        p.switchOffText = UIColor(170, 170, 175)
        p.switchOffTextShadow = UIColor(0, 0, 0, 0.8)
        p.switchBorder = UIColor(8, 8, 9)
        p.knobTop = UIColor(96, 96, 100)
        p.knobBottom = UIColor(160, 160, 166)
        p.knobBorder = UIColor(10, 10, 12)
        p.surfaceIsLinen = true
        p.surfaceBase = UIColor(37, 38, 42)
        p.surfaceText = UIColor(200, 202, 208)
        p.surfaceTextShadow = UIColor(0, 0, 0, 0.9)
        p.surfaceTextShadowOffset = CGSize(width: 0, height: -1)
        p.keyTop = UIColor(80, 81, 86)
        p.keyBottom = UIColor(28, 29, 32)
        p.keyPressedTop = UIColor(20, 20, 22)
        p.keyPressedBottom = UIColor(50, 51, 55)
        p.keyBorder = UIColor(0, 0, 0)
        p.keyGloss = 0.17
        p.keyDropShadow = UIColor(0, 0, 0, 0.7)
        p.keyText = UIColor(226, 226, 230)
        p.keyTextShadow = UIColor(0, 0, 0, 0.9)
        p.keyTextShadowOffset = CGSize(width: 0, height: -1)
        p.keyGroove = UIColor(8, 8, 9)
        p.alertFill = UIColor(22, 22, 26, 0.9)
        p.alertBorder = UIColor(255, 255, 255, 0.55)
        p.pageDot = UIColor(255, 255, 255, 0.25)
        p.pageDotCurrent = UIColor(230, 230, 235)
        return p
    }()
}

enum Theme {
    static var palette: Palette { ThemeManager.shared.palette }
}

final class ThemeManager {
    static let shared = ThemeManager()
    static let didChange = Notification.Name("RetroRemote.ThemeDidChange")

    weak var window: UIWindow?
    private(set) var palette: Palette = .light
    private let key = "appearance.mode"

    var mode: AppearanceMode {
        get { AppearanceMode(rawValue: UserDefaults.standard.integer(forKey: key)) ?? .automatic }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key); apply() }
    }

    /// Imposta lo stile del sistema e aggiorna la palette (come OldSafari: chiaro / scuro / automatico).
    func apply() {
        switch mode {
        case .automatic: window?.overrideUserInterfaceStyle = .unspecified
        case .light: window?.overrideUserInterfaceStyle = .light
        case .dark: window?.overrideUserInterfaceStyle = .dark
        }
        refresh(force: true)
    }

    func refresh(force: Bool = false) {
        let dark: Bool
        switch mode {
        case .light: dark = false
        case .dark: dark = true
        case .automatic:
            let style = window?.windowScene?.traitCollection.userInterfaceStyle ?? UITraitCollection.current.userInterfaceStyle
            dark = style == .dark
        }
        guard force || dark != palette.isDark else { return }
        palette = dark ? .dark : .light
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
