#!/usr/bin/env python3
"""Genera gli stili MapLibre (mappa + globo) per tutti i temi di GassMaps.

Uso:  python3 tools/generate_styles.py
Scrive i file in GassMaps/Styles/<id>.json e GassMaps/Styles/<id>_globe.json
Fonte dati: OpenFreeMap (schema OpenMapTiles) - gratuita, senza API key.
"""
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "GassMaps", "Styles")

SOURCE = {"type": "vector", "url": "https://tiles.openfreemap.org/planet"}
GLYPHS = "https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf"
BOLD = ["Noto Sans Bold"]
REG = ["Noto Sans Regular"]
ITAL = ["Noto Sans Italic"]

NAME = ["coalesce", ["get", "name:it"], ["get", "name:latin"], ["get", "name"]]
NAME_EN = ["coalesce", ["get", "name:en"], ["get", "name:latin"], ["get", "name"]]

THEMES = {
    # ex "Saint Denis II" -> seppia western
    "dust": dict(
        land="#d6c19a", wood="#c9b287", grass="#cfb98f", sand="#e0cda6", ice="#efe6d2",
        park="#c5ae80", water="#a99f86", waterway="#9c927a", building="#bfa77c",
        building_top="#cbb489", minor="#f1e4c4", major="#f6ead0", motor="#fbf1dc",
        path="#e6d6b2", rail="#8f7b58", boundary="#7a6646", label="#3d2b16",
        halo="#e3d1ac", road_label="#3d2b16", road_halo="#efe1c0", house="#8a7550",
        water_label="#6b604a", shield="#7a5a2e", oneway=0.0, transform="uppercase",
    ),
    # ex "Los Santas" -> noir urbano (tema predefinito)
    "noir": dict(
        land="#303030", wood="#2e302e", grass="#2f312f", sand="#343332", ice="#4a4f53",
        park="#2d2f2d", water="#36414a", waterway="#36414a", building="#1b1b1b",
        building_top="#202020", minor="#a9a9a9", major="#ababab", motor="#b4b4b4",
        path="#6e6e6e", rail="#5c5c5c", boundary="#8a8a8a", label="#fcfcfc",
        halo="#000000", road_label="#fcfcfc", road_halo="#000000", house="#a0a0a0",
        water_label="#9fb2bf", shield="#2f47c9", oneway=0.8, transform="uppercase",
    ),
    # ex "PipBoy" -> terminale verde
    "bunker": dict(
        land="#061206", wood="#071707", grass="#071607", sand="#081808", ice="#0d260d",
        park="#082008", water="#020a02", waterway="#0a3a0a", building="#0b2a0b",
        building_top="#0f360f", minor="#1f9e1f", major="#2ccf2c", motor="#45ff45",
        path="#157015", rail="#1b7f1b", boundary="#2ccf2c", label="#5dff5d",
        halo="#000000", road_label="#7dff7d", road_halo="#000000", house="#2a9a2a",
        water_label="#3fcf3f", shield="#0f5f0f", oneway=0.6, transform="uppercase",
    ),
    # ex "Pixel Map" -> mondo a blocchi
    "pixel": dict(
        land="#79b64c", wood="#4f8f2f", grass="#7fc152", sand="#ddd08f", ice="#f4f7f7",
        park="#5ea338", water="#3d3ad6", waterway="#3d3ad6", building="#8c8c8c",
        building_top="#a3a3a3", minor="#c8b88a", major="#d9c896", motor="#e8d9a5",
        path="#a8996c", rail="#6b5a3a", boundary="#c0392b", label="#ffffff",
        halo="#1d1d4a", road_label="#ffffff", road_halo="#3a3a3a", house="#e9f3dd",
        water_label="#9fd1ff", shield="#3d3ad6", oneway=0.5, transform="none",
    ),
    # ex "Night City" -> distretto al neon
    "neon": dict(
        land="#0e0a12", wood="#100c14", grass="#100c15", sand="#130e16", ice="#1a1424",
        park="#120f1a", water="#081221", waterway="#0b1a33", building="#1b1024",
        building_top="#2a1838", minor="#b0205f", major="#ff2e7e", motor="#ff5fa2",
        path="#6a1640", rail="#3fd8ff", boundary="#c9a040", label="#3ff2ff",
        halo="#000000", road_label="#bff9ff", road_halo="#000000", house="#7a5c8c",
        water_label="#3f8fbf", shield="#ff2e7e", oneway=0.6, transform="uppercase",
    ),
    # ex "San Andrias" -> costa soleggiata
    "palm": dict(
        land="#86a072", wood="#6f8c5c", grass="#8daa76", sand="#cdbf94", ice="#e8eef0",
        park="#77955f", water="#6a92b8", waterway="#6a92b8", building="#9b9886",
        building_top="#aeab98", minor="#e9e5d6", major="#f2eedf", motor="#fff8e3",
        path="#c9c4b0", rail="#5b5b55", boundary="#4f4f4f", label="#ffffff",
        halo="#1c1c1c", road_label="#ffffff", road_halo="#2a2a2a", house="#f0f0e8",
        water_label="#e6f2ff", shield="#2f47c9", oneway=0.6, transform="uppercase",
    ),
    # ex "Heat Racing" -> viola notturno
    "heat": dict(
        land="#3a1162", wood="#341058", grass="#3f1569", sand="#4c1f78", ice="#c9b3ff",
        park="#43176f", water="#170a3d", waterway="#22105a", building="#4b1c7c",
        building_top="#5d2793", minor="#b98cff", major="#d7b8ff", motor="#f0e2ff",
        path="#7d52b8", rail="#9a7ad0", boundary="#d7b8ff", label="#ffffff",
        halo="#22003f", road_label="#ffffff", road_halo="#22003f", house="#cdb5f2",
        water_label="#b49cff", shield="#ff3d8b", oneway=0.6, transform="uppercase",
    ),
    # ex "The Rivia III" -> pergamena medievale
    "kingdom": dict(
        land="#b8925a", wood="#a6844f", grass="#b38f58", sand="#c7a46c", ice="#e3d3b0",
        park="#a5864f", water="#6f7a62", waterway="#66705a", building="#8f6c3c",
        building_top="#9c7845", minor="#e5cf9f", major="#ecd8ab", motor="#f3e2bb",
        path="#a8895a", rail="#4a3520", boundary="#4a3520", label="#2b1b0b",
        halo="#d9bb85", road_label="#2b1b0b", road_halo="#e2c895", house="#5a4122",
        water_label="#e8dcc0", shield="#5a4122", oneway=0.0, transform="none",
    ),
    # mappa tattica grigia (ispirata alla mappa allegata): area chiara, alberi/acqua scuri
    "contract": dict(
        land="#c2c5c7", wood="#2b2c2e", grass="#c7cacc", sand="#cfd1d3", ice="#e6e8e9",
        park="#c7cacc", water="#34363a", waterway="#34363a", building="#9ea1a4",
        building_top="#a9acaf", minor="#d6d8da", major="#dcdee0", motor="#e2e4e5",
        path="#9a9da0", rail="#6f7275", boundary="#5a5d60", label="#ffffff",
        halo="#3a3b3e", road_label="#ffffff", road_halo="#4a4c4f", house="#5f6265",
        water_label="#c9ccce", shield="#2a2b2d", oneway=0.0, transform="none",
    ),
    # isola battle royale (ispirata alla mappa allegata): prati, boschi, sabbia, fiumi azzurri
    "storm": dict(
        land="#43722f", wood="#2f5a22", grass="#4b7d35", sand="#dcc38a", ice="#eaf4ff",
        park="#4a7b33", water="#3d8fe0", waterway="#3d8fe0", building="#cfc8b8",
        building_top="#ddd7c9", minor="#e3c78a", major="#e8cf96", motor="#6a6a6a",
        path="#d8bd80", rail="#5a4a3a", boundary="#ffffff", label="#ffffff",
        halo="#000000", road_label="#ffffff", road_halo="#1a1a1a", house="#ffffff",
        water_label="#e8f4ff", shield="#2f7bff", oneway=0.0, transform="uppercase",
    ),
    # mappa notturna da corse (ispirata alla foto): fondo antracite, quartieri a mimetico turchese, strade kaki
    "canyon": dict(
        land="#1f2627", wood="#283132", grass="#252d2e", sand="#2b3334", ice="#3a4546",
        park="#273031", water="#0f1e24", waterway="#16303a", building="#4d9592",
        building_top="#5aa6a2", minor="#8a8670", major="#959078", motor="#a19c82",
        path="#6f6c5c", rail="#4f5b5c", boundary="#5f7f7a", label="#6f908b",
        halo="#0d1213", road_label="#c9d6d3", road_halo="#0d1213", house="#9fbcb8",
        water_label="#3f7480", shield="#2f47c9", oneway=0.0, transform="uppercase",
    ),
    # come Street Heat ma rosso al posto del viola
    "crimson": dict(
        land="#a81f24", wood="#9a1c21", grass="#ad2228", sand="#b52a2f", ice="#ffb3b3",
        park="#ad2228", water="#3d0a10", waterway="#55101a", building="#b52a30",
        building_top="#c43a40", minor="#a8a8a8", major="#ababab", motor="#b4b4b4",
        path="#6e6e6e", rail="#5c5c5c", boundary="#ffb8b8", label="#ffffff",
        halo="#4a0f14", road_label="#ffffff", road_halo="#4a0f14", house="#ffc9c9",
        water_label="#ff9c9c", shield="#2f47c9", oneway=0.8, transform="uppercase",
    ),
    # mappa di guida notturna (ispirata alla foto allegata): indaco scuro, edifici 3D blu, strade chiare
    "midnight": dict(
        land="#3b4161", wood="#34474f", grass="#36494f", sand="#454a68", ice="#5a6088",
        park="#35494e", water="#262e4c", waterway="#2c3557", building="#46548a",
        building_top="#55639a", minor="#4a5280", major="#59639a", motor="#6a76b0",
        path="#5c6590", rail="#6c7398", boundary="#8d97c6", label="#c9cde3",
        halo="#1f2338", road_label="#ffffff", road_halo="#1f2338", house="#9aa2c8",
        water_label="#8f9ad0", shield="#2f63d6", oneway=0.0, transform="none",
    ),
}


def interp(stops, base=1.5):
    expr = ["interpolate", ["exponential", base], ["zoom"]]
    for z, v in stops:
        expr += [z, v]
    return expr


def cls(*names):
    return ["match", ["get", "class"], list(names), True, False]


def road_line(lid, p, classes, color, widths, minzoom=0, dash=None, opacity=1.0):
    layer = {
        "id": lid,
        "type": "line",
        "source": "openmaptiles",
        "source-layer": "transportation",
        "minzoom": minzoom,
        "filter": ["all", cls(*classes), ["!=", ["get", "brunnel"], "tunnel"]],
        "layout": {"line-cap": "butt" if dash else "round", "line-join": "round"},
        "paint": {"line-color": color, "line-width": interp(widths), "line-opacity": opacity},
    }
    if dash:
        layer["paint"]["line-dasharray"] = dash
    return layer


# Categorie dei luoghi: (categoria, valori OSM "subclass", valori OpenMapTiles "class").
# Si confronta prima il tag OSM preciso (subclass), poi la classe generale.
POI_CATEGORIES = [
    ("park", ["park", "nature_reserve"], ["park"]),
    ("garden", ["garden"], ["garden"]),
    ("playground", ["playground"], ["playground"]),
    ("dog", ["dog_park"], ["dog_park"]),
    ("cinema", ["cinema"], ["cinema"]),
    ("theatre", ["theatre", "arts_centre"], ["theatre"]),
    ("rail", ["station", "halt", "tram_stop", "subway_entrance", "train_station"], ["railway"]),
    ("bus", ["bus_station", "bus_stop"], ["bus"]),
    ("library", ["library", "books"], ["library"]),
    ("fuel", ["fuel"], ["fuel"]),
    ("charging", ["charging_station"], ["charging_station"]),
    ("restaurant", ["restaurant", "food_court"], ["restaurant"]),
    ("fastfood", ["fast_food"], ["fast_food"]),
    ("cafe", ["cafe"], ["cafe"]),
    ("bakery", ["bakery", "pastry", "confectionery"], ["bakery"]),
    ("icecream", ["ice_cream"], ["ice_cream"]),
    ("bar", ["bar", "pub", "biergarten"], ["bar", "beer"]),
    ("nightclub", ["nightclub"], ["music"]),
    ("supermarket", ["supermarket", "convenience", "greengrocer", "butcher", "deli"], ["grocery"]),
    ("clothes", ["clothes", "fashion", "boutique"], ["clothing_store"]),
    ("shoes", ["shoes"], ["shoes"]),
    ("jewelry", ["jewelry"], ["jewelry"]),
    ("pharmacy", ["pharmacy", "chemist"], ["pharmacy"]),
    ("hospital", ["hospital"], ["hospital"]),
    ("clinic", ["clinic", "doctors", "dentist", "veterinary"], ["doctors", "dentist", "veterinary"]),
    ("police", ["police"], ["police"]),
    ("fire", ["fire_station"], ["fire_station"]),
    ("bank", ["bank"], ["bank"]),
    ("atm", ["atm"], ["atm"]),
    ("lodging", ["hotel", "motel", "guest_house", "hostel", "apartment"], ["lodging"]),
    ("camping", ["camp_site", "caravan_site"], ["campsite"]),
    ("school", ["school", "kindergarten"], ["school", "kindergarten"]),
    ("university", ["university", "college"], ["college", "university"]),
    ("parking", ["parking", "parking_entrance"], ["parking"]),
    ("bicycle", ["bicycle_parking", "bicycle_rental", "bicycle"], ["bicycle", "bicycle_rental", "bicycle_parking"]),
    ("sport", ["sports_centre", "stadium", "pitch"], ["stadium", "sports", "pitch"]),
    ("swimming", ["swimming_pool", "water_park"], ["swimming"]),
    ("fitness", ["fitness_centre"], ["fitness"]),
    ("worship", ["place_of_worship"], ["place_of_worship", "religion"]),
    ("museum", ["museum", "gallery"], ["museum", "art_gallery"]),
    ("attraction", ["attraction", "viewpoint", "zoo", "theme_park"], ["attraction", "zoo"]),
    ("monument", ["monument", "memorial", "castle", "ruins"], ["monument", "castle"]),
    ("townhall", ["townhall"], ["town_hall"]),
    ("post", ["post_office"], ["post"]),
    ("car", ["car", "car_rental", "car_wash"], ["car"]),
    ("carrepair", ["car_repair", "tyres"], ["car_repair"]),
    ("hairdresser", ["hairdresser", "beauty"], ["hairdresser"]),
    ("toilets", ["toilets"], ["toilets"]),
    ("shop", [], ["shop", "gift", "mall", "department_store"]),
]


def _poi_expr():
    by_class = ["match", ["get", "class"]]
    seen = set()
    for cat, _, classes in POI_CATEGORIES:
        vals = [c for c in classes if c not in seen]
        seen.update(vals)
        if vals:
            by_class += [vals, "gm-poi-" + cat]
    by_class.append("gm-poi-default")
    expr = ["match", ["get", "subclass"]]
    seen = set()
    for cat, subs, _ in POI_CATEGORIES:
        vals = [v for v in subs if v not in seen]
        seen.update(vals)
        if vals:
            expr += [vals, "gm-poi-" + cat]
    expr.append(by_class)
    return expr


POI_ICON_EXPR = _poi_expr()

# colori per famiglia di luoghi (tema Midnight Route): icona e nome dello stesso colore
POI_FAMILY_COLORS = {
    "#f0a04b": ["restaurant", "fastfood", "cafe", "bakery", "icecream", "bar", "nightclub"],
    "#5e9cf2": ["supermarket", "shop", "clothes", "shoes", "jewelry", "hairdresser"],
    "#9aa6f5": ["fuel", "charging", "parking", "car", "carrepair", "rail", "bus", "bicycle"],
    "#5bb974": ["park", "garden", "playground", "dog", "camping", "sport", "swimming", "fitness"],
    "#e8706a": ["pharmacy", "hospital", "clinic"],
    "#e57fb6": ["lodging"],
    "#2bb5a8": ["cinema", "theatre", "museum", "attraction", "monument", "library"],
}


def _poi_text_color(default):
    expr = ["match", POI_ICON_EXPR]
    for color, cats in POI_FAMILY_COLORS.items():
        expr += [["gm-poi-" + c for c in cats], color]
    expr.append("#aab1d2")
    return expr


# ---------------------------------------------------------------------------
# Impostazioni di resa per tema, ricavate dalle schermate di riferimento.
# road_mode:     "solid" (strade piene) | "casing" (bordo chiaro + interno, a doppia linea)
# building_mode: "extrude" (3D) | "flat" | "ink" (contorno a inchiostro) | "pattern" (texture)
# pattern:       immagini disegnate dall'app (MapIcons.swift) usate come texture
# ---------------------------------------------------------------------------
EXTRA = {
    # rif. schermata 5 — scuro con strade a doppia linea, edifici piatti più chiari, icone nere
    "noir": dict(road_mode="casing", casing="#b8b8b8", inner="#6a6a6a", minor_solid="#a8a8a8",
                 land="#161616", building="#353535", building_mode="flat", water="#34495a",
                 park="#1c1f1c", wood="#1b1d1b", grass="#1b1e1b", labels=True),
    # rif. schermata 2 — pergamena, inchiostro, edifici contornati, sentieri tratteggiati
    "dust": dict(road_mode="solid", minor="#33312b", major="#2c2a25", motor="#24221e",
                 land="#d4c09a", bg_pattern="gm-paper", building="#c3ad89", building_mode="ink",
                 ink="#2e2b24", water="#8f9283", water_outline="#2e2b24", park="#cdb891",
                 wood="#cdb891", grass="#d0bb94", path="#3a362d", rail="#3a362d",
                 label="#2b2924", halo="#d4c09a", road_label="#2b2924", road_halo="#d4c09a", labels=True),
    # rif. schermata 3 — erba, acqua e tetti a blocchi pixelati, strade grigie
    "pixel": dict(road_mode="solid", minor="#8e8e8e", major="#969696", motor="#a0a0a0",
                  land="#6e9050", bg_pattern="gm-grass", water="#5a5abe", water_pattern="gm-water",
                  building="#a8784a", building_mode="pattern", building_pattern="gm-planks",
                  building_pattern_big="gm-stone", park="#6e9050", wood="#4f7a33", grass="#6e9050",
                  label="#ffffff", halo="#2a2a2a", road_label="#ffffff", road_halo="#2a2a2a",
                  transform="none", labels=True),
    # rif. mappa di San Andreas allegata — campagna verde, città grigie, strade chiare, acqua blu-grigia
    "palm": dict(road_mode="solid", minor="#151515", major="#0d0d0d", motor="#050505",
                 land="#5e9e48", urban="#8b8b8b", building="#f4f4f2", building_mode="flat",
                 water="#6e8db4", park="#8cc965", wood="#3f7d32", grass="#7bbd57", sand="#b39a73",
                 path="#c9b892", rail="#5a5a5a", label="#ffffff", halo="#000000",
                 road_label="#ffffff", road_halo="#000000", labels=True),
    # rif. schermata 4 — nero, strade ciano a doppia linea, edifici 3D cremisi, etichette arancioni
    "neon": dict(road_mode="casing", casing="#4b9fb0", inner="#070707", minor_solid=None,
                 land="#070707", building="#b3204a", building_mode="extrude", water="#0f2347",
                 park="#080a08", wood="#080a08", grass="#080a08", label="#ffb02e", halo="#3a1600",
                 road_label="#ffb02e", road_halo="#2a1000", labels=True),
    # rif. schermata Street Heat — satellite viola, strade grigio-azzurre, icone bianche
    "heat": dict(road_mode="solid", minor="#a4b2bc", major="#aab7c0", motor="#b2bec6",
                 land="#9b55dd", satellite=True, building="#b8a8ff", building_mode="flat", building_opacity=0.18,
                 water="#2a1260", park="#9b55dd", wood="#9b55dd", grass="#9b55dd",
                 path="#8f9aaa", rail="#8f9aaa", label="#ffffff", halo="#2a1e5a",
                 road_label="#ffffff", road_halo="#2a1e5a", labels=True),
    # rif. schermata Old Kingdom — terra kaki, tetti di coppi in 3D, strade chiare, etichette crema
    "kingdom": dict(road_mode="solid", minor="#c4c6b6", major="#cacbbc", motor="#d0d0c2",
                    land="#97957f", building="#a06e5e", building_mode="extrude", extrude_scale=0.45,
                    extrude_pattern="gm-roof", water="#7d8a86", park="#8f9078", wood="#8a8b72", grass="#929179",
                    path="#b0ae9c", rail="#6a604e", label="#f3ecd6", halo="#4a4232",
                    road_label="#f3ecd6", road_halo="#4a4232", transform="none", labels=True),
    # mappa allegata (tattica): pavimento grigio chiaro, edifici grigi con contorno, corridoi a doppia linea,
    # alberi e acqua grigio scuro, etichette bianche
    "contract": dict(road_mode="casing", casing="#8c8f92", inner="#d3d5d7", minor_solid=None,
                     land="#c2c5c7", building="#a3a6a9", building_mode="ink", ink="#7a7d80",
                     water="#34363a", water_outline="#232426", wood="#2b2c2e", park="#c7cacc", grass="#c7cacc",
                     path="#8c8f92", path_solid=False, label="#ffffff", halo="#3a3b3e",
                     road_label="#ffffff", road_halo="#4a4c4f", halo_width=1.1, transform="none", labels=True),
    # mappa allegata (isola): prato verde, boschi a chiome, sentieri sabbia, fiumi azzurri con riva chiara,
    # etichette bianche maiuscole con contorno nero spesso
    # foto allegata: quartieri con texture mimetica turchese bordata di nero, strade kaki con bordo scuro,
    # acqua blu notte con riva luminosa, campagna antracite, scritte turchesi spente
    "canyon": dict(road_mode="casing", casing="#0e1314", inner="#8a8670", minor_solid=None,
                   land="#1f2627", urban_pattern="gm-camo", urban_outline="#050708",
                   building="#46548a", building_mode="extrude", extrude_opacity=0.82,
                   water="#0f1e24", water_outline="#2b5560", water_outline_width=[(8, 1.5), (12, 3.5), (16, 6)],
                   park="#273031", wood="#283132", grass="#252d2e",
                   path="#6f6c5c", rail="#4f5b5c", label="#c9d6d3", halo="#0d1213",
                   urban_all=True, urban_buildings=True,
                   road_label="#c9d6d3", road_halo="#0d1213", halo_width=1.6, labels=True),
    # Street Heat in rosso: satellite in scala di grigi su fondo rosso, strade e icone di Vice Noir
    "crimson": dict(road_mode="casing", casing="#b8b8b8", inner="#6a6a6a", minor_solid="#a8a8a8",
                    urban_pattern="gm-swirl", urban_outline="#050708", urban_all=True, urban_buildings=True,
                    landcover_overlay=True,
                    land="#34363a", building="#7d1d22", building_mode="extrude", extrude_opacity=0.85,
                    water="#4a0d12", park="#34363a", wood="#34363a", grass="#34363a",
                    path="#6e6e6e", rail="#5c5c5c", label="#ffffff", halo="#4a0f14",
                    road_label="#ffffff", road_halo="#4a0f14", labels=True),
    # foto allegata: strade con bordo chiaro, edifici in rilievo blu, nomi delle vie in fumetti, POI colorati
    "midnight": dict(road_mode="casing", casing="#8d97c6", inner="#4a5280", minor_solid=None,
                     land="#3b4161", building="#46548a", building_mode="extrude", extrude_opacity=0.82,
                     water="#262e4c", park="#35494e", wood="#34474f", grass="#36494f",
                     path="#5c6590", rail="#6c7398", label="#c9cde3", halo="#1f2338",
                     road_label="#ffffff", road_halo="#1f2338", poi_text_colors=True,
                     transform="none", labels=True),
    # replica della mappa allegata: prato verde saturo con texture, boschi a chiome scure,
    # sentieri sabbia larghi con bordo bruno, fiumi azzurri con schiuma bianca e fascia chiara,
    # rocce chiare, spiagge sabbia, edifici in pietra grigia, scritte bianche maiuscole con contorno nero
    "storm": dict(road_mode="solid", minor="#222222", major="#1e1e1e", motor="#1a1a1a",
                  land="#3e6b26", bg_pattern="gm-meadow", wood_pattern="gm-trees", park="#45772b", grass="#45772b",
                  sand="#e3c78a", rock="#cfc9bd", rock_outline="#8d877b",
                  water="#3a88e2", water_outline="#eaf6ff", water_outline_width=[(10, 1.2), (14, 3), (18, 6)],
                  water_inner="#64aef0", waterway_casing="#eaf6ff",
                  building="#a3a6a9", building_mode="extrude",
                  path="#e8cb8c", path_solid=True, path_casing="#a07e45", rail="#5a4a3a",
                  label="#ffffff", halo="#000000", road_label="#ffffff", road_halo="#111111",
                  halo_width=2.2, labels=True),
}


def road_widths(kind):
    return {
        "path": [(14, 0.6), (18, 2.4)],
        "rail": [(12, 0.8), (18, 3)],
        "service": [(14, 0.8), (16, 2.5), (18, 7)],
        "minor": [(12, 0.6), (14, 1.8), (16, 5), (18, 14), (20, 36)],
        "secondary": [(8, 0.6), (12, 1.8), (14, 3.8), (16, 8), (18, 20), (20, 48)],
        "primary": [(5, 0.6), (10, 1.8), (14, 5), (16, 10), (18, 24), (20, 56)],
        "motorway": [(4, 0.8), (10, 2.2), (14, 6), (16, 12), (18, 28), (20, 64)],
    }[kind]


def scaled(stops, f, add=0.0):
    return [(z, max(0.3, w * f + add)) for z, w in stops]


ROAD_CLASSES = [
    ("service", ["service"], 14),
    ("minor", ["minor"], 12),
    ("secondary", ["secondary", "tertiary"], 8),
    ("primary", ["primary", "trunk"], 5),
    ("motorway", ["motorway"], 4),
]


def map_style(tid, p):
    x = EXTRA.get(tid, {})
    p = dict(p, **{k: v for k, v in x.items() if v is not None})
    labels = x.get("labels", True)
    layers = []

    bg = {"id": "background", "type": "background", "paint": {"background-color": p["land"]}}
    if x.get("bg_pattern"):
        bg["paint"] = {"background-pattern": x["bg_pattern"]}
    layers.append(bg)
    sources = {"openmaptiles": SOURCE}
    if x.get("satellite"):
        sources["satellite"] = {
            "type": "raster", "tileSize": 256, "maxzoom": 19,
            "tiles": ["https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}"],
            "attribution": "Imagery © Esri, Maxar, Earthstar Geographics",
        }
        # satellite in scala di grigi sopra lo sfondo viola = tinta viola come nella schermata
        layers.append({"id": "satellite", "type": "raster", "source": "satellite",
                       "paint": {"raster-saturation": -1, "raster-contrast": 0.3, "raster-opacity": 0.5}})

    if x.get("urban_buildings"):
        # dove OpenStreetMap non disegna l'area urbana (es. i centri storici) la texture segue i palazzi:
        # una fascia larga attorno a ogni edificio unisce gli isolati in una sola zona mimetica bordata di nero
        # (la fascia si allarga con lo zoom per restare ~10-12 m attorno ai palazzi)
        halo = [(13, 3), (14, 6), (15, 12), (16, 24), (17, 48), (18, 96), (19, 192)]
        layers.append({"id": "urban-buildings-outline", "type": "line", "source": "openmaptiles", "source-layer": "building",
                       "minzoom": 13, "layout": {"line-join": "round", "line-cap": "round"},
                       "paint": {"line-color": x.get("urban_outline", "#000000"),
                                 "line-width": interp([(z, w + (2 if z < 15 else 5)) for z, w in halo], base=2)}})
        layers.append({"id": "urban-buildings-halo", "type": "line", "source": "openmaptiles", "source-layer": "building",
                       "minzoom": 13, "layout": {"line-join": "round", "line-cap": "round"},
                       "paint": {"line-pattern": x["urban_pattern"], "line-width": interp(halo, base=2)}})
        layers.append({"id": "urban-buildings-fill", "type": "fill", "source": "openmaptiles", "source-layer": "building",
                       "minzoom": 13, "paint": {"fill-pattern": x["urban_pattern"]}})
    if x.get("urban") or x.get("urban_pattern"):
        urban_cls = cls("residential", "commercial", "industrial", "retail", "railway", "suburb",
                        "neighbourhood", "quarter")
        if x.get("urban_all"):
            # tutte le aree costruite delle città, non solo le residenziali
            urban_cls = cls("residential", "commercial", "industrial", "retail", "railway", "suburb",
                            "neighbourhood", "quarter", "garages", "school", "university", "college",
                            "kindergarten", "library", "hospital", "stadium", "bus_station", "military",
                            "theme_park", "zoo", "place_of_worship", "parking", "construction",
                            "brownfield", "farmyard", "village", "town", "city")
        layers.append({"id": "landuse-urban", "type": "fill", "source": "openmaptiles", "source-layer": "landuse",
                       "filter": urban_cls,
                       "paint": {"fill-pattern": x["urban_pattern"]} if x.get("urban_pattern")
                                else {"fill-color": x["urban"]}})
        if x.get("urban_outline"):
            layers.append({"id": "landuse-urban-outline", "type": "line", "source": "openmaptiles", "source-layer": "landuse",
                           "filter": urban_cls,
                           "paint": {"line-color": x["urban_outline"], "line-width": interp([(10, 1.2), (14, 3), (18, 5)])}})

    for lid, classes, key, op in [("landcover-ice", ["ice"], "ice", 1), ("landcover-sand", ["sand"], "sand", 1),
                                  ("landcover-wood", ["wood", "forest"], "wood", 0.95),
                                  ("landcover-grass", ["grass", "farmland", "scrub"], "grass", 0.9)]:
        paint = {"fill-color": p[key], "fill-opacity": op}
        if key == "wood" and x.get("wood_pattern"):
            paint = {"fill-pattern": x["wood_pattern"]}
        layers.append({"id": lid, "type": "fill", "source": "openmaptiles", "source-layer": "landcover",
                       "filter": cls(*classes), "paint": paint})
    if x.get("rock"):
        layers.append({"id": "landcover-rock", "type": "fill", "source": "openmaptiles", "source-layer": "landcover",
                       "filter": cls("rock", "bare_rock", "scree"),
                       "paint": {"fill-color": x["rock"], "fill-outline-color": x.get("rock_outline", x["rock"])}})
    if x.get("landcover_overlay"):
        # prati, boschi, rocce e spiagge come velature sopra il fondo e il pattern rosso:
        # boschi più scuri, prati appena più chiari, rocce/montagne e sabbia chiare
        overlay = {"landcover-wood": ("#000000", 0.28), "landcover-grass": ("#ffffff", 0.07),
                   "landcover-sand": ("#ffffff", 0.14), "landcover-ice": ("#ffffff", 0.22)}
        for l in layers:
            if l["id"] in overlay:
                col, op = overlay[l["id"]]
                l["paint"] = {"fill-color": col, "fill-opacity": op}
        layers.append({"id": "landcover-rock", "type": "fill", "source": "openmaptiles", "source-layer": "landcover",
                       "filter": cls("rock", "bare_rock", "scree"),
                       "paint": {"fill-color": "#ffffff", "fill-opacity": 0.16}})
    if x.get("satellite"):
        layers = [l for l in layers if not l["id"].startswith("landcover")]
    layers.append({"id": "park", "type": "fill", "source": "openmaptiles", "source-layer": "park",
                   "paint": ({"fill-color": "#000000", "fill-opacity": 0.14} if x.get("landcover_overlay") else
                             {"fill-color": p["park"], "fill-opacity": 0 if x.get("satellite") else 0.95})})
    layers.append({"id": "landuse-grass", "type": "fill", "source": "openmaptiles", "source-layer": "landuse",
                   "filter": cls("grass", "cemetery", "pitch", "playground"),
                   "paint": ({"fill-color": "#ffffff", "fill-opacity": 0.08} if x.get("landcover_overlay") else
                             {"fill-color": p["park"], "fill-opacity": 0 if x.get("satellite") else 0.9})})

    water = {"id": "water", "type": "fill", "source": "openmaptiles", "source-layer": "water",
             "paint": {"fill-color": p["water"], "fill-antialias": True}}
    if x.get("water_pattern"):
        water["paint"] = {"fill-pattern": x["water_pattern"]}
    layers.append(water)
    if x.get("water_inner"):
        # fascia più chiara lungo le rive (acqua bassa), sotto la schiuma bianca
        layers.append({"id": "water-shallow", "type": "line", "source": "openmaptiles", "source-layer": "water",
                       "paint": {"line-color": x["water_inner"], "line-blur": 2,
                                 "line-width": interp([(10, 3), (14, 9), (18, 22)])}})
    if x.get("water_outline"):
        layers.append({"id": "water-outline", "type": "line", "source": "openmaptiles", "source-layer": "water",
                       "paint": {"line-color": x["water_outline"],
                                 "line-width": interp(x.get("water_outline_width", [(10, 0.8), (16, 2.2), (19, 4)]))}})
    if x.get("waterway_casing"):
        layers.append({"id": "waterway-casing", "type": "line", "source": "openmaptiles", "source-layer": "waterway",
                       "paint": {"line-color": x["waterway_casing"], "line-width": interp([(8, 1.5), (14, 5.5), (18, 13)])}})
    layers.append({"id": "waterway", "type": "line", "source": "openmaptiles", "source-layer": "waterway",
                   "paint": {"line-color": p["water"], "line-width": interp([(8, 0.5), (14, 2.5), (18, 8)])}})

    layers.append({"id": "boundary-state", "type": "line", "source": "openmaptiles", "source-layer": "boundary",
                   "filter": ["all", ["==", ["get", "admin_level"], 4], ["!=", ["get", "maritime"], 1]],
                   "paint": {"line-color": p["boundary"], "line-opacity": 0.35, "line-dasharray": [3, 2],
                             "line-width": interp([(3, 0.4), (10, 1.2)])}})
    layers.append({"id": "boundary-country", "type": "line", "source": "openmaptiles", "source-layer": "boundary",
                   "filter": ["all", ["==", ["get", "admin_level"], 2], ["!=", ["get", "maritime"], 1]],
                   "paint": {"line-color": p["boundary"], "line-opacity": 0.7,
                             "line-width": interp([(2, 0.6), (8, 1.6), (12, 2.4)])}})

    # edifici piatti / a inchiostro / a texture (sotto le strade)
    mode = x.get("building_mode", "extrude")
    if mode in ("flat", "ink", "pattern"):
        b = {"id": "building", "type": "fill", "source": "openmaptiles", "source-layer": "building",
             "minzoom": 13, "paint": dict({"fill-color": p["building"]},
                                          **({"fill-opacity": x["building_opacity"]} if "building_opacity" in x else {}))}
        if mode == "pattern":
            # due livelli semplici (pattern fisso) invece di un pattern calcolato per ogni edificio: più veloce
            tall = [">", ["to-number", ["get", "render_height"], 0], 14]
            b["paint"] = {"fill-pattern": x["building_pattern"]}
            b["filter"] = ["!", tall]
            layers.append(b)
            b = {"id": "building-tall", "type": "fill", "source": "openmaptiles", "source-layer": "building",
                 "minzoom": 13, "filter": tall,
                 "paint": {"fill-pattern": x.get("building_pattern_big", x["building_pattern"])}}
        layers.append(b)
        if mode == "ink":
            layers.append({"id": "building-ink", "type": "line", "source": "openmaptiles", "source-layer": "building",
                           "minzoom": 14, "paint": {"line-color": x["ink"],
                                                    "line-width": interp([(14, 0.6), (16, 1.6), (18, 2.6)])}})

    # sentieri e ferrovie
    path_dash = None if x.get("path_solid") else [2.2, 1.6]
    if x.get("path_casing"):
        layers.append(road_line("road-path-casing", p, ["path", "track"], x["path_casing"],
                                scaled(road_widths("path"), 1.6, 1.4), minzoom=14))
    layers.append(road_line("road-path", p, ["path", "track"], p["path"], road_widths("path"), minzoom=14, dash=path_dash))
    layers.append(road_line("road-rail", p, ["rail", "transit"], p["rail"], road_widths("rail"), minzoom=12,
                            dash=None if tid == "palm" else [3, 2]))

    # strade
    if x.get("road_mode") == "casing":
        solid = x.get("minor_solid")
        inners = []
        for kind, classes, mz in ROAD_CLASSES:
            w = scaled(road_widths(kind), x.get("road_scale", 1.0))
            if solid and kind in ("service", "minor"):
                layers.append(road_line(f"road-{kind}", p, classes, solid, scaled(w, 0.8), minzoom=mz))
                continue
            # prima tutti i bordi, poi tutti gli interni: incroci puliti
            layers.append(road_line(f"road-{kind}-casing", p, classes, x["casing"], scaled(w, 1.0, 1.2), minzoom=mz))
            inners.append(road_line(f"road-{kind}", p, classes, x["inner"], scaled(w, 0.62), minzoom=mz))
        layers.extend(inners)
    else:
        colors = {"service": p["minor"], "minor": p["minor"], "secondary": p["major"],
                  "primary": p["major"], "motorway": p["motor"]}
        for kind, classes, mz in ROAD_CLASSES:
            layers.append(road_line(f"road-{kind}", p, classes, colors[kind], road_widths(kind), minzoom=mz))

    if mode == "extrude":
        ext = {
            "id": "building-3d", "type": "fill-extrusion", "source": "openmaptiles", "source-layer": "building",
            "minzoom": 14,
            "paint": {
                "fill-extrusion-color": p["building"],
                "fill-extrusion-height": ["interpolate", ["linear"], ["zoom"], 14, 0, 15.5,
                                          (["*", ["to-number", ["get", "render_height"], 8], x["extrude_scale"]]
                                           if "extrude_scale" in x else ["to-number", ["get", "render_height"], 8])],
                "fill-extrusion-base": ["to-number", ["get", "render_min_height"], 0],
                "fill-extrusion-opacity": x.get("extrude_opacity", 0.95),
                "fill-extrusion-vertical-gradient": True,
            },
        }
        if x.get("extrude_pattern"):
            ext["paint"]["fill-extrusion-pattern"] = x["extrude_pattern"]
            del ext["paint"]["fill-extrusion-color"]
        layers.append(ext)

    layers.append({
        "id": "road-oneway", "type": "symbol", "source": "openmaptiles", "source-layer": "transportation",
        "minzoom": 16, "filter": ["match", ["get", "oneway"], [1, -1], True, False],
        "layout": {"symbol-placement": "line", "symbol-spacing": 90, "icon-image": "gm-oneway",
                   "icon-size": interp([(16, 0.55), (19, 0.9)]),
                   "icon-rotate": ["match", ["get", "oneway"], -1, 180, 0],
                   "icon-rotation-alignment": "map"},
        "paint": {"icon-opacity": p["oneway"] if labels else 0},
    })

    if labels:
        layers.append({"id": "housenumber", "type": "symbol", "source": "openmaptiles", "source-layer": "housenumber",
                       "minzoom": 17,
                       "layout": {"text-field": ["get", "housenumber"], "text-font": BOLD, "text-size": 10},
                       "paint": {"text-color": p["house"], "text-halo-color": p["halo"], "text-halo-width": 0.6}})
        layers.append({"id": "water-label", "type": "symbol", "source": "openmaptiles", "source-layer": "water_name",
                       "layout": {"text-field": NAME, "text-font": ITAL, "text-size": 13, "text-letter-spacing": 0.2,
                                  "text-transform": p["transform"], "text-max-width": 6},
                       "paint": {"text-color": p["water_label"], "text-halo-color": p["halo"], "text-halo-width": 0.6}})
        layers.append({
            "id": "road-shield", "type": "symbol", "source": "openmaptiles", "source-layer": "transportation_name",
            "minzoom": 11,
            "filter": ["all", ["has", "ref"], ["<=", ["to-number", ["get", "ref_length"], 9], 6]],
            "layout": {
                "symbol-placement": "point", "symbol-spacing": 400,
                "text-field": ["get", "ref"], "text-font": BOLD, "text-size": 9,
                "icon-image": "gm-shield", "icon-text-fit": "both", "icon-text-fit-padding": [2, 4, 2, 4],
                "text-rotation-alignment": "viewport", "icon-rotation-alignment": "viewport",
            },
            "paint": {"text-color": "#ffffff"},
        })
        if x.get("road_callout"):
            # nomi delle vie dentro fumetti orizzontali (come nella navigazione della foto)
            layers.append({"id": "road-label", "type": "symbol", "source": "openmaptiles", "source-layer": "transportation_name",
                           "minzoom": 15, "filter": ["has", "name"],
                           "layout": {"symbol-placement": "point", "text-field": NAME, "text-font": REG,
                                      "text-size": interp([(15, 12), (18, 15)]), "text-max-width": 14,
                                      "icon-image": "gm-callout", "icon-text-fit": "both",
                                      "icon-text-fit-padding": [5, 10, 7, 10],
                                      "text-rotation-alignment": "viewport", "icon-rotation-alignment": "viewport",
                                      "text-pitch-alignment": "viewport", "icon-pitch-alignment": "viewport",
                                      "symbol-spacing": 350, "text-padding": 6},
                           "paint": {"text-color": "#ffffff"}})
        else:
          layers.append({"id": "road-label", "type": "symbol", "source": "openmaptiles", "source-layer": "transportation_name",
                       "minzoom": 14,
                       "layout": {"symbol-placement": "line", "text-field": NAME, "text-font": BOLD,
                                  "text-size": interp([(14, 10), (16, 12.5), (18, 16)]),
                                  "text-transform": p["transform"], "text-letter-spacing": 0.04,
                                  "text-rotation-alignment": "map", "text-pitch-alignment": "viewport"},
                       "paint": {"text-color": p["road_label"], "text-halo-color": p["road_halo"],
                                 "text-halo-width": x.get("halo_width", 1.6), "text-halo-blur": 0.4 if tid == "neon" else 0}})

    layers.append({
        "id": "poi", "type": "symbol", "source": "openmaptiles", "source-layer": "poi",
        "minzoom": 15, "filter": ["<=", ["to-number", ["get", "rank"], 30], 22],
        "layout": {
            "icon-image": POI_ICON_EXPR, "icon-size": 0.55,  # stessa dimensione per tutti i temi "icon-allow-overlap": False,
            "text-field": NAME if labels else "", "text-font": BOLD, "text-size": 10.5,
            "text-transform": p["transform"], "text-anchor": "top", "text-offset": [0, 1.2],
            "text-max-width": 8, "text-optional": True,
        },
        "paint": {"text-color": _poi_text_color(p["label"]) if x.get("poi_text_colors") else p["label"],
                  "text-halo-color": p["halo"], "text-halo-width": x.get("halo_width", 1.3)},
    })

    if labels:
        for lid, classes, size in [("place-minor", ["village", "hamlet", "suburb", "quarter", "neighbourhood"], [(10, 10), (15, 13)]),
                                   ("place-town", ["town"], [(8, 11), (14, 16)]),
                                   ("place-city", ["city"], [(4, 11), (10, 18)])]:
            layers.append({"id": lid, "type": "symbol", "source": "openmaptiles", "source-layer": "place",
                           "filter": cls(*classes),
                           "layout": {"text-field": NAME, "text-font": BOLD, "text-transform": p["transform"],
                                      "text-size": interp(size), "text-max-width": 8},
                           "paint": {"text-color": p["label"], "text-halo-color": p["halo"], "text-halo-width": 1.5}})
    layers.append({"id": "place-country", "type": "symbol", "source": "openmaptiles", "source-layer": "place",
                   "filter": cls("country"), "maxzoom": 9,
                   "layout": {"text-field": NAME_EN, "text-font": BOLD, "text-transform": p["transform"],
                              "text-size": interp([(2, 10), (6, 16)]), "text-max-width": 7},
                   "paint": {"text-color": p["label"], "text-halo-color": p["halo"], "text-halo-width": 1.6}})

    return {"version": 8, "name": "GassMaps " + tid, "sources": sources,
            "glyphs": GLYPHS, "layers": layers}


# Colori della superficie del globo misurati sul video (terra, acqua)
GLOBE_COLORS = {
    "noir": ("#1a1a1a", "#2c363e"),
    "dust": ("#d9c6a2", "#a79e88"),
    "bunker": ("#061206", "#020a02"),
    "pixel": ("#6aa84f", "#3d3cc3"),
    "neon": ("#0d0b0a", "#06162b"),
    "palm": ("#738372", "#607da7"),
    "heat": ("#a05fd8", "#1d0b45"),
    "kingdom": ("#8a6f4a", "#6f7a62"),
    "contract": ("#c2c5c7", "#2e3033"),
    "storm": ("#4b7d35", "#3d8fe0"),
    "midnight": ("#3b4161", "#262e4c"),
    "crimson": ("#34363a", "#4a0d12"),
    "canyon": ("#232b2c", "#0f1e24"),
}


def globe_style(tid, p):
    """Stile leggero usato per generare la texture del globo (snapshot)."""
    land, water = GLOBE_COLORS.get(tid, (p["land"], p["water"]))
    p = dict(p, land=land, water=water)
    layers = [
        {"id": "background", "type": "background", "paint": {"background-color": p["land"]}},
        {"id": "landcover-ice", "type": "fill", "source": "openmaptiles", "source-layer": "landcover",
         "filter": cls("ice"), "paint": {"fill-color": p["ice"]}},
        {"id": "landcover-sand", "type": "fill", "source": "openmaptiles", "source-layer": "landcover",
         "filter": cls("sand"), "paint": {"fill-color": p["sand"]}},
        {"id": "landcover-wood", "type": "fill", "source": "openmaptiles", "source-layer": "landcover",
         "filter": cls("wood", "forest"), "paint": {"fill-color": p["wood"], "fill-opacity": 0.8}},
        {"id": "water", "type": "fill", "source": "openmaptiles", "source-layer": "water",
         "paint": {"fill-color": p["water"]}},
        {"id": "boundary-country", "type": "line", "source": "openmaptiles", "source-layer": "boundary",
         "filter": ["all", ["==", ["get", "admin_level"], 2], ["!=", ["get", "maritime"], 1]],
         "paint": {"line-color": p["boundary"], "line-opacity": 0.55, "line-width": 0.8}},
        {"id": "road-motorway", "type": "line", "source": "openmaptiles", "source-layer": "transportation",
         "filter": cls("motorway", "trunk"),
         "paint": {"line-color": p["motor"], "line-opacity": 0.35, "line-width": 0.5}},
        {"id": "place-city", "type": "symbol", "source": "openmaptiles", "source-layer": "place",
         "filter": ["all", cls("city"), ["<=", ["to-number", ["get", "rank"], 10], 4]],
         "layout": {"text-field": NAME_EN, "text-font": BOLD, "text-size": 8,
                    "text-transform": p["transform"], "text-anchor": "left", "text-offset": [0.5, 0],
                    "icon-image": "gm-dot", "icon-size": 0.5},
         "paint": {"text-color": p["label"], "text-halo-color": p["halo"], "text-halo-width": 1}},
        {"id": "place-country", "type": "symbol", "source": "openmaptiles", "source-layer": "place",
         "filter": cls("country"),
         "layout": {"text-field": NAME_EN, "text-font": BOLD, "text-size": 9,
                    "text-transform": p["transform"], "text-max-width": 6},
         "paint": {"text-color": p["label"], "text-halo-color": p["halo"], "text-halo-width": 1.2}},
    ]
    # le etichette del globo sono disegnate in 3D dall'app (sempre rivolte verso lo schermo)
    layers = [l for l in layers if l["type"] != "symbol"]
    return {"version": 8, "name": "GassMaps globe " + tid, "sources": {"openmaptiles": SOURCE},
            "glyphs": GLYPHS, "layers": layers}


def main():
    os.makedirs(OUT, exist_ok=True)
    for tid, p in THEMES.items():
        with open(os.path.join(OUT, f"{tid}.json"), "w") as f:
            json.dump(map_style(tid, p), f, indent=1)
        with open(os.path.join(OUT, f"{tid}_globe.json"), "w") as f:
            json.dump(globe_style(tid, p), f, indent=1)
    print("Stili generati in", OUT)


if __name__ == "__main__":
    main()
