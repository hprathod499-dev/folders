import AppKit
import QuickLookThumbnailing
import SwiftUI

/// One file or folder shown in the browser.
struct FileItem: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let size: Int64          // -1 for folders and app bundles
    let modified: Date
    let created: Date?
    let kind: String

    var id: URL { url }

    static let resourceKeys: [URLResourceKey] = [
        .nameKey, .isDirectoryKey, .isPackageKey, .fileSizeKey,
        .contentModificationDateKey, .creationDateKey, .localizedTypeDescriptionKey,
    ]

    init(url: URL) {
        let values = try? url.resourceValues(forKeys: Set(Self.resourceKeys))
        let isDir = values?.isDirectory ?? false
        let isPackage = values?.isPackage ?? false
        self.url = url
        self.name = values?.name ?? url.lastPathComponent
        self.isDirectory = isDir && !isPackage
        self.isPackage = isPackage
        self.size = (isDir || isPackage) ? -1 : Int64(values?.fileSize ?? 0)
        self.modified = values?.contentModificationDate ?? .distantPast
        self.created = values?.creationDate
        self.kind = values?.localizedTypeDescription ?? (isDir ? "Folder" : "Document")
    }

    var icon: NSImage { IconCache.shared.icon(for: url) }
    var ext: String { url.pathExtension }
    var isZip: Bool { ext.lowercased() == "zip" }
    var isImage: Bool { ["jpg", "jpeg", "png", "heic", "tif", "tiff", "bmp", "gif", "webp"].contains(ext.lowercased()) }

    /// Windows-style type names: "File folder", "PNG File", "Application"…
    var typeText: String {
        if isDirectory {
            return DiskImages.imageFile(forMountPoint: url.path) != nil ? "Disk image (read-only)" : "File folder"
        }
        switch ext.lowercased() {
        case "": return "File"
        case "app": return "Application"
        case "txt": return "Text Document"
        case "zip": return "Compressed (zipped) Folder"
        case "pdf": return "PDF Document"
        case "rtf": return "Rich Text Document"
        case "html", "htm": return "HTML Document"
        case "doc", "docx": return "Word Document"
        case "xls", "xlsx": return "Excel Worksheet"
        case "ppt", "pptx": return "PowerPoint Presentation"
        case "dmg": return "Disk Image"
        default: return "\(ext.uppercased()) File"
        }
    }

    /// Like Windows, file extensions are hidden unless turned on in View › Show.
    func displayName(showExtensions: Bool) -> String {
        if showExtensions || isDirectory || ext.isEmpty { return name }
        return (name as NSString).deletingPathExtension
    }

    var sizeText: String { size < 0 ? "" : WinFormat.friendly(size) }

    /// Total size, file count and folder count of a folder (runs off the main thread).
    static func folderStats(_ url: URL) async -> (bytes: Int64, files: Int, folders: Int) {
        folderStatsSync(url)
    }

    private static func folderStatsSync(_ url: URL) -> (bytes: Int64, files: Int, folders: Int) {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: [],
            errorHandler: { _, _ in true }
        ) else { return (0, 0, 0) }
        var bytes: Int64 = 0
        var files = 0
        var folders = 0
        while let next = enumerator.nextObject() as? URL {
            if Task.isCancelled { break }
            let v = try? next.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if v?.isDirectory == true { folders += 1 } else { files += 1 }
            bytes += Int64(v?.fileSize ?? 0)
        }
        return (bytes, files, folders)
    }
}

enum WinFormat {
    static let date: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd-MM-yyyy HH:mm"
        return f
    }()

    static let longDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd MMMM yyyy, HH:mm:ss"
        return f
    }()

    static let month: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f
    }()

    private static let grouping: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        return f
    }()

    static func number(_ n: Int64) -> String { grouping.string(from: NSNumber(value: n)) ?? "\(n)" }

    /// "1,673 KB" — the Size column always uses KB, rounded up.
    /// Sizes in MB (GB/TB once large) — never KB or bytes. Tiny files show "0.01 MB".
    static func friendly(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        func fmt(_ v: Double) -> String { f.string(from: NSNumber(value: v)) ?? String(format: "%.2f", v) }
        if bytes <= 0 { return "0 MB" }
        if mb < 0.01 { return "0.01 MB" }
        if mb < 1024 { return "\(fmt(mb)) MB" }
        if mb < 1024 * 1024 { return "\(fmt(mb / 1024)) GB" }
        return "\(fmt(mb / 1024 / 1024)) TB"
    }

    /// "939 KB (9,61,234 bytes)" as in the Properties dialog.
    static func withBytes(_ bytes: Int64) -> String { "\(friendly(bytes)) (\(number(bytes)) bytes)" }
}

/// Date groups used when grouping by date (like the Downloads folder in Windows).
enum DateGroup: Int, CaseIterable {
    case today, yesterday, earlierThisWeek, lastWeek, earlierThisMonth, lastMonth, earlierThisYear, longAgo

    var title: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .earlierThisWeek: return "Earlier this week"
        case .lastWeek: return "Last week"
        case .earlierThisMonth: return "Earlier this month"
        case .lastMonth: return "Last month"
        case .earlierThisYear: return "Earlier this year"
        case .longAgo: return "A long time ago"
        }
    }

    static func of(_ date: Date, now: Date = Date(), calendar cal: Calendar = .current) -> DateGroup {
        let today = cal.startOfDay(for: now)
        if date >= today { return .today }
        if date >= cal.date(byAdding: .day, value: -1, to: today)! { return .yesterday }
        let week = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        if date >= week { return .earlierThisWeek }
        if date >= cal.date(byAdding: .day, value: -7, to: week)! { return .lastWeek }
        let month = cal.dateInterval(of: .month, for: now)?.start ?? today
        if date >= month { return .earlierThisMonth }
        if date >= cal.date(byAdding: .month, value: -1, to: month)! { return .lastMonth }
        let year = cal.dateInterval(of: .year, for: now)?.start ?? today
        if date >= year { return .earlierThisYear }
        return .longAgo
    }
}

/// A mounted drive, shown Windows-style as "Macintosh HD (C:)".
struct VolumeInfo: Identifiable, Hashable {
    let url: URL
    let name: String
    let letter: String
    let total: Int64
    let available: Int64
    let format: String
    let isRemovable: Bool
    let isReadOnly: Bool
    /// The .dmg/.iso file this volume was opened from, if it's a disk image rather than a real drive.
    let imageFile: URL?

    var id: URL { url }
    var used: Int64 { max(total - available, 0) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
    var isInternal: Bool { url.path == "/" }
    var isDiskImage: Bool { imageFile != nil }
    /// Real drives: "Macintosh HD (C:)". Disk images live inside Macintosh HD, so they get no letter.
    var displayName: String { letter.isEmpty ? name : "\(name) (\(letter))" }
    var imageFileSize: Int64 {
        guard let imageFile else { return 0 }
        return Int64((try? imageFile.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    static func all() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey, .volumeLocalizedFormatDescriptionKey, .volumeIsRemovableKey,
            .volumeIsEjectableKey, .volumeIsReadOnlyKey,
        ]
        let urls = (FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]
        ) ?? []).sorted { a, b in
            if a.path == "/" { return true }
            if b.path == "/" { return false }
            return a.path < b.path
        }
        let letters = Array("CDEFGHIJKLMNOPQRSTUVWXYZ")
        let images = DiskImages.sources(for: Set(urls.map { $0.standardizedFileURL.path }))
        var nextLetter = 0
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let total = Int64(v.volumeTotalCapacity ?? 0)
            let available = v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
            let image = images[url.standardizedFileURL.path]
            var letter = ""
            if image == nil, nextLetter < letters.count {
                letter = "\(letters[nextLetter]):"
                nextLetter += 1
            }
            return VolumeInfo(url: url.normalizedFolder, name: v.volumeName ?? url.lastPathComponent,
                              letter: letter,
                              total: total, available: available,
                              format: v.volumeLocalizedFormatDescription ?? "",
                              isRemovable: (v.volumeIsRemovable ?? false) || (v.volumeIsEjectable ?? false),
                              isReadOnly: v.volumeIsReadOnly ?? false,
                              imageFile: image)
        }
    }
}

/// Finds which mounted volumes are opened disk image files (.dmg, .iso) and where those files live.
enum DiskImages {
    private static var cachedFor: Set<String> = []
    private static var cache: [String: URL] = [:]
    private static let lock = NSLock()

    /// Mount point path → image file. Re-reads `hdiutil info` only when the set of mounted volumes changes.
    static func sources(for mounted: Set<String>) -> [String: URL] {
        lock.lock()
        defer { lock.unlock() }
        if mounted == cachedFor { return cache }
        cachedFor = mounted
        cache = readHdiutil()
        return cache
    }

    static func imageFile(forMountPoint path: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return cache[URL(fileURLWithPath: path).standardizedFileURL.path]
    }

    private static func readHdiutil() -> [String: URL] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info", "-plist"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return [:] }
        var map: [String: URL] = [:]
        for image in images {
            guard let path = image["image-path"] as? String,
                  let entities = image["system-entities"] as? [[String: Any]] else { continue }
            for entity in entities {
                if let mount = entity["mount-point"] as? String {
                    map[URL(fileURLWithPath: mount).standardizedFileURL.path] = URL(fileURLWithPath: path)
                }
            }
        }
        return map
    }
}

/// The standard user folders, with Windows-style colored icons.
struct Place: Identifiable, Hashable {
    let name: String
    let symbol: String
    let color: Color
    let url: URL
    var id: URL { url }

    static let home = FileManager.default.homeDirectoryForCurrentUser.normalizedFolder

    static let standard: [Place] = {
        let fm = FileManager.default
        let wanted: [(String, String, Color, FileManager.SearchPathDirectory)] = [
            ("Desktop", "menubar.dock.rectangle", Color(hex: 0x3AB0E8), .desktopDirectory),
            ("Music", "music.note", Color(hex: 0xF0596B), .musicDirectory),
            ("Downloads", "arrow.down.to.line", Color(hex: 0x3CC8A8), .downloadsDirectory),
            ("Documents", "doc.text.fill", Color(hex: 0x9DB4CF), .documentDirectory),
            ("Pictures", "photo.fill", Color(hex: 0x4FA3F7), .picturesDirectory),
            ("Videos", "play.rectangle.fill", Color(hex: 0x9B6CF0), .moviesDirectory),
        ]
        return wanted.compactMap { name, symbol, color, dir in
            fm.urls(for: dir, in: .userDomainMask).first.map {
                Place(name: name, symbol: symbol, color: color, url: $0.normalizedFolder)
            }
        }
    }()

    static let downloads = standard.first { $0.name == "Downloads" }?.url
    static let pictures = standard.first { $0.name == "Pictures" }?.url
    static let desktop = standard.first { $0.name == "Desktop" }?.url

    static func special(for url: URL) -> Place? {
        let folder = url.normalizedFolder
        return standard.first { $0.url == folder }
    }

    static let iCloudDrive: URL? = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        return FileManager.default.fileExists(atPath: url.path) ? url.normalizedFolder : nil
    }()
}

extension URL {
    /// One consistent form for folder URLs, so the same folder always compares equal.
    var normalizedFolder: URL { URL(fileURLWithPath: standardizedFileURL.path, isDirectory: true) }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

// MARK: - Settings (View › Show and Folder Options)

enum AppTheme: String, CaseIterable, Identifiable {
    case dark, light, system
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dark: return "Dark"
        case .light: return "Light"
        case .system: return "Use system setting"
        }
    }
}

enum SidePane: String { case none, details, preview }

/// Where settings are kept. Self-test and snapshot runs get their own throwaway copy,
/// so they never change your theme, panes, Quick access or Recent folders.
enum AppDefaults {
    static let store: UserDefaults = {
        let env = ProcessInfo.processInfo.environment
        guard env["MYMAC_SELFTEST"] != nil || env["MYMAC_SNAPSHOT"] != nil else { return .standard }
        let name = "local.mymac.filemanager.devrun"
        UserDefaults.standard.removePersistentDomain(forName: name)
        return UserDefaults(suiteName: name) ?? .standard
    }()
}

@MainActor
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let defaults = AppDefaults.store

    @Published var theme: AppTheme { didSet { save(theme.rawValue, "theme"); applyAppearance() } }
    @Published var showHidden: Bool { didSet { save(showHidden, "showHidden") } }
    @Published var showExtensions: Bool { didSet { save(showExtensions, "showExtensions") } }
    @Published var showCheckboxes: Bool { didSet { save(showCheckboxes, "showCheckboxes") } }
    @Published var compact: Bool { didSet { save(compact, "compact") } }
    @Published var showNavPane: Bool { didSet { save(showNavPane, "showNavPane") } }
    @Published var sidePane: SidePane { didSet { save(sidePane.rawValue, "sidePane") } }

    private init() {
        theme = AppTheme(rawValue: defaults.string(forKey: "theme") ?? "") ?? .dark
        showHidden = defaults.bool(forKey: "showHidden")
        showExtensions = defaults.bool(forKey: "showExtensions")
        showCheckboxes = defaults.object(forKey: "showCheckboxes") as? Bool ?? true
        compact = defaults.bool(forKey: "compact")
        showNavPane = defaults.object(forKey: "showNavPane") as? Bool ?? true
        sidePane = SidePane(rawValue: defaults.string(forKey: "sidePane") ?? "") ?? .none
    }

    var colorScheme: ColorScheme? {
        switch theme {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }

    func applyAppearance() {
        switch theme {
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .system: NSApp.appearance = nil
        }
    }

    private func save(_ value: Any, _ key: String) { defaults.set(value, forKey: key) }
}

/// Quick access (pinned + recent folders) and Favorites. Shared by every tab.
@MainActor
final class PinStore: ObservableObject {
    static let shared = PinStore()

    @Published private(set) var pinned: [URL] = []
    @Published private(set) var recent: [URL] = []
    @Published private(set) var favorites: [URL] = []

    private let pinnedKey = "quickAccessPinned"
    private let recentKey = "quickAccessRecent"
    private let favoritesKey = "favorites"

    private init() {
        let defaults = AppDefaults.store
        if let saved = defaults.stringArray(forKey: pinnedKey) {
            pinned = Self.existing(saved, folders: true)
        } else {
            pinned = Place.standard.map(\.url)
        }
        recent = Self.existing(defaults.stringArray(forKey: recentKey) ?? [], folders: true)
        favorites = Self.existing(defaults.stringArray(forKey: favoritesKey) ?? [], folders: false)
    }

    private static func existing(_ paths: [String], folders: Bool) -> [URL] {
        paths.filter { FileManager.default.fileExists(atPath: $0) }
            .map { folders ? URL(fileURLWithPath: $0, isDirectory: true) : URL(fileURLWithPath: $0) }
    }

    func isPinned(_ url: URL) -> Bool { pinned.contains(url.normalizedFolder) }

    func toggle(_ url: URL) {
        let folder = url.normalizedFolder
        if let i = pinned.firstIndex(of: folder) {
            pinned.remove(at: i)
        } else {
            pinned.append(folder)
            recent.removeAll { $0 == folder }
        }
        save()
    }

    func isFavorite(_ url: URL) -> Bool { favorites.contains { $0.standardizedFileURL == url.standardizedFileURL } }

    func toggleFavorite(_ url: URL) {
        if let i = favorites.firstIndex(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
            favorites.remove(at: i)
        } else {
            favorites.append(url.standardizedFileURL)
        }
        save()
    }

    func clearHistory() {
        recent = []
        save()
    }

    func noteVisit(_ url: URL) {
        let folder = url.normalizedFolder
        guard !isPinned(folder), folder != Place.home, folder.path != "/" else { return }
        recent.removeAll { $0 == folder }
        recent.insert(folder, at: 0)
        if recent.count > 5 { recent.removeLast(recent.count - 5) }
        save()
    }

    private func save() {
        AppDefaults.store.set(pinned.map(\.path), forKey: pinnedKey)
        AppDefaults.store.set(recent.map(\.path), forKey: recentKey)
        AppDefaults.store.set(favorites.map(\.path), forKey: favoritesKey)
    }
}

final class IconCache {
    static let shared = IconCache()
    private let cache = NSCache<NSString, NSImage>()

    func icon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(image, forKey: key)
        return image
    }

    func forget(_ url: URL) { cache.removeObject(forKey: url.path as NSString) }
}

/// Picture previews for icon views, the Gallery and the Details pane.
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    func thumbnail(for url: URL, size: CGFloat) async -> NSImage? {
        let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)#\(Int(size))#\(stamp)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: size, height: size), scale: 2, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        let image = rep.nsImage
        cache.setObject(image, forKey: key)
        return image
    }
}

/// Apps that can open a file type (for "Open with"), cached per extension.
enum OpenWith {
    private static var cache: [String: [URL]] = [:]

    static func apps(for url: URL) -> [URL] {
        let key = url.pathExtension.lowercased()
        if let cached = cache[key] { return cached }
        let apps = Array(NSWorkspace.shared.urlsForApplications(toOpen: url).prefix(12))
        cache[key] = apps
        return apps
    }

    static func defaultApp(for url: URL) -> URL? { NSWorkspace.shared.urlForApplication(toOpen: url) }

    static func name(of app: URL) -> String {
        (FileManager.default.displayName(atPath: app.path) as NSString).deletingPathExtension
    }
}

/// Calls back on the main thread whenever a folder's contents change.
final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject

    init?(url: URL, onChange: @escaping @MainActor () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main
        )
        source.setEventHandler { MainActor.assumeIsolated { onChange() } }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { source.cancel() }
}
