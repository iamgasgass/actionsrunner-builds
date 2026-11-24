import UIKit

/// Vista che si ridisegna automaticamente quando cambia il tema.
class ThemedView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        registerTheme()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerTheme()
    }

    private func registerTheme() {
        contentMode = .redraw
        NotificationCenter.default.addObserver(self, selector: #selector(themeNotification),
                                               name: ThemeManager.didChange, object: nil)
    }

    @objc private func themeNotification() { applyTheme() }

    func applyTheme() { setNeedsDisplay() }
}

/// Controllo che si ridisegna automaticamente quando cambia il tema.
class ThemedControl: UIControl {
    override init(frame: CGRect) {
        super.init(frame: frame)
        registerTheme()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerTheme()
    }

    private func registerTheme() {
        contentMode = .redraw
        NotificationCenter.default.addObserver(self, selector: #selector(themeNotification),
                                               name: ThemeManager.didChange, object: nil)
    }

    @objc private func themeNotification() { applyTheme() }

    func applyTheme() { setNeedsDisplay() }
}

/// Sfondo a texture (pinstripe delle tabelle o superficie del telecomando).
final class TexturedView: ThemedView {
    enum Kind { case pinstripe, surface }
    let kind: Kind

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    override func applyTheme() {
        let p = Theme.palette
        backgroundColor = UIColor(patternImage: kind == .pinstripe ? Textures.pinstripe(p) : Textures.surface(p))
    }
}
