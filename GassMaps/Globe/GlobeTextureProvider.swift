import UIKit
import CoreLocation
import MapLibre

/// Genera la texture equirettangolare del globo per ogni tema
/// facendo uno snapshot del mondo intero con lo stile "_globe" del tema.
final class GlobeTextureProvider {
    static let shared = GlobeTextureProvider()

    private var memory: [String: UIImage] = [:]
    private var pending: [String: [(UIImage?) -> Void]] = [:]
    private var snapshotters: [String: MLNMapSnapshotter] = [:]
    private let version = "v12"

    private var cacheDir: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GlobeTextures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func cached(_ theme: MapTheme) -> UIImage? {
        if let img = memory[theme.id] { return img }
        let url = cacheDir.appendingPathComponent("\(theme.id)_\(version).jpg")
        if let data = try? Data(contentsOf: url), let img = UIImage(data: data) {
            memory[theme.id] = img
            return img
        }
        return nil
    }

    func texture(for theme: MapTheme, completion: @escaping (UIImage?) -> Void) {
        if let img = cached(theme) {
            completion(img)
            return
        }
        if pending[theme.id] != nil {
            pending[theme.id]?.append(completion)
            return
        }
        pending[theme.id] = [completion]

        let size = CGSize(width: 4096, height: 4096)
        let camera = MLNMapCamera(lookingAtCenter: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                                  altitude: 20_000_000, pitch: 0, heading: 0)
        let options = MLNMapSnapshotOptions(styleURL: theme.globeStyleURL, camera: camera, size: size)
        options.zoomLevel = 3
        options.scale = 1
        let snapshotter = MLNMapSnapshotter(options: options)
        snapshotters[theme.id] = snapshotter

        let themeID = theme.id
        let polar = theme.polar
        let fileURL = cacheDir.appendingPathComponent("\(themeID)_\(version).jpg")

        snapshotter.start { [weak self] snapshot, _ in
            guard let self = self else { return }
            self.snapshotters[themeID] = nil
            let image = snapshot?.image
            DispatchQueue.global(qos: .userInitiated).async {
                var result: UIImage?
                if let img = image {
                    result = GlobeTextureProvider.equirectangular(fromMercator: img, polar: polar)
                    if let r = result, let data = r.jpegData(compressionQuality: 0.9) {
                        try? data.write(to: fileURL)
                    }
                }
                DispatchQueue.main.async {
                    if let r = result { self.memory[themeID] = r }
                    let callbacks = self.pending[themeID] ?? []
                    self.pending[themeID] = nil
                    callbacks.forEach { $0(result) }
                }
            }
        }
    }

    /// Precarica tutte le texture una alla volta.
    func preloadAll(_ themes: [MapTheme], index: Int = 0) {
        guard index < themes.count else { return }
        texture(for: themes[index]) { [weak self] _ in
            self?.preloadAll(themes, index: index + 1)
        }
    }

    /// Converte un'immagine Web Mercator (mondo intero, quadrata) in equirettangolare 2:1.
    static func equirectangular(fromMercator image: UIImage, polar: UIColor) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let srcW = cg.width
        let srcH = cg.height
        let outW = srcW
        let outH = srcW / 2
        let maxLat = 85.0511

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: outW, height: outH), format: format)
        return renderer.image { ctx in
            polar.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: outW, height: outH))
            for y in 0..<outH {
                let lat = 90.0 - 180.0 * (Double(y) + 0.5) / Double(outH)
                guard abs(lat) < maxLat else { continue }
                let latRad = lat * .pi / 180
                let mercN = log(tan(.pi / 4 + latRad / 2))
                let sy = (1 - mercN / .pi) / 2 * Double(srcH)
                let row = min(max(Int(sy), 0), srcH - 1)
                if let rowImage = cg.cropping(to: CGRect(x: 0, y: row, width: srcW, height: 1)) {
                    UIImage(cgImage: rowImage).draw(in: CGRect(x: 0, y: y, width: outW, height: 1))
                }
            }
        }
    }

    static func fallback(for theme: MapTheme) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 256, height: 128), format: format).image { ctx in
            theme.polar.withAlphaComponent(1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 256, height: 128))
        }
    }
}
