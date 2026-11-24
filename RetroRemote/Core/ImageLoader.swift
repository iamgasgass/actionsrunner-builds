import UIKit

final class ImageLoader {
    static let shared = ImageLoader()
    private let cache = NSCache<NSURL, UIImage>()

    func load(_ url: URL, completion: @escaping (UIImage?) -> Void) {
        if let cached = cache.object(forKey: url as NSURL) {
            completion(cached)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            let image = data.flatMap { UIImage(data: $0) }
            if let image = image { self?.cache.setObject(image, forKey: url as NSURL) }
            DispatchQueue.main.async { completion(image) }
        }.resume()
    }
}
