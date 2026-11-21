import Foundation

public enum PEArchitecture: String, Sendable, Equatable {
    case x86 = "x86 (32-bit)"
    case x64 = "x86_64 (64-bit)"
    case arm64 = "ARM64"
    case unknown = "Unknown"
}

public enum PESubsystem: String, Sendable, Equatable {
    case windowsGUI = "Windows GUI"
    case windowsConsole = "Windows Console"
    case native = "Native"
    case other = "Other"
}

public struct PEInfo: Sendable, Equatable {
    public let path: String
    public let architecture: PEArchitecture
    public let subsystem: PESubsystem
    public let isDLL: Bool
    public let isMSI: Bool
    public let fileSizeBytes: Int64
}

/// Pure-Swift Portable Executable (PE32 / PE32+) inspector and icon resource extractor.
/// Zero external dependencies. Validates Windows executables before launch.
public enum PEInspector {
    public static func inspect(url: URL) throws -> PEInfo {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TinyWinError.executableNotFound(url.path)
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let headerData = try handle.read(upToCount: 4096) ?? Data()
        if headerData.count < 64 {
            throw TinyWinError.invalidPEFile("File is too small (\(headerData.count) bytes)")
        }

        // Check MSI (OLE Compound File Binary header: D0 CF 11 E0 A1 B1 1A E1)
        let oleMagic: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
        if headerData.prefix(8).elementsEqual(oleMagic) && url.pathExtension.lowercased() == "msi" {
            return PEInfo(
                path: url.path,
                architecture: .x86,
                subsystem: .windowsGUI,
                isDLL: false,
                isMSI: true,
                fileSizeBytes: fileSize
            )
        }

        // Check DOS header magic 'MZ'
        guard headerData[0] == 0x4D, headerData[1] == 0x5A else {
            throw TinyWinError.invalidPEFile("Missing MZ DOS signature (not a Windows PE executable)")
        }

        let peOffset = Int(readUInt32LE(headerData, at: 0x3C))
        guard peOffset > 0, peOffset < Int(fileSize) - 24 else {
            throw TinyWinError.invalidPEFile("Invalid PE header offset: \(peOffset)")
        }

        // Read PE header (COFF + Optional header)
        try handle.seek(toOffset: UInt64(peOffset))
        guard let peData = try handle.read(upToCount: 256), peData.count >= 24 else {
            throw TinyWinError.invalidPEFile("Truncated PE header")
        }

        // Check 'PE\0\0'
        guard peData[0] == 0x50, peData[1] == 0x45, peData[2] == 0x00, peData[3] == 0x00 else {
            throw TinyWinError.invalidPEFile("Missing PE\\0\\0 signature")
        }

        let machine = readUInt16LE(peData, at: 4)
        let characteristics = readUInt16LE(peData, at: 22)
        let isDLL = (characteristics & 0x2000) != 0

        let arch: PEArchitecture
        switch machine {
        case 0x014C: arch = .x86
        case 0x8664: arch = .x64
        case 0xAA64: arch = .arm64
        default: arch = .unknown
        }

        // Optional header starts at offset 24
        var subsystem: PESubsystem = .other
        if peData.count >= 94 {
            let optMagic = readUInt16LE(peData, at: 24)
            // Subsystem field is at OptionalHeader + 68 for both PE32 (0x10B) and PE32+ (0x20B)
            if optMagic == 0x010B || optMagic == 0x020B {
                let rawSubsystem = readUInt16LE(peData, at: 24 + 68)
                switch rawSubsystem {
                case 1: subsystem = .native
                case 2: subsystem = .windowsGUI
                case 3: subsystem = .windowsConsole
                default: subsystem = .other
                }
            }
        }

        return PEInfo(
            path: url.path,
            architecture: arch,
            subsystem: subsystem,
            isDLL: isDLL,
            isMSI: false,
            fileSizeBytes: fileSize
        )
    }

    /// Best-effort extraction of the largest PNG/BMP icon image from a PE file's `.rsrc` section.
    /// Returns valid `.ico` bytes (suitable for `sips` / `iconutil` conversion to `.icns`) if found.
    public static func extractIconICO(from url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count > 128 else {
            return nil
        }
        guard data[0] == 0x4D, data[1] == 0x5A else { return nil }
        let peOffset = Int(readUInt32LE(data, at: 0x3C))
        guard peOffset > 0, peOffset + 24 < data.count else { return nil }
        guard data[peOffset] == 0x50, data[peOffset + 1] == 0x45,
              data[peOffset + 2] == 0x00, data[peOffset + 3] == 0x00 else { return nil }

        let numberOfSections = Int(readUInt16LE(data, at: peOffset + 6))
        let sizeOfOptionalHeader = Int(readUInt16LE(data, at: peOffset + 20))
        let sectionTableOffset = peOffset + 24 + sizeOfOptionalHeader

        // Find `.rsrc` section
        var rsrcRVA: UInt32 = 0
        var rsrcRawOffset: Int = 0
        var rsrcRawSize: Int = 0

        for i in 0..<numberOfSections {
            let off = sectionTableOffset + i * 40
            guard off + 40 <= data.count else { break }
            let nameBytes = data[off..<(off + 8)].prefix { $0 != 0 }
            let name = String(decoding: nameBytes, as: UTF8.self)
            if name == ".rsrc" {
                rsrcRVA = readUInt32LE(data, at: off + 12)
                rsrcRawSize = Int(readUInt32LE(data, at: off + 16))
                rsrcRawOffset = Int(readUInt32LE(data, at: off + 20))
                break
            }
        }

        guard rsrcRawSize > 16, rsrcRawOffset > 0, rsrcRawOffset + rsrcRawSize <= data.count else {
            return nil
        }

        // Parse 3-level resource directory tree for RT_ICON (type 3)
        let iconEntries = collectIconResources(
            data: data,
            rsrcBase: rsrcRawOffset,
            rsrcRVA: rsrcRVA,
            rsrcEnd: rsrcRawOffset + rsrcRawSize
        )
        guard !iconEntries.isEmpty else { return nil }

        // Pick largest valid icon payload (PNG or DIB bitmap)
        let pngSig: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let best = iconEntries.max(by: { $0.count < $1.count })!

        // If it's a PNG icon, wrap it into a single-image .ico container
        var width: UInt8 = 0
        var height: UInt8 = 0
        if best.count >= 24 && best.prefix(8).elementsEqual(pngSig) {
            let s = best.startIndex
            let w = UInt32(best[s + 16]) << 24 | UInt32(best[s + 17]) << 16 | UInt32(best[s + 18]) << 8 | UInt32(best[s + 19])
            let h = UInt32(best[s + 20]) << 24 | UInt32(best[s + 21]) << 16 | UInt32(best[s + 22]) << 8 | UInt32(best[s + 23])
            width = w >= 256 ? 0 : UInt8(w)
            height = h >= 256 ? 0 : UInt8(h)
        } else if best.count >= 40 {
            let dibSize = readUInt32LE(best, at: 0)
            guard dibSize == 40 else { return nil }
            let w = Int64(Int32(bitPattern: readUInt32LE(best, at: 4)))
            let h = abs(Int64(Int32(bitPattern: readUInt32LE(best, at: 8)))) / 2
            guard w > 0, h > 0 else { return nil }
            width = w >= 256 ? 0 : UInt8(w)
            height = h >= 256 ? 0 : UInt8(h)
        } else {
            return nil
        }

        // Build minimal valid ICO header (6 bytes) + 1 ICONDIRENTRY (16 bytes) + payload
        var ico = Data(capacity: 22 + best.count)
        ico.append(contentsOf: [0x00, 0x00, 0x01, 0x00, 0x01, 0x00]) // reserved=0, type=1 (ICO), count=1
        ico.append(width)
        ico.append(height)
        ico.append(0x00) // color count
        ico.append(0x00) // reserved
        ico.append(contentsOf: [0x01, 0x00]) // planes
        ico.append(contentsOf: [0x20, 0x00]) // bpp = 32
        var byteCount = UInt32(best.count).littleEndian
        ico.append(Data(bytes: &byteCount, count: 4))
        var imgOffset = UInt32(22).littleEndian
        ico.append(Data(bytes: &imgOffset, count: 4))
        ico.append(best)
        return ico
    }

    private static func collectIconResources(data: Data, rsrcBase: Int, rsrcRVA: UInt32, rsrcEnd: Int) -> [Data] {
        var results: [Data] = []
        guard let rootEntries = readResourceDirEntries(data: data, dirOffset: rsrcBase, rsrcEnd: rsrcEnd) else {
            return results
        }
        // Level 1: Type == 3 (RT_ICON)
        for entry in rootEntries where entry.id == 3 && entry.isSubdir {
            let level2Off = rsrcBase + entry.offset
            guard let nameEntries = readResourceDirEntries(data: data, dirOffset: level2Off, rsrcEnd: rsrcEnd) else { continue }
            for nameEntry in nameEntries where nameEntry.isSubdir {
                let level3Off = rsrcBase + nameEntry.offset
                guard let langEntries = readResourceDirEntries(data: data, dirOffset: level3Off, rsrcEnd: rsrcEnd) else { continue }
                for langEntry in langEntries where !langEntry.isSubdir {
                    let dataEntryOff = rsrcBase + langEntry.offset
                    guard dataEntryOff + 16 <= rsrcEnd else { continue }
                    let dataRVA = readUInt32LE(data, at: dataEntryOff)
                    let size = Int(readUInt32LE(data, at: dataEntryOff + 4))
                    guard dataRVA >= rsrcRVA, size > 40, size < 4 * 1024 * 1024 else { continue }
                    let rawOff = rsrcBase + Int(dataRVA - rsrcRVA)
                    guard rawOff >= rsrcBase, rawOff + size <= data.count else { continue }
                    results.append(Data(data[rawOff..<(rawOff + size)]))
                }
            }
        }
        return results
    }

    private struct ResEntry {
        let id: UInt32
        let isSubdir: Bool
        let offset: Int
    }

    private static func readResourceDirEntries(data: Data, dirOffset: Int, rsrcEnd: Int) -> [ResEntry]? {
        guard dirOffset >= 0, dirOffset + 16 <= rsrcEnd else { return nil }
        let namedCount = Int(readUInt16LE(data, at: dirOffset + 12))
        let idCount = Int(readUInt16LE(data, at: dirOffset + 14))
        let total = namedCount + idCount
        guard total > 0, total < 2048, dirOffset + 16 + total * 8 <= rsrcEnd else { return nil }

        var entries: [ResEntry] = []
        entries.reserveCapacity(total)
        for i in 0..<total {
            let off = dirOffset + 16 + i * 8
            let nameOrId = readUInt32LE(data, at: off)
            let dataOrSubdir = readUInt32LE(data, at: off + 4)
            let isSubdir = (dataOrSubdir & 0x8000_0000) != 0
            let relOffset = Int(dataOrSubdir & 0x7FFF_FFFF)
            entries.append(ResEntry(id: nameOrId, isSubdir: isSubdir, offset: relOffset))
        }
        return entries
    }

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }
}
