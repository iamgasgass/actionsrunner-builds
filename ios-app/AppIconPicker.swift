import SwiftUI
import UIKit

/// iLoader X's two icons: the Liquid Glass one (primary AppIcon.appiconset,
/// the same artwork as the in-app logo, AppLogo) and the iOS 6 one (alternate
/// AppIcon-iOS6). Each has its Dark and Tinted variants; iOS picks among those
/// itself, by the Home Screen's appearance.
enum AppIconChoice: String, CaseIterable, Identifiable {
    case liquidGlass
    case iOS6

    var id: String { rawValue }

    /// The name `setAlternateIconName` takes; nil for the primary icon.
    var alternateName: String? {
        switch self {
        case .liquidGlass: return nil
        case .iOS6: return "AppIcon-iOS6"
        }
    }

    var title: String {
        switch self {
        case .liquidGlass: return "Liquid Glass"
        case .iOS6: return "iOS 6"
        }
    }

    /// The tile shown in the picker (an app icon set can't be shown as an Image).
    var preview: String {
        switch self {
        case .liquidGlass: return "AppLogo"
        case .iOS6: return "IconPreviewIOS6"
        }
    }

    static var current: AppIconChoice {
        allCases.first { $0.alternateName == UIApplication.shared.alternateIconName } ?? .liquidGlass
    }
}

/// Settings › App Icon: the two icons side by side; a tap switches.
struct AppIconSection: View {
    @EnvironmentObject private var loc: Localizer
    @State private var selected = AppIconChoice.current
    @State private var failure: String?

    var body: some View {
        Section {
            HStack(spacing: 20) {
                ForEach(AppIconChoice.allCases) { choice in
                    Button { pick(choice) } label: { tile(choice) }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(choice == selected ? .isSelected : [])
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            if let failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(L("App Icon"))
        } footer: {
            Text(L("Each icon has Dark and Tinted versions, which iOS uses with the Home Screen's appearance."))
        }
    }

    private func tile(_ choice: AppIconChoice) -> some View {
        let shape = RoundedRectangle(cornerRadius: 64 * 23 / 86, style: .continuous)
        return VStack(spacing: 8) {
            Image(choice.preview)
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)
                .clipShape(shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                .overlay(shape.strokeBorder(Color.accentColor, lineWidth: choice == selected ? 3 : 0).padding(-5))
            Text(choice.title)
                .font(.footnote.weight(choice == selected ? .semibold : .regular))
                .foregroundStyle(choice == selected ? .primary : .secondary)
        }
        .padding(6)
        .contentShape(Rectangle())
    }

    private func pick(_ choice: AppIconChoice) {
        guard choice != selected, UIApplication.shared.supportsAlternateIcons else { return }
        let previous = selected
        selected = choice
        failure = nil
        UIApplication.shared.setAlternateIconName(choice.alternateName) { error in
            guard let error else { return }
            Task { @MainActor in
                selected = previous
                failure = L("Couldn't change the icon: %@", error.localizedDescription)
            }
        }
    }
}
