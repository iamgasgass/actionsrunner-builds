// SPDX-License-Identifier: GPL-2.0-or-later

#if APP_REVIEW

import Foundation

extension AppEntry {
    /// The rating prompt of the application's own launch (`ReviewAsk`). A
    /// hosted test makes its own with doubles, and the Simulator preview has
    /// none, so neither asks. A Debug build can set the counter and clear the
    /// attempts for its own check from the environment
    /// (`ANDARIUM_REVIEW_ASK_SECONDS`, `ANDARIUM_REVIEW_ASK_RESET=1`); an App
    /// Store build compiles that out.
    @MainActor
    static func addRatingPrompt(to model: AppModel) {
        #if !APP_STORE
        let environment = ProcessInfo.processInfo.environment
        guard environment["XCTestConfigurationFilePath"] == nil else { return }
        #endif
        let ask = ReviewAsk(model: model, services: model.reviewServices.ask)
        #if !APP_STORE
        ask.applyDebugLaunch(environment: environment)
        #endif
        model.reviewAsk = ask
    }
}

#endif
