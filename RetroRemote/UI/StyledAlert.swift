import UIKit

/// Alert che usa UIAlertController in stile Liquid Glass e l'alert blu iOS 6 nell'altro stile.
final class StyledAlert {
    enum ActionStyle { case normal, cancel, destructive }

    private struct Action {
        let title: String
        let style: ActionStyle
        let handler: ((StyledAlert) -> Void)?
    }

    private struct Field {
        let placeholder: String
        let text: String?
        let keyboard: UIKeyboardType
        let capitalization: UITextAutocapitalizationType
    }

    private let title: String?
    private let message: String?
    private var actions: [Action] = []
    private var fields: [Field] = []
    private(set) var values: [String] = []
    /// In Liquid Glass mostra un foglio di azioni invece di un alert (per elenchi di scelte).
    var prefersSheet = false

    init(title: String?, message: String?) {
        self.title = title
        self.message = message
    }

    func addAction(_ title: String, style: ActionStyle = .normal, handler: ((StyledAlert) -> Void)? = nil) {
        actions.append(Action(title: title, style: style, handler: handler))
    }

    func addTextField(placeholder: String, text: String? = nil, keyboard: UIKeyboardType = .default,
                      capitalization: UITextAutocapitalizationType = .none) {
        fields.append(Field(placeholder: placeholder, text: text, keyboard: keyboard, capitalization: capitalization))
    }

    func value(_ index: Int) -> String {
        values.indices.contains(index) ? values[index].trimmingCharacters(in: .whitespaces) : ""
    }

    func show(from presenter: UIViewController, sourceView: UIView? = nil) {
        var top = presenter
        while let presented = top.presentedViewController { top = presented }

        if InterfaceStyle.isGlass {
            let sheet = prefersSheet && fields.isEmpty
            let controller = UIAlertController(title: title, message: message, preferredStyle: sheet ? .actionSheet : .alert)
            for field in fields {
                controller.addTextField { textField in
                    textField.placeholder = field.placeholder
                    textField.text = field.text
                    textField.keyboardType = field.keyboard
                    textField.autocapitalizationType = field.capitalization
                    textField.autocorrectionType = .no
                    textField.clearButtonMode = .whileEditing
                }
            }
            for action in actions {
                let style: UIAlertAction.Style
                switch action.style {
                case .normal: style = .default
                case .cancel: style = .cancel
                case .destructive: style = .destructive
                }
                controller.addAction(UIAlertAction(title: action.title, style: style) { [weak controller] _ in
                    self.values = controller?.textFields?.map { $0.text ?? "" } ?? []
                    action.handler?(self)
                })
            }
            if let popover = controller.popoverPresentationController {
                let anchor = sourceView ?? top.view!
                popover.sourceView = anchor
                popover.sourceRect = sourceView == nil
                    ? CGRect(x: anchor.bounds.midX, y: anchor.bounds.midY, width: 1, height: 1)
                    : anchor.bounds
            }
            top.present(controller, animated: true)
        } else {
            let controller = ClassicAlertController(title: title, message: message)
            for field in fields {
                controller.addTextField(placeholder: field.placeholder, text: field.text,
                                        keyboard: field.keyboard, capitalization: field.capitalization)
            }
            for action in actions {
                controller.addAction(action.title, style: action.style == .cancel ? .cancel : .normal) { alert in
                    self.values = alert.textFields.map { $0.text ?? "" }
                    action.handler?(self)
                }
            }
            controller.show(from: top)
        }
    }
}
