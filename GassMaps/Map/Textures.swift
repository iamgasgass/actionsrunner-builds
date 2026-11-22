import UIKit

/// Texture ripetibili usate come "background-pattern" / "fill-pattern" negli stili mappa.
/// Disegnate interamente dall'app (nessuna immagine esterna).
enum Textures {
    static let names = ["gm-paper", "gm-grass", "gm-water", "gm-planks", "gm-stone", "gm-roof", "gm-trees", "gm-meadow", "gm-camo", "gm-swirl"]

    private static var cache: [String: UIImage] = [:]

    static func image(named name: String) -> UIImage? {
        if let c = cache[name] { return c }
        let img: UIImage?
        switch name {
        case "gm-paper": img = paper()
        case "gm-grass": img = blocks(colors: [0x6E9050, 0x6A8C4A, 0x76985A, 0x648646, 0x7A9C58, 0x70924E], block: 8, count: 8)
        case "gm-water": img = blocks(colors: [0x5A5ABE, 0x5454B6, 0x6060C6, 0x5050B0, 0x5C5CC2], block: 8, count: 8)
        case "gm-planks": img = planks()
        case "gm-stone": img = stone()
        case "gm-roof": img = roof()
        case "gm-trees": img = trees()
        case "gm-meadow": img = meadow()
        case "gm-camo": img = camo()
        case "gm-swirl": img = swirl()
        default: img = nil
        }
        if let img = img { cache[name] = img }
        return img
    }

    private static func renderer(_ side: CGFloat) -> UIGraphicsImageRenderer {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 2
        fmt.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: fmt)
    }

    /// Pergamena: base sabbia + puntini e fibre (ripetibile: tutto avvolto sui bordi)
    private static func paper() -> UIImage {
        let side: CGFloat = 256
        var rng = SeededGenerator(seed: 7)
        return renderer(side).image { ctx in
            let c = ctx.cgContext
            c.setFillColor(UIColor(hex: 0xD4C09A).cgColor)
            c.fill(CGRect(x: 0, y: 0, width: side, height: side))
            // macchie morbide
            for _ in 0..<40 {
                let x = CGFloat.random(in: 0..<side, using: &rng), y = CGFloat.random(in: 0..<side, using: &rng)
                let r = CGFloat.random(in: 10...40, using: &rng)
                let dark = Bool.random(using: &rng)
                let col = (dark ? UIColor(hex: 0xA88F66) : UIColor(hex: 0xE6D6B4)).withAlphaComponent(0.10)
                c.setFillColor(col.cgColor)
                for dx in [-side, 0, side] { for dy in [-side, 0, side] {
                    c.fillEllipse(in: CGRect(x: x - r + dx, y: y - r + dy, width: r * 2, height: r * 2))
                } }
            }
            // granelli
            for _ in 0..<2600 {
                let x = CGFloat.random(in: 0..<side, using: &rng), y = CGFloat.random(in: 0..<side, using: &rng)
                let a = CGFloat.random(in: 0.05...0.22, using: &rng)
                let col = Bool.random(using: &rng) ? UIColor(hex: 0x6E5A3A) : UIColor(hex: 0xF2E6C8)
                c.setFillColor(col.withAlphaComponent(a).cgColor)
                c.fill(CGRect(x: x, y: y, width: 0.8, height: 0.8))
            }
            // fibre
            c.setLineWidth(0.5)
            for _ in 0..<70 {
                let x = CGFloat.random(in: 0..<side, using: &rng), y = CGFloat.random(in: 0..<side, using: &rng)
                let len = CGFloat.random(in: 4...14, using: &rng)
                let ang = CGFloat.random(in: 0..<(2 * .pi), using: &rng)
                c.setStrokeColor(UIColor(hex: 0x8A7552).withAlphaComponent(0.18).cgColor)
                for dx in [-side, 0, side] { for dy in [-side, 0, side] {
                    c.move(to: CGPoint(x: x + dx, y: y + dy))
                    c.addLine(to: CGPoint(x: x + dx + cos(ang) * len, y: y + dy + sin(ang) * len))
                } }
                c.strokePath()
            }
        }
    }

    /// Griglia di blocchi colorati (erba / acqua pixelate)
    private static func blocks(colors: [UInt32], block: CGFloat, count: Int) -> UIImage {
        var rng = SeededGenerator(seed: UInt64(colors[0]))
        let side = block * CGFloat(count)
        return renderer(side).image { ctx in
            let c = ctx.cgContext
            c.interpolationQuality = .none
            c.setShouldAntialias(false)
            for i in 0..<count {
                for j in 0..<count {
                    let col = colors[Int.random(in: 0..<colors.count, using: &rng)]
                    c.setFillColor(UIColor(hex: col).cgColor)
                    c.fill(CGRect(x: CGFloat(i) * block, y: CGFloat(j) * block, width: block, height: block))
                }
            }
        }
    }

    /// Bosco visto dall'alto in stile cartoon (Storm Isle): chiome tonde verde scuro con luce e ombra.
    /// Ogni chioma che esce da un bordo viene ripetuta su quello opposto: la texture si ripete senza giunte.
    private static func trees() -> UIImage {
        let side: CGFloat = 128
        var rng = SeededGenerator(seed: 0x2D5420)
        var crowns: [(CGFloat, CGFloat, CGFloat)] = []
        for _ in 0..<14 {
            crowns.append((CGFloat.random(in: 0..<side, using: &rng), CGFloat.random(in: 0..<side, using: &rng),
                           CGFloat.random(in: 11...19, using: &rng)))
        }
        return renderer(side).image { ctx in
            let c = ctx.cgContext
            c.setFillColor(UIColor(hex: 0x2F5A22).cgColor)
            c.fill(CGRect(x: 0, y: 0, width: side, height: side))
            for pass in 0..<3 {
                for (x, y, r) in crowns {
                    for dx in [-side, 0, side] {
                        for dy in [-side, 0, side] {
                            let cx = x + dx, cy = y + dy
                            switch pass {
                            case 0: // ombra
                                c.setFillColor(UIColor(hex: 0x1C3A15).cgColor)
                                c.fillEllipse(in: CGRect(x: cx - r + 3, y: cy - r + 4, width: r * 2, height: r * 2))
                            case 1: // chioma
                                c.setFillColor(UIColor(hex: 0x3B6E2A).cgColor)
                                c.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
                            default: // luce
                                c.setFillColor(UIColor(hex: 0x4F8A36).cgColor)
                                c.fillEllipse(in: CGRect(x: cx - r * 0.75, y: cy - r * 0.8, width: r * 1.1, height: r * 1.0))
                            }
                        }
                    }
                }
            }
        }
    }

    /// Prato cartoon (Storm Isle): verde saturo con macchie più chiare e più scure, ripetibile senza giunte
    private static func meadow() -> UIImage {
        let side: CGFloat = 128
        var rng = SeededGenerator(seed: 0x3E6B26)
        return renderer(side).image { ctx in
            let c = ctx.cgContext
            c.setFillColor(UIColor(hex: 0x3E6B26).cgColor)
            c.fill(CGRect(x: 0, y: 0, width: side, height: side))
            let tones: [UInt32] = [0x447430, 0x386222, 0x4A7A33, 0x3B6825]
            for _ in 0..<22 {
                let x = CGFloat.random(in: 0..<side, using: &rng), y = CGFloat.random(in: 0..<side, using: &rng)
                let w = CGFloat.random(in: 10...26, using: &rng), h = w * CGFloat.random(in: 0.5...0.9, using: &rng)
                c.setFillColor(UIColor(hex: tones[Int.random(in: 0..<tones.count, using: &rng)]).withAlphaComponent(0.7).cgColor)
                for dx in [-side, 0, side] {
                    for dy in [-side, 0, side] {
                        c.fillEllipse(in: CGRect(x: x + dx - w / 2, y: y + dy - h / 2, width: w, height: h))
                    }
                }
            }
        }
    }

    /// Mimetico turchese con macchie chiare e segni a "X" (quartieri della mappa Canyon Run), ripetibile senza giunte
    private static func camo() -> UIImage {
        let side: CGFloat = 128
        var rng = SeededGenerator(seed: 0x5AA6A2)
        return renderer(side).image { ctx in
            let c = ctx.cgContext
            c.setFillColor(UIColor(hex: 0x4F9B97).cgColor)
            c.fill(CGRect(x: 0, y: 0, width: side, height: side))
            func wrap(_ draw: (CGFloat, CGFloat) -> Void) {
                for dx in [-side, 0, side] { for dy in [-side, 0, side] { draw(dx, dy) } }
            }
            // macchie scure e chiare a "pixel" irregolari
            for (tone, count) in [(UInt32(0x3C807D), 16), (UInt32(0x7CC9C4), 14), (UInt32(0xA6EEE8), 9)] {
                c.setFillColor(UIColor(hex: tone).cgColor)
                for _ in 0..<count {
                    let x = CGFloat.random(in: 0..<side, using: &rng), y = CGFloat.random(in: 0..<side, using: &rng)
                    let w = CGFloat.random(in: 6...18, using: &rng), h = CGFloat.random(in: 4...12, using: &rng)
                    let w2 = w * CGFloat.random(in: 0.4...0.8, using: &rng), off = CGFloat.random(in: -5...5, using: &rng)
                    wrap { dx, dy in
                        c.fill(CGRect(x: x + dx, y: y + dy, width: w, height: h))
                        c.fill(CGRect(x: x + dx + off, y: y + dy + h, width: w2, height: h * 0.7))
                    }
                }
            }
            // segni a X chiari di varie misure
            c.setStrokeColor(UIColor(hex: 0xBDF7F2).cgColor)
            c.setLineCap(.round)
            for _ in 0..<12 {
                let x = CGFloat.random(in: 0..<side, using: &rng), y = CGFloat.random(in: 0..<side, using: &rng)
                let r = CGFloat.random(in: 2.5...9, using: &rng)
                c.setLineWidth(r > 6 ? 2.6 : 1.5)
                wrap { dx, dy in
                    c.move(to: CGPoint(x: x + dx - r, y: y + dy - r)); c.addLine(to: CGPoint(x: x + dx + r, y: y + dy + r))
                    c.move(to: CGPoint(x: x + dx + r, y: y + dy - r)); c.addLine(to: CGPoint(x: x + dx - r, y: y + dy + r))
                }
                c.strokePath()
            }
        }
    }

    /// Rosso a pennellate curve intrecciate (quartieri di Crimson Heat), ripetibile senza giunte
    private static func swirl() -> UIImage {
        let side: CGFloat = 160
        var rng = SeededGenerator(seed: 0x9A4A4F)
        return renderer(side).image { ctx in
            let c = ctx.cgContext
            c.setFillColor(UIColor(hex: 0x93474C).cgColor)
            c.fill(CGRect(x: 0, y: 0, width: side, height: side))
            c.setLineCap(.round)
            let tones: [(UInt32, CGFloat)] = [(0x7E3A3F, 0.9), (0xB0656A, 0.75), (0xC98A8D, 0.55)]
            for (tone, alpha) in tones {
                c.setStrokeColor(UIColor(hex: tone).withAlphaComponent(alpha).cgColor)
                for _ in 0..<7 {
                    let x = CGFloat.random(in: 0..<side, using: &rng), y = CGFloat.random(in: 0..<side, using: &rng)
                    let r = CGFloat.random(in: 18...60, using: &rng)
                    let start = CGFloat.random(in: 0...(2 * .pi), using: &rng)
                    let sweep = CGFloat.random(in: 1.2...2.6, using: &rng)
                    c.setLineWidth(CGFloat.random(in: 4...10, using: &rng))
                    for dx in [-side, 0, side] {
                        for dy in [-side, 0, side] {
                            c.addArc(center: CGPoint(x: x + dx, y: y + dy), radius: r,
                                     startAngle: start, endAngle: start + sweep, clockwise: false)
                            c.strokePath()
                        }
                    }
                }
            }
        }
    }

    /// Assi di legno (tetti)
    private static func planks() -> UIImage {
        var rng = SeededGenerator(seed: 11)
        let side: CGFloat = 32
        return renderer(side).image { ctx in
            let c = ctx.cgContext
            c.setShouldAntialias(false)
            let tones: [UInt32] = [0xB0834E, 0xA87A46, 0xB88C56, 0xA0723F]
            for row in 0..<4 {
                let y = CGFloat(row) * 8
                c.setFillColor(UIColor(hex: tones[row % tones.count]).cgColor)
                c.fill(CGRect(x: 0, y: y, width: side, height: 8))
                for _ in 0..<10 {
                    let x = CGFloat(Int.random(in: 0..<16, using: &rng)) * 2
                    let yy = y + CGFloat(Int.random(in: 1..<3, using: &rng)) * 2
                    c.setFillColor(UIColor(hex: 0x8C6236).cgColor)
                    c.fill(CGRect(x: x, y: yy, width: 4, height: 2))
                }
                c.setFillColor(UIColor(hex: 0x6E4A26).cgColor)
                c.fill(CGRect(x: 0, y: y + 6, width: side, height: 2))
                let cut = CGFloat(row % 2 == 0 ? 12 : 26)
                c.fill(CGRect(x: cut, y: y, width: 2, height: 8))
            }
        }
    }

    /// Tetti di coppi (Old Kingdom): file di tegole sfalsate color terracotta
    private static func roof() -> UIImage {
        let side: CGFloat = 32
        return renderer(side).image { ctx in
            let c = ctx.cgContext
            c.setFillColor(UIColor(hex: 0xA26F5F).cgColor)
            c.fill(CGRect(x: 0, y: 0, width: side, height: side))
            for row in 0..<4 {
                let y = CGFloat(row) * 8
                let offset: CGFloat = row % 2 == 0 ? 0 : 4
                for col in -1..<5 {
                    let x = CGFloat(col) * 8 + offset
                    let tile = UIBezierPath(roundedRect: CGRect(x: x + 0.5, y: y + 0.5, width: 7, height: 7.5), cornerRadius: 2.5)
                    UIColor(hex: 0xAD7967).setFill(); tile.fill()
                    UIColor(hex: 0x7E5246).setStroke(); tile.lineWidth = 0.8; tile.stroke()
                    UIColor(hex: 0xC08A76).withAlphaComponent(0.7).setFill()
                    UIBezierPath(rect: CGRect(x: x + 1.5, y: y + 1.2, width: 5, height: 1.2)).fill()
                }
            }
        }
    }

    /// Blocchi di pietra (edifici alti)
    private static func stone() -> UIImage {
        var rng = SeededGenerator(seed: 23)
        let side: CGFloat = 32
        return renderer(side).image { ctx in
            let c = ctx.cgContext
            c.setShouldAntialias(false)
            let tones: [UInt32] = [0x8C8C8C, 0x7E7E7E, 0x989898, 0x868686, 0x737373]
            for i in 0..<8 {
                for j in 0..<8 {
                    c.setFillColor(UIColor(hex: tones[Int.random(in: 0..<tones.count, using: &rng)]).cgColor)
                    c.fill(CGRect(x: CGFloat(i) * 4, y: CGFloat(j) * 4, width: 4, height: 4))
                }
            }
            c.setFillColor(UIColor(hex: 0x5E5E5E).cgColor)
            c.fill(CGRect(x: 0, y: 15, width: side, height: 2))
            c.fill(CGRect(x: 0, y: 31, width: side, height: 1))
            c.fill(CGRect(x: 15, y: 0, width: 2, height: 16))
            c.fill(CGRect(x: 6, y: 16, width: 2, height: 16))
            c.fill(CGRect(x: 24, y: 16, width: 2, height: 16))
        }
    }
}

/// Sprite in pixel art (16×16) disegnati per il tema a blocchi, come nella schermata di riferimento.
enum PixelArt {
    private struct Sprite {
        let palette: [Character: UInt32]
        let rows: [String]
    }

    private static let chicken = Sprite(palette: ["k": 0x3B1F0E, "b": 0x8A4A22, "m": 0xB8692F, "l": 0xE09A55,
                                                  "y": 0xF2C27A, "w": 0xF2EEE6, "g": 0xBDB6AA], rows: [
        "......kkkk......", "....kkmmmmkk....", "...kmmllllmmk...", "..kmllyylllmbk..",
        "..kmlyyllllmbk..", ".kmmllllllmmbbk.", ".kmlllllllmmbbk.", ".kmmlllllmmmbbk.",
        ".kbmmmmmmmmbbbk.", "..kbbmmmmmbbbk..", "..kbbbbbbbbbk...", "...kkbbbbbkk....",
        "....kkkkkkwwk...", "..........kwwk..", "...........kgk..", "............k..."])

    private static let chestplate = Sprite(palette: ["D": 0x0E4F4E, "d": 0x167A78, "c": 0x2BB5B0,
                                                     "C": 0x64E8E0, "W": 0xCFFFFB], rows: [
        "................", "..DDD......DDD..", ".DcCcD....DcCcD.", ".DcCCcDDDDcCCcD.",
        ".DccCccccccCccD.", ".DDdcccCCcccdDD.", "...DdccCCccdD...", "...DdcCWWCcdD...",
        "...DdccCCccdD...", "...DdccccccdD...", "...DddccccddD...", "...DddddddddD...",
        "....DDDDDDDD....", "................", "................", "................"])

    // osso (area cani)
    private static let bone = Sprite(palette: ["k": 0x4A4A44, "w": 0xF4F1E8, "g": 0xC9C4B8], rows: [
        "................", "..........kk.kk.", ".........kwwkwwk", ".........kwwwwgk",
        "..........kwwgk.", ".........kwwgk..", "........kwwgk...", ".......kwwgk....",
        "......kwwgk.....", ".....kwwgk......", "....kwwgk.......", "...kwwgk........",
        ".kkwwwgk........", "kwwwwgk.........", "kwwgkwk.........", ".kk..k.........."])

    // tulipano (giardini)
    private static let tulip = Sprite(palette: ["R": 0x8E1A1E, "r": 0xD8282E, "l": 0xF06A6A,
                                                "G": 0x2F6F22, "g": 0x67B347], rows: [
        "................", "....R..RR..R....", "....RrRrrRrR....", "....RrrrrrrR....",
        "....RrrlrrrR....", "....RrrrrrrR....", ".....RrrrrR.....", "......RRRR......",
        ".......GG.......", "..GG...GG...GG..", "..GgG..GG..GgG..", "...GgG.GG.GgG...",
        "....GgGGGGgG....", ".....GgGGgG.....", ".......GG.......", ".......GG......."])

    // campana (municipio)
    private static let bell = Sprite(palette: ["k": 0x5A4010, "y": 0xF2C230, "Y": 0xB8861A, "l": 0xFFF0A0], rows: [
        "................", ".......kk.......", "......kYYk......", ".....kyyyyk.....",
        "....kyylyyYk....", "....kylyyyYk....", "....kyyyyyYk....", "...kyyyyyyyYk...",
        "...kyyyyyyyYk...", "..kyyyyyyyyyYk..", "..kYYYYYYYYYYk..", "...kkkkkkkkkk...",
        "......kYYk......", ".......kk.......", "................", "................"])

    // scudo blu con stella (polizia / carabinieri)
    private static let shield = Sprite(palette: ["k": 0x10183A, "B": 0x2E4FB8, "b": 0x1C2F7A, "s": 0xF2C230], rows: [
        "................", "..kkkkkkkkkkkk..", "..kBBBBBBBBBBk..", "..kBBBBsBBBBbk..",
        "..kBBBsssBBBbk..", "..kBsssssssBbk..", "..kBBsssssBBbk..", "..kBBBsssBBBbk..",
        "..kBBssBssBBbk..", "..kBsBBBBBsBbk..", "...kBBBBBBBbk...", "....kBBBBBbk....",
        ".....kBBBbk.....", "......kBbk......", ".......kk.......", "................"])

    // parchimetro (parcheggi)
    private static let meter = Sprite(palette: ["k": 0x2E3138, "g": 0x8A8F99, "G": 0x555A63,
                                                "c": 0x4A8BE0, "w": 0xD8ECFF], rows: [
        "................", ".....kkkkkk.....", "....kGggggGk....", "....kgccccgk....",
        "....kgcwccgk....", "....kgccccgk....", "....kggggggk....", "....kGgkkgGk....",
        ".....kGggGk.....", "......kGGk......", "......kggk......", "......kggk......",
        "......kggk......", ".....kGggGk.....", ".....kkkkkk.....", "................"])

    // libro rosso (scuole / biblioteche)
    private static let book = Sprite(palette: ["k": 0x3A0E0E, "R": 0x7E1C1C, "r": 0xA8282A,
                                               "l": 0xE87A6A, "p": 0xF0E6D0], rows: [
        "................", "................", "......kkkkkk....", ".....krrrrrrk...",
        "....krrrrrrrrk..", "...krrrlrrrrRk..", "..krrrrrrrrRRk..", ".krrrrrrrrRRpk..",
        ".kRRRrrrrRRppk..", ".kpppRRRRRppk...", "..kkpppppppk....", "....kkkkkkk.....",
        "................", "................", "................", "................"])

    // busta (poste)
    private static let envelope = Sprite(palette: ["k": 0x6A6458, "w": 0xF2EFE6, "g": 0xC9C3B4], rows: [
        "................", "................", "................", ".kkkkkkkkkkkkkk.",
        ".kwgwwwwwwwwgwk.", ".kwwgwwwwwwgwwk.", ".kwwwgwwwwgwwwk.", ".kwwwwgwwgwwwwk.",
        ".kwwwwwggwwwwwk.", ".kwwwwwwwwwwwwk.", ".kwwwwwwwwwwwwk.", ".kkkkkkkkkkkkkk.",
        "................", "................", "................", "................"])

    // segnaposto rosso (piazze e luoghi generici)
    private static let pin = Sprite(palette: ["k": 0x4A0A0A, "r": 0xD02A2A, "R": 0x8A1616, "l": 0xF06060], rows: [
        "................", ".....kkkkkk.....", "....krrrrrrk....", "...krrlrrrrRk...",
        "...krrRRRrrRk...", "...krRkkkRrRk...", "...krRkkkRrRk...", "...krrRRRrrRk...",
        "....krrrrrRk....", "....krrrrrRk....", ".....krrrRk.....", ".....krrRk......",
        "......krk.......", "......kRk.......", ".......k........", "................"])

    // pozione (farmacie)
    private static let potion = Sprite(palette: ["k": 0x2A2A3A, "c": 0x8A5A2A, "w": 0xD8F0FF,
                                                 "r": 0xE0306A, "R": 0xA01A4A, "l": 0xFF9AC0], rows: [
        "................", "......kkkk......", "......kcck......", "......kwwk......",
        ".....kwwwwk.....", "....kwwwwwwk....", "...kwrrrrrrwk...", "...krrlrrrrrk...",
        "...krlrrrrrrk...", "...krrrrrrRrk...", "...krrrrrRRrk...", "....krrrrrrk....",
        ".....kkkkkk.....", "................", "................", "................"])

    // croce rossa (ospedali)
    private static let redcross = Sprite(palette: ["k": 0x5A1010, "w": 0xF8F4F0, "r": 0xD82020], rows: [
        "................", "..kkkkkkkkkkkk..", "..kwwwwwwwwwwk..", "..kwwwwrrwwwwk..",
        "..kwwwwrrwwwwk..", "..kwwwwrrwwwwk..", "..kwrrrrrrrrwk..", "..kwrrrrrrrrwk..",
        "..kwwwwrrwwwwk..", "..kwwwwrrwwwwk..", "..kwwwwrrwwwwk..", "..kwwwwwwwwwwk..",
        "..kkkkkkkkkkkk..", "................", "................", "................"])

    // boccale di birra (bar, pub)
    private static let beer = Sprite(palette: ["k": 0x6A4010, "w": 0xF8F4E8, "y": 0xF2B233, "l": 0xFFE08A], rows: [
        "................", "...wwwwwww......", "..wwwwwwwww.....", "..kyyyyyyyk.....",
        "..kyyyyyyykkk...", "..kyylyyyyk.k...", "..kyylyyyyk.k...", "..kyyyyyyyk.k...",
        "..kyyyyyyykkk...", "..kyyyyyyyk.....", "..kkkkkkkkk.....", "................",
        "................", "................", "................", "................"])

    // mela (supermercati)
    private static let apple = Sprite(palette: ["k": 0x3A0A0A, "r": 0xD82020, "R": 0x901010,
                                                "l": 0xFF8080, "g": 0x5A3A1A], rows: [
        "................", "........kk......", ".......kgk......", "....kkkgkkk.....",
        "...krrrrrrrk....", "..krrlrrrrrRk...", "..krllrrrrrRk...", "..krrrrrrrrRk...",
        "..krrrrrrrrRk...", "..krrrrrrrRRk...", "...krrrrrRRk....", "....krrkrRk.....",
        ".....kk.kk......", "................", "................", "................"])

    // torta (panetterie, pasticcerie)
    private static let cake = Sprite(palette: ["k": 0x4A2A10, "w": 0xF8F4EC, "r": 0xD82020,
                                               "b": 0xC8864A, "B": 0xA86A3A], rows: [
        "................", "................", "................", "..kkkkkkkkkkkk..",
        "..kwwrwwwwrwwk..", "..kwwwwwrwwwwk..", "..kwrwwwwwwrwk..", "..kbbbbbbbbbbk..",
        "..kBBBBBBBBBBk..", "..kbbbbbbbbbbk..", "..kBBBBBBBBBBk..", "..kkkkkkkkkkkk..",
        "................", "................", "................", "................"])

    // albero (parchi)
    private static let tree = Sprite(palette: ["k": 0x1A3A10, "G": 0x3F8F2E, "g": 0x67B347, "b": 0x7A5A30], rows: [
        "................", "....kkkkkkk.....", "...kGGgGGGGk....", "..kGgGGGgGGGk...",
        "..kGGGGGGGgGk...", "..kGGgGGGGGGk...", "..kGGGGGgGGGk...", "...kGGGGGGGk....",
        "....kkbbkkk.....", "......bb........", "......bb........", "......bb........",
        ".....kbbk.......", "................", "................", "................"])

    // moneta (banche, bancomat)
    private static let coin = Sprite(palette: ["k": 0x5A4010, "y": 0xF2C230, "Y": 0xB8861A, "l": 0xFFF0A0], rows: [
        "................", ".....kkkkkk.....", "....kyyyyyyk....", "...kyylyyyyYk...",
        "..kyylyYYyyyYk..", "..kyyyYyyyyyYk..", "..kyyyyYYyyyYk..", "..kyyyyyyYyyYk..",
        "..kyyyYYYyyyYk..", "...kyyyyyyyYk...", "....kYYYYYYk....", ".....kkkkkk.....",
        "................", "................", "................", "................"])

    // forziere (negozi generici)
    private static let chest = Sprite(palette: ["k": 0x3A2410, "b": 0xA8743A, "B": 0x8A5A2A, "g": 0xC8C8C8], rows: [
        "................", "................", "..kkkkkkkkkkkk..", "..kbbbbbbbbbbk..",
        "..kbBBBBBBBBbk..", "..kbbbbbbbbbbk..", "..kkkkkggkkkkk..", "..kbbbbggbbbbk..",
        "..kbBBBBBBBBbk..", "..kbbbbbbbbbbk..", "..kbbbbbbbbbbk..", "..kkkkkkkkkkkk..",
        "................", "................", "................", "................"])

    // --- sprite aggiuntivi ---
    private static let cup = Sprite(palette: ["k": 0x3A3A3A, "c": 0x6B3E1E, "w": 0xF4F1E8, "g": 0xC9C4B8], rows: [
        "................", "....g...g.......", ".....g...g......", "....g...g.......",
        "..kkkkkkkkk.....", "..kccccccck.....", "..kwwwwwwwkkk...", "..kwwwwwwwk.k...",
        "..kwwwwwwwk.k...", "..kwwwwwwwkkk...", "...kwwwwwk......", "..kkkkkkkkk.....",
        "..kgggggggk.....", "...kkkkkkk......", "................", "................"])

    private static let burger = Sprite(palette: ["k": 0x4A2A10, "b": 0xD89A48, "y": 0xF8EED0, "g": 0x4FAE2F, "r": 0xD83A2A, "m": 0x6B3A1E, "c": 0xF2C230], rows: [
        "................", "................", ".....kkkkkk.....", "...kkbbbbbbkk...",
        "..kbbybbbybbbk..", "..kbbbbbybbbbk..", "..kggggggggggk..", "..krrrrrrrrrrk..",
        "..kmmmmmmmmmmk..", "..kcccccccccck..", "..kbbbbbbbbbbk..", "...kkkkkkkkkk...",
        "................", "................", "................", "................"])

    private static let lava = Sprite(palette: ["k": 0x2A2A2A, "o": 0xFF7A1A, "y": 0xFFD23A, "g": 0xBDBDBD, "G": 0x7E7E7E], rows: [
        "................", "................", "..kkkkkkkkkkkk..", "..kooyoooyoook..",
        "..kgggggggggGk..", "..kgggggggggGk..", "...kgggggggGk...", "...kgggggggGk...",
        "....kgggggGk....", "....kkkkkkkk....", "................", "................",
        "................", "................", "................", "................"])

    private static let water = Sprite(palette: ["k": 0x2A2A2A, "o": 0x3A6AE0, "y": 0x7AB0FF, "g": 0xBDBDBD, "G": 0x7E7E7E], rows: [
        "................", "................", "..kkkkkkkkkkkk..", "..kooyoooyoook..",
        "..kgggggggggGk..", "..kgggggggggGk..", "...kgggggggGk...", "...kgggggggGk...",
        "....kgggggGk....", "....kkkkkkkk....", "................", "................",
        "................", "................", "................", "................"])

    private static let minecart = Sprite(palette: ["k": 0x2A2A2A, "g": 0x9E9E9E, "G": 0x6E6E6E, "d": 0x4A4A4A], rows: [
        "................", "................", "................", "................",
        "................", "..kkkkkkkkkkkk..", "..kgGGGGGGGGgk..", "..kgggggggggGk..",
        "..kgggggggggGk..", "...kgggggggGk...", "..kkkkkkkkkkkk..", "...kdk....kdk...",
        "....k......k....", "................", "................", "................"])

    private static let cartcar = Sprite(palette: ["k": 0x3A2410, "g": 0xC08040, "G": 0x8A5A2A, "d": 0x4A4A4A], rows: [
        "................", "................", "................", "................",
        "................", "..kkkkkkkkkkkk..", "..kgGGGGGGGGgk..", "..kgggggggggGk..",
        "..kgggggggggGk..", "...kgggggggGk...", "..kkkkkkkkkkkk..", "...kdk....kdk...",
        "....k......k....", "................", "................", "................"])

    private static let bed = Sprite(palette: ["k": 0x3A2410, "w": 0xF4F1E8, "r": 0xC8282E, "b": 0x8A5A2A], rows: [
        "................", "................", "................", "................",
        "................", "................", "................", ".kkkkkkkkkkkkkk.",
        ".kwwwkrrrrrrrrk.", ".kwwwkrrrrrrrrk.", ".kbbbbbbbbbbbbk.", ".kbkkkkkkkkkkbk.",
        ".kbk........kbk.", ".kkk........kkk.", "................", "................"])

    private static let church = Sprite(palette: ["y": 0xF2C230, "k": 0x3A3A3A, "r": 0x8A4A3A, "s": 0xC8C4B8], rows: [
        ".......y........", "......yyy.......", ".......y........", "......kkk.......",
        ".....krrrk......", "....krrrrrk.....", "...krrrrrrrk....", "..krrrrrrrrrk...",
        ".kkkkkkkkkkkkk..", "..ksssssssssk...", "..ksksssssksk...", "..ksksssssksk...",
        "..kssskkksssk...", "..kssskkksssk...", "..kkkkkkkkkkk...", "................"])

    private static let painting = Sprite(palette: ["k": 0x3A2410, "b": 0xA8743A, "c": 0x7AB8F0, "y": 0xF2E23A, "g": 0x4FAE2F], rows: [
        "................", "................", "..kkkkkkkkkkkk..", "..kbbbbbbbbbbk..",
        "..kbccccccccbk..", "..kbccycccccbk..", "..kbcccccgccbk..", "..kbcccgggggbk..",
        "..kbggggggggbk..", "..kbbbbbbbbbbk..", "..kkkkkkkkkkkk..", "................",
        "................", "................", "................", "................"])

    private static let ball = Sprite(palette: ["k": 0x2A2A2A, "w": 0xF4F4F4], rows: [
        "................", "................", "................", ".....kkkkkk.....",
        "....kwwwwwwk....", "...kwwkkwwwwk...", "...kwkkkkwwwk...", "...kwwkkwwkwk...",
        "...kwwwwwkkkk...", "...kwkwwwwkwk...", "....kwwwwwwk....", ".....kkkkkk.....",
        "................", "................", "................", "................"])

    private static let anvil = Sprite(palette: ["k": 0x1A1A1A, "g": 0x5A5A5A], rows: [
        "................", "................", "................", "................",
        "................", "................", "..kkkkkkkkkkkk..", "..kggggggggggk..",
        "...kkkggggkkk...", ".....kggggk.....", "....kggggggk....", "...kkkkkkkkkk...",
        "................", "................", "................", "................"])

    private static let campfire = Sprite(palette: ["o": 0xFF6A1A, "y": 0xFFD23A, "b": 0x7A5A30, "k": 0x3A2410], rows: [
        "................", "................", "................", "................",
        ".......o........", "......oyo.......", ".....oyyyo......", ".....oyyyo......",
        "....ooyyyoo.....", "....oyyyyyo.....", "...kbbbbbbbbk...", "..kbbkbbbbkbbk..",
        "..kkkkkkkkkkkk..", "................", "................", "................"])

    private static let heart = Sprite(palette: ["k": 0x5A0A0A, "r": 0xE02424, "l": 0xFF8A8A], rows: [
        "................", "................", "................", "...kkk...kkk....",
        "..krrrk.krrrk...", ".krrlrrkrrrrrk..", ".krlrrrrrrrrrk..", ".krrrrrrrrrrrk..",
        "..krrrrrrrrrk...", "...krrrrrrrk....", "....krrrrrk.....", ".....krrrk......",
        "......krk.......", ".......k........", "................", "................"])

    private static let diamond = Sprite(palette: ["k": 0x0E4F4E, "C": 0xCFFFFB, "c": 0x4AE8E0, "d": 0x1CA8A0], rows: [
        "................", "................", "................", ".....kkkkkk.....",
        "....kCCcccck....", "...kCCcccccck...", "..kCccccccccck..", "..kccccccccddk..",
        "...kcccccddk....", "....kcccddk.....", ".....kcddk......", "......kdk.......",
        ".......k........", "................", "................", "................"])

    private static let boots = Sprite(palette: ["k": 0x3A2410, "b": 0x8A5A2A], rows: [
        "................", "................", "................", "................",
        "..kkkk...kkkk...", "..kbbk...kbbk...", "..kbbk...kbbk...", "..kbbk...kbbk...",
        "..kbbbkk.kbbbkk.", "..kbbbbbkkbbbbbk", "..kkkkkkkkkkkkkk", "................",
        "................", "................", "................", "................"])

    private static let bookshelf = Sprite(palette: ["k": 0x3A2410, "b": 0xA8743A, "r": 0xC8282E, "g": 0x3F8F2E, "u": 0x3A5AD0, "y": 0xE0C040], rows: [
        "................", "................", "..kkkkkkkkkkkk..", "..kbbbbbbbbbbk..",
        "..kbrguyrguybk..", "..kbrguyrguybk..", "..kbbbbbbbbbbk..", "..kbyurgyurgbk..",
        "..kbyurgyurgbk..", "..kbbbbbbbbbbk..", "..kkkkkkkkkkkk..", "................",
        "................", "................", "................", "................"])

    private static let emerald = Sprite(palette: ["k": 0x0A4A1A, "g": 0x2ED36B, "G": 0x9BFFB8, "d": 0x149A44], rows: [
        "................", "................", "................", "......kkkk......",
        ".....kgGGgk.....", "....kgGGggGk....", "....kgGgggGk....", "....kggggggk....",
        "....kgggggdk....", "....kggggddk....", ".....kgddk......", "......kkkk......",
        "................", "................", "................", "................"])

    private static let icecream = Sprite(palette: ["k": 0x5A3A1A, "p": 0xF5A3C8, "l": 0xFFE0EE, "c": 0xE0A050], rows: [
        "................", "......kkkk......", ".....kppppk.....", "....kpplpppk....",
        "....kppppppk....", "....kkkkkkkk....", "....kcccccck....", ".....kcccck.....",
        ".....kcccck.....", "......kcck......", "......kcck......", ".......kk.......",
        "................", "................", "................", "................"])

    private static let star = Sprite(palette: ["k": 0x6A4A10, "y": 0xF2C230], rows: [
        "................", "................", ".......kk.......", "......kyyk......",
        "......kyyk......", ".kkkkkkyykkkkkk.", "..kyyyyyyyyyyk..", "...kyyyyyyyyk...",
        "....kyyyyyyk....", "....kyyyyyyk....", "...kyyykkyyyk...", "..kyyk....kyyk..",
        "..kkk......kkk..", "................", "................", "................"])

    private static let pillar = Sprite(palette: ["k": 0x3A3A3A, "s": 0xC8C4B8, "S": 0x9A968A], rows: [
        "................", ".....kkkkkk.....", "....kssssssk....", ".....kssssk.....",
        ".....ksSssk.....", ".....ksSssk.....", ".....ksSssk.....", ".....ksSssk.....",
        ".....ksSssk.....", ".....ksSssk.....", ".....ksSssk.....", ".....ksSssk.....",
        "....kssssssk....", "...kkkkkkkkkk...", "................", "................"])

    static func sprite(for cat: POICategory) -> UIImage? {
        let s: Sprite
        switch cat {
        case .restaurant: s = chicken
        case .clothes: s = chestplate
        case .shop: s = chest
        case .supermarket: s = apple
        case .pharmacy: s = potion
        case .hospital: s = redcross
        case .bar: s = beer
        case .bakery: s = cake
        case .park: s = tree
        case .bank: s = coin
        case .dog: s = bone
        case .garden: s = tulip
        case .townhall: s = bell
        case .police: s = shield
        case .parking: s = meter
        case .school: s = book
        case .post: s = envelope
        case .default: s = pin
        case .cafe: s = cup
        case .fastfood: s = burger
        case .fuel: s = lava
        case .swimming: s = water
        case .rail: s = minecart
        case .car: s = cartcar
        case .lodging: s = bed
        case .worship: s = church
        case .museum: s = painting
        case .sport: s = ball
        case .fitness: s = anvil
        case .camping: s = campfire
        case .clinic: s = heart
        case .jewelry: s = diamond
        case .shoes: s = boots
        case .library: s = bookshelf
        case .atm: s = emerald
        case .icecream: s = icecream
        case .attraction: s = star
        case .monument: s = pillar
        default: return nil
        }
        return render(s, pixel: 3)
    }

    private static func render(_ sprite: Sprite, pixel: CGFloat) -> UIImage {
        let rows = sprite.rows
        let h = CGFloat(rows.count), w = CGFloat(rows.map { $0.count }.max() ?? 0)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 2
        return UIGraphicsImageRenderer(size: CGSize(width: w * pixel, height: h * pixel), format: fmt).image { ctx in
            let c = ctx.cgContext
            c.setShouldAntialias(false)
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() {
                    guard let hex = sprite.palette[ch] else { continue }
                    c.setFillColor(UIColor(hex: hex).cgColor)
                    c.fill(CGRect(x: CGFloat(x) * pixel, y: CGFloat(y) * pixel, width: pixel, height: pixel))
                }
            }
        }
    }
}
