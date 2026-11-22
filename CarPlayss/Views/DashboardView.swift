import MapKit
import SwiftUI

/// Dashboard: mappa grande + widget riproduzione e calendario/meteo.
struct DashboardView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var media: MediaController
    @EnvironmentObject var nav: NavigationModel
    @EnvironmentObject var runtime: GuestRuntime

    /// App di navigazione con Dashboard: la più recente tra quelle in esecuzione.
    private var dashboardSession: GuestSession? {
        for item in state.recents {
            if case .guest(let id) = item, let s = runtime.sessions[id], s.dashboardWindow != nil { return s }
        }
        return runtime.sessions.values.first { $0.dashboardWindow != nil }
    }

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 10
            let sideWidth = max(200, geo.size.width * 0.36)
            HStack(spacing: spacing) {
                Group {
                    if let session = dashboardSession, let window = session.dashboardWindow {
                        GuestWindowHost(window: window, overlay: GuestDashboardOverlay(session: session) {
                            state.open(.guest(session.app.id))
                        })
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    } else {
                        mapCard
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(spacing: spacing) {
                    nowPlayingCard
                    nextEventCard
                }
                .frame(width: sideWidth)
            }
            .padding(spacing)
        }
    }

    // MARK: Mappa

    private var mapCard: some View {
        ZStack(alignment: .bottomLeading) {
            MiniMapView()
                .allowsHitTesting(false)
            LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 4) {
                if nav.phase == .navigating, let step = nav.currentStep {
                    HStack(spacing: 10) {
                        Image(systemName: Formatters.maneuverSymbol(for: step.instructions))
                            .font(.system(size: 26, weight: .bold))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Formatters.distance(nav.distanceToNextManeuver))
                                .font(.system(size: 20, weight: .bold))
                            Text(step.instructions)
                                .font(.system(size: 14))
                                .lineLimit(2)
                        }
                    }
                    Text("Arrivo \(Formatters.arrival(after: nav.remainingTime)) · \(Formatters.distance(nav.remainingDistance))")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                } else {
                    Text("Dove vuoi andare?")
                        .font(.system(size: 20, weight: .bold))
                    Text("Tocca per aprire Mappe")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.8))
                }
            }
            .foregroundColor(.white)
            .padding(16)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { state.open(.maps) }
    }

    // MARK: Riproduzione

    private var nowPlayingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ArtworkView(image: media.artwork, hue: media.hue,
                            symbol: media.source == .radio ? "dot.radiowaves.left.and.right" : "music.note",
                            cornerRadius: 10)
                    .frame(width: 58, height: 58)
                VStack(alignment: .leading, spacing: 2) {
                    Text(media.title)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                    Text(media.artist.isEmpty ? "Tocca per scegliere" : media.artist)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if media.duration > 0 {
                ProgressView(value: min(media.elapsed, media.duration), total: media.duration)
                    .tint(.white)
            }
            HStack {
                Spacer()
                Button { media.previous() } label: { Image(systemName: "backward.fill") }
                Spacer()
                Button { media.togglePlayPause() } label: {
                    Image(systemName: media.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 26))
                }
                Spacer()
                Button { media.next() } label: { Image(systemName: "forward.fill") }
                Spacer()
            }
            .font(.system(size: 20))
            .buttonStyle(PressableStyle())
            .foregroundStyle(.primary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
        .contentShape(Rectangle())
        .onTapGesture { state.open(.nowPlaying) }
    }

    // MARK: Calendario / meteo

    private var nextEventCard: some View {
        let now = Date()
        let event = CalendarEvent.today.first { $0.start.addingTimeInterval(Double($0.minutes) * 60) > now }
        let weather = WeatherSample.current
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: weather.symbol)
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 22))
                Text("\(weather.temperature)°")
                    .font(.system(size: 22, weight: .semibold))
                Text(weather.condition)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .onTapGesture { state.open(.weather) }
            Divider()
            if let event = event {
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.hue(event.hue))
                        .frame(width: 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                        Text("\(timeString(event.start)) · \(event.location)")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxHeight: 44)
                .onTapGesture { state.open(.calendar) }
            } else {
                Text("Nessun altro evento oggi")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

/// Mappa non interattiva per la Dashboard, centrata sulla posizione.
struct MiniMapView: UIViewRepresentable {
    @EnvironmentObject var settings: SettingsStore

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.showsUserLocation = true
        map.isUserInteractionEnabled = false
        map.showsCompass = false
        map.pointOfInterestFilter = .includingAll
        map.setUserTrackingMode(.follow, animated: false)
        let rome = CLLocationCoordinate2D(latitude: 41.9028, longitude: 12.4964)
        map.setRegion(MKCoordinateRegion(center: rome, latitudinalMeters: 3000, longitudinalMeters: 3000), animated: false)
        map.setUserTrackingMode(.follow, animated: false)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        map.overrideUserInterfaceStyle = settings.appearance == .light ? .light : (settings.appearance == .dark ? .dark : .unspecified)
    }
}

/// Scorciatoie della Dashboard di un'app (CPDashboardButton) sopra la sua mappa.
/// Toccando la mappa si apre l'app, come su CarPlay.
struct GuestDashboardOverlay: View {
    @ObservedObject var session: GuestSession
    let openApp: () -> Void

    var body: some View {
        let _ = session.tick
        let buttons = session.dashboardController?.shortcutButtons ?? []
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture(perform: openApp)
                .cpsHitRegion()
            if !buttons.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(buttons.enumerated()), id: \.offset) { _, button in
                        Button {
                            session.tap(handlerOf: button, label: "Scorciatoia")
                            openApp()
                        } label: {
                            HStack(spacing: 8) {
                                if let img = cpsOpt(button.image) {
                                    Image(uiImage: img).resizable().scaledToFit().frame(width: 28, height: 28)
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(cpsOpt(button.titleVariants)?.first ?? "")
                                        .font(.system(size: 14, weight: .semibold))
                                        .lineLimit(1)
                                    if let sub = cpsOpt(button.subtitleVariants)?.first {
                                        Text(sub).font(.system(size: 12)).foregroundColor(CP.secondaryText).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(CP.panel.opacity(0.95)))
                        }
                        .buttonStyle(.plain)
                        .cpsHitRegion()
                    }
                }
                .padding(10)
            }
        }
    }
}
