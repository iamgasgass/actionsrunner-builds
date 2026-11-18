// SPDX-License-Identifier: GPL-2.0-or-later

#if TIP_JAR

import AndariumCore
import SwiftUI

/// The system symbol of Buy me tokens, beside its menu item and its sheet's
/// title.
enum TipJarSymbols {
    static let menuItem = "cup.and.heat.waves"
}

/// One opening of the sheet: a model made when the sheet appears and closed
/// when it goes, so that nothing outlives it.
private struct TipJarPresentation: View {
    let app: AppModel
    @State private var jar: TipJarModel?
    @State private var sender: TipJarSenderContent

    init(app: AppModel) {
        self.app = app
        _jar = State(initialValue: app.makeTipJarModel())
        _sender = State(initialValue: app.tipJarServices.sender())
    }

    var body: some View {
        if let jar {
            TipJarSheet(jar: jar, sender: sender, device: app.host.name) { app.tipJarSheetOpen = false }
                .onDisappear { jar.close() }
                #if !APP_STORE
                .environment(\.openURL, OpenURLAction { app.tipJarServices.openLink($0) })
                .environment(\.tipJarFullHeight, app.tipJarServices.previewFullHeight)
                .task { await app.tipJarServices.previewPlays(jar) }
                #endif
        }
    }
}

extension View {
    /// Presents Buy me tokens over Home. Only the menu item opens it.
    func tipJarSheet(_ app: AppModel) -> some View {
        sheet(isPresented: Binding(get: { app.tipJarSheetOpen }, set: { app.tipJarSheetOpen = $0 })) {
            // Outside the sheet's own detent and sizing, as the shared presentation needs: turned and
            // bent the sheet rises to a little below the fold; anywhere else it is the sheet's own.
            TipJarPresentation(app: app)
                .environment(app)
                .foldSheet(app)
        }
        #if !APP_STORE
        .task {
            // The Simulator preview opens it once Home has settled, as a tap
            // would; a sheet presented while its presenter still moves is
            // laid out inside it.
            guard app.tipJarServices.previewOpensSheet else { return }
            try? await Task.sleep(for: .milliseconds(1200))
            app.tipJarSheetOpen = true
        }
        #endif
    }
}

#endif
