import Foundation

/// "Magic packet" Wake-on-LAN per accendere le TV in standby di rete.
/// Nota: iOS può bloccare i broadcast UDP senza l'entitlement multicast; si prova anche l'unicast.
enum WakeOnLAN {
    static func send(mac: String, host: String?) {
        let hex = mac.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
        guard hex.count == 12 else { return }
        var macBytes: [UInt8] = []
        var index = hex.startIndex
        for _ in 0..<6 {
            let next = hex.index(index, offsetBy: 2)
            guard let b = UInt8(hex[index..<next], radix: 16) else { return }
            macBytes.append(b)
            index = next
        }
        var packet = [UInt8](repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet += macBytes }

        var targets = ["255.255.255.255"]
        if let ip = LocalNetwork.wifiIPv4() {
            let parts = ip.split(separator: ".")
            if parts.count == 4 { targets.append(parts[0...2].joined(separator: ".") + ".255") }
        }
        if let host = host { targets.append(host) }

        DispatchQueue.global(qos: .userInitiated).async {
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { return }
            defer { close(fd) }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
            for _ in 0..<3 {
                for target in targets {
                    for port: UInt16 in [9, 7] {
                        var addr = sockaddr_in()
                        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                        addr.sin_family = sa_family_t(AF_INET)
                        addr.sin_port = port.bigEndian
                        guard inet_pton(AF_INET, target, &addr.sin_addr) == 1 else { continue }
                        packet.withUnsafeBytes { buffer in
                            withUnsafePointer(to: &addr) { pointer in
                                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                                    _ = sendto(fd, buffer.baseAddress, buffer.count, 0, sa,
                                               socklen_t(MemoryLayout<sockaddr_in>.size))
                                }
                            }
                        }
                    }
                }
                usleep(100_000)
            }
        }
    }
}
