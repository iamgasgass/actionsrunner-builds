import UIKit
import AudioToolbox

enum Feedback {
    private static let impact = UIImpactFeedbackGenerator(style: .light)
    private static let selectionGenerator = UISelectionFeedbackGenerator()

    /// Vibrazione leggera + il "clic" della tastiera di iOS.
    static func tap() {
        if Preferences.shared.haptics { impact.impactOccurred() }
        if Preferences.shared.clicks { AudioServicesPlaySystemSound(1104) }
    }

    static func selection() {
        if Preferences.shared.haptics { selectionGenerator.selectionChanged() }
    }
}
