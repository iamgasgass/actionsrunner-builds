import SwiftUI
import MapKit

struct SearchScreen: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var location: LocationManager
    @StateObject private var search = SearchService()
    @StateObject private var voice = VoiceSearch()
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // barra di ricerca
            GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    TextField("", text: $search.query, prompt: Text(placeholder).foregroundColor(Color.white.opacity(0.4)))
                        .font(.system(size: 17))
                        .foregroundStyle(.white)
                        .tint(Color(hex: 0x2F8CFF))
                        .focused($focused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                        .onSubmit { submit() }
                    if search.query.isEmpty {
                        // ricerca vocale (come il microfono di Google Maps)
                        Button {
                            if voice.isListening { voice.stop() } else {
                                focused = false
                                voice.start { text in
                                    search.query = text
                                    submit()
                                }
                            }
                        } label: {
                            Image(systemName: voice.isListening ? "waveform" : "mic.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(voice.isListening ? Color(hex: 0x2F8CFF) : Color.white.opacity(0.7))
                                .symbolEffect(.variableColor.iterative, isActive: voice.isListening)
                        }
                        .buttonStyle(.plain)
                    }
                    if !search.query.isEmpty {
                        Button { search.query = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Color.white.opacity(0.45))
                        }
                    }
                }
                .padding(.horizontal, 18)
                .frame(height: 50)
                .glassEffect(.regular.interactive(), in: Capsule())

                Button {
                    focused = false
                    state.searchPurpose = .destination
                    state.showSearch = false
                } label: {
                    GlassCircle(size: 50) {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
            }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, state.searchPurpose == .destination ? 18 : 8)

            if state.searchPurpose != .destination {
                VStack(alignment: .leading, spacing: 10) {
                    Text(state.searchPurpose == .origin ? "Scegli il punto di partenza" : "Aggiungi una tappa")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.6))
                    if state.searchPurpose == .origin, location.location != nil {
                        Button {
                            focused = false
                            state.searchPurpose = .destination
                            state.origin = nil
                            state.showSearch = false
                            state.requestDirections()
                        } label: {
                            ResultRow(title: "La tua posizione", subtitle: "Posizione in tempo reale")
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }

            if voice.isListening || voice.error != nil {
                HStack(spacing: 10) {
                    Image(systemName: voice.error == nil ? "mic.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(voice.error == nil ? Color(hex: 0x2F8CFF) : Color(hex: 0xFF5A5F))
                    Text(voice.error ?? (voice.transcript.isEmpty ? "Ti ascolto…" : voice.transcript))
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18).frame(minHeight: 54)
                .glassRow(cornerRadius: 26)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !search.query.isEmpty {
                        resultsList
                    } else if let category = search.activeCategory {
                        categoryList(category)
                    } else {
                        historySection
                        nearbySection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Color.black.ignoresSafeArea())
        .onDisappear { voice.stop(deliver: false) }
        .onAppear {
            // zona di ricerca: posizione attuale, altrimenti il centro della mappa
            search.userLocation = location.location
            // zona di ricerca: l'area visibile sulla mappa (come Google Maps), altrimenti la posizione
            if let r = state.map.visibleRegion, r.span.latitudeDelta < 3 {
                search.region = MKCoordinateRegion(center: r.center,
                                                   span: MKCoordinateSpan(latitudeDelta: max(r.span.latitudeDelta, 0.05),
                                                                          longitudeDelta: max(r.span.longitudeDelta, 0.05)))
            } else if let c = location.location?.coordinate ?? state.map.centerCoordinate {
                search.region = MKCoordinateRegion(center: c, latitudinalMeters: 40_000, longitudinalMeters: 40_000)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { focused = true }
        }
    }

    /// Invio: un risultato → scheda del luogo, più risultati → elenco sulla mappa (come Google Maps)
    private func submit() {
        let q = search.query
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        search.searchAll { items in
            if state.searchPurpose != .destination, let item = items.first {
                state.select(mapItem: item)
            } else if items.count == 1, let item = items.first {
                state.select(mapItem: item)
            } else if !items.isEmpty {
                state.showResults(items, title: q)
            }
        }
    }

    private var placeholder: String {
        switch state.searchPurpose {
        case .origin: return "Partenza"
        case .stop: return "Aggiungi tappa"
        case .destination: return "Cerca"
        }
    }

    // MARK: Sezioni

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                shortcut("Casa", "house.fill", state.home)
                shortcut("Lavoro", "briefcase.fill", state.work)
            }
            .padding(.bottom, 10)
            if !state.history.isEmpty {
                HStack {
                    Text("Cronologia")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.white)
                    Spacer()
                    Button("Cancella") { state.history = [] }
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Color(hex: 0xFF3B4E))
                }
                ForEach(state.history) { place in
                    Button {
                        focused = false
                        state.addToHistory(place)
                        state.choose(place)
                    } label: {
                        ResultRow(title: place.name, subtitle: place.address)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.bottom, 22)
    }

    private func shortcut(_ title: String, _ icon: String, _ place: Place?) -> some View {
        Button {
            guard let p = place else { return }
            focused = false
            if state.searchPurpose == .destination { state.go(to: p) } else { state.choose(p) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 16, weight: .bold))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 15, weight: .bold))
                    Text(place?.address ?? "Imposta dal menu ••• di un luogo")
                        .font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.5)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).frame(height: 56)
            .frame(maxWidth: .infinity)
            .glassRow(cornerRadius: 20)
        }
        .buttonStyle(.plain)
        .opacity(place == nil ? 0.6 : 1)
    }

    private var nearbySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trova nelle vicinanze")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white)
            VStack(spacing: 0) {
                ForEach(SearchService.nearbyCategories, id: \.self) { category in
                    Button {
                        focused = false
                        state.searchCategory(category)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white)
                            Text(category)
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(.white)
                            Spacer()
                        }
                        .padding(.horizontal, 18)
                        .frame(height: 58)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
    }

    private var resultsList: some View {
        VStack(spacing: 10) {
            ForEach(Array(search.completions.enumerated()), id: \.offset) { _, completion in
                Button {
                    focused = false
                    // le ricerche generiche ("pizzeria") aprono l'elenco, gli indirizzi la scheda del luogo
                    search.resolveAll(completion) { items, isQuery in
                        if isQuery && items.count > 1 && state.searchPurpose == .destination {
                            state.showResults(items, title: completion.title)
                        } else if let item = items.first {
                            state.select(mapItem: item)
                        }
                    }
                } label: {
                    ResultRow(title: completion.title, subtitle: completion.subtitle)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func categoryList(_ category: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    search.activeCategory = nil
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left").font(.system(size: 15, weight: .bold))
                        Text(category).font(.system(size: 17, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                }
                Spacer()
            }
            .padding(.bottom, 4)

            if search.isSearching {
                ProgressView().tint(.white).frame(maxWidth: .infinity).padding(.top, 30)
            } else if search.categoryResults.isEmpty {
                Text("Nessun risultato nelle vicinanze")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .padding(.top, 20)
            } else {
                ForEach(Array(search.categoryResults.enumerated()), id: \.offset) { _, item in
                    Button { state.select(mapItem: item) } label: {
                        ResultRow(title: item.name ?? category,
                                  subtitle: distanceText(item) + Place.formatShort(item.placemark))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func distanceText(_ item: MKMapItem) -> String {
        guard let loc = location.location, let itemLoc = item.placemark.location else { return "" }
        return "\(state.units.value(loc.distance(from: itemLoc))) \(state.units.shortLabel) • "
    }
}

struct ResultRow: View {
    var title: String
    var subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Image(systemName: "drop.fill")
                    .font(.system(size: 22))
                    .rotationEffect(.degrees(180))
                    .foregroundStyle(LinearGradient(colors: [Color(hex: 0x4FA3FF), Color(hex: 0x1D6BFF)],
                                                    startPoint: .top, endPoint: .bottom))
                Circle().fill(Color(hex: 0x0A1E3D)).frame(width: 7, height: 7).offset(y: -2)
            }
            .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title.isEmpty ? "Posizione" : title)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.white.opacity(0.4))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
        .glassRow(cornerRadius: 26)
    }
}
