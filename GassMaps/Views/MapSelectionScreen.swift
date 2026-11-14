import SwiftUI
import MapLibre
import CoreLocation

struct MapSelectionScreen: View {
    @EnvironmentObject var state: AppState
    @State private var index: Int = Themes.defaultIndex
    @State private var globeTheme: MapTheme = Themes.all[Themes.defaultIndex]
    @State private var globeOffset: CGFloat = 0
    @State private var transitioning = false
    @State private var didAppear = false
    @State private var globeInteraction = GlobeInteraction()
    @State private var lastDrag: CGSize = .zero
    /// animazione d'ingresso dal punto GPS: mappa che si allontana → globo
    @State private var introMapVisible = true
    @State private var introCenter: CLLocationCoordinate2D?
    @State private var introZoom: Double = 15
    @State private var glowVisible = false
    @State private var introHolder = IntroMapHolder()
    @State private var introDriver: GlobeIntroDriver?

    private var theme: MapTheme { Themes.all[index] }

    var body: some View {
        GeometryReader { geo in
            let fullHeight = geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom

            VStack(spacing: 0) {
                // intestazione
                HStack(spacing: 14) {
                    BackCircleButton { state.showMapSelection = false }
                    Text("Selezione mappa 🎨")
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundStyle(.white)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                Spacer(minLength: 0)

                // nome tema + frecce
                GlassEffectContainer(spacing: 20) {
                    HStack {
                        arrowButton("arrow.left") { move(-1) }
                        Spacer()
                        Text(theme.name)
                            .font(.system(size: 24, weight: .heavy))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.45), radius: 6)
                            .id(theme.id)
                            .transition(.opacity)
                        Spacer()
                        arrowButton("arrow.right") { move(1) }
                    }
                }
                .padding(.horizontal, 20)

                PageDots(count: Themes.all.count, index: index)
                    .padding(.top, 26)
                    .padding(.bottom, 26)

                // Continua (Liquid Glass) — 17 pt sopra la home bar, come nel video
                GlassCapsuleButton(title: "Continua", icon: "arrow.right.circle.fill", height: 54,
                                   tint: Color.white.opacity(transitioning ? 0.35 : 0.88),
                                   foreground: .black) {
                    state.themeIndex = index
                    state.showMapSelection = false
                }
                .disabled(transitioning)
                .padding(.horizontal, 24)
                .padding(.bottom, 17)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .background {
                ZStack {
                    theme.backgroundTop
                    StarField()
                        .opacity(theme.id == "pixel" ? 0.35 : 1)
                    ZStack {
                        GlobeView(theme: globeTheme, height: fullHeight, interaction: globeInteraction)
                        GlobeGlow(size: CGSize(width: geo.size.width, height: fullHeight),
                                  glow: Color(globeTheme.glow), core: Color(globeTheme.glowCore))
                            .opacity(glowVisible ? 1 : 0)
                    }
                    .frame(width: geo.size.width, height: fullHeight)
                    .offset(y: globeOffset)
                    .opacity(didAppear ? 1 : 0)
                    // la mappa del tema dal tuo punto GPS che si allontana (prima parte dell'ingresso)
                    if introMapVisible, let c = introCenter {
                        IntroZoomMap(theme: state.theme, center: c, startZoom: introZoom, holder: introHolder,
                                     topInset: GlobeIntroDriver.gpsOffset(height: fullHeight) * 2)
                            .frame(width: geo.size.width, height: fullHeight)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.5), value: index)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            // trascinando il globo lo si ruota; al rilascio prosegue con inerzia e poi riprende la rotazione automatica
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        let delta = CGSize(width: value.translation.width - lastDrag.width,
                                           height: value.translation.height - lastDrag.height)
                        lastDrag = value.translation
                        globeInteraction.changed(delta: delta)
                    }
                    .onEnded { value in
                        lastDrag = .zero
                        globeInteraction.ended(velocity: value.velocity)
                    }
            )
        }
        .onAppear {
            index = state.themeIndex
            globeTheme = state.theme
            startIntro()
        }
    }

    /// Ingresso come nel video, in un unico movimento continuo:
    /// la mappa del tema parte dal punto GPS e si allontana sempre più veloce; quando arriva alla scala di una nazione
    /// si dissolve nel globo, che ha la stessa scala e il punto GPS nello stesso punto dello schermo,
    /// e il globo continua ad allontanarsi rallentando fino alla vista normale.
    private func startIntro() {
        guard let c = state.location.location?.coordinate ?? state.map.centerCoordinate else {
            introMapVisible = false
            glowVisible = true
            withAnimation(.easeOut(duration: 0.5)) { didAppear = true }
            return
        }
        introCenter = c
        introZoom = min(max(state.map.mapView?.zoomLevel ?? 15, 12), 17)
        introMapVisible = true
        didAppear = false
        glowVisible = false
        transitioning = true
        let driver = GlobeIntroDriver(holder: introHolder, interaction: globeInteraction, center: c, startZoom: introZoom)
        driver.onCrossfade = {
            withAnimation(.easeInOut(duration: 0.28)) {
                didAppear = true
                introMapVisible = false
            }
        }
        driver.onFinish = {
            withAnimation(.easeOut(duration: 0.5)) { glowVisible = true }
            transitioning = false
            introDriver = nil
        }
        introDriver = driver
        driver.start()
    }

    private func arrowButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            GlassCircle(size: 46) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .opacity(transitioning ? 0.45 : 1)
        .disabled(transitioning)
    }

    private func move(_ delta: Int) {
        guard !transitioning else { return }
        let count = Themes.all.count
        let next = (index + delta + count) % count
        transitioning = true
        withAnimation(.easeIn(duration: 0.32)) {
            globeOffset = 900
        }
        withAnimation(.easeInOut(duration: 0.3)) {
            index = next
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
            globeTheme = Themes.all[next]
            withAnimation(.spring(response: 0.7, dampingFraction: 0.86)) {
                globeOffset = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                transitioning = false
            }
        }
    }
}

struct PageDots: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(Color.white.opacity(i == index ? 1 : 0.4))
                    .frame(width: i == index ? 22 : 6, height: 6)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: index)
    }
}

struct StarField: View {
    private struct Star { let x: CGFloat; let y: CGFloat; let r: CGFloat; let a: Double }

    private let stars: [Star] = {
        var gen = SeededGenerator(seed: 42)
        return (0..<170).map { _ in
            Star(x: CGFloat.random(in: 0...1, using: &gen),
                 y: CGFloat.random(in: 0...1, using: &gen),
                 r: CGFloat.random(in: 0.4...1.3, using: &gen),
                 a: Double.random(in: 0.25...0.9, using: &gen))
        }
    }()

    var body: some View {
        Canvas { ctx, size in
            for s in stars {
                let rect = CGRect(x: s.x * size.width, y: s.y * size.height, width: s.r * 2, height: s.r * 2)
                ctx.fill(Path(ellipseIn: rect), with: .color(.white.opacity(s.a)))
            }
        }
        .allowsHitTesting(false)
    }
}

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}


/// Riferimento alla mappa dell'ingresso (creata da SwiftUI, animata da GlobeIntroDriver)
final class IntroMapHolder {
    weak var map: MLNMapView?
}

/// Anima l'ingresso fotogramma per fotogramma (60/120 Hz) con CADisplayLink: zoom della mappa e scala del globo
/// sono la stessa curva continua, così il passaggio mappa → globo non ha salti.
final class GlobeIntroDriver {
    /// livello di zoom a cui il globo, alla scala 1, ha la stessa dimensione della vista normale (dal video)
    static let globeZoom = GlobeCoordinator.zoom
    /// zoom a cui la mappa lascia il posto al globo
    static let handoffZoom = 4.35
    static let mapDuration: CFTimeInterval = 0.95
    static let globeDuration: CFTimeInterval = 1.1

    /// il punto guardato dal globo sta 150 pt (su 852) sotto il centro: anche la mappa mette lì il punto GPS
    static func gpsOffset(height: CGFloat) -> CGFloat {
        CGFloat(GlobeCoordinator.targetOffsetPt / GlobeCoordinator.screenRefHeight) * height
    }

    private let holder: IntroMapHolder
    private let interaction: GlobeInteraction
    private let center: CLLocationCoordinate2D
    private let startZoom: Double
    private var link: CADisplayLink?
    private var startTime: CFTimeInterval = 0
    private var crossfaded = false
    var onCrossfade: (() -> Void)?
    var onFinish: (() -> Void)?

    init(holder: IntroMapHolder, interaction: GlobeInteraction, center: CLLocationCoordinate2D, startZoom: Double) {
        self.holder = holder
        self.interaction = interaction
        self.center = center
        self.startZoom = startZoom
    }

    func start() {
        // il globo si prepara subito (invisibile) già orientato sul punto GPS e alla scala d'incontro
        interaction.startIntro(lat: center.latitude, lon: center.longitude,
                               scale: Float(min(pow(2, startZoom - GlobeIntroDriver.globeZoom), 2.8)))
        startTime = CACurrentMediaTime() + 0.08      // un attimo per far apparire la mappa
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick() {
        let t = CACurrentMediaTime() - startTime
        guard t >= 0 else { return }
        let md = GlobeIntroDriver.mapDuration
        if t < md {
            // mappa: si allontana accelerando (zoom in scala logaritmica, come il video)
            let p = t / md
            let e = p * p * (3 - 2 * p) * 0.35 + p * p * 0.65      // partenza dolce, poi accelera
            let z = startZoom + (GlobeIntroDriver.handoffZoom - startZoom) * e
            holder.map?.setZoomLevel(z, animated: false)
            // oltre ~2,8 volte la camera entrerebbe nella sfera: finché è nascosto il globo resta a quella scala
            interaction.setIntroScale(Float(min(pow(2, z - GlobeIntroDriver.globeZoom), 2.8)))
            if !crossfaded && p > 0.93 {
                crossfaded = true
                onCrossfade?()
            }
        } else {
            if !crossfaded { crossfaded = true; onCrossfade?() }
            // globo: continua ad allontanarsi alla stessa velocità e poi rallenta fino alla scala 1
            let q = min((t - md) / GlobeIntroDriver.globeDuration, 1)
            let e = 1 - pow(1 - q, 3)
            let z = GlobeIntroDriver.handoffZoom + (GlobeIntroDriver.globeZoom - GlobeIntroDriver.handoffZoom) * e
            interaction.setIntroScale(Float(pow(2, z - GlobeIntroDriver.globeZoom)))
            if q >= 1 {
                interaction.endIntro()
                link?.invalidate()
                link = nil
                onFinish?()
            }
        }
    }

    deinit { link?.invalidate() }
}

/// Mappa del tema centrata sul punto GPS che si allontana fino alla scala di una nazione
/// (prima parte dell'animazione d'ingresso nella Selezione mappa).
struct IntroZoomMap: UIViewRepresentable {
    let theme: MapTheme
    let center: CLLocationCoordinate2D
    let startZoom: Double
    let holder: IntroMapHolder
    /// il punto GPS va nella stessa posizione dello schermo del punto guardato dal globo
    let topInset: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(theme: theme) }

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero, styleURL: theme.styleURL)
        map.delegate = context.coordinator
        map.logoView.isHidden = true
        map.attributionButton.isHidden = true
        map.compassView.isHidden = true
        map.isUserInteractionEnabled = false
        map.backgroundColor = .black
        map.contentInset = UIEdgeInsets(top: topInset, left: 0, bottom: 0, right: 0)
        map.setCenter(center, zoomLevel: startZoom, direction: 0, animated: false)
        // stessa inclinazione della camera del globo: il passaggio è continuo
        let cam = map.camera
        cam.pitch = CGFloat(GlobeCoordinator.pitchDeg)
        map.setCamera(cam, animated: false)
        holder.map = map
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {}

    final class Coordinator: NSObject, MLNMapViewDelegate {
        let theme: MapTheme
        init(theme: MapTheme) { self.theme = theme }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            MapIcons.install(in: style, theme: theme)
        }

        func mapView(_ mapView: MLNMapView, didFailToLoadImage imageName: String) -> UIImage? {
            MapIcons.image(named: imageName, theme: theme)
        }
    }
}
