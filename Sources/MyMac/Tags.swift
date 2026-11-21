import AppKit
import SwiftUI

/// A Finder tag (the coloured labels in Finder's sidebar). Tags live on the files themselves,
/// so Folders and Finder always show the same ones.
struct FileTag: Identifiable, Hashable {
    let name: String
    /// Finder's colour number: 0 none, 1 grey, 2 green, 3 purple, 4 blue, 5 yellow, 6 red, 7 orange.
    let colorIndex: Int
    var id: String { name }

    var color: Color? {
        switch colorIndex {
        case 1: return Color(nsColor: .systemGray)
        case 2: return Color(nsColor: .systemGreen)
        case 3: return Color(nsColor: .systemPurple)
        case 4: return Color(nsColor: .systemBlue)
        case 5: return Color(nsColor: .systemYellow)
        case 6: return Color(nsColor: .systemRed)
        case 7: return Color(nsColor: .systemOrange)
        default: return nil
        }
    }

    /// Finder's seven colour tags, in Finder's order.
    static let standard: [FileTag] = [
        FileTag(name: "Red", colorIndex: 6), FileTag(name: "Orange", colorIndex: 7),
        FileTag(name: "Yellow", colorIndex: 5), FileTag(name: "Green", colorIndex: 2),
        FileTag(name: "Blue", colorIndex: 4), FileTag(name: "Purple", colorIndex: 3),
        FileTag(name: "Grey", colorIndex: 1),
    ]
}

/// The coloured dot shown next to a tag (a hollow ring for tags without a colour).
struct TagDot: View {
    let tag: FileTag
    var size: CGFloat = 11

    var body: some View {
        Group {
            if let color = tag.color {
                Circle().fill(color)
            } else {
                Circle().strokeBorder(Theme.secondary, lineWidth: 1.3)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Every tag in use on this Mac, for the navigation pane's Tags section.
@MainActor
final class TagStore: ObservableObject {
    static let shared = TagStore()
    @Published private(set) var tags: [FileTag] = FileTag.standard
    private var loading = false

    private init() { refresh() }

    func tag(named name: String) -> FileTag {
        tags.first { $0.name == name } ?? FileTag(name: name, colorIndex: 0)
    }

    /// Shows a tag in the sidebar straight away (Spotlight takes a few seconds to notice new tags).
    func remember(_ name: String) {
        guard !tags.contains(where: { $0.name == name }) else { return }
        tags.append(FileTag(name: name, colorIndex: 0))
    }

    /// Renames a tag everywhere: on every file Spotlight finds with it (plus `extra` files, e.g.
    /// the ones on screen), keeping each file's tag colour. Returns the files that couldn't be changed.
    func rename(_ old: String, to new: String, alsoOn extra: [URL] = []) async -> [URL] {
        guard old != new, !new.isEmpty else { return [] }
        let tagged = await TagStore.files(tagged: old).map(\.url)
        let urls = Array(Set(tagged + extra.filter { TagStore.tagNames(of: $0).contains(old) }))
        let failed = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: urls.filter { !TagStore.renameOnFile($0.path, old, new) })
            }
        }
        // A renamed colour tag replaces that colour in the list (like Finder).
        var renames = Self.renames
        if let base = FileTag.standard.first(where: { (renames[$0.name] ?? $0.name) == old }) {
            renames[base.name] = new == base.name ? nil : new
            Self.renames = renames
        }
        let color = tag(named: old).colorIndex
        tags = tags.compactMap { tag in
            if tag.name == old { return FileTag(name: new, colorIndex: color) }
            if tag.name == new { return nil }   // merged into the renamed one
            return tag
        }
        if !tags.contains(where: { $0.name == new }) { tags.append(FileTag(name: new, colorIndex: color)) }
        return failed
    }

    /// Swaps one tag name for another in a file's tag list, keeping its colour and the other tags.
    nonisolated private static func renameOnFile(_ path: String, _ old: String, _ new: String) -> Bool {
        let current = tagsOnFile(atPath: path)
        guard current.contains(where: { $0.name == old }) else { return true }
        var renamed: [FileTag] = []
        for tag in current {
            let next = tag.name == old ? FileTag(name: new, colorIndex: tag.colorIndex) : tag
            if let i = renamed.firstIndex(where: { $0.name == next.name }) {
                // The file already had the new name: keep one, with a colour if either had one.
                if renamed[i].colorIndex == 0 { renamed[i] = next }
            } else {
                renamed.append(next)
            }
        }
        let entries = renamed.map { $0.colorIndex == 0 ? $0.name : "\($0.name)\n\($0.colorIndex)" }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)
        else { return false }
        let attribute = "com.apple.metadata:_kMDItemUserTags"
        return data.withUnsafeBytes { setxattr(path, attribute, $0.baseAddress, data.count, 0, 0) } == 0
    }

    /// A file's tag names, read fresh from disk.
    nonisolated static func tagNames(of url: URL) -> [String] {
        (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
    }

    /// Adds or removes one tag on each file, keeping its other tags. The same call Finder's
    /// tag menu uses, so Finder and Spotlight see the change. Returns the files that failed.
    nonisolated static func set(_ name: String, on urls: [URL], add: Bool) -> [URL] {
        var failed: [URL] = []
        for url in urls {
            var names = tagNames(of: url)
            if add {
                guard !names.contains(name) else { continue }
                names.append(name)
            } else {
                guard names.contains(name) else { continue }
                names.removeAll { $0 == name }
            }
            do { try (url as NSURL).setResourceValue(names, forKey: .tagNamesKey) } catch { failed.append(url) }
        }
        return failed
    }

    /// Finder's colour tags plus every other tag Spotlight finds on your files.
    func refresh() {
        guard !loading else { return }
        loading = true
        Task {
            let found = await TagStore.tagsInUse()
            self.tags = TagStore.merge(found)
            self.loading = false
        }
    }

    /// Colour tags renamed in Folders, e.g. ["Red": "UPSC"]; the new name takes the colour's place.
    private static let renamesKey = "tagRenames"
    private static var renames: [String: String] {
        get { AppDefaults.store.dictionary(forKey: renamesKey) as? [String: String] ?? [:] }
        set { AppDefaults.store.set(newValue, forKey: renamesKey) }
    }

    /// Colour tags first (Finder's order, renamed ones included), then your own tags A to Z.
    private static func merge(_ found: [FileTag]) -> [FileTag] {
        var byName: [String: FileTag] = [:]
        for tag in found { byName[tag.name] = tag }
        // Finder's favourite list keeps renamed colour tags (e.g. "Red" renamed "UPSC").
        let favourites = (UserDefaults(suiteName: "com.apple.finder")?.array(forKey: "FavoriteTagNames") as? [String])?
            .filter { !$0.isEmpty } ?? []
        var result: [FileTag] = []
        let renames = renames
        for standard in FileTag.standard {
            let name = renames[standard.name] ?? standard.name
            byName.removeValue(forKey: name)
            result.append(FileTag(name: name, colorIndex: standard.colorIndex))
        }
        for name in favourites where byName[name] != nil {
            result.append(byName.removeValue(forKey: name)!)
        }
        result += byName.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return result
    }

    /// Reads the tags (with colours) of tagged files that Spotlight knows about.
    nonisolated private static func tagsInUse() async -> [FileTag] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let paths = mdfind("kMDItemUserTags == *").prefix(3000)
                var tags: [String: Int] = [:]
                for path in paths {
                    for tag in tagsOnFile(atPath: path) where tags[tag.name] == nil || tags[tag.name] == 0 {
                        tags[tag.name] = tag.colorIndex
                    }
                }
                continuation.resume(returning: tags.map { FileTag(name: $0.key, colorIndex: $0.value) })
            }
        }
    }

    /// Files with this tag, found by Spotlight (like clicking a tag in Finder's sidebar).
    nonisolated static func files(tagged name: String) async -> [FileItem] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let escaped = name.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                let paths = mdfind("kMDItemUserTags == \"\(escaped)\"")
                    .filter { FileManager.default.fileExists(atPath: $0) }
                continuation.resume(returning: paths.prefix(2000).map { FileItem(url: URL(fileURLWithPath: $0)) })
            }
        }
    }

    /// A file's tags, from the same place Finder keeps them (the file's extended attributes).
    nonisolated static func tagsOnFile(atPath path: String) -> [FileTag] {
        let attribute = "com.apple.metadata:_kMDItemUserTags"
        let size = getxattr(path, attribute, nil, 0, 0, 0)
        guard size > 0 else { return [] }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, attribute, $0.baseAddress, size, 0, 0) }
        guard read == size,
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String]
        else { return [] }
        // Each entry is "Name" or "Name\nColourNumber".
        return list.compactMap { entry in
            let parts = entry.split(separator: "\n", omittingEmptySubsequences: false)
            guard let name = parts.first, !name.isEmpty else { return nil }
            let color = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            return FileTag(name: String(name), colorIndex: color)
        }
    }

    nonisolated private static func mdfind(_ query: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = [query]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "").split(separator: "\n").map(String.init)
    }
}

// MARK: - Tagging

/// Toolbar button: tick a tag to add it to the selected files, tick again to remove it.
struct TagMenuButton: View {
    @EnvironmentObject private var browser: FileBrowser
    @ObservedObject private var store = TagStore.shared
    let enabled: Bool

    var body: some View {
        DropMenu {
            Image(systemName: "tag")
                .font(.system(size: 14))
                .frame(width: 38, height: 34)
        } content: { close in
            let urls = browser.selection
            ForEach(store.tags) { tag in
                MenuRow(title: tag.name, icon: AnyView(TagDot(tag: tag)),
                        mark: browser.allHave(tag: tag.name, urls) ? .check : .none) {
                    close(); browser.toggleTag(tag.name, on: urls)
                }
            }
            MenuSeparator()
            MenuRow(title: "New tag…", symbol: "plus") {
                close(); browser.addNewTag(to: urls)
            }
        }
        .disabled(!enabled)
        .help("Tags")
    }
}

/// Small tag dots after a file's name, like Finder.
struct TagDots: View {
    let names: [String]
    @ObservedObject private var store = TagStore.shared

    var body: some View {
        HStack(spacing: 2) {
            ForEach(names.prefix(3), id: \.self) { name in
                TagDot(tag: store.tag(named: name), size: 8)
            }
        }
        .help(names.joined(separator: ", "))
    }
}

/// A coloured dot as an image, for the right-click menu.
enum TagImages {
    @MainActor static func dot(_ tag: FileTag) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        return NSImage(size: size, flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            if let color = tag.color {
                NSColor(color).setFill()
                circle.fill()
            } else {
                NSColor.secondaryLabelColor.setStroke()
                circle.lineWidth = 1.2
                circle.stroke()
            }
            return true
        }
    }
}

// MARK: - Pages

/// "All Tags…": every tag, like Finder's list. Click one to see its files.
struct AllTagsView: View {
    @EnvironmentObject private var browser: FileBrowser
    @ObservedObject private var store = TagStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(store.tags.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { tag in
                    TagListRow(tag: tag) { browser.go(to: .tag(tag.name)) }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.content)
    }
}

private struct TagListRow: View {
    let tag: FileTag
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            TagDot(tag: tag, size: 12)
            Text(tag.name).font(.system(size: 13)).foregroundStyle(Theme.text)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(width: 320, height: 30)
        .background(RoundedRectangle(cornerRadius: 4).fill(hovering ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }
}

/// Files with one tag, shown in the current view mode, with a Folder column saying where each is.
struct TagContentView: View {
    @EnvironmentObject private var browser: FileBrowser

    var body: some View {
        switch browser.viewMode {
        case .details: DetailsListView()
        case .list: ListModeView()
        case .tiles, .content: RowsGridView(mode: browser.viewMode)
        default: IconGridView(mode: browser.viewMode)
        }
    }
}
