import UIKit
import CarPlay

/// Schermo principale di CarPlay: la schermata principale di GassMaps in orizzontale (CarLandscapeScreen)
/// nella CPWindow, comandi dai pulsanti e dagli elenchi di CarPlay.
@MainActor
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

    /// Giorno/notte dell'auto: l'interfaccia di GassMaps resta quella del tema scelto (come sul telefono)
    func contentStyleDidChange(_ contentStyle: UIUserInterfaceStyle) {}

    /// Notifica di una manovra toccata mentre era aperta un'altra app: si torna alla guida
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didSelect maneuver: CPManeuver) {
        CarPlayManager.shared.showGuidance()
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didSelect navigationAlert: CPNavigationAlert) {
        CarPlayManager.shared.showGuidance()
    }
}

/// Riquadro di GassMaps nella schermata Dashboard di CarPlay: mappa che segue l'auto
/// (con il percorso durante la guida) e due scorciatoie (Casa, Lavoro…).
@MainActor
final class CarPlayDashboardSceneDelegate: UIResponder, CPTemplateApplicationDashboardSceneDelegate {
    func templateApplicationDashboardScene(_ templateApplicationDashboardScene: CPTemplateApplicationDashboardScene,
                                           didConnect dashboardController: CPDashboardController,
                                           to window: UIWindow) {
        CarPlayManager.shared.connectDashboard(dashboardController, window: window)
    }

    func templateApplicationDashboardScene(_ templateApplicationDashboardScene: CPTemplateApplicationDashboardScene,
                                           didDisconnect dashboardController: CPDashboardController,
                                           from window: UIWindow) {
        CarPlayManager.shared.disconnectDashboard()
    }
}

/// Quadro strumenti dell'auto (solo le auto che lo supportano): mappa che segue la marcia.
/// Le indicazioni nel quadro le disegna CarPlay dai metadati di navigazione (CarPlayManager).
/// I nomi dei metodi opzionali sono scritti in entrambe le forme possibili di importazione in Swift:
/// quella che corrisponde al protocollo viene usata, l'altra resta un normale metodo.
@MainActor
final class CarPlayInstrumentClusterSceneDelegate: UIResponder, CPTemplateApplicationInstrumentClusterSceneDelegate {
    private let windowDelegate = CarPlayClusterWindowDelegate()

    func templateApplicationInstrumentClusterScene(_ scene: CPTemplateApplicationInstrumentClusterScene,
                                                   didConnect instrumentClusterController: CPInstrumentClusterController) {
        clusterConnected(instrumentClusterController)
    }

    func templateApplicationInstrumentClusterScene(_ scene: CPTemplateApplicationInstrumentClusterScene,
                                                   didConnectInstrumentClusterController instrumentClusterController: CPInstrumentClusterController) {
        clusterConnected(instrumentClusterController)
    }

    func templateApplicationInstrumentClusterScene(_ scene: CPTemplateApplicationInstrumentClusterScene,
                                                   didDisconnect instrumentClusterController: CPInstrumentClusterController) {
        CarPlayManager.shared.disconnectCluster()
    }

    func templateApplicationInstrumentClusterScene(_ scene: CPTemplateApplicationInstrumentClusterScene,
                                                   didDisconnectInstrumentClusterController instrumentClusterController: CPInstrumentClusterController) {
        CarPlayManager.shared.disconnectCluster()
    }

    func contentStyleDidChange(_ contentStyle: UIUserInterfaceStyle) {}

    private func clusterConnected(_ controller: CPInstrumentClusterController) {
        controller.delegate = windowDelegate
        CarPlayManager.shared.connectCluster(controller)
        if let w = controller.instrumentClusterWindow { CarPlayManager.shared.clusterWindowConnected(w) }
    }
}

/// Finestra e zoom del quadro strumenti (protocollo non legato al thread principale: si passa al main actor)
final class CarPlayClusterWindowDelegate: NSObject, CPInstrumentClusterControllerDelegate {
    func instrumentClusterControllerDidConnect(_ instrumentClusterWindow: UIWindow) { connected(instrumentClusterWindow) }
    func instrumentClusterControllerDidConnectWindow(_ instrumentClusterWindow: UIWindow) { connected(instrumentClusterWindow) }
    func instrumentClusterControllerDidDisconnect(_ instrumentClusterWindow: UIWindow) { disconnected() }
    func instrumentClusterControllerDidDisconnectWindow(_ instrumentClusterWindow: UIWindow) { disconnected() }

    func instrumentClusterControllerDidZoom(in instrumentClusterController: CPInstrumentClusterController) { zoom(1) }
    func instrumentClusterControllerDidZoomIn(_ instrumentClusterController: CPInstrumentClusterController) { zoom(1) }
    func instrumentClusterControllerDidZoom(out instrumentClusterController: CPInstrumentClusterController) { zoom(-1) }
    func instrumentClusterControllerDidZoomOut(_ instrumentClusterController: CPInstrumentClusterController) { zoom(-1) }

    private func connected(_ window: UIWindow) {
        MainActor.assumeIsolated { CarPlayManager.shared.clusterWindowConnected(window) }
    }

    private func disconnected() {
        MainActor.assumeIsolated { CarPlayManager.shared.clusterWindowDisconnected() }
    }

    private func zoom(_ delta: Double) {
        MainActor.assumeIsolated { CarPlayManager.shared.zoomCluster(by: delta) }
    }
}
