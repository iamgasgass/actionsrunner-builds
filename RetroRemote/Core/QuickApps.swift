import Foundation

/// Identificativi delle app più usate per ogni piattaforma (avvio con un tocco).
enum QuickApps {
    static let names = ["Netflix", "YouTube", "Prime Video", "Disney+"]

    static func apps(for brand: TVBrand) -> [TVApp] {
        let ids: [String]
        var extra: String? = nil
        switch brand {
        case .roku:
            ids = ["12", "837", "13", "291097"]
        case .samsung:
            ids = ["3201907018807", "111299001912", "3201910019365", "3201901017640"]
            extra = "2"
        case .lg:
            ids = ["netflix", "youtube.leanback.v4", "amazon", "com.disney.disneyplus-prod"]
        case .androidTV:
            ids = ["https://www.netflix.com/title", "https://www.youtube.com",
                   "https://app.primevideo.com", "https://www.disneyplus.com"]
        case .fireTV:
            ids = ["com.netflix.ninja", "com.amazon.firetv.youtube", "com.amazon.avod", "com.disney.disneyplus"]
        case .panasonic:
            ids = ["0010000200000001", "0070000200180001", "0010000100180001", ""]
        case .vizio:
            ids = []
        }
        return zip(names, ids).compactMap { name, id in
            id.isEmpty ? nil : TVApp(id: id, name: name, iconURL: nil, extra: extra)
        }
    }
}
