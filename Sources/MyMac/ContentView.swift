import AppKit
import SwiftUI

/// Folders' own colour scheme: graphite (dark) or paper (light), with the accent colour
/// chosen in Customise (green by default).
enum Theme {
    static let strip = dynamic(0x141312, 0xEAE8E4)
    static let chrome = dynamic(0x1F1D1B, 0xF6F5F2)
    static let content = dynamic(0x191817, 0xFFFFFF)
    static let field = dynamic(0x2B2926, 0xFFFFFF)
    static let fieldBorder = dynamic(0x3A3632, 0xD6D3CE)
    static let hover = dynamic(0xFFFFFF, 0x000000, 0.06, 0.05)
    static let selected = accented(darkAlpha: 0.18, lightAlpha: 0.16)
    static let selectedHover = accented(darkAlpha: 0.25, lightAlpha: 0.24)
    static let divider = dynamic(0xFFFFFF, 0x000000, 0.08, 0.10)
    static let text = dynamic(0xFFFFFF, 0x161616, 0.92, 1)
    static let secondary = dynamic(0xFFFFFF, 0x161616, 0.60, 0.62)
    static let tertiary = dynamic(0xFFFFFF, 0x161616, 0.35, 0.32)
    static let accent = accented(darkAlpha: 1, lightAlpha: 1, deepInLight: true)
    static let onAccent = dynamic(0x111111, 0xFFFFFF)
    static let barTrack = dynamic(0xFFFFFF, 0x000000, 0.12, 0.10)
    /// Icon colour for places in the sidebar and title bar, and for folders.
    static let brand = Color(nsColor: NSColor(name: nil) { _ in nsColor(CurrentAccent.value.icon) })

    /// The chosen accent: its bright shade (dark mode) or deep shade (light mode, for text and buttons).
    private static func accented(darkAlpha: CGFloat, lightAlpha: CGFloat, deepInLight: Bool = false) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let a = CurrentAccent.value
            return nsColor(isDark || !deepInLight ? a.dark : a.light, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }

    static func nsColor(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
    static let danger = Color(hex: 0xE5484D)

    static func dynamic(_ dark: UInt32, _ light: UInt32, _ darkAlpha: CGFloat = 1, _ lightAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}

// MARK: - Window

struct ContentView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var ops = FileOps.shared

    var body: some View {
        VStack(spacing: 0) {
            TabStrip()
            BrowserView()
                .environmentObject(app.current)
                .id(app.current.id)
        }
        .background(Theme.content)
        .foregroundStyle(Theme.text)
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(prefs.colorScheme)
        .id(prefs.accent)
        .overlay(alignment: .bottomTrailing) {
            if let progress = ops.progress {
                ProgressCard(progress: progress)
                    .padding(.trailing, 20)
                    .padding(.bottom, 40)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: ops.progress == nil)
        .sheet(item: $ops.conflict) { request in
            ConflictView(request: request)
        }
        .alert("Folders", isPresented: Binding(
            get: { ops.errorMessage != nil },
            set: { if !$0 { ops.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(ops.errorMessage ?? "")
        }
        .onAppear { prefs.applyAppearance() }
    }
}

struct BrowserView: View {
    @EnvironmentObject private var browser: FileBrowser
    @ObservedObject private var prefs = Prefs.shared
    @State private var sidebarWidth: CGFloat = 230

    var body: some View {
        VStack(spacing: 0) {
            NavBar()
            CommandBar()
            Rectangle().fill(Theme.divider).frame(height: 1)
            HStack(spacing: 0) {
                if prefs.showNavPane {
                    SidebarView()
                        .frame(width: sidebarWidth)
                        .layoutPriority(2)
                    SidebarResizer(width: $sidebarWidth)
                        .layoutPriority(2)
                }
                MainArea()
                    .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
                if prefs.sidePane != .none {
                    Rectangle().fill(Theme.divider).frame(width: 1)
                    Group {
                        if prefs.sidePane == .details { DetailsPane() } else { PreviewPane() }
                    }
                    .frame(width: 320)
                    .layoutPriority(2)
                }
            }
            StatusBar()
        }
        .background(Theme.content)
        .navigationTitle(browser.title)
        .onChange(of: browser.searchText) { browser.updateSearch() }
        .sheet(item: $browser.propertiesTarget) { target in
            PropertiesView(urls: target.urls).environmentObject(browser)
        }
        .alert(permanentDeleteTitle, isPresented: Binding(
            get: { browser.confirmPermanentDelete != nil },
            set: { if !$0 { browser.confirmPermanentDelete = nil } }
        )) {
            Button("Yes", role: .destructive) { browser.performPermanentDelete() }
            Button("No", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
        .confirmationDialog(trashTitle, isPresented: Binding(
            get: { browser.confirmTrash != nil },
            set: { if !$0 { browser.confirmTrash = nil } }
        )) {
            Button("Move to Trash", role: .destructive) { browser.performTrash() }
            Button("Cancel", role: .cancel) { browser.confirmTrash = nil }
        } message: {
            Text("You can get \((browser.confirmTrash?.count ?? 1) == 1 ? "it" : "them") back from the Trash, or press ⌘Z to undo.")
        }
        .dialogSuppressionToggle("Don't ask me again", isSuppressed: Binding(
            get: { !Prefs.shared.confirmDelete }, set: { Prefs.shared.confirmDelete = !$0 }))
    }

    private var trashTitle: String {
        let urls = browser.confirmTrash ?? []
        if urls.count == 1, let url = urls.first {
            let kind = FileBrowser.isFolder(url) ? "folder" : "file"
            return "Are you sure you want to move this \(kind) to the Trash?\n“\(url.lastPathComponent)”"
        }
        return "Are you sure you want to move these \(urls.count) items to the Trash?"
    }

    private var permanentDeleteTitle: String {
        let urls = browser.confirmPermanentDelete ?? []
        if urls.count == 1, let url = urls.first {
            return "Are you sure you want to permanently delete “\(url.lastPathComponent)”?"
        }
        return "Are you sure you want to permanently delete these \(urls.count) items?"
    }
}

// MARK: - Tabs

struct TabStrip: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            CaptionButtons()
                .padding(.trailing, 8)
            ForEach(app.tabs) { tab in
                TabButton(tab: tab, selected: tab.id == app.selectedID)
            }
            Button { app.newTab() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13))
                    .frame(width: 34, height: 30)
            }
            .buttonStyle(BarButtonStyle())
            .help("Add a new tab (⌘T)")
            .padding(.bottom, 3)
            Spacer(minLength: 60)
        }
        .padding(.leading, 8)
        .frame(height: 44, alignment: .bottom)
        .background(HideTrafficLights())
        .background(WindowDragArea())
        .background(Theme.strip)
    }
}

/// Window buttons in Folders' own style: small round Close, Minimize and Full screen buttons, top left.
struct CaptionButtons: View {
    var body: some View {
        // On the left, in the Mac's order: Close, Minimize, Full screen.
        HStack(spacing: 6) {
            CaptionButton(symbol: "xmark", help: "Close", danger: true) {
                WindowActions.mainWindow?.performClose(nil)
            }
            CaptionButton(symbol: "minus", help: "Minimize", danger: false) {
                WindowActions.minimize()
            }
            CaptionButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Full screen", danger: false) {
                WindowActions.mainWindow?.toggleFullScreen(nil)
            }
        }
        .padding(.leading, 4)
        .frame(maxHeight: .infinity, alignment: .center)
    }
}

struct CaptionButton: View {
    let symbol: String
    let help: String
    let danger: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hovering ? (danger ? Color.white : Theme.onAccent) : Theme.secondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(hovering ? (danger ? Theme.danger : Theme.accent) : Theme.field))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Minimize / full screen / close for the app's main window (not a menu or dialog).
@MainActor
enum WindowActions {
    static var mainWindow: NSWindow? {
        if let w = NSApp.mainWindow, !(w is NSPanel) { return w }
        return NSApp.windows.first { $0.isVisible && !($0 is NSPanel) && !$0.isSheet && $0.contentView != nil }
    }

    /// macOS can't minimize a full-screen window, so leave full screen first (Windows has no such limit).
    static func minimize() {
        guard let window = mainWindow else { return }
        guard window.styleMask.contains(.fullScreen) else {
            minimizeOrHide(window)
            return
        }
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification,
                                                       object: window, queue: .main) { _ in
            if let token { NotificationCenter.default.removeObserver(token) }
            MainActor.assumeIsolated { minimizeOrHide(window) }
        }
        window.toggleFullScreen(nil)
    }

    /// Tries a real minimize; if macOS refuses (it does for this window style on some setups),
    /// hides the app instead, which looks the same: the window goes away and the Dock icon brings it back.
    private static func minimizeOrHide(_ window: NSWindow) {
        var started = false
        let token = NotificationCenter.default.addObserver(forName: NSWindow.willMiniaturizeNotification,
                                                           object: window, queue: .main) { _ in started = true }
        miniaturize(window)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            NotificationCenter.default.removeObserver(token)
            if !started && !window.isMiniaturized {
                isMinimizing = false
                NSApp.hide(nil)
            }
        }
    }

    /// macOS won't minimize a window whose own minimize button is hidden (we hide the Mac buttons
    /// so the tabs can start at the edge), so show it for that moment and hide it again afterwards.
    private static func miniaturize(_ window: NSWindow) {
        // Keep the (invisible) button present until the window comes back from the Dock;
        // hiding it again mid-animation makes macOS cancel the minimize.
        let button = window.standardWindowButton(.miniaturizeButton)
        button?.alphaValue = 0
        button?.isHidden = false
        isMinimizing = true
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: NSWindow.didDeminiaturizeNotification,
                                                       object: window, queue: .main) { _ in
            if let token { NotificationCenter.default.removeObserver(token) }
            MainActor.assumeIsolated {
                isMinimizing = false
                button?.isHidden = true
                button?.alphaValue = 1
            }
        }
        window.miniaturize(nil)
    }

    /// While true, the Mac buttons are left alone (see HideTrafficLights).
    static var isMinimizing = false
}

/// Hides the Mac's red/yellow/green buttons so the tabs start at the left edge, like Windows.
struct HideTrafficLights: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Watcher() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Watcher: NSView {
        private var tokens: [NSObjectProtocol] = []
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            hide(window)
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = [NSWindow.didResizeNotification, NSWindow.didExitFullScreenNotification,
                      NSWindow.didBecomeKeyNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak window] _ in
                    if let window { MainActor.assumeIsolated { HideTrafficLights.Watcher.hideButtons(window) } }
                }
            }
        }
        private func hide(_ window: NSWindow) { Self.hideButtons(window) }
        @MainActor static func hideButtons(_ window: NSWindow) {
            window.styleMask.insert(.miniaturizable)
            guard !WindowActions.isMinimizing else { return }
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(kind)?.isHidden = true
            }
        }
    }
}

struct TabButton: View {
    @ObservedObject var tab: FileBrowser
    let selected: Bool
    @EnvironmentObject private var app: AppState
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            LocationIcon(location: tab.location, size: 16)
            Text(tab.title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            Button { app.close(tab) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(BarButtonStyle(corner: 4))
            .help("Close tab (⌘W)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(minWidth: 120, idealWidth: 250, maxWidth: 260)
        .frame(height: 38)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8)
                .fill(selected ? Theme.chrome : (hovering ? Theme.hover : .clear))
        )
        .contentShape(Rectangle())
        .onTapGesture { app.select(tab) }
        .onHover { hovering = $0 }
        .help(tab.title)
        .winContextMenu { Menus.tab(app, tab) }
    }
}

/// Lets the user drag the window by the empty part of the tab strip (double-click maximizes).
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.zoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

// MARK: - Navigation row

struct NavBar: View {
    @EnvironmentObject private var browser: FileBrowser

    var body: some View {
        HStack(spacing: 2) {
            NavButton(symbol: "arrow.left", help: "Back (⌥←)", enabled: browser.canGoBack) { browser.goBack() }
            NavButton(symbol: "arrow.right", help: "Forward (⌥→)", enabled: browser.canGoForward) { browser.goForward() }
            NavButton(symbol: "arrow.up", help: "Up (⌥↑)", enabled: browser.canGoUp) { browser.goUp() }
            NavButton(symbol: "arrow.clockwise", help: "Refresh (F5)", enabled: true) { browser.reload() }
            AddressBar()
                .padding(.leading, 8)
            SearchBox()
                .frame(width: 320)
                .padding(.leading, 8)
        }
        .padding(.horizontal, 10)
        .frame(height: 50)
        .background(Theme.chrome)
    }
}

struct NavButton: View {
    let symbol: String
    let help: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .frame(width: 36, height: 34)
        }
        .buttonStyle(BarButtonStyle())
        .disabled(!enabled)
        .help(help)
    }
}

struct AddressBar: View {
    @EnvironmentObject private var browser: FileBrowser
    @State private var editing = false
    @State private var pathText = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            if editing {
                LocationIcon(location: browser.location, size: 16)
                    .padding(.leading, 12)
                TextField("", text: $pathText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($fieldFocused)
                    .padding(.horizontal, 10)
                    .onSubmit {
                        editing = false
                        browser.goTo(path: pathText)
                    }
                    .onExitCommand { editing = false }
                    .onChange(of: fieldFocused) { if !fieldFocused { editing = false } }
            } else {
                rootIcon
                    .padding(.leading, 12)
                    .padding(.trailing, 2)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(browser.breadcrumbs.enumerated()), id: \.offset) { _, crumb in
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.secondary)
                                .frame(width: 22)
                            Button(crumb.name) { browser.go(to: crumb.location) }
                                .buttonStyle(CrumbButtonStyle())
                                .dropDestination(for: URL.self) { urls, _ in
                                    if case .folder(let dir) = crumb.location { return browser.drop(urls, into: dir) }
                                    return false
                                }
                        }
                    }
                }
                .defaultScrollAnchor(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                if browser.currentURL != nil {
                    DropMenu {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.secondary)
                            .frame(width: 22, height: 26)
                    } content: { close in
                        if browser.subfolders.isEmpty {
                            Text("No subfolders")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.secondary)
                                .padding(8)
                        } else {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(browser.subfolders) { folder in
                                        MenuRow(title: folder.name, icon: AnyView(FolderIcon(size: 16))) {
                                            close()
                                            browser.go(to: .folder(folder.url))
                                        }
                                    }
                                }
                            }
                            .frame(maxHeight: 420)
                        }
                    }
                }
                Color.clear
                    .frame(minWidth: 40)
                    .contentShape(Rectangle())
                    .onTapGesture { startEditing() }
            }
        }
        .frame(height: 34)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.field))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(editing ? Theme.accent : Theme.fieldBorder, lineWidth: 1)
        )
        .onChange(of: browser.focusRequest) {
            if browser.focusRequest == .address {
                browser.focusRequest = nil
                startEditing()
            }
        }
    }

    @ViewBuilder private var rootIcon: some View {
        if let url = browser.currentURL {
            if let cloud = Place.iCloudDrive, url.path.hasPrefix(cloud.path) {
                Glyph(symbol: "icloud", color: Theme.accent, size: 18)
            } else {
                Glyph(symbol: "laptopcomputer", color: Theme.brand, size: 18)
            }
        } else {
            LocationIcon(location: browser.location, size: 18)
        }
    }

    private func startEditing() {
        switch browser.location {
        case .folder(let url): pathText = url.path
        default: pathText = browser.title
        }
        editing = true
        DispatchQueue.main.async { fieldFocused = true }
    }
}

struct CrumbButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CrumbBody(configuration: configuration)
    }

    private struct CrumbBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13.5))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(configuration.isPressed ? Theme.selected : (hovering ? Theme.hover : .clear))
                )
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

struct SearchBox: View {
    @EnvironmentObject private var browser: FileBrowser
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("Search \(browser.title)", text: $browser.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onExitCommand { browser.searchText = "" }
            if !browser.searchText.isEmpty {
                Button { browser.searchText = "" } label: {
                    Image(systemName: "xmark").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondary)
                .help("Clear search")
            }
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.field))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(focused ? Theme.accent : Theme.fieldBorder, lineWidth: 1)
        )
        .onChange(of: browser.focusRequest) {
            if browser.focusRequest == .search {
                browser.focusRequest = nil
                focused = true
            }
        }
    }
}

// MARK: - Command bar

struct CommandBar: View {
    @EnvironmentObject private var browser: FileBrowser
    @ObservedObject private var prefs = Prefs.shared

    private var hasSelection: Bool { !browser.selection.isEmpty }
    private var inFolder: Bool { browser.currentURL != nil }

    var body: some View {
        let selected = browser.selectedItems
        HStack(spacing: 2) {
            DropMenu {
                BarLabel(symbol: "plus.circle", title: "New", chevron: true)
            } content: { close in
                MenuRow(title: "Folder", icon: AnyView(FolderIcon(size: 16)), shortcut: "⇧⌘N") {
                    close(); browser.create(.folder)
                }
                MenuSeparator()
                MenuRow(title: "Rich Text Document", symbol: "doc.richtext") { close(); browser.create(.richText) }
                MenuRow(title: "Text Document", symbol: "doc.text") { close(); browser.create(.text) }
                MenuRow(title: "Compressed (zipped) Folder", symbol: "doc.zipper") { close(); browser.create(.zip) }
            }
            .disabled(!inFolder)
            .help("Create a new item in the current location")

            BarDivider()

            IconCommand(symbol: "scissors", help: "Cut (⌘X)", enabled: hasSelection) {
                browser.copy(browser.selection, cut: true)
            }
            IconCommand(symbol: "doc.on.doc", help: "Copy (⌘C)", enabled: hasSelection) {
                browser.copy(browser.selection)
            }
            IconCommand(symbol: "doc.on.clipboard", help: "Paste (⌘V)", enabled: browser.canPaste()) {
                browser.paste()
            }
            IconCommand(symbol: "character.textbox", help: "Rename (F2)", enabled: browser.selection.count == 1) {
                if let url = browser.selection.first { browser.beginRename(url) }
            }
            ShareLink(items: Array(browser.selection)) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 14))
                    .frame(width: 38, height: 34)
            }
            .buttonStyle(BarButtonStyle())
            .disabled(!hasSelection)
            .help("Share")
            IconCommand(symbol: "trash", help: "Delete (⌘⌫)", enabled: hasSelection) {
                browser.requestTrash(browser.selection)
            }
            AirDropButton(enabled: hasSelection) {
                browser.airDrop(browser.selection)
            }
            TagMenuButton(enabled: hasSelection)

            BarDivider()

            DropMenu {
                BarLabel(symbol: "arrow.up.arrow.down", title: "Sort", chevron: true)
            } content: { close in
                ForEach(SortField.allCases) { field in
                    MenuRow(title: field.title, mark: browser.sortField == field ? .bullet : .none) {
                        close(); browser.sortField = field
                    }
                }
                MenuSeparator()
                MenuRow(title: "Ascending", mark: browser.sortAscending ? .bullet : .none) {
                    close(); browser.sortAscending = true
                }
                MenuRow(title: "Descending", mark: browser.sortAscending ? .none : .bullet) {
                    close(); browser.sortAscending = false
                }
                MenuSeparator()
                Text("Group by")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                ForEach(GroupField.allCases) { field in
                    MenuRow(title: field.title, mark: browser.groupBy == field ? .bullet : .none) {
                        close(); browser.groupBy = field
                    }
                }
            }
            .disabled(!inFolder)
            .help("Sort and group options")

            DropMenu {
                BarLabel(symbol: browser.viewMode.symbol, title: "View", chevron: true)
            } content: { close in
                ForEach(Array(ViewMode.allCases.enumerated()), id: \.element) { index, mode in
                    MenuRow(title: mode.title, symbol: mode.symbol, mark: browser.viewMode == mode ? .bullet : .none,
                            shortcut: "⇧⌘\(index + 1)") {
                        close(); browser.viewMode = mode
                    }
                }
                MenuSeparator()
                MenuRow(title: "Compact view", symbol: "rectangle.compress.vertical", mark: prefs.compact ? .check : .none) {
                    close(); prefs.compact.toggle()
                }
                MenuSeparator()
                Text("Show")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                MenuRow(title: "Navigation pane", symbol: "sidebar.left", mark: prefs.showNavPane ? .check : .none) {
                    close(); prefs.showNavPane.toggle()
                }
                MenuRow(title: "Details pane", symbol: "sidebar.right", mark: prefs.sidePane == .details ? .check : .none,
                        shortcut: "⌥⇧P") {
                    close(); prefs.sidePane = prefs.sidePane == .details ? .none : .details
                }
                MenuRow(title: "Preview pane", symbol: "eye", mark: prefs.sidePane == .preview ? .check : .none,
                        shortcut: "⌥P") {
                    close(); prefs.sidePane = prefs.sidePane == .preview ? .none : .preview
                }
                MenuRow(title: "Item check boxes", symbol: "checkmark.square", mark: prefs.showCheckboxes ? .check : .none) {
                    close(); prefs.showCheckboxes.toggle()
                }
                MenuRow(title: "File name extensions", symbol: "doc.badge.ellipsis", mark: prefs.showExtensions ? .check : .none) {
                    close(); prefs.showExtensions.toggle()
                }
                MenuRow(title: "Hidden items", symbol: "eye.slash", mark: prefs.showHidden ? .check : .none, shortcut: "⇧⌘.") {
                    close(); prefs.showHidden.toggle()
                }
                MenuSeparator()
                Text("Customise")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                AccentSwatches()
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
            .help("Layout and view options")

            contextualCommands(selected)

            BarDivider()

            DropMenu {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 38, height: 34)
            } content: { close in
                if let title = FileOps.shared.undoTitle {
                    MenuRow(title: title, symbol: "arrow.uturn.backward", shortcut: "⌘Z") { close(); browser.undo() }
                    MenuSeparator()
                }
                if let url = browser.currentURL {
                    MenuRow(title: PinStore.shared.isPinned(url) ? "Unpin from sidebar" : "Pin to sidebar",
                            symbol: "pin") { close(); PinStore.shared.toggle(url) }
                    MenuSeparator()
                }
                MenuRow(title: "Select all", symbol: "checkmark.square", shortcut: "⌘A") { close(); browser.selectAll() }
                MenuRow(title: "Select none", symbol: "square") { close(); browser.selectNone() }
                MenuRow(title: "Invert selection", symbol: "square.lefthalf.filled") { close(); browser.invertSelection() }
                MenuSeparator()
                if let url = browser.currentURL {
                    MenuRow(title: "Copy as path", symbol: "link", shortcut: "⇧⌘C") {
                        close(); browser.copyPath(browser.selection.isEmpty ? [url] : browser.selection)
                    }
                    MenuRow(title: "Open in Terminal", symbol: "terminal") { close(); browser.openInTerminal(url) }
                    MenuRow(title: "Open in Finder", symbol: "macwindow") { close(); NSWorkspace.shared.open(url) }
                }
                MenuRow(title: "Properties", symbol: "wrench.and.screwdriver", shortcut: "⌘I") {
                    close(); browser.showProperties(browser.selection)
                }
                MenuRow(title: "Options", symbol: "gearshape") { close(); OptionsWindow.show() }
            }
            .help("See more")

            Spacer()

            Button {
                prefs.sidePane = prefs.sidePane == .details ? .none : .details
            } label: {
                BarLabel(symbol: "sidebar.right", title: "Details", chevron: false)
            }
            .buttonStyle(BarButtonStyle(active: prefs.sidePane == .details))
            .help("Show the details pane (⌥⇧P)")
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .background(Theme.chrome)
    }

    /// Extra buttons Explorer adds for the selected kind of file.
    @ViewBuilder private func contextualCommands(_ selected: [FileItem]) -> some View {
        if selected.count == 1, let zip = selected.first, zip.isZip {
            BarDivider()
            Button { browser.extract(zip.url) } label: {
                BarLabel(symbol: "arrow.up.bin", title: "Extract all", chevron: false)
            }
            .buttonStyle(BarButtonStyle())
        } else if !selected.isEmpty, selected.allSatisfy(\.isImage) {
            BarDivider()
            if selected.count == 1, let image = selected.first {
                Button { browser.setAsDesktopBackground(image.url) } label: {
                    BarLabel(symbol: "photo.on.rectangle", title: "Set as background", chevron: false)
                }
                .buttonStyle(BarButtonStyle())
            }
            IconCommand(symbol: "rotate.left", help: "Rotate left", enabled: true) {
                browser.rotate(browser.selection, clockwise: false)
            }
            IconCommand(symbol: "rotate.right", help: "Rotate right", enabled: true) {
                browser.rotate(browser.selection, clockwise: true)
            }
        } else if browser.location == .thisMac, browser.selection.count == 1, let url = browser.selection.first,
                  browser.volumes.first(where: { $0.url == url })?.isRemovable == true {
            BarDivider()
            Button { browser.eject(url) } label: {
                BarLabel(symbol: "eject", title: "Eject", chevron: false)
            }
            .buttonStyle(BarButtonStyle())
        }
    }
}

struct BarLabel: View {
    let symbol: String
    let title: String
    let chevron: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 14))
            Text(title).font(.system(size: 13))
            if chevron {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
    }
}

struct IconCommand: View {
    let symbol: String
    let help: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .frame(width: 38, height: 34)
        }
        .buttonStyle(BarButtonStyle())
        .disabled(!enabled)
        .help(help)
    }
}

/// AirDrop button drawn as a line icon, so it takes the toolbar's colours like the other icons.
struct AirDropButton: View {
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AirDropGlyph()
                .frame(width: 17, height: 17)
                .frame(width: 38, height: 34)
        }
        .buttonStyle(BarButtonStyle())
        .disabled(!enabled)
        .help("AirDrop")
    }
}

/// The AirDrop mark: a dot inside three rings that open at the bottom.
struct AirDropGlyph: View {
    var lineWidth: CGFloat = 1.4

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            // Three rings, each open at the bottom (on screen 90° points straight down).
            let gap = 46.0 * .pi / 180
            for fraction in [0.16, 0.31, 0.46] {
                let radius = side * fraction
                let start = Double.pi / 2 + gap / 2   // left edge of the bottom gap, then round over the top
                let sweep = 2 * Double.pi - gap
                var ring = Path()
                let steps = 48
                for step in 0...steps {
                    let angle = start + sweep * Double(step) / Double(steps)
                    let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
                    if step == 0 { ring.move(to: point) } else { ring.addLine(to: point) }
                }
                context.stroke(ring, with: .style(.foreground), style: style)
            }
            let dot = side * 0.065
            context.fill(Path(ellipseIn: CGRect(x: center.x - dot, y: center.y - dot, width: dot * 2, height: dot * 2)),
                         with: .style(.foreground))
        }
    }
}

struct BarDivider: View {
    var body: some View {
        Rectangle().fill(Theme.divider).frame(width: 1, height: 26).padding(.horizontal, 6)
    }
}

/// Flat Windows-style button: no border, soft highlight on hover, dimmed when disabled.
struct BarButtonStyle: ButtonStyle {
    var corner: CGFloat = 5
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        BarBody(configuration: configuration, corner: corner, active: active)
    }

    private struct BarBody: View {
        let configuration: ButtonStyleConfiguration
        let corner: CGFloat
        let active: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(isEnabled ? Theme.text : Theme.tertiary)
                .background(
                    RoundedRectangle(cornerRadius: corner)
                        .fill(configuration.isPressed ? Theme.selected
                              : (active ? Theme.selected : (hovering && isEnabled ? Theme.hover : .clear)))
                )
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Flyout menus

/// A button that opens a Windows-style flyout menu.
struct DropMenu<Label: View, Content: View>: View {
    private let label: Label
    private let content: (@escaping () -> Void) -> Content
    @State private var open = false
    @ObservedObject private var prefs = Prefs.shared

    init(@ViewBuilder label: () -> Label, @ViewBuilder content: @escaping (@escaping () -> Void) -> Content) {
        self.label = label()
        self.content = content
    }

    var body: some View {
        Button { open.toggle() } label: { label }
            .buttonStyle(BarButtonStyle(active: open))
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    content { open = false }
                }
                .padding(5)
                .frame(minWidth: 250, alignment: .leading)
                .foregroundStyle(Theme.text)
                .preferredColorScheme(prefs.colorScheme)
            }
    }
}

enum MenuMark { case none, check, bullet }

/// Customise: one round swatch per accent colour; the chosen one has a ring and a tick.
struct AccentSwatches: View {
    @ObservedObject private var prefs = Prefs.shared
    var size: CGFloat = 22

    var body: some View {
        HStack(spacing: 8) {
            ForEach(AccentColor.allCases) { colour in
                let chosen = prefs.accent == colour
                Button { prefs.accent = colour } label: {
                    Circle()
                        .fill(Color(nsColor: Theme.nsColor(colour.icon)))
                        .frame(width: size, height: size)
                        .overlay {
                            if chosen {
                                Image(systemName: "checkmark").font(.system(size: size * 0.45, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .padding(3)
                        .overlay(Circle().strokeBorder(chosen ? Theme.text : .clear, lineWidth: 1.5))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(colour == .green ? "Green (default)" : colour.title)
                .accessibilityLabel(colour.title)
            }
        }
    }
}

struct MenuRow: View {
    let title: String
    var symbol: String?
    var icon: AnyView?
    var mark: MenuMark = .none
    var shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    init(title: String, symbol: String? = nil, icon: AnyView? = nil, mark: MenuMark = .none,
         shortcut: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.icon = icon
        self.mark = mark
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    switch mark {
                    case .check: Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                    case .bullet: Circle().frame(width: 6, height: 6)
                    case .none: Color.clear
                    }
                }
                .frame(width: 14)
                Group {
                    if let icon { icon } else if let symbol { Image(systemName: symbol).font(.system(size: 13)) } else { Color.clear }
                }
                .frame(width: 18)
                Text(title).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 20)
                if let shortcut {
                    Text(shortcut).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 4).fill(hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct MenuSeparator: View {
    var body: some View {
        Rectangle().fill(Theme.divider).frame(height: 1).padding(.vertical, 4)
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @EnvironmentObject private var browser: FileBrowser
    @ObservedObject private var ops = FileOps.shared

    var body: some View {
        HStack(spacing: 10) {
            Text(countText)
            if !browser.selection.isEmpty {
                Text("|").foregroundStyle(Theme.tertiary)
                Text(selectionText)
            }
            if browser.isSearching {
                Text("|").foregroundStyle(Theme.tertiary)
                ProgressView().controlSize(.mini)
                Text("Searching…")
            }
            Spacer()
            if let notice = FileOps.shared.notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                    .transition(.opacity)
            }
            ViewToggle(mode: .details, symbol: "list.bullet.rectangle", help: "Display information about each item in the window")
            ViewToggle(mode: .largeIcons, symbol: "rectangle.grid.2x2", help: "Display items by using large thumbnails")
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.secondary)
        .animation(.easeOut(duration: 0.2), value: ops.notice)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(Theme.content)
    }

    private var countText: String {
        if browser.location == .thisMac && browser.searchQuery.isEmpty {
            // Only real drives count; disk images live inside Macintosh HD.
            let drives = browser.volumes.filter { !$0.isDiskImage }.count
            return drives == 1 ? "1 item" : "\(drives) items"
        }
        if browser.location == .allTags {
            let tags = TagStore.shared.tags.count
            return tags == 1 ? "1 tag" : "\(tags) tags"
        }
        let count = browser.visibleCount
        return count == 1 ? "1 item" : "\(count) items"
    }

    private var selectionText: String {
        let selected = browser.selectedItems
        var text = browser.selection.count == 1 ? "1 item selected" : "\(browser.selection.count) items selected"
        let bytes = selected.filter { $0.size > 0 }.reduce(Int64(0)) { $0 + $1.size }
        if bytes > 0 { text += "  \(WinFormat.friendly(bytes))" }
        return text
    }
}

struct ViewToggle: View {
    @EnvironmentObject private var browser: FileBrowser
    let mode: ViewMode
    let symbol: String
    let help: String

    var body: some View {
        Button { browser.viewMode = mode } label: {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 24, height: 22)
        }
        .buttonStyle(BarButtonStyle(corner: 3, active: browser.viewMode == mode))
        .help(help)
    }
}

// MARK: - Copy progress (like the Windows "Copying…" window)

struct ProgressCard: View {
    let progress: TransferProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(progress.title)
                    .font(.system(size: 12.5))
                    .lineLimit(2)
                Spacer()
                Button { FileOps.shared.cancelTransfer() } label: {
                    Image(systemName: "xmark").font(.system(size: 11)).frame(width: 24, height: 24)
                }
                .buttonStyle(BarButtonStyle(corner: 4))
                .help("Cancel")
            }
            Text("\(Int(progress.fraction * 100))% complete")
                .font(.system(size: 16, weight: .semibold))
            ProgressView(value: progress.fraction)
                .tint(Theme.accent)
            Text(progress.currentName.isEmpty ? "Calculating…" : "Name: \(progress.currentName)")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(16)
        .frame(width: 380)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.chrome))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.divider))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
    }
}

// MARK: - Icons

struct Glyph: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 16

    var body: some View {
        Image(systemName: symbol)
            .resizable()
            .scaledToFit()
            .foregroundStyle(color)
            .frame(width: size * 0.92, height: size * 0.92)
            .frame(width: size, height: size)
    }
}

/// Folders' own folder icon (same shape as the app icon): a darker back panel with a tab
/// and a lighter front panel, drawn here at any size.
struct FolderIcon: View {
    var size: CGFloat = 16

    var body: some View {
        Canvas { ctx, canvas in
            let w = canvas.width, h = canvas.height
            let top = h * 0.16, bottom = h * 0.86, left = w * 0.06, right = w * 0.94
            let r = w * 0.09
            var back = Path()
            back.move(to: CGPoint(x: left, y: top + r))
            back.addQuadCurve(to: CGPoint(x: left + r, y: top), control: CGPoint(x: left, y: top))
            back.addLine(to: CGPoint(x: w * 0.40, y: top))
            back.addQuadCurve(to: CGPoint(x: w * 0.50, y: top + h * 0.09), control: CGPoint(x: w * 0.46, y: top))
            back.addLine(to: CGPoint(x: right - r, y: top + h * 0.09))
            back.addQuadCurve(to: CGPoint(x: right, y: top + h * 0.09 + r), control: CGPoint(x: right, y: top + h * 0.09))
            back.addLine(to: CGPoint(x: right, y: bottom - r))
            back.addQuadCurve(to: CGPoint(x: right - r, y: bottom), control: CGPoint(x: right, y: bottom))
            back.addLine(to: CGPoint(x: left + r, y: bottom))
            back.addQuadCurve(to: CGPoint(x: left, y: bottom - r), control: CGPoint(x: left, y: bottom))
            back.closeSubpath()
            let base = Theme.nsColor(CurrentAccent.value.icon)
            ctx.fill(back, with: .color(Color(nsColor: base.blended(withFraction: 0.18, of: .black) ?? base)))
            let front = Path(roundedRect: CGRect(x: left, y: top + h * 0.22, width: right - left,
                                                 height: bottom - top - h * 0.22),
                             cornerRadius: r)
            ctx.fill(front, with: .linearGradient(Gradient(colors: [Color(nsColor: base.blended(withFraction: 0.30, of: .white) ?? base),
                                                                    Color(nsColor: base)]),
                                                  startPoint: CGPoint(x: 0, y: top + h * 0.22),
                                                  endPoint: CGPoint(x: 0, y: bottom)))
        }
        .frame(width: size, height: size)
    }
}

struct LocationIcon: View {
    let location: Location
    var size: CGFloat = 16

    var body: some View {
        switch location {
        case .home: Glyph(symbol: "house.fill", color: Theme.brand, size: size)
        case .gallery: Glyph(symbol: "photo.stack.fill", color: Theme.brand, size: size)
        case .thisMac: Glyph(symbol: "laptopcomputer", color: Theme.brand, size: size)
        case .folder(let url): FolderGlyph(url: url, size: size)
        case .tag(let name): TagDot(tag: TagStore.shared.tag(named: name), size: size * 0.7)
        case .allTags: Glyph(symbol: "tag", color: Theme.secondary, size: size)
        }
    }
}

struct FolderGlyph: View {
    let url: URL
    var size: CGFloat = 16

    var body: some View {
        let folder = url.normalizedFolder
        if let place = Place.special(for: folder) {
            Glyph(symbol: place.symbol, color: place.color, size: size)
        } else if folder == Place.iCloudDrive {
            Glyph(symbol: "icloud.fill", color: Theme.brand, size: size)
        } else if folder.path == "/" {
            Glyph(symbol: "internaldrive.fill", color: Color(hex: 0x9AA6B2), size: size)
        } else if DiskImages.imageFile(forMountPoint: folder.path) != nil {
            Glyph(symbol: "opticaldisc.fill", color: Color(hex: 0x9AA6B2), size: size)
        } else if folder.deletingLastPathComponent().path == "/Volumes" {
            Glyph(symbol: "externaldrive.fill", color: Color(hex: 0x9AA6B2), size: size)
        } else {
            FolderIcon(size: size)
        }
    }
}

struct ItemIcon: View {
    let item: FileItem
    let size: CGFloat

    var body: some View {
        if item.isDirectory {
            if DiskImages.imageFile(forMountPoint: item.url.path) != nil {
                FolderGlyph(url: item.url, size: size)
            } else {
                FolderIcon(size: size)
            }
        } else if size >= 40 {
            ThumbnailImage(url: item.url, size: size)
        } else {
            Image(nsImage: item.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        }
    }
}

struct ThumbnailImage: View {
    let url: URL
    let size: CGFloat
    var fill = false
    @State private var image: NSImage?

    var body: some View {
        Group {
            if fill {
                Image(nsImage: image ?? IconCache.shared.icon(for: url))
                    .resizable()
                    .aspectRatio(contentMode: image == nil ? .fit : .fill)
                    .frame(width: size, height: size)
                    .clipped()
            } else {
                Image(nsImage: image ?? IconCache.shared.icon(for: url))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
            }
        }
        .task(id: url) {
            image = await ThumbnailCache.shared.thumbnail(for: url, size: size)
        }
    }
}
