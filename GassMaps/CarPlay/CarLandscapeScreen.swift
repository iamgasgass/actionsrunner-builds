import SwiftUI
import UIKit

/// Ciò che serve allo schermo di CarPlay per avere una mappa propria dentro l'interfaccia del telefono:
/// il controller della mappa dell'auto (che riceve le stesse azioni di quello del telefono)
/// e la sua sorgente di posizione filtrata.
final class CarScreenContext {
    let map: MapController
    let feed: MapLocationFeed

    init(state: AppState) {
        map = MapController()
        map.state = state
        feed = state.location.makeMapFeed()
    }
}

private struct CarScreenKey: EnvironmentKey {
    static let defaultValue: CarScreenContext? = nil
}

extension EnvironmentValues {
    /// non nil quando la vista è disegnata sullo schermo di CarPlay
    var carScreen: CarScreenContext? {
        get { self[CarScreenKey.self] }
        set { self[CarScreenKey.self] = newValue }
    }
}

/// Lo schermo di CarPlay mostra esattamente la schermata principale di GassMaps in orizzontale:
/// mappa del tema, barra in alto, chip, scheda del luogo, indicazioni con i percorsi, banner di guida,
/// pannello con tempo/arrivo, tachimetro, pulsanti laterali… tutto uguale al telefono e sincronizzato con esso.
/// CarPlay non passa i tocchi alle viste dell'app: i comandi arrivano dai pulsanti e dagli elenchi di CarPlay
/// (CarPlayManager) e dai gesti sulla mappa (trascina, pizzica, frecce "Sposta").
struct CarLandscapeScreen: View {
    @ObservedObject var state: AppState
    let context: CarScreenContext

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MainMapScreen()
        }
        .environmentObject(state)
        .environmentObject(state.location)
        .environment(\.carScreen, context)
        .environment(\.isLandscapeLayout, true)
        .preferredColorScheme(.dark)
    }
}

/// Contenitore UIKit per la CPWindow
enum CarLandscapeHost {
    @MainActor
    static func make(state: AppState, context: CarScreenContext) -> UIViewController {
        let host = UIHostingController(rootView: CarLandscapeScreen(state: state, context: context))
        host.overrideUserInterfaceStyle = .dark
        host.view.backgroundColor = .black
        return host
    }
}
