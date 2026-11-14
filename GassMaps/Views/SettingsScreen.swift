import SwiftUI
import StoreKit
import SafariServices
import CoreLocation
import UserNotifications
import MapLibre

// MARK: - Impostazioni (struttura come Google Maps, interfaccia Liquid Glass)

private enum SettingsPage: Hashable {
    case display, navigation, vehicles, privacy, offline, notifications, about, licenses
}

struct SettingsScreen: View {
    @EnvironmentObject var state: AppState
    @State private var path: [SettingsPage] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 12) {
                    entry(.display, "map", "App e display", "Tema, controlli della mappa, accessibilità")
                    entry(.navigation, "location.north", "Navigazione", "In auto, a piedi, con i mezzi di trasporto")
                    entry(.vehicles, "car", "I tuoi veicoli", "Tipo di motore, veicoli connessi")
                    entry(.privacy, "mappin.and.ellipse", "Posizione e privacy", "Spostamenti, Cronologia di GassMaps, profilo")
                    entry(.offline, "icloud.slash", "Mappe offline", "Opzioni di download, aggiornamenti")
                    entry(.notifications, "bell", "Notifiche", "Promemoria, consigli")
                    entry(.about, "checkmark.shield", "Informazioni e termini", nil)
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 40)
            }
            .background(Color(hex: 0x121212).ignoresSafeArea())
            .navigationTitle("Impostazioni")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { state.showSettings = false } label: { Image(systemName: "xmark") }
                }
            }
            .navigationDestination(for: SettingsPage.self) { page in
                switch page {
                case .display: DisplaySettings()
                case .navigation: NavigationSettings()
                case .vehicles: VehicleSettings()
                case .privacy: PrivacySettings()
                case .offline: OfflineSettings()
                case .notifications: NotificationSettings()
                case .about: AboutSettings()
                case .licenses: LicensesPage()
                }
            }
        }
        .tint(.white)
        .preferredColorScheme(.dark)
    }

    /// Dimensioni come nella versione stile Google Maps, con il Liquid Glass su tutta la scheda (icona senza cerchio)
    private func entry(_ page: SettingsPage, _ icon: String, _ title: String, _ subtitle: String?) -> some View {
        NavigationLink(value: page) {
            HStack(spacing: 18) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .regular))
                    .frame(width: 50, height: 50)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 18, weight: .regular))
                    if let subtitle {
                        Text(subtitle).font(.system(size: 15)).foregroundStyle(Color.white.opacity(0.6))
                            .lineLimit(2).multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.85))
            }
            .foregroundStyle(.white)
            .padding(.vertical, 14)
            .padding(.leading, 8)
            .padding(.trailing, 18)
            .frame(maxWidth: .infinity, minHeight: 78)
            .glassRow(cornerRadius: 30)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Componenti delle sotto-schede

/// Pagina di una sotto-scheda: sezioni su vetro, sfondo scuro
private struct SettingsPageView<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) { content }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 40)
        }
        .background(Color(hex: 0x121212).ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SettingsSection<Content: View>: View {
    var title: String?
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.white.opacity(0.6))
                    .padding(.leading, 6)
            }
            VStack(spacing: 0) { content }
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            if let footer {
                Text(footer).font(.system(size: 13)).foregroundStyle(Color.white.opacity(0.45))
                    .padding(.horizontal, 8)
            }
        }
    }
}

/// Riga con icona, titolo, sottotitolo e contenuto a destra
private struct PrefRow<Trailing: View>: View {
    var icon: String?
    var title: String
    var subtitle: String? = nil
    var destructive = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 14) {
            if let icon {
                Image(systemName: icon).font(.system(size: 17, weight: .medium)).frame(width: 26)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16, weight: .medium))
                if let subtitle {
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(Color.white.opacity(0.55))
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .foregroundStyle(destructive ? Color(hex: 0xFF5A5F) : .white)
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }
}

extension PrefRow where Trailing == EmptyView {
    init(icon: String?, title: String, subtitle: String? = nil, destructive: Bool = false) {
        self.init(icon: icon, title: title, subtitle: subtitle, destructive: destructive) { EmptyView() }
    }
}

private struct Chevron: View {
    var body: some View {
        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.white.opacity(0.5))
    }
}

private struct RowDivider: View {
    var body: some View { Divider().overlay(Color.white.opacity(0.08)).padding(.leading, 56) }
}

private struct ToggleRow: View {
    var icon: String
    var title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        PrefRow(icon: icon, title: title, subtitle: subtitle) {
            Toggle("", isOn: $isOn).labelsHidden().tint(Color(hex: 0x2F8CFF))
        }
    }
}

/// Selettore a menu con il valore attuale a destra
private struct PickerRow<T: Hashable>: View {
    var icon: String
    var title: String
    var options: [(T, String)]
    @Binding var selection: T

    var body: some View {
        Menu {
            ForEach(options.indices, id: \.self) { i in
                Button {
                    selection = options[i].0
                } label: {
                    if options[i].0 == selection { Label(options[i].1, systemImage: "checkmark") } else { Text(options[i].1) }
                }
            }
        } label: {
            PrefRow(icon: icon, title: title) {
                HStack(spacing: 4) {
                    Text(options.first(where: { $0.0 == selection })?.1 ?? "")
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold))
                }
                .font(.system(size: 14))
                .foregroundStyle(Color.white.opacity(0.55))
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - App e display

private struct DisplaySettings: View {
    @EnvironmentObject var state: AppState
    @AppStorage(Prefs.showCompass) private var showCompass = true
    @AppStorage(Prefs.showScale) private var showScale = false
    @AppStorage(Prefs.tilt3D) private var tilt3D = true
    @AppStorage(Prefs.haptics) private var haptics = true
    @Environment(\.openURL) private var openURL
    @State private var showIconPicker = false

    var body: some View {
        SettingsPageView(title: "App e display") {
            SettingsSection(title: "Tema") {
                Button {
                    state.showSettings = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { state.showMapSelection = true }
                } label: {
                    PrefRow(icon: "globe.europe.africa", title: "Tema della mappa", subtitle: state.theme.name) { Chevron() }
                }
                .buttonStyle(.plain)
                RowDivider()
                Button { showIconPicker = true } label: {
                    PrefRow(icon: "app.badge", title: "Icona app") { Chevron() }
                }
                .buttonStyle(.plain)
            }
            SettingsSection(title: "Controlli della mappa") {
                PickerRow(icon: "ruler", title: "Unità di distanza",
                          options: DistanceUnit.allCases.map { ($0, $0.title) }, selection: $state.units)
                RowDivider()
                ToggleRow(icon: "location.north.circle", title: "Mostra bussola",
                          subtitle: "Compare quando ruoti la mappa", isOn: $showCompass)
                RowDivider()
                ToggleRow(icon: "ruler.fill", title: "Mostra scala", subtitle: "Barra della scala durante lo zoom", isOn: $showScale)
                RowDivider()
                ToggleRow(icon: "view.3d", title: "Vista inclinata 3D",
                          subtitle: "Inclinazione propria di ogni tema; se disattivata la mappa è vista dall'alto", isOn: $tilt3D)
            }
            SettingsSection(title: "Accessibilità", footer: "Dimensione del testo, contrasto e lettura dello schermo seguono le impostazioni di Accessibilità di iOS.") {
                ToggleRow(icon: "hand.tap", title: "Feedback aptico", subtitle: "Vibrazione leggera ai tocchi sulla mappa", isOn: $haptics)
                RowDivider()
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } label: {
                    PrefRow(icon: "accessibility", title: "Impostazioni di accessibilità") {
                        Image(systemName: "arrow.up.right").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.5))
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $showIconPicker) {
            AppIconPicker().presentationDetents([.medium])
        }
    }
}

// MARK: - Navigazione

private struct NavigationSettings: View {
    @EnvironmentObject var state: AppState
    @AppStorage(Prefs.voiceVolume) private var volume = 0.8
    @AppStorage(Prefs.voiceRate) private var rate = 1.0
    @AppStorage(Prefs.keepAwake) private var keepAwake = true
    @AppStorage(Prefs.showSpeed) private var showSpeed = true
    @AppStorage(Prefs.defaultMode) private var defaultMode = TravelMode.car.rawValue

    var body: some View {
        SettingsPageView(title: "Navigazione") {
            SettingsSection(title: "Guida vocale") {
                ToggleRow(icon: "speaker.wave.2", title: "Indicazioni vocali",
                          isOn: Binding(get: { !state.voiceMuted }, set: { state.voiceMuted = !$0 }))
                RowDivider()
                PickerRow(icon: "speaker.wave.3", title: "Volume della guida",
                          options: [(0.45, "Più basso"), (0.8, "Normale"), (1.0, "Più alto")], selection: $volume)
                RowDivider()
                PickerRow(icon: "metronome", title: "Velocità della voce",
                          options: [(0.85, "Lenta"), (1.0, "Normale"), (1.15, "Veloce")], selection: $rate)
                RowDivider()
                Button { VoiceGuide.shared.speak("Tra 200 metri, svolta a destra.") } label: {
                    PrefRow(icon: "play.circle", title: "Prova la voce")
                }
                .buttonStyle(.plain)
            }
            SettingsSection(title: "In auto") {
                ToggleRow(icon: "road.lanes", title: "Evita autostrade",
                          isOn: Binding(get: { state.routeOptions.avoidHighways }, set: { state.routeOptions.avoidHighways = $0 }))
                RowDivider()
                ToggleRow(icon: "eurosign.circle", title: "Evita pedaggi",
                          isOn: Binding(get: { state.routeOptions.avoidTolls }, set: { state.routeOptions.avoidTolls = $0 }))
                RowDivider()
                ToggleRow(icon: "gauge.with.needle", title: "Tachimetro", subtitle: "Mostra la velocità durante la navigazione", isOn: $showSpeed)
                RowDivider()
                ToggleRow(icon: "sun.max", title: "Mantieni lo schermo acceso", subtitle: "Durante la navigazione", isOn: $keepAwake)
            }
            SettingsSection(title: "A piedi e con i mezzi di trasporto",
                            footer: "Per i mezzi pubblici GassMaps mostra i tempi e apre linee e orari in Mappe di Apple.") {
                PickerRow(icon: "figure.walk", title: "Modalità predefinita",
                          options: TravelMode.allCases.map { ($0.rawValue, $0.title) }, selection: $defaultMode)
            }
        }
    }
}

// MARK: - I tuoi veicoli

private struct VehicleSettings: View {
    @EnvironmentObject var state: AppState
    @AppStorage(Prefs.engine) private var engine = "gas"
    @AppStorage(Prefs.avatar) private var avatar = 0

    private let engines: [(String, String, String)] = [
        ("gas", "Benzina", "fuelpump"), ("diesel", "Diesel", "fuelpump.fill"), ("electric", "Elettrico", "bolt.car"),
        ("hybrid", "Ibrido", "leaf"), ("plugin", "Ibrido plug-in", "powerplug")
    ]

    var body: some View {
        SettingsPageView(title: "I tuoi veicoli") {
            SettingsSection(title: "Tipo di motore",
                            footer: "Con un'auto elettrica o plug-in il pulsante rapido \"Benzina\" diventa \"Ricarica\" e la ricerca lungo il percorso propone le colonnine.") {
                ForEach(engines.indices, id: \.self) { i in
                    if i > 0 { RowDivider() }
                    Button { engine = engines[i].0 } label: {
                        PrefRow(icon: engines[i].2, title: engines[i].1) {
                            if engine == engines[i].0 {
                                Image(systemName: "checkmark").font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(Color(hex: 0x2F8CFF))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            SettingsSection(title: "Avatar di guida",
                            footer: "Indica dove ti trovi sulla mappa. In Pixel Land entrambi gli avatar sono disegnati a blocchi.") {
                avatarRow(0, "Default")
                RowDivider()
                avatarRow(1, "Alternative")
            }
            SettingsSection(title: "Veicoli connessi",
                            footer: "GassMaps non è ancora disponibile su CarPlay: collegando l'iPhone all'auto la guida vocale passa dagli altoparlanti dell'auto tramite Bluetooth.") {
                PrefRow(icon: "carplay", title: "CarPlay", subtitle: "Non disponibile")
            }
        }
    }
}

extension VehicleSettings {
    /// anteprima dell'avatar nello stile del tema attuale
    fileprivate func avatarRow(_ value: Int, _ title: String) -> some View {
        let pixel = state.theme.userMarker == 3
        let kind = value == 1 ? (pixel ? 5 : 4) : (pixel ? 3 : 0)
        return Button { avatar = value } label: {
            HStack(spacing: 16) {
                Group {
                    if kind == 0 {
                        Image(uiImage: UserArrowView.defaultArrowImage(tint: state.theme.arrowColor)).resizable().scaledToFit()
                    } else if let img = UserArrowView.markerImage(kind) {
                        Image(uiImage: img).interpolation(pixel ? .none : .high).resizable().scaledToFit()
                    }
                }
                .frame(width: 44, height: 44)
                Text(title).font(.system(size: 16, weight: .medium)).foregroundStyle(.white)
                Spacer()
                if avatar == value {
                    Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Color(hex: 0x2F8CFF))
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Anteprima della freccia standard (due metà, lato destro più scuro)
private struct DefaultArrowPreview: View {
    var color: Color
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            var l = Path(); l.move(to: CGPoint(x: w / 2, y: h * 0.07)); l.addLine(to: CGPoint(x: w * 0.18, y: h * 0.9))
            l.addLine(to: CGPoint(x: w / 2, y: h * 0.7)); l.closeSubpath()
            var r = Path(); r.move(to: CGPoint(x: w / 2, y: h * 0.07)); r.addLine(to: CGPoint(x: w * 0.82, y: h * 0.9))
            r.addLine(to: CGPoint(x: w / 2, y: h * 0.7)); r.closeSubpath()
            ctx.fill(l, with: .color(color))
            ctx.fill(r, with: .color(color.opacity(0.75)))
        }
        .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
    }
}

// MARK: - Posizione e privacy

private struct PrivacySettings: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var location: LocationManager
    @AppStorage(Prefs.saveHistory) private var saveHistory = true
    @Environment(\.openURL) private var openURL
    @State private var showDeleteConfirm = false

    private var authText: String {
        switch location.authorization {
        case .authorizedAlways: return "Sempre"
        case .authorizedWhenInUse: return "Mentre usi l'app"
        case .denied: return "Negata"
        case .restricted: return "Limitata"
        default: return "Non ancora richiesta"
        }
    }

    var body: some View {
        SettingsPageView(title: "Posizione e privacy") {
            SettingsSection(title: "Posizione",
                            footer: "La posizione resta sul tuo iPhone: GassMaps la usa per la mappa, i percorsi e le ricerche vicine.") {
                PrefRow(icon: "location", title: "Accesso alla posizione", subtitle: authText) {
                    if location.accuracy > 0 {
                        Text("±\(Int(location.accuracy)) m").font(.system(size: 14)).foregroundStyle(Color.white.opacity(0.55))
                    }
                }
                RowDivider()
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } label: {
                    PrefRow(icon: "gearshape", title: "Impostazioni di localizzazione di iOS") {
                        Image(systemName: "arrow.up.right").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.5))
                    }
                }
                .buttonStyle(.plain)
            }
            SettingsSection(title: "Spostamenti") {
                PrefRow(icon: "figure.walk.motion", title: "Luoghi esplorati", subtitle: "\(state.explored.count) luoghi raggiunti") {
                    if !state.explored.isEmpty {
                        Button("Azzera") { state.explored = [] }.font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color(hex: 0xFF5A5F))
                    }
                }
                RowDivider()
                PrefRow(icon: "car", title: "Parcheggio salvato", subtitle: state.parking?.address ?? "Nessuno") {
                    if state.parking != nil {
                        Button("Rimuovi") { state.parking = nil }.font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color(hex: 0xFF5A5F))
                    }
                }
            }
            SettingsSection(title: "Cronologia di GassMaps") {
                ToggleRow(icon: "clock.arrow.circlepath", title: "Salva la cronologia delle ricerche", isOn: $saveHistory)
                RowDivider()
                PrefRow(icon: "clock", title: "Ricerche recenti", subtitle: "\(state.history.count) elementi") {
                    if !state.history.isEmpty {
                        Button("Elimina") { state.history = [] }.font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color(hex: 0xFF5A5F))
                    }
                }
            }
            SettingsSection(title: "Profilo") {
                profileRow("house", "Casa", state.home) { state.home = nil }
                RowDivider()
                profileRow("briefcase", "Lavoro", state.work) { state.work = nil }
                RowDivider()
                PrefRow(icon: "bookmark", title: "Posizioni salvate", subtitle: "\(state.saved.count) luoghi")
            }
            SettingsSection(title: nil) {
                Button { showDeleteConfirm = true } label: {
                    PrefRow(icon: "trash.fill", title: "Cancella i miei dati", destructive: true)
                }
                .buttonStyle(.plain)
            }
        }
        .confirmationDialog("Cancellare tutti i tuoi dati?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Cancella i miei dati", role: .destructive) { state.deleteAllData() }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Posizioni salvate, cronologia e luoghi esplorati verranno eliminati.")
        }
    }

    private func profileRow(_ icon: String, _ title: String, _ place: Place?, remove: @escaping () -> Void) -> some View {
        PrefRow(icon: icon, title: title, subtitle: place?.address ?? "Imposta dal menu ••• di un luogo") {
            if place != nil {
                Button("Rimuovi", action: remove).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xFF5A5F))
            }
        }
    }
}

// MARK: - Mappe offline

private struct OfflineSettings: View {
    @EnvironmentObject var state: AppState
    @StateObject private var offline = OfflineMaps.shared
    @State private var cacheCleared = false

    var body: some View {
        SettingsPageView(title: "Mappe offline") {
            SettingsSection(title: "Le tue mappe offline",
                            footer: "Scarica la zona visibile sulla mappa con il tema attuale (\(state.theme.name)) per vederla senza connessione. Ricerca e percorsi richiedono comunque internet.") {
                Button {
                    offline.downloadVisibleArea(state: state)
                } label: {
                    PrefRow(icon: "arrow.down.circle", title: "Scarica la zona visibile",
                            subtitle: "Livelli di dettaglio fino alle strade e agli edifici")
                }
                .buttonStyle(.plain)
                ForEach(offline.items) { item in
                    RowDivider()
                    PrefRow(icon: item.complete ? "checkmark.circle.fill" : "icloud.and.arrow.down",
                            title: item.name, subtitle: item.detail) {
                        Button { offline.remove(item) } label: {
                            Image(systemName: "trash").font(.system(size: 15)).foregroundStyle(Color(hex: 0xFF5A5F))
                        }
                    }
                }
            }
            if let error = offline.error {
                Text(error).font(.system(size: 13)).foregroundStyle(Color(hex: 0xFF5A5F)).padding(.horizontal, 8)
            }
            SettingsSection(title: "Aggiornamenti",
                            footer: "Le mappe già viste restano in memoria per un caricamento più rapido; svuotala per liberare spazio.") {
                Button {
                    offline.refreshAll()
                } label: {
                    PrefRow(icon: "arrow.triangle.2.circlepath", title: "Aggiorna le mappe offline")
                }
                .buttonStyle(.plain)
                RowDivider()
                Button {
                    MLNOfflineStorage.shared.clearAmbientCache { _ in
                        DispatchQueue.main.async { cacheCleared = true }
                    }
                } label: {
                    PrefRow(icon: "internaldrive", title: "Svuota la cache delle mappe",
                            subtitle: cacheCleared ? "Cache svuotata" : nil)
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear { offline.reload() }
    }
}

/// Gestione delle mappe scaricate (MapLibre offline packs)
final class OfflineMaps: ObservableObject {
    static let shared = OfflineMaps()

    struct Item: Identifiable {
        let id: ObjectIdentifier
        let pack: MLNOfflinePack
        let name: String
        let detail: String
        let complete: Bool
    }

    @Published var items: [Item] = []
    @Published var error: String?

    private init() {
        NotificationCenter.default.addObserver(forName: .MLNOfflinePackProgressChanged, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }
        NotificationCenter.default.addObserver(forName: .MLNOfflinePackError, object: nil, queue: .main) { [weak self] _ in
            self?.error = "Download non riuscito: riprova con una connessione stabile."
            self?.reload()
        }
    }

    func reload() {
        let packs = MLNOfflineStorage.shared.packs ?? []
        items = packs.map { pack in
            let info = (try? JSONSerialization.jsonObject(with: pack.context)) as? [String: String] ?? [:]
            let p = pack.progress
            let done = p.countOfResourcesExpected > 0 && p.countOfResourcesCompleted >= p.countOfResourcesExpected
            let mb = Double(p.countOfBytesCompleted) / 1_048_576
            let detail: String
            if done {
                detail = String(format: "%.1f MB · %@", mb, info["date"] ?? "")
            } else if p.countOfResourcesExpected > 0 {
                let pct = Int(Double(p.countOfResourcesCompleted) / Double(p.countOfResourcesExpected) * 100)
                detail = "Download \(pct)% · " + String(format: "%.1f MB", mb)
            } else {
                detail = "In attesa…"
            }
            return Item(id: ObjectIdentifier(pack), pack: pack, name: info["name"] ?? "Zona scaricata",
                        detail: detail, complete: done)
        }
    }

    func downloadVisibleArea(state: AppState) {
        guard let map = state.map.mapView else { return }
        error = nil
        let bounds = map.visibleCoordinateBounds
        let fromZoom = max(0, floor(map.zoomLevel) - 2)
        let region = MLNTilePyramidOfflineRegion(styleURL: state.theme.styleURL, bounds: bounds,
                                                 fromZoomLevel: fromZoom, toZoomLevel: min(16, max(fromZoom, map.zoomLevel + 2)))
        let name = "\(location(state)) · \(state.theme.name)"
        let date = Formatters.time.string(from: Date())
        let context = (try? JSONSerialization.data(withJSONObject: ["name": name, "date": "scaricata alle " + date])) ?? Data()
        MLNOfflineStorage.shared.addPack(for: region, withContext: context) { [weak self] pack, err in
            DispatchQueue.main.async {
                if err != nil || pack == nil {
                    self?.error = "Impossibile avviare il download."
                } else {
                    pack?.resume()
                }
                self?.reload()
            }
        }
    }

    private func location(_ state: AppState) -> String {
        let name = state.location.placeName
        return name.hasPrefix("Ricerca") ? "Zona" : name
    }

    func refreshAll() {
        for item in items { item.pack.resume() }
        reload()
    }

    func remove(_ item: Item) {
        MLNOfflineStorage.shared.removePack(item.pack) { [weak self] _ in
            DispatchQueue.main.async { self?.reload() }
        }
    }
}

// MARK: - Notifiche

private struct NotificationSettings: View {
    @AppStorage(Prefs.parkingReminder) private var parkingReminder = false
    @AppStorage(Prefs.parkingHours) private var parkingHours = 2
    @AppStorage(Prefs.tips) private var tips = false
    @State private var status: UNAuthorizationStatus = .notDetermined
    @Environment(\.openURL) private var openURL

    var body: some View {
        SettingsPageView(title: "Notifiche") {
            if status == .denied {
                SettingsSection(title: nil) {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    } label: {
                        PrefRow(icon: "bell.slash", title: "Notifiche disattivate", subtitle: "Attivale nelle Impostazioni di iOS") {
                            Image(systemName: "arrow.up.right").font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.5))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            SettingsSection(title: "Promemoria") {
                ToggleRow(icon: "parkingsign.circle", title: "Promemoria parcheggio",
                          subtitle: "Avviso dopo aver salvato dove hai lasciato l'auto",
                          isOn: Binding(get: { parkingReminder }, set: { on in
                              parkingReminder = on
                              if on { Notifier.requestPermission { refresh() } }
                          }))
                if parkingReminder {
                    RowDivider()
                    PickerRow(icon: "timer", title: "Avvisami dopo",
                              options: [(1, "1 ora"), (2, "2 ore"), (3, "3 ore"), (4, "4 ore"), (8, "8 ore")],
                              selection: $parkingHours)
                }
            }
            SettingsSection(title: "Consigli", footer: "Un suggerimento a settimana per esplorare un posto nuovo con il tuo tema.") {
                ToggleRow(icon: "lightbulb", title: "Consigli per esplorare",
                          isOn: Binding(get: { tips }, set: { on in
                              tips = on
                              if on { Notifier.requestPermission { Notifier.scheduleTips(); refresh() } }
                              else { Notifier.cancelTips() }
                          }))
            }
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            DispatchQueue.main.async { status = s.authorizationStatus }
        }
    }
}

/// Notifiche locali (promemoria parcheggio, consigli settimanali)
enum Notifier {
    static func requestPermission(_ done: @escaping () -> Void = {}) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
            DispatchQueue.main.async { done() }
        }
    }

    static func scheduleParkingReminder() {
        let d = UserDefaults.standard
        guard d.bool(forKey: Prefs.parkingReminder) else { return }
        let hours = max(1, d.integer(forKey: Prefs.parkingHours))
        let content = UNMutableNotificationContent()
        content.title = "La tua auto"
        content.body = "Sono passate \(hours) or\(hours == 1 ? "a" : "e") da quando hai parcheggiato. Apri GassMaps per tornare all'auto."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(hours * 3600), repeats: false)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["gm.parking"])
        center.add(UNNotificationRequest(identifier: "gm.parking", content: content, trigger: trigger))
    }

    static func cancelParkingReminder() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["gm.parking"])
    }

    static func scheduleTips() {
        let content = UNMutableNotificationContent()
        content.title = "Esplora qualcosa di nuovo"
        content.body = "C'è un posto vicino a te che nessuno ha ancora esplorato. Aprilo in GassMaps!"
        content.sound = .default
        var date = DateComponents()
        date.weekday = 7
        date.hour = 11
        let trigger = UNCalendarNotificationTrigger(dateMatching: date, repeats: true)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "gm.tips", content: content, trigger: trigger))
    }

    static func cancelTips() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["gm.tips"])
    }
}

// MARK: - Informazioni e termini

private struct AboutSettings: View {
    @Environment(\.requestReview) private var requestReview
    @Environment(\.openURL) private var openURL
    @State private var safariURL: URL?
    @State private var restoreMessage: String?

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        SettingsPageView(title: "Informazioni e termini") {
            SettingsSection(title: nil) {
                PrefRow(icon: "info.circle", title: "Versione") {
                    Text(version).font(.system(size: 14)).foregroundStyle(Color.white.opacity(0.55))
                }
                RowDivider()
                Button { safariURL = AppConfig.termsURL } label: {
                    PrefRow(icon: "doc.text", title: "Termini di servizio") { Chevron() }
                }
                .buttonStyle(.plain)
                RowDivider()
                Button { safariURL = AppConfig.privacyURL } label: {
                    PrefRow(icon: "checkmark.shield", title: "Informativa sulla privacy") { Chevron() }
                }
                .buttonStyle(.plain)
                RowDivider()
                NavigationLink(value: SettingsPage.licenses) {
                    PrefRow(icon: "text.book.closed", title: "Note legali e dati della mappa") { Chevron() }
                }
                .buttonStyle(.plain)
            }
            SettingsSection(title: "GassMaps") {
                Button { requestReview() } label: {
                    PrefRow(icon: "star", title: "Valuta l'app")
                }
                .buttonStyle(.plain)
                RowDivider()
                ShareLink(item: AppConfig.shareURL, message: Text(AppConfig.shareText)) {
                    PrefRow(icon: "square.and.arrow.up", title: "Condividi")
                }
                .buttonStyle(.plain)
                RowDivider()
                Button { openURL(AppConfig.discordURL) } label: {
                    PrefRow(icon: "gamecontroller", title: "Unisciti alla community Discord")
                }
                .buttonStyle(.plain)
                RowDivider()
                Button {
                    if let url = URL(string: "mailto:\(AppConfig.contactEmail)") { openURL(url) }
                } label: {
                    PrefRow(icon: "envelope", title: "Contattaci")
                }
                .buttonStyle(.plain)
                RowDivider()
                Button { restorePurchases() } label: {
                    PrefRow(icon: "clock.arrow.circlepath", title: "Ripristina acquisti")
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(item: Binding(get: { safariURL.map(IdentifiableURL.init) },
                             set: { safariURL = $0?.url })) { item in
            SafariView(url: item.url).ignoresSafeArea()
        }
        .alert("Ripristina acquisti", isPresented: Binding(get: { restoreMessage != nil },
                                                          set: { if !$0 { restoreMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(restoreMessage ?? "")
        }
    }

    private func restorePurchases() {
        Task {
            do {
                try await AppStore.sync()
                await MainActor.run { restoreMessage = "Acquisti ripristinati." }
            } catch {
                await MainActor.run { restoreMessage = "Nessun acquisto da ripristinare." }
            }
        }
    }
}

private struct LicensesPage: View {
    var body: some View {
        SettingsPageView(title: "Note legali") {
            SettingsSection(title: "Dati della mappa") {
                PrefRow(icon: nil, title: "© OpenStreetMap contributors", subtitle: "Dati cartografici, licenza ODbL")
                RowDivider()
                PrefRow(icon: nil, title: "OpenFreeMap", subtitle: "Tile vettoriali gratuiti")
                RowDivider()
                PrefRow(icon: nil, title: "Esri World Imagery", subtitle: "Immagini satellitari del tema Street Heat © Esri, Maxar, Earthstar Geographics")
            }
            SettingsSection(title: "Software") {
                PrefRow(icon: nil, title: "MapLibre Native", subtitle: "Rendering della mappa, licenza BSD-2-Clause")
                RowDivider()
                PrefRow(icon: nil, title: "Apple MapKit", subtitle: "Ricerca, indirizzi e percorsi")
            }
        }
    }
}

// MARK: - Preferenze condivise

enum Prefs {
    static let showCompass = "gm.showCompass"
    static let showScale = "gm.showScale"
    static let tilt3D = "gm.tilt3D"
    static let haptics = "gm.haptics"
    static let voiceVolume = "gm.voiceVolume"
    static let voiceRate = "gm.voiceRate"
    static let keepAwake = "gm.keepAwake"
    static let showSpeed = "gm.showSpeed"
    static let defaultMode = "gm.defaultMode"
    static let engine = "gm.engine"
    static let saveHistory = "gm.saveHistory"
    static let parkingReminder = "gm.parkingReminder"
    static let parkingHours = "gm.parkingHours"
    static let tips = "gm.tips"
    static let avatar = "gm.avatar"
    static let layerSatellite = "gm.layer.satellite"
    static let layerTransit = "gm.layer.transit"
    static let layerBike = "gm.layer.bike"

    private static var d: UserDefaults { .standard }
    static func bool(_ key: String, default value: Bool) -> Bool { d.object(forKey: key) == nil ? value : d.bool(forKey: key) }
    static func double(_ key: String, default value: Double) -> Double { d.object(forKey: key) == nil ? value : d.double(forKey: key) }
    static var isElectric: Bool { ["electric", "plugin"].contains(d.string(forKey: engine) ?? "gas") }
}

struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct SettingsRow<Trailing: View>: View {
    var icon: AnyView
    var title: String
    var destructive: Bool = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 14) {
            icon
                .font(.system(size: 19, weight: .semibold))
                .frame(width: 26)
            Text(title)
                .font(.system(size: 17, weight: .medium))
            Spacer()
            trailing
        }
        .foregroundStyle(destructive ? Color(hex: 0xFF3B4E) : .white)
        .padding(.horizontal, 18)
        .frame(height: 60)
        .glassRow(cornerRadius: 30, tint: destructive ? Color(hex: 0xFF3B4E).opacity(0.22) : nil)
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(icon: AnyView, title: String, destructive: Bool = false) {
        self.init(icon: icon, title: title, destructive: destructive) { EmptyView() }
    }
}

struct AppIconGlyph: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white).frame(width: 20, height: 20)
            Circle().strokeBorder(Color.black, lineWidth: 2.5).frame(width: 10, height: 10)
        }
    }
}

struct ShareNodesGlyph: View {
    var body: some View {
        Canvas { ctx, size in
            let a = CGPoint(x: size.width * 0.22, y: size.height * 0.5)
            let b = CGPoint(x: size.width * 0.78, y: size.height * 0.2)
            let c = CGPoint(x: size.width * 0.78, y: size.height * 0.8)
            var p = Path()
            p.move(to: b); p.addLine(to: a); p.addLine(to: c)
            ctx.stroke(p, with: .foreground, lineWidth: 2.2)
            for pt in [a, b, c] {
                ctx.fill(Path(ellipseIn: CGRect(x: pt.x - 4, y: pt.y - 4, width: 8, height: 8)), with: .foreground)
            }
        }
        .frame(width: 22, height: 22)
    }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}

struct AppIconPicker: View {
    @Environment(\.dismiss) private var dismiss
    @State private var current: String? = UIApplication.shared.alternateIconName

    private struct IconOption: Identifiable {
        let name: String?
        let preview: String
        let title: String
        var id: String { preview }
    }

    private let options: [IconOption] = [
        IconOption(name: nil, preview: "IconPreviewDefault", title: "Classica"),
        IconOption(name: "AppIconLight", preview: "IconPreviewLight", title: "Chiara"),
        IconOption(name: "AppIconNeon", preview: "IconPreviewNeon", title: "Neon")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Icona app")
                .font(.system(size: 24, weight: .heavy))
                .foregroundStyle(.white)
                .padding(.top, 24)
            HStack(spacing: 18) {
                ForEach(options) { option in
                    Button {
                        UIApplication.shared.setAlternateIconName(option.name) { _ in
                            DispatchQueue.main.async {
                                current = UIApplication.shared.alternateIconName
                            }
                        }
                    } label: {
                        VStack(spacing: 8) {
                            Image(option.preview)
                                .resizable()
                                .frame(width: 84, height: 84)
                                .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 19, style: .continuous)
                                        .strokeBorder(current == option.name ? Color.white : Color.white.opacity(0.1),
                                                      lineWidth: current == option.name ? 3 : 1)
                                )
                            Text(option.title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity)
            Spacer()
        }
        .padding(.horizontal, 20)
    }
}
