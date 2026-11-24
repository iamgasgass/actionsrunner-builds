import UIKit

enum CellPosition {
    case top, middle, bottom, single
    var isFirst: Bool { self == .top || self == .single }
    var isLast: Bool { self == .bottom || self == .single }
}

/// Sfondo della cella raggruppata iOS 6: bordo grigio, angoli arrotondati e ombra bianca sotto il gruppo.
final class GroupedCellBackgroundView: ThemedView {
    var position: CellPosition = .single { didSet { setNeedsDisplay() } }
    var highlighted = false { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let p = Theme.palette
        let inset = ClassicCell.sideInset(for: bounds.width)
        var r = CGRect(x: inset, y: 0, width: bounds.width - inset * 2, height: bounds.height)
        if position.isLast { r.size.height -= 1 }
        var corners: UIRectCorner = []
        if position.isFirst { corners.formUnion([.topLeft, .topRight]) }
        if position.isLast { corners.formUnion([.bottomLeft, .bottomRight]) }
        let radius: CGFloat = 8
        let outer = UIBezierPath(roundedRect: r, byRoundingCorners: corners, cornerRadii: CGSize(width: radius, height: radius))

        if position.isLast {
            let shadow = UIBezierPath(cgPath: outer.cgPath)
            shadow.apply(CGAffineTransform(translationX: 0, y: 1))
            p.cellShadow.setFill()
            shadow.fill()
        }
        p.cellBorder.setFill()
        outer.fill()

        var ir = r.insetBy(dx: 1, dy: 0)
        if position.isFirst { ir.origin.y += 1; ir.size.height -= 1 }
        ir.size.height -= 1
        let inner = UIBezierPath(roundedRect: ir, byRoundingCorners: corners,
                                 cornerRadii: CGSize(width: radius - 1, height: radius - 1))
        if highlighted {
            Draw.fillVertical(inner, ir, [p.selectTop, p.selectBottom])
        } else {
            p.cellBackground.setFill()
            inner.fill()
            if p.isDark {
                ctx.saveGState()
                inner.addClip()
                ctx.setFillColor(UIColor(255, 255, 255, 0.05).cgColor)
                ctx.fill(CGRect(x: ir.minX, y: ir.minY, width: ir.width, height: 1))
                ctx.restoreGState()
            }
        }
        if !position.isLast {
            ctx.setFillColor((highlighted ? p.selectBottom : p.cellSeparator).cgColor)
            ctx.fill(CGRect(x: r.minX + 1, y: r.maxY - 1, width: r.width - 2, height: 1))
        }
    }
}

final class ChevronView: ThemedView {
    var highlighted = false { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    override func draw(_ rect: CGRect) {
        let path = UIBezierPath()
        let r = bounds
        path.move(to: CGPoint(x: r.midX - 3, y: r.midY - 6))
        path.addLine(to: CGPoint(x: r.midX + 3, y: r.midY))
        path.addLine(to: CGPoint(x: r.midX - 3, y: r.midY + 6))
        path.lineWidth = 3
        path.lineJoin = .miter
        path.lineCapStyle = .square
        (highlighted ? UIColor.white : Theme.palette.chevron).setStroke()
        path.stroke()
    }
}

final class CheckmarkView: ThemedView {
    var highlighted = false { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let p = Theme.palette
        let r = bounds
        let path = UIBezierPath()
        path.move(to: CGPoint(x: r.midX - 6, y: r.midY))
        path.addLine(to: CGPoint(x: r.midX - 2, y: r.midY + 5))
        path.addLine(to: CGPoint(x: r.midX + 6, y: r.midY - 6))
        path.lineWidth = 3
        path.lineJoin = .miter
        if !highlighted {
            ctx.setShadow(offset: p.headerShadowOffset, blur: 0, color: p.headerShadow.cgColor)
        }
        (highlighted ? UIColor.white : p.checkmark).setStroke()
        path.stroke()
    }
}

/// Il celebre pulsante blu rotondo con la freccia bianca.
final class DetailDisclosureButton: UIControl {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    override var isHighlighted: Bool { didSet { setNeedsDisplay() } }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let d: CGFloat = 27
        let c = CGPoint(x: bounds.midX, y: bounds.midY - 0.5)
        let outer = CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 1.5, color: UIColor(0, 0, 0, 0.45).cgColor)
        UIColor.white.setFill()
        UIBezierPath(ovalIn: outer).fill()
        ctx.restoreGState()
        let inner = outer.insetBy(dx: 2.5, dy: 2.5)
        let innerPath = UIBezierPath(ovalIn: inner)
        var colors = [UIColor(110, 172, 250), UIColor(36, 104, 226), UIColor(20, 80, 210)]
        if isHighlighted { colors = colors.map { $0.scaled(0.75) } }
        Draw.fillVertical(innerPath, inner, colors, [0, 0.5, 1])
        ctx.saveGState()
        innerPath.addClip()
        Draw.glossEllipse(in: inner, top: 0.5, bottom: 0.12, heightFactor: 0.5)
        ctx.restoreGState()
        let chevron = UIBezierPath()
        chevron.move(to: CGPoint(x: c.x - 2.5, y: c.y - 5))
        chevron.addLine(to: CGPoint(x: c.x + 2.5, y: c.y))
        chevron.addLine(to: CGPoint(x: c.x - 2.5, y: c.y + 5))
        chevron.lineWidth = 2.6
        chevron.lineJoin = .miter
        UIColor.white.setStroke()
        chevron.stroke()
    }
}

/// Riga del modello dati delle tabelle.
struct TableRow {
    var title: String
    var value: String? = nil
    var icon: UIImage? = nil
    var accessory: ClassicCell.AccessoryKind = .none
    var style: ClassicCell.TitleStyle = .normal
    var toggle: Bool? = nil
    var onToggle: ((Bool) -> Void)? = nil
    var onSelect: (() -> Void)? = nil
    var onDetail: (() -> Void)? = nil
}

struct TableSection {
    var header: String? = nil
    var footer: String? = nil
    var rows: [TableRow]
    var headerSpinner = false
}

final class ClassicCell: UITableViewCell {
    enum AccessoryKind { case none, chevron, checkmark, detail }
    enum TitleStyle { case normal, button, placeholder }

    static func sideInset(for width: CGFloat) -> CGFloat {
        if width > 700 { return 45 }
        if width > 480 { return 30 }
        return 10
    }

    private let bgView = GroupedCellBackgroundView()
    private let titleLabel = UILabel()
    private let valueLabel = UILabel()
    private let iconView = UIImageView()
    private let chevron = ChevronView(frame: CGRect(x: 0, y: 0, width: 12, height: 16))
    private let checkmark = CheckmarkView(frame: CGRect(x: 0, y: 0, width: 16, height: 16))
    private let detailButton = DetailDisclosureButton(frame: CGRect(x: 0, y: 0, width: 36, height: 36))
    private let switchControl = ClassicSwitch(frame: .zero)

    var position: CellPosition = .single {
        didSet { bgView.position = position; setNeedsLayout() }
    }

    private var titleStyle: TitleStyle = .normal
    private var accessoryKind: AccessoryKind = .none
    private var onToggle: ((Bool) -> Void)?
    private var onDetail: (() -> Void)?
    private var isHighlightedState = false

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .default, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        backgroundView = bgView
        selectionStyle = .none
        titleLabel.backgroundColor = .clear
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.6
        valueLabel.backgroundColor = .clear
        valueLabel.textAlignment = .right
        iconView.contentMode = .scaleAspectFit
        iconView.layer.cornerRadius = 6
        iconView.clipsToBounds = true
        [iconView, titleLabel, valueLabel, chevron, checkmark, detailButton, switchControl].forEach {
            contentView.addSubview($0)
        }
        detailButton.addTarget(self, action: #selector(detailTapped), for: .touchUpInside)
        switchControl.addTarget(self, action: #selector(toggled), for: .valueChanged)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    func configure(_ row: TableRow) {
        titleLabel.text = row.title
        valueLabel.text = row.value
        iconView.image = row.icon
        iconView.isHidden = row.icon == nil
        titleStyle = row.style
        accessoryKind = row.accessory
        onToggle = row.onToggle
        onDetail = row.onDetail
        chevron.isHidden = row.accessory != .chevron
        checkmark.isHidden = row.accessory != .checkmark
        detailButton.isHidden = row.accessory != .detail
        switchControl.isHidden = row.toggle == nil
        if let value = row.toggle { switchControl.setOn(value, animated: false) }
        applyColors()
        setNeedsLayout()
    }

    @objc private func detailTapped() { onDetail?() }
    @objc private func toggled() { onToggle?(switchControl.isOn) }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        isHighlightedState = highlighted
        bgView.highlighted = highlighted
        chevron.highlighted = highlighted
        checkmark.highlighted = highlighted
        applyColors()
    }

    func applyColors() {
        let p = Theme.palette
        let hl = isHighlightedState
        switch titleStyle {
        case .normal:
            titleLabel.font = Fonts.bold(17)
            titleLabel.textAlignment = .left
            titleLabel.textColor = hl ? .white : (accessoryKind == .checkmark ? p.cellDetail : p.cellText)
        case .button:
            titleLabel.font = Fonts.bold(17)
            titleLabel.textAlignment = .center
            titleLabel.textColor = hl ? .white : p.cellDetail
        case .placeholder:
            titleLabel.font = Fonts.regular(17)
            titleLabel.textAlignment = .center
            titleLabel.textColor = p.cellSubtle
        }
        valueLabel.font = Fonts.regular(17)
        valueLabel.textColor = hl ? .white : p.cellDetail
        bgView.setNeedsDisplay()
        chevron.setNeedsDisplay()
        checkmark.setNeedsDisplay()
        switchControl.setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        contentView.frame = bounds
        let inset = Self.sideInset(for: bounds.width)
        let h = bounds.height - (position.isLast ? 1 : 0)
        var left = inset + 10
        var right = bounds.width - inset - 10

        if !iconView.isHidden {
            iconView.frame = CGRect(x: left, y: (h - 29) / 2, width: 29, height: 29)
            left += 39
        }
        if !switchControl.isHidden {
            let s = ClassicSwitch.size
            switchControl.frame = CGRect(x: right - s.width + 1, y: (h - s.height) / 2, width: s.width, height: s.height)
            right -= s.width + 10
        }
        switch accessoryKind {
        case .chevron:
            chevron.frame = CGRect(x: right - 10, y: (h - 16) / 2, width: 12, height: 16)
            right -= 22
        case .checkmark:
            checkmark.frame = CGRect(x: right - 14, y: (h - 16) / 2, width: 16, height: 16)
            right -= 26
        case .detail:
            detailButton.frame = CGRect(x: right - 31, y: (h - 36) / 2, width: 36, height: 36)
            right -= 38
        case .none:
            break
        }
        if titleStyle != .normal {
            titleLabel.frame = CGRect(x: left, y: 0, width: max(0, right - left), height: h)
            valueLabel.frame = .zero
            return
        }
        let available = max(0, right - left)
        var valueWidth: CGFloat = 0
        if let v = valueLabel.text, !v.isEmpty {
            valueWidth = min(ceil(valueLabel.sizeThatFits(CGSize(width: available, height: h)).width), available * 0.62)
        }
        valueLabel.frame = CGRect(x: right - valueWidth, y: 0, width: valueWidth, height: h)
        titleLabel.frame = CGRect(x: left, y: 0, width: max(0, available - valueWidth - (valueWidth > 0 ? 8 : 0)), height: h)
    }
}

final class ClassicSectionHeaderView: ThemedView {
    private let label = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let isFooter: Bool

    init(text: String?, spinning: Bool = false, footer: Bool = false) {
        isFooter = footer
        super.init(frame: .zero)
        backgroundColor = .clear
        label.text = text
        label.numberOfLines = footer ? 0 : 1
        label.textAlignment = footer ? .center : .left
        label.font = footer ? Fonts.regular(15) : Fonts.bold(17)
        addSubview(label)
        if spinning {
            spinner.hidesWhenStopped = true
            spinner.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
            addSubview(spinner)
            spinner.startAnimating()
        }
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    override func applyTheme() {
        let p = Theme.palette
        label.textColor = p.headerText
        label.shadowColor = p.headerShadow
        label.shadowOffset = p.headerShadowOffset
        spinner.color = p.headerText
    }

    static func footerHeight(_ text: String, width: CGFloat) -> CGFloat {
        let inset = ClassicCell.sideInset(for: width)
        let w = max(10, width - inset * 2 - 20)
        let h = (text as NSString).boundingRect(with: CGSize(width: w, height: .greatestFiniteMagnitude),
                                                options: .usesLineFragmentOrigin,
                                                attributes: [.font: Fonts.regular(15)], context: nil).height
        return ceil(h) + 22
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = ClassicCell.sideInset(for: bounds.width)
        if isFooter {
            label.frame = CGRect(x: inset + 10, y: 8, width: bounds.width - inset * 2 - 20, height: bounds.height - 14)
        } else {
            let width = bounds.width - inset * 2 - 18
            let textWidth = min(width - 30, ceil(label.sizeThatFits(CGSize(width: width, height: 24)).width))
            label.frame = CGRect(x: inset + 9, y: bounds.height - 30, width: textWidth, height: 24)
            spinner.center = CGPoint(x: label.frame.maxX + 16, y: label.frame.midY)
        }
    }
}

/// Grande pulsante rosso "Elimina" dei vecchi Contatti/Impostazioni.
final class ClassicBigButton: ThemedControl {
    private let title: String

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    override var isHighlighted: Bool { didSet { setNeedsDisplay() } }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let p = Theme.palette
        var r = bounds.insetBy(dx: 0.5, dy: 0.5)
        r.size.height -= 1
        let path = UIBezierPath(roundedRect: r, cornerRadius: 8)
        let shadow = UIBezierPath(roundedRect: r.offsetBy(dx: 0, dy: 1), cornerRadius: 8)
        p.cellShadow.setFill()
        shadow.fill()
        UIColor(112, 14, 14).setFill()
        path.fill()
        let inner = r.insetBy(dx: 1, dy: 1)
        let body = UIBezierPath(roundedRect: inner, cornerRadius: 7)
        var colors = [UIColor(238, 124, 124), UIColor(216, 68, 68), UIColor(198, 32, 32), UIColor(176, 14, 14)]
        if isHighlighted { colors = colors.map { $0.scaled(0.75) } }
        Draw.fillVertical(body, inner, colors, [0, 0.5, 0.5, 1])
        ctx.saveGState()
        body.addClip()
        ctx.setFillColor(UIColor(255, 255, 255, 0.3).cgColor)
        ctx.fill(CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: 1))
        ctx.restoreGState()
        Draw.text(title, font: Fonts.bold(20), color: .white, shadow: UIColor(0, 0, 0, 0.5),
                  offset: CGSize(width: 0, height: -1), in: inner)
    }
}
