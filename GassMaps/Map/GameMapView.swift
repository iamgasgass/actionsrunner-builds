import SwiftUI
import MapLibre

struct GameMapView: UIViewRepresentable {
    @ObservedObject var state: AppState
    @AppStorage(Prefs.showScale) private var showScale = false
    @AppStorage(Prefs.tilt3D) private var tilt3D = true
    @AppStorage(Prefs.avatar) private var avatar = 0

    func makeCoordinator() -> MapCoordinator {
        MapCoordinator(state: state)
    }

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero, styleURL: state.theme.styleURL)
        map.delegate = context.coordinator
        map.backgroundColor = .black
        map.logoView.isHidden = true
        map.compassView.isHidden = true
        map.attributionButtonPosition = .bottomLeft
        map.attributionButtonMargins = CGPoint(x: 8, y: 6)
        map.attributionButton.alpha = 0.45
        // la freccia usa la posizione già filtrata (stessa della navigazione)
        map.locationManager = state.location.mapFeed
        map.showsUserLocation = true
        map.showsUserHeadingIndicator = true   // la freccia riceve la bussola anche senza modalità bussola
        map.allowsTilting = true
        map.allowsRotating = true
        map.minimumZoomLevel = 2
        map.maximumZoomLevel = 19.5
        map.setZoomLevel(MapController.defaultZoom, animated: false)

        let longPress = UILongPressGestureRecognizer(target: context.coordinator,
                                                     action: #selector(MapCoordinator.handleLongPress(_:)))
        map.addGestureRecognizer(longPress)

        // tocco singolo: icone dei luoghi, percorsi alternativi (non interferisce col doppio tocco per lo zoom)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(MapCoordinator.handleTap(_:)))
        for g in map.gestureRecognizers ?? [] {
            if let t = g as? UITapGestureRecognizer, t.numberOfTapsRequired == 2 { tap.require(toFail: t) }
        }
        map.addGestureRecognizer(tap)

        context.coordinator.currentStyleID = state.theme.id
        state.map.attach(map)
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        context.coordinator.state = state
        if map.showsScale != showScale { map.showsScale = showScale }
        if UserArrowView.avatar != avatar {
            UserArrowView.avatar = avatar
            if let ul = map.userLocation, let v = map.view(for: ul) as? UserArrowView { v.update() }
        }
        if context.coordinator.tilt3D != tilt3D {
            context.coordinator.tilt3D = tilt3D
            let cam = map.camera
            cam.pitch = tilt3D ? state.theme.mapPitch : 0
            map.setCamera(cam, withDuration: 0.4, animationTimingFunction: CAMediaTimingFunction(name: .easeInEaseOut))
        }
        if context.coordinator.currentStyleID != state.theme.id {
            context.coordinator.currentStyleID = state.theme.id
            map.styleURL = state.theme.styleURL
        }
    }
}

final class MapCoordinator: NSObject, MLNMapViewDelegate {
    var state: AppState
    var currentStyleID: String = ""
    var tilt3D = Prefs.bool(Prefs.tilt3D, default: true)

    init(state: AppState) {
        self.state = state
    }

    // MARK: Stile

    func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
        MapIcons.install(in: style, theme: state.theme)
        state.map.installRoute(in: style)
        state.map.applyLayers()
        if state.measuring { state.updateMeasure() }
        UserArrowView.tint = state.theme.arrowColor
        UserArrowView.marker = state.theme.userMarker
        UserArrowView.avatar = UserDefaults.standard.integer(forKey: Prefs.avatar)
        // inclinazione propria del tema (es. pergamena vista dall'alto, neon in 3D)
        let cam = mapView.camera
        cam.pitch = tilt3D ? state.theme.mapPitch : 0
        mapView.setCamera(cam, withDuration: 0.6, animationTimingFunction: CAMediaTimingFunction(name: .easeInEaseOut))
    }

    func mapView(_ mapView: MLNMapView, didFailToLoadImage imageName: String) -> UIImage? {
        MapIcons.image(named: imageName, theme: state.theme)
    }

    // MARK: Annotazioni

    func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
        if annotation is MLNUserLocation {
            return UserArrowView()
        }
        if let alt = annotation as? AltLabelAnnotation {
            let rid = "gm-alt-label"
            let v = (mapView.dequeueReusableAnnotationView(withIdentifier: rid) as? AltLabelView)
                ?? AltLabelView(reuseIdentifier: rid)
            v.configure(text: alt.title ?? "", color: state.theme.accent)
            return v
        }
        if annotation is ResultAnnotation {
            let rid = "gm-result"
            let v = (mapView.dequeueReusableAnnotationView(withIdentifier: rid) as? ResultMarkerView)
                ?? ResultMarkerView(reuseIdentifier: rid)
            v.configure(color: state.theme.accent)
            return v
        }
        let id = "gm-pin"
        let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? PinBubbleView)
            ?? PinBubbleView(reuseIdentifier: id)
        let title = annotation.title ?? nil
        view.configure(title: title ?? "", theme: state.theme)
        return view
    }

    func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: MLNAnnotation) -> Bool {
        false
    }

    func mapView(_ mapView: MLNMapView, didSelect annotation: MLNAnnotation) {
        if let alt = annotation as? AltLabelAnnotation {
            mapView.deselectAnnotation(annotation, animated: false)
            state.switchToNavAlternative(alt.index)
            return
        }
        guard let r = annotation as? ResultAnnotation, state.searchResults.indices.contains(r.index) else { return }
        let item = state.searchResults[r.index]
        mapView.deselectAnnotation(annotation, animated: false)
        state.pin(Place(mapItem: item), item: item)
    }

    /// la bussola ruota insieme alla mappa anche durante il gesto
    func mapViewRegionIsChanging(_ mapView: MLNMapView) {
        let h = mapView.direction
        if abs(h - state.mapHeading) > 0.5 {
            state.mapHeading = h
        }
    }

    func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
        let h = mapView.direction
        if abs(h - state.mapHeading) > 1 {
            DispatchQueue.main.async { self.state.mapHeading = h }
        }
        DispatchQueue.main.async { self.state.mapMoved() }
    }

    // MARK: Posizione

    func mapView(_ mapView: MLNMapView, didUpdate userLocation: MLNUserLocation?) {
        guard let loc = userLocation?.location else { return }
        state.map.initialPosition(loc.coordinate)
    }

    func mapView(_ mapView: MLNMapView, didChange mode: MLNUserTrackingMode, animated: Bool) {
        let t: TrackingState
        switch mode {
        case .follow: t = .follow
        case .followWithHeading, .followWithCourse: t = .heading
        default: t = .none
        }
        if state.tracking != t {
            DispatchQueue.main.async { self.state.tracking = t }
        }
    }

    // MARK: Gesture

    @objc func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let map = gesture.view as? MLNMapView else { return }
        if Prefs.bool(Prefs.haptics, default: true) { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        let point = gesture.location(in: map)

        // tocco sulla freccia della posizione → scheda "La tua posizione" (come Google Maps)
        if let ul = map.userLocation?.location, state.panel != .navigating, state.panel != .directions {
            let p = map.convert(ul.coordinate, toPointTo: map)
            if hypot(p.x - point.x, p.y - point.y) < 30 {
                state.openMyLocation()
                return
            }
        }

        // durante la navigazione: tocco su un percorso alternativo → si passa a quello
        if state.panel == .navigating, !state.navAlternatives.isEmpty, let i = state.map.alternativeIndex(near: point) {
            state.switchToNavAlternative(i)
            return
        }

        // scelta di un percorso alternativo
        if state.panel == .directions, let i = state.map.alternativeIndex(near: point),
           state.alternativeIndices.indices.contains(i) {
            state.selectRoute(state.alternativeIndices[i])
            return
        }
        guard state.panel != .navigating, state.panel != .directions else { return }

        // icona di un luogo sulla mappa → scheda del luogo
        let rect = CGRect(x: point.x - 18, y: point.y - 18, width: 36, height: 36)
        let features = map.visibleFeatures(in: rect, styleLayerIdentifiers: ["poi"])
        if let f = features.first,
           let name = (f.attribute(forKey: "name:it") as? String) ?? (f.attribute(forKey: "name") as? String) {
            state.openPOI(name: name, coordinate: f.coordinate)
        }
    }

    @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let map = gesture.view as? MLNMapView else { return }
        if Prefs.bool(Prefs.haptics, default: true) { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        let point = gesture.location(in: map)
        let coord = map.convert(point, toCoordinateFrom: map)
        let place = Place(name: "", address: "Ricerca indirizzo...", coordinate: coord)
        state.pin(place, fly: false)
        Geocoder.reverse(coord) { [weak self] address in
            guard let self = self, var p = self.state.pinnedPlace, p.latitude == coord.latitude else { return }
            p.address = address
            self.state.pinnedPlace = p
        }
    }
}
