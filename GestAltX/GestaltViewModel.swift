import Combine
import Foundation

@MainActor
final class GestaltViewModel: ObservableObject {
    @Published var plist: GestaltPlist? {
        didSet { appliedTweaks = Self.appliedTweaks(in: plist) }
    }
    /// Presets currently written in `plist` (cached: iPadOS Mode needs a CacheData scan).
    @Published private(set) var appliedTweaks: Set<GestaltTweakID> = []
    /// Presets already present in the oldest backup, i.e. values of the device itself.
    @Published private(set) var originalTweaks: Set<GestaltTweakID> = []
    @Published var isDirty = false
    @Published var isBusy = false
    @Published var notice: GestaltNotice?
    @Published private(set) var hasAttemptedLoad = false
    @Published private(set) var backups: [GestaltBackup] = []
    /// MobileGestalt as it was in the oldest local backup (taken before the first write).
    @Published private(set) var originalBaseline: GestaltPlist? {
        didSet { originalTweaks = Self.appliedTweaks(in: originalBaseline) }
    }

    private static func appliedTweaks(in plist: GestaltPlist?) -> Set<GestaltTweakID> {
        guard let plist else { return [] }
        return Set(GestaltTweakCatalog.definitions.filter { plist.isApplied($0) }.map(\.id))
    }
    @Published var selectedTweaks: Set<GestaltTweakID> = []
    /// Presets already written in MobileGestalt that the user switched off: removed on Apply.
    @Published var revertedTweaks: Set<GestaltTweakID> = []
    @Published var dynamicIslandSubtype: Int?
    @Published var changesModelName = false
    @Published var modelName = ""
    @Published var stagesAIRegion = false
    @Published var regionPresetID: String?
    @Published private(set) var isRespringing = false

    enum Device: Hashable { case iPhone, appleWatch }
    @Published private(set) var selectedDevice: Device = .iPhone
    @Published var isDeviceSelectorExpanded = true
    let watch = WatchConnection()
    private var watchDeviceID: String?
    private var watchSnapshot: Data?
    private var watchGeneration = 0
    private var watchSubscription: AnyCancellable?

    init() {
        watchSubscription = watch.$pairingGeneration.dropFirst().sink { [weak self] _ in
            guard let self, self.selectedDevice == .appleWatch else { return }
            self.watchGeneration += 1
            self.clearStagedChanges()
            self.isDirty = false
            self.plist = nil
            self.watchSnapshot = nil
            self.watchDeviceID = nil
            self.backups = []
        }
    }

    func selectDevice(_ device: Device) {
        guard !isBusy, device != selectedDevice else { return }
        selectedDevice = device
        plist = nil
        isDirty = false
        clearStagedChanges()
        watchSnapshot = nil
        watchDeviceID = nil
        backups = []
        load()
    }

    var deviceContextID: String {
        selectedDevice == .iPhone ? "iPhone" : "AppleWatch-\(watchGeneration)-\(watchDeviceID ?? "unavailable")"
    }

    private func clearStagedChanges() {
        selectedTweaks.removeAll()
        revertedTweaks.removeAll()
        dynamicIslandSubtype = nil
        changesModelName = false
        modelName = ""
        stagesAIRegion = false
        regionPresetID = nil
        selectedWatchTweaks.removeAll()
        watchRegionCode = ""
        watchSalesRegion = ""
        watchResolution = -1
        watchUltraFaceClass = 29
    }

    @Published var selectedWatchTweaks: Set<String> = []
    @Published var watchRegionCode = ""
    @Published var watchSalesRegion = ""
    @Published var watchResolution = -1
    @Published var watchUltraFaceClass = 29

    var watchUltraFaceClassOptions: [Int] {
        guard selectedDevice == .appleWatch, let plist else { return [] }
        return WatchTweakCatalog.ultraFaceClasses(plist: plist, build: watch.build)
    }

    var currentWatchUltraFaceClass: Int? {
        guard selectedDevice == .appleWatch, let plist else { return nil }
        return WatchTweakCatalog.currentUltraFaceClass(plist: plist, build: watch.build)
    }

    private func syncWatchUltraFaceClass() {
        watchUltraFaceClass = currentWatchUltraFaceClass ?? watchUltraFaceClassOptions.first ?? 29
    }

    var supportsWatchFaces: Bool {
        guard selectedDevice == .appleWatch, let plist else { return false }
        return WatchTweakCatalog.faceLayout(plist: plist, build: watch.build) != nil
    }

    private let access = GestaltAccess.shared()

    var aiRegionProfile: AIRegionProfile? {
        plist.flatMap(AIRegionProfile.init(plist:))
    }

    var requiresForcedAIEnable: Bool {
        plist.map { AIRegionConfiguration.resolve(for: $0).requiresDeviceSpoofing } ?? false
    }

    var hasStagedTweaks: Bool {
        if selectedDevice == .appleWatch { return stagedChangeCount > 0 }
        return !selectedTweaks.isEmpty
            || !revertedTweaks.isEmpty
            || dynamicIslandSubtype != nil
            || (changesModelName && !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            || stagesAIRegion
            || regionPresetID != nil
    }

    var stagedChangeCount: Int {
        if selectedDevice == .appleWatch {
            return selectedWatchTweaks.count + (watchRegionCode.isEmpty ? 0 : 1)
                + (watchSalesRegion.isEmpty ? 0 : 1) + (watchResolution >= 0 ? 1 : 0)
        }
        return selectedTweaks.count
            + revertedTweaks.count
            + (dynamicIslandSubtype == nil || selectedTweaks.contains(.supportsDynamicIsland) ? 0 : 1)
            + (changesModelName ? 1 : 0)
            + (stagesAIRegion ? 1 : 0)
            + (regionPresetID == nil ? 0 : 1)
    }

    func load() {
        guard !isBusy else { return }
        hasAttemptedLoad = true
        if selectedDevice == .appleWatch { loadWatch(); return }
        isBusy = true
        notice = nil

        defer { isBusy = false }
        do {
            try access.connect()
            guard let dictionary = try access.readGestalt() as? [String: Any] else {
                throw GestAltXError.invalidPlist
            }
            plist = GestaltPlist(dict: dictionary)
            isDirty = false
            refreshBackups()
        } catch {
            plist = nil
            report(error)
        }
    }

    var stagedAIRegionPresetID: String? {
        guard stagesAIRegion, let plist else { return regionPresetID }
        return AIRegionConfiguration.resolve(for: plist).changesRegion ? "LL" : regionPresetID
    }

    func setRegionPreset(_ id: String?) {
        guard !stagesAIRegion else { return }
        regionPresetID = id
    }

    /// The preset is written in the current MobileGestalt.
    func isApplied(_ id: GestaltTweakID) -> Bool {
        appliedTweaks.contains(id)
    }

    /// Written and not scheduled for removal.
    func isActive(_ id: GestaltTweakID) -> Bool {
        isApplied(id) && !revertedTweaks.contains(id)
    }

    /// Stage Manager and iPad apps are part of iPadOS Mode while it is selected or active.
    func isIncludedInIPadOS(_ id: GestaltTweakID) -> Bool {
        GestaltTweakCatalog.iPadIncludedTweaks.contains(id)
            && (selectedTweaks.contains(.iPadOS) || isActive(.iPadOS))
    }

    /// The toggle state shown in Tools: what MobileGestalt will contain after Apply.
    func isTweakOn(_ id: GestaltTweakID) -> Bool {
        isIncludedInIPadOS(id) || selectedTweaks.contains(id) || isActive(id)
    }

    func setTweak(_ id: GestaltTweakID, enabled: Bool) {
        if enabled {
            if revertedTweaks.contains(id) {
                // Undo a pending removal instead of rewriting the same values.
                revertedTweaks.remove(id)
                if id == .iPadOS { revertedTweaks.subtract(GestaltTweakCatalog.iPadIncludedTweaks) }
                if id == .enableLiquidGlassLowPerformance { setTweak(.disableLiquidGlassLowPerformance, enabled: false) }
                if id == .disableLiquidGlassLowPerformance { setTweak(.enableLiquidGlassLowPerformance, enabled: false) }
                return
            }
            guard !isApplied(id) else { return }
            selectedTweaks = GestaltTweakCatalog.selecting(id, enabled: true, in: selectedTweaks)
            if id == .iPadOS { revertedTweaks.subtract(GestaltTweakCatalog.iPadIncludedTweaks) }
            if id == .enableLiquidGlassLowPerformance, isApplied(.disableLiquidGlassLowPerformance) {
                revertedTweaks.insert(.disableLiquidGlassLowPerformance)
            }
            if id == .disableLiquidGlassLowPerformance, isApplied(.enableLiquidGlassLowPerformance) {
                revertedTweaks.insert(.enableLiquidGlassLowPerformance)
            }
        } else {
            selectedTweaks = GestaltTweakCatalog.selecting(id, enabled: false, in: selectedTweaks)
            if isApplied(id) {
                revertedTweaks.insert(id)
                if id == .iPadOS {
                    // Its keys include Stage Manager and iPad apps: turning iPadOS Mode off removes them too.
                    for included in GestaltTweakCatalog.iPadIncludedTweaks where isApplied(included) {
                        revertedTweaks.insert(included)
                    }
                }
            }
        }
    }

    func setAIRegion(enabled: Bool) {
        stagesAIRegion = enabled
        if enabled {
            regionPresetID = nil
        }
        if enabled, requiresForcedAIEnable {
            let twoStage = plist.map { AIRegionConfiguration.resolve(for: $0).usesTwoStageSetup } ?? false
            notice = GestaltNotice(
                kind: .riskWarning,
                message: twoStage
                    ? String(localized: "First, this will temporarily spoof an eligible device. Face ID and dictation may stop working while spoofed. Complete the Siri AI model download in Settings, then open Restore and use “After Model Download · Remove Device Spoof”. After removing the spoof and restarting, Face ID and dictation will work again while Siri AI settings stay enabled. A separate full backup is also saved before setup. System instability is possible.")
                    : String(localized: "This device does not officially support Siri AI. Force enabling spoofs the product, hardware, and CPU model. It may temporarily break Face ID, cause system instability or boot loops, and could require restoring the device. A backup will be created before writing.")
            )
        }
    }

    private var selectedBackupActions: [String] {
        var actions: [String]
        if selectedDevice == .appleWatch {
            actions = WatchTweakCatalog.definitions.filter { selectedWatchTweaks.contains($0.id) }.map(\.title)
            if !watchRegionCode.isEmpty { actions.append(String(localized: "Region") + ": " + watchRegionCode) }
            if !watchSalesRegion.isEmpty { actions.append(String(localized: "Sales Region") + ": " + watchSalesRegion) }
            if WatchTweakCatalog.resolutions.indices.contains(watchResolution) { actions.append(String(localized: "Resolution")) }
        } else {
            actions = GestaltTweakCatalog.definitions.filter { selectedTweaks.contains($0.id) }.map(\.title)
            actions += GestaltTweakCatalog.definitions.filter { revertedTweaks.contains($0.id) }
                .map { String(localized: "Remove") + ": " + $0.title }
            if dynamicIslandSubtype != nil { actions.append(String(localized: "Dynamic Island")) }
            if changesModelName { actions.append(String(localized: "Model Name")) }
            if let regionPresetID { actions.append(String(localized: "Region") + ": " + regionPresetID) }
            if stagesAIRegion { actions.append(String(localized: "Enable Siri AI")) }
        }
        return actions
    }

    func applySelectedTweaks() {
        if selectedDevice == .appleWatch { applyWatchTweaks(); return }
        guard !isBusy, var pending = plist else { return }
        do {
            if !revertedTweaks.isEmpty {
                // Keys shared with presets that stay on (e.g. Stage Manager inside iPadOS Mode) are kept.
                let staying = GestaltTweakCatalog.definitions.filter {
                    !revertedTweaks.contains($0.id) && (selectedTweaks.contains($0.id) || isApplied($0.id))
                }
                let keptKeys = Set(staying.flatMap { $0.values.keys })
                let original = originalBaseline
                for definition in GestaltTweakCatalog.definitions where revertedTweaks.contains(definition.id) {
                    try pending.revert(definition: definition, original: original, keeping: keptKeys)
                }
            }
            for id in selectedTweaks {
                guard let definition = GestaltTweakCatalog.definition(for: id) else { continue }
                try pending.apply(definition: definition)
            }
            if let dynamicIslandSubtype {
                try pending.setDynamicIslandSubtype(dynamicIslandSubtype)
            }
            if changesModelName {
                let name = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { throw GestAltXError.emptyModelName }
                try pending.setModelName(name)
            }
            if let regionPresetID,
               let region = GestaltRegionPreset.all.first(where: { $0.id == regionPresetID }) {
                pending.apply(region: region)
            }
            var expectedConfiguration: AIRegionConfiguration?
            if stagesAIRegion {
                let configuration = AIRegionConfiguration.resolve(for: pending)
                configuration.apply(to: &pending)
                expectedConfiguration = configuration
            }
            save(pending, expectedAIRegion: expectedConfiguration, actions: selectedBackupActions) { [weak self] in
                self?.selectedTweaks.removeAll()
                self?.revertedTweaks.removeAll()
                self?.dynamicIslandSubtype = nil
                self?.changesModelName = false
                self?.modelName = ""
                self?.stagesAIRegion = false
                self?.regionPresetID = nil
            }
        } catch {
            report(error)
        }
    }

    func applyChanges() {
        guard !isBusy, let plist else { return }
        save(plist, expectedAIRegion: nil)
    }

    func createBackup() {
        guard !isBusy else { return }
        if selectedDevice == .appleWatch { backupWatch(); return }
        isBusy = true
        defer { isBusy = false }
        do {
            try access.connect()
            let data = try access.readGestaltData()
            let backup = try GestaltBackupStore.create(from: data, record: .init(source: .manual, actions: [], changes: []))
            refreshBackups()
            notice = GestaltNotice(
                kind: .backupCreated,
                message: String(
                    format: String(localized: "Saved %@.plist. You can export it from the Backups tab."),
                    backup.name
                )
            )
        } catch {
            report(error)
        }
    }

    func importBackup(from url: URL) {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        guard selectedDevice != .appleWatch || watchDeviceID != nil else {
            report(WatchMGWire.failure(String(localized: "Reload Apple Watch before saving.")))
            return
        }
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let data = try Data(contentsOf: url)
            var format = PropertyListSerialization.PropertyListFormat.binary
            guard let dictionary = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: &format
            ) as? [String: Any],
                  dictionary["CacheExtra"] is [String: Any] else {
                throw GestAltXError.invalidBackup
            }
            let backup = try GestaltBackupStore.create(from: data, deviceID: selectedDevice == .appleWatch ? watchDeviceID : nil, record: .init(source: .imported, actions: [], changes: []))
            refreshBackups()
            notice = GestaltNotice(
                kind: .backupCreated,
                message: String(
                    format: String(localized: "Imported %@ and saved it as %@.plist."),
                    url.lastPathComponent,
                    backup.name
                )
            )
        } catch {
            report(error)
        }
    }

    func restore(_ backup: GestaltBackup) {
        guard !isBusy else { return }
        do {
            let data = try GestaltBackupStore.data(for: backup)
            var format = PropertyListSerialization.PropertyListFormat.binary
            guard let dictionary = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: &format
            ) as? [String: Any] else {
                throw GestAltXError.invalidBackup
            }
            let snapshot = GestaltPlist(dict: dictionary)
            if backup.purpose == .siriAIIdentityRestore {
                guard selectedDevice == .iPhone,
                      snapshot.dict["CacheExtra"] is [String: Any],
                      let currentDictionary = try access.readGestalt() as? [String: Any] else {
                    throw GestAltXError.invalidBackup
                }
                let current = GestaltPlist(dict: currentDictionary)
                guard SiriAIIdentityRestore.sameDevice(current, snapshot) else {
                    throw GestAltXError.wrongDeviceBackup
                }
                let restored = SiriAIIdentityRestore.restoring(current, from: snapshot)
                save(restored, expectedAIRegion: nil,
                     expectedIdentity: SiriAIIdentityRestore.values(in: snapshot),
                     source: .restore, actions: [String(localized: "Remove Device Spoof")]) { [weak self] in
                    self?.clearStagedChanges()
                }
            } else {
                save(snapshot, expectedAIRegion: nil, source: .restore, actions: [String(localized: "Restore Backup"), backup.name]) { [weak self] in self?.clearStagedChanges() }
            }
        } catch {
            report(error)
        }
    }

    func delete(_ backup: GestaltBackup) {
        do {
            try GestaltBackupStore.delete(backup)
            refreshBackups()
        } catch {
            report(error)
        }
    }

    /// The value comes from the device itself (already present before the first backup).
    func isOriginalValue(_ id: GestaltTweakID) -> Bool {
        originalTweaks.contains(id)
    }

    /// The oldest local backup: the closest thing to the device's untouched MobileGestalt.
    private func originalDevicePlist() -> GestaltPlist? {
        guard let oldest = backups.filter({ $0.purpose == .standard }).min(by: { $0.createdAt < $1.createdAt }),
              let data = try? GestaltBackupStore.data(for: oldest),
              let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        return GestaltPlist(dict: dictionary)
    }

    func refreshBackups() {
        do {
            if selectedDevice == .appleWatch && watchDeviceID == nil { backups = []; return }
            backups = try GestaltBackupStore.list(deviceID: selectedDevice == .appleWatch ? watchDeviceID : nil)
            originalBaseline = selectedDevice == .iPhone ? originalDevicePlist() : nil
        } catch {
            report(error)
        }
    }

    private func siriAIOriginalIdentity(current: GestaltPlist, configuration: AIRegionConfiguration) throws -> GestaltPlist {
        // Reapplying setup must not replace the real identity baseline with an
        // already-spoofed identity. Prefer the dedicated recovery snapshot.
        guard current.cacheExtra["h9jDsbgj7xIVeIQ8S3/X3Q"] as? String == configuration.spoofedProductType else {
            return current
        }
        let saved = try GestaltBackupStore.list()
        let candidates = saved.filter { $0.purpose == .siriAIIdentityRestore }
            + saved.filter { $0.purpose != .siriAIIdentityRestore }.reversed()
        for backup in candidates {
            guard let data = try? GestaltBackupStore.data(for: backup),
                  let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  dictionary["CacheExtra"] is [String: Any] else { continue }
            let candidate = GestaltPlist(dict: dictionary)
            if SiriAIIdentityRestore.sameDevice(current, candidate),
               candidate.cacheExtra["h9jDsbgj7xIVeIQ8S3/X3Q"] as? String != configuration.spoofedProductType {
                return candidate
            }
        }
        throw GestAltXError.missingOriginalIdentityBackup
    }

    private func save(
        _ pendingPlist: GestaltPlist,
        expectedAIRegion: AIRegionConfiguration?,
        expectedIdentity: NSDictionary? = nil,
        source: GestaltBackupRecord.Source = .modification,
        actions: [String] = [],
        completion: (() -> Void)? = nil
    ) {
        if selectedDevice == .appleWatch {
            saveWatch(pendingPlist, source: source, actions: actions, completion: completion)
            return
        }
        isBusy = true
        notice = nil

        do {
            let originalData = try access.readGestaltData()
            let record = try GestaltBackupRecord.modification(from: originalData, to: pendingPlist.dict, source: source, actions: actions)
            let automaticBackup = try GestaltBackupStore.create(from: originalData, record: record)
            if let configuration = expectedAIRegion, configuration.usesTwoStageSetup {
                guard let originalDictionary = try PropertyListSerialization.propertyList(from: originalData, format: nil) as? [String: Any],
                      originalDictionary["CacheExtra"] is [String: Any] else {
                    throw GestAltXError.invalidPlist
                }
                let original = GestaltPlist(dict: originalDictionary)
                let baseline = try siriAIOriginalIdentity(current: original, configuration: configuration)
                let recovery = SiriAIIdentityRestore.restoring(pendingPlist, from: baseline)
                let recoveryData = try PropertyListSerialization.data(fromPropertyList: recovery.dict, format: .binary, options: 0)
                _ = try GestaltBackupStore.create(from: recoveryData, purpose: .siriAIIdentityRestore,
                    record: try .modification(from: PropertyListSerialization.data(fromPropertyList: pendingPlist.dict, format: .binary, options: 0),
                                              to: recovery.dict, source: .identityRecovery, actions: []))
            }
            try access.saveGestalt(pendingPlist.dict)
            guard let verification = try access.readGestalt() as? [String: Any] else {
                throw GestAltXError.invalidPlist
            }
            let verifiedPlist = GestaltPlist(dict: verification)
            if let expectedIdentity,
               !expectedIdentity.isEqual(SiriAIIdentityRestore.values(in: verifiedPlist)) {
                throw GestAltXError.verificationFailed
            }

            if let expectedAIRegion {
                let cacheExtra = verifiedPlist.cacheExtra
                guard AIRegionConfiguration.regionValues(in: verifiedPlist)
                    .isEqual(AIRegionConfiguration.regionValues(in: pendingPlist)) else {
                    throw GestAltXError.verificationFailed
                }
                if expectedAIRegion.enablesSiriMode,
                   cacheExtra["a3n5T9sFtlyQ74NEp9ESxg"] as? Int != 2 {
                    throw GestAltXError.verificationFailed
                }
                if expectedAIRegion.requiresDeviceSpoofing {
                    guard cacheExtra["A62OafQ85EJAiiqKn4agtg"] as? Int == 1,
                          cacheExtra["a3n5T9sFtlyQ74NEp9ESxg"] as? Int == 2,
                          cacheExtra["h9jDsbgj7xIVeIQ8S3/X3Q"] as? String == expectedAIRegion.spoofedProductType,
                          cacheExtra["oYicEKzVTz4/CxxE05pEgQ"] as? String == expectedAIRegion.spoofedHardwareModel,
                          cacheExtra["5pYKlGnYYBzGvAlIU8RjEQ"] as? String == expectedAIRegion.spoofedCPUModel else {
                        throw GestAltXError.verificationFailed
                    }
                }
            }

            if NSDictionary(dictionary: verification).isEqual(to: pendingPlist.dict) {
                try? GestaltBackupStore.markVerified(automaticBackup)
            }
            plist = verifiedPlist
            isDirty = false
            completion?()
            refreshBackups()
            isBusy = false
            isRespringing = true
        } catch {
            isDirty = true
            refreshBackups()
            report(error)
            isBusy = false
        }
    }

    private func applyWatchTweaks() {
        guard !isBusy, let plist else { return }
        do {
            var pending = plist
            if !watchRegionCode.isEmpty {
                guard WatchTweakCatalog.regions.contains(where: { $0.1 == watchRegionCode }) else { return }
                pending.setCacheExtra(watchRegionCode, forKey: "h63QSdBCiT/z0WU6rdQv6Q")
            }
            if !watchSalesRegion.isEmpty {
                guard WatchTweakCatalog.regions.contains(where: { $0.2 == watchSalesRegion }) else { return }
                let current = "zHeENZu+wbg7PUprwNwBWg", legacy = "yK+xavymRGZ3xWc1tb8XDg"
                let hasCurrent = pending.cacheExtra[current] != nil, hasLegacy = pending.cacheExtra[legacy] != nil
                if hasCurrent || !hasLegacy { pending.setCacheExtra(watchSalesRegion, forKey: current) }
                if hasLegacy { pending.setCacheExtra(watchSalesRegion, forKey: legacy) }
            }
            // Apply the combined AI preset after manual region selections so
            // enabling it cannot leave a newly selected unsupported MG region.
            pending = try WatchTweakCatalog.apply(selectedWatchTweaks, to: pending, build: watch.build,
                                                  regionIdentifier: watch.regionIdentifier,
                                                  ultraFaceClass: watchUltraFaceClass,
                                                  original: selectedWatchTweaks.contains("ultra") ? try originalWatchCache() : nil,
                                                  hardwareIdentifier: watch.hardwareIdentifier)
            if WatchTweakCatalog.resolutions.indices.contains(watchResolution) {
                let resolution = WatchTweakCatalog.resolutions[watchResolution]
                pending.setCacheExtra(resolution.1, forKey: "g7YQ1Djxh4YiKlEeaoGhzg")
                pending.setCacheExtra(resolution.2, forKey: "OjzOua0LkOegX7pQdgMksw")
            }
            saveWatch(pending, actions: selectedBackupActions) { [weak self] in
                self?.clearStagedChanges()
                self?.syncWatchUltraFaceClass()
            }
        } catch { report(error) }
    }

    private func originalWatchCache() throws -> GestaltPlist {
        // Automatic pre-write backups preserve the state before the first Ultra
        // edit, including across reloads and switching back from class 38.
        if let id = watchDeviceID {
            for backup in try GestaltBackupStore.list(deviceID: id).reversed() {
                guard let data = try? GestaltBackupStore.data(for: backup),
                      let dict = try? WatchMGWire.decode(data) else { continue }
                let candidate = GestaltPlist(dict: dict)
                if WatchTweakCatalog.faceLayout(plist: candidate, build: watch.build) != nil {
                    return candidate
                }
            }
        }
        guard let watchSnapshot else { throw WatchMGWire.failure(String(localized: "Reload Apple Watch before saving.")) }
        return GestaltPlist(dict: try WatchMGWire.decode(watchSnapshot))
    }

    private func loadWatch() {
        isBusy = true
        notice = nil
        let generation = watchGeneration
        Task {
            defer { isBusy = false }
            do {
                let id = try await watch.identify()
                let data = try await watch.read(deviceID: id)
                guard generation == watchGeneration else { return }
                if watchDeviceID != id { clearStagedChanges() }
                watchDeviceID = id
                watchSnapshot = data
                plist = GestaltPlist(dict: try WatchMGWire.decode(data))
                if !selectedWatchTweaks.contains("ultra") { syncWatchUltraFaceClass() }
                isDirty = false
                refreshBackups()
            } catch {
                plist = nil
                watchSnapshot = nil
                report(error)
            }
        }
    }

    private func backupWatch() {
        guard let id = watchDeviceID else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let data = try await watch.read(deviceID: id)
                _ = try GestaltBackupStore.create(from: data, deviceID: id, record: .init(source: .manual, actions: [], changes: []))
                refreshBackups()
                notice = GestaltNotice(kind: .backupCreated, message: String(localized: "Apple Watch backup saved on this iPhone."))
            } catch { report(error) }
        }
    }

    private func saveWatch(_ pending: GestaltPlist, source: GestaltBackupRecord.Source = .modification, actions: [String] = [], completion: (() -> Void)?) {
        guard let id = watchDeviceID, let snapshot = watchSnapshot else {
            report(WatchMGWire.failure(String(localized: "Reload Apple Watch before saving.")))
            return
        }
        isBusy = true
        notice = nil
        let generation = watchGeneration
        Task {
            defer { isBusy = false }
            do {
                let data = try PropertyListSerialization.data(fromPropertyList: pending.dict, format: .binary, options: 0)
                let automaticBackup = try GestaltBackupStore.create(from: snapshot, deviceID: id,
                    record: try .modification(from: snapshot, to: pending.dict, source: source, actions: actions))
                try await watch.write(data, deviceID: id, expectedHash: WatchMGWire.digest(snapshot))
                guard generation == watchGeneration else { return }
                let verified = try await watch.read(deviceID: id)
                guard generation == watchGeneration else { return }
                let dictionary = try WatchMGWire.decode(verified)
                guard NSDictionary(dictionary: dictionary).isEqual(to: pending.dict) else {
                    throw GestAltXError.verificationFailed
                }
                try? GestaltBackupStore.markVerified(automaticBackup)
                plist = GestaltPlist(dict: dictionary)
                watchSnapshot = verified
                isDirty = false
                completion?()
                refreshBackups()
                // Restart only after both helper-side and iPhone-side readback
                // verification succeeds. Keep restart errors separate: the MG
                // write is already committed and must not be marked dirty/retried.
                do {
                    try await watch.restartInterface(deviceID: id)
                    notice = GestaltNotice(kind: .saved, message: String(localized: "Saved to Apple Watch and verified. Automatic watch interface restart requested."))
                } catch {
                    notice = GestaltNotice(kind: .saved, message: String(
                        format: String(localized: "Saved to Apple Watch and verified, but the automatic interface restart could not be confirmed. Restart Apple Watch manually if needed.\n%@"),
                        error.localizedDescription
                    ))
                }
            } catch {
                // A timeout can occur after commit. Force a fresh read before any retry.
                watchSnapshot = nil
                isDirty = true
                refreshBackups()
                report(error)
            }
        }
    }

    private func report(_ error: Error) {
        notice = GestaltNotice(kind: .error, message: error.localizedDescription)
    }
}

private enum GestAltXError: LocalizedError {
    case invalidPlist
    case invalidBackup
    case wrongDeviceBackup
    case missingOriginalIdentityBackup
    case verificationFailed
    case emptyModelName

    var errorDescription: String? {
        switch self {
        case .invalidPlist: String(localized: "The MobileGestalt plist is not a valid dictionary.")
        case .wrongDeviceBackup: String(localized: "This Siri AI identity backup belongs to a different device.")
        case .missingOriginalIdentityBackup: String(localized: "This device is already spoofed, but no original identity backup was found. Restore an original MobileGestalt backup before starting Siri AI setup again.")
        case .invalidBackup: String(localized: "The backup is not a valid MobileGestalt plist.")
        case .verificationFailed: String(localized: "The MobileGestalt values after writing do not match the expected values.")
        case .emptyModelName: String(localized: "The device model name cannot be empty.")
        }
    }
}
