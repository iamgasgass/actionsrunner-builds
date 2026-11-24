import Foundation
import Network

enum LocalNetwork {
    /// Indirizzo IPv4 dell'interfaccia Wi-Fi (en0).
    static func wifiIPv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var fallback: String?
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ptr = cursor {
            let iface = ptr.pointee
            cursor = iface.ifa_next
            guard let addr = iface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: iface.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if name == "en0" { return ip }
            if fallback == nil { fallback = ip }
        }
        return fallback
    }
}

/// Cerca le TV nella sottorete /24 provando le porte note di Roku, Samsung e LG.
final class NetworkScanner {
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.5
        config.timeoutIntervalForResource = 2.5
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    func scan(found: @escaping (TVDevice) -> Void) async {
        await MainActor.run {
            BonjourDiscovery.shared.browse(type: "_androidtvremote2._tcp", brand: .androidTV, found: found)
            BonjourDiscovery.shared.browse(type: "_amzn-wplay._tcp", brand: .fireTV, found: found)
        }
        guard let ip = LocalNetwork.wifiIPv4() else { return }
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return }
        let prefix = parts[0...2].joined(separator: ".")
        let hosts = (1...254).map { "\(prefix).\($0)" }.filter { $0 != ip }

        var index = 0
        let batchSize = 32
        while index < hosts.count {
            if Task.isCancelled { return }
            let batch = Array(hosts[index..<min(index + batchSize, hosts.count)])
            index += batchSize
            await withTaskGroup(of: [TVDevice].self) { group in
                for host in batch {
                    group.addTask { await self.probe(host) }
                }
                for await devices in group {
                    for d in devices {
                        DispatchQueue.main.async { found(d) }
                    }
                }
            }
        }
    }

    private func probe(_ host: String) async -> [TVDevice] {
        async let roku = probeRoku(host)
        async let samsung = probeSamsung(host)
        async let lg = probeLG(host)
        async let android = probePort(host, 6466, name: "Android TV", brand: .androidTV)
        async let fire = probePort(host, 5555, name: "Fire TV", brand: .fireTV)
        async let vizio = probePort(host, 7345, name: "VIZIO TV", brand: .vizio)
        async let panasonic = probePanasonic(host)
        let results: [TVDevice?] = [await roku, await samsung, await lg, await android,
                                    await fire, await vizio, await panasonic]
        return results.compactMap { $0 }
    }

    private func probePort(_ host: String, _ port: UInt16, name: String, brand: TVBrand) async -> TVDevice? {
        await portOpen(host, port) ? TVDevice(name: name, host: host, brand: brand) : nil
    }

    private func probePanasonic(_ host: String) async -> TVDevice? {
        guard let data = await get("http://\(host):55000/nrc/ddd.xml"),
              let xml = String(data: data, encoding: .utf8), xml.lowercased().contains("panasonic") else { return nil }
        return TVDevice(name: Self.xmlValue("friendlyName", xml) ?? "Panasonic Viera", host: host, brand: .panasonic,
                        model: Self.xmlValue("modelNumber", xml))
    }

    private func get(_ string: String) async -> Data? {
        guard let url = URL(string: string) else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return data
        } catch {
            return nil
        }
    }

    private func probeRoku(_ host: String) async -> TVDevice? {
        guard let data = await get("http://\(host):8060/query/device-info"),
              let xml = String(data: data, encoding: .utf8), xml.contains("<device-info") else { return nil }
        let name = Self.xmlValue("user-device-name", xml)
            ?? Self.xmlValue("friendly-device-name", xml)
            ?? Self.xmlValue("default-device-name", xml)
            ?? "Roku"
        return TVDevice(name: name, host: host, brand: .roku,
                        model: Self.xmlValue("model-name", xml),
                        mac: Self.xmlValue("wifi-mac", xml) ?? Self.xmlValue("ethernet-mac", xml))
    }

    private func probeSamsung(_ host: String) async -> TVDevice? {
        guard let data = await get("http://\(host):8001/api/v2/"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let device = json["device"] as? [String: Any]
        let name = (device?["name"] as? String) ?? (json["name"] as? String) ?? "Samsung TV"
        return TVDevice(name: Self.decodeEntities(name), host: host, brand: .samsung,
                        model: device?["modelName"] as? String,
                        mac: device?["wifiMac"] as? String)
    }

    private func probeLG(_ host: String) async -> TVDevice? {
        if await portOpen(host, 3001) {
            return TVDevice(name: "LG webOS TV", host: host, brand: .lg)
        }
        if await portOpen(host, 3000), let data = await get("http://\(host):3000/"),
           let body = String(data: data, encoding: .utf8), body.lowercased().contains("hello") {
            return TVDevice(name: "LG webOS TV", host: host, brand: .lg)
        }
        return nil
    }

    private func portOpen(_ host: String, _ port: UInt16) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let lock = NSLock()
            var finished = false
            let finish: (Bool) -> Void = { value in
                lock.lock()
                let already = finished
                finished = true
                lock.unlock()
                guard !already else { return }
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled, .waiting: finish(false)
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.2) { finish(false) }
        }
    }

    static func xmlValue(_ tag: String, _ xml: String) -> String? {
        guard let start = xml.range(of: "<\(tag)>"),
              let end = xml.range(of: "</\(tag)>", range: start.upperBound..<xml.endIndex) else { return nil }
        let value = String(xml[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : decodeEntities(value)
    }

    static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// Nomi "veri" delle TV annunciate via Bonjour (Android TV, Fire TV).
final class BonjourDiscovery {
    static let shared = BonjourDiscovery()
    private var browsers: [NWBrowser] = []

    func browse(type: String, brand: TVBrand, duration: TimeInterval = 8, found: @escaping (TVDevice) -> Void) {
        let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: .tcp)
        var seen = Set<String>()
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            for result in results {
                guard case let .service(name, _, _, _) = result.endpoint, !seen.contains(name) else { continue }
                seen.insert(name)
                self?.resolve(result.endpoint) { ip in
                    found(TVDevice(name: name, host: ip, brand: brand))
                }
            }
        }
        browsers.append(browser)
        browser.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            browser.cancel()
            self?.browsers.removeAll { $0 === browser }
        }
    }

    private func resolve(_ endpoint: NWEndpoint, completion: @escaping (String) -> Void) {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak connection] state in
            guard let connection = connection else { return }
            switch state {
            case .ready:
                if case let .hostPort(host, _)? = connection.currentPath?.remoteEndpoint {
                    var address: String?
                    switch host {
                    case .ipv4(let v4): address = "\(v4)"
                    case .name(let name, _): address = name
                    default: address = nil
                    }
                    if let raw = address {
                        let clean = raw.split(separator: "%").first.map(String.init) ?? raw
                        completion(clean)
                    }
                }
                connection.cancel()
            case .failed, .waiting:
                connection.cancel()
            case .cancelled:
                connection.stateUpdateHandler = nil
            default:
                break
            }
        }
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { connection.cancel() }
    }
}
