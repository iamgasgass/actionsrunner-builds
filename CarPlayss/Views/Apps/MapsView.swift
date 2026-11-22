import MapKit
import SwiftUI

struct MapsView: View {
    @EnvironmentObject var nav: NavigationModel
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var state: AppState
    @EnvironmentObject var location: LocationManager
    @State private var showSearch = false
    @FocusState private var searchFocused: Bool

    private let quickDestinations: [(String, String)] = [
        ("fuelpump.fill", "Distributori"),
        ("parkingsign.circle.fill", "Parcheggi"),
        ("fork.knife", "Ristoranti"),
        ("cup.and.saucer.fill", "Bar"),
        ("bolt.car.fill", "Ricarica"),
        ("cart.fill", "Supermercati")
    ]

    var body: some View {
        ZStack {
            CarMapView()
                .ignoresSafeArea()

            switch nav.phase {
            case .browsing:
                browsingOverlay
            case .preview:
                previewOverlay
            case .navigating:
                navigationOverlay
            }
        }
        .onReceive(location.$lastLocation) { loc in
            if let loc = loc { nav.updateWithRealLocation(loc) }
        }
    }

    // MARK: - Browsing

    private var browsingOverlay: some View {
        HStack(alignment: .top, spacing: 0) {
            if showSearch {
                searchPanel
                    .frame(width: 330)
                    .padding(10)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            Spacer()
            mapButtons
                .padding(10)
        }
        .overlay(alignment: .topLeading) {
            if !showSearch {
                Button {
                    withAnimation { showSearch = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { searchFocused = true }
                } label: {
                    Label("Cerca", systemImage: "magnifyingglass")
                        .font(.system(size: 17, weight: .semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .card(radius: 24)
                }
                .buttonStyle(PressableStyle())
                .foregroundStyle(.primary)
                .padding(10)
            }
        }
        .overlay(alignment: .bottom) {
            if let err = nav.errorMessage {
                Text(err)
                    .font(.system(size: 14, weight: .medium))
                    .padding(10)
                    .card(radius: 12)
                    .padding(.bottom, 12)
            }
        }
    }

    private var searchPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Cerca luogo o indirizzo", text: $nav.query)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .onSubmit { nav.performSearch() }
                    .font(.system(size: 17))
                if nav.isSearching { ProgressView() }
                Button {
                    nav.clearSearch()
                    searchFocused = false
                    withAnimation { showSearch = false }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    if nav.results.isEmpty {
                        ForEach(quickDestinations.indices, id: \.self) { i in
                            let item = quickDestinations[i]
                            Button {
                                nav.performSearch(item.1)
                            } label: {
                                CarListRow(title: item.1, subtitle: "Nelle vicinanze") {
                                    Image(systemName: item.0)
                                        .font(.system(size: 18))
                                        .frame(width: 38, height: 38)
                                        .background(Color.blue.opacity(0.8), in: Circle())
                                        .foregroundColor(.white)
                                }
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 66)
                        }
                    } else {
                        ForEach(nav.results, id: \.self) { item in
                            Button {
                                searchFocused = false
                                withAnimation { showSearch = false }
                                nav.select(item)
                            } label: {
                                CarListRow(title: item.name ?? "Luogo", subtitle: address(of: item)) {
                                    Image(systemName: "mappin.circle.fill")
                                        .font(.system(size: 30))
                                        .foregroundColor(.red)
                                        .frame(width: 38)
                                }
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 66)
                        }
                    }
                }
            }
        }
        .card()
    }

    private var mapButtons: some View {
        VStack(spacing: 10) {
            roundButton("location.fill") { nav.centerOnUser() }
            roundButton("plus") { nav.zoom(0.5) }
            roundButton("minus") { nav.zoom(2) }
        }
    }

    private func roundButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 46, height: 46)
                .card(radius: 23)
        }
        .buttonStyle(PressableStyle())
        .foregroundStyle(.primary)
    }

    // MARK: - Anteprima percorso

    private var previewOverlay: some View {
        HStack {
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(nav.destination?.name ?? "Destinazione")
                            .font(.system(size: 19, weight: .bold))
                            .lineLimit(1)
                        Text(nav.destination.map { address(of: $0) } ?? "")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button { nav.cancelPreview() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .frame(width: 32, height: 32)
                            .background(Color.white.opacity(0.15), in: Circle())
                    }
                    .buttonStyle(PressableStyle())
                }

                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(Array(nav.routes.enumerated()), id: \.offset) { index, route in
                            Button { nav.chooseRoute(index) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(Formatters.duration(route.expectedTravelTime))
                                            .font(.system(size: 18, weight: .bold))
                                        Text("\(Formatters.distance(route.distance)) · \(route.name)")
                                            .font(.system(size: 13))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if index == nav.selectedRouteIndex {
                                        Image(systemName: "checkmark.circle.fill").foregroundColor(.blue)
                                    }
                                }
                                .padding(10)
                                .background(Color.white.opacity(index == nav.selectedRouteIndex ? 0.14 : 0.05),
                                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Button { nav.startNavigation(simulate: false) } label: {
                        Text("Vai")
                            .font(.system(size: 18, weight: .bold))
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(Color.green, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .foregroundColor(.white)
                    }
                    Button { nav.startNavigation(simulate: true) } label: {
                        Label("Simula", systemImage: "car.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(Color.blue, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .foregroundColor(.white)
                    }
                }
                .buttonStyle(PressableStyle())
            }
            .padding(14)
            .frame(width: 320)
            .card()
            .padding(10)
        }
    }

    // MARK: - Navigazione

    private var navigationOverlay: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                maneuverCard
                Spacer()
                VStack(spacing: 10) {
                    if !nav.followUser {
                        roundButton("location.north.line.fill") { nav.centerOnUser() }
                    }
                    if nav.isSimulating {
                        roundButton(nav.simulationPaused ? "play.fill" : "pause.fill") { nav.toggleSimulationPause() }
                    }
                }
            }
            .padding(10)

            Spacer()

            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Formatters.arrival(after: nav.remainingTime))
                        .font(.system(size: 20, weight: .bold))
                    Text("arrivo").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(Formatters.duration(nav.remainingTime))
                        .font(.system(size: 20, weight: .bold))
                    Text("min").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(Formatters.distance(nav.remainingDistance))
                        .font(.system(size: 20, weight: .bold))
                    Text("rimanenti").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if nav.isSimulating {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Int(nav.simulatedSpeedKmh))")
                            .font(.system(size: 20, weight: .bold))
                            .monospacedDigit()
                        Text("km/h").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button { nav.endNavigation() } label: {
                    Text("Termina")
                        .font(.system(size: 16, weight: .bold))
                        .padding(.horizontal, 18)
                        .frame(minHeight: 42)
                        .background(Color.red, in: Capsule())
                        .foregroundColor(.white)
                }
                .buttonStyle(PressableStyle())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .card()
            .padding(10)
        }
    }

    private var maneuverCard: some View {
        let step = nav.currentStep
        let instruction = step?.instructions.isEmpty == false ? step!.instructions : "Segui il percorso"
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: Formatters.maneuverSymbol(for: instruction))
                    .font(.system(size: 34, weight: .bold))
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Formatters.distance(nav.distanceToNextManeuver))
                        .font(.system(size: 26, weight: .bold))
                    Text(instruction)
                        .font(.system(size: 16, weight: .medium))
                        .lineLimit(2)
                }
            }
            if let next = nav.nextStep, !next.instructions.isEmpty {
                Divider().background(Color.white.opacity(0.4))
                HStack(spacing: 8) {
                    Text("Poi").font(.system(size: 13, weight: .semibold))
                    Image(systemName: Formatters.maneuverSymbol(for: next.instructions))
                    Text(next.instructions).font(.system(size: 13)).lineLimit(1)
                }
                .foregroundColor(.white.opacity(0.85))
            }
        }
        .foregroundColor(.white)
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .background(Color(red: 0.10, green: 0.45, blue: 0.30), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
    }

    private func address(of item: MKMapItem) -> String {
        let p = item.placemark
        let parts = [p.thoroughfare, p.subThoroughfare, p.locality].compactMap { $0 }
        return parts.isEmpty ? (p.title ?? "") : parts.joined(separator: " ")
    }
}

/// MKMapView collegata al NavigationModel.
struct CarMapView: UIViewRepresentable {
    @EnvironmentObject var nav: NavigationModel
    @EnvironmentObject var settings: SettingsStore

    func makeCoordinator() -> Coordinator { Coordinator(nav: nav) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsCompass = false
        map.showsScale = false
        map.pointOfInterestFilter = .includingAll
        if nav.phase == .browsing {
            let fallback = CLLocationCoordinate2D(latitude: 41.9028, longitude: 12.4964)
            map.setRegion(MKCoordinateRegion(center: fallback, latitudinalMeters: 4000, longitudinalMeters: 4000), animated: false)
            map.setUserTrackingMode(.follow, animated: false)
        }
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.userPanned(_:)))
        pan.delegate = context.coordinator
        map.addGestureRecognizer(pan)
        nav.attach(map)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.nav = nav
        map.overrideUserInterfaceStyle = settings.appearance == .light ? .light : (settings.appearance == .dark ? .dark : .unspecified)
    }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var nav: NavigationModel

        init(nav: NavigationModel) {
            self.nav = nav
        }

        @objc func userPanned(_ g: UIPanGestureRecognizer) {
            if g.state == .began { nav.followUser = false }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let r = MKPolylineRenderer(polyline: line)
            let selected = nav.isSelectedRoute(line)
            r.strokeColor = selected ? UIColor.systemBlue : UIColor.systemGray.withAlphaComponent(0.7)
            r.lineWidth = selected ? 8 : 6
            r.lineCap = .round
            r.lineJoin = .round
            return r
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }
            if nav.isCar(annotation) {
                let id = "car"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: id) ?? MKAnnotationView(annotation: annotation, reuseIdentifier: id)
                view.annotation = annotation
                let config = UIImage.SymbolConfiguration(pointSize: 30, weight: .bold)
                view.image = UIImage(systemName: "location.north.circle.fill", withConfiguration: config)?
                    .withTintColor(.systemBlue, renderingMode: .alwaysOriginal)
                view.layer.shadowColor = UIColor.black.cgColor
                view.layer.shadowOpacity = 0.4
                view.layer.shadowRadius = 4
                view.zPriority = .max
                return view
            }
            let id = "dest"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
            view.annotation = annotation
            view.markerTintColor = .systemRed
            view.glyphImage = UIImage(systemName: "flag.checkered")
            return view
        }
    }
}
