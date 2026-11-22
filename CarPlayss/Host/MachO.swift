import Foundation

enum MachOError: LocalizedError {
    case notMachO
    case noArm64
    case noHeaderSpace
    case io(String)

    var errorDescription: String? {
        switch self {
        case .notMachO: return "L'eseguibile non è un file Mach-O valido."
        case .noArm64: return "L'eseguibile non contiene codice arm64."
        case .noHeaderSpace: return "Spazio insufficiente nell'header Mach-O per trasformarlo in libreria."
        case .io(let m): return m
        }
    }
}

/// Lettura e modifica degli eseguibili Mach-O delle app CarPlay importate.
///
/// Per caricare un'app dentro CarPlayss l'eseguibile viene trasformato in libreria dinamica
/// (stessa tecnica di LiveContainer): MH_EXECUTE → MH_DYLIB, __PAGEZERO ridotto, LC_ID_DYLIB aggiunto.
/// In più i percorsi "@executable_path" diventano "@loader_path", così i framework interni
/// dell'app vengono trovati anche se l'eseguibile principale del processo è CarPlayss.
enum MachO {
    static let mhMagic64: UInt32 = 0xFEEDFACF
    static let fatMagic: UInt32 = 0xCAFEBABE
    static let fatMagic64: UInt32 = 0xCAFEBABF
    static let cpuTypeARM64: UInt32 = 0x0100000C

    static let mhExecute: UInt32 = 0x2
    static let mhDylib: UInt32 = 0x6
    static let mhNoReexportedDylibs: UInt32 = 0x100000
    static let mhPIE: UInt32 = 0x200000

    static let lcSegment64: UInt32 = 0x19
    static let lcIDDylib: UInt32 = 0xD
    static let lcLoadDylib: UInt32 = 0xC
    static let lcLoadWeakDylib: UInt32 = 0x80000018
    static let lcReexportDylib: UInt32 = 0x8000001F
    static let lcLazyLoadDylib: UInt32 = 0x20
    static let lcLoadUpwardDylib: UInt32 = 0x80000023
    static let lcRpath: UInt32 = 0x8000001C
    static let lcCodeSignature: UInt32 = 0x1D
    static let lcEncryptionInfo64: UInt32 = 0x2C

    struct Command {
        let cmd: UInt32
        let offset: Int
        let size: Int
    }

    // MARK: Lettura byte

    static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        guard o + 4 <= b.count else { return 0 }
        return UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }

    static func u32be(_ b: [UInt8], _ o: Int) -> UInt32 {
        guard o + 4 <= b.count else { return 0 }
        return UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
    }

    static func u64(_ b: [UInt8], _ o: Int) -> UInt64 {
        UInt64(u32(b, o)) | UInt64(u32(b, o + 4)) << 32
    }

    static func u64be(_ b: [UInt8], _ o: Int) -> UInt64 {
        UInt64(u32be(b, o)) << 32 | UInt64(u32be(b, o + 4))
    }

    static func set32(_ b: inout [UInt8], _ o: Int, _ v: UInt32) {
        b[o] = UInt8(v & 0xFF)
        b[o + 1] = UInt8((v >> 8) & 0xFF)
        b[o + 2] = UInt8((v >> 16) & 0xFF)
        b[o + 3] = UInt8((v >> 24) & 0xFF)
    }

    static func set64(_ b: inout [UInt8], _ o: Int, _ v: UInt64) {
        set32(&b, o, UInt32(v & 0xFFFF_FFFF))
        set32(&b, o + 4, UInt32(v >> 32))
    }

    static func cString(_ b: [UInt8], _ o: Int, max: Int) -> String {
        var end = o
        while end < min(b.count, o + max), b[end] != 0 { end += 1 }
        return String(decoding: b[o..<end], as: UTF8.self)
    }

    // MARK: Struttura

    /// Offset delle slice arm64 (thin o fat).
    static func arm64Slices(_ b: [UInt8]) throws -> [Int] {
        if u32(b, 0) == mhMagic64 { return [0] }
        let magic = u32be(b, 0)
        guard magic == fatMagic || magic == fatMagic64 else { throw MachOError.notMachO }
        let count = Int(u32be(b, 4))
        var result: [Int] = []
        for i in 0..<count {
            if magic == fatMagic {
                let e = 8 + i * 20
                if u32be(b, e) == cpuTypeARM64 { result.append(Int(u32be(b, e + 8))) }
            } else {
                let e = 8 + i * 32
                if u32be(b, e) == cpuTypeARM64 { result.append(Int(u64be(b, e + 8))) }
            }
        }
        guard !result.isEmpty else { throw MachOError.noArm64 }
        return result.filter { u32(b, $0) == mhMagic64 }
    }

    static func commands(_ b: [UInt8], slice: Int) -> [Command] {
        let ncmds = Int(u32(b, slice + 16))
        var off = slice + 32
        var result: [Command] = []
        for _ in 0..<ncmds {
            let cmd = u32(b, off)
            let size = Int(u32(b, off + 4))
            guard size >= 8, off + size <= b.count else { break }
            result.append(Command(cmd: cmd, offset: off, size: size))
            off += size
        }
        return result
    }

    // MARK: Analisi

    static func filetype(of url: URL) throws -> UInt32 {
        let b = try [UInt8](Data(contentsOf: url, options: .mappedIfSafe))
        guard let slice = try arm64Slices(b).first else { throw MachOError.noArm64 }
        return u32(b, slice + 12)
    }

    static func needsPatch(_ url: URL) throws -> Bool {
        try filetype(of: url) == mhExecute
    }

    /// true se il binario è criptato FairPlay (IPA scaricate dall'App Store, non decriptate).
    static func isEncrypted(_ b: [UInt8]) -> Bool {
        guard let slices = try? arm64Slices(b) else { return false }
        for s in slices {
            for c in commands(b, slice: s) where c.cmd == lcEncryptionInfo64 {
                if u32(b, c.offset + 16) != 0 { return true }
            }
        }
        return false
    }

    /// Testo della firma del codice (contiene il plist degli entitlement).
    static func signatureText(_ b: [UInt8]) -> String {
        guard let slices = try? arm64Slices(b) else { return "" }
        var text = ""
        for s in slices {
            for c in commands(b, slice: s) where c.cmd == lcCodeSignature {
                let start = s + Int(u32(b, c.offset + 8))
                let len = Int(u32(b, c.offset + 12))
                guard start >= 0, len > 0, start + len <= b.count else { continue }
                text += String(decoding: b[start..<(start + len)], as: UTF8.self)
            }
        }
        return text
    }

    // MARK: Patch

    /// Applica la patch all'eseguibile principale (idempotente). Restituisce true se il file è stato modificato.
    @discardableResult
    static func patch(fileAt url: URL) throws -> Bool {
        try patch(fileAt: url, isMain: true, depth: 0)
    }

    @discardableResult
    static func patch(fileAt url: URL, isMain: Bool, depth: Int) throws -> Bool {
        var b: [UInt8]
        do { b = try [UInt8](Data(contentsOf: url)) } catch { throw MachOError.io(error.localizedDescription) }
        let original = b
        for slice in try arm64Slices(b) {
            try patchSlice(&b, slice: slice, executableName: url.lastPathComponent, isMain: isMain, depth: depth)
        }
        guard b != original else { return false }
        do { try Data(b).write(to: url, options: .atomic) } catch { throw MachOError.io(error.localizedDescription) }
        return true
    }

    /// true se il file inizia con un magic Mach-O (thin 64 bit o fat).
    static func isMachO(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: 4), d.count == 4 else { return false }
        let b = [UInt8](d)
        return u32(b, 0) == mhMagic64 || [fatMagic, fatMagic64].contains(u32be(b, 0))
    }

    /// Librerie collegate (LC_LOAD_DYLIB e simili) dell'eseguibile.
    static func linkedLibraries(_ url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        let b = [UInt8](data)
        guard let slice = (try? arm64Slices(b))?.first else { return [] }
        let kinds: Set<UInt32> = [lcLoadDylib, lcLoadWeakDylib, lcReexportDylib, lcLazyLoadDylib, lcLoadUpwardDylib]
        return commands(b, slice: slice).filter { kinds.contains($0.cmd) }.map { c in
            let off = Int(u32(b, c.offset + 8))
            return cString(b, c.offset + off, max: c.size - off)
        }
    }

    /// Tutti i file Mach-O del bundle (percorsi relativi), esclusi i link simbolici.
    static func machOFiles(in appURL: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: appURL, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return []
        }
        var result: [URL] = []
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true, isMachO(url) else { continue }
            result.append(url)
        }
        return result
    }

    /// Patch di tutto il bundle: eseguibile principale + ogni dylib/framework/tweak iniettato.
    /// "@executable_path" diventa "@loader_path" più i "/.." necessari per risalire alla radice dell'app.
    @discardableResult
    static func patchBundle(at appURL: URL, executableName: String) throws -> Bool {
        var changed = try patch(fileAt: appURL.appendingPathComponent(executableName))
        let root = appURL.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(at: appURL, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return changed
        }
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            let path = url.standardizedFileURL.path
            guard path != root + "/" + executableName, isMachO(url) else { continue }
            let relativeDir = String(path.dropFirst(root.count)).split(separator: "/").dropLast()
            if (try? patch(fileAt: url, isMain: false, depth: relativeDir.count)) == true { changed = true }
        }
        return changed
    }

    private static func writeString(_ b: inout [UInt8], _ value: String, at offset: Int, maxLength: Int) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count < maxLength else { return false }
        for i in 0..<maxLength { b[offset + i] = i < bytes.count ? bytes[i] : 0 }
        return true
    }

    private static func patchSlice(_ b: inout [UInt8], slice: Int, executableName: String, isMain: Bool, depth: Int) throws {
        let loaderRoot = "@loader_path" + String(repeating: "/..", count: depth)
        let cmds = commands(b, slice: slice)

        // @executable_path -> @loader_path (rpath e librerie collegate).
        // dyld rifiuta LC_RPATH duplicati: se il nuovo percorso esiste già, si usa "@loader_path/./…" (stessa cartella).
        let dylibCommands: Set<UInt32> = [lcLoadDylib, lcLoadWeakDylib, lcReexportDylib, lcLazyLoadDylib, lcLoadUpwardDylib, lcRpath]
        var seenRpaths = Set<String>()
        for c in cmds where dylibCommands.contains(c.cmd) {
            let strOff = Int(u32(b, c.offset + 8))
            guard strOff < c.size else { continue }
            let at = c.offset + strOff
            let maxLength = c.size - strOff
            var value = cString(b, at, max: maxLength)
            if value.hasPrefix("@executable_path") {
                value = loaderRoot + value.dropFirst("@executable_path".count)
            }
            if c.cmd == lcRpath {
                var candidate = value
                while seenRpaths.contains(candidate), candidate.hasPrefix("@loader_path") {
                    candidate = "@loader_path/." + candidate.dropFirst("@loader_path".count)
                }
                value = candidate
                seenRpaths.insert(value)
            }
            if value != cString(b, at, max: maxLength) {
                _ = writeString(&b, value, at: at, maxLength: maxLength)
            }
        }

        let filetype = u32(b, slice + 12)
        guard isMain, filetype == mhExecute else { return }

        // MH_EXECUTE -> MH_DYLIB
        set32(&b, slice + 12, mhDylib)
        var flags = u32(b, slice + 24)
        flags |= mhNoReexportedDylibs
        flags &= ~mhPIE
        set32(&b, slice + 24, flags)

        // __PAGEZERO: una sola pagina invece di 4 GB
        var firstSectionOffset = Int.max
        for c in cmds where c.cmd == lcSegment64 {
            let name = cString(b, c.offset + 8, max: 16)
            if name == "__PAGEZERO" && u64(b, c.offset + 24) == 0 {
                set64(&b, c.offset + 24, 0x1_0000_0000 - 0x4000)
                set64(&b, c.offset + 32, 0x4000)
            }
            let nsects = Int(u32(b, c.offset + 64))
            for i in 0..<nsects {
                let sec = c.offset + 72 + i * 80
                let off = Int(u32(b, sec + 48))
                if off > 0 { firstSectionOffset = min(firstSectionOffset, off) }
            }
        }

        // LC_ID_DYLIB come primo comando
        guard !cmds.contains(where: { $0.cmd == lcIDDylib }) else { return }
        let name = Array(executableName.utf8)
        let cmdSize = (24 + name.count + 1 + 7) & ~7
        let sizeOfCmds = Int(u32(b, slice + 20))
        let headerEnd = 32 + sizeOfCmds
        guard firstSectionOffset != Int.max, firstSectionOffset - headerEnd >= cmdSize else {
            throw MachOError.noHeaderSpace
        }
        let start = slice + 32
        // sposta i comandi esistenti in avanti di cmdSize
        var i = sizeOfCmds - 1
        while i >= 0 {
            b[start + cmdSize + i] = b[start + i]
            i -= 1
        }
        for j in 0..<cmdSize { b[start + j] = 0 }
        set32(&b, start, lcIDDylib)
        set32(&b, start + 4, UInt32(cmdSize))
        set32(&b, start + 8, 24)          // name.offset
        set32(&b, start + 12, 2)          // timestamp
        set32(&b, start + 16, 0x10000)    // current_version
        set32(&b, start + 20, 0x10000)    // compatibility_version
        for (k, byte) in name.enumerated() { b[start + 24 + k] = byte }

        set32(&b, slice + 16, u32(b, slice + 16) + 1)
        set32(&b, slice + 20, UInt32(sizeOfCmds + cmdSize))
    }
}
