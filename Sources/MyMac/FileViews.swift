import AppKit
import Quartz
import SwiftUI

// MARK: - Navigation pane

struct SidebarView: View {
    @EnvironmentObject private var browser: FileBrowser
    @ObservedObject private var pins = PinStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                SidebarRow(title: "Home", icon: AnyView(LocationIcon(location: .home)), location: .home)
                SidebarRow(title: "Gallery", icon: AnyView(LocationIcon(location: .gallery)), location: .gallery)
                if let cloud = Place.iCloudDrive {
                    TreeNode(url: cloud, title: "iCloud Drive", depth: 0, startExpanded: true)
                } else {
                    TreeNode(url: Place.home, title: "\(NSUserName()) - Personal", depth: 0, startExpanded: true)
                }

                SidebarDivider()

                ForEach(pins.pinned, id: \.self) { url in
                    SidebarRow(title: displayName(url), icon: AnyView(FolderGlyph(url: url)),
                               location: .folder(url), folderURL: url, pinned: true)
                }
                ForEach(pins.recent, id: \.self) { url in
                    SidebarRow(title: displayName(url), icon: AnyView(FolderGlyph(url: url)),
                               location: .folder(url), folderURL: url)
                }

                SidebarDivider()

                ThisPCNode()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
        }
        .background(Theme.content)
    }

    private func displayName(_ url: URL) -> String {
        Place.special(for: url)?.name ?? FileManager.default.displayName(atPath: url.path)
    }
}

struct SidebarDivider: View {
    var body: some View {
        Rectangle().fill(Theme.divider).frame(height: 1).padding(.horizontal, 10).padding(.vertical, 10)
    }
}

struct SidebarRow: View {
    @EnvironmentObject private var browser: FileBrowser
    let title: String
    let icon: AnyView
    let location: Location
    var folderURL: URL?
    var depth = 0
    var pinned = false
    var expandable = false
    var expanded = false
    var onToggle: (() -> Void)?
    @State private var hovering = false
    @State private var dropTarget = false

    private var selected: Bool { browser.location == location.normalized }

    var body: some View {
        HStack(spacing: 6) {
            if expandable {
                Button { onToggle?() } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 16, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 16)
            }
            icon.frame(width: 18, height: 18)
            Text(title)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 2)
            if pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .rotationEffect(.degrees(45))
                    .foregroundStyle(Theme.secondary)
                    .padding(.trailing, 6)
            }
        }
        .padding(.leading, CGFloat(depth) * 14 + 2)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(dropTarget ? Theme.accent.opacity(0.25)
                      : selected ? (hovering ? Theme.selectedHover : Theme.selected)
                      : (hovering ? Theme.hover : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { browser.go(to: location) }
        .help(title)
        .winContextMenu { () -> Menus.Built in
            if let url = folderURL { return Menus.folderLink(browser, url) }
            return ([], nil)
        }
        .modifier(DropInto(folder: folderURL, isTargeted: $dropTarget))
    }
}

/// An expandable folder in the navigation pane that loads its subfolders when opened.
struct TreeNode: View {
    let url: URL
    let title: String
    let depth: Int
    @State private var expanded: Bool
    @State private var children: [URL]?

    init(url: URL, title: String, depth: Int, startExpanded: Bool = false) {
        self.url = url
        self.title = title
        self.depth = depth
        _expanded = State(initialValue: startExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            SidebarRow(title: title, icon: AnyView(FolderGlyph(url: url)), location: .folder(url), folderURL: url,
                       depth: depth, expandable: children.map { !$0.isEmpty } ?? true, expanded: expanded) {
                expanded.toggle()
            }
            if expanded, let children {
                ForEach(children, id: \.self) { child in
                    AnyView(TreeNode(url: child, title: child.lastPathComponent, depth: depth + 1))
                }
            }
        }
        .onAppear { if expanded { load() } }
        .onChange(of: expanded) { if expanded { load() } }
    }

    private func load() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles])) ?? []
        var folders = urls.filter(FileBrowser.isFolder)
        // Disk images opened from files on Macintosh HD are listed inside it.
        if url.path == "/" {
            folders += VolumeInfo.all().filter(\.isDiskImage).map(\.url)
        }
        children = folders
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

struct ThisPCNode: View {
    @EnvironmentObject private var browser: FileBrowser
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            SidebarRow(title: "This Mac", icon: AnyView(LocationIcon(location: .thisMac)), location: .thisMac,
                       expandable: true, expanded: expanded) { expanded.toggle() }
            if expanded {
                // Only real drives here; disk images appear inside Macintosh HD (C:).
                ForEach(browser.volumes.filter { !$0.isDiskImage }) { volume in
                    TreeNode(url: volume.url, title: volume.displayName, depth: 1)
                        .id("\(volume.id)-\(browser.volumes.count)")
                }
            }
        }
    }
}

struct SidebarResizer: View {
    @Binding var width: CGFloat
    @State private var start: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Theme.divider)
            .frame(width: 1)
            .overlay(
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                if start == nil { start = width }
                                width = min(max((start ?? width) + value.translation.width, 150), 420)
                            }
                            .onEnded { _ in start = nil }
                    )
            )
    }
}

/// Lets files be dropped onto a folder (moves on the same drive, copies across drives, ⌥ copies).
struct DropInto: ViewModifier {
    @EnvironmentObject private var browser: FileBrowser
    let folder: URL?
    @Binding var isTargeted: Bool

    func body(content: Content) -> some View {
        if let folder {
            content.dropDestination(for: URL.self) { urls, _ in
                browser.drop(urls, into: folder)
            } isTargeted: { isTargeted = $0 }
        } else {
            content
        }
    }
}

// MARK: - Main area

struct MainArea: View {
    @EnvironmentObject private var browser: FileBrowser

    var body: some View {
        switch browser.location {
        case .home: HomeView()
        case .gallery: GalleryView()
        case .thisMac:
            if browser.searchQuery.isEmpty {
                ThisPCView()
            } else {
                // Search This PC results, with a Folder column showing where each file is.
                DetailsListView()
            }
        case .folder(let url): FolderContentView(folder: url)
        }
    }
}

struct FolderContentView: View {
    @EnvironmentObject private var browser: FileBrowser
    let folder: URL
    @State private var dropTarget = false

    var body: some View {
        Group {
            switch browser.viewMode {
            case .details: DetailsListView()
            case .list: ListModeView()
            case .tiles, .content: RowsGridView(mode: browser.viewMode)
            default: IconGridView(mode: browser.viewMode)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Theme.accent.opacity(dropTarget ? 0.6 : 0), lineWidth: 2)
                .allowsHitTesting(false)
        )
        .modifier(DropInto(folder: folder, isTargeted: $dropTarget))
    }
}

struct EmptyMessage: View {
    @EnvironmentObject private var browser: FileBrowser

    var body: some View {
        if browser.visibleCount == 0 && !browser.isSearching {
            Text(browser.searchQuery.isEmpty ? "This folder is empty." : "No items match your search.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Rubber-band selection

struct ItemFramesKey: PreferenceKey {
    static var defaultValue: [URL: CGRect] = [:]
    static func reduce(value: inout [URL: CGRect], nextValue: () -> [URL: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    func reportFrame(_ url: URL) -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(key: ItemFramesKey.self, value: [url: geo.frame(in: .named("items"))])
        })
    }
}

/// A scrolling area where dragging on empty space draws a selection rectangle, like Explorer.
struct SelectableArea<Content: View>: View {
    @EnvironmentObject private var browser: FileBrowser
    var axes: Axis.Set = .vertical
    var focused: FocusState<Bool>.Binding
    @ViewBuilder let content: Content
    @State private var frames: [URL: CGRect] = [:]
    @State private var marquee: CGRect?
    @State private var base: Set<URL> = []

    var body: some View {
        GeometryReader { geo in
            ScrollView(axes) {
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            browser.selectNone()
                            focused.wrappedValue = true
                        }
                        .gesture(
                            DragGesture(minimumDistance: 4, coordinateSpace: .named("items"))
                                .onChanged { value in
                                    if marquee == nil {
                                        let keep = NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.control)
                                        base = keep ? browser.selection : []
                                        focused.wrappedValue = true
                                    }
                                    let rect = CGRect(x: min(value.startLocation.x, value.location.x),
                                                      y: min(value.startLocation.y, value.location.y),
                                                      width: abs(value.location.x - value.startLocation.x),
                                                      height: abs(value.location.y - value.startLocation.y))
                                    marquee = rect
                                    let hits = frames.filter { $0.value.intersects(rect) }.map(\.key)
                                    browser.selection = base.union(hits)
                                }
                                .onEnded { _ in marquee = nil }
                        )
                        .winContextMenu(prepare: { browser.selectNone() }) { Menus.background(browser) }
                    content
                    if let rect = marquee {
                        Rectangle()
                            .fill(Theme.accent.opacity(0.18))
                            .overlay(Rectangle().strokeBorder(Theme.accent.opacity(0.9), lineWidth: 1))
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                            .allowsHitTesting(false)
                    }
                }
                .coordinateSpace(name: "items")
            }
            .onPreferenceChange(ItemFramesKey.self) { frames = $0 }
        }
    }
}

// MARK: - Keyboard

/// Explorer keys: arrows, Home/End, Enter opens, Backspace goes back, Delete recycles,
/// Shift+Delete deletes permanently, F2 renames, F3 searches, F5 refreshes, Alt+arrows navigate,
/// typing jumps to a name.
struct ListKeyboard: ViewModifier {
    @EnvironmentObject private var browser: FileBrowser
    var focused: FocusState<Bool>.Binding
    var columns = 1
    @State private var typed = ""
    @State private var lastTyped = Date.distantPast
    @State private var spaceDownAt: Date?

    private static func fKey(_ code: Int) -> KeyEquivalent { KeyEquivalent(Character(UnicodeScalar(code)!)) }
    private static let f2 = fKey(NSF2FunctionKey)
    private static let f3 = fKey(NSF3FunctionKey)
    private static let f5 = fKey(NSF5FunctionKey)

    func body(content: Content) -> some View {
        content
            .focusable()
            .focused(focused)
            .focusEffectDisabled()
            .onAppear { focused.wrappedValue = true }
            .onKeyPress(phases: [.down, .up]) { press in
                press.phase == .up ? handleUp(press) : handle(press)
            }
    }

    /// Releasing Space after holding it closes the preview (hold to peek, tap to keep it open).
    private func handleUp(_ press: KeyPress) -> KeyPress.Result {
        guard press.key == .space, let downAt = spaceDownAt else { return .ignored }
        spaceDownAt = nil
        if Date().timeIntervalSince(downAt) > 0.45 { QuickLook.shared.close() }
        return .handled
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard browser.renamingURL == nil else { return .ignored }
        let mods = press.modifiers
        let shift = mods.contains(.shift)
        let option = mods.contains(.option)
        if mods.contains(.command) && press.key != .downArrow { return .ignored }

        // Space previews the selection, unless it's part of a name being typed ("my file").
        if press.key == .space, mods.isEmpty, typed.isEmpty || Date().timeIntervalSince(lastTyped) > 1 {
            if QuickLook.shared.isOpen {
                QuickLook.shared.close()
                spaceDownAt = nil
            } else {
                let list = browser.orderedURLs.filter(browser.selection.contains)
                QuickLook.shared.show(list.isEmpty ? Array(browser.selection) : list, owner: browser)
                spaceDownAt = Date()
            }
            return .handled
        }

        switch press.key {
        case .upArrow:
            if option { browser.goUp() } else { browser.moveSelection(by: -columns, extend: shift) }
            return .handled
        case .downArrow:
            if mods.contains(.command) { browser.openSelection() } else { browser.moveSelection(by: columns, extend: shift) }
            return .handled
        case .leftArrow:
            if option { browser.goBack(); return .handled }
            guard columns > 1 else { return .ignored }
            browser.moveSelection(by: -1, extend: shift)
            return .handled
        case .rightArrow:
            if option { browser.goForward(); return .handled }
            guard columns > 1 else { return .ignored }
            browser.moveSelection(by: 1, extend: shift)
            return .handled
        case .home:
            browser.selectEdge(last: false); return .handled
        case .end:
            browser.selectEdge(last: true); return .handled
        case .return:
            if option { browser.showProperties(browser.selection) } else { browser.openSelection() }
            return .handled
        case .delete:
            browser.goBack(); return .handled
        case .deleteForward:
            if shift { browser.requestPermanentDelete(browser.selection) } else { browser.requestTrash(browser.selection) }
            return .handled
        case .escape:
            if QuickLook.shared.isOpen { QuickLook.shared.close() } else { browser.selectNone() }
            return .handled
        case Self.f2:
            if browser.selection.count == 1, let url = browser.selection.first { browser.beginRename(url) }
            return .handled
        case Self.f3:
            browser.focusRequest = .search; return .handled
        case Self.f5:
            browser.reload(); return .handled
        default:
            break
        }

        let chars = press.characters
        if !mods.contains(.control), let c = chars.first, c.isLetter || c.isNumber || c == " " {
            if Date().timeIntervalSince(lastTyped) > 1 { typed = "" }
            typed += chars
            lastTyped = Date()
            browser.jump(to: typed)
            return .handled
        }
        return .ignored
    }
}

// MARK: - Details view

enum Column: String, CaseIterable, Hashable {
    case name, date, type, size, folder, location

    var title: String {
        switch self {
        case .name: return "Name"
        case .date: return "Date modified"
        case .type: return "Type"
        case .size: return "Size"
        case .folder: return "Folder"
        case .location: return "File location"
        }
    }

    var sortField: SortField? {
        switch self {
        case .name: return .name
        case .date: return .date
        case .type: return .type
        case .size: return .size
        default: return nil
        }
    }

    var defaultWidth: CGFloat {
        switch self {
        case .name: return 340
        case .date: return 170
        case .type: return 160
        case .size: return 100
        case .folder, .location: return 260
        }
    }

    func value(for item: FileItem) -> String {
        switch self {
        case .name: return item.name
        case .date: return WinFormat.date.string(from: item.modified)
        case .type: return item.typeText
        case .size: return item.sizeText
        case .folder, .location:
            return (item.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        }
    }
}

struct DetailsListView: View {
    @EnvironmentObject private var browser: FileBrowser
    @State private var widths: [Column: CGFloat] = Dictionary(uniqueKeysWithValues: Column.allCases.map { ($0, $0.defaultWidth) })
    @FocusState private var focused: Bool

    private var columns: [Column] {
        browser.isSearchResults ? [.name, .date, .type, .size, .folder] : [.name, .date, .type, .size]
    }

    var body: some View {
        let sections = browser.sections
        let columns = columns
        VStack(alignment: .leading, spacing: 0) {
            HeaderRow(columns: columns, widths: $widths, sortable: true)
            SelectableArea(focused: $focused) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sections) { section in
                        if let title = section.title {
                            GroupHeader(id: section.id, title: title, count: section.items.count)
                        }
                        if !browser.collapsedGroups.contains(section.id) {
                            ForEach(section.items) { item in
                                FileRow(item: item, columns: columns, widths: widths) { focused = true }
                                    .reportFrame(item.url)
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 24)
            }
            .overlay(alignment: .top) { EmptyMessage() }
        }
        .background(Theme.content)
        .modifier(ListKeyboard(focused: $focused))
    }
}

struct HeaderRow: View {
    @EnvironmentObject private var browser: FileBrowser
    @ObservedObject private var prefs = Prefs.shared
    let columns: [Column]
    @Binding var widths: [Column: CGFloat]
    let sortable: Bool

    private var allSelected: Bool {
        let all = browser.orderedURLs
        return !all.isEmpty && browser.selection.count == all.count
    }

    var body: some View {
        HStack(spacing: 0) {
            if prefs.showCheckboxes {
                CheckBox(on: allSelected, visible: true) {
                    allSelected ? browser.selectNone() : browser.selectAll()
                }
                .frame(width: 28)
            } else {
                Color.clear.frame(width: 8)
            }
            ForEach(columns, id: \.self) { column in
                HeaderCell(title: column.title, field: sortable ? column.sortField : nil,
                           width: (widths[column] ?? column.defaultWidth) - (column == .name ? (prefs.showCheckboxes ? 28 : 8) : 0),
                           widthBinding: Binding(get: { widths[column] ?? column.defaultWidth },
                                                 set: { widths[column] = $0 }))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: 34)
        .background(Theme.content)
    }
}

struct HeaderCell: View {
    @EnvironmentObject private var browser: FileBrowser
    let title: String
    let field: SortField?
    let width: CGFloat
    @Binding var widthBinding: CGFloat
    @State private var hovering = false
    @State private var start: CGFloat?

    var body: some View {
        HStack(spacing: 0) {
            Button {
                if let field { browser.sort(by: field) }
            } label: {
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.text.opacity(0.85))
                    .padding(.leading, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .background(hovering && field != nil ? Theme.hover : .clear)
                    .overlay(alignment: .top) {
                        if let field, browser.sortField == field {
                            Image(systemName: browser.sortAscending ? "chevron.up" : "chevron.down")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(Theme.secondary)
                                .offset(y: 1)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .winContextMenu {
                [.submenu("Sort by", "arrow.up.arrow.down", Menus.sortEntries(browser)),
                 .submenu("Group by", "rectangle.grid.1x2", Menus.groupEntries(browser))]
            }

            Rectangle()
                .fill(Theme.divider)
                .frame(width: 1, height: 24)
                .overlay(
                    Color.clear.frame(width: 8).contentShape(Rectangle())
                        .onHover { inside in
                            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    if start == nil { start = widthBinding }
                                    widthBinding = max((start ?? widthBinding) + value.translation.width, 70)
                                }
                                .onEnded { _ in start = nil }
                        )
                )
        }
        .frame(width: max(width, 40), height: 34)
    }
}

struct GroupHeader: View {
    @EnvironmentObject private var browser: FileBrowser
    let id: String
    let title: String
    var count: Int?

    var body: some View {
        let collapsed = browser.collapsedGroups.contains(id)
        Button {
            if collapsed { browser.collapsedGroups.remove(id) } else { browser.collapsedGroups.insert(id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                Text(title).font(.system(size: 12.5))
                if collapsed, let count {
                    Text("(\(count))").font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                }
            }
            .padding(.leading, 4)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .winContextMenu {
            [.item("Collapse all groups", "chevron.up") { browser.collapsedGroups = Set(browser.sections.map(\.id)) },
             .item("Expand all groups", "chevron.down") { browser.collapsedGroups = [] }]
        }
    }
}

/// Shared look and behaviour for every item (row, icon, tile): hover, selection, click, drag, drop, menu.
struct ItemChrome: ViewModifier {
    @EnvironmentObject private var browser: FileBrowser
    let item: FileItem
    var corner: CGFloat = 4
    let onActivate: () -> Void
    @State private var hovering = false
    @State private var dropTarget = false

    func body(content: Content) -> some View {
        let selected = browser.selection.contains(item.url)
        content
            .background(
                RoundedRectangle(cornerRadius: corner)
                    .fill(dropTarget ? Theme.accent.opacity(0.25)
                          : selected ? (hovering ? Theme.selectedHover : Theme.selected)
                          : (hovering ? Theme.hover : .clear))
            )
            .opacity(browser.isCut(item.url) ? 0.5 : 1)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture {
                onActivate()
                if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                    browser.open([item.url])
                } else {
                    browser.click(item.url)
                }
            }
            .winContextMenu(prepare: { browser.prepareContextMenu(for: item.url) }) {
                Menus.items(browser, browser.selection.isEmpty ? [item.url] : browser.selection)
            }
            .modifier(FileDragSource(url: item.url))
            .modifier(DropInto(folder: item.isDirectory ? item.url : nil, isTargeted: $dropTarget))
            .help(tooltip)
            .environment(\.itemHovering, hovering)
    }

    private var tooltip: String {
        var lines = ["Type: \(item.typeText)"]
        if item.size >= 0 { lines.append("Size: \(WinFormat.friendly(item.size))") }
        lines.append("Date modified: \(WinFormat.date.string(from: item.modified))")
        return lines.joined(separator: "\n")
    }
}

private struct ItemHoveringKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var itemHovering: Bool {
        get { self[ItemHoveringKey.self] }
        set { self[ItemHoveringKey.self] = newValue }
    }
}

struct FileRow: View {
    @EnvironmentObject private var browser: FileBrowser
    @ObservedObject private var prefs = Prefs.shared
    let item: FileItem
    let columns: [Column]
    let widths: [Column: CGFloat]
    let onActivate: () -> Void

    var body: some View {
        let selected = browser.selection.contains(item.url)
        let lead: CGFloat = prefs.showCheckboxes ? 28 : 8
        HStack(spacing: 0) {
            if prefs.showCheckboxes {
                RowCheckBox(url: item.url, selected: selected).frame(width: 28)
            } else {
                Color.clear.frame(width: 8)
            }
            ForEach(columns, id: \.self) { column in
                let width = widths[column] ?? column.defaultWidth
                switch column {
                case .name:
                    HStack(spacing: 9) {
                        ItemIcon(item: item, size: 16)
                        if browser.renamingURL == item.url {
                            RenameField()
                        } else {
                            Text(item.displayName(showExtensions: prefs.showExtensions))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .padding(.leading, 4)
                    .frame(width: width - lead, alignment: .leading)
                case .size:
                    Text(item.sizeText)
                        .foregroundStyle(Theme.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .padding(.trailing, 10)
                        .frame(width: width, alignment: .trailing)
                default:
                    Text(column.value(for: item))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.leading, 9)
                        .frame(width: width, alignment: .leading)
                }
            }
        }
        .font(.system(size: 13))
        .frame(height: prefs.compact ? 25 : 31, alignment: .leading)
        .modifier(ItemChrome(item: item, onActivate: onActivate))
    }
}

/// Checkbox that appears on hover or when selected.
struct RowCheckBox: View {
    @EnvironmentObject private var browser: FileBrowser
    @Environment(\.itemHovering) private var hovering
    let url: URL
    let selected: Bool

    var body: some View {
        CheckBox(on: selected, visible: hovering || selected) { browser.toggleSelection(url) }
    }
}

struct CheckBox: View {
    let on: Bool
    let visible: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(on ? Theme.accent : Theme.content.opacity(0.6))
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(on ? Theme.accent : Theme.secondary, lineWidth: 1)
                if on {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                }
            }
            .frame(width: 14, height: 14)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(visible ? 1 : 0)
    }
}

struct RenameField: View {
    @EnvironmentObject private var browser: FileBrowser
    var centered = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $browser.renameText)
            .textFieldStyle(.plain)
            .multilineTextAlignment(centered ? .center : .leading)
            .padding(.horizontal, 4)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 3).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.accent, lineWidth: 1))
            .focused($focused)
            .onAppear { DispatchQueue.main.async { focused = true } }
            .onSubmit { browser.commitRename() }
            .onExitCommand { browser.cancelRename() }
            .onChange(of: focused) {
                if !focused, browser.renamingURL != nil { browser.commitRename() }
            }
    }
}

// MARK: - Icon views (extra large, large, medium, small)

struct IconGridView: View {
    @EnvironmentObject private var browser: FileBrowser
    @ObservedObject private var prefs = Prefs.shared
    let mode: ViewMode
    @FocusState private var focused: Bool

    private var spec: (cell: CGFloat, icon: CGFloat) {
        switch mode {
        case .extraLargeIcons: return (210, 180)
        case .largeIcons: return (128, 96)
        case .mediumIcons: return (100, 48)
        default: return (240, 16)
        }
    }

    var body: some View {
        let sections = browser.sections
        let spacing: CGFloat = prefs.compact ? 2 : 4
        GeometryReader { geo in
            let columns = max(Int((geo.size.width - 20) / (spec.cell + spacing)), 1)
            SelectableArea(focused: $focused) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: spec.cell, maximum: spec.cell), spacing: spacing)],
                          alignment: .leading, spacing: spacing) {
                    ForEach(sections) { section in
                        Section {
                            if !browser.collapsedGroups.contains(section.id) {
                                ForEach(section.items) { item in
                                    IconCell(item: item, mode: mode, width: spec.cell, iconSize: spec.icon) {
                                        focused = true
                                    }
                                    .reportFrame(item.url)
                                }
                            }
                        } header: {
                            if let title = section.title {
                                GroupHeader(id: section.id, title: title, count: section.items.count)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(10)
            }
            .overlay(alignment: .top) { EmptyMessage() }
            .modifier(ListKeyboard(focused: $focused, columns: columns))
        }
        .background(Theme.content)
    }
}

struct IconCell: View {
    @EnvironmentObject private var browser: FileBrowser
    @ObservedObject private var prefs = Prefs.shared
    let item: FileItem
    let mode: ViewMode
    let width: CGFloat
    let iconSize: CGFloat
    let onActivate: () -> Void

    var body: some View {
        let selected = browser.selection.contains(item.url)
        Group {
            if mode == .smallIcons {
                HStack(spacing: 8) {
                    ItemIcon(item: item, size: 16)
                    nameView(lines: 1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(width: width, height: prefs.compact ? 22 : 28)
            } else {
                VStack(spacing: 6) {
                    ItemIcon(item: item, size: iconSize)
                        .frame(width: iconSize, height: iconSize)
                    nameView(lines: 2)
                        .multilineTextAlignment(.center)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
                .frame(width: width, height: iconSize + (prefs.compact ? 52 : 64), alignment: .top)
                .overlay(alignment: .topLeading) {
                    if prefs.showCheckboxes {
                        RowCheckBox(url: item.url, selected: selected)
                            .offset(x: -4, y: -4)
                    }
                }
            }
        }
        .font(.system(size: 12.5))
        .modifier(ItemChrome(item: item, onActivate: onActivate))
    }

    @ViewBuilder private func nameView(lines: Int) -> some View {
        if browser.renamingURL == item.url {
            RenameField(centered: lines > 1)
        } else {
            Text(item.displayName(showExtensions: prefs.showExtensions))
                .lineLimit(lines)
                .truncationMode(.middle)
        }
    }
}

// MARK: - List view (columns that flow left to right)

struct ListModeView: View {
    @EnvironmentObject private var browser: FileBrowser
    @ObservedObject private var prefs = Prefs.shared
    @FocusState private var focused: Bool

    var body: some View {
        let items = browser.sections.flatMap(\.items)
        GeometryReader { geo in
            let rowHeight: CGFloat = prefs.compact ? 22 : 28
            let rows = max(Int((geo.size.height - 24) / (rowHeight + 2)), 1)
            SelectableArea(axes: .horizontal, focused: $focused) {
                LazyHGrid(rows: Array(repeating: GridItem(.fixed(rowHeight), spacing: 2), count: rows),
                          alignment: .top, spacing: 8) {
                    ForEach(items) { item in
                        IconCell(item: item, mode: .smallIcons, width: 260, iconSize: 16) { focused = true }
                            .reportFrame(item.url)
                    }
                }
                .padding(10)
            }
            .overlay(alignment: .top) { EmptyMessage() }
            .modifier(ListKeyboard(focused: $focused, columns: 1))
        }
        .background(Theme.content)
    }
}

// MARK: - Tiles and Content views

struct RowsGridView: View {
    @EnvironmentObject private var browser: FileBrowser
    let mode: ViewMode
    @FocusState private var focused: Bool

    var body: some View {
        let sections = browser.sections
        GeometryReader { geo in
            let columns = mode == .tiles ? max(Int((geo.size.width - 20) / 304), 1) : 1
            SelectableArea(focused: $focused) {
                LazyVGrid(columns: mode == .tiles
                          ? [GridItem(.adaptive(minimum: 300, maximum: 300), spacing: 4)]
                          : [GridItem(.flexible())],
                          alignment: .leading, spacing: mode == .tiles ? 4 : 0) {
                    ForEach(sections) { section in
                        Section {
                            if !browser.collapsedGroups.contains(section.id) {
                                ForEach(section.items) { item in
                                    Group {
                                        if mode == .tiles {
                                            TileCell(item: item) { focused = true }
                                        } else {
                                            ContentRow(item: item) { focused = true }
                                        }
                                    }
                                    .reportFrame(item.url)
                                }
                            }
                        } header: {
                            if let title = section.title {
                                GroupHeader(id: section.id, title: title, count: section.items.count)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(10)
            }
            .overlay(alignment: .top) { EmptyMessage() }
            .modifier(ListKeyboard(focused: $focused, columns: columns))
        }
        .background(Theme.content)
    }
}

struct TileCell: View {
    @EnvironmentObject private var browser: FileBrowser
    @ObservedObject private var prefs = Prefs.shared
    let item: FileItem
    let onActivate: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ItemIcon(item: item, size: 48).frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                if browser.renamingURL == item.url {
                    RenameField()
                } else {
                    Text(item.displayName(showExtensions: prefs.showExtensions)).lineLimit(1)
                }
                Text(item.typeText).foregroundStyle(Theme.secondary).lineLimit(1)
                if item.size >= 0 {
                    Text(WinFormat.friendly(item.size)).foregroundStyle(Theme.secondary)
                }
            }
            .font(.system(size: 12.5))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(width: 300, height: prefs.compact ? 62 : 72)
        .modifier(ItemChrome(item: item, onActivate: onActivate))
    }
}

struct ContentRow: View {
    @EnvironmentObject private var browser: FileBrowser
    @ObservedObject private var prefs = Prefs.shared
    let item: FileItem
    let onActivate: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ItemIcon(item: item, size: 40).frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    if browser.renamingURL == item.url {
                        RenameField()
                    } else {
                        Text(item.displayName(showExtensions: prefs.showExtensions)).lineLimit(1)
                    }
                    Text(item.typeText).foregroundStyle(Theme.secondary)
                }
                Spacer()
                VStack(alignment: .leading, spacing: 3) {
                    Text("Date modified: \(WinFormat.date.string(from: item.modified))")
                    if item.size >= 0 { Text("Size: \(WinFormat.friendly(item.size))") }
                }
                .foregroundStyle(Theme.secondary)
                .frame(width: 240, alignment: .leading)
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 10)
            .frame(height: prefs.compact ? 52 : 64)
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
        .modifier(ItemChrome(item: item, onActivate: onActivate))
    }
}

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject private var browser: FileBrowser
    @ObservedObject private var pins = PinStore.shared
    @State private var widths: [Column: CGFloat] = [.name: 340, .date: 170, .location: 260, .size: 100]
    @FocusState private var focused: Bool

    var body: some View {
        if browser.viewMode == .details {
            detailsLayout
        } else {
            // Any other View choice (icons, list, tiles, content) applies to the Recent files, like Windows.
            VStack(alignment: .leading, spacing: 10) {
                quickAccess
                SectionTitle(title: "Recent").padding(.top, 10)
                Group {
                    switch browser.viewMode {
                    case .list: ListModeView()
                    case .tiles, .content: RowsGridView(mode: browser.viewMode)
                    default: IconGridView(mode: browser.viewMode)
                    }
                }
                .padding(.horizontal, -20)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .background(Theme.content)
        }
    }

    private var quickAccess: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Pinned")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 280), spacing: 6)],
                      alignment: .leading, spacing: 6) {
                ForEach(pins.pinned, id: \.self) { url in
                    QuickTile(url: url)
                }
            }
        }
    }

    private var detailsLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Pinned")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 280), spacing: 6)],
                          alignment: .leading, spacing: 6) {
                    ForEach(pins.pinned, id: \.self) { url in
                        QuickTile(url: url)
                    }
                }

                if !browser.favoriteItems.isEmpty {
                    SectionTitle(title: "Favorites").padding(.top, 16)
                    HeaderRow(columns: [.name, .date, .location, .size], widths: $widths, sortable: false)
                        .padding(.horizontal, -6)
                    ForEach(browser.favoriteItems) { item in
                        FileRow(item: item, columns: [.name, .date, .location, .size], widths: widths) {}
                    }
                }

                SectionTitle(title: "Recent").padding(.top, 16)
                HeaderRow(columns: [.name, .date, .location, .size], widths: $widths, sortable: false)
                    .padding(.horizontal, -6)
                if browser.sortedItems.isEmpty {
                    Text(browser.searchQuery.isEmpty ? "After you've opened some files, we'll show the most recent ones here."
                                                     : "No items match your search.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondary)
                        .padding(.top, 12)
                        .frame(maxWidth: .infinity)
                }
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(browser.sortedItems) { item in
                        FileRow(item: item, columns: [.name, .date, .location, .size], widths: widths) {}
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .background(Theme.content)
        .modifier(ListKeyboard(focused: $focused))
    }
}

struct SectionTitle: View {
    let title: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.secondary)
            Text(title).font(.system(size: 13, weight: .semibold))
        }
    }
}

struct QuickTile: View {
    @EnvironmentObject private var browser: FileBrowser
    let url: URL
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            FolderGlyph(url: url, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(Place.special(for: url)?.name ?? FileManager.default.displayName(atPath: url.path))
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text("Stored locally")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "pin.fill")
                .font(.system(size: 10))
                .rotationEffect(.degrees(45))
                .foregroundStyle(Theme.secondary)
        }
        .padding(10)
        .frame(height: 64)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { browser.go(to: .folder(url)) }
        .dropDestination(for: URL.self) { urls, _ in browser.drop(urls, into: url) }
        .winContextMenu { Menus.folderLink(browser, url) }
    }
}

// MARK: - Gallery

struct GalleryView: View {
    @EnvironmentObject private var browser: FileBrowser
    @FocusState private var focused: Bool

    /// The View menu's icon sizes change the picture size, like Windows Gallery.
    private var tileSize: (CGFloat, CGFloat) {
        switch browser.viewMode {
        case .extraLargeIcons: return (300, 380)
        case .largeIcons: return (190, 240)
        case .smallIcons, .list, .details: return (90, 110)
        default: return (140, 170)
        }
    }

    private var months: [ItemSection] {
        var order: [String] = []
        var buckets: [String: [FileItem]] = [:]
        for item in browser.sortedItems {
            let key = WinFormat.month.string(from: item.modified)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(item)
        }
        return order.map { ItemSection(id: $0, title: $0, items: buckets[$0] ?? []) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(months) { month in
                    Text(month.title ?? "").font(.system(size: 14, weight: .semibold))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: tileSize.0, maximum: tileSize.1), spacing: 4)], spacing: 4) {
                        ForEach(month.items) { item in
                            GalleryTile(item: item)
                        }
                    }
                }
            }
            .padding(16)
        }
        .overlay {
            if browser.isLoadingGallery {
                ProgressView("Loading photos…").controlSize(.small)
            } else if browser.sortedItems.isEmpty {
                Text(browser.searchQuery.isEmpty ? "No photos or videos found in your Pictures folder."
                                                 : "No items match your search.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
            }
        }
        .background(Theme.content)
        .modifier(ListKeyboard(focused: $focused, columns: 1))
    }
}

struct GalleryTile: View {
    @EnvironmentObject private var browser: FileBrowser
    let item: FileItem

    var body: some View {
        let selected = browser.selection.contains(item.url)
        GeometryReader { geo in
            ThumbnailImage(url: item.url, size: geo.size.width, fill: true)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.accent, lineWidth: selected ? 3 : 0))
        .contentShape(Rectangle())
        .onTapGesture {
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { browser.open([item.url]) } else { browser.click(item.url) }
        }
        .winContextMenu(prepare: { browser.prepareContextMenu(for: item.url) }) {
            Menus.items(browser, browser.selection.isEmpty ? [item.url] : browser.selection)
        }
        .modifier(FileDragSource(url: item.url))
        .help(item.name)
    }
}

// MARK: - This PC

struct ThisPCView: View {
    @EnvironmentObject private var browser: FileBrowser

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Devices and drives")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 360), spacing: 6)],
                          alignment: .leading, spacing: 6) {
                    ForEach(browser.volumes.filter { !$0.isDiskImage }) { volume in
                        // Disk images (Claude, Steam, UTM…) live inside Macintosh HD: open it to see them.
                        DriveTile(volume: volume)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.content)
        .contentShape(Rectangle())
        .onTapGesture { browser.selectNone() }
    }
}

struct DriveTile: View {
    @EnvironmentObject private var browser: FileBrowser
    let volume: VolumeInfo
    var nested = false
    @State private var hovering = false

    var body: some View {
        let selected = browser.selection.contains(volume.url)
        HStack(spacing: 12) {
            FolderGlyph(url: volume.url, size: nested ? 34 : 48)
            VStack(alignment: .leading, spacing: 5) {
                Text(volume.displayName).font(.system(size: 13)).lineLimit(1)
                if let file = volume.imageFile {
                    Text("Disk image · Read-only · \(WinFormat.friendly(volume.total))")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondary)
                    Text("From \((file.path as NSString).abbreviatingWithTildeInPath)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Theme.barTrack)
                            Rectangle().fill(volume.usedFraction > 0.9 ? Theme.danger : Theme.accent)
                                .frame(width: geo.size.width * volume.usedFraction)
                        }
                    }
                    .frame(height: 13)
                    Text("\(WinFormat.friendly(volume.available)) free of \(WinFormat.friendly(volume.total))")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if volume.isDiskImage || volume.isRemovable {
                Button { browser.eject(volume.url) } label: {
                    Image(systemName: "eject").font(.system(size: 13)).frame(width: 30, height: 30)
                }
                .buttonStyle(BarButtonStyle())
                .help("Eject \(volume.name)")
            }
        }
        .padding(10)
        .frame(height: nested ? 66 : 78)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(selected ? (hovering ? Theme.selectedHover : Theme.selected) : (hovering ? Theme.hover : .clear)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                browser.go(to: .folder(volume.url))
            } else {
                browser.selection = [volume.url]
            }
        }
        .dropDestination(for: URL.self) { urls, _ in browser.drop(urls, into: volume.url) }
        .winContextMenu(prepare: { browser.selection = [volume.url] }) { Menus.drive(browser, volume) }
    }
}

// MARK: - Details pane and Preview pane

struct DetailsPane: View {
    @EnvironmentObject private var browser: FileBrowser
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        let selected = browser.selectedItems
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if selected.count == 1, let item = selected.first {
                    HStack {
                        Spacer()
                        if item.isDirectory {
                            FolderIcon(size: 120)
                        } else {
                            ThumbnailImage(url: item.url, size: 200)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 10)
                    Text(item.displayName(showExtensions: prefs.showExtensions))
                        .font(.system(size: 16, weight: .semibold))
                        .textSelection(.enabled)
                    Text(item.typeText).foregroundStyle(Theme.secondary)
                    Rectangle().fill(Theme.divider).frame(height: 1)
                    Text("Details").font(.system(size: 13, weight: .semibold))
                    if !item.isDirectory { detail("Size", WinFormat.friendly(max(item.size, 0))) }
                    detail("Date modified", WinFormat.date.string(from: item.modified))
                    if let created = item.created { detail("Date created", WinFormat.date.string(from: created)) }
                    detail("Path", (item.url.path as NSString).abbreviatingWithTildeInPath)
                } else if selected.count > 1 {
                    HStack {
                        Spacer()
                        ZStack {
                            ItemIcon(item: selected[1], size: 96).offset(x: 12, y: -12).opacity(0.6)
                            ItemIcon(item: selected[0], size: 96)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 16)
                    Text("\(selected.count) items selected").font(.system(size: 16, weight: .semibold))
                    let bytes = selected.filter { $0.size > 0 }.reduce(Int64(0)) { $0 + $1.size }
                    if bytes > 0 { detail("Total size", WinFormat.friendly(bytes)) }
                } else {
                    HStack {
                        Spacer()
                        LocationIcon(location: browser.location, size: 72)
                        Spacer()
                    }
                    .padding(.vertical, 16)
                    Text(browser.title).font(.system(size: 16, weight: .semibold))
                    Text("\(browser.visibleCount) items")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondary)
                    Text("Select a single file to get more information and share your cloud content")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondary)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.content)
    }

    private func detail(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
            Text(value).font(.system(size: 12.5)).textSelection(.enabled).lineLimit(3)
        }
    }
}

struct PreviewPane: View {
    @EnvironmentObject private var browser: FileBrowser

    var body: some View {
        let selected = browser.selectedItems
        Group {
            if selected.count == 1, let item = selected.first, !item.isDirectory {
                QuickLookPreview(url: item.url)
            } else {
                Text(selected.count > 1 ? "\(selected.count) items selected" : "Select a file to preview.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.content)
    }
}

struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.shouldCloseWithWindow = false
        view.autostarts = true
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url {
            view.previewItem = url as NSURL
        }
    }
}

// MARK: - Right-click menu

