// SPDX-License-Identifier: GPL-2.0-or-later

#if FEEDBACK_MAIL

import SwiftUI

/// The row that opens Send feedback from a running session's Settings: the
/// first row of Diagnostics, above Create bug report. Home reaches it from its
/// toolbar menu.
struct SendFeedbackEntrance: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.feedbackSheetOpen = true
        } label: {
            HStack(spacing: 12) {
                IconTile(symbol: "envelope.fill")
                    .accessibilityHidden(true)
                Text("Send feedback\u{2026}", tableName: "Feedback")
                    .foregroundStyle(Color.accentColor)
                Spacer()
            }
            .contentShape(.rect)
        }
        .accessibilityIdentifier("settings-send-feedback")
    }
}

extension View {
    /// Presents Send feedback over Home or Settings. It stays over Settings,
    /// which does not close beneath it, so a bug report made from the sheet
    /// leaves the session as it was.
    ///
    func sendFeedbackSheet(_ app: AppModel) -> some View {
        sheet(isPresented: Binding(get: { app.feedbackSheetOpen }, set: { app.feedbackSheetOpen = $0 })) {
            SendFeedbackSheet(app: app)
                .environment(app)
                .statusBarHidden(app.virtualMachineRuns)
        }
        #if !APP_STORE
        .task {
            // The Simulator preview opens it once Home or Settings has
            // settled, as a tap would; a sheet presented while its presenter
            // still moves is laid out inside it.
            guard app.feedbackServices.previewOpensAtLaunch else { return }
            try? await Task.sleep(for: .milliseconds(1600))
            app.feedbackSheetOpen = true
        }
        #endif
    }

    /// Presents the Send feedback sheet the boot screen's notice opens, from
    /// the root, which every phase is under: the sheet and what the person
    /// typed in it stay up when the boot completes, restarts or ends. Its own
    /// flag keeps it apart from Home's and Settings' presenters.
    func sendFeedbackFromBootSheet(_ app: AppModel) -> some View {
        sheet(isPresented: Binding(get: { app.feedbackFromBoot }, set: { app.feedbackFromBoot = $0 })) {
            SendFeedbackSheet(app: app)
                .environment(app)
                .statusBarHidden(app.virtualMachineRuns)
        }
        #if !APP_STORE
        .task {
            // The Simulator preview opens it over the boot screen once that has
            // settled; only `feedback-boot…` shots ask.
            guard app.feedbackServices.previewOpensOverBoot else { return }
            try? await Task.sleep(for: .milliseconds(1600))
            app.feedbackFromBoot = true
        }
        #endif
    }
}

#endif
