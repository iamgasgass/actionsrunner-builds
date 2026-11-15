//
//  LiveContainerAppIcon.swift
//  StikDebug (LiveContainer fork)
//
//  Loads the icon of a LiveContainer guest app straight from its .app bundle
//  (guests are not installed on the device, so the device icon service can't provide it).
//

import SwiftUI
import UIKit

enum LiveContainerAppIconStore {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 200
        return cache
    }()

    static func cachedIcon(for app: LiveContainerGuestApp) -> UIImage? {
        cache.object(forKey: app.bundleURL.path as NSString)
    }

    static func loadIcon(for app: LiveContainerGuestApp) async -> UIImage? {
        if let cached = cachedIcon(for: app) { return cached }
        let bundleURL = app.bundleURL
        let image = await Task.detached(priority: .utility) { () -> UIImage? in
            guard let image = Self.readIcon(bundleURL: bundleURL) else { return nil }
            return image.preparingForDisplay() ?? image
        }.value
        if let image {
            cache.setObject(image, forKey: bundleURL.path as NSString)
        }
        return image
    }

    nonisolated private static func readIcon(bundleURL: URL) -> UIImage? {
        let info = NSDictionary(contentsOf: bundleURL.appendingPathComponent("Info.plist")) as? [String: Any] ?? [:]
        var names: [String] = []

        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            if let icons = info[key] as? [String: Any],
               let primary = icons["CFBundlePrimaryIcon"] as? [String: Any] {
                if let files = primary["CFBundleIconFiles"] as? [String] {
                    names += files.reversed() // largest icon is usually last
                }
                if let name = primary["CFBundleIconName"] as? String {
                    names.append(name)
                }
            }
        }
        if let files = info["CFBundleIconFiles"] as? [String] {
            names += files.reversed()
        }
        if let file = info["CFBundleIconFile"] as? String {
            names.append(file)
        }
        names.append(contentsOf: ["AppIcon60x60", "AppIcon", "Icon"])

        let bundle = Bundle(url: bundleURL)
        var seen = Set<String>()
        for name in names where seen.insert(name).inserted {
            let base = (name as NSString).deletingPathExtension
            for suffix in ["@3x.png", "@2x.png", ".png", ""] {
                let url = bundleURL.appendingPathComponent(base + suffix)
                if FileManager.default.fileExists(atPath: url.path), let image = UIImage(contentsOfFile: url.path) {
                    return image
                }
            }
            if let bundle, let image = UIImage(named: base, in: bundle, compatibleWith: nil) {
                return image
            }
        }

        // Last resort: the biggest PNG whose name looks like an app icon.
        let files = (try? FileManager.default.contentsOfDirectory(atPath: bundleURL.path)) ?? []
        let candidates = files
            .filter { $0.lowercased().hasPrefix("appicon") && $0.lowercased().hasSuffix(".png") }
            .compactMap { UIImage(contentsOfFile: bundleURL.appendingPathComponent($0).path) }
        return candidates.max { $0.size.width * $0.scale < $1.size.width * $1.scale }
    }
}

/// Same look as the icons in the JIT tab (54 pt, continuous corners, soft shadow).
struct LiveContainerAppIconView: View {
    let app: LiveContainerGuestApp
    @State private var image: UIImage?

    init(app: LiveContainerGuestApp) {
        self.app = app
        _image = State(initialValue: LiveContainerAppIconStore.cachedIcon(for: app))
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 3, x: 0, y: 1.5)
                    .transition(.opacity.combined(with: .scale))
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(UIColor.systemGray5))
                    .frame(width: 54, height: 54)
                    .overlay {
                        Image(systemName: "app")
                            .font(.system(size: 24, weight: .regular))
                            .foregroundStyle(.gray)
                    }
            }
        }
        .accessibilityHidden(true)
        .task(id: app.id) {
            guard image == nil else { return }
            let loaded = await LiveContainerAppIconStore.loadIcon(for: app)
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
    }
}
