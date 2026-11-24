import UIKit

/// Navigation bar iOS 6 disegnata a mano. Si estende sotto la barra di stato / Dynamic Island
/// così l'app occupa tutto lo schermo sugli iPhone moderni.
final class ClassicNavBar: ThemedView {
    static let barHeight: CGFloat = 44

    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()

    var title: String? {
        didSet { titleLabel.text = title; setNeedsLayout() }
    }

    var subtitle: String? {
        didSet {
            subtitleLabel.text = subtitle
            subtitleLabel.isHidden = (subtitle ?? "").isEmpty
            titleLabel.font = subtitleLabel.isHidden ? Fonts.bold(20) : Fonts.bold(17)
            setNeedsLayout()
        }
    }

    var leftView: UIView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let v = leftView { addSubview(v) }
            setNeedsLayout()
        }
    }

    var rightView: UIView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let v = rightView { addSubview(v) }
            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        titleLabel.font = Fonts.bold(20)
        titleLabel.textAlignment = .center
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.7
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = Fonts.bold(12)
        subtitleLabel.textAlignment = .center
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.isHidden = true
        addSubview(titleLabel)
        addSubview(subtitleLabel)
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    override func applyTheme() {
        let p = Theme.palette
        titleLabel.textColor = p.navTitle
        titleLabel.shadowColor = p.navTitleShadow
        titleLabel.shadowOffset = CGSize(width: 0, height: -1)
        subtitleLabel.textColor = p.navSubtitle
        subtitleLabel.shadowColor = p.navTitleShadow
        subtitleLabel.shadowOffset = CGSize(width: 0, height: -1)
        setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let barY = bounds.height - Self.barHeight
        let insetL = safeAreaInsets.left + 5
        let insetR = safeAreaInsets.right + 5
        var leftW: CGFloat = 0
        var rightW: CGFloat = 0
        if let l = leftView {
            let s = l.sizeThatFits(CGSize(width: bounds.width / 3, height: Self.barHeight))
            l.frame = CGRect(x: insetL, y: barY + (Self.barHeight - s.height) / 2, width: s.width, height: s.height)
            leftW = s.width + insetL
        }
        if let r = rightView {
            let s = r.sizeThatFits(CGSize(width: bounds.width / 3, height: Self.barHeight))
            r.frame = CGRect(x: bounds.width - insetR - s.width, y: barY + (Self.barHeight - s.height) / 2,
                             width: s.width, height: s.height)
            rightW = s.width + insetR
        }
        let side = max(leftW, rightW) + 8
        let width = max(0, bounds.width - side * 2)
        if subtitleLabel.isHidden {
            titleLabel.frame = CGRect(x: side, y: barY, width: width, height: Self.barHeight)
        } else {
            titleLabel.frame = CGRect(x: side, y: barY + 4, width: width, height: 22)
            subtitleLabel.frame = CGRect(x: side, y: barY + 25, width: width, height: 15)
        }
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let p = Theme.palette
        let barY = bounds.height - Self.barHeight
        if barY > 0 {
            let status = CGRect(x: 0, y: 0, width: bounds.width, height: barY)
            Draw.fillVertical(UIBezierPath(rect: status), status, [p.statusTop, p.statusBottom])
        }
        let bar = CGRect(x: 0, y: barY, width: bounds.width, height: Self.barHeight)
        Draw.fillVertical(UIBezierPath(rect: bar), bar, [p.navTop, p.navBottom])
        ctx.setFillColor(p.navHighlight.cgColor)
        ctx.fill(CGRect(x: 0, y: barY, width: bounds.width, height: 1))
        ctx.setFillColor(p.navBorder.cgColor)
        ctx.fill(CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1))
    }
}
