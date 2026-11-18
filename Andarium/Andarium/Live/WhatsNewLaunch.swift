// SPDX-License-Identifier: GPL-2.0-or-later

import AndariumCore
import Foundation

extension AppEntry {
    /// The release notes of this launch. Info lists them in every launch. The
    /// person's own launch (`announcesWhatsNew`) also asks the rules for the
    /// ribbon above Start and keeps their record in `defaults`; any other
    /// shows no ribbon and keeps none, so a harness never sees the ribbon and
    /// never uses it up. `vCPUs` is the guest's count, at which the device's
    /// memory is measured for an entry's requirement; `features` is what the
    /// build has (`AppModel.buildFeatures`), and notes about one it lacks are
    /// in neither the ribbon nor Info. A track with no notes at all (the App
    /// Store's, until its version has some) has nothing to announce or to have
    /// seen: its launch lists none, shows no ribbon and keeps no record.
    @MainActor
    func announceWhatsNew(
        on model: AppModel, hasGuest: Bool, vCPUs: Int, features: Set<WhatsNewFeature>? = nil,
        notes: [WhatsNewRelease] = WhatsNewCatalog.load()
    ) {
        guard !notes.isEmpty else {
            model.whatsNew.list([])
            return
        }
        let features = features ?? model.buildFeatures
        let notes = WhatsNewCatalog.available(notes, features: features)
        guard announcesWhatsNew, let build else {
            model.whatsNew.list(notes)
            return
        }
        let store = WhatsNewStore(defaults: defaults)
        let host = model.host
        model.whatsNew.keep = { store.keep($0) }
        model.whatsNew.launch(
            releases: notes, record: store.record, currentBuild: build, hasGuest: hasGuest,
            offers: { $0.requirement?.isMet(by: host, vCPUs: vCPUs, features: features) ?? true })
    }
}
