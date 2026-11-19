import AppKit
import SwiftUI

/// Shown in the copy/move progress window.
struct TransferProgress {
    var title: String
    var fraction: Double
    var currentName: String
}

enum ConflictChoice { case replace, skip, keepBoth, cancel }

/// "Replace or Skip Files" question, answered by the dialog.
struct ConflictRequest: Identifiable {
    let id = UUID()
    let verb: String
    let count: Int
    let firstName: String
    let destination: String
    let respond: (ConflictChoice) -> Void
}

/// One step that ⌘Z can reverse.
enum UndoEntry {
    case rename(from: URL, to: URL)
    case move([(from: URL, to: URL)])
    case create([URL], what: String)
    case trash([(original: URL, inTrash: URL)])

    var title: String {
        switch self {
        case .rename: return "Undo Rename"
        case .move: return "Undo Move"
        case .create(_, let what): return "Undo \(what)"
        case .trash: return "Undo Delete"
        }
    }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}

struct CancelledError: Error {}

/// Copy, move, delete, compress and undo — shared by every tab, like Windows' single file-operation engine.
@MainActor
final class FileOps: ObservableObject {
    static let shared = FileOps()

    @Published var progress: TransferProgress?
    @Published var conflict: ConflictRequest?
    @Published private(set) var undoStack: [UndoEntry] = []
    @Published var errorMessage: String?
    /// A short confirmation shown in the status bar for a few seconds ("3 items copied").
    @Published private(set) var notice: String?
    private var noticeID = UUID()

    func say(_ text: String) {
        notice = text
        let id = UUID()
        noticeID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.noticeID == id { self?.notice = nil }
        }
    }

    static func count(_ n: Int) -> String { n == 1 ? "1 item" : "\(n) items" }
    private var flag = CancelFlag()

    var undoTitle: String? { undoStack.last?.title }

    func record(_ entry: UndoEntry) {
        undoStack.append(entry)
        if undoStack.count > 50 { undoStack.removeFirst() }
    }

    func cancelTransfer() { flag.cancel() }

    // MARK: Copy / move

    /// Copies or moves files into a folder. Returns the new items.
    @discardableResult
    func transfer(_ sources: [URL], into dir: URL, move: Bool) async -> [URL] {
        let fm = FileManager.default
        let dirPath = dir.resolvingSymlinksInPath().standardizedFileURL.path
        var plan: [(src: URL, dest: URL)] = []
        var conflicts: [(src: URL, dest: URL)] = []
        var errors: [String] = []

        for src in sources {
            let srcPath = src.resolvingSymlinksInPath().standardizedFileURL.path
            if dirPath == srcPath || dirPath.hasPrefix(srcPath + "/") || Self.sameFile(src, dir) {
                errors.append("The destination folder is a subfolder of the source folder.")
                continue
            }
            let sameFolder = Self.sameFile(src.deletingLastPathComponent(), dir)
            if sameFolder {
                if move { continue }
                plan.append((src, Self.copyName(for: src.lastPathComponent, in: dir)))
                continue
            }
            let dest = dir.appendingPathComponent(src.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { conflicts.append((src, dest)) } else { plan.append((src, dest)) }
        }

        var replacing = Set<String>()
        if !conflicts.isEmpty {
            let choice = await ask(verb: move ? "Moving" : "Copying", count: conflicts.count,
                                   firstName: conflicts[0].src.lastPathComponent,
                                   destination: FileManager.default.displayName(atPath: dir.path))
            switch choice {
            case .cancel: return []
            case .skip: break
            case .replace:
                for c in conflicts { replacing.insert(c.dest.path); plan.append(c) }
            case .keepBoth:
                for c in conflicts { plan.append((c.src, Self.uniqueURL(in: dir, name: c.src.lastPathComponent))) }
            }
        }
        if !errors.isEmpty { errorMessage = errors[0] }
        guard !plan.isEmpty else { return [] }

        let dirVolume = Self.volumeID(dir)
        let names = plan.count == 1 ? "1 item" : "\(plan.count) items"
        let from = FileManager.default.displayName(atPath: plan[0].src.deletingLastPathComponent().path)
        let to = FileManager.default.displayName(atPath: dir.path)
        let title = "\(move ? "Moving" : "Copying") \(names) from \(from) to \(to)"
        flag = CancelFlag()
        let flag = self.flag
        progress = TransferProgress(title: title, fraction: 0, currentName: "")

        let report: @Sendable (Double, String) -> Void = { fraction, name in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    FileOps.shared.progress?.fraction = fraction
                    FileOps.shared.progress?.currentName = name
                }
            }
        }
        let jobs = plan
        let replaceSet = replacing
        let result = await Task.detached(priority: .userInitiated) {
            Self.run(jobs, move: move, replacing: replaceSet, dirVolume: dirVolume, flag: flag, report: report)
        }.value

        progress = nil
        if let error = result.errors.first { errorMessage = error }
        if !result.done.isEmpty {
            record(move ? .move(result.done.map { (from: $0.src, to: $0.dest) })
                        : .create(result.done.map(\.dest), what: "Copy"))
        }
        return result.done.map(\.dest)
    }

    private func ask(verb: String, count: Int, firstName: String, destination: String) async -> ConflictChoice {
        await withCheckedContinuation { continuation in
            // The dialog may report more than once (a button, then closing); only the first answer counts.
            let once = CancelFlag()
            conflict = ConflictRequest(verb: verb, count: count, firstName: firstName, destination: destination) { choice in
                guard !once.isCancelled else { return }
                once.cancel()
                continuation.resume(returning: choice)
            }
        }
    }

    nonisolated private static func run(_ plan: [(src: URL, dest: URL)], move: Bool, replacing: Set<String>,
                                        dirVolume: NSObject?, flag: CancelFlag,
                                        report: @escaping @Sendable (Double, String) -> Void)
        -> (done: [(src: URL, dest: URL)], errors: [String]) {
        let fm = FileManager.default
        var done: [(src: URL, dest: URL)] = []
        var errors: [String] = []
        let fastMove = { (src: URL) in move && volumeID(src) == dirVolume }
        let total = max(plan.reduce(Int64(0)) { $0 + (fastMove($1.src) ? 1 : byteCount($1.src)) }, 1)
        var copied: Int64 = 0
        var lastReport = Date.distantPast

        for job in plan {
            if flag.isCancelled { break }
            do {
                if replacing.contains(job.dest.path) {
                    try fm.trashItem(at: job.dest, resultingItemURL: nil)
                }
                if fastMove(job.src) {
                    try fm.moveItem(at: job.src, to: job.dest)
                    copied += 1
                } else {
                    try copyTree(job.src, to: job.dest, flag: flag) { bytes, name in
                        copied += bytes
                        if Date().timeIntervalSince(lastReport) > 0.05 {
                            lastReport = Date()
                            report(Double(copied) / Double(total), name)
                        }
                    }
                    if move { try fm.removeItem(at: job.src) }
                }
                done.append(job)
                report(Double(copied) / Double(total), job.src.lastPathComponent)
            } catch is CancelledError {
                try? fm.removeItem(at: job.dest)
                break
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        return (done, errors)
    }

    nonisolated private static func copyTree(_ src: URL, to dest: URL, flag: CancelFlag,
                                             progress: (Int64, String) -> Void) throws {
        if flag.isCancelled { throw CancelledError() }
        let fm = FileManager.default
        let values = try? src.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .fileSizeKey])
        if values?.isDirectory == true, values?.isPackage != true, values?.isSymbolicLink != true {
            try fm.createDirectory(at: dest, withIntermediateDirectories: false)
            for child in try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil, options: []) {
                try copyTree(child, to: dest.appendingPathComponent(child.lastPathComponent), flag: flag, progress: progress)
            }
        } else {
            try fm.copyItem(at: src, to: dest)
            let size = values?.isPackage == true ? byteCount(src) : Int64(values?.fileSize ?? 0)
            progress(size, src.lastPathComponent)
        }
    }

    nonisolated static func byteCount(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        guard values?.isDirectory == true else { return Int64(values?.fileSize ?? 0) }
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey],
                                                     options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        while let next = e.nextObject() as? URL {
            total += Int64((try? next.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    nonisolated static func volumeID(_ url: URL) -> NSObject? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
    }

    // MARK: Delete

    func trash(_ urls: [URL]) {
        var pairs: [(original: URL, inTrash: URL)] = []
        for url in urls {
            var result: NSURL?
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: &result)
                if let inTrash = result as URL? { pairs.append((url, inTrash)) }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        if !pairs.isEmpty { record(.trash(pairs)) }
    }

    /// Shift+Delete: skips the Recycle Bin (asked for first by the caller).
    func deletePermanently(_ urls: [URL]) {
        for url in urls {
            do { try FileManager.default.removeItem(at: url) } catch { errorMessage = error.localizedDescription }
        }
    }

    // MARK: Undo

    func undo() {
        guard let entry = undoStack.popLast() else { return }
        let fm = FileManager.default
        do {
            switch entry {
            case .rename(let from, let to):
                try Self.moveRenaming(to, to: from)
            case .move(let pairs):
                for pair in pairs.reversed() { try fm.moveItem(at: pair.to, to: pair.from) }
            case .create(let urls, _):
                for url in urls where fm.fileExists(atPath: url.path) { try fm.trashItem(at: url, resultingItemURL: nil) }
            case .trash(let pairs):
                for pair in pairs { try fm.moveItem(at: pair.inTrash, to: pair.original) }
            }
        } catch {
            errorMessage = "Couldn't undo: \(error.localizedDescription)"
        }
    }

    // MARK: Zip

    /// "Compress to ZIP file": a zip next to the first item, named after it (a folder keeps its whole
    /// name, e.g. "Trip 2024.06.zip"). Items from different folders (search results) all go in,
    /// awkward names (-x, [1], *, ?) are taken literally, and Mac junk (.DS_Store) is left out.
    func compress(_ urls: [URL]) async -> URL? {
        guard let first = urls.first else { return nil }
        let dir = first.deletingLastPathComponent()
        let name = first.lastPathComponent
        let stem = FileBrowser.isFolder(first) ? name : (name as NSString).deletingPathExtension
        let dest = Self.uniqueURL(in: dir, name: (stem.isEmpty ? name : stem) + ".zip")
        if urls.count > 3 { say("Compressing \(Self.count(urls.count))…") }
        // Add each item from its own folder ("./name" so a leading "-" isn't read as an option;
        // -nw so [ ] * ? aren't wildcards).
        for url in urls {
            let result = await Self.runTool("/usr/bin/zip", ["-r", "-y", "-q", "-nw", dest.path, "./" + url.lastPathComponent],
                                            in: url.deletingLastPathComponent())
            if !result.ok {
                try? FileManager.default.removeItem(at: dest)
                errorMessage = "Couldn't create “\(dest.lastPathComponent)”. \(Self.friendly(result.error))"
                return nil
            }
        }
        // Leave out Finder's hidden .DS_Store files (Windows users see them as junk).
        _ = await Self.runTool("/usr/bin/zip", ["-q", "-d", dest.path, "*.DS_Store", "*/.DS_Store"], in: dir)
        // Mark names as UTF-8 so Windows shows Hindi, emoji and accents correctly.
        ZipNames.markUTF8(dest)
        record(.create([dest], what: "Compress"))
        say("Compressed \(Self.count(urls.count)) into \(dest.lastPathComponent)")
        return dest
    }

    /// "Extract All": unpacks next to the zip into a folder of the same name.
    func extract(_ zip: URL) async -> URL? {
        let dir = zip.deletingLastPathComponent()
        let dest = Self.uniqueURL(in: dir, name: (zip.lastPathComponent as NSString).deletingPathExtension)
        let result = await Self.runTool("/usr/bin/ditto", ["-x", "-k", zip.path, dest.path], in: dir)
        if result.ok {
            record(.create([dest], what: "Extract"))
            say("Extracted “\(zip.lastPathComponent)” into \(dest.lastPathComponent)")
            return dest
        }
        try? FileManager.default.removeItem(at: dest)
        errorMessage = "Can't open the folder. The compressed (zipped) folder “\(zip.lastPathComponent)” is invalid or can't be read."
        return nil
    }

    /// Turns a tool's error output into something readable.
    private static func friendly(_ error: String) -> String {
        let text = error.lowercased()
        if text.contains("permission denied") || text.contains("read-only") || text.contains("could not create") {
            return "You don't have permission to save files in this folder."
        }
        if text.contains("no space") { return "There isn't enough free space on the disk." }
        let line = error.split(separator: "\n").first.map(String.init) ?? ""
        return line.isEmpty ? "Something went wrong while compressing." : line
    }

    nonisolated private static func runTool(_ path: String, _ args: [String], in dir: URL) async -> (ok: Bool, error: String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            process.currentDirectoryURL = dir
            process.standardOutput = FileHandle.nullDevice
            let errPipe = Pipe()
            process.standardError = errPipe
            process.terminationHandler = { p in
                let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: (p.terminationStatus == 0, String(data: data, encoding: .utf8) ?? ""))
            }
            do { try process.run() } catch { continuation.resume(returning: (false, error.localizedDescription)) }
        }
    }

    // MARK: Images

    /// "Rotate left/right" for pictures, written back in the same format.
    /// Uses the picture as you see it (iPhone photos store their turn in EXIF) and keeps its metadata.
    func rotate(_ urls: [URL], clockwise: Bool) {
        for url in urls where !Self.rotateImage(at: url, clockwise: clockwise) {
            errorMessage = "Couldn't rotate “\(url.lastPathComponent)”."
        }
    }

    nonisolated static func rotateImage(at url: URL, clockwise: Bool) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pw = props[kCGImagePropertyPixelWidth] as? Int, let ph = props[kCGImagePropertyPixelHeight] as? Int
        else { return false }
        // Full-size image with its EXIF orientation already applied.
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: max(pw, ph)]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return false }
        let w = image.width, h = image.height
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: h, height: w, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        if clockwise {
            ctx.translateBy(x: 0, y: CGFloat(w))
            ctx.rotate(by: -.pi / 2)
        } else {
            ctx.translateBy(x: CGFloat(h), y: 0)
            ctx.rotate(by: .pi / 2)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let rotated = ctx.makeImage() else { return false }
        var meta = props
        meta[kCGImagePropertyOrientation] = 1
        meta[kCGImagePropertyPixelWidth] = nil
        meta[kCGImagePropertyPixelHeight] = nil
        if var tiff = meta[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            meta[kCGImagePropertyTIFFDictionary] = tiff
        }
        meta[kCGImageDestinationLossyCompressionQuality] = 0.95
        // Write next to the original, then swap, so a failure never damages the picture.
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).\(url.pathExtension)")
        guard let dest = CGImageDestinationCreateWithURL(temp as CFURL, type, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, rotated, meta as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { try? FileManager.default.removeItem(at: temp); return false }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            return true
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return false
        }
    }

    // MARK: Names

    /// True when two paths are the same file on disk (e.g. "report.txt" and "Report.txt", or /tmp and /private/tmp).
    nonisolated static func sameFile(_ a: URL, _ b: URL) -> Bool {
        func id(_ u: URL) -> NSObject? {
            (try? u.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject
        }
        guard let x = id(a), let y = id(b) else { return false }
        return x.isEqual(y)
    }

    /// Rename that also works when only capitals change ("report" → "Report"),
    /// which the Mac's case-insensitive disk otherwise treats as "already exists".
    nonisolated static func moveRenaming(_ src: URL, to dest: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path), sameFile(src, dest) {
            let temp = src.deletingLastPathComponent().appendingPathComponent(".rename-\(UUID().uuidString)")
            try fm.moveItem(at: src, to: temp)
            do { try fm.moveItem(at: temp, to: dest) } catch {
                try? fm.moveItem(at: temp, to: src)
                throw error
            }
        } else {
            try fm.moveItem(at: src, to: dest)
        }
    }

    /// Windows copy naming: "Report - Copy.pdf", "Report - Copy (2).pdf".
    nonisolated static func copyName(for name: String, in dir: URL) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        func make(_ suffix: String) -> URL {
            dir.appendingPathComponent(ext.isEmpty ? "\(base)\(suffix)" : "\(base)\(suffix).\(ext)")
        }
        var candidate = make(" - Copy")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = make(" - Copy (\(n))")
            n += 1
        }
        return candidate
    }

    /// "New folder" → "New folder (2)".
    nonisolated static func uniqueURL(in dir: URL, name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = dir.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            candidate = dir.appendingPathComponent(next)
            counter += 1
        }
        return candidate
    }
}
