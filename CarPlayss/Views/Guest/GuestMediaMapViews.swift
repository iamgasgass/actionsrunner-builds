import CarPlay
import MapKit
import MediaPlayer
import SwiftUI

// MARK: - Now Playing (CPNowPlayingTemplate)

/// Tiene traccia di quando l'app ha aggiornato il tempo trascorso, per far avanzare la barra.
final class NowPlayingClock {
    static let shared = NowPlayingClock()
    private var lastElapsed: Double = -1
    private var lastDate = Date()

    func current(elapsed: Double, rate: Double, now: Date) -> Double {
        if elapsed != lastElapsed {
            lastElapsed = elapsed
            lastDate = now
        }
        return elapsed + max(0, now.timeIntervalSince(lastDate)) * rate
    }
}

struct CPNowPlayingView: View {
    @ObservedObject var session: GuestSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            content(now: context.date)
        }
    }

    private func content(now: Date) -> some View {
        let info = GuestRemote.nowPlayingInfo
        let title = info[MPMediaItemPropertyTitle] as? String ?? "Non in riproduzione"
        let artist = info[MPMediaItemPropertyArtist] as? String ?? ""
        let album = info[MPMediaItemPropertyAlbumTitle] as? String ?? ""
        let duration = info[MPMediaItemPropertyPlaybackDuration] as? Double ?? 0
        let rate = info[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? 0
        let live = info[MPNowPlayingInfoPropertyIsLiveStream] as? Bool ?? false
        let elapsedRaw = info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? 0
        let elapsed = min(duration > 0 ? duration : .greatestFiniteMagnitude,
                          NowPlayingClock.shared.current(elapsed: elapsedRaw, rate: rate, now: now))
        let artwork = (info[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)?.image(at: CGSize(width: 600, height: 600))
        let template = CPNowPlayingTemplate.shared

        return GeometryReader { geo in
            let art = min(geo.size.height - 40, geo.size.width * 0.42)
            HStack(spacing: 26) {
                Group {
                    if let artwork = artwork {
                        Image(uiImage: artwork).resizable().scaledToFill()
                    } else {
                        ZStack {
                            Color(white: 0.18)
                            Image(systemName: "music.note")
                                .font(.system(size: art * 0.32))
                                .foregroundColor(Color(white: 0.5))
                        }
                    }
                }
                .frame(width: art, height: art)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 0) {
                    Spacer(minLength: 0)
                    Text(title)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                    Text(artist)
                        .font(.system(size: 18))
                        .foregroundColor(CP.secondaryText)
                        .lineLimit(1)
                        .padding(.top, 2)
                    if !album.isEmpty {
                        Text(album)
                            .font(.system(size: 15))
                            .foregroundColor(CP.tertiaryText)
                            .lineLimit(1)
                    }

                    progress(elapsed: elapsed, duration: duration, live: live)
                        .padding(.top, 14)

                    HStack {
                        Button { GuestRemote.previous() } label: {
                            Image(systemName: GuestRemote.usesSkipIntervals ? "gobackward.15" : "backward.fill")
                        }
                        Spacer()
                        Button { GuestRemote.togglePlayPause() } label: {
                            Image(systemName: rate > 0 ? "pause.fill" : "play.fill").font(.system(size: 40))
                        }
                        Spacer()
                        Button { GuestRemote.next() } label: {
                            Image(systemName: GuestRemote.usesSkipIntervals ? "goforward.30" : "forward.fill")
                        }
                    }
                    .font(.system(size: 30))
                    .foregroundColor(.white)
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)

                    HStack(spacing: 14) {
                        ForEach(Array(template.nowPlayingButtons.enumerated()), id: \.offset) { _, button in
                            nowPlayingButton(button)
                        }
                        Spacer(minLength: 0)
                        if template.isAlbumArtistButtonEnabled {
                            Button {
                                notifyObservers("nowPlayingTemplateAlbumArtistButtonTapped:")
                            } label: {
                                Image(systemName: "music.mic")
                            }
                            .buttonStyle(CPCapsuleButtonStyle())
                        }
                        if template.isUpNextButtonEnabled {
                            Button {
                                notifyObservers("nowPlayingTemplateUpNextButtonTapped:")
                            } label: {
                                Text(template.upNextTitle.isEmpty ? "A seguire" : template.upNextTitle)
                            }
                            .buttonStyle(CPCapsuleButtonStyle())
                        }
                    }
                    .padding(.top, 14)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 28)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    @ViewBuilder
    private func progress(elapsed: Double, duration: Double, live: Bool) -> some View {
        if live {
            HStack(spacing: 6) {
                Text("IN DIRETTA")
                    .font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.red))
                    .foregroundColor(.white)
            }
        } else if duration > 0 {
            VStack(spacing: 4) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(white: 0.3))
                        Capsule().fill(Color.white).frame(width: g.size.width * CGFloat(min(1, elapsed / duration)))
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                        let fraction = max(0, min(1, v.location.x / max(1, g.size.width)))
                        _ = CPSHooks.invokeChangePlaybackPosition(Double(fraction) * duration)
                    })
                }
                .frame(height: 4)
                HStack {
                    Text(Formatters.time(elapsed))
                    Spacer()
                    Text("-" + Formatters.time(max(0, duration - elapsed)))
                }
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundColor(CP.secondaryText)
            }
        }
    }

    private func nowPlayingButton(_ button: CPNowPlayingButton) -> some View {
        Button {
            session.tap(handlerOf: button, label: "Now Playing")
        } label: {
            Group {
                if let image = cpsOpt((button as? CPNowPlayingImageButton)?.image) {
                    Image(uiImage: image).renderingMode(.template).resizable().scaledToFit().frame(width: 20, height: 20)
                } else if button is CPNowPlayingPlaybackRateButton {
                    Text("1×").font(.system(size: 15, weight: .bold))
                } else {
                    Image(systemName: symbol(for: button))
                }
            }
            .foregroundColor(button.isSelected ? .black : .white)
            .frame(width: 40, height: 32)
            .background(Capsule().fill(button.isSelected ? Color.white : CP.buttonFill))
        }
        .buttonStyle(.plain)
        .disabled(!button.isEnabled)
        .opacity(button.isEnabled ? 1 : 0.4)
    }

    private func symbol(for button: CPNowPlayingButton) -> String {
        switch button {
        case is CPNowPlayingShuffleButton: return "shuffle"
        case is CPNowPlayingRepeatButton: return "repeat"
        case is CPNowPlayingAddToLibraryButton: return "plus"
        case is CPNowPlayingMoreButton: return "ellipsis"
        default: return "circle"
        }
    }

    private func notifyObservers(_ selector: String) {
        let sel = NSSelectorFromString(selector)
        session.guest("Now Playing") {
            for observer in CPSHooks.nowPlayingObservers() {
                CPSObjC.send(observer, sel, CPNowPlayingTemplate.shared)
            }
        }
    }
}

// MARK: - Aree toccabili dello strato controlli

/// Rettangoli (nello spazio dello strato) occupati dai controlli SwiftUI sopra la mappa.
final class CPHitRegions {
    static let space = "cpsMapOverlay"
    var rects: [CGRect] = []

    func contains(_ point: CGPoint) -> Bool {
        rects.contains { $0.insetBy(dx: -4, dy: -4).contains(point) }
    }
}

struct CPHitRegionKey: PreferenceKey {
    static var defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// Segna la vista come toccabile quando sta sopra la mappa dell'app.
    func cpsHitRegion() -> some View {
        background(
            GeometryReader { g in
                Color.clear.preference(key: CPHitRegionKey.self, value: [g.frame(in: .named(CPHitRegions.space))])
            }
        )
    }
}

// MARK: - Finestra dell'auto (app di navigazione)

/// Intercetta solo i tocchi sui controlli (aree comunicate dalla vista SwiftUI); il resto va all'app.
final class GuestPassthroughView: UIView {
    weak var content: UIView?
    var regions: CPHitRegions?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let content = content, let regions = regions else { return nil }
        let p = convert(point, to: content)
        guard regions.contains(p) else { return nil }
        return content.hitTest(p, with: event) ?? content
    }
}

final class GuestWindowPlaceholder: UIView {
    weak var guest: UIWindow?
    var overlay: GuestPassthroughView?

    override func layoutSubviews() {
        super.layoutSubviews()
        place()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        place()
    }

    func place() {
        guard let guest = guest else { return }
        guard let host = window, let scene = host.windowScene, !bounds.isEmpty else {
            guest.isHidden = true
            return
        }
        if guest.windowScene !== scene {
            _ = CPSObjC.catching { guest.windowScene = scene }
        }
        guest.windowLevel = host.windowLevel + 1
        let rect = convert(bounds, to: nil)
        if guest.frame != rect { guest.frame = rect }
        guest.isHidden = false
        if let overlay = overlay {
            if overlay.superview !== guest { guest.addSubview(overlay) }
            overlay.frame = guest.bounds
            guest.bringSubviewToFront(overlay)
        }
    }

    func hideGuest() {
        guest?.isHidden = true
        overlay?.removeFromSuperview()
    }
}

final class GuestWindowCoordinator {
    var hosting: UIHostingController<AnyView>?
    let regions = CPHitRegions()
}


/// Mostra una finestra dell'app ospite (CPWindow della mappa o finestra della Dashboard) come finestra
/// vera della scena, sopra l'area occupata da questo segnaposto. (Annidarla come sottovista confonde
/// i motori di Auto Layout delle due finestre.) `overlay` viene disegnato dentro la finestra, sopra
/// il contenuto dell'app: riceve solo i tocchi sulle aree marcate con `cpsHitRegion()`.
struct GuestWindowHost<Overlay: View>: UIViewRepresentable {
    let window: UIWindow
    let overlay: Overlay

    typealias Coordinator = GuestWindowCoordinator

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func root(_ regions: CPHitRegions) -> AnyView {
        AnyView(
            overlay
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .coordinateSpace(name: CPHitRegions.space)
                .onPreferenceChange(CPHitRegionKey.self) { regions.rects = $0 }
        )
    }

    func makeUIView(context: Context) -> GuestWindowPlaceholder {
        let view = GuestWindowPlaceholder()
        view.backgroundColor = .black
        view.guest = window
        let hosting = UIHostingController(rootView: root(context.coordinator.regions))
        hosting.view.backgroundColor = .clear
        hosting.overrideUserInterfaceStyle = .dark
        let overlay = GuestPassthroughView()
        overlay.backgroundColor = .clear
        hosting.view.frame = overlay.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.addSubview(hosting.view)
        overlay.content = hosting.view
        overlay.regions = context.coordinator.regions
        view.overlay = overlay
        context.coordinator.hosting = hosting
        return view
    }

    func updateUIView(_ view: GuestWindowPlaceholder, context: Context) {
        context.coordinator.hosting?.rootView = root(context.coordinator.regions)
        view.guest = window
        view.place()
    }

    static func dismantleUIView(_ view: GuestWindowPlaceholder, coordinator: Coordinator) {
        view.hideGuest()
    }
}

// MARK: - Mappa (CPMapTemplate)

struct CPMapTemplateView: View {
    @ObservedObject var session: GuestSession
    let map: CPMapTemplate

    var body: some View {
        GuestWindowHost(window: session.window, overlay: CPMapOverlay(session: session, map: map))
    }
}

/// Controlli del template mappa (barra, pulsanti, pannelli), disegnati sopra la mappa dell'app.
struct CPMapOverlay: View {
    @ObservedObject var session: GuestSession
    let map: CPMapTemplate

    var body: some View {
        let navigation = CPSHooks.navigationSession(for: map)
        let trips = CPSHooks.tripPreviews(for: map)
        let panning = CPSHooks.isPanning(for: map)

        ZStack(alignment: .topLeading) {
            Color.clear

            // Barra superiore: pulsanti dell'app
            HStack(spacing: 8) {
                if session.stack.count > 1 {
                    Button { session.back() } label: {
                        Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                    }
                    .buttonStyle(CPCapsuleButtonStyle())
                    .cpsHitRegion()
                }
                ForEach(Array((CPSObjC.get(map, NSSelectorFromString("leadingNavigationBarButtons")) as? [CPBarButton] ?? []).enumerated()), id: \.offset) { _, b in
                    CPBarButtonView(button: b, session: session).cpsHitRegion()
                }
                Spacer()
                ForEach(Array((CPSObjC.get(map, NSSelectorFromString("trailingNavigationBarButtons")) as? [CPBarButton] ?? []).enumerated()), id: \.offset) { _, b in
                    CPBarButtonView(button: b, session: session).cpsHitRegion()
                }
            }
            .padding(10)

            // Pannello sinistro: anteprima percorsi o indicazioni
            VStack(alignment: .leading, spacing: 8) {
                Spacer().frame(height: 52)
                if let navigation = navigation {
                    guidancePanel(navigation).cpsHitRegion()
                } else if !trips.isEmpty {
                    tripPanel(trips).cpsHitRegion()
                }
                Spacer(minLength: 0)
                if navigation != nil, let estimates = CPSHooks.tripEstimates(for: map) {
                    estimatesPanel(estimates).cpsHitRegion()
                }
            }
            .padding(10)

            // Pulsanti mappa a destra
            HStack {
                Spacer()
                VStack(spacing: 10) {
                    Spacer()
                    ForEach(Array((CPSObjC.get(map, NSSelectorFromString("mapButtons")) as? [CPMapButton] ?? []).enumerated()), id: \.offset) { _, button in
                        if !button.isHidden {
                            Button {
                                session.tap(handlerOf: button, label: "Pulsante mappa")
                            } label: {
                                Group {
                                    if let image = cpsOpt(button.image) {
                                        Image(uiImage: image).renderingMode(.template).resizable().scaledToFit().frame(width: 22, height: 22)
                                    } else {
                                        Image(systemName: "circle")
                                    }
                                }
                                .foregroundColor(.white)
                                .frame(width: 44, height: 44)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(white: 0.16).opacity(0.95)))
                            }
                            .buttonStyle(.plain)
                            .disabled(!button.isEnabled)
                            .cpsHitRegion()
                        }
                    }
                }
                .padding(10)
            }

            if panning {
                panningArrows
            }

            if let alert = CPSHooks.navigationAlert(for: map) {
                navigationAlert(alert)
            }

            // Alert / action sheet presentati sopra la mappa (la CPWindow copre la finestra principale)
            if let presented = session.presented {
                CPPresentedView(session: session, template: presented)
                    .cpsHitRegion()
            }

            if let err = session.lastError {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.yellow)
                        Text(err).font(.system(size: 12)).foregroundColor(.white).lineLimit(3)
                        Button { session.lastError = nil } label: {
                            Image(systemName: "xmark.circle.fill").foregroundColor(CP.secondaryText)
                        }
                    }
                    .padding(10)
                    .background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: 10))
                    .cpsHitRegion()
                    .padding(10)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var delegate: Any? { map.mapDelegate }

    // Indicazioni svolta per svolta
    private func guidancePanel(_ navigation: CPNavigationSession) -> some View {
        let maneuvers = navigation.upcomingManeuvers
        let cardColor = maneuvers.first.flatMap { CPSObjC.get($0, NSSelectorFromString("cardBackgroundColor")) as? UIColor }
        let bg = Color(cardColor ?? map.guidanceBackgroundColor)
        return VStack(alignment: .leading, spacing: 0) {
            if let m = maneuvers.first {
                maneuverRow(m, primary: true)
                    .padding(12)
                if maneuvers.count > 1 {
                    Rectangle().fill(Color.white.opacity(0.25)).frame(height: 0.5)
                    maneuverRow(maneuvers[1], primary: false)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
            } else {
                Text("Navigazione in corso")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(12)
            }
        }
        .frame(width: 280, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(bg == .clear ? Color(red: 0.13, green: 0.33, blue: 0.23) : bg))
    }

    private func maneuverRow(_ m: CPManeuver, primary: Bool) -> some View {
        let estimates = CPSHooks.estimates(for: m) ?? m.initialTravelEstimates
        return HStack(alignment: .top, spacing: 10) {
            if let image = cpsOpt(m.symbolImage) {
                Image(uiImage: image).renderingMode(.template).resizable().scaledToFit()
                    .frame(width: primary ? 44 : 22, height: primary ? 44 : 22)
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                if let e = estimates {
                    Text(Self.displayDistance(e))
                        .font(.system(size: primary ? 24 : 15, weight: .bold))
                        .foregroundColor(.white)
                }
                Text(cpsOpt(m.instructionVariants)?.first ?? "")
                    .font(.system(size: primary ? 17 : 14, weight: primary ? .semibold : .regular))
                    .foregroundColor(.white)
                    .lineLimit(primary ? 3 : 1)
            }
        }
    }

    private func estimatesPanel(_ e: CPTravelEstimates) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                Text(Formatters.arrival(after: e.timeRemaining)).font(.system(size: 19, weight: .semibold))
                Text("arrivo").font(.system(size: 12)).foregroundColor(CP.secondaryText)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(Formatters.duration(e.timeRemaining)).font(.system(size: 19, weight: .semibold))
                Text("tempo").font(.system(size: 12)).foregroundColor(CP.secondaryText)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(Self.displayDistance(e)).font(.system(size: 19, weight: .semibold))
                Text("distanza").font(.system(size: 12)).foregroundColor(CP.secondaryText)
            }
        }
        .foregroundColor(.white)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(CP.panel.opacity(0.95)))
    }

    // Anteprima percorsi
    private func tripPanel(_ trips: [CPTrip]) -> some View {
        let tripIndex = min(session.selectedTrip, trips.count - 1)
        let trip = trips[max(0, tripIndex)]
        let routes = trip.routeChoices
        let routeIndex = min(session.selectedRoute, max(0, routes.count - 1))
        let config = CPSHooks.tripTextConfiguration(for: map)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(cpsOpt(trip.destination.name) ?? "Destinazione")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Spacer()
                if trips.count > 1 {
                    Text("\(tripIndex + 1)/\(trips.count)")
                        .font(.system(size: 13))
                        .foregroundColor(CP.secondaryText)
                    Button {
                        session.selectedTrip = (tripIndex + 1) % trips.count
                        session.selectedRoute = 0
                        preview(trips[session.selectedTrip], route: 0)
                    } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(CPCapsuleButtonStyle())
                }
            }
            ForEach(Array(routes.enumerated()), id: \.offset) { i, route in
                Button {
                    session.selectedRoute = i
                    preview(trip, route: i)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.first(route.summaryVariants) ?? "Percorso \(i + 1)")
                            .font(.system(size: 16, weight: .semibold))
                        if let extra = Self.first(route.additionalInformationVariants) {
                            Text(extra).font(.system(size: 13)).foregroundColor(CP.secondaryText)
                        }
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(i == routeIndex ? Color(white: 0.25) : Color.clear))
                }
                .buttonStyle(.plain)
            }
            Button {
                guard routes.indices.contains(routeIndex), let d = delegate else { return }
                session.guest("Avvia") {
                    CPSObjC.send(d, NSSelectorFromString("mapTemplate:startedTrip:usingRouteChoice:"), map, trip, routes[routeIndex])
                }
            } label: {
                Text(cpsOpt(config?.startButtonTitle) ?? "Vai")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(CPCapsuleButtonStyle(prominent: true))
        }
        .padding(12)
        .frame(width: 300)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(CP.panel.opacity(0.96)))
        .onAppear { preview(trip, route: routeIndex) }
    }

    private func preview(_ trip: CPTrip, route: Int) {
        guard let d = delegate, trip.routeChoices.indices.contains(route) else { return }
        session.guest("Anteprima") {
            CPSObjC.send(d, NSSelectorFromString("mapTemplate:selectedPreviewForTrip:usingRouteChoice:"), map, trip, trip.routeChoices[route])
        }
    }

    private var panningArrows: some View {
        ZStack {
            VStack { arrow("chevron.up", 1 << 2); Spacer(); arrow("chevron.down", 1 << 3) }
            HStack { arrow("chevron.left", 1 << 0); Spacer(); arrow("chevron.right", 1 << 1) }
        }
        .padding(16)
    }

    private func arrow(_ symbol: String, _ direction: Int) -> some View {
        Button {
            guard let d = delegate else { return }
            session.guest("Panoramica") {
                CPSObjC.send(d, NSSelectorFromString("mapTemplate:panWithDirection:"), map, integer: direction)
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 48, height: 48)
                .background(Circle().fill(Color(white: 0.16).opacity(0.95)))
        }
        .buttonStyle(.plain)
        .cpsHitRegion()
    }

    private func navigationAlert(_ alert: CPNavigationAlert) -> some View {
        let subtitles: [String]? = alert.subtitleVariants
        return VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    if let img = cpsOpt(alert.image) {
                        Image(uiImage: img).resizable().scaledToFit().frame(width: 40, height: 40)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cpsOpt(alert.titleVariants)?.first ?? "")
                            .font(.system(size: 17, weight: .semibold))
                        if let s = subtitles?.first {
                            Text(s).font(.system(size: 14)).foregroundColor(CP.secondaryText)
                        }
                    }
                    .foregroundColor(.white)
                }
                HStack(spacing: 8) {
                    alertButton(alert.primaryAction, prominent: true)
                    if let secondary = cpsOpt(alert.secondaryAction) {
                        alertButton(secondary, prominent: false)
                    }
                }
            }
            .padding(14)
            .frame(width: 360)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(CP.panel))
            .cpsHitRegion()
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
    }

    private func alertButton(_ action: CPAlertAction, prominent: Bool) -> some View {
        Button {
            session.tap(handlerOf: action, label: action.title)
            CPSHooks.clearNavigationAlert(for: map)
        } label: {
            Text(action.title).frame(maxWidth: .infinity)
        }
        .buttonStyle(CPCapsuleButtonStyle(prominent: prominent))
    }

    /// Primo elemento di un array di varianti (opzionale o no nell'SDK).
    static func first(_ values: [String]?) -> String? {
        values?.first
    }

    /// Distanza da mostrare: distanceRemainingToDisplay (già arrotondata dall'app) se presente.
    static func displayDistance(_ e: CPTravelEstimates) -> String {
        if let shown = CPSObjC.get(e, NSSelectorFromString("distanceRemainingToDisplay")) as? NSMeasurement,
           let unit = shown.unit as? UnitLength {
            return format(Measurement(value: shown.doubleValue, unit: unit))
        }
        return format(e.distanceRemaining)
    }

    static func format(_ m: Measurement<UnitLength>) -> String {
        let f = MeasurementFormatter()
        f.unitOptions = .naturalScale
        f.numberFormatter.maximumFractionDigits = m.converted(to: .meters).value < 1000 ? 0 : 1
        f.locale = Locale(identifier: "it_IT")
        return f.string(from: m)
    }
}

// MARK: - Punti di interesse (CPPointOfInterestTemplate)

struct POIPin: Identifiable {
    let id: Int
    let coordinate: CLLocationCoordinate2D
}

struct CPPointOfInterestView: View {
    @ObservedObject var session: GuestSession
    let poi: CPPointOfInterestTemplate
    @State private var region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 41.9, longitude: 12.5),
                                                   span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1))

    var body: some View {
        let points = poi.pointsOfInterest
        let pins = points.enumerated().map { POIPin(id: $0.offset, coordinate: $0.element.location.placemark.coordinate) }
        HStack(spacing: 0) {
            panel(points)
                .frame(width: 300)
                .background(CP.background)
            Map(coordinateRegion: $region, annotationItems: pins) { pin in
                MapAnnotation(coordinate: pin.coordinate) {
                    Button { select(pin.id) } label: {
                        Group {
                            if let img = cpsOpt(points[pin.id].pinImage) {
                                Image(uiImage: img).resizable().scaledToFit().frame(width: 30, height: 30)
                            } else {
                                Image(systemName: "mappin.circle.fill")
                                    .font(.system(size: 30))
                                    .foregroundColor(session.selectedPOI == pin.id ? .blue : .red)
                            }
                        }
                        .background(Circle().fill(Color.white).frame(width: 22, height: 22))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .onAppear { fit(pins) }
    }

    @ViewBuilder
    private func panel(_ points: [CPPointOfInterest]) -> some View {
        if let index = session.selectedPOI, points.indices.contains(index) {
            let p = points[index]
            VStack(alignment: .leading, spacing: 8) {
                Button { session.selectedPOI = nil } label: {
                    Label("Elenco", systemImage: "chevron.left")
                }
                .buttonStyle(CPCapsuleButtonStyle())
                Text(cpsOpt(p.detailTitle) ?? p.title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
                if let s = cpsOpt(p.detailSubtitle) ?? cpsOpt(p.subtitle) {
                    Text(s).font(.system(size: 15)).foregroundColor(CP.secondaryText)
                }
                if let s = cpsOpt(p.detailSummary) ?? cpsOpt(p.summary) {
                    Text(s).font(.system(size: 14)).foregroundColor(CP.tertiaryText)
                }
                Spacer(minLength: 0)
                if let b = cpsOpt(p.primaryButton) { CPTextButtonView(session: session, button: b) }
                if let b = cpsOpt(p.secondaryButton) { CPTextButtonView(session: session, button: b) }
            }
            .padding(12)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(points.enumerated()), id: \.offset) { i, p in
                        Button { select(i) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.title).font(CP.rowFont).foregroundColor(.white).lineLimit(1)
                                if let s = cpsOpt(p.subtitle) {
                                    Text(s).font(CP.detailFont).foregroundColor(CP.secondaryText).lineLimit(1)
                                }
                                if let s = cpsOpt(p.summary) {
                                    Text(s).font(CP.detailFont).foregroundColor(CP.tertiaryText).lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: CP.rowMinHeight, alignment: .leading)
                            .padding(.horizontal, CP.horizontalPadding)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(CPRowButtonStyle())
                        Rectangle().fill(CP.separator).frame(height: 0.5).padding(.leading, CP.horizontalPadding)
                    }
                }
            }
        }
    }

    private func select(_ index: Int) {
        let points = poi.pointsOfInterest
        guard points.indices.contains(index) else { return }
        session.selectedPOI = index
        region.center = points[index].location.placemark.coordinate
        if let d = poi.pointOfInterestDelegate {
            session.guest("Punto di interesse") {
                CPSObjC.send(d, NSSelectorFromString("pointOfInterestTemplate:didSelectPointOfInterest:"), poi, points[index])
            }
        }
    }

    private func fit(_ pins: [POIPin]) {
        guard !pins.isEmpty else { return }
        let lats = pins.map { $0.coordinate.latitude }
        let lons = pins.map { $0.coordinate.longitude }
        guard let minLat = lats.min(), let maxLat = lats.max(), let minLon = lons.min(), let maxLon = lons.max() else { return }
        region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: max(0.01, (maxLat - minLat) * 1.4), longitudeDelta: max(0.01, (maxLon - minLon) * 1.4)))
    }
}
