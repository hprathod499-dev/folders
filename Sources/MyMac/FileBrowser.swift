import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

enum ViewMode: String, CaseIterable, Identifiable {
    case extraLargeIcons, largeIcons, mediumIcons, smallIcons, list, details, tiles, content
    var id: String { rawValue }

    var title: String {
        switch self {
        case .extraLargeIcons: return "Extra large icons"
        case .largeIcons: return "Large icons"
        case .mediumIcons: return "Medium icons"
        case .smallIcons: return "Small icons"
        case .list: return "List"
        case .details: return "Details"
        case .tiles: return "Tiles"
        case .content: return "Content"
        }
    }

    var symbol: String {
        switch self {
        case .extraLargeIcons: return "square"
        case .largeIcons: return "square.grid.2x2"
        case .mediumIcons: return "square.grid.3x2"
        case .smallIcons: return "square.grid.3x3"
        case .list: return "list.dash"
        case .details: return "list.bullet"
        case .tiles: return "rectangle.grid.1x2"
        case .content: return "list.bullet.below.rectangle"
        }
    }
}

enum SortField: String, CaseIterable, Identifiable {
    case name, date, type, size, created
    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "Name"
        case .date: return "Date modified"
        case .type: return "Type"
        case .size: return "Size"
        case .created: return "Date created"
        }
    }
}

enum GroupField: String, CaseIterable, Identifiable {
    case none, name, date, type, size
    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "(None)"
        case .name: return "Name"
        case .date: return "Date modified"
        case .type: return "Type"
        case .size: return "Size"
        }
    }
}

enum Location: Hashable {
    case home
    case gallery
    case thisMac
    case folder(URL)

    var normalized: Location {
        if case .folder(let url) = self { return .folder(url.normalizedFolder) }
        return self
    }
}

enum FocusRequest: Equatable { case search, address }

struct Crumb {
    let name: String
    let location: Location
}

struct ItemSection: Identifiable {
    let id: String
    let title: String?
    let items: [FileItem]
}

struct PropertiesTarget: Identifiable {
    let id = UUID()
    let urls: [URL]
}

/// One tab's browsing state and all file operations.
@MainActor
final class FileBrowser: ObservableObject, Identifiable {
    let id = UUID()
    private let prefs = Prefs.shared
    private let ops = FileOps.shared

    @Published private(set) var location: Location = .home
    @Published private(set) var items: [FileItem] = []
    @Published private(set) var recentItems: [FileItem] = []
    @Published private(set) var favoriteItems: [FileItem] = []
    @Published private(set) var galleryItems: [FileItem] = []
    @Published private(set) var isLoadingGallery = false
    @Published private(set) var searchResults: [FileItem]?
    @Published private(set) var isSearching = false
    @Published private(set) var volumes: [VolumeInfo] = []
    @Published private(set) var cutPaths: Set<String> = []

    @Published var selection = Set<URL>()
    @Published var searchText = ""
    @Published var viewMode: ViewMode = .details
    @Published var sortField: SortField = .name
    @Published var sortAscending = true
    @Published var groupBy: GroupField = .none
    @Published var collapsedGroups = Set<String>()

    @Published var renamingURL: URL?
    @Published var renameText = ""
    @Published var propertiesTarget: PropertiesTarget?
    @Published var confirmPermanentDelete: [URL]?
    @Published var focusRequest: FocusRequest?

    private var anchor: URL?
    private var cutChangeCount = -1
    private var backStack: [Location] = []
    private var forwardStack: [Location] = []
    private var watcher: DirectoryWatcher?
    private var searchTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var subscriptions: [AnyCancellable] = []

    init(start: Location = .home) {
        volumes = VolumeInfo.all()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.volumes = VolumeInfo.all()
                    if self?.location == .thisMac { self?.reload() }
                }
            })
        }
        prefs.$showHidden.dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.reload() } }
            .store(in: &subscriptions)
        // Keep the Space-bar preview in step with the selection (arrow keys while it's open).
        $selection.dropFirst()
            .sink { [weak self] selection in
                DispatchQueue.main.async {
                    guard let self else { return }
                    QuickLook.shared.update(self.orderedURLs.filter(selection.contains), from: self)
                }
            }
            .store(in: &subscriptions)
                PinStore.shared.$favorites.dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { if self?.location == .home { self?.reload() } } }
            .store(in: &subscriptions)
        show(start.normalized)
    }

    deinit {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    // MARK: - Derived state

    var currentURL: URL? {
        if case .folder(let url) = location { return url }
        return nil
    }

    var title: String {
        switch location {
        case .home: return "Home"
        case .gallery: return "Gallery"
        case .thisMac: return "This Mac"
        case .folder(let url):
            if let place = Place.special(for: url) { return place.name }
            if let volume = volumes.first(where: { $0.url == url.normalizedFolder }) { return volume.displayName }
            return FileManager.default.displayName(atPath: url.path)
        }
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { currentURL != nil }
    var searchQuery: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isSearchResults: Bool { searchResults != nil }

    private var baseItems: [FileItem] {
        switch location {
        case .home: return recentItems
        case .gallery: return galleryItems
        case .thisMac: return searchResults ?? []
        case .folder: return searchResults ?? items
        }
    }

    /// Items after search filtering and sorting.
    var sortedItems: [FileItem] {
        var source = baseItems
        if searchResults == nil, !searchQuery.isEmpty {
            source = source.filter { $0.name.localizedCaseInsensitiveContains(searchQuery) }
        }
        if location == .home || location == .gallery {
            return source.sorted { $0.modified > $1.modified }
        }
        return source.sorted(by: areInOrder)
    }

    var sections: [ItemSection] {
        let sorted = sortedItems
        guard groupBy != .none, currentURL != nil else { return [ItemSection(id: "all", title: nil, items: sorted)] }
        var buckets: [String: [FileItem]] = [:]
        var rank: [String: Int] = [:]
        let now = Date()
        for item in sorted {
            let info = groupInfo(item, now: now)
            buckets[info.title, default: []].append(item)
            rank[info.title] = info.rank
        }
        var titles = buckets.keys.sorted {
            (rank[$0] ?? 0, $0.localizedLowercase) < (rank[$1] ?? 0, $1.localizedLowercase)
        }
        let reverse: Bool
        switch groupBy {
        case .date: reverse = sortField == .date && sortAscending
        case .name: reverse = sortField == .name && !sortAscending
        case .type: reverse = sortField == .type && !sortAscending
        case .size: reverse = sortField == .size && !sortAscending
        case .none: reverse = false
        }
        if reverse { titles.reverse() }
        return titles.map { ItemSection(id: $0, title: $0, items: buckets[$0] ?? []) }
    }

    private func groupInfo(_ item: FileItem, now: Date) -> (rank: Int, title: String) {
        switch groupBy {
        case .none:
            return (0, "")
        case .date:
            let group = DateGroup.of(item.modified, now: now)
            return (group.rawValue, group.title)
        case .type:
            return (0, item.typeText)
        case .name:
            guard let first = item.name.uppercased().first else { return (5, "Other") }
            if first.isNumber { return (0, "0 - 9") }
            if ("A"..."H").contains(String(first)) { return (1, "A - H") }
            if ("I"..."P").contains(String(first)) { return (2, "I - P") }
            if ("Q"..."Z").contains(String(first)) { return (3, "Q - Z") }
            return (4, "Other")
        case .size:
            if item.size < 0 { return (8, "Unspecified") }
            let kb: Int64 = 1024, mb = kb * 1024, gb = mb * 1024
            switch item.size {
            case 0: return (0, "Empty (0 KB)")
            case ..<(16 * kb): return (1, "Tiny (0 - 16 KB)")
            case ..<mb: return (2, "Small (16 KB - 1 MB)")
            case ..<(128 * mb): return (3, "Medium (1 - 128 MB)")
            case ..<gb: return (4, "Large (128 MB - 1 GB)")
            case ..<(4 * gb): return (5, "Huge (1 - 4 GB)")
            default: return (6, "Gigantic (> 4 GB)")
            }
        }
    }

    /// Visible items in on-screen order (collapsed groups left out); used for ⇧-click and arrow keys.
    var orderedURLs: [URL] {
        sections.flatMap { collapsedGroups.contains($0.id) ? [] : $0.items.map(\.url) }
    }

    var visibleCount: Int { sortedItems.count }
    var selectedItems: [FileItem] { sortedItems.filter { selection.contains($0.url) } }

    var breadcrumbs: [Crumb] {
        guard let url = currentURL else { return [Crumb(name: title, location: location)] }
        let path = url.standardizedFileURL.path
        var crumbs: [Crumb] = []
        var root: URL
        if let place = Place.standard.first(where: { path == $0.url.path || path.hasPrefix($0.url.path + "/") }) {
            root = place.url
            crumbs.append(Crumb(name: place.name, location: .folder(place.url)))
        } else if let cloud = Place.iCloudDrive, path == cloud.path || path.hasPrefix(cloud.path + "/") {
            root = cloud
            crumbs.append(Crumb(name: "iCloud Drive", location: .folder(cloud)))
        } else {
            let volume = volumes
                .filter { $0.url.path == "/" || path == $0.url.path || path.hasPrefix($0.url.path + "/") }
                .max { $0.url.path.count < $1.url.path.count }
            root = volume?.url ?? URL(fileURLWithPath: "/")
            crumbs.append(Crumb(name: "This Mac", location: .thisMac))
            if let volume, volume.isDiskImage {
                // This PC › Macintosh HD (C:) › Claude
                let system = volumes.first(where: \.isInternal)
                let systemRoot = URL(fileURLWithPath: "/").normalizedFolder
                crumbs.append(Crumb(name: system?.displayName ?? "Macintosh HD", location: .folder(systemRoot)))
                crumbs.append(Crumb(name: volume.name, location: .folder(root)))
            } else {
                crumbs.append(Crumb(name: volume?.displayName ?? "Macintosh HD", location: .folder(root)))
            }
        }
        let rootPath = root.standardizedFileURL.path
        let rest = String(path.dropFirst(rootPath == "/" ? 0 : rootPath.count)).split(separator: "/").map(String.init)
        var current = root
        for part in rest {
            current = current.appendingPathComponent(part)
            crumbs.append(Crumb(name: part, location: .folder(current)))
        }
        return crumbs
    }

    var subfolders: [FileItem] {
        items.filter(\.isDirectory).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func item(for url: URL) -> FileItem {
        (baseItems + favoriteItems).first { $0.url == url } ?? FileItem(url: url)
    }

    func isCut(_ url: URL) -> Bool {
        !cutPaths.isEmpty && FileBrowser.pasteboard.changeCount == cutChangeCount
            && cutPaths.contains(url.standardizedFileURL.path)
    }

    /// The clipboard used for Cut/Copy/Paste. The self-test swaps in a private one.
    static var pasteboard: NSPasteboard = .general

    /// Files on the clipboard that still exist (anything deleted since it was copied is ignored).
    func clipboardFiles() -> [URL] {
        let urls = FileBrowser.pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func canPaste() -> Bool {
        currentURL != nil && !clipboardFiles().isEmpty
    }

    func isVolume(_ url: URL) -> Bool { volumes.contains { $0.url == url.normalizedFolder } }

    private func areInOrder(_ a: FileItem, _ b: FileItem) -> Bool {
        if sortField != .date, sortField != .created, a.isDirectory != b.isDirectory { return a.isDirectory }
        let result: ComparisonResult
        switch sortField {
        case .name: result = a.name.localizedStandardCompare(b.name)
        case .type: result = a.typeText.localizedStandardCompare(b.typeText)
        case .date: result = Self.compare(a.modified, b.modified)
        case .created: result = Self.compare(a.created ?? .distantPast, b.created ?? .distantPast)
        case .size: result = Self.compare(a.size, b.size)
        }
        if result == .orderedSame { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
        return sortAscending ? result == .orderedAscending : result == .orderedDescending
    }

    private static func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
    }

    func sort(by field: SortField) {
        if sortField == field {
            sortAscending.toggle()
        } else {
            sortField = field
            sortAscending = field == .name || field == .type
        }
    }

    // MARK: - Navigation

    func go(to newLocation: Location) {
        let target = newLocation.normalized
        guard target != location else { return }
        backStack.append(location)
        forwardStack.removeAll()
        show(target)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(location)
        show(previous)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(location)
        show(next)
    }

    func goUp() {
        guard let url = currentURL else { return }
        if let volume = volumes.first(where: { $0.url == url.normalizedFolder }) {
            // A disk image's parent is Macintosh HD; a real drive's parent is This PC.
            go(to: volume.isDiskImage ? .folder(URL(fileURLWithPath: "/")) : .thisMac)
            return
        }
        go(to: .folder(url.deletingLastPathComponent()))
    }

    func goTo(path text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch trimmed.lowercased() {
        case "home": go(to: .home); return
        case "gallery": go(to: .gallery); return
        case "this pc", "this mac", "my computer", "computer": go(to: .thisMac); return
        case "recycle bin", "trash", "bin":
            NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash")); return
        default: break
        }
        if let place = Place.standard.first(where: { $0.name.lowercased() == trimmed.lowercased() }) {
            go(to: .folder(place.url)); return
        }
        guard let path = Self.resolve(addressText: trimmed, volumes: volumes) else {
            ops.errorMessage = "Can't find '\(trimmed)'. Check the spelling and try again."
            return
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            ops.errorMessage = "Can't find '\(trimmed)'. Check the spelling and try again."
            return
        }
        let url = URL(fileURLWithPath: path)
        if isDir.boolValue && !(FileBrowser.isPackage(url)) {
            go(to: .folder(url))
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Turns what was typed in the address bar into a Mac path. Understands Windows forms too:
    /// "C:", "C:\\", "C:\\Users\\me", "D:\\Photos", "Downloads\\Work", "~/Desktop".
    static func resolve(addressText text: String, volumes: [VolumeInfo]) -> String? {
        var t = text.replacingOccurrences(of: "\\", with: "/")
        let chars = Array(t)
        if chars.count >= 2, chars[0].isLetter, chars[1] == ":", chars.count == 2 || chars[2] == "/" {
            let letter = String(chars[0...1]).uppercased()
            guard let volume = volumes.first(where: { $0.letter == letter }) else { return nil }
            let rest = String(t.dropFirst(2)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            t = rest.isEmpty ? volume.url.path : volume.url.appendingPathComponent(rest).path
        } else if let place = Place.standard.first(where: { t.lowercased().hasPrefix($0.name.lowercased() + "/") }) {
            t = place.url.appendingPathComponent(String(t.dropFirst(place.name.count + 1))).path
        }
        let path = (t as NSString).expandingTildeInPath
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    private func show(_ newLocation: Location) {
        location = newLocation
        selection = []
        anchor = nil
        renamingURL = nil
        collapsedGroups = []
        searchTask?.cancel()
        searchResults = nil
        isSearching = false
        if !searchText.isEmpty { searchText = "" }
        if let url = currentURL {
            if url == Place.downloads {
                groupBy = .date
                sortField = .date
                sortAscending = false
            } else {
                groupBy = .none
                if sortField == .date || sortField == .created { sortField = .name; sortAscending = true }
            }
            PinStore.shared.noteVisit(url)
        }
        watcher = currentURL.flatMap { url in
            DirectoryWatcher(url: url) { [weak self] in self?.reload() }
        }
        reload()
    }

    func reload() {
        loadTask?.cancel()
        switch location {
        case .thisMac:
            volumes = VolumeInfo.all()
            items = []
        case .home:
            items = []
            favoriteItems = PinStore.shared.favorites.map(FileItem.init(url:))
            loadTask = Task { [weak self] in
                let recent = await FileBrowser.loadRecent()
                guard !Task.isCancelled else { return }
                self?.recentItems = recent
            }
        case .gallery:
            items = []
            guard let pictures = Place.pictures else { return }
            isLoadingGallery = galleryItems.isEmpty
            loadTask = Task { [weak self] in
                let photos = await FileBrowser.loadImages(in: pictures)
                guard !Task.isCancelled else { return }
                self?.galleryItems = photos
                self?.isLoadingGallery = false
            }
        case .folder(let url):
            var options: FileManager.DirectoryEnumerationOptions = []
            if !prefs.showHidden { options.insert(.skipsHiddenFiles) }
            do {
                let urls = try FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: FileItem.resourceKeys, options: options)
                items = urls.map(FileItem.init(url:))
                // Disk images opened from files on this drive appear inside Macintosh HD (C:).
                if url.path == "/" {
                    items += volumes.filter(\.isDiskImage).map { FileItem(url: $0.url) }
                }
            } catch {
                items = []
                ops.errorMessage = "\(url.path) is unavailable. \(error.localizedDescription)"
            }
            if searchResults == nil {
                let valid = Set(items.map(\.url))
                selection = selection.intersection(valid)
            }
            if !searchQuery.isEmpty { updateSearch() }
        }
    }

    nonisolated static func loadRecent() async -> [FileItem] {
        let fm = FileManager.default
        let dirs: [FileManager.SearchPathDirectory] = [.desktopDirectory, .documentDirectory, .downloadsDirectory]
        var all: [FileItem] = []
        for d in dirs {
            guard let dir = fm.urls(for: d, in: .userDomainMask).first,
                  let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: FileItem.resourceKeys,
                                                         options: [.skipsHiddenFiles]) else { continue }
            all += urls.map(FileItem.init(url:)).filter { !$0.isDirectory }
        }
        return Array(all.sorted { $0.modified > $1.modified }.prefix(30))
    }

    nonisolated static func loadImages(in root: URL) async -> [FileItem] {
        loadImagesSync(in: root)
    }

    nonisolated private static func loadImagesSync(in root: URL) -> [FileItem] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: FileItem.resourceKeys + [.contentTypeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }
        ) else { return [] }
        var results: [FileItem] = []
        while let next = enumerator.nextObject() as? URL {
            if Task.isCancelled || results.count >= 2000 { break }
            if let type = (try? next.resourceValues(forKeys: [.contentTypeKey]))?.contentType,
               type.conforms(to: .image) || type.conforms(to: .movie) {
                results.append(FileItem(url: next))
            }
        }
        return results.sorted { $0.modified > $1.modified }
    }

    // MARK: - Search (current folder and all subfolders)

    func updateSearch() {
        searchTask?.cancel()
        let query = searchQuery
        // "Search This PC": the whole Mac, using the Spotlight index (fast, like Windows search).
        if location == .thisMac {
            guard !query.isEmpty else {
                searchResults = nil
                isSearching = false
                return
            }
            isSearching = true
            let includeHidden = prefs.showHidden
            searchTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                let results = await FileBrowser.spotlightSearch(query, includeHidden: includeHidden)
                guard !Task.isCancelled, let self else { return }
                self.searchResults = results
                self.isSearching = false
                self.selection = []
            }
            return
        }
        guard !query.isEmpty, let root = currentURL else {
            searchResults = nil
            isSearching = false
            return
        }
        isSearching = true
        let includeHidden = prefs.showHidden
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let results = await FileBrowser.search(in: root, matching: query, includeHidden: includeHidden)
            guard !Task.isCancelled, let self else { return }
            self.searchResults = results
            self.isSearching = false
            self.selection = self.selection.intersection(Set(results.map(\.url)))
        }
    }

    /// Searches every indexed file on the Mac by name with `mdfind` (Spotlight). Up to 500 results.
    nonisolated static func spotlightSearch(_ query: String, includeHidden: Bool) async -> [FileItem] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
                process.arguments = ["-name", query]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(returning: [])
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                let paths = (String(data: data, encoding: .utf8) ?? "")
                    .split(separator: "\n").map(String.init)
                    // Like Windows hiding AppData: skip hidden and system/app-data folders unless
                    // "Hidden items" is on.
                    .filter { path in
                        includeHidden || !(path.contains("/.") || path.hasPrefix(home + "/Library/")
                            || path.hasPrefix("/System/") || path.hasPrefix("/private/")
                            || path.hasPrefix("/Library/") || path.contains(".app/"))
                    }
                    // Put the user's own files first, like Windows does.
                    .sorted { ($0.hasPrefix(home) ? 0 : 1, $0.count) < ($1.hasPrefix(home) ? 0 : 1, $1.count) }
                continuation.resume(returning: paths.prefix(500).map { FileItem(url: URL(fileURLWithPath: $0)) })
            }
        }
    }

    nonisolated static func search(in root: URL, matching query: String, includeHidden: Bool) async -> [FileItem] {
        searchSync(in: root, matching: query, includeHidden: includeHidden)
    }

    nonisolated private static func searchSync(in root: URL, matching query: String, includeHidden: Bool) -> [FileItem] {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !includeHidden { options.insert(.skipsHiddenFiles) }
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: FileItem.resourceKeys, options: options,
            errorHandler: { _, _ in true }
        ) else { return [] }
        var results: [FileItem] = []
        while let next = enumerator.nextObject() as? URL {
            if Task.isCancelled || results.count >= 1000 { break }
            if next.lastPathComponent.localizedCaseInsensitiveContains(query) {
                results.append(FileItem(url: next))
            }
        }
        return results
    }

    // MARK: - Selection

    /// Click handling like Explorer: plain click selects one, ⌘ (Ctrl) toggles, ⇧ selects a range.
    func click(_ url: URL) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) || flags.contains(.control) {
            toggleSelection(url)
        } else if flags.contains(.shift), let anchor {
            let order = orderedURLs
            if let i = order.firstIndex(of: anchor), let j = order.firstIndex(of: url) {
                selection = Set(order[min(i, j)...max(i, j)])
            }
        } else {
            selection = [url]
            anchor = url
        }
    }

    /// Right-clicking an unselected item selects just that item, like Windows.
    func prepareContextMenu(for url: URL) {
        if !selection.contains(url) {
            selection = [url]
            anchor = url
        }
    }

    func toggleSelection(_ url: URL) {
        if selection.contains(url) { selection.remove(url) } else { selection.insert(url) }
        anchor = url
    }

    func moveSelection(by offset: Int, extend: Bool = false) {
        let order = orderedURLs
        guard !order.isEmpty else { return }
        let current = anchor.flatMap { order.firstIndex(of: $0) } ?? (offset > 0 ? -1 : order.count)
        let next = min(max(current + offset, 0), order.count - 1)
        if extend { selection.insert(order[next]) } else { selection = [order[next]] }
        anchor = order[next]
    }

    func selectEdge(last: Bool) {
        let order = orderedURLs
        guard let target = last ? order.last : order.first else { return }
        selection = [target]
        anchor = target
    }

    /// Typing letters jumps to the first matching name, like Explorer.
    func jump(to prefix: String) {
        let match = sortedItems.first { $0.name.lowercased().hasPrefix(prefix.lowercased()) }
        if let match {
            selection = [match.url]
            anchor = match.url
        }
    }

    func selectAll() { selection = Set(orderedURLs) }
    func selectNone() { selection = [] }
    func invertSelection() { selection = Set(orderedURLs).subtracting(selection) }

    func select(paths: [String]) {
        let wanted = Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        selection = Set(sortedItems.filter { wanted.contains($0.url.standardizedFileURL.path) }.map(\.url))
        anchor = selection.first
    }

    // MARK: - File operations

    func open(_ urls: Set<URL>) {
        let list = Array(urls)
        if list.count == 1, Self.isFolder(list[0]) {
            go(to: .folder(list[0]))
            return
        }
        for url in list {
            if Self.isFolder(url) { AppState.shared.newTab(.folder(url)) } else { NSWorkspace.shared.open(url) }
        }
    }

    func openSelection() { open(selection) }

    func open(_ urls: Set<URL>, with app: URL) {
        NSWorkspace.shared.open(Array(urls), withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    func chooseAppToOpen(_ urls: Set<URL>) {
        let panel = NSOpenPanel()
        panel.title = "How do you want to open this file?"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Open"
        if panel.runModal() == .OK, let app = panel.url { open(urls, with: app) }
    }

    enum NewKind { case folder, text, richText, zip }

    func create(_ kind: NewKind) {
        guard let dir = currentURL else { return }
        let name: String
        var data = Data()
        switch kind {
        case .folder: name = "New folder"
        case .text: name = "New Text Document.txt"
        case .richText:
            name = "New Rich Text Document.rtf"
            data = Data("{\\rtf1\\ansi\\deff0 }".utf8)
        case .zip:
            name = "New Compressed (zipped) Folder.zip"
            data = Data([0x50, 0x4B, 0x05, 0x06] + Array(repeating: 0, count: 18))
        }
        let url = FileOps.uniqueURL(in: dir, name: name)
        do {
            if kind == .folder {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            } else {
                try data.write(to: url)
            }
            ops.record(.create([url], what: kind == .folder ? "New Folder" : "New"))
            reload()
            select(paths: [url.path])
            if let match = selection.first { beginRename(match) }
        } catch {
            ops.errorMessage = error.localizedDescription
        }
    }

    func newFolder() { create(.folder) }
    func newTextDocument() { create(.text) }

    func beginRename(_ url: URL) {
        renameText = item(for: url).displayName(showExtensions: prefs.showExtensions)
        selection = [url]
        renamingURL = url
    }

    func cancelRename() { renamingURL = nil }

    func commitRename() {
        guard let url = renamingURL else { return }
        renamingURL = nil
        rename(url, to: renameText, keepHiddenExtension: true)
    }

    func rename(_ url: URL, to text: String, keepHiddenExtension: Bool) {
        let item = item(for: url)
        var name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if keepHiddenExtension, !prefs.showExtensions, !item.isDirectory, !item.ext.isEmpty { name += "." + item.ext }
        guard name != item.name else { return }
        if name.contains("/") || name.contains(":") {
            ops.errorMessage = "A file name can't contain any of the following characters:\n/ :"
            return
        }
        let dest = url.deletingLastPathComponent().appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path), !FileOps.sameFile(dest, url) {
            ops.errorMessage = "There is already a file with the same name in this location."
            return
        }
        do {
            try FileOps.moveRenaming(url, to: dest)
            ops.record(.rename(from: url, to: dest))
            reload()
            select(paths: [dest.path])
        } catch {
            ops.errorMessage = error.localizedDescription
        }
    }

    /// Delete key: to the Trash (Recycle Bin), no question asked — undo with ⌘Z.
    func trash(_ urls: Set<URL>) {
        guard !urls.isEmpty else { return }
        ops.trash(Array(urls))
        selection = []
        reload()
    }

    /// Shift+Delete: asks first, then deletes for good.
    func requestPermanentDelete(_ urls: Set<URL>) {
        guard !urls.isEmpty else { return }
        confirmPermanentDelete = Array(urls)
    }

    func performPermanentDelete() {
        guard let urls = confirmPermanentDelete else { return }
        confirmPermanentDelete = nil
        ops.deletePermanently(urls)
        selection = []
        reload()
    }

    func copy(_ urls: Set<URL>, cut: Bool = false) {
        guard !urls.isEmpty else { return }
        let pasteboard = FileBrowser.pasteboard
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        cutPaths = cut ? Set(urls.map { $0.standardizedFileURL.path }) : []
        cutChangeCount = pasteboard.changeCount
        objectWillChange.send()
    }

    func paste() {
        guard let dir = currentURL else { return }
        let pasteboard = FileBrowser.pasteboard
        let sources = clipboardFiles()
        guard !sources.isEmpty else { return }
        let move = !cutPaths.isEmpty && pasteboard.changeCount == cutChangeCount
        Task {
            let created = await ops.transfer(sources, into: dir, move: move)
            if move, !created.isEmpty {
                cutPaths = []
                pasteboard.clearContents()
            }
            reload()
            select(paths: created.map(\.path))
        }
    }

    /// Files dropped from Finder or this app. Same drive moves, another drive copies (⌥ always copies).
    func drop(_ urls: [URL], into dir: URL) -> Bool {
        let target = dir.standardizedFileURL.path
        let fileURLs = urls.filter { $0.isFileURL && $0.standardizedFileURL.path != target }
        guard !fileURLs.isEmpty else { return false }
        let forceCopy = NSEvent.modifierFlags.contains(.option)
        let dirVolume = FileOps.volumeID(dir)
        let sameVolume = fileURLs.allSatisfy { FileOps.volumeID($0) == dirVolume }
        Task {
            let created = await ops.transfer(fileURLs, into: dir, move: sameVolume && !forceCopy)
            reload()
            if dir.normalizedFolder == currentURL { select(paths: created.map(\.path)) }
        }
        return true
    }

    func compress(_ urls: Set<URL>) {
        let list = sortedItems.map(\.url).filter { urls.contains($0) }
        Task {
            guard let zip = await ops.compress(list.isEmpty ? Array(urls) : list) else { return }
            reload()
            select(paths: [zip.path])
            if let match = selection.first { beginRename(match) }
        }
    }

    func extract(_ zip: URL) {
        Task {
            guard let folder = await ops.extract(zip) else { return }
            reload()
            go(to: .folder(folder))
        }
    }

    func rotate(_ urls: Set<URL>, clockwise: Bool) {
        ops.rotate(Array(urls), clockwise: clockwise)
        urls.forEach(IconCache.shared.forget)
        reload()
    }

    func setAsDesktopBackground(_ url: URL) {
        for screen in NSScreen.screens {
            do { try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:]) }
            catch { ops.errorMessage = error.localizedDescription }
        }
    }

    func eject(_ url: URL) {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            if let current = currentURL, current.path.hasPrefix(url.path) { go(to: .thisMac) }
        } catch {
            ops.errorMessage = "Problem Ejecting \(FileManager.default.displayName(atPath: url.path)): \(error.localizedDescription)"
        }
    }

    func revealInFinder(_ urls: Set<URL>) {
        NSWorkspace.shared.activateFileViewerSelecting(Array(urls))
    }

    func copyPath(_ urls: Set<URL>) {
        let pasteboard = FileBrowser.pasteboard
        pasteboard.clearContents()
        pasteboard.setString(urls.map { "\"\($0.standardizedFileURL.path)\"" }.sorted().joined(separator: "\n"),
                             forType: .string)
    }

    func openInTerminal(_ url: URL) {
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    func showProperties(_ urls: Set<URL>) {
        let list = urls.isEmpty ? (currentURL.map { [$0] } ?? []) : Array(urls)
        guard !list.isEmpty else { return }
        propertiesTarget = PropertiesTarget(urls: list)
    }

    func undo() {
        ops.undo()
        reload()
    }

    // MARK: - Helpers

    nonisolated static func isFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
    }

    nonisolated static func isPackage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
    }
}

/// All open tabs.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published private(set) var tabs: [FileBrowser]
    @Published private(set) var selectedID: UUID
    private var cancellable: AnyCancellable?

    private init() {
        let first = FileBrowser()
        tabs = [first]
        selectedID = first.id
        observeCurrent()
    }

    var current: FileBrowser { tabs.first { $0.id == selectedID } ?? tabs[0] }

    func newTab(_ location: Location = .home) {
        let tab = FileBrowser(start: location)
        if let i = tabs.firstIndex(where: { $0.id == selectedID }) {
            tabs.insert(tab, at: i + 1)
        } else {
            tabs.append(tab)
        }
        select(tab)
    }

    func duplicate(_ tab: FileBrowser) {
        let copy = FileBrowser(start: tab.location)
        copy.viewMode = tab.viewMode
        if let i = tabs.firstIndex(where: { $0.id == tab.id }) { tabs.insert(copy, at: i + 1) } else { tabs.append(copy) }
        select(copy)
    }

    func select(_ tab: FileBrowser) {
        selectedID = tab.id
        observeCurrent()
    }

    func close(_ tab: FileBrowser) {
        guard tabs.count > 1 else {
            NSApp.keyWindow?.performClose(nil)
            return
        }
        guard let i = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: i)
        if tab.id == selectedID { select(tabs[min(i, tabs.count - 1)]) }
    }

    func closeOthers(_ tab: FileBrowser) {
        tabs = [tab]
        select(tab)
    }

    func closeToTheRight(_ tab: FileBrowser) {
        guard let i = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs = Array(tabs.prefix(i + 1))
        if !tabs.contains(where: { $0.id == selectedID }) { select(tab) }
    }

    func closeCurrent() { close(current) }

    func selectNext(_ offset: Int) {
        guard let i = tabs.firstIndex(where: { $0.id == selectedID }) else { return }
        select(tabs[(i + offset + tabs.count) % tabs.count])
    }

    func select(index: Int) {
        guard !tabs.isEmpty else { return }
        select(tabs[min(index, tabs.count - 1)])
    }

    /// Re-publish the current tab's changes so menus stay up to date.
    private func observeCurrent() {
        cancellable = current.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
}
