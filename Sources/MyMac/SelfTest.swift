import AppKit
import Combine
import ImageIO

/// Development aid: MYMAC_SELFTEST=/some/empty/folder runs every file function there and prints PASS/FAIL.
@MainActor
enum SelfTest {
    private static var results: [(String, Bool)] = []
    private static var autoAnswer: AnyCancellable?
    private static var answer: ConflictChoice = .keepBoth

    static func run(in root: URL) async {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        // Never touch the user's real clipboard.
        let privateBoard = NSPasteboard(name: NSPasteboard.Name("MyMac.SelfTest.\(UUID().uuidString)"))
        FileBrowser.pasteboard = privateBoard
        let generalBefore = NSPasteboard.general.changeCount
        let ops = FileOps.shared
        // Answer "Replace or Skip Files" automatically (Keep both unless a test says otherwise).
        autoAnswer = ops.$conflict.sink { request in
            guard let request else { return }
            DispatchQueue.main.async {
                request.respond(answer)
                ops.conflict = nil
            }
        }

        let browser = FileBrowser(start: .folder(root))
        func exists(_ name: String, in dir: URL = root) -> Bool { fm.fileExists(atPath: dir.appendingPathComponent(name).path) }

        // New folder / new text document (Windows names)
        browser.create(.folder)
        browser.cancelRename()
        check("New folder creates “New folder”", exists("New folder"))
        browser.create(.folder)
        browser.cancelRename()
        check("Second new folder is “New folder (2)”", exists("New folder (2)"))
        browser.create(.text)
        browser.cancelRename()
        check("New Text Document.txt created", exists("New Text Document.txt"))
        browser.create(.zip)
        browser.cancelRename()
        check("New Compressed (zipped) Folder created", exists("New Compressed (zipped) Folder.zip"))

        // Rename with hidden extension keeps .txt
        let txt = root.appendingPathComponent("New Text Document.txt")
        try? "hello".write(to: txt, atomically: true, encoding: .utf8)
        browser.reload()
        browser.beginRename(txt)
        browser.renameText = "notes"
        browser.commitRename()
        check("Rename keeps hidden extension (notes.txt)", exists("notes.txt"))
        browser.undo()
        check("Undo rename restores old name", exists("New Text Document.txt") && !exists("notes.txt"))
        browser.beginRename(txt)
        browser.renameText = "notes"
        browser.commitRename()
        let notes = root.appendingPathComponent("notes.txt")

        // Copy + paste into the same folder → " - Copy"
        browser.reload()
        browser.copy([notes])
        browser.paste()
        await settle()
        check("Paste in same folder makes “notes - Copy.txt”", exists("notes - Copy.txt"))

        // Copy here, paste in another folder (exactly what the Copy and Paste buttons do)
        let sub = root.appendingPathComponent("New folder")
        let other = root.appendingPathComponent("New folder (2)")
        browser.go(to: .folder(root))
        browser.reload()
        browser.copy([notes])
        browser.go(to: .folder(other))
        check("Paste button is enabled after Copy", browser.canPaste())
        browser.paste()
        await settle()
        check("Copy → Paste into another folder", exists("notes.txt", in: other) && exists("notes.txt"))
        try? fm.removeItem(at: other.appendingPathComponent("notes.txt"))

        // Cut here, paste in another folder → moved
        let cutMe = root.appendingPathComponent("cut-me.txt")
        try? "cut".write(to: cutMe, atomically: true, encoding: .utf8)
        browser.go(to: .folder(root))
        browser.reload()
        browser.copy([cutMe], cut: true)
        check("Cut item is dimmed", browser.isCut(cutMe))
        browser.go(to: .folder(other))
        browser.paste()
        await settle()
        check("Cut → Paste moves the file", exists("cut-me.txt", in: other) && !exists("cut-me.txt"))

        // A file deleted after copying is skipped, and Paste is greyed out
        let gone = root.appendingPathComponent("gone.txt")
        try? "x".write(to: gone, atomically: true, encoding: .utf8)
        browser.copy([gone])
        try? fm.removeItem(at: gone)
        ops.errorMessage = nil
        check("Paste is disabled when the copied file no longer exists", !browser.canPaste())
        browser.paste()
        await settle()
        check("Pasting a deleted file shows no error", ops.errorMessage == nil)
        browser.go(to: .folder(root))

        // Copy into a subfolder, then again → conflict → Keep both
        await ops.transfer([notes], into: sub, move: false)
        check("Copy into folder", exists("notes.txt", in: sub))
        await ops.transfer([notes], into: sub, move: false)
        check("Name conflict → Keep both makes “notes (2).txt”", exists("notes (2).txt", in: sub))

        // Cut + paste (move) and undo
        let sub2 = root.appendingPathComponent("New folder (2)")
        let copyFile = root.appendingPathComponent("notes - Copy.txt")
        await ops.transfer([copyFile], into: sub2, move: true)
        check("Move into folder", exists("notes - Copy.txt", in: sub2) && !exists("notes - Copy.txt"))
        browser.undo()
        check("Undo move puts it back", exists("notes - Copy.txt") && !exists("notes - Copy.txt", in: sub2))

        // Folder copy with contents and progress
        await ops.transfer([sub], into: sub2, move: false)
        check("Copy a folder with its contents", exists("New folder/notes.txt", in: sub2))

        // Can't copy a folder into itself
        ops.errorMessage = nil
        await ops.transfer([sub], into: sub, move: false)
        check("Copying a folder into itself is refused", ops.errorMessage != nil)
        ops.errorMessage = nil

        // Delete → Trash, then undo
        browser.reload()
        browser.trash([copyFile])
        check("Delete moves to Trash", !exists("notes - Copy.txt"))
        browser.undo()
        check("Undo delete restores from Trash", exists("notes - Copy.txt"))

        // Permanent delete
        browser.requestPermanentDelete([copyFile])
        browser.performPermanentDelete()
        check("Shift+Delete removes permanently", !exists("notes - Copy.txt"))

        // Zip and extract
        if let zip = await ops.compress([sub]) {
            check("Compress to ZIP file", fm.fileExists(atPath: zip.path))
            if let folder = await ops.extract(zip) {
                check("Extract All", fm.fileExists(atPath: folder.appendingPathComponent("New folder/notes.txt").path))
            } else { check("Extract All", false) }
        } else { check("Compress to ZIP file", false) }

        // Sorting and grouping
        browser.reload()
        browser.groupBy = .type
        check("Group by type makes sections", browser.sections.count >= 2)
        browser.groupBy = .size
        check("Group by size makes sections", browser.sections.contains { $0.title == "Unspecified" })
        browser.groupBy = .name
        check("Group by name makes A - H style sections", browser.sections.contains { $0.title == "I - P" || $0.title == "A - H" })
        browser.groupBy = .none
        browser.sortField = .name
        browser.sortAscending = true
        check("Folders listed first when sorted by name", browser.sortedItems.first?.isDirectory == true)

        // Selection helpers
        browser.selectAll()
        let all = browser.selection.count
        browser.invertSelection()
        check("Select all / invert selection", all > 0 && browser.selection.isEmpty)

        // Search through subfolders
        browser.searchText = "notes"
        browser.updateSearch()
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        check("Search finds files in subfolders", (browser.searchResults?.count ?? 0) >= 3)

        // Search This PC (whole Mac via Spotlight)
        let pc = FileBrowser(start: .thisMac)
        pc.searchText = "Downloads"
        pc.updateSearch()
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        check("Search This PC finds files anywhere on the Mac", (pc.searchResults?.count ?? 0) > 0)
        check("This PC search shows results in the list", pc.visibleCount > 0)

        // Navigation
        browser.go(to: .folder(sub))
        browser.goBack()
        check("Back returns to previous folder", browser.currentURL == root.normalizedFolder)
        browser.goForward()
        browser.goUp()
        check("Up goes to parent folder", browser.currentURL == root.normalizedFolder)

        await moreTests(root: root, browser: browser)
        await stressTests(root: root, browser: browser)

        check("Your real clipboard was not touched", NSPasteboard.general.changeCount == generalBefore)
        privateBoard.releaseGlobally()

        let failed = results.filter { !$0.1 }
        print("SELFTEST: \(results.count - failed.count)/\(results.count) passed")
        fflush(stdout)
        exit(failed.isEmpty ? 0 : 1)
    }

    // MARK: - Everything else a Windows Explorer user does

    private static func moreTests(root: URL, browser: FileBrowser) async {
        let fm = FileManager.default
        let ops = FileOps.shared
        let prefs = Prefs.shared
        let more = root.appendingPathComponent("More tests")
        let dest = more.appendingPathComponent("Dest")
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
        func exists(_ name: String, in dir: URL) -> Bool { fm.fileExists(atPath: dir.appendingPathComponent(name).path) }
        func write(_ text: String, _ url: URL) { try? text.write(to: url, atomically: true, encoding: .utf8) }
        func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
        let alpha = more.appendingPathComponent("alpha.txt")
        let beta = more.appendingPathComponent("Beta.txt")
        write("aaaa", alpha)
        write("bb", beta)
        browser.go(to: .folder(more))
        browser.reload()

        // Cut / copy / paste edge cases
        browser.copy([alpha], cut: true)
        browser.paste()
        await settle()
        check("Cut → Paste in the same folder leaves the file alone",
              exists("alpha.txt", in: more) && !exists("alpha - Copy.txt", in: more))
        browser.copy([alpha], cut: true)
        browser.copy([beta])
        check("Copying something else cancels an earlier Cut", !browser.isCut(alpha))
        browser.copy([beta], cut: true)
        browser.go(to: .folder(dest))
        browser.paste()
        await settle()
        check("Cut → Paste moves, then clipboard is empty", exists("Beta.txt", in: dest) && !browser.canPaste())
        browser.undo()
        check("Undo Cut → Paste puts it back", exists("Beta.txt", in: more) && !exists("Beta.txt", in: dest))
        browser.go(to: .folder(more))

        // Replace or Skip Files: every choice
        let destAlpha = dest.appendingPathComponent("alpha.txt")
        write("old", destAlpha)
        answer = .replace
        await ops.transfer([alpha], into: dest, move: false)
        check("Conflict → Replace the file in the destination", read(destAlpha) == "aaaa")
        write("old", destAlpha)
        answer = .skip
        await ops.transfer([alpha], into: dest, move: false)
        check("Conflict → Skip this file", read(destAlpha) == "old" && !exists("alpha (2).txt", in: dest))
        answer = .cancel
        await ops.transfer([alpha], into: dest, move: false)
        check("Conflict → Cancel copies nothing", read(destAlpha) == "old" && !exists("alpha (2).txt", in: dest))
        answer = .keepBoth

        // Undo for copy and new folder
        await ops.transfer([alpha], into: more, move: false)
        let hadCopy = exists("alpha - Copy.txt", in: more)
        browser.undo()
        check("Undo Copy removes the copy", hadCopy && !exists("alpha - Copy.txt", in: more))
        browser.create(.folder)
        browser.cancelRename()
        let hadFolder = exists("New folder", in: more)
        browser.undo()
        check("Undo New Folder removes it", hadFolder && !exists("New folder", in: more))
        browser.create(.richText)
        browser.cancelRename()
        check("New Rich Text Document.rtf created", exists("New Rich Text Document.rtf", in: more))

        // Rename rules
        browser.reload()
        browser.rename(alpha, to: "Alpha", keepHiddenExtension: true)
        let names = (try? fm.contentsOfDirectory(atPath: more.path)) ?? []
        check("Rename that only changes capitals (alpha → Alpha)", names.contains("Alpha.txt") && !names.contains("alpha.txt"))
        let bigAlpha = more.appendingPathComponent("Alpha.txt")
        let gamma = more.appendingPathComponent("gamma.txt")
        write("c", gamma)
        browser.reload()
        ops.errorMessage = nil
        browser.rename(gamma, to: "Alpha", keepHiddenExtension: true)
        check("Rename to an existing name is refused with a message", ops.errorMessage != nil && exists("gamma.txt", in: more))
        ops.errorMessage = nil
        browser.rename(gamma, to: "a/b", keepHiddenExtension: true)
        check("Rename with “/” is refused with a message", ops.errorMessage != nil && exists("gamma.txt", in: more))
        ops.errorMessage = nil
        browser.rename(gamma, to: "   ", keepHiddenExtension: true)
        check("Blank rename keeps the old name", exists("gamma.txt", in: more) && ops.errorMessage == nil)
        prefs.showExtensions = true
        browser.reload()
        browser.rename(gamma, to: "gamma.md", keepHiddenExtension: true)
        check("With extensions shown, rename can change the extension", exists("gamma.md", in: more))
        prefs.showExtensions = false
        let gammaMd = more.appendingPathComponent("gamma.md")

        // Names and types like Windows
        check("Extensions are hidden by default (“Alpha”)", FileItem(url: bigAlpha).displayName(showExtensions: false) == "Alpha")
        check("Type column: “Text Document” and “File folder”",
              FileItem(url: bigAlpha).typeText == "Text Document" && FileItem(url: dest).typeText == "File folder")

        // Hidden items
        write("h", more.appendingPathComponent(".secret"))
        browser.reload()
        let hiddenOff = !browser.sortedItems.contains { $0.name == ".secret" }
        prefs.showHidden = true
        browser.reload()
        let hiddenOn = browser.sortedItems.contains { $0.name == ".secret" }
        prefs.showHidden = false
        browser.reload()
        check("Hidden items appear only when turned on", hiddenOff && hiddenOn)

        // Keyboard selection
        browser.groupBy = .none
        browser.sortField = .name
        browser.sortAscending = true
        let order = browser.orderedURLs
        browser.selectEdge(last: false)
        check("Home key selects the first item", browser.selection == [order[0]])
        browser.moveSelection(by: 1)
        check("Down arrow selects the next item", browser.selection == [order[1]])
        browser.moveSelection(by: 1, extend: true)
        check("Shift+Down extends the selection", browser.selection.count == 2)
        browser.selectEdge(last: true)
        check("End key selects the last item", browser.selection == [order[order.count - 1]])
        browser.jump(to: "gam")
        check("Typing a name jumps to it", browser.selection == [gammaMd])

        // Column header sorting
        browser.sort(by: .size)
        let files = browser.sortedItems.filter { !$0.isDirectory }
        check("Click Size header → largest first",
              !browser.sortAscending && zip(files, files.dropFirst()).allSatisfy { $0.size >= $1.size })
        browser.sort(by: .size)
        check("Click Size again → smallest first", browser.sortAscending)
        browser.sort(by: .name)
        browser.groupBy = .date
        check("Group by Date modified shows “Today”", browser.sections.first?.title == "Today")
        browser.groupBy = .none

        // Address bar (Windows paths work too)
        browser.goTo(path: "C:\\Users")
        check("Address bar: C:\\Users", browser.currentURL?.path == "/Users")
        browser.goTo(path: "c:")
        check("Address bar: C:", browser.currentURL?.path == "/")
        browser.goTo(path: "this pc")
        check("Address bar: This PC", browser.location == .thisMac)
        if let dl = Place.downloads {
            browser.goTo(path: "Downloads")
            check("Address bar: Downloads", browser.currentURL == dl.normalizedFolder)
        }
        browser.goTo(path: more.path)
        ops.errorMessage = nil
        browser.goTo(path: "/no/such/folder")
        check("Address bar: unknown path shows “Can't find” and stays put",
              ops.errorMessage?.contains("Can't find") == true && browser.currentURL == more.normalizedFolder)
        ops.errorMessage = nil

        // Breadcrumbs and Up, drives and disk images
        browser.go(to: .folder(URL(fileURLWithPath: "/Users")))
        let crumbs = browser.breadcrumbs.map(\.name)
        check("Path shows This PC › Macintosh HD (C:) › Users",
              crumbs.count == 3 && crumbs[0] == "This Mac" && crumbs[1].hasSuffix("(C:)") && crumbs[2] == "Users")
        browser.go(to: .folder(URL(fileURLWithPath: "/")))
        browser.goUp()
        check("Up from C: goes to This PC", browser.location == .thisMac)
        check("Only real drives get letters (C: is the Mac's disk)",
              browser.volumes.first(where: \.isInternal)?.letter == "C:"
                  && browser.volumes.filter(\.isDiskImage).allSatisfy { $0.letter.isEmpty })
        if let image = browser.volumes.first(where: \.isDiskImage) {
            browser.go(to: .folder(image.url))
            let ic = browser.breadcrumbs.map(\.name)
            check("Disk image path is This PC › Macintosh HD (C:) › \(image.name)",
                  ic.count == 3 && ic[1].hasSuffix("(C:)") && ic[2] == image.name)
            browser.goUp()
            check("Up from a disk image goes to Macintosh HD (C:)", browser.currentURL?.path == "/")
            check("Disk images are listed inside Macintosh HD (C:)", browser.sortedItems.contains { $0.url == image.url })
        }

        // Tabs
        let app = AppState.shared
        let tabsBefore = app.tabs.count
        app.newTab(.folder(more))
        check("New tab opens", app.tabs.count == tabsBefore + 1 && app.current.currentURL == more.normalizedFolder)
        app.duplicate(app.current)
        check("Duplicate tab", app.tabs.count == tabsBefore + 2 && app.current.currentURL == more.normalizedFolder)
        let dup = app.current
        app.selectNext(1)
        check("Ctrl+Tab goes to the next tab (wraps around)", app.current.id != dup.id)
        app.select(dup)
        app.close(dup)
        check("Close tab", app.tabs.count == tabsBefore + 1 && !app.tabs.contains { $0.id == dup.id })
        app.closeOthers(app.current)
        check("Close other tabs", app.tabs.count == 1)

        // Quick access, Favorites, Recent (test copy of settings only)
        let pins = PinStore.shared
        pins.toggle(more)
        let pinnedOK = pins.isPinned(more)
        pins.toggle(more)
        check("Pin to / unpin from Quick access", pinnedOK && !pins.isPinned(more))
        pins.toggleFavorite(bigAlpha)
        let favOK = pins.isFavorite(bigAlpha)
        pins.toggleFavorite(bigAlpha)
        check("Add to / remove from Favorites", favOK && !pins.isFavorite(bigAlpha))
        browser.go(to: .folder(dest))
        check("Visited folder shows in Recent", pins.recent.first == dest.normalizedFolder)
        browser.go(to: .folder(more))

        // Copy as path
        browser.copyPath([bigAlpha])
        check("Copy as path gives the quoted path", FileBrowser.pasteboard.string(forType: .string) == "\"\(bigAlpha.standardizedFileURL.path)\"")

        // Drag and drop
        let dropFile = more.appendingPathComponent("drop.txt")
        write("d", dropFile)
        _ = browser.drop([dropFile], into: dest)
        await settle()
        check("Drag a file onto a folder moves it", exists("drop.txt", in: dest) && !exists("drop.txt", in: more))
        _ = browser.drop([dest.appendingPathComponent("drop.txt")], into: dest)
        await settle()
        check("Dropping a file into its own folder does nothing", !exists("drop - Copy.txt", in: dest) && exists("drop.txt", in: dest))
        check("Dropping a folder onto itself is refused", browser.drop([dest], into: dest) == false)

        // Live refresh when another app changes the folder
        write("o", more.appendingPathComponent("outside.txt"))
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        check("New file from another app appears by itself", browser.sortedItems.contains { $0.name == "outside.txt" })

        // Search box behaviour
        browser.searchText = "gam"
        browser.updateSearch()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let found = browser.searchResults?.count ?? 0
        browser.searchText = ""
        browser.updateSearch()
        check("Clearing the search shows the folder again", found == 1 && !browser.isSearchResults && browser.visibleCount > 3)
        browser.searchText = "gam"
        browser.updateSearch()
        browser.go(to: .folder(dest))
        check("Opening another folder clears the search", browser.searchText.isEmpty && !browser.isSearchResults)
        browser.go(to: .folder(more))

        // This PC search hides app data like Windows hides AppData
        let pc = FileBrowser(start: .thisMac)
        pc.searchText = "plist"
        pc.updateSearch()
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        let home = fm.homeDirectoryForCurrentUser.path
        check("This PC search leaves out Library/system files",
              !(pc.searchResults ?? []).contains { $0.url.path.hasPrefix(home + "/Library/") || $0.url.path.hasPrefix("/System/") })

        // Downloads opens like Windows: grouped by date, newest first
        if let dl = Place.downloads {
            let d = FileBrowser(start: .folder(dl))
            check("Downloads groups by date, newest first", d.groupBy == .date && d.sortField == .date && !d.sortAscending)
        }

        // Home and Gallery load
        let homeTab = FileBrowser(start: .home)
        let galleryTab = FileBrowser(start: .gallery)
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        check("Home loads recent files", !homeTab.recentItems.isEmpty)
        check("Gallery finishes loading", !galleryTab.isLoadingGallery)

        // Properties
        browser.reload()
        browser.showProperties([bigAlpha])
        check("Properties opens for a file", browser.propertiesTarget?.urls == [bigAlpha])
        browser.propertiesTarget = nil
        let stats = await ItemStats.compute([dest])
        check("Properties counts files and folders inside", stats.files == 2 && stats.folders == 1 && stats.bytes > 0)

        // Zip several items, extract twice
        if let zip = await ops.compress([bigAlpha, gammaMd]) {
            check("Zip of several items named after the first (Alpha.zip)", zip.lastPathComponent == "Alpha.zip")
            let first = await ops.extract(zip)
            let second = await ops.extract(zip)
            check("Extract twice makes “Alpha (2)”",
                  first?.lastPathComponent == "Alpha" && second?.lastPathComponent == "Alpha (2)"
                      && exists("gamma.md", in: second ?? more))
        } else {
            check("Zip of several items", false)
        }

        // Rotate pictures
        let png = more.appendingPathComponent("wide.png")
        let jpg = more.appendingPathComponent("phone.jpg")
        makeImage(png, width: 40, height: 20, type: "public.png", orientation: nil)
        makeImage(jpg, width: 40, height: 20, type: "public.jpeg", orientation: 6)  // shown as 20 × 40
        browser.reload()
        browser.rotate([png], clockwise: true)
        check("Rotate right turns a 40×20 picture into 20×40", pixelSize(png) == "20x40")
        browser.rotate([jpg], clockwise: true)
        check("Rotate respects iPhone-style orientation (20×40 shown → 40×20)", pixelSize(jpg) == "40x20")
        browser.rotate([png], clockwise: false)
        check("Rotate left turns it back", pixelSize(png) == "40x20")

        // Space bar preview (Quick Look)
        browser.reload()
        browser.select(paths: [png.path])
        QuickLook.shared.show([png], owner: browser)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let opened = QuickLook.shared.isOpen && QuickLook.shared.urls == [png]
        browser.select(paths: [jpg.path])
        try? await Task.sleep(nanoseconds: 500_000_000)
        let followed = QuickLook.shared.urls.map(\.lastPathComponent) == ["phone.jpg"]
        QuickLook.shared.close()
        try? await Task.sleep(nanoseconds: 300_000_000)
        check("Space opens a preview of the selected file", opened)
        check("Preview follows the selection (arrow keys)", followed)
        check("Space again / Esc closes the preview", !QuickLook.shared.isOpen)

        // Delete several, undo brings all back
        browser.trash([bigAlpha, gammaMd])
        let goneBoth = !exists("Alpha.txt", in: more) && !exists("gamma.md", in: more)
        browser.undo()
        check("Delete several then Undo restores all", goneBoth && exists("Alpha.txt", in: more) && exists("gamma.md", in: more))

        // Delete a folder permanently
        browser.requestPermanentDelete([dest])
        browser.performPermanentDelete()
        check("Shift+Delete removes a folder with its contents", !exists("Dest", in: more))
    }

    // MARK: - Harder cases

    private static func stressTests(root: URL, browser: FileBrowser) async {
        let fm = FileManager.default
        let ops = FileOps.shared
        let base = root.appendingPathComponent("Stress")
        let inbox = base.appendingPathComponent("Inbox")
        try? fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        func exists(_ name: String, in dir: URL) -> Bool { fm.fileExists(atPath: dir.appendingPathComponent(name).path) }
        func write(_ text: String, _ url: URL) { try? text.write(to: url, atomically: true, encoding: .utf8) }
        func count(_ dir: URL) -> Int { (try? fm.contentsOfDirectory(atPath: dir.path).filter { !$0.hasPrefix(".") }.count) ?? -1 }

        // Sizes in MB, never KB
        check("Sizes: 0 → “0 MB”", WinFormat.friendly(0) == "0 MB")
        check("Sizes: 2 bytes → “0.01 MB”", WinFormat.friendly(2) == "0.01 MB")
        check("Sizes: 1 MB → “1.00 MB”", WinFormat.friendly(1_048_576) == "1.00 MB")
        check("Sizes: 500 KB → “0.49 MB”", WinFormat.friendly(512_000) == "0.49 MB")
        check("Sizes: 5 GB → “5.00 GB”", WinFormat.friendly(5 * 1_073_741_824) == "5.00 GB")
        let tiny = base.appendingPathComponent("tiny.txt")
        write("hi", tiny)
        check("Size column never says KB", !FileItem(url: tiny).sizeText.contains("KB") && FileItem(url: tiny).sizeText.hasSuffix("MB"))
        check("Folders have no size in the list", FileItem(url: inbox).sizeText.isEmpty)

        // The same folder written two ways (/tmp vs /private/tmp) is still the same folder
        browser.go(to: .folder(base))
        browser.reload()
        let alias = URL(fileURLWithPath: tiny.path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/"))
        if alias.path != tiny.path {
            await ops.transfer([alias], into: base, move: false)
            check("Copy via another spelling of the path still makes “- Copy”", exists("tiny - Copy.txt", in: base))
            browser.rename(alias, to: "Tiny", keepHiddenExtension: true)
            check("Capitals rename via another spelling of the path", (try? fm.contentsOfDirectory(atPath: base.path))?.contains("Tiny.txt") == true)
            browser.undo()
            check("Undo a capitals-only rename", (try? fm.contentsOfDirectory(atPath: base.path))?.contains("tiny.txt") == true)
        }

        // Unicode / emoji names
        let hindi = base.appendingPathComponent("नमस्ते दुनिया 😀.txt")
        write("namaste", hindi)
        browser.reload()
        await ops.transfer([hindi], into: inbox, move: false)
        check("Copy a file with Hindi and emoji in its name", exists("नमस्ते दुनिया 😀.txt", in: inbox))
        browser.rename(hindi, to: "शुभ 🎉", keepHiddenExtension: true)
        check("Rename to Hindi and emoji", exists("शुभ 🎉.txt", in: base))
        browser.searchText = "शुभ"
        browser.updateSearch()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        check("Search finds Hindi names", browser.searchResults?.count == 1)
        browser.searchText = "TINY"
        browser.updateSearch()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        check("Search ignores capitals", (browser.searchResults?.count ?? 0) >= 2)
        browser.searchText = ""
        browser.updateSearch()

        // Name too long
        ops.errorMessage = nil
        browser.rename(tiny, to: String(repeating: "x", count: 300), keepHiddenExtension: true)
        check("Too-long name shows an error and keeps the file", ops.errorMessage != nil && fm.fileExists(atPath: tiny.path))
        ops.errorMessage = nil

        // 200 files at once
        let many = base.appendingPathComponent("Many")
        try? fm.createDirectory(at: many, withIntermediateDirectories: true)
        for i in 1...200 { write("file \(i)", many.appendingPathComponent("file \(i).txt")) }
        let manyFiles = (1...200).map { many.appendingPathComponent("file \($0).txt") }
        let copied = await ops.transfer(manyFiles, into: inbox, move: false)
        check("Copy 200 files at once", copied.count == 200 && count(inbox) == 201)
        browser.go(to: .folder(inbox))
        browser.selectAll()
        check("Select all picks 201 items", browser.selection.count == 201)
        browser.trash(browser.selection)
        check("Delete 201 items at once", count(inbox) == 0)
        browser.undo()
        check("Undo brings all 201 back", count(inbox) == 201)

        // Big file copied byte-for-byte
        let big = base.appendingPathComponent("big.bin")
        var bytes = Data(count: 50 * 1_048_576)
        bytes.withUnsafeMutableBytes { raw in
            for i in stride(from: 0, to: raw.count, by: 4096) { raw[i] = UInt8(i / 4096 % 251) }
        }
        try? bytes.write(to: big)
        let bigDest = base.appendingPathComponent("Big copy")
        try? fm.createDirectory(at: bigDest, withIntermediateDirectories: true)
        await ops.transfer([big], into: bigDest, move: false)
        check("50 MB file copies byte-for-byte", (try? Data(contentsOf: bigDest.appendingPathComponent("big.bin"))) == bytes)
        check("50 MB file shows as “50.00 MB”", FileItem(url: big).sizeText == "50.00 MB")

        // Deep folders
        var deep = base.appendingPathComponent("Deep")
        for level in 1...12 { deep.appendPathComponent("Level \(level)") }
        try? fm.createDirectory(at: deep, withIntermediateDirectories: true)
        write("bottom", deep.appendingPathComponent("bottom.txt"))
        let deepDest = base.appendingPathComponent("Deep target")
        try? fm.createDirectory(at: deepDest, withIntermediateDirectories: true)
        await ops.transfer([base.appendingPathComponent("Deep")], into: deepDest, move: true)
        check("Move a 12-level folder tree", fm.fileExists(atPath: deepDest.appendingPathComponent("Deep/" + (1...12).map { "Level \($0)" }.joined(separator: "/") + "/bottom.txt").path)
              && !exists("Deep", in: base))
        ops.errorMessage = nil
        await ops.transfer([deepDest], into: deepDest.appendingPathComponent("Deep/Level 1"), move: true)
        check("Moving a folder into its own subfolder is refused", ops.errorMessage != nil && exists("Deep target", in: base))
        ops.errorMessage = nil

        // Symbolic links stay links
        let link = base.appendingPathComponent("shortcut")
        try? fm.createSymbolicLink(at: link, withDestinationURL: big)
        await ops.transfer([link], into: inbox, move: false)
        check("Copying a shortcut (symlink) copies the shortcut, not 50 MB",
              (try? fm.destinationOfSymbolicLink(atPath: inbox.appendingPathComponent("shortcut").path)) != nil)

        // Read-only folder: errors, no crash
        let locked = base.appendingPathComponent("Locked")
        try? fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        ops.errorMessage = nil
        await ops.transfer([tiny], into: locked, move: false)
        check("Paste into a read-only folder shows an error", ops.errorMessage != nil && count(locked) == 0)
        ops.errorMessage = nil
        browser.go(to: .folder(locked))
        browser.create(.folder)
        check("New folder in a read-only folder shows an error", ops.errorMessage != nil && count(locked) == 0)
        ops.errorMessage = nil
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        browser.go(to: .folder(base))

        // Broken zip, missing file
        let badZip = base.appendingPathComponent("broken.zip")
        write("this is not a zip", badZip)
        ops.errorMessage = nil
        let extracted = await ops.extract(badZip)
        check("Extracting a broken zip shows an error", extracted == nil && ops.errorMessage != nil)
        ops.errorMessage = nil
        ops.trash([base.appendingPathComponent("never existed.txt")])
        check("Deleting a file that's already gone shows an error, no crash", ops.errorMessage != nil)
        ops.errorMessage = nil

        // Zip a folder with spaces, then extract it
        if let zip = await ops.compress([bigDest]) {
            let out = await ops.extract(zip)
            check("Zip and unzip a folder with spaces in its name",
                  zip.lastPathComponent == "Big copy.zip" && fm.fileExists(atPath: (out ?? base).appendingPathComponent("Big copy/big.bin").path))
        } else { check("Zip a folder with spaces in its name", false) }

        // Undo several steps in order
        browser.reload()
        let u = base.appendingPathComponent("undo.txt")
        write("u", u)
        browser.reload()
        browser.rename(u, to: "undo 1", keepHiddenExtension: true)
        browser.rename(base.appendingPathComponent("undo 1.txt"), to: "undo 2", keepHiddenExtension: true)
        browser.trash([base.appendingPathComponent("undo 2.txt")])
        browser.undo()
        let step1 = exists("undo 2.txt", in: base)
        browser.undo()
        let step2 = exists("undo 1.txt", in: base)
        browser.undo()
        check("Three Undos step back in order (delete, rename, rename)", step1 && step2 && exists("undo.txt", in: base))

        // Back / Forward history
        browser.go(to: .folder(base))
        browser.go(to: .folder(inbox))
        browser.go(to: .folder(many))
        browser.goBack(); browser.goBack()
        let backOK = browser.currentURL == base.normalizedFolder
        browser.goForward()
        check("Back twice, then Forward", backOK && browser.currentURL == inbox.normalizedFolder)
        browser.go(to: .folder(bigDest))
        check("Going somewhere new clears Forward", !browser.canGoForward)

        // Date sort order
        browser.go(to: .folder(base))
        let old = base.appendingPathComponent("old.txt")
        write("o", old)
        try? fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: old.path)
        browser.reload()
        browser.sort(by: .date)
        check("Sort by Date modified: newest first", browser.sortedItems.last?.url.lastPathComponent == "old.txt")
        browser.groupBy = .date
        check("Group by date puts 1970 under “A long time ago”", browser.sections.last?.title == "A long time ago")
        browser.groupBy = .none
        browser.sort(by: .name)

        // This PC lists only real drives (disk images live inside Macintosh HD)
        let pc = FileBrowser(start: .thisMac)
        check("This PC shows Macintosh HD (C:)", pc.volumes.contains { $0.isInternal && $0.displayName.hasSuffix("(C:)") })
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
    }

    private static func makeImage(_ url: URL, width: Int, height: Int, type: String, orientation: Int?) {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else { return }
        var props: [CFString: Any] = [:]
        if let orientation { props[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    /// Size as the picture is shown (orientation applied).
    private static func pixelSize(_ url: URL) -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return "?" }
        let o = p[kCGImagePropertyOrientation] as? Int ?? 1
        return o >= 5 ? "\(h)x\(w)" : "\(w)x\(h)"
    }

    private static func check(_ name: String, _ ok: Bool) {
        results.append((name, ok))
        print("\(ok ? "PASS" : "FAIL")  \(name)")
        fflush(stdout)
    }

    private static func settle() async {
        try? await Task.sleep(nanoseconds: 800_000_000)
    }
}
