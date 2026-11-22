import UIKit
import MapLibre

/// Categorie dei luoghi mostrate sulla mappa (devono coincidere con POI_CATEGORIES in tools/generate_styles.py).
/// Ogni categoria ha la sua icona: niente più raggruppamenti (es. supermercato ≠ abbigliamento).
enum POICategory: String, CaseIterable {
    case park, garden, playground, dog, cinema, theatre, rail, bus, library, fuel, charging,
         restaurant, fastfood, cafe, bakery, icecream, bar, nightclub, supermarket, shop, clothes,
         shoes, jewelry, pharmacy, hospital, clinic, police, fire, bank, atm, lodging, camping,
         school, university, parking, bicycle, sport, swimming, fitness, worship, museum,
         attraction, monument, townhall, post, car, carrepair, hairdresser, toilets, `default`

    var imageName: String { "gm-poi-\(rawValue)" }

    /// Glifo SF di base della categoria (ogni tema può sostituirlo).
    var baseGlyph: String {
        switch self {
        case .park: return "tree.fill"
        case .garden: return "camera.macro"
        case .playground: return "figure.play"
        case .dog: return "dog.fill"
        case .cinema: return "film.fill"
        case .theatre: return "theatermasks.fill"
        case .rail: return "tram.fill"
        case .bus: return "bus.fill"
        case .library: return "books.vertical.fill"
        case .fuel: return "fuelpump.fill"
        case .charging: return "bolt.car.fill"
        case .restaurant: return "fork.knife"
        case .fastfood: return "takeoutbag.and.cup.and.straw.fill"
        case .cafe: return "cup.and.saucer.fill"
        case .bakery: return "birthday.cake.fill"
        case .icecream: return "snowflake"
        case .bar: return "wineglass.fill"
        case .nightclub: return "music.note"
        case .supermarket: return "cart.fill"
        case .shop: return "bag.fill"
        case .clothes: return "tshirt.fill"
        case .shoes: return "shoe.fill"
        case .jewelry: return "suit.diamond.fill"
        case .pharmacy: return "pills.fill"
        case .hospital: return "cross.case.fill"
        case .clinic: return "stethoscope"
        case .police: return "shield.fill"
        case .fire: return "flame.fill"
        case .bank: return "banknote.fill"
        case .atm: return "creditcard.fill"
        case .lodging: return "bed.double.fill"
        case .camping: return "tent.fill"
        case .school: return "graduationcap.fill"
        case .university: return "studentdesk"
        case .parking: return "parkingsign"
        case .bicycle: return "bicycle"
        case .sport: return "sportscourt.fill"
        case .swimming: return "figure.pool.swim"
        case .fitness: return "dumbbell.fill"
        case .worship: return MapIcons.churchGlyph   // edificio di culto, non la croce (sembrava un ospedale)
        case .museum: return "building.columns.fill"
        case .attraction: return "star.fill"
        case .monument: return "flag.fill"
        case .townhall: return "bell.fill"
        case .post: return "envelope.fill"
        case .car: return "car.fill"
        case .carrepair: return "wrench.and.screwdriver.fill"
        case .hairdresser: return "scissors"
        case .toilets: return "toilet.fill"
        case .default: return "mappin"
        }
    }
}

/// Come viene "incorniciata" l'icona, nello stile del gioco a cui si ispira il tema.
enum IconFrame {
    /// glifo con contorno
    case outline(halo: UIColor)
    /// glifo chiaro su disco scuro con anello
    case badge(fill: UIColor, ring: UIColor)
    /// glifo dentro un esagono
    case hexagon(fill: UIColor, ring: UIColor)
    /// glifo pixelato su griglia 16×16 (stesse dimensioni degli sprite)
    case pixel(halo: UIColor)
    /// mappa tattica: quadrato nero con glifo bianco e angolari bianchi
    case tactical(fill: UIColor, bracket: UIColor)
    /// segnaposto tondo a goccia colorato per categoria con glifo scuro (Midnight Route)
    case teardrop(glyph: UIColor)
}

struct ThemeIconSet {
    let frame: IconFrame
    /// colore predefinito dei glifi
    let tint: UIColor
    /// colori specifici per categoria
    var colors: [POICategory: UIColor] = [:]
    /// glifi sostitutivi per categoria
    var glyphs: [POICategory: String] = [:]
    /// icona predefinita: quadrifoglio viola (Vice Noir)
    var cloverDefault = false
    /// icona predefinita: segnaposto rosso (Palm Coast)
    var redPinDefault = false

    func glyph(_ c: POICategory) -> String { glyphs[c] ?? c.baseGlyph }
    func color(_ c: POICategory) -> UIColor { colors[c] ?? tint }
}

enum MapIcons {
    // MARK: Set di icone per tema

    static func iconSet(for theme: MapTheme) -> ThemeIconSet {
        let w = UIColor.white
        switch theme.id {
        case "canyon": // stesse icone di Vice Noir, ma gialle, blu e rosse con contorno nero
            let yellow = UIColor(hex: 0xF2D21B), blue = UIColor(hex: 0x2F7BFF), red = UIColor(hex: 0xE8322E)
            var colors: [POICategory: UIColor] = [:]
            for c in [POICategory.police, .fire, .hospital, .clinic, .pharmacy, .carrepair, .fuel, .nightclub, .bar] { colors[c] = red }
            for c in [POICategory.rail, .bus, .parking, .car, .charging, .bicycle, .swimming, .atm, .bank, .post,
                      .lodging, .school, .university, .library] { colors[c] = blue }
            return ThemeIconSet(frame: .outline(halo: .black), tint: yellow, colors: colors,
                                glyphs: [.shop: "basket.fill", .police: "star.circle.fill"],
                                cloverDefault: true)

        case "noir", "crimson": // icone nere con contorno bianco (Crimson Heat usa le stesse di Vice Noir)
            return ThemeIconSet(frame: .outline(halo: .white), tint: .black,
                                glyphs: [.shop: "basket.fill", .police: "star.circle.fill"],
                                cloverDefault: true)

        case "palm": // icone colorate con contorno blu notte, segnaposto rosso
            let gold = UIColor(hex: 0xE0B040), red = UIColor(hex: 0xE02424), blue = UIColor(hex: 0x2F5FD0)
            let green = UIColor(hex: 0x4FA45A), light = UIColor(hex: 0xE8E8E8)
            return ThemeIconSet(frame: .outline(halo: UIColor(hex: 0x283848)), tint: light, colors: [
                .park: green, .garden: UIColor(hex: 0xE0505A), .playground: gold, .dog: UIColor(hex: 0xC98A3A),
                .cinema: light, .theatre: UIColor(hex: 0xF2D03A), .rail: gold, .bus: gold, .library: gold,
                .fuel: red, .charging: UIColor(hex: 0x3DD06A), .fastfood: UIColor(hex: 0xF29A2E),
                .bakery: UIColor(hex: 0xF2C88A), .icecream: UIColor(hex: 0xF5A3C8), .bar: UIColor(hex: 0x6EE0F0),
                .nightclub: UIColor(hex: 0xC07BFF), .supermarket: gold, .shop: UIColor(hex: 0xF29A2E),
                .clothes: UIColor(hex: 0xF5C9D6), .shoes: UIColor(hex: 0xC98A3A), .jewelry: UIColor(hex: 0x6EE0F0),
                .pharmacy: UIColor(hex: 0x3DD06A), .hospital: red, .clinic: red, .police: gold, .fire: red,
                .bank: green, .atm: green, .camping: green, .school: UIColor(hex: 0xD9A93A), .university: gold,
                .parking: blue, .bicycle: blue, .swimming: UIColor(hex: 0x4AB0F0), .worship: UIColor(hex: 0xD9B03A),
                .attraction: gold, .monument: gold, .townhall: gold, .post: UIColor(hex: 0xF0EAD8),
                .car: blue, .carrepair: red, .toilets: UIColor(hex: 0x4AB0F0)
            ], cloverDefault: true)

        case "dust": // dischi scuri western
            return ThemeIconSet(frame: .badge(fill: UIColor(hex: 0x1A120A), ring: UIColor(hex: 0xEADBB8)), tint: w,
                                glyphs: [.rail: "train.side.front.car", .bar: "mug.fill", .parking: "figure.equestrian.sports",
                                         .car: "figure.equestrian.sports", .bank: "dollarsign",
                                         .police: "star.fill", .default: "dollarsign"])

        case "bunker": // esagoni verdi
            let g = UIColor(hex: 0x5DFF5D)
            return ThemeIconSet(frame: .hexagon(fill: UIColor(hex: 0x031203), ring: g), tint: g,
                                glyphs: [.fuel: "bolt.fill", .default: "atom"])

        case "pixel": // pixel art: sprite disegnati + glifi pixelati colorati, tutti 16×16
            return ThemeIconSet(frame: .pixel(halo: UIColor(hex: 0x1D1D1D)), tint: UIColor(hex: 0xBDBDBD), colors: [
                .garden: UIColor(hex: 0xE02424), .playground: UIColor(hex: 0xF2B233), .dog: UIColor(hex: 0xF4F1E8),
                .cinema: UIColor(hex: 0xBDBDBD), .theatre: UIColor(hex: 0xF2D03A), .rail: UIColor(hex: 0x9E9E9E),
                .bus: UIColor(hex: 0xF2B233), .fuel: UIColor(hex: 0xFF8A1F), .charging: UIColor(hex: 0xF2E233),
                .fastfood: UIColor(hex: 0xE8A33A), .icecream: UIColor(hex: 0xF5A3C8), .nightclub: UIColor(hex: 0xC07BFF),
                .shoes: UIColor(hex: 0x8B5A2B), .jewelry: UIColor(hex: 0x3FE0E0), .clinic: UIColor(hex: 0xF0F0F0),
                .fire: UIColor(hex: 0xFF6A1F), .camping: UIColor(hex: 0x4FAF2F), .university: UIColor(hex: 0x8B5A2B),
                .bicycle: UIColor(hex: 0x9E9E9E), .sport: UIColor(hex: 0xF0F0F0), .swimming: UIColor(hex: 0x4A7BD8),
                .fitness: UIColor(hex: 0x9E9E9E), .worship: UIColor(hex: 0xC07BFF), .museum: UIColor(hex: 0xBDBDBD),
                .attraction: UIColor(hex: 0xF2C230), .monument: UIColor(hex: 0x9E9E9E), .car: UIColor(hex: 0x9E9E9E),
                .carrepair: UIColor(hex: 0x9E9E9E), .hairdresser: UIColor(hex: 0xD8D8D8), .toilets: UIColor(hex: 0x4A7BD8),
                .lodging: UIColor(hex: 0xD8332E)
            ])

        case "neon": // esagoni neri con glifo bianco
            return ThemeIconSet(frame: .hexagon(fill: UIColor(hex: 0x050506), ring: UIColor(hex: 0x1C2226)), tint: w,
                                glyphs: [.police: "star.circle.fill", .lodging: "building.2.fill",
                                         .default: "arrow.up.and.down.and.arrow.left.and.right"])

        case "contract": // quadrati neri con glifo bianco; polizia, pompieri e ospedali in rosso
            let red = UIColor(hex: 0xD8333A)
            return ThemeIconSet(frame: .tactical(fill: UIColor(hex: 0x111111), bracket: w), tint: w,
                                colors: [.police: red, .fire: red, .hospital: red],
                                glyphs: [.attraction: "camera.fill", .museum: "camera.fill",
                                         .monument: "camera.fill", .rail: "figure.stairs", .bus: "figure.stairs",
                                         .parking: "door.left.hand.open", .lodging: "key.fill",
                                         .default: "mappin"])

        case "storm": // sagome bianche con contorno nero spesso
            return ThemeIconSet(frame: .outline(halo: UIColor(hex: 0x101010)), tint: w,
                                glyphs: [.shop: "shippingbox.fill", .supermarket: "cart.fill", .bank: "dollarsign.circle.fill",
                                         .atm: "dollarsign.circle.fill", .police: "figure.wave", .attraction: "star.fill",
                                         .parking: "car.fill", .default: "mappin.and.ellipse"])

        case "midnight": // gocce colorate per famiglia di luoghi, glifo scuro (stessi colori dei nomi)
            let orange = UIColor(hex: 0xF0A04B), blue = UIColor(hex: 0x5E9CF2), lavender = UIColor(hex: 0x9AA6F5)
            let green = UIColor(hex: 0x5BB974), red = UIColor(hex: 0xE8706A), pink = UIColor(hex: 0xE57FB6)
            let teal = UIColor(hex: 0x2BB5A8)
            var colors: [POICategory: UIColor] = [:]
            for c in [POICategory.restaurant, .fastfood, .cafe, .bakery, .icecream, .bar, .nightclub] { colors[c] = orange }
            for c in [POICategory.supermarket, .shop, .clothes, .shoes, .jewelry, .hairdresser] { colors[c] = blue }
            for c in [POICategory.fuel, .charging, .parking, .car, .carrepair, .rail, .bus, .bicycle] { colors[c] = lavender }
            for c in [POICategory.park, .garden, .playground, .dog, .camping, .sport, .swimming, .fitness] { colors[c] = green }
            for c in [POICategory.pharmacy, .hospital, .clinic] { colors[c] = red }
            colors[.lodging] = pink
            for c in [POICategory.cinema, .theatre, .museum, .attraction, .monument, .library] { colors[c] = teal }
            return ThemeIconSet(frame: .teardrop(glyph: UIColor(hex: 0x1F2338)), tint: UIColor(hex: 0xAAB1D2), colors: colors)

        case "heat": // glifi bianchi
            return ThemeIconSet(frame: .outline(halo: UIColor(hex: 0x2A1E5A)), tint: w)

        default: // "kingdom" — glifi crema con contorno scuro
            return ThemeIconSet(frame: .outline(halo: UIColor(hex: 0x3A3428)), tint: UIColor(hex: 0xF3ECD6),
                                colors: [.default: UIColor(hex: 0xF3ECD6)],
                                glyphs: [.rail: "figure.equestrian.sports", .restaurant: "mortar.and.pestle.fill",
                                         .bar: "mug.fill", .supermarket: "basket.fill", .shop: "bag.fill",
                                         .bank: "bag.fill", .atm: "bag.fill", .school: "book.fill", .parking: "cart.fill",
                                         .car: "cart.fill", .garden: "leaf.fill", .museum: "crown.fill",
                                         .clothes: "hanger", .default: "signpost.right.fill"])
        }
    }

    // MARK: Installazione nello stile

    static func install(in style: MLNStyle, theme: MapTheme) {
        for name in allNames {
            if let img = image(named: name, theme: theme) {
                style.setImage(img, forName: name)
            }
        }
    }

    static var allNames: [String] {
        POICategory.allCases.map { $0.imageName }
            + ["gm-oneway", "gm-shield", "gm-dot", "gm-callout"]
            + Textures.names
    }

    // cache delle icone già disegnate: cambiare tema non le ridisegna
    private static var cache: [String: UIImage] = [:]
    private static let cacheLock = NSLock()

    static func image(named name: String, theme: MapTheme) -> UIImage? {
        let key = theme.id + "|" + name
        cacheLock.lock()
        if let hit = cache[key] { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        let img = makeImage(named: name, theme: theme)
        if let img = img {
            cacheLock.lock(); cache[key] = img; cacheLock.unlock()
        }
        return img
    }

    /// Prepara in anticipo tutte le icone di un tema (in background)
    static func prewarm(_ theme: MapTheme) {
        DispatchQueue.global(qos: .utility).async {
            for name in allNames { _ = image(named: name, theme: theme) }
        }
    }

    private static func makeImage(named name: String, theme: MapTheme) -> UIImage? {
        switch name {
        case "gm-oneway": return oneway(color: theme.iconColor)
        case "gm-shield": return shield(theme: theme)
        case "gm-dot": return dot(color: theme.iconColor)
        case "gm-callout": return callout()
        case _ where Textures.names.contains(name): return Textures.image(named: name)
        default:
            guard name.hasPrefix("gm-poi-"),
                  let cat = POICategory(rawValue: String(name.dropFirst("gm-poi-".count))) else { return nil }
            return rawPoiIcon(cat, theme: theme).map { normalized($0, pixel: theme.id == "pixel") }
        }
    }

    /// Icona di una categoria nello stile del tema (usata sia sulla mappa sia sul globo).
    /// Tutte le icone POI, di ogni tema, escono nello stesso quadrato da 48 pt
    /// con il contenuto alto/largo esattamente 42 pt: dimensioni identiche ovunque.
    static let poiCanvas: CGFloat = 48
    static let poiContent: CGFloat = 42

    static func poiIcon(_ cat: POICategory, theme: MapTheme, pointSize: CGFloat) -> UIImage? {
        if pointSize == 30 {   // richiesta standard: passa dalla cache
            return image(named: cat.imageName, theme: theme)
        }
        return rawPoiIcon(cat, theme: theme).map { normalized($0, pixel: theme.id == "pixel") }
    }

    private static func rawPoiIcon(_ cat: POICategory, theme: MapTheme) -> UIImage? {
        let pointSize: CGFloat = 30
        let set = iconSet(for: theme)
        // Crimson Heat: stemma rosa con stella; Canyon Run: stesso stemma nel colore delle sue icone
        if cat == .default && theme.id == "crimson" {
            return starShield(fill: UIColor(hex: 0xE46BB0), size: pointSize * 1.4)
        }
        if cat == .default && theme.id == "canyon" {
            return starShield(fill: set.tint, size: pointSize * 1.4)
        }
        if cat == .default && set.cloverDefault {
            // Palm Coast: bordi e pallino centrale nel colore del contorno delle altre icone del tema
            if case .outline(let halo) = set.frame, theme.id == "palm" || theme.id == "canyon" {
                return clover(color: theme.accent, size: pointSize * 1.45, border: halo, center: halo)
            }
            return clover(color: theme.accent, size: pointSize * 1.45)
        }
        if cat == .default && set.redPinDefault { return redPin(size: pointSize * 1.5) }
        if theme.id == "pixel", let sprite = PixelArt.sprite(for: cat) { return sprite }
        let color = set.color(cat)
        return framedSymbol(set.glyph(cat), color: color, frame: set.frame, pointSize: pointSize)
            ?? framedSymbol(cat.baseGlyph, color: color, frame: set.frame, pointSize: pointSize)
            ?? framedSymbol("mappin", color: color, frame: set.frame, pointSize: pointSize)
    }

    /// Ritaglia i margini trasparenti e adatta l'icona al quadrato standard.
    static func normalized(_ image: UIImage, pixel: Bool) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        var box = CGRect(x: 0, y: 0, width: w, height: h)
        data.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            let px = buf.bindMemory(to: UInt8.self)
            var minX = w, minY = h, maxX = -1, maxY = -1
            for y in 0..<h {
                for x in 0..<w where px[(y * w + x) * 4 + 3] > 8 {
                    if x < minX { minX = x }; if x > maxX { maxX = x }
                    if y < minY { minY = y }; if y > maxY { maxY = y }
                }
            }
            if maxX >= minX && maxY >= minY {
                box = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
            }
        }
        guard let cropped = cg.cropping(to: box) else { return image }
        let k = poiContent / max(box.width, box.height)
        let size = CGSize(width: box.width * k, height: box.height * k)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 3
        return UIGraphicsImageRenderer(size: CGSize(width: poiCanvas, height: poiCanvas), format: fmt).image { ctx in
            let c = ctx.cgContext
            c.interpolationQuality = pixel ? .none : .high
            let r = CGRect(x: (poiCanvas - size.width) / 2, y: (poiCanvas - size.height) / 2,
                           width: size.width, height: size.height)
            UIImage(cgImage: cropped).draw(in: r)
        }
    }

    // MARK: Glifi personalizzati

    static let churchGlyph = "gm.church"

    /// Glifo SF oppure glifo disegnato dall'app (es. chiesa).
    static func glyphImage(_ name: String, pointSize: CGFloat, weight: UIImage.SymbolWeight) -> UIImage? {
        if name == churchGlyph { return church(height: pointSize * 1.15) }
        return UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight))
    }

    /// Chiesa: navata con tetto, campanile con croce, porta e finestre (immagine "template" da colorare).
    static func church(height: CGFloat) -> UIImage {
        let w = height * 0.9
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 3
        let img = UIGraphicsImageRenderer(size: CGSize(width: w, height: height), format: fmt).image { ctx in
            let c = ctx.cgContext
            let u = height / 24
            c.setFillColor(UIColor.black.cgColor)
            // croce sul campanile
            c.fill(CGRect(x: w / 2 - u * 0.6, y: 0, width: u * 1.2, height: u * 4.2))
            c.fill(CGRect(x: w / 2 - u * 1.8, y: u * 1.2, width: u * 3.6, height: u * 1.1))
            // guglia del campanile
            let spire = UIBezierPath()
            spire.move(to: CGPoint(x: w / 2, y: u * 4))
            spire.addLine(to: CGPoint(x: w / 2 + u * 3, y: u * 8))
            spire.addLine(to: CGPoint(x: w / 2 - u * 3, y: u * 8))
            spire.close(); spire.fill()
            // torre
            c.fill(CGRect(x: w / 2 - u * 2.6, y: u * 8, width: u * 5.2, height: u * 6))
            // tetto della navata
            let roof = UIBezierPath()
            roof.move(to: CGPoint(x: 0, y: u * 15.5))
            roof.addLine(to: CGPoint(x: w / 2, y: u * 10.5))
            roof.addLine(to: CGPoint(x: w, y: u * 15.5))
            roof.close(); roof.fill()
            // navata
            c.fill(CGRect(x: u * 1.2, y: u * 15, width: w - u * 2.4, height: u * 9))
            // porta e finestre (trasparenti)
            c.setBlendMode(.clear)
            let door = UIBezierPath(roundedRect: CGRect(x: w / 2 - u * 1.7, y: u * 18.5, width: u * 3.4, height: u * 5.5),
                                    byRoundingCorners: [.topLeft, .topRight], cornerRadii: CGSize(width: u * 1.7, height: u * 1.7))
            door.fill()
            c.fill(CGRect(x: u * 3.4, y: u * 17.5, width: u * 1.6, height: u * 2.6))
            c.fill(CGRect(x: w - u * 5, y: u * 17.5, width: u * 1.6, height: u * 2.6))
            c.fill(CGRect(x: w / 2 - u * 0.8, y: u * 9.5, width: u * 1.6, height: u * 2.4))
        }
        return img.withRenderingMode(.alwaysTemplate)
    }

    // MARK: Disegno

    static func framedSymbol(_ name: String, color: UIColor, frame: IconFrame, pointSize: CGFloat) -> UIImage? {
        switch frame {
        case .outline(let halo):
            return outlinedSymbol(name, color: color, halo: halo, pointSize: pointSize)
        case .pixel(let halo):
            return pixelSymbol(name, color: color, halo: halo)
        case .teardrop(let glyphColor):
            guard let base = glyphImage(name, pointSize: pointSize * 0.55, weight: .bold) else { return nil }
            let d = pointSize * 1.3
            let fmt = UIGraphicsImageRendererFormat()
            fmt.scale = 2
            return UIGraphicsImageRenderer(size: CGSize(width: d + 4, height: d * 1.22 + 4), format: fmt).image { ctx in
                let c = ctx.cgContext
                let r = d / 2
                let center = CGPoint(x: 2 + r, y: 2 + r)
                let path = UIBezierPath()
                path.addArc(withCenter: center, radius: r, startAngle: .pi * 0.62, endAngle: .pi * 0.38, clockwise: true)
                path.addLine(to: CGPoint(x: center.x, y: 2 + d * 1.22))
                path.close()
                c.setShadow(offset: CGSize(width: 0, height: 1), blur: 2, color: UIColor.black.withAlphaComponent(0.45).cgColor)
                color.setFill(); path.fill()
                c.setShadow(offset: .zero, blur: 0, color: nil)
                UIColor.white.withAlphaComponent(0.85).setStroke(); path.lineWidth = 1.2; path.stroke()
                let s = base.size
                base.withTintColor(glyphColor, renderingMode: .alwaysOriginal)
                    .draw(in: CGRect(x: center.x - s.width / 2, y: center.y - s.height / 2, width: s.width, height: s.height))
            }
        case .tactical(let fill, let bracket):
            return enclosed(name, color: color, pointSize: pointSize) { ctx, rect in
                let r = rect.insetBy(dx: rect.width * 0.08, dy: rect.width * 0.08)
                ctx.setFillColor(fill.cgColor)
                ctx.addPath(UIBezierPath(roundedRect: r, cornerRadius: r.width * 0.08).cgPath)
                ctx.fillPath()
                // angolari ai quattro spigoli
                let l = r.width * 0.26, t = max(1.5, r.width * 0.06), o = rect.width * 0.02
                ctx.setFillColor(bracket.cgColor)
                let a = rect.insetBy(dx: o, dy: o)
                for (x, y, sx, sy) in [(a.minX, a.minY, 1.0, 1.0), (a.maxX, a.minY, -1.0, 1.0),
                                       (a.minX, a.maxY, 1.0, -1.0), (a.maxX, a.maxY, -1.0, -1.0)] {
                    let fx = CGFloat(sx), fy = CGFloat(sy)
                    ctx.fill(CGRect(x: fx > 0 ? x : x - l, y: fy > 0 ? y : y - t, width: l, height: t))
                    ctx.fill(CGRect(x: fx > 0 ? x : x - t, y: fy > 0 ? y : y - l, width: t, height: l))
                }
            }
        case .badge(let fill, let ring):
            return enclosed(name, color: color, pointSize: pointSize) { ctx, rect in
                ctx.setFillColor(fill.cgColor)
                ctx.fillEllipse(in: rect)
                ctx.setStrokeColor(ring.cgColor)
                ctx.setLineWidth(rect.width * 0.07)
                ctx.strokeEllipse(in: rect.insetBy(dx: rect.width * 0.035, dy: rect.width * 0.035))
            }
        case .hexagon(let fill, let ring):
            return enclosed(name, color: color, pointSize: pointSize) { ctx, rect in
                let path = hexagonPath(in: rect)
                ctx.addPath(path)
                ctx.setFillColor(fill.cgColor)
                ctx.fillPath()
                ctx.addPath(path)
                ctx.setStrokeColor(ring.cgColor)
                ctx.setLineWidth(rect.width * 0.07)
                ctx.strokePath()
            }
        }
    }

    private static func hexagonPath(in rect: CGRect) -> CGPath {
        let p = CGMutablePath()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = rect.width / 2 * 0.95
        for i in 0..<6 {
            let a = CGFloat(i) * .pi / 3 - .pi / 2
            let pt = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }

    private static func enclosed(_ name: String, color: UIColor, pointSize: CGFloat,
                                 background: (CGContext, CGRect) -> Void) -> UIImage? {
        guard let base = glyphImage(name, pointSize: pointSize * 0.62, weight: .bold) else { return nil }
        let side = pointSize * 1.45
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 2
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: fmt).image { ctx in
            let rect = CGRect(x: 1, y: 1, width: side - 2, height: side - 2)
            background(ctx.cgContext, rect)
            let s = base.size
            let r = CGRect(x: (side - s.width) / 2, y: (side - s.height) / 2, width: s.width, height: s.height)
            base.withTintColor(color, renderingMode: .alwaysOriginal).draw(in: r)
        }
    }

    /// Glifo SF ridotto a una griglia 16×16 con contorno di 1 pixel e ingrandito ×3 senza sfumature:
    /// risultato 48×48 pt, identico per dimensioni agli sprite disegnati a mano.
    static func pixelSymbol(_ name: String, color: UIColor, halo: UIColor) -> UIImage? {
        guard let base = glyphImage(name, pointSize: 11, weight: .heavy) else { return nil }
        let grid: CGFloat = 16
        let fmt1 = UIGraphicsImageRendererFormat()
        fmt1.scale = 1
        let small = UIGraphicsImageRenderer(size: CGSize(width: grid, height: grid), format: fmt1).image { ctx in
            ctx.cgContext.interpolationQuality = .none
            let s = base.size
            let k = min(12 / s.width, 12 / s.height)
            let r = CGRect(x: (grid - s.width * k) / 2, y: (grid - s.height * k) / 2, width: s.width * k, height: s.height * k)
            let h = base.withTintColor(halo, renderingMode: .alwaysOriginal)
            for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                h.draw(in: r.offsetBy(dx: CGFloat(dx), dy: CGFloat(dy)))
            }
            base.withTintColor(color, renderingMode: .alwaysOriginal).draw(in: r)
        }
        guard let cg = small.cgImage else { return nil }
        let px: CGFloat = 3
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 2
        return UIGraphicsImageRenderer(size: CGSize(width: grid * px, height: grid * px), format: fmt).image { ctx in
            let c = ctx.cgContext
            c.interpolationQuality = .none
            c.setShouldAntialias(false)
            c.translateBy(x: 0, y: grid * px)
            c.scaleBy(x: 1, y: -1)
            c.draw(cg, in: CGRect(x: 0, y: 0, width: grid * px, height: grid * px))
        }
    }

    private static func pixelate(_ image: UIImage, factor: CGFloat) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let w = Int(CGFloat(cg.width) * factor)
        let h = Int(CGFloat(cg.height) * factor)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 2
        return UIGraphicsImageRenderer(size: CGSize(width: CGFloat(w) / 2, height: CGFloat(h) / 2), format: fmt).image { ctx in
            let c = ctx.cgContext
            c.interpolationQuality = .none
            c.translateBy(x: 0, y: CGFloat(h) / 2)
            c.scaleBy(x: 1, y: -1)
            c.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(w) / 2, height: CGFloat(h) / 2))
        }
    }

    /// Simbolo SF con contorno
    static func outlinedSymbol(_ name: String, color: UIColor, halo: UIColor, pointSize: CGFloat,
                               scale: CGFloat = 2) -> UIImage? {
        guard let base = glyphImage(name, pointSize: pointSize, weight: .black) else { return nil }
        let o: CGFloat = max(1, pointSize * 0.085)
        let pad = o * 2.4
        let size = CGSize(width: base.size.width + pad * 2, height: base.size.height + pad * 2)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = scale
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            let haloImg = base.withTintColor(halo, renderingMode: .alwaysOriginal)
            let r = CGRect(x: pad, y: pad, width: base.size.width, height: base.size.height)
            for i in 0..<12 {
                let a = CGFloat(i) / 12 * 2 * .pi
                haloImg.draw(in: r.offsetBy(dx: cos(a) * o, dy: sin(a) * o))
            }
            base.withTintColor(color, renderingMode: .alwaysOriginal).draw(in: r)
        }
    }

    /// Stemma (scudo a punta) con stella nera al centro e fascia chiara, contorno nero spesso
    static func starShield(fill: UIColor, size: CGFloat) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 2
        let w = size * 0.9, h = size
        return UIGraphicsImageRenderer(size: CGSize(width: w + 6, height: h + 6), format: fmt).image { ctx in
            let c = ctx.cgContext
            let o = CGPoint(x: 3, y: 3)
            let shield = UIBezierPath()
            shield.move(to: CGPoint(x: o.x, y: o.y))
            shield.addLine(to: CGPoint(x: o.x + w, y: o.y))
            shield.addLine(to: CGPoint(x: o.x + w, y: o.y + h * 0.68))
            shield.addLine(to: CGPoint(x: o.x + w / 2, y: o.y + h))
            shield.addLine(to: CGPoint(x: o.x, y: o.y + h * 0.68))
            shield.close()
            c.setLineJoin(.round)
            c.setStrokeColor(UIColor(hex: 0x0A0A0A).cgColor)
            c.setLineWidth(size * 0.12)
            c.addPath(shield.cgPath); c.strokePath()
            // stemma tutto di un colore (nessuna fascia) con la stella nera grande che lo riempie
            c.setFillColor(fill.cgColor)
            c.addPath(shield.cgPath); c.fillPath()
            // stella che riempie tutto lo stemma: le punte arrivano ai bordi (tagliate dal contorno)
            let m = CGPoint(x: o.x + w / 2, y: o.y + h * 0.5)
            let outer = size * 0.53, inner = size * 0.215
            let star = UIBezierPath()
            for i in 0..<10 {
                let a = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5
                let r = i % 2 == 0 ? outer : inner
                let pt = CGPoint(x: m.x + cos(a) * r, y: m.y + sin(a) * r)
                if i == 0 { star.move(to: pt) } else { star.addLine(to: pt) }
            }
            star.close()
            c.saveGState()
            c.addPath(shield.cgPath); c.clip()
            c.setFillColor(UIColor(hex: 0x0A0A0A).cgColor)
            c.addPath(star.cgPath); c.fillPath()
            c.restoreGState()
            // contorno ridisegnato sopra: bordi netti dove la stella tocca lo scudo
            c.setStrokeColor(UIColor(hex: 0x0A0A0A).cgColor)
            c.setLineWidth(size * 0.08)
            c.addPath(shield.cgPath); c.strokePath()
        }
    }

    /// Segnaposto rosso a goccia con punto bianco
    static func redPin(size: CGFloat) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 2
        let w = size * 0.72, h = size
        return UIGraphicsImageRenderer(size: CGSize(width: w + 4, height: h + 4), format: fmt).image { ctx in
            let c = ctx.cgContext
            let r = w / 2
            let center = CGPoint(x: 2 + r, y: 2 + r)
            let path = UIBezierPath()
            path.addArc(withCenter: center, radius: r, startAngle: .pi * 0.8, endAngle: .pi * 0.2, clockwise: true)
            path.addLine(to: CGPoint(x: center.x, y: 2 + h))
            path.close()
            c.setShadow(offset: CGSize(width: 0, height: 1), blur: 2, color: UIColor.black.withAlphaComponent(0.4).cgColor)
            UIColor(hex: 0xC8343C).setFill(); path.fill()
            c.setShadow(offset: .zero, blur: 0, color: nil)
            UIColor(hex: 0x7A1A20).setStroke(); path.lineWidth = 1.2; path.stroke()
            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(x: center.x - r * 0.36, y: center.y - r * 0.36, width: r * 0.72, height: r * 0.72)).fill()
        }
    }

    /// Quadrifoglio viola (segnaposto luoghi, tema Vice Noir)
    static func clover(color: UIColor, size: CGFloat, border: UIColor = .white,
                       center: UIColor = UIColor.white.withAlphaComponent(0.9)) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 2
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: fmt).image { ctx in
            let c = ctx.cgContext
            let s = size
            let petal = s * 0.36
            let mid = s / 2
            let centers = [
                CGPoint(x: mid, y: mid - petal * 0.62),
                CGPoint(x: mid, y: mid + petal * 0.62),
                CGPoint(x: mid - petal * 0.62, y: mid),
                CGPoint(x: mid + petal * 0.62, y: mid)
            ]
            c.setFillColor(border.cgColor)
            for p in centers {
                c.fillEllipse(in: CGRect(x: p.x - petal / 2 - 2, y: p.y - petal / 2 - 2, width: petal + 4, height: petal + 4))
            }
            c.setFillColor(color.cgColor)
            for p in centers {
                c.fillEllipse(in: CGRect(x: p.x - petal / 2, y: p.y - petal / 2, width: petal, height: petal))
            }
            c.fillEllipse(in: CGRect(x: mid - petal * 0.55, y: mid - petal * 0.55, width: petal * 1.1, height: petal * 1.1))
            c.setFillColor(center.cgColor)
            c.fillEllipse(in: CGRect(x: mid - petal * 0.2, y: mid - petal * 0.2, width: petal * 0.4, height: petal * 0.4))
        }
    }

    static func oneway(color: UIColor) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 2
        return UIGraphicsImageRenderer(size: CGSize(width: 24, height: 14), format: fmt).image { ctx in
            let c = ctx.cgContext
            c.setStrokeColor(color.cgColor)
            c.setLineWidth(2.4)
            c.setLineCap(.round)
            c.setLineJoin(.round)
            c.move(to: CGPoint(x: 3, y: 7)); c.addLine(to: CGPoint(x: 20, y: 7))
            c.move(to: CGPoint(x: 14, y: 2.5)); c.addLine(to: CGPoint(x: 20, y: 7)); c.addLine(to: CGPoint(x: 14, y: 11.5))
            c.strokePath()
        }
    }

    static func shield(theme: MapTheme) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 2
        let color: UIColor
        switch theme.id {
        case "bunker": color = UIColor(hex: 0x0F5F0F)
        case "neon", "heat": color = UIColor(hex: 0xFF2E7E)
        case "dust", "kingdom": color = UIColor(hex: 0x6B4A28)
        case "contract": color = UIColor(hex: 0x2A2B2D)
        case "storm": color = UIColor(hex: 0x2F7BFF)
        case "midnight": color = UIColor(hex: 0x2F63D6)
        default: color = UIColor(hex: 0x2F47C9)
        }
        return UIGraphicsImageRenderer(size: CGSize(width: 24, height: 16), format: fmt).image { _ in
            let path = UIBezierPath(roundedRect: CGRect(x: 1, y: 1, width: 22, height: 14), cornerRadius: 3)
            color.setFill(); path.fill()
            UIColor.white.setStroke(); path.lineWidth = 1.2; path.stroke()
        }
    }

    /// Fumetto per i nomi delle vie (Midnight Route): fondo indaco, bordo chiaro, codina in basso a sinistra.
    /// Le estremità non si deformano quando il fumetto si allarga attorno al testo.
    static func callout() -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 2
        let w: CGFloat = 40, h: CGFloat = 34
        let img = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: fmt).image { _ in
            let body = UIBezierPath(roundedRect: CGRect(x: 1.5, y: 1.5, width: w - 3, height: h - 9), cornerRadius: 9)
            let tail = UIBezierPath()
            tail.move(to: CGPoint(x: 9, y: h - 8.5)); tail.addLine(to: CGPoint(x: 13, y: h - 1.5)); tail.addLine(to: CGPoint(x: 17, y: h - 8.5))
            UIColor(hex: 0x2E3454).withAlphaComponent(0.92).setFill()
            body.fill(); tail.fill()
            UIColor(hex: 0xA0A8D0).setStroke()
            body.lineWidth = 1.5; body.stroke()
        }
        return img.resizableImage(withCapInsets: UIEdgeInsets(top: 12, left: 20, bottom: 14, right: 12), resizingMode: .stretch)
    }

    static func dot(color: UIColor) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 2
        return UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12), format: fmt).image { ctx in
            ctx.cgContext.setFillColor(UIColor.black.withAlphaComponent(0.6).cgColor)
            ctx.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: 12, height: 12))
            ctx.cgContext.setFillColor(color.cgColor)
            ctx.cgContext.fillEllipse(in: CGRect(x: 2.5, y: 2.5, width: 7, height: 7))
        }
    }
}
