import UIKit
import CarPlay

/// Scena CarPlay (app di navigazione): la mappa va nella CPWindow, i comandi nei template di CarPlay.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController,
                                  to window: CPWindow) {
        CarPlayManager.shared.connect(interfaceController, window: window)
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnect interfaceController: CPInterfaceController,
                                  from window: CPWindow) {
        CarPlayManager.shared.disconnect()
    }
}
