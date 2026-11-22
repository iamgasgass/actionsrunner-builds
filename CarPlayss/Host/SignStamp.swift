import Foundation

/// Impronta dei file Mach-O di un'app dopo che CarPlayss l'ha firmata.
///
/// Se un file viene modificato dopo la firma (patch), iOS chiude il processo con SIGKILL appena esegue
/// una pagina con firma non corrispondente, senza alcun errore intercettabile. Prima di caricare un'app
/// importata si confronta quindi l'impronta attuale con quella salvata e, se diversa, si rifirma.
enum SignStamp {
    private static let fileName = ".carplayss-signed.plist"

    private static func fingerprint(_ appURL: URL) -> [String: String] {
        let root = appURL.standardizedFileURL.path
        var result: [String: String] = [:]
        for url in MachO.machOFiles(in: appURL) {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let date = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            let size = values?.fileSize ?? 0
            let relative = String(url.standardizedFileURL.path.dropFirst(root.count))
            result[relative] = "\(size)-\(Int(date * 1000))"
        }
        return result
    }

    /// Da chiamare subito dopo una firma riuscita.
    static func write(_ appURL: URL) {
        let dict = fingerprint(appURL) as NSDictionary
        dict.write(to: appURL.appendingPathComponent(fileName), atomically: true)
    }

    static func isValid(_ appURL: URL) -> Bool {
        guard let saved = NSDictionary(contentsOf: appURL.appendingPathComponent(fileName)) as? [String: String] else {
            return false
        }
        return saved == fingerprint(appURL)
    }

    static func invalidate(_ appURL: URL) {
        try? FileManager.default.removeItem(at: appURL.appendingPathComponent(fileName))
    }
}
