import SwiftUI

struct MainMapScreen: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var location: LocationManager
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(Prefs.showCompass) private var showCompass = true

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let sideW = MapController.sidePanelWidth(for: geo.size.width + geo.safeAreaInsets.leading + geo.safeAreaInsets.trailing)
            ZStack {
                GameMapView(state: state)
                    .ignoresSafeArea()

                // vignettatura del tema (bordi scuri come nelle schermate di riferimento)
                // (solo in verticale: in orizzontale il gradiente, calcolato su larghezza e altezza invertite,
                //  diventava un'ombra scura al centro)
                if state.theme.vignette > 0 && !landscape {
                    RadialGradient(colors: [.clear, .black.opacity(state.theme.vignette)],
                                   center: .center, startRadius: geo.size.width * 0.42,
                                   endRadius: geo.size.height * 0.62)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }

                // sfocatura superiore solo mentre l'intestazione d'avvio mostra giorno, ora e posizione
                if state.showHeader && state.panel != .navigating {
                    // in modalità scura: materiale scuro più denso + velatura nera, sfocatura ben visibile
                    ZStack {
                        Rectangle()
                            .fill(colorScheme == .dark ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.ultraThinMaterial))
                        if colorScheme == .dark {
                            Rectangle().fill(Color.black.opacity(0.32))
                        }
                    }
                    .environment(\.colorScheme, colorScheme)
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                                 .init(color: .black, location: 0.6),
                                                 .init(color: .clear, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
                        .frame(height: geo.safeAreaInsets.top + (colorScheme == .dark ? 200 : 170))
                        .frame(maxHeight: .infinity, alignment: .top)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                VStack(spacing: 0) {
                    ZStack {
                        if state.panel == .navigating {
                            NavigationBanner()
                                .frame(width: landscape ? sideW : nil)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        } else if state.showHeader {
                            HeaderView()
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        } else if state.panel != .directions {
                            VStack(spacing: 10) {
                                TopBar()
                                    .frame(width: landscape ? sideW : nil)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if (state.panel == .none || state.panel == .results) && !state.measuring {
                                    CategoryChips()
                                        .frame(width: landscape ? sideW : nil)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                if state.showSearchArea && state.panel == .results {
                                    Button { state.searchThisArea() } label: {
                                        Label("Cerca in questa zona", systemImage: "arrow.clockwise")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 16).frame(height: 38)
                                            .glassEffect(.regular.tint(Color(state.theme.accent).opacity(0.75)).interactive(),
                                                         in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .transition(.scale.combined(with: .opacity))
                                }
                                HStack(alignment: .top) {
                                    Spacer()
                                    VStack(spacing: 10) {
                                        // Livelli (come Google Maps)
                                        if (state.panel == .none || state.panel == .results) && !state.measuring {
                                            Button { state.showLayers = true } label: {
                                                GlassCircle(size: 44) {
                                                    Image(systemName: "square.3.layers.3d")
                                                        .font(.system(size: 17, weight: .semibold))
                                                        .foregroundStyle(.white)
                                                }
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        // bussola sempre visibile sotto il pulsante Livelli
                                        if showCompass {
                                            CompassButton()
                                        }
                                    }
                                    .padding(.trailing, 18)
                                }
                                .offset(y: landscape ? -(44 + 10 + ((state.panel == .none || state.panel == .results) && !state.measuring ? 46 : 0)) : 0)
                            }
                            .transition(.opacity)
                        }
                    }
                    .padding(.top, 8)
                    Spacer()
                }

                // controlli inferiori
                VStack {
                    Spacer()
                    if state.measuring {
                        MeasureBar()
                            .frame(width: landscape ? sideW : nil)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.bottom, max(geo.safeAreaInsets.bottom, 12) + 8)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else if state.panel == .none {
                        BottomControls()
                            .frame(maxWidth: .infinity, alignment: landscape ? .trailing : .center)
                            .padding(.trailing, landscape ? 18 : 0)
                            .padding(.bottom, max(geo.safeAreaInsets.bottom, 12) + 8)
                            .transition(.opacity)
                    }
                }

                // navigazione in orizzontale: pulsanti sul bordo destro, in basso, come Google Maps
                if landscape && state.panel == .navigating {
                    VStack {
                        Spacer()
                        NavigationSideButtons()
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 18)
                    .padding(.bottom, max(geo.safeAreaInsets.bottom, 12) + 8)
                    .transition(.opacity)
                }

                // mirino al centro per la misura della distanza
                if state.measuring {
                    MeasureCrosshair()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }

                // pannelli
                VStack {
                    Spacer()
                    if landscape {
                        // se il pannello è più alto dello schermo diventa scorrevole
                        ViewThatFits(in: .vertical) {
                            panel
                            ScrollView(.vertical, showsIndicators: false) { panel }
                                .defaultScrollAnchor(.bottom)
                        }
                        .frame(width: sideW)
                        .frame(maxHeight: geo.size.height + geo.safeAreaInsets.bottom - 4, alignment: .bottom)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        panel
                    }
                }
                .ignoresSafeArea(edges: .bottom)
            }
            .environment(\.isLandscapeLayout, landscape)
            .onChange(of: landscape) { _, _ in
                // dopo la rotazione si riapplicano i margini della mappa per il nuovo orientamento
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    state.map.orientationChanged(navigating: state.panel == .navigating)
                }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.88), value: state.panel)
        .animation(.easeInOut(duration: 0.2), value: abs(state.mapHeading) > 2)
        .sheet(isPresented: $state.showSteps) {
            StepsSheet()
                .environmentObject(state)
        }
        .sheet(isPresented: $state.showAlongRoute) {
            AlongRouteSheet()
                .environmentObject(state)
        }
        .sheet(isPresented: $state.showLayers) {
            LayersSheet()
                .environmentObject(state)
                .presentationDetents([.height(330)])
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: state.measuring)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: state.tracking)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: state.showSearchArea)
        .animation(.easeInOut(duration: 0.3), value: state.isLoadingRoute)
        .alert("Indicazioni", isPresented: Binding(get: { state.routeError != nil },
                                                   set: { if !$0 { state.routeError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(state.routeError ?? "")
        }
    }

    @ViewBuilder
    private var panel: some View {
        switch state.panel {
        case .pinned:
            PinnedPlacePanel().transition(.move(edge: .bottom))
        case .directions:
            DirectionsPanel().transition(.move(edge: .bottom))
        case .navigating:
            NavigationPanel().transition(.move(edge: .bottom))
        case .saved:
            SavedPlacesPanel().transition(.move(edge: .bottom))
        case .results:
            ResultsPanel().transition(.move(edge: .bottom))
        case .myLocation:
            MyLocationPanel().transition(.move(edge: .bottom))
        case .none:
            EmptyView()
        }
    }
}

struct HeaderView: View {
    @EnvironmentObject var location: LocationManager
    @State private var now = Date()

    var body: some View {
        VStack(spacing: 2) {
            Text(Formatters.dayTime.string(from: now))
                .font(.system(size: 17, weight: .bold))
            Text(location.placeName)
                .font(.system(size: 34, weight: .heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.8), radius: 8, y: 2)
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .onAppear { now = Date() }
    }
}

struct TopBar: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var location: LocationManager

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 10) {
                Button { state.showMapSelection = true } label: {
                    GlassCircle(size: 44) {
                        Image(systemName: "globe.europe.africa.fill")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                Button { state.showSearch = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                        Text(location.placeName)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.75))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .frame(maxWidth: 250)
                    .contentShape(Capsule())
                    .glassEffect(.regular.interactive(), in: Capsule())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                Button { state.showSettings = true } label: {
                    GlassCircle(size: 44) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
    }
}

struct BottomControls: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var location: LocationManager

    private var locationDenied: Bool {
        location.authorization == .denied || location.authorization == .restricted
    }

    /// Icona come Google Maps: freccia vuota se la mappa non ti segue, piena (blu) se ti segue, bussola in modalità bussola
    private var locationIcon: String {
        if locationDenied { return "location.slash" }
        switch state.tracking {
        case .none: return "location"
        case .follow: return "location.fill"
        case .heading: return "location.north.line.fill"
        }
    }

    var body: some View {
        GlassEffectContainer(spacing: 18) {
            HStack(spacing: 18) {
                Button { state.panel = .saved } label: {
                    GlassCircle(size: 46) {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)

                Button { state.pinCurrentPosition() } label: {
                    GlassCircle(size: 58, tint: Color(hex: 0x0A6CFF).opacity(0.18)) { BluePinIcon() }
                }
                .buttonStyle(.plain)

                Button { state.cycleTracking() } label: {
                    GlassCircle(size: 46) {
                        Image(systemName: locationIcon)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(state.tracking == .none || locationDenied ? Color.white : Color(hex: 0x2F8CFF))
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Scorciatoie di ricerca sotto la barra (come i chip di Google Maps)
struct CategoryChips: View {
    @EnvironmentObject var state: AppState

    private struct Chip: Identifiable {
        let title: String
        let icon: String
        var id: String { title }
    }

    private let baseItems: [Chip] = [
        Chip(title: "Ristoranti", icon: "fork.knife"), Chip(title: "Benzina", icon: "fuelpump.fill"),
        Chip(title: "Caffè", icon: "cup.and.saucer.fill"), Chip(title: "Supermercati", icon: "cart.fill"),
        Chip(title: "Hotel", icon: "bed.double.fill"), Chip(title: "Farmacie", icon: "pills.fill"),
        Chip(title: "Parcheggi", icon: "parkingsign"), Chip(title: "Bancomat", icon: "creditcard.fill"),
        Chip(title: "Ospedali", icon: "cross.case.fill")
    ]
    @AppStorage(Prefs.engine) private var engine = "gas"

    /// con auto elettrica o plug-in "Benzina" diventa "Ricarica" (come Google Maps)
    private var items: [Chip] {
        guard engine == "electric" || engine == "plugin" else { return baseItems }
        return baseItems.map { $0.title == "Benzina" ? Chip(title: "Ricarica elettrica", icon: "bolt.car.fill") : $0 }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(items) { item in
                        Button { state.searchCategory(item.title) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: item.icon).font(.system(size: 13, weight: .bold))
                                Text(item.title).font(.system(size: 14, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .frame(height: 36)
                            .contentShape(Capsule())
                            .glassEffect(.regular.tint(state.resultsTitle == item.title && state.panel == .results
                                                       ? Color(state.theme.accent).opacity(0.7) : nil).interactive(),
                                         in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 2)
            }
        }
    }
}

/// Bussola: compare quando la mappa è ruotata, toccala per tornare al nord
struct CompassButton: View {
    @EnvironmentObject var state: AppState

    /// lettera del punto cardinale verso cui guarda la parte alta della mappa
    private var letter: String {
        let names = ["N", "E", "S", "O"]
        var h = state.mapHeading.truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        return names[Int((h + 45) / 90) % 4]
    }

    var body: some View {
        Button { state.map.resetNorth() } label: {
            ZStack {
                // quadrante: tacche che ruotano con la mappa, le principali più chiare
                Canvas { ctx, size in
                    let c = CGPoint(x: size.width / 2, y: size.height / 2)
                    let outer = size.width / 2 - 4.5, inner = outer - 4.5
                    // tutto in CGFloat (prima Double × CGFloat bloccava la compilazione)
                    let rot = CGFloat(-state.mapHeading * .pi / 180)
                    for i in 0..<24 where i != 0 {
                        let a: CGFloat = rot + CGFloat(i) * .pi / 12 - .pi / 2
                        let major = i % 3 == 0
                        var p = Path()
                        p.move(to: CGPoint(x: c.x + cos(a) * inner, y: c.y + sin(a) * inner))
                        p.addLine(to: CGPoint(x: c.x + cos(a) * outer, y: c.y + sin(a) * outer))
                        ctx.stroke(p, with: .color(.white.opacity(major ? 0.85 : 0.35)),
                                   style: StrokeStyle(lineWidth: major ? 2 : 1.6, lineCap: .round))
                    }
                    // triangolo rosso del nord sul bordo
                    let a: CGFloat = rot - .pi / 2
                    let tip = CGPoint(x: c.x + cos(a) * (outer + 0.5), y: c.y + sin(a) * (outer + 0.5))
                    let base: CGFloat = outer - 6
                    let perp: CGFloat = a + .pi / 2
                    let bc = CGPoint(x: c.x + cos(a) * base, y: c.y + sin(a) * base)
                    var tri = Path()
                    tri.move(to: tip)
                    tri.addLine(to: CGPoint(x: bc.x + cos(perp) * 4, y: bc.y + sin(perp) * 4))
                    tri.addLine(to: CGPoint(x: bc.x - cos(perp) * 4, y: bc.y - sin(perp) * 4))
                    tri.closeSubpath()
                    ctx.fill(tri, with: .color(Color(hex: 0xFF3B30)))
                }
                Text(letter)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.opacity)
            }
            // stesso Liquid Glass e stessa misura del pulsante Impostazioni
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .glassEffect(.regular.interactive(), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Livelli

struct LayersSheet: View {
    @EnvironmentObject var state: AppState
    @AppStorage(Prefs.layerSatellite) private var satellite = false
    @AppStorage(Prefs.layerTransit) private var transit = false
    @AppStorage(Prefs.layerBike) private var bike = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Tipo di mappa").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
            HStack(spacing: 14) {
                option("Tema", "map.fill", on: !satellite) { satellite = false }
                option("Satellite", "globe.europe.africa.fill", on: satellite) { satellite = true }
            }
            Text("Dettagli della mappa").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
            HStack(spacing: 14) {
                option("Trasporti pubblici", "tram.fill", on: transit) { transit.toggle() }
                option("Ciclabili", "bicycle", on: bike) { bike.toggle() }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.top, 26)
        .onChange(of: satellite) { _, _ in state.map.applyLayers() }
        .onChange(of: transit) { _, _ in state.map.applyLayers() }
        .onChange(of: bike) { _, _ in state.map.applyLayers() }
    }

    private func option(_ title: String, _ icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(on ? Color(hex: 0x2F8CFF) : .white)
                    .frame(width: 76, height: 64)
                    .glassEffect(.regular.tint(on ? Color(hex: 0x2F8CFF).opacity(0.25) : nil).interactive(),
                                 in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(on ? Color(hex: 0x2F8CFF) : .clear, lineWidth: 2))
                Text(title).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(on ? Color(hex: 0x2F8CFF) : .white)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(width: 96)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Misura distanza

struct MeasureCrosshair: View {
    var body: some View {
        ZStack {
            Circle().strokeBorder(Color.white, lineWidth: 2.5).frame(width: 30, height: 30)
            Circle().strokeBorder(Color.black.opacity(0.5), lineWidth: 1).frame(width: 34, height: 34)
            Circle().fill(Color.white).frame(width: 5, height: 5)
        }
        .shadow(color: .black.opacity(0.4), radius: 3)
    }
}

struct MeasureBar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Distanza totale").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.white.opacity(0.6))
                    Text(state.units.short(state.measureDistance))
                        .font(.system(size: 28, weight: .heavy)).foregroundStyle(.white)
                        .contentTransition(.numericText())
                }
                Spacer()
                Button { state.stopMeasuring() } label: {
                    GlassCircle(size: 40) {
                        Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 10) {
                ActionChip(title: "Annulla", icon: "arrow.uturn.backward") { state.undoMeasurePoint() }
                ActionChip(title: "Aggiungi punto", icon: "plus", prominent: true, accent: Color(hex: 0x2F8CFF)) {
                    state.addMeasurePoint()
                }
            }
            Text("Sposta la mappa per posizionare il mirino sul punto successivo.")
                .font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.5))
        }
        .padding(18)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
    }
}
