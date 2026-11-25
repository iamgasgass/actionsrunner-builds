import UIKit

/// Le due interfacce dell'app, selezionabili dal menu "…".
enum InterfaceStyle: String, CaseIterable {
    case liquidGlass
    case ios6

    static let didChange = Notification.Name("RetroRemote.InterfaceStyleDidChange")

    var title: String {
        switch self {
        case .liquidGlass: return "Liquid Glass"
        case .ios6: return "iOS 6"
        }
    }

    var symbol: String {
        switch self {
        case .liquidGlass: return "drop.fill"
        case .ios6: return "square.stack.3d.down.right.fill"
        }
    }

    static var current: InterfaceStyle { Preferences.shared.interfaceStyle }
    static var isGlass: Bool { current == .liquidGlass }
}

/// Simbolo SF con alternative per le versioni di iOS che non lo hanno.
func systemSymbol(_ names: String..., size: CGFloat = 17, weight: UIImage.SymbolWeight = .semibold) -> UIImage? {
    let config = UIImage.SymbolConfiguration(pointSize: size, weight: weight)
    for name in names {
        if let image = UIImage(systemName: name, withConfiguration: config) { return image }
    }
    return nil
}
