import AppKit
import Quartz
import SwiftUI

@main
struct MyMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var app = AppState.shared

    var body: some Scene {
        Window("Folders", id: "main") {
            ContentView()
                .environmentObject(app)
                .frame(minWidth: 900, minHeight: 520)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        .commands { AppCommands(app: app, prefs: Prefs.shared, ops: FileOps.shared) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var testedWindow: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        Prefs.shared.applyAppearance()
        NSApp.activate(ignoringOtherApps: true)
        let env = ProcessInfo.processInfo.environment
        if let dir = env["MYMAC_SELFTEST"] {
            Task { await SelfTest.run(in: URL(fileURLWithPath: dir)) }
        } else {
            debugSnapshotIfRequested(env)
            testMinimizeIfRequested(env)
        }
    }

    // The app delegate is at the end of the responder chain, so it owns the Quick Look panel.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = QuickLook.shared
            panel.delegate = QuickLook.shared
        }
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}

    /// Like Windows: closing the window quits the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func testMinimizeIfRequested(_ env: [String: String]) {
        // MYMAC_TEST_MINIMIZE=windowed|fullscreen: puts the window in that state, presses Minimize, reports.
        guard let mode = env["MYMAC_TEST_MINIMIZE"] else { return }
        let wantFull = mode == "fullscreen"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            NSApp.activate(ignoringOtherApps: true)
            if let w = WindowActions.mainWindow, w.styleMask.contains(.fullScreen) != wantFull { w.toggleFullScreen(nil) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
            let w = WindowActions.mainWindow
            AppDelegate.testedWindow = w
            print("MINIMIZE \(mode) before: fullScreen=\(w?.styleMask.contains(.fullScreen) ?? false) active=\(NSApp.isActive) button=\(w?.standardWindowButton(.miniaturizeButton) != nil) windows=\(NSApp.windows.map { String(describing: type(of: $0)) })")
            WindowActions.minimize()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
            let w = AppDelegate.testedWindow
            print("MINIMIZE \(mode) result: miniaturized=\(w?.isMiniaturized ?? false) visible=\(w?.isVisible ?? false) mask=\(w?.styleMask.rawValue ?? 0) titled=\(w?.styleMask.contains(.titled) ?? false) delegate=\(w?.delegate.map { String(describing: type(of: $0)) } ?? "nil")")
            w?.deminiaturize(nil)
            if w?.styleMask.contains(.fullScreen) == true { w?.toggleFullScreen(nil) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) }
        }
    }

    /// Development aid: MYMAC_SNAPSHOT=/path.png saves a picture of the window, then quits.
    private func debugSnapshotIfRequested(_ env: [String: String]) {
        guard let output = env["MYMAC_SNAPSHOT"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let browser = AppState.shared.current
            if let theme = env["MYMAC_THEME"], let t = AppTheme(rawValue: theme) { Prefs.shared.theme = t }
            if let start = env["MYMAC_START"] { browser.goTo(path: start) }
            if let view = env["MYMAC_VIEW"], let mode = ViewMode(rawValue: view) { browser.viewMode = mode }
            if let pane = env["MYMAC_PANE"], let p = SidePane(rawValue: pane) { Prefs.shared.sidePane = p }
            if let query = env["MYMAC_SEARCH"] { browser.searchText = query; browser.updateSearch() }
            if env["MYMAC_SELECT_FIRST"] != nil { browser.moveSelection(by: 1) }
            if env["MYMAC_PROPERTIES"] != nil { browser.showProperties(browser.selection) }
        }
        // MYMAC_RIGHTCLICK="x,y" (from the window's top-left) sends a real right-click there;
        // MYMAC_SUBMENU=n then opens the flyout of the n-th line.
        if let spot = env["MYMAC_RIGHTCLICK"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                let parts = spot.split(separator: ",").compactMap { Double($0) }
                guard parts.count == 2, let window = NSApp.windows.first(where: { $0.isVisible && !($0 is MenuPanel) }),
                      let view = window.contentView else { return }
                let local = NSPoint(x: parts[0], y: view.isFlipped ? parts[1] : view.bounds.height - parts[1])
                let inWindow = view.convert(local, to: nil)
                if let event = NSEvent.mouseEvent(with: .rightMouseDown, location: inWindow, modifierFlags: [],
                                                  timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                  eventNumber: 0, clickCount: 1, pressure: 1) {
                    let consumed = RightClickTargets.shared.handle(event) == nil
                    print("RIGHTCLICK consumed=\(consumed) open=\(WinMenu.shared.isOpen) lines=\(WinMenu.shared.root.map(\.title))")
                }
                if let n = env["MYMAC_SUBMENU"].flatMap(Int.init), WinMenu.shared.root.indices.contains(n) {
                    let entries = WinMenu.shared.root
                    WinMenu.shared.hover(entries[n], y: 4 + entries[..<n].reduce(0) { $0 + $1.height })
                    WinMenu.shared.freezeFlyout = true
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            let windows = NSApp.windows.filter(\.isVisible).sorted { $0.frame.width > $1.frame.width }
            for (i, window) in windows.prefix(2).enumerated() {
                guard let view = window.contentView?.superview ?? window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let path = i == 0 ? output : output.replacingOccurrences(of: ".png", with: "-sheet.png")
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            if let panel = NSApp.windows.first(where: { $0 is MenuPanel && $0.isVisible }), let view = panel.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: output.replacingOccurrences(of: ".png", with: "-menu.png")))
            }
            if let sheet = NSApp.windows.first(where: { $0.isSheet }), let view = sheet.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: output.replacingOccurrences(of: ".png", with: "-sheet.png")))
            }
            exit(0)
        }
    }
}

/// Menu bar commands with Windows-style shortcuts (Ctrl → ⌘).
struct AppCommands: Commands {
    @ObservedObject var app: AppState
    @ObservedObject var prefs: Prefs
    @ObservedObject var ops: FileOps
    private var browser: FileBrowser { app.current }

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Folder Options…") { OptionsWindow.show() }
                .keyboardShortcut(",")
        }

        CommandGroup(replacing: .newItem) {
            Button("New Tab") { app.newTab() }
                .keyboardShortcut("t")
            Button("New Folder") { browser.create(.folder) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(browser.currentURL == nil)
            Button("New Text Document") { browser.create(.text) }
                .disabled(browser.currentURL == nil)
            Divider()
            Button("Open") { browser.openSelection() }
                .keyboardShortcut("o")
                .disabled(browser.selection.isEmpty)
            Button("Open in New Tab") {
                for url in browser.selection where FileBrowser.isFolder(url) { app.newTab(.folder(url)) }
            }
            .disabled(browser.selection.isEmpty)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") { app.closeCurrent() }
                .keyboardShortcut("w")
        }

        CommandGroup(replacing: .undoRedo) {
            Button(ops.undoTitle ?? "Undo") {
                textEdit(Selector(("undo:"))) { browser.undo() }
            }
            .keyboardShortcut("z")
        }

        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { textEdit(#selector(NSText.cut(_:))) { browser.copy(browser.selection, cut: true) } }
                .keyboardShortcut("x")
            Button("Copy") { textEdit(#selector(NSText.copy(_:))) { browser.copy(browser.selection) } }
                .keyboardShortcut("c")
            Button("Paste") { textEdit(#selector(NSText.paste(_:))) { browser.paste() } }
                .keyboardShortcut("v")
            Button("Copy as Path") { browser.copyPath(browser.selection.isEmpty ? Set(browser.currentURL.map { [$0] } ?? []) : browser.selection) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Divider()
            Button("Select All") { textEdit(#selector(NSText.selectAll(_:))) { browser.selectAll() } }
                .keyboardShortcut("a")
            Button("Select None") { browser.selectNone() }
            Button("Invert Selection") { browser.invertSelection() }
            Divider()
            Button("Rename") {
                if let url = browser.selection.first { browser.beginRename(url) }
            }
            .disabled(browser.selection.count != 1)
            Button("Delete") {
                textEdit(#selector(NSResponder.deleteToBeginningOfLine(_:))) { browser.trash(browser.selection) }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            Button("Delete Permanently…") { browser.requestPermanentDelete(browser.selection) }
                .keyboardShortcut(.delete, modifiers: [.command, .option])
            Divider()
            Button("Compress to ZIP File") { browser.compress(browser.selection) }
                .disabled(browser.selection.isEmpty)
            Button("Extract All") {
                if let zip = browser.selection.first(where: { $0.pathExtension.lowercased() == "zip" }) { browser.extract(zip) }
            }
            .disabled(!browser.selection.contains { $0.pathExtension.lowercased() == "zip" })
            Divider()
            Button("Properties") { browser.showProperties(browser.selection) }
                .keyboardShortcut("i")
        }

        CommandGroup(after: .toolbar) {
            ForEach(Array(ViewMode.allCases.enumerated()), id: \.element) { index, mode in
                Button(mode.title) { browser.viewMode = mode }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .shift])
            }
            Divider()
            Toggle("Compact View", isOn: $prefs.compact)
            Toggle("Navigation Pane", isOn: $prefs.showNavPane)
            Toggle("Details Pane", isOn: Binding(get: { prefs.sidePane == .details },
                                                 set: { prefs.sidePane = $0 ? .details : .none }))
                .keyboardShortcut("p", modifiers: [.option, .shift])
            Toggle("Preview Pane", isOn: Binding(get: { prefs.sidePane == .preview },
                                                 set: { prefs.sidePane = $0 ? .preview : .none }))
                .keyboardShortcut("p", modifiers: [.option])
            Toggle("Item Check Boxes", isOn: $prefs.showCheckboxes)
            Toggle("File Name Extensions", isOn: $prefs.showExtensions)
            Toggle("Hidden Items", isOn: $prefs.showHidden)
                .keyboardShortcut(".", modifiers: [.command, .shift])
            Picker("Theme", selection: $prefs.theme) {
                ForEach(AppTheme.allCases) { Text($0.title).tag($0) }
            }
            Divider()
            Button("Next Tab") { app.selectNext(1) }
                .keyboardShortcut(.tab, modifiers: .control)
            Button("Previous Tab") { app.selectNext(-1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            ForEach(1..<10) { n in
                Button("Tab \(n)") { app.select(index: n == 9 ? app.tabs.count - 1 : n - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
            }
            Divider()
        }

        CommandMenu("Go") {
            Button("Back") { browser.goBack() }
                .keyboardShortcut("[")
                .disabled(!browser.canGoBack)
            Button("Forward") { browser.goForward() }
                .keyboardShortcut("]")
                .disabled(!browser.canGoForward)
            Button("Up") { browser.goUp() }
                .keyboardShortcut(.upArrow)
                .disabled(!browser.canGoUp)
            Divider()
            Button("Home") { browser.go(to: .home) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Gallery") { browser.go(to: .gallery) }
            Button("This Mac") { browser.go(to: .thisMac) }
            ForEach(Place.standard) { place in
                Button(place.name) { browser.go(to: .folder(place.url)) }
            }
            Divider()
            Button("Address Bar") { browser.focusRequest = .address }
                .keyboardShortcut("l")
            Button("Search") { browser.focusRequest = .search }
                .keyboardShortcut("f")
            Button("Search ") { browser.focusRequest = .search }
                .keyboardShortcut("e")
            Divider()
            Button("Refresh") { browser.reload() }
                .keyboardShortcut("r")
        }
    }

    /// When a text field is being edited, let ⌘C/⌘V etc. work on its text instead of on files.
    private func textEdit(_ selector: Selector, otherwise action: () -> Void) {
        if NSApp.keyWindow?.firstResponder is NSText {
            NSApp.sendAction(selector, to: nil, from: nil)
        } else {
            action()
        }
    }
}
