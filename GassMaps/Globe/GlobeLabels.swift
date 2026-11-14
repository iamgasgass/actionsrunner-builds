import Foundation

/// Etichette del globo (sempre rivolte verso lo schermo, come nell'originale).
struct GlobeLabel {
    let name: String
    let lat: Double
    let lon: Double
    let isCity: Bool
}

enum GlobeLabels {
    static let countries: [(String, Double, Double)] = [
        ("greenland", 72, -40), ("iceland", 64.9, -18.6), ("svalbard", 78.5, 17), ("norway", 61.5, 8.5),
        ("sweden", 62.5, 16), ("finland", 63.5, 26.5), ("estonia", 58.7, 25.5), ("latvia", 56.9, 24.8),
        ("lithuania", 55.3, 23.9), ("denmark", 56, 9.3), ("united kingdom", 53.5, -2), ("ireland", 53.2, -8),
        ("france", 46.6, 2.4), ("spain", 40.2, -3.7), ("portugal", 39.6, -8.1), ("germany", 51.1, 10.4),
        ("poland", 52.1, 19.4), ("belarus", 53.6, 28), ("ukraine", 49, 31.5), ("italy", 42.8, 12.6),
        ("switzerland", 46.8, 8.2), ("austria", 47.6, 14.1), ("czechia", 49.8, 15.5), ("hungary", 47.1, 19.4),
        ("romania", 45.9, 24.9), ("bulgaria", 42.7, 25.3), ("serbia", 44, 20.9), ("croatia", 45.4, 15.9),
        ("greece", 39.3, 22), ("türkiye", 39, 35), ("cyprus", 35, 33.2), ("moldova", 47.2, 28.5),
        ("netherlands", 52.2, 5.5), ("belgium", 50.6, 4.6), ("russia", 61, 90), ("kazakhstan", 48, 67),
        ("georgia", 42.2, 43.5), ("armenia", 40.2, 45), ("azerbaijan", 40.3, 47.7), ("syria", 35, 38.5),
        ("lebanon", 33.9, 35.9), ("israel", 31.3, 34.9), ("jordan", 31, 36.5), ("iraq", 33, 43.7),
        ("iran", 32.4, 53.7), ("kuwait", 29.3, 47.6), ("saudi arabia", 24, 45), ("yemen", 15.6, 47.6),
        ("oman", 20.5, 56.5), ("united arab emirates", 23.8, 54), ("qatar", 25.3, 51.2), ("egypt", 26.6, 30),
        ("libya", 27, 17), ("tunisia", 34, 9.5), ("algeria", 28, 2.6), ("morocco", 31.8, -6.6),
        ("western sahara", 24.5, -13), ("mauritania", 20.3, -10.3), ("mali", 17.5, -3.5), ("niger", 17.6, 9.4),
        ("chad", 15.4, 18.7), ("sudan", 15.8, 30.2), ("ethiopia", 9, 39.6), ("somalia", 6, 46),
        ("kenya", 0.5, 37.9), ("nigeria", 9.6, 8.1), ("cameroon", 5.7, 12.7), ("dr congo", -2.9, 23.6),
        ("angola", -12.3, 17.5), ("tanzania", -6.3, 34.8), ("zambia", -13.5, 27.8), ("namibia", -22.6, 17.2),
        ("botswana", -22.2, 23.8), ("south africa", -29, 25), ("madagascar", -19.4, 46.7), ("mozambique", -17.3, 35.5),
        ("turkmenistan", 39, 59.5), ("uzbekistan", 41.7, 63.9), ("kyrgyzstan", 41.5, 74.6), ("tajikistan", 38.9, 71),
        ("afghanistan", 33.8, 66), ("pakistan", 29.9, 69.4), ("india", 22.5, 79), ("nepal", 28.3, 84),
        ("bhutan", 27.4, 90.4), ("bangladesh", 23.8, 90.3), ("myanmar", 21, 96), ("thailand", 15.5, 101),
        ("laos", 19.5, 102.5), ("vietnam", 15.5, 107.5), ("cambodia", 12.7, 104.9), ("malaysia", 3.8, 102.2),
        ("indonesia", -2.2, 117.3), ("philippines", 12.5, 122.9), ("china", 35.5, 103), ("mongolia", 46.8, 103),
        ("north korea", 40.2, 127.2), ("south korea", 36.4, 127.9), ("japan", 37, 139), ("taiwan", 23.7, 121),
        ("sri lanka", 7.8, 80.7), ("australia", -25, 134), ("new zealand", -42, 172.5), ("papua new guinea", -6.5, 145),
        ("canada", 58, -100), ("united states", 39.5, -98.5), ("alaska", 64, -152), ("mexico", 23.8, -102.5),
        ("guatemala", 15.6, -90.3), ("cuba", 21.8, -79), ("haiti", 19, -72.5), ("colombia", 4, -73),
        ("venezuela", 7, -66), ("ecuador", -1.5, -78.4), ("peru", -9.5, -75), ("brazil", -10.5, -52),
        ("bolivia", -16.7, -64.6), ("paraguay", -23.3, -58.4), ("chile", -30, -71), ("argentina", -35, -65),
        ("uruguay", -32.8, -56), ("guyana", 4.9, -58.9), ("antarctica", -82, 0)
    ]

    static let cities: [(String, Double, Double)] = [
        ("moscow", 55.75, 37.62), ("kazan", 55.79, 49.12), ("chelyabinsk", 55.16, 61.4), ("novosibirsk", 55.03, 82.92),
        ("krasnoyarsk", 56.01, 92.87), ("saint petersburg", 59.93, 30.36), ("london", 51.5, -0.12), ("paris", 48.86, 2.35),
        ("madrid", 40.42, -3.7), ("rome", 41.9, 12.5), ("berlin", 52.52, 13.4), ("istanbul", 41.01, 28.97),
        ("cairo", 30.04, 31.24), ("amman", 31.95, 35.93), ("riyadh", 24.71, 46.68), ("tehran", 35.69, 51.39),
        ("baghdad", 33.31, 44.36), ("dubai", 25.2, 55.27), ("karachi", 24.86, 67.0), ("lahore", 31.55, 74.34),
        ("delhi", 28.61, 77.2), ("mumbai", 19.07, 72.88), ("dhaka", 23.81, 90.41), ("almaty", 43.24, 76.89),
        ("tashkent", 41.3, 69.24), ("beijing", 39.9, 116.4), ("tianjin", 39.34, 117.36), ("shanghai", 31.23, 121.47),
        ("guangzhou", 23.13, 113.26), ("hong kong", 22.32, 114.17), ("seoul", 37.57, 126.98), ("tokyo", 35.68, 139.69),
        ("osaka", 34.69, 135.5), ("bangkok", 13.76, 100.5), ("singapore", 1.35, 103.82), ("jakarta", -6.2, 106.85),
        ("manila", 14.6, 120.98), ("sydney", -33.87, 151.21), ("melbourne", -37.81, 144.96), ("lagos", 6.52, 3.38),
        ("nairobi", -1.29, 36.82), ("johannesburg", -26.2, 28.05), ("rabat", 34.02, -6.84), ("algiers", 36.75, 3.06),
        ("new york", 40.71, -74.0), ("washington", 38.9, -77.04), ("boston", 42.36, -71.06), ("chicago", 41.88, -87.63),
        ("toronto", 43.65, -79.38), ("montreal", 45.5, -73.57), ("quebec", 46.81, -71.21), ("houston", 29.76, -95.37),
        ("los angeles", 34.05, -118.24), ("san francisco", 37.77, -122.42), ("vancouver", 49.28, -123.12),
        ("calgary", 51.05, -114.07), ("miami", 25.76, -80.19), ("mexico city", 19.43, -99.13), ("havana", 23.11, -82.37),
        ("bogotá", 4.71, -74.07), ("lima", -12.05, -77.04), ("são paulo", -23.55, -46.63), ("rio de janeiro", -22.91, -43.17),
        ("buenos aires", -34.6, -58.38), ("santiago", -33.45, -70.67), ("reykjavík", 64.15, -21.94)
    ]

    static let oceans: [(String, Double, Double)] = [
        ("north atlantic ocean", 35, -40), ("south atlantic ocean", -25, -15), ("north pacific ocean", 30, -160),
        ("south pacific ocean", -25, -130), ("indian ocean", -20, 80), ("arctic ocean", 84, 0)
    ]

    static var all: [GlobeLabel] {
        countries.map { GlobeLabel(name: $0.0, lat: $0.1, lon: $0.2, isCity: false) }
            + oceans.map { GlobeLabel(name: $0.0, lat: $0.1, lon: $0.2, isCity: false) }
            + cities.map { GlobeLabel(name: $0.0, lat: $0.1, lon: $0.2, isCity: true) }
    }
}

/// Luoghi mostrati sul globo: le stesse icone dei POI della vista mappa del tema.
enum GlobeMarkers {
    /// posizioni sparse su tutti i continenti
    private static let spots: [(Double, Double)] = [
        (51.5, -0.1), (48.9, 2.4), (41.9, 12.5), (40.4, -3.7), (52.5, 13.4), (59.3, 18.1), (55.8, 37.6),
        (41.0, 29.0), (30.0, 31.2), (24.7, 46.7), (25.2, 55.3), (28.6, 77.2), (19.1, 72.9), (13.8, 100.5),
        (39.9, 116.4), (31.2, 121.5), (37.6, 127.0), (35.7, 139.7), (1.35, 103.8), (-6.2, 106.8),
        (-33.9, 151.2), (-37.8, 145.0), (-26.2, 28.0), (6.5, 3.4), (-1.3, 36.8), (33.6, -7.6),
        (40.7, -74.0), (41.9, -87.6), (34.1, -118.2), (37.8, -122.4), (49.3, -123.1), (43.7, -79.4),
        (29.8, -95.4), (25.8, -80.2), (19.4, -99.1), (4.7, -74.1), (-12.0, -77.0), (-23.5, -46.6),
        (-34.6, -58.4), (64.1, -21.9), (60.2, 24.9), (50.1, 14.4), (47.5, 19.0), (38.0, 23.7),
        (35.7, 51.4), (43.2, 76.9), (55.0, 82.9), (62.0, 129.7), (64.8, -147.7), (61.2, -149.9)
    ]

    /// categorie in ordine di apparizione (variate per ogni tema)
    private static let categories: [POICategory] = [
        .restaurant, .clothes, .police, .lodging, .bar, .park, .hospital, .supermarket, .bank, .cinema,
        .fuel, .school, .museum, .cafe, .car, .parking, .theatre, .shop, .pharmacy, .worship,
        .rail, .sport, .post, .townhall, .garden, .attraction, .bakery, .fastfood, .swimming, .fitness,
        .default, .monument, .nightclub, .jewelry, .dog, .playground, .fire, .camping, .library, .atm,
        .bus, .clinic, .shoes, .carrepair, .icecream, .university, .bicycle, .charging, .hairdresser, .default
    ]

    static func list(for theme: MapTheme) -> [(lat: Double, lon: Double, category: POICategory)] {
        let shift = (Themes.all.firstIndex(of: theme) ?? 0) * 7
        return spots.enumerated().map { i, spot in
            (spot.0, spot.1, categories[(i + shift) % categories.count])
        }
    }
}
