import Foundation
import CoreLocation
import MapLibre

/// Posizione in tempo reale.
/// Su iPhone ogni app (Google Maps compresa) riceve la posizione da Core Location, che unisce GPS, Galileo,
/// GLONASS, BeiDou, Wi-Fi, celle e sensori di movimento. Qui la si chiede alla massima precisione
/// ("per la navigazione"), con precisione completa anche se l'utente aveva scelto quella approssimativa,
/// poi la si ripulisce: letture scartate se imprecise o vecchie, filtro di Kalman contro i salti,
/// direzione di marcia calcolata anche quando il GPS non la fornisce.
/// La stessa posizione filtrata muove la freccia sulla mappa e la navigazione.
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var location: CLLocation?
    @Published var authorization: CLAuthorizationStatus = .notDetermined
    @Published var placeName: String = "Ricerca posizione..."
    /// precisione stimata in metri (dopo il filtro)
    @Published var accuracy: Double = -1
    /// precisione della bussola in gradi (-1 = non disponibile); aggiornata solo quando cambia fascia
    @Published var compassAccuracy: Double = -1

    /// richiamato ad ogni nuova posizione (usato dalla navigazione, anche in background)
    var onUpdate: ((CLLocation) -> Void)?

    /// sorgente di posizione per la mappa (freccia utente): riceve le posizioni già filtrate
    let mapFeed = MapLocationFeed()

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var lastGeocoded: CLLocation?
    private var filter = KalmanLocationFilter()
    private var previous: CLLocation?
    private var navigating = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.headingFilter = 1
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = false
        authorization = manager.authorizationStatus
        mapFeed.owner = self
        mapFeed.authorizationStatus = manager.authorizationStatus
        mapFeed.accuracyAuthorization = manager.accuracyAuthorization
    }

    func start() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        requestFullAccuracyIfNeeded()
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
    }

    /// Se l'utente ha concesso solo la posizione approssimativa, chiede la precisione completa
    private func requestFullAccuracyIfNeeded() {
        guard manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways,
              manager.accuracyAuthorization == .reducedAccuracy else { return }
        manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "Navigation")
    }

    /// Durante la navigazione: aggiornamenti anche con lo schermo spento e profilo "guida"
    func setNavigating(_ on: Bool) {
        navigating = on
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = on ? .automotiveNavigation : .otherNavigation
        manager.allowsBackgroundLocationUpdates = on
        manager.showsBackgroundLocationIndicator = on
        manager.pausesLocationUpdatesAutomatically = false
        requestFullAccuracyIfNeeded()
        manager.startUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async {
            self.authorization = manager.authorizationStatus
            self.mapFeed.authorizationChanged(manager.authorizationStatus, accuracy: manager.accuracyAuthorization)
        }
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            requestFullAccuracyIfNeeded()
            manager.startUpdatingLocation()
            if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        mapFeed.forward(heading: newHeading)
        let a = newHeading.headingAccuracy
        let bucket: Double = a < 0 ? -1 : (a <= 15 ? 10 : (a <= 35 ? 30 : 60))
        let old = compassAccuracy
        let bucketOld: Double = old < 0 ? -1 : (old <= 15 ? 10 : (old <= 35 ? 30 : 60))
        if bucket != bucketOld {
            DispatchQueue.main.async { self.compassAccuracy = a }
        }
    }

    func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool { false }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // scarta posizioni non valide, troppo imprecise o vecchie (es. la prima cache del GPS)
        let maxError: Double = location == nil ? 300 : 80
        let good = locations.filter { $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy < maxError
                                      && abs($0.timestamp.timeIntervalSinceNow) < 10 }
        guard !good.isEmpty else { return }
        var out: CLLocation?
        for raw in good {
            out = smooth(raw)
        }
        guard let loc = out else { return }
        DispatchQueue.main.async {
            self.location = loc
            self.accuracy = loc.horizontalAccuracy
            self.onUpdate?(loc)
        }
        mapFeed.forward(locations: [loc])
        if lastGeocoded == nil || loc.distance(from: lastGeocoded!) > 250 {
            lastGeocoded = loc
            geocoder.reverseGeocodeLocation(loc, preferredLocale: Locale(identifier: "it_IT")) { [weak self] placemarks, _ in
                guard let pm = placemarks?.first else { return }
                let city = pm.locality ?? pm.name ?? ""
                let area = pm.subAdministrativeArea ?? pm.administrativeArea ?? pm.country ?? ""
                let text = [city, area].filter { !$0.isEmpty }.joined(separator: ", ")
                DispatchQueue.main.async {
                    if !text.isEmpty { self?.placeName = text }
                }
            }
        }
    }

    /// Filtro di Kalman + direzione di marcia
    private func smooth(_ raw: CLLocation) -> CLLocation {
        let c = filter.process(raw)
        var course = raw.course
        var courseAcc = raw.courseAccuracy
        if course < 0, let prev = previous {
            let d = prev.distance(from: raw)
            if d > max(4, raw.horizontalAccuracy * 0.6) {
                course = MapController.bearing(from: prev.coordinate, to: raw.coordinate)
                courseAcc = 25
            }
        }
        if previous == nil || (previous.map { $0.distance(from: raw) } ?? 0) > 3 { previous = raw }
        return CLLocation(coordinate: c, altitude: raw.altitude,
                          horizontalAccuracy: min(raw.horizontalAccuracy, filter.accuracy),
                          verticalAccuracy: raw.verticalAccuracy,
                          course: course, courseAccuracy: courseAcc,
                          speed: raw.speed, speedAccuracy: raw.speedAccuracy,
                          timestamp: raw.timestamp)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    fileprivate func startHeading() {
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
    }
    fileprivate func requestWhenInUse() { manager.requestWhenInUseAuthorization() }
    fileprivate func requestFullAccuracy() { requestFullAccuracyIfNeeded() }
    fileprivate var currentAuthorization: CLAuthorizationStatus { manager.authorizationStatus }
    fileprivate var currentAccuracy: CLAccuracyAuthorization { manager.accuracyAuthorization }
}

/// Filtro di Kalman su latitudine/longitudine: elimina i salti del GPS senza ritardare la freccia
/// (il rumore di processo cresce con la velocità, quindi in auto segue subito i movimenti reali).
struct KalmanLocationFilter {
    private var lat = 0.0, lon = 0.0
    private var variance = -1.0
    private var time: TimeInterval = 0

    var accuracy: Double { variance < 0 ? 1000 : sqrt(variance) }

    mutating func process(_ loc: CLLocation) -> CLLocationCoordinate2D {
        let acc = max(loc.horizontalAccuracy, 1)
        let t = loc.timestamp.timeIntervalSince1970
        let measured = loc.coordinate
        if variance >= 0 {
            let current = CLLocation(latitude: lat, longitude: lon)
            // dopo una pausa lunga o un salto enorme si riparte dalla lettura nuova
            if t - time > 20 || current.distance(from: loc) > 250 { variance = -1 }
        }
        if variance < 0 {
            lat = measured.latitude; lon = measured.longitude
            variance = acc * acc; time = t
            return measured
        }
        let dt = t - time
        if dt > 0 {
            let q = max(3.0, loc.speed > 0 ? loc.speed * 1.2 : 0)   // metri al secondo
            variance += dt * q * q
            time = t
        }
        let k = variance / (variance + acc * acc)
        lat += k * (measured.latitude - lat)
        lon += k * (measured.longitude - lon)
        variance = (1 - k) * variance
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

/// Fa arrivare alla mappa (freccia utente) le posizioni filtrate invece di quelle grezze.
final class MapLocationFeed: NSObject, MLNLocationManager {
    weak var delegate: MLNLocationManagerDelegate?
    fileprivate weak var owner: LocationManager?

    var authorizationStatus: CLAuthorizationStatus = .notDetermined
    var accuracyAuthorization: CLAccuracyAuthorization = .fullAccuracy
    var headingOrientation: CLDeviceOrientation = .portrait
    var activityType: CLActivityType = .otherNavigation
    var desiredAccuracy: CLLocationAccuracy = kCLLocationAccuracyBestForNavigation
    var distanceFilter: CLLocationDistance = kCLDistanceFilterNone

    private var active = false
    private var headingActive = false
    private var last: CLLocation?

    func requestAlwaysAuthorization() { owner?.requestWhenInUse() }
    func requestWhenInUseAuthorization() { owner?.requestWhenInUse() }

    func startUpdatingLocation() {
        active = true
        if let owner = owner {
            authorizationStatus = owner.currentAuthorization
            accuracyAuthorization = owner.currentAccuracy
        }
        if let l = last { forward(locations: [l]) }
    }
    func stopUpdatingLocation() { active = false }
    func startUpdatingHeading() { headingActive = true; owner?.startHeading() }
    func stopUpdatingHeading() { headingActive = false }
    func dismissHeadingCalibrationDisplay() {}
    func requestTemporaryFullAccuracyAuthorization(withPurposeKey purposeKey: String) {
        owner?.requestFullAccuracy()
    }

    func authorizationChanged(_ status: CLAuthorizationStatus, accuracy: CLAccuracyAuthorization) {
        authorizationStatus = status
        accuracyAuthorization = accuracy
        if let d = delegate as? NSObject, d.responds(to: NSSelectorFromString("locationManagerDidChangeAuthorization:")) {
            _ = d.perform(NSSelectorFromString("locationManagerDidChangeAuthorization:"), with: self)
        }
    }

    func forward(locations: [CLLocation]) {
        last = locations.last
        guard active else { return }
        DispatchQueue.main.async {
            guard let d = self.delegate as? NSObject else { return }
            _ = d.perform(NSSelectorFromString("locationManager:didUpdateLocations:"), with: self, with: locations)
        }
    }

    func forward(heading: CLHeading) {
        guard headingActive else { return }
        DispatchQueue.main.async {
            guard let d = self.delegate as? NSObject else { return }
            _ = d.perform(NSSelectorFromString("locationManager:didUpdateHeading:"), with: self, with: heading)
        }
    }
}

enum Geocoder {
    static func reverse(_ coordinate: CLLocationCoordinate2D, completion: @escaping (String) -> Void) {
        let geocoder = CLGeocoder()
        let loc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        geocoder.reverseGeocodeLocation(loc, preferredLocale: Locale(identifier: "it_IT")) { placemarks, _ in
            let text = placemarks?.first.map { Place.formatFull($0) }
                ?? String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
            DispatchQueue.main.async { completion(text) }
        }
    }
}
