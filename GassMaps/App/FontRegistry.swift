import UIKit
import CoreText
import SwiftUI

/// Registra a runtime i font presenti nel bundle (cartella GassMaps/Fonts).
/// Per il font di GTA San Andreas copia "pricedown.ttf" / "pricedown bl.otf" in GassMaps/Fonts:
/// viene trovato e usato automaticamente (splash, nomi dei temi, etichette del globo GTA).
enum FontRegistry {
    /// Nome PostScript del font Pricedown, se presente nel bundle.
    static let pricedown: String? = {
        let exts = ["ttf", "otf", "TTF", "OTF"]
        var urls: [URL] = []
        for ext in exts {
            urls += Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? []
            urls += Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: "Fonts") ?? []
        }
        var found: String?
        for url in urls {
            guard let provider = CGDataProvider(url: url as CFURL),
                  let cgFont = CGFont(provider),
                  let psName = cgFont.postScriptName as String? else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            if url.lastPathComponent.lowercased().contains("pricedown") || psName.lowercased().contains("pricedown") {
                found = psName
            }
        }
        return found
    }()

    /// Font "stile GTA": Pricedown se disponibile, altrimenti un sostituto pesante e condensato.
    static func gta(size: CGFloat) -> Font {
        if let name = pricedown { return .custom(name, size: size) }
        return .system(size: size, weight: .black, design: .default).width(.condensed)
    }

    static func gtaUIFont(size: CGFloat) -> UIFont {
        if let name = pricedown, let f = UIFont(name: name, size: size) { return f }
        return UIFont(name: "Futura-CondensedExtraBold", size: size) ?? .systemFont(ofSize: size, weight: .black)
    }
}
