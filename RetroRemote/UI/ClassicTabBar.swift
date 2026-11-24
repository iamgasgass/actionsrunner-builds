import UIKit

struct TabItem {
    let title: String
    let symbol: String
}

/// Tab bar nera lucida di iOS 6 con icone a gradiente blu e alone sull'elemento selezionato.
final class ClassicTabBar: ThemedView {
    static let barHeight: CGFloat = 49

    var items: [TabItem] = [] { didSet { setNeedsDisplay() } }
    var selectedIndex = 0 { didSet { setNeedsDisplay() } }
    var onSelect: ((Int) -> Void)?

    private var iconCache: [String: UIImage] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = .black
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    override func applyTheme() {
        iconCache.removeAll()
        setNeedsDisplay()
    }

    private func itemRect(_ index: Int) -> CGRect {
        let count = CGFloat(max(items.count, 1))
        let itemWidth = min(bounds.width / count, 116)
        let x0 = (bounds.width - itemWidth * count) / 2
        return CGRect(x: x0 + itemWidth * CGFloat(index), y: 0, width: itemWidth, height: Self.barHeight)
    }

    private func icon(_ symbol: String, selected: Bool) -> UIImage? {
        let key = "\(symbol)-\(selected)"
        if let cached = iconCache[key] { return cached }
        let colors = selected
            ? [UIColor(170, 225, 255), UIColor(42, 154, 244), UIColor(0, 104, 214)]
            : [UIColor(176, 176, 176), UIColor(112, 112, 112)]
        let image = Draw.gradientSymbol(symbol, pointSize: 21, weight: .semibold, colors: colors)
        iconCache[key] = image
        return image
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let bar = CGRect(x: 0, y: 0, width: bounds.width, height: Self.barHeight)
        Draw.fillVertical(UIBezierPath(rect: bar), bar,
                          [UIColor(66, 66, 66), UIColor(32, 32, 32), UIColor(14, 14, 14), UIColor(0, 0, 0)],
                          [0, 0.5, 0.5, 1])
        ctx.setFillColor(UIColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: Self.barHeight, width: bounds.width, height: max(0, bounds.height - Self.barHeight)))
        ctx.fill(CGRect(x: 0, y: 0, width: bounds.width, height: 1))
        ctx.setFillColor(UIColor(255, 255, 255, 0.13).cgColor)
        ctx.fill(CGRect(x: 0, y: 1, width: bounds.width, height: 1))

        for (index, item) in items.enumerated() {
            let r = itemRect(index)
            let selected = index == selectedIndex
            if selected {
                let hr = CGRect(x: r.minX + 2, y: 3, width: r.width - 4, height: Self.barHeight - 5)
                let path = UIBezierPath(roundedRect: hr, cornerRadius: 3)
                Draw.fillVertical(path, hr, [UIColor(255, 255, 255, 0.16), UIColor(255, 255, 255, 0.08),
                                             UIColor(255, 255, 255, 0.05), UIColor(255, 255, 255, 0.07)],
                                  [0, 0.5, 0.5, 1])
            }
            let iconArea = CGRect(x: r.minX, y: 4, width: r.width, height: 30)
            if let img = icon(item.symbol, selected: selected) {
                if selected {
                    Draw.image(img, centeredIn: iconArea, shadow: UIColor(80, 170, 255, 0.75), offset: .zero, blur: 5)
                } else {
                    Draw.image(img, centeredIn: iconArea, shadow: UIColor(0, 0, 0, 0.9), offset: CGSize(width: 0, height: -1))
                }
            }
            Draw.text(item.title, font: Fonts.bold(10),
                      color: selected ? .white : UIColor(150, 150, 150),
                      in: CGRect(x: r.minX, y: 35, width: r.width, height: 12))
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = touches.first?.location(in: self) else { return }
        for index in items.indices {
            let r = itemRect(index)
            if point.x >= r.minX && point.x < r.maxX {
                onSelect?(index)
                return
            }
        }
    }
}
