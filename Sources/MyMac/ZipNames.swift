import Foundation

/// The Mac's zip tools store file names as UTF-8 but don't set the zip format's "UTF-8 names" flag
/// (bit 11), so Windows shows names like "नमस्ते 😀.txt" as gibberish. This sets that flag on every
/// entry, in the central directory (what Windows and Archive Utility read) and in each local header.
/// Only a few bytes change; file data is never rewritten.
enum ZipNames {
    struct Entry { let name: String; let utf8Flag: Bool }

    private static let utf8Bit: UInt16 = 0x0800

    /// Sets the UTF-8 flag on every entry. Returns false if the file doesn't look like a zip.
    @discardableResult
    static func markUTF8(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forUpdating: url),
              let directory = centralDirectory(handle) else { return false }
        defer { try? handle.close() }
        var cd = directory.bytes
        var localOffsets: [UInt64] = []
        var p = 0
        while p + 46 <= cd.count, read32(cd, p) == 0x02014B50 {
            let flags = read16(cd, p + 8) | utf8Bit
            cd[p + 8] = UInt8(flags & 0xFF); cd[p + 9] = UInt8(flags >> 8)
            let nameLen = Int(read16(cd, p + 28)), extraLen = Int(read16(cd, p + 30)), commentLen = Int(read16(cd, p + 32))
            let local = read32(cd, p + 42)
            if local != 0xFFFF_FFFF { localOffsets.append(UInt64(local)) }   // zip64 entries: central flag is enough
            p += 46 + nameLen + extraLen + commentLen
        }
        do {
            try handle.seek(toOffset: directory.offset)
            try handle.write(contentsOf: Data(cd))
            for offset in localOffsets {
                try handle.seek(toOffset: offset)
                guard let head = try handle.read(upToCount: 8), head.count == 8,
                      read32([UInt8](head), 0) == 0x04034B50 else { continue }
                let flags = read16([UInt8](head), 6) | utf8Bit
                try handle.seek(toOffset: offset + 6)
                try handle.write(contentsOf: Data([UInt8(flags & 0xFF), UInt8(flags >> 8)]))
            }
            return true
        } catch {
            return false
        }
    }

    /// Entry names and whether each is flagged UTF-8 (used by the self-test).
    static func entries(_ url: URL) -> [Entry] {
        guard let handle = try? FileHandle(forReadingFrom: url), let directory = centralDirectory(handle) else { return [] }
        defer { try? handle.close() }
        let cd = directory.bytes
        var result: [Entry] = []
        var p = 0
        while p + 46 <= cd.count, read32(cd, p) == 0x02014B50 {
            let flags = read16(cd, p + 8)
            let nameLen = Int(read16(cd, p + 28)), extraLen = Int(read16(cd, p + 30)), commentLen = Int(read16(cd, p + 32))
            guard p + 46 + nameLen <= cd.count else { break }
            let name = String(decoding: cd[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            result.append(Entry(name: name, utf8Flag: flags & utf8Bit != 0))
            p += 46 + nameLen + extraLen + commentLen
        }
        return result
    }

    // MARK: - Reading the zip's index

    private static func centralDirectory(_ handle: FileHandle) -> (offset: UInt64, bytes: [UInt8])? {
        guard let size = try? handle.seekToEnd(), size >= 22 else { return nil }
        let tailLength = min(size, 65_557)
        guard (try? handle.seek(toOffset: size - tailLength)) != nil,
              let tailData = try? handle.read(upToCount: Int(tailLength)) else { return nil }
        let tail = [UInt8](tailData)
        // End of central directory record, searched from the end (a comment may follow it).
        var e = tail.count - 22
        while e >= 0, read32(tail, e) != 0x06054B50 { e -= 1 }
        guard e >= 0 else { return nil }
        var cdSize = UInt64(read32(tail, e + 12)), cdOffset = UInt64(read32(tail, e + 16))
        if cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            // Zip64: the locator just before points at the zip64 end record.
            guard e >= 20, read32(tail, e - 20) == 0x07064B50 else { return nil }
            let z64 = read64(tail, e - 20 + 8)
            guard (try? handle.seek(toOffset: z64)) != nil, let rec = try? handle.read(upToCount: 56),
                  rec.count == 56, read32([UInt8](rec), 0) == 0x06064B50 else { return nil }
            cdSize = read64([UInt8](rec), 40)
            cdOffset = read64([UInt8](rec), 48)
        }
        guard cdOffset + cdSize <= size, cdSize < 512 * 1_048_576,
              (try? handle.seek(toOffset: cdOffset)) != nil,
              let cd = try? handle.read(upToCount: Int(cdSize)) else { return nil }
        return (cdOffset, [UInt8](cd))
    }

    private static func read16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    private static func read32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
    private static func read64(_ b: [UInt8], _ i: Int) -> UInt64 {
        UInt64(read32(b, i)) | UInt64(read32(b, i + 4)) << 32
    }
}
