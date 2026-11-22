import SwiftUI

/// Splash che rispecchia l'app: mappa animata nei colori del tema scelto, icone dei luoghi,
/// percorso che si disegna fino alla freccia dell'utente, logo su vetro e barra di caricamento.
struct SplashScreen: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var location: LocationManager
    @State private var progress: CGFloat = 0
    @State private var appeared = false
    @State private var start = Date()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                SplashMapBackground(theme: state.theme, start: start)

                // leggibilità di logo e barra
                LinearGradient(colors: [.black.opacity(0.55), .clear, .clear, .black.opacity(0.8)],
                               startPoint: .top, endPoint: .bottom)

                SplashUserArrow(color: Color(state.theme.arrowColor), accent: Color(state.theme.accent))
                    .position(x: geo.size.width / 2, y: geo.size.height * 0.58)

                VStack(spacing: 12) {
                    LogoView(size: 58)
                    Text("Il mondo reale, in stile videogioco")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.85))
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 22)
                .glassEffect(.regular.tint(Color.black.opacity(0.25)), in: RoundedRectangle(cornerRadius: 32, style: .continuous))
                .scaleEffect(appeared ? 1 : 0.92)
                .opacity(appeared ? 1 : 0)
                .position(x: geo.size.width / 2, y: geo.size.height * 0.27)

                VStack(spacing: 18) {
                    Spacer()
                    HStack(spacing: 8) {
                        Image(systemName: "globe.europe.africa.fill")
                        Text(state.theme.name)
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 36)
                    .glassEffect(.regular, in: Capsule())
                    .opacity(appeared ? 1 : 0)

                    // barra di caricamento — misure prese dal video (393×852 pt)
                    LoadingBar(progress: progress)
                        .frame(height: 21)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 51)
                }
            }
            .ignoresSafeArea()
        }
        .onAppear {
            start = Date()
            location.start()
            withAnimation(.spring(response: 0.7, dampingFraction: 0.8)) { appeared = true }
            withAnimation(.easeOut(duration: 1.1)) { progress = 0.62 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) {
                withAnimation(.easeInOut(duration: 0.7)) { progress = 1 }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
                state.finishSplash()
                GlobeTextureProvider.shared.preloadAll(Themes.all)
                // icone di tutti i temi pronte in anticipo: cambio tema immediato
                MapIcons.prewarm(state.theme)
                Themes.all.forEach { MapIcons.prewarm($0) }
            }
        }
    }
}

/// Città stilizzata generata una volta (strade, isolati, incroci) e disegnata con i colori del tema.
private struct SplashCity {
    struct Road { let a: CGPoint; let b: CGPoint; let major: Bool }
    let roads: [Road]
    let blocks: [CGRect]
    let pois: [CGPoint]
    let route: [CGPoint]

    static let shared = SplashCity()

    private init() {
        var rng = SeededGenerator(seed: 2024)
        let w: CGFloat = 1400, h: CGFloat = 1900
        var xs: [CGFloat] = []
        var x: CGFloat = -w / 2
        while x < w / 2 { xs.append(x); x += CGFloat.random(in: 70...120, using: &rng) }
        var ys: [CGFloat] = []
        var y: CGFloat = -h / 2
        while y < h / 2 { ys.append(y); y += CGFloat.random(in: 60...100, using: &rng) }
        // il centro (freccia utente) cade esattamente su un incrocio: le strade sono inclinate
        // (verticali +40 pt dall'alto in basso, orizzontali −30 pt da sinistra a destra), quindi le due strade
        // che passano per (0,0) partono da x = −20 e y = +15
        let i0 = xs.indices.min(by: { abs(xs[$0]) < abs(xs[$1]) }) ?? 0
        let j0 = ys.indices.min(by: { abs(ys[$0]) < abs(ys[$1]) }) ?? 0
        xs[i0] = -40 * 0.5
        ys[j0] = 30 * 0.5

        var roads: [Road] = []
        for (i, x) in xs.enumerated() {
            roads.append(Road(a: CGPoint(x: x, y: -h / 2), b: CGPoint(x: x + 40, y: h / 2), major: i % 4 == 0 || i == i0))
        }
        for (j, y) in ys.enumerated() {
            roads.append(Road(a: CGPoint(x: -w / 2, y: y), b: CGPoint(x: w / 2, y: y - 30), major: j % 3 == 0 || j == j0))
        }
        // diagonale
        roads.append(Road(a: CGPoint(x: -w / 2, y: h / 3), b: CGPoint(x: w / 2, y: -h / 3), major: true))
        self.roads = roads

        var blocks: [CGRect] = []
        for i in 0..<(xs.count - 1) {
            for j in 0..<(ys.count - 1) {
                let cellW = xs[i + 1] - xs[i], cellH = ys[j + 1] - ys[j]
                let n = Int.random(in: 1...3, using: &rng)
                for _ in 0..<n {
                    let bw = CGFloat.random(in: 0.25...0.45, using: &rng) * cellW
                    let bh = CGFloat.random(in: 0.25...0.45, using: &rng) * cellH
                    let bx = xs[i] + CGFloat.random(in: 8...(max(9, cellW - bw - 8)), using: &rng)
                    let by = ys[j] + CGFloat.random(in: 8...(max(9, cellH - bh - 8)), using: &rng)
                    blocks.append(CGRect(x: bx, y: by, width: bw, height: bh))
                }
            }
        }
        self.blocks = blocks

        var pois: [CGPoint] = []
        for _ in 0..<26 {
            let i = Int.random(in: 1..<(xs.count - 1), using: &rng)
            let j = Int.random(in: 1..<(ys.count - 1), using: &rng)
            pois.append(CGPoint(x: (xs[i] + xs[i + 1]) / 2, y: (ys[j] + ys[j + 1]) / 2))
        }
        self.pois = pois

        // percorso: dal basso fino al centro, lungo le strade
        // percorso lungo le strade vere (stesse inclinazioni): sale su una strada a destra, gira a sinistra
        // su una trasversale e risale sulla strada centrale fino a fermarsi esattamente sotto la freccia
        let iR = xs.firstIndex(where: { $0 > 150 }) ?? min(i0 + 2, xs.count - 1)
        let jB = ys.firstIndex(where: { $0 > 260 }) ?? min(j0 + 3, ys.count - 1)
        func vx(_ i: Int, _ y: CGFloat) -> CGFloat { xs[i] + 40 * (y + h / 2) / h }        // strada verticale i
        func hy(_ j: Int, _ x: CGFloat) -> CGFloat { ys[j] - 30 * (x + w / 2) / w }        // strada orizzontale j
        /// incrocio tra la verticale i e l'orizzontale j
        func cross(_ i: Int, _ j: Int) -> CGPoint {
            // x = xs[i] + 40(y + h/2)/h ;  y = ys[j] − 30(x + w/2)/w  → si risolve per y
            let a = 40 / h, b = 30 / w
            let y = (ys[j] - b * (xs[i] + a * h / 2) - b * w / 2) / (1 + a * b)
            return CGPoint(x: vx(i, y), y: y)
        }
        _ = hy
        self.route = [CGPoint(x: vx(iR, h / 2), y: h / 2), cross(iR, jB), cross(i0, jB), cross(i0, j0)]
    }
}

/// Colori della mappa del tema per la splash
private struct SplashPalette {
    let land: Color, road: Color, building: Color

    init(_ id: String) {
        switch id {
        case "palm": land = Color(hex: 0x5E9E48); road = Color(hex: 0x151515); building = Color(hex: 0xF4F4F2)
        case "dust": land = Color(hex: 0xD4C09A); road = Color(hex: 0x2C2A25); building = Color(hex: 0xC3AD89)
        case "bunker": land = Color(hex: 0x061206); road = Color(hex: 0x2CCF2C); building = Color(hex: 0x0B2A0B)
        case "pixel": land = Color(hex: 0x6E9050); road = Color(hex: 0x8E8E8E); building = Color(hex: 0xA8784A)
        case "neon": land = Color(hex: 0x070707); road = Color(hex: 0x4B9FB0); building = Color(hex: 0xB3204A)
        case "heat": land = Color(hex: 0x9B55DD); road = Color(hex: 0xAAB7C0); building = Color(hex: 0xB8A8FF, opacity: 0.35)
        case "kingdom": land = Color(hex: 0x97957F); road = Color(hex: 0xCACBBC); building = Color(hex: 0xA06E5E)
        case "contract": land = Color(hex: 0xC2C5C7); road = Color(hex: 0xD6D8DA); building = Color(hex: 0x9EA1A4)
        case "canyon": land = Color(hex: 0x1F2627); road = Color(hex: 0x8A8670); building = Color(hex: 0x46548A)
        case "crimson": land = Color(hex: 0xD2373A); road = Color(hex: 0xB8B8B8); building = Color(hex: 0xFFB0A8, opacity: 0.35)
        case "midnight": land = Color(hex: 0x3B4161); road = Color(hex: 0x8D97C6); building = Color(hex: 0x46548A)
        case "storm": land = Color(hex: 0x43722F); road = Color(hex: 0x222222); building = Color(hex: 0xA3A6A9)
        default: land = Color(hex: 0x161616); road = Color(hex: 0xB8B8B8); building = Color(hex: 0x353535)
        }
    }
}

private struct SplashMapBackground: View {
    let theme: MapTheme
    let start: Date

    private static let categories: [POICategory] = [.restaurant, .cafe, .fuel, .park, .shop, .hospital, .police,
                                                     .lodging, .museum, .supermarket, .bar, .parking, .cinema]

    var body: some View {
        let city = SplashCity.shared
        let pal = SplashPalette(theme.id)
        let icons: [UIImage] = SplashMapBackground.categories.compactMap { MapIcons.image(named: $0.imageName, theme: theme) }
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSince(start)
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(pal.land))
                var c = ctx
                c.translateBy(x: size.width / 2, y: size.height * 0.58)
                let zoom = 0.9 + 0.12 * min(t / 3, 1)
                c.scaleBy(x: zoom, y: zoom)
                c.rotate(by: .degrees(-16 + 4 * min(t / 3, 1)))

                for b in city.blocks {
                    c.fill(Path(roundedRect: b, cornerRadius: 2), with: .color(pal.building))
                }
                for r in city.roads {
                    var p = Path(); p.move(to: r.a); p.addLine(to: r.b)
                    c.stroke(p, with: .color(pal.road), style: StrokeStyle(lineWidth: r.major ? 11 : 5, lineCap: .round))
                }
                // percorso che si disegna fino alla posizione dell'utente
                var route = Path()
                route.addLines(city.route)
                let trim = min(max((t - 0.2) / 1.5, 0), 1)
                let drawn = route.trimmedPath(from: 0, to: trim)
                c.stroke(drawn, with: .color(.black.opacity(0.5)), style: StrokeStyle(lineWidth: 13, lineCap: .round, lineJoin: .round))
                c.stroke(drawn, with: .color(Color(theme.accent)), style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))

                // icone dei luoghi che compaiono una dopo l'altra
                if !icons.isEmpty {
                    for (i, p) in city.pois.enumerated() {
                        let appear = min(max((t - 0.15 - Double(i) * 0.07) / 0.25, 0), 1)
                        guard appear > 0 else { continue }
                        let img = c.resolve(Image(uiImage: icons[i % icons.count]))
                        let s = 30 * appear / zoom
                        var ic = c
                        ic.translateBy(x: p.x, y: p.y)
                        ic.rotate(by: .degrees(16 - 4 * min(t / 3, 1)))   // icone sempre dritte
                        ic.opacity = appear
                        ic.draw(img, in: CGRect(x: -s / 2, y: -s / 2, width: s, height: s))
                    }
                }
            }
        }
    }
}

/// Freccia dell'utente con mirino e impulso, come sulla mappa
private struct SplashUserArrow: View {
    let color: Color
    let accent: Color
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(accent.opacity(pulse ? 0 : 0.8), lineWidth: 3)
                .frame(width: pulse ? 120 : 30, height: pulse ? 120 : 30)
            Rectangle().fill(LinearGradient(colors: [.clear, .white.opacity(0.6), .clear], startPoint: .leading, endPoint: .trailing))
                .frame(width: 320, height: 1)
            Rectangle().fill(LinearGradient(colors: [.clear, .white.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom))
                .frame(width: 1, height: 260)
            ArrowShape(half: .left).fill(color)
                .frame(width: 34, height: 40)
            ArrowShape(half: .right).fill(color.opacity(0.78))
                .frame(width: 34, height: 40)
        }
        .shadow(color: .black.opacity(0.6), radius: 6, y: 3)
        .onAppear {
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
        }
    }

    private struct ArrowShape: Shape {
        enum Half { case left, right }
        let half: Half
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: half == .left ? r.minX : r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY - r.height * 0.24))
            p.closeSubpath()
            return p
        }
    }
}


/// Scritta "GassMaps" nel font di GTA San Andreas (Pricedown): riempimento bianco, contorno nero spesso.
struct LogoView: View {
    var size: CGFloat = 66

    var body: some View {
        let text = Text("GassMaps").font(FontRegistry.gta(size: size))
        ZStack {
            // contorno nero (16 copie spostate) + ombra
            ForEach(0..<16, id: \.self) { i in
                let a = CGFloat(i) / 16 * 2 * .pi
                text.foregroundStyle(.black)
                    .offset(x: cos(a) * size * 0.06, y: sin(a) * size * 0.06)
            }
            text.foregroundStyle(.white)
        }
        .shadow(color: .black.opacity(0.8), radius: 0, x: size * 0.04, y: size * 0.06)
        .shadow(color: .black.opacity(0.6), radius: 14)
        .fixedSize()
    }
}

/// Barra di caricamento identica al video: traccia scura e riempimento blu "a tubo" lucido.
struct LoadingBar: View {
    var progress: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(hex: 0x181818))
                Capsule()
                    .fill(
                        LinearGradient(stops: [
                            .init(color: Color(hex: 0x68BBFE), location: 0.0),
                            .init(color: Color(hex: 0x359CFF), location: 0.18),
                            .init(color: Color(hex: 0x1784FF), location: 0.34),
                            .init(color: Color(hex: 0x0970FF), location: 0.5),
                            .init(color: Color(hex: 0x0B64FF), location: 0.64),
                            .init(color: Color(hex: 0x1A5DFF), location: 0.76),
                            .init(color: Color(hex: 0x3564FE), location: 0.88),
                            .init(color: Color(hex: 0x6983ED), location: 1.0)
                        ], startPoint: .top, endPoint: .bottom)
                    )
                    .frame(width: max(15, (geo.size.width - 6) * progress), height: geo.size.height - 6)
                    .padding(.leading, 3)
                    .shadow(color: Color(hex: 0x0970FF).opacity(0.55), radius: 5)
            }
        }
    }
}
