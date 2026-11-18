import AppKit
import SwiftUI

/// The right-click menus, laid out like Windows 11 File Explorer.
@MainActor
enum Menus {
    typealias Built = (main: [WinMenuEntry], classic: [WinMenuEntry]?)

    private static let folderTint = Color(hex: 0xF7C64F)

    // MARK: Files and folders

    static func items(_ browser: FileBrowser, _ urls: Set<URL>) -> Built {
        guard let first = urls.sorted(by: { $0.path < $1.path }).first else { return background(browser) }
        let single = urls.count == 1
        let isFolder = single && FileBrowser.isFolder(first)
        let allFolders = urls.allSatisfy(FileBrowser.isFolder)
        let item = FileItem(url: first)
        let list = Array(urls)

        var main: [WinMenuEntry] = [
            .toolbar([
                WinToolButton(symbol: "scissors", help: "Cut (⌘X)") { browser.copy(urls, cut: true) },
                WinToolButton(symbol: "doc.on.doc", help: "Copy (⌘C)") { browser.copy(urls) },
                WinToolButton(symbol: "character.cursor.ibeam", help: "Rename (F2)", enabled: single) { browser.beginRename(first) },
                WinToolButton(symbol: "square.and.arrow.up", help: "Share") { WinMenu.shared.share(list) },
                WinToolButton(symbol: "trash", help: "Delete (⌘⌫)") { browser.trash(urls) },
            ]),
        ]

        if isFolder {
            main += [
                .item("Open", "folder", shortcut: "↩") { browser.open(urls) },
                .item("Open in new tab", "plus.rectangle.on.rectangle") { AppState.shared.newTab(.folder(first)) },
                .item(PinStore.shared.isPinned(first) ? "Unpin from sidebar" : "Pin to sidebar", "pin") {
                    PinStore.shared.toggle(first)
                },
            ]
        } else {
            let appIcon = OpenWith.defaultApp(for: first).map { IconCache.shared.icon(for: $0) }
            main.append(.item("Open", appIcon == nil ? "arrow.up.forward.app" : nil, shortcut: "↩", image: appIcon) {
                browser.open(urls)
            })
            if single { main.append(openWith(browser, first)) }
            if single && item.isImage {
                main += [
                    .item("Set as desktop background", "photo.on.rectangle") { browser.setAsDesktopBackground(first) },
                    .item("Rotate right", "rotate.right") { browser.rotate(urls, clockwise: true) },
                    .item("Rotate left", "rotate.left") { browser.rotate(urls, clockwise: false) },
                ]
            }
            if single && item.isZip {
                main.append(.item("Extract All…", "archivebox") { browser.extract(first) })
            }
            if single {
                main.append(.item(PinStore.shared.isFavorite(first) ? "Remove from Favorites" : "Add to Favorites", "star") {
                    PinStore.shared.toggleFavorite(first)
                })
            }
        }
        main += [
            .item("Compress to ZIP file", "doc.zipper") { browser.compress(urls) },
            .item("Copy as path", "doc.on.clipboard", shortcut: "⇧⌘C") { browser.copyPath(urls) },
            .item("Properties", "wrench.adjustable", shortcut: "⌘I") { browser.showProperties(urls) },
        ]
        if isFolder {
            main += [.separator, .item("Open in Terminal", "terminal") { browser.openInTerminal(first) }]
        }
        main += [.separator, showMore]

        // Classic menu: everything, including Mac extras.
        var classic: [WinMenuEntry] = [.item("Open") { browser.open(urls) }]
        if isFolder {
            classic.append(.item("Open in new tab") { AppState.shared.newTab(.folder(first)) })
        } else if single {
            classic.append(openWith(browser, first))
        }
        if single && item.isZip { classic.append(.item("Extract All…") { browser.extract(first) }) }
        if single && item.isImage {
            classic += [
                .item("Set as desktop background") { browser.setAsDesktopBackground(first) },
                .item("Rotate right") { browser.rotate(urls, clockwise: true) },
                .item("Rotate left") { browser.rotate(urls, clockwise: false) },
            ]
        }
        classic += [.separator]
        if allFolders {
            classic.append(.item(PinStore.shared.isPinned(first) ? "Unpin from sidebar" : "Pin to sidebar") {
                PinStore.shared.toggle(first)
            })
        }
        classic += [
            .item("Compress to ZIP file") { browser.compress(urls) },
            .item("Copy as path") { browser.copyPath(urls) },
            .item("Share…") { WinMenu.shared.share(list) },
            .item("Show in Finder") { browser.revealInFinder(urls) },
            .separator,
            .item("Cut") { browser.copy(urls, cut: true) },
            .item("Copy") { browser.copy(urls) },
            .separator,
            .item("Rename", enabled: single) { browser.beginRename(first) },
            .item("Delete") { browser.trash(urls) },
            .item("Delete permanently…") { browser.requestPermanentDelete(urls) },
            .separator,
            .item("Properties") { browser.showProperties(urls) },
        ]
        return (main, classic)
    }

    private static func openWith(_ browser: FileBrowser, _ url: URL) -> WinMenuEntry {
        let apps = OpenWith.apps(for: url)
        var entries: [WinMenuEntry] = apps.prefix(12).map { app in
            .item(OpenWith.name(of: app), image: IconCache.shared.icon(for: app)) { browser.open([url], with: app) }
        }
        if !entries.isEmpty { entries.append(.separator) }
        entries.append(.item("Choose another app", "magnifyingglass") { browser.chooseAppToOpen([url]) })
        return .submenu("Open with", "square.grid.2x2", entries)
    }

    private static var showMore: WinMenuEntry {
        .item("More options", "arrow.up.forward.square") { WinMenu.shared.showMoreOptions() }
    }

    // MARK: Empty space in a folder

    static func background(_ browser: FileBrowser) -> Built {
        let inFolder = browser.currentURL != nil
        var main: [WinMenuEntry] = [
            .submenu("View", "square.grid.2x2", viewEntries(browser)),
            .submenu("Sort by", "arrow.up.arrow.down", sortEntries(browser)),
            .submenu("Group by", "rectangle.grid.1x2", groupEntries(browser)),
            .separator,
        ]
        if let undo = FileOps.shared.undoTitle {
            main.append(.item(undo, "arrow.uturn.backward", shortcut: "⌘Z") { browser.undo() })
        }
        main.append(.item("Refresh", "arrow.clockwise", shortcut: "⌘R") { browser.reload() })
        if inFolder {
            main.append(.item("Paste", "doc.on.clipboard", shortcut: "⌘V", enabled: browser.canPaste()) { browser.paste() })
            main += [.separator, .submenu("New", "plus.circle", newEntries(browser))]
        }
        main += [.separator, .item("Properties", "wrench.adjustable", shortcut: "⌘I", enabled: inFolder) {
            browser.showProperties([])
        }]
        if let url = browser.currentURL {
            main += [.separator, .item("Open in Terminal", "terminal") { browser.openInTerminal(url) }]
        }
        main += [.separator, showMore]

        var classic: [WinMenuEntry] = [
            .submenu("View", nil, viewEntries(browser)),
            .submenu("Sort by", nil, sortEntries(browser)),
            .submenu("Group by", nil, groupEntries(browser)),
            .item("Refresh") { browser.reload() },
            .separator,
            .item("Paste", enabled: browser.canPaste()) { browser.paste() },
        ]
        if let undo = FileOps.shared.undoTitle { classic.append(.item(undo) { browser.undo() }) }
        if let url = browser.currentURL {
            classic += [
                .separator,
                .submenu("New", nil, newEntries(browser)),
                .separator,
                .item(PinStore.shared.isPinned(url) ? "Unpin from sidebar" : "Pin to sidebar") { PinStore.shared.toggle(url) },
                .item("Open in Terminal") { browser.openInTerminal(url) },
                .item("Open in Finder") { NSWorkspace.shared.open(url) },
                .separator,
                .item("Properties") { browser.showProperties([]) },
            ]
        }
        return (main, classic)
    }

    static func viewEntries(_ browser: FileBrowser) -> [WinMenuEntry] {
        var entries: [WinMenuEntry] = ViewMode.allCases.map { mode in
            .item(mode.title, mode.symbol, radio: browser.viewMode == mode) { browser.viewMode = mode }
        }
        entries += [.separator, .item("Compact view", "arrow.up.and.down.text.horizontal", radio: Prefs.shared.compact) {
            Prefs.shared.compact.toggle()
        }]
        return entries
    }

    static func sortEntries(_ browser: FileBrowser) -> [WinMenuEntry] {
        var entries: [WinMenuEntry] = SortField.allCases.map { field in
            .item(field.title, radio: browser.sortField == field) { browser.sortField = field }
        }
        entries += [
            .separator,
            .item("Ascending", radio: browser.sortAscending) { browser.sortAscending = true },
            .item("Descending", radio: !browser.sortAscending) { browser.sortAscending = false },
        ]
        return entries
    }

    static func groupEntries(_ browser: FileBrowser) -> [WinMenuEntry] {
        GroupField.allCases.map { field in
            .item(field.title, radio: browser.groupBy == field) { browser.groupBy = field }
        }
    }

    static func newEntries(_ browser: FileBrowser) -> [WinMenuEntry] {
        [
            .item("Folder", "folder.fill", tint: folderTint) { browser.create(.folder) },
            .separator,
            .item("Rich Text Document", "doc.richtext") { browser.create(.richText) },
            .item("Text Document", "doc.text") { browser.create(.text) },
            .item("Compressed (zipped) Folder", "doc.zipper") { browser.create(.zip) },
        ]
    }

    // MARK: Sidebar folders, Quick access tiles, drives, tabs

    static func folderLink(_ browser: FileBrowser, _ url: URL) -> Built {
        let main: [WinMenuEntry] = [
            .toolbar([
                WinToolButton(symbol: "doc.on.doc", help: "Copy (⌘C)") { browser.copy([url]) },
                WinToolButton(symbol: "square.and.arrow.up", help: "Share") { WinMenu.shared.share([url]) },
            ]),
            .item("Open", "folder", shortcut: "↩") { browser.go(to: .folder(url)) },
            .item("Open in new tab", "plus.rectangle.on.rectangle") { AppState.shared.newTab(.folder(url)) },
            .item(PinStore.shared.isPinned(url) ? "Unpin from sidebar" : "Pin to sidebar", "pin") {
                PinStore.shared.toggle(url)
            },
            .item("Compress to ZIP file", "doc.zipper") { browser.compress([url]) },
            .item("Copy as path", "doc.on.clipboard", shortcut: "⇧⌘C") { browser.copyPath([url]) },
            .item("Properties", "wrench.adjustable", shortcut: "⌘I") { browser.propertiesTarget = PropertiesTarget(urls: [url]) },
            .separator,
            .item("Open in Terminal", "terminal") { browser.openInTerminal(url) },
            .separator,
            showMore,
        ]
        let classic: [WinMenuEntry] = [
            .item("Open") { browser.go(to: .folder(url)) },
            .item("Open in new tab") { AppState.shared.newTab(.folder(url)) },
            .separator,
            .item(PinStore.shared.isPinned(url) ? "Unpin from sidebar" : "Pin to sidebar") { PinStore.shared.toggle(url) },
            .item("Copy as path") { browser.copyPath([url]) },
            .item("Show in Finder") { browser.revealInFinder([url]) },
            .separator,
            .item("Copy") { browser.copy([url]) },
            .separator,
            .item("Properties") { browser.propertiesTarget = PropertiesTarget(urls: [url]) },
        ]
        return (main, classic)
    }

    static func drive(_ browser: FileBrowser, _ volume: VolumeInfo) -> Built {
        var main: [WinMenuEntry] = [
            .item("Open", "internaldrive", shortcut: "↩") { browser.go(to: .folder(volume.url)) },
            .item("Open in new tab", "plus.rectangle.on.rectangle") { AppState.shared.newTab(.folder(volume.url)) },
            .item(PinStore.shared.isPinned(volume.url) ? "Unpin from sidebar" : "Pin to sidebar", "pin") {
                PinStore.shared.toggle(volume.url)
            },
        ]
        if volume.isRemovable || volume.isDiskImage {
            main.append(.item("Eject", "eject") { browser.eject(volume.url) })
        }
        if let file = volume.imageFile {
            main.append(.item("Show image file", "doc") { browser.go(to: .folder(file.deletingLastPathComponent())) })
        }
        main += [
            .item("Copy as path", "doc.on.clipboard", shortcut: "⇧⌘C") { browser.copyPath([volume.url]) },
            .item("Properties", "wrench.adjustable", shortcut: "⌘I") { browser.propertiesTarget = PropertiesTarget(urls: [volume.url]) },
            .separator,
            .item("Open in Terminal", "terminal") { browser.openInTerminal(volume.url) },
            .separator,
            showMore,
        ]
        return (main, nil)
    }

    static func tab(_ app: AppState, _ tab: FileBrowser) -> [WinMenuEntry] {
        [
            .item("New tab", "plus", shortcut: "⌘T") { app.newTab() },
            .item("Duplicate tab", "plus.rectangle.on.rectangle") { app.duplicate(tab) },
            .separator,
            .item("Close tab", "xmark", shortcut: "⌘W") { app.close(tab) },
            .item("Close other tabs", enabled: app.tabs.count > 1) { app.closeOthers(tab) },
            .item("Close tabs to the right", enabled: app.tabs.last?.id != tab.id) { app.closeToTheRight(tab) },
        ]
    }
}
