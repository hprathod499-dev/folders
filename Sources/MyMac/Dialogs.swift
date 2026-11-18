import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Properties

struct PropertiesView: View {
    let urls: [URL]
    @EnvironmentObject private var browser: FileBrowser

    var body: some View {
        Group {
            if urls.count == 1, let url = urls.first,
               let volume = browser.volumes.first(where: { $0.url == url.normalizedFolder }) {
                DriveProperties(volume: volume)
            } else if urls.count == 1, let url = urls.first {
                ItemProperties(url: url)
            } else {
                MultiProperties(urls: urls)
            }
        }
        .frame(width: 440)
        .background(Theme.chrome)
        .foregroundStyle(Theme.text)
        .preferredColorScheme(Prefs.shared.colorScheme)
    }
}

/// Size, size on disk and counts for one or more items (computed off the main thread).
struct ItemStats {
    var bytes: Int64 = 0
    var onDisk: Int64 = 0
    var files = 0
    var folders = 0

    static func compute(_ urls: [URL]) async -> ItemStats { computeSync(urls) }

    private static func computeSync(_ urls: [URL]) -> ItemStats {
        var stats = ItemStats()
        let keys: [URLResourceKey] = [.fileSizeKey, .totalFileAllocatedSizeKey, .isDirectoryKey]
        func add(_ url: URL) {
            let v = try? url.resourceValues(forKeys: Set(keys))
            if v?.isDirectory == true { stats.folders += 1 } else { stats.files += 1 }
            stats.bytes += Int64(v?.fileSize ?? 0)
            stats.onDisk += Int64(v?.totalFileAllocatedSize ?? 0)
        }
        for url in urls {
            add(url)
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                                         errorHandler: { _, _ in true }) else { continue }
            while let next = e.nextObject() as? URL {
                if Task.isCancelled { break }
                add(next)
            }
        }
        return stats
    }
}

struct PropertiesHeader: View {
    let tab: String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tab)
                .font(.system(size: 12.5, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(UnevenRoundedRectangle(topLeadingRadius: 5, topTrailingRadius: 5).fill(Theme.content))
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }
}

struct PropRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).foregroundStyle(Theme.secondary).frame(width: 110, alignment: .leading)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12.5))
    }
}

struct PropDivider: View {
    var body: some View { Rectangle().fill(Theme.divider).frame(height: 1).padding(.vertical, 4) }
}

struct ItemProperties: View {
    @EnvironmentObject private var browser: FileBrowser
    @Environment(\.dismiss) private var dismiss
    @State private var url: URL
    @State private var name: String
    @State private var readOnly = false
    @State private var hidden = false
    @State private var stats: ItemStats?
    @State private var defaultApp: URL?

    init(url: URL) {
        _url = State(initialValue: url)
        _name = State(initialValue: url.lastPathComponent)
    }

    private var item: FileItem { FileItem(url: url) }

    var body: some View {
        let item = item
        VStack(alignment: .leading, spacing: 10) {
            PropertiesHeader(tab: "General")
            HStack(spacing: 14) {
                ItemIcon(item: item, size: 40)
                TextField("", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.top, 6)
            PropDivider()
            PropRow(label: "Type of file:", value: item.isDirectory ? "File folder"
                    : item.ext.isEmpty ? item.typeText : "\(item.typeText) (.\(item.ext))")
            if !item.isDirectory {
                HStack(spacing: 12) {
                    Text("Opens with:").foregroundStyle(Theme.secondary).frame(width: 110, alignment: .leading)
                    if let app = defaultApp {
                        Image(nsImage: IconCache.shared.icon(for: app)).resizable().frame(width: 16, height: 16)
                        Text(OpenWith.name(of: app))
                    } else {
                        Text("Unknown application")
                    }
                    Spacer()
                    Button("Change…") { changeDefaultApp() }
                }
                .font(.system(size: 12.5))
            }
            PropDivider()
            PropRow(label: "Location:", value: url.deletingLastPathComponent().path)
            PropRow(label: "Size:", value: stats.map { WinFormat.withBytes($0.bytes) } ?? "Calculating…")
            PropRow(label: "Size on disk:", value: stats.map { WinFormat.withBytes($0.onDisk) } ?? "Calculating…")
            if item.isDirectory {
                PropRow(label: "Contains:", value: stats.map { "\(WinFormat.number(Int64($0.files))) Files, \(WinFormat.number(Int64(max($0.folders - 1, 0)))) Folders" } ?? "Calculating…")
            }
            PropDivider()
            if let created = item.created { PropRow(label: "Created:", value: WinFormat.longDate.string(from: created)) }
            PropRow(label: "Modified:", value: WinFormat.longDate.string(from: item.modified))
            if let accessed = (try? url.resourceValues(forKeys: [.contentAccessDateKey]))?.contentAccessDate {
                PropRow(label: "Accessed:", value: WinFormat.longDate.string(from: accessed))
            }
            PropDivider()
            HStack(spacing: 12) {
                Text("Attributes:").foregroundStyle(Theme.secondary).frame(width: 110, alignment: .leading)
                Toggle("Read-only", isOn: $readOnly)
                Toggle("Hidden", isOn: $hidden)
            }
            .font(.system(size: 12.5))
            .toggleStyle(.checkbox)
            Spacer(minLength: 8)
            DialogButtons(ok: { apply(); dismiss() }, cancel: { dismiss() }, apply: { apply() })
        }
        .padding(16)
        .task(id: url) {
            let values = try? url.resourceValues(forKeys: [.isUserImmutableKey, .isHiddenKey])
            readOnly = values?.isUserImmutable ?? false
            hidden = values?.isHidden ?? false
            defaultApp = OpenWith.defaultApp(for: url)
            stats = await ItemStats.compute([url])
        }
    }

    private func apply() {
        var values = URLResourceValues()
        values.isHidden = hidden
        values.isUserImmutable = readOnly
        var target = url
        do { try target.setResourceValues(values) } catch { FileOps.shared.errorMessage = error.localizedDescription }
        if name != url.lastPathComponent, !name.isEmpty {
            browser.rename(url, to: name, keepHiddenExtension: false)
            url = url.deletingLastPathComponent().appendingPathComponent(name)
        }
        browser.reload()
    }

    private func changeDefaultApp() {
        let panel = NSOpenPanel()
        panel.title = "How do you want to open \(url.pathExtension.isEmpty ? "this file" : ".\(url.pathExtension) files") from now on?"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Always use this app"
        guard panel.runModal() == .OK, let app = panel.url,
              let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType else { return }
        NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type) { error in
            DispatchQueue.main.async {
                if let error { FileOps.shared.errorMessage = error.localizedDescription } else { defaultApp = app }
            }
        }
    }
}

struct MultiProperties: View {
    let urls: [URL]
    @Environment(\.dismiss) private var dismiss
    @State private var stats: ItemStats?

    var body: some View {
        let folders = urls.filter(FileBrowser.isFolder).count
        let files = urls.count - folders
        VStack(alignment: .leading, spacing: 10) {
            PropertiesHeader(tab: "General")
            HStack(spacing: 14) {
                Image(systemName: "doc.on.doc.fill").font(.system(size: 30)).foregroundStyle(Theme.secondary)
                Text("\(files) Files, \(folders) Folders").font(.system(size: 14))
            }
            .padding(.top, 6)
            PropDivider()
            PropRow(label: "Type:", value: "Multiple types")
            PropRow(label: "Location:", value: "All in \(urls[0].deletingLastPathComponent().path)")
            PropRow(label: "Size:", value: stats.map { WinFormat.withBytes($0.bytes) } ?? "Calculating…")
            PropRow(label: "Size on disk:", value: stats.map { WinFormat.withBytes($0.onDisk) } ?? "Calculating…")
            Spacer(minLength: 8)
            DialogButtons(ok: { dismiss() }, cancel: { dismiss() }, apply: nil)
        }
        .padding(16)
        .task { stats = await ItemStats.compute(urls) }
    }
}

struct DriveProperties: View {
    let volume: VolumeInfo
    @Environment(\.dismiss) private var dismiss
    private let usedColor = Color(hex: 0x1A86D9)
    private let freeColor = Color(hex: 0xB9B9B9)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PropertiesHeader(tab: "General")
            HStack(spacing: 14) {
                FolderGlyph(url: volume.url, size: 40)
                Text(volume.name).font(.system(size: 14))
            }
            .padding(.top, 6)
            PropDivider()
            PropRow(label: "Type:", value: volume.isDiskImage ? "Disk image (read-only)"
                    : volume.isRemovable ? "Removable Disk" : "Local Disk")
            PropRow(label: "File system:", value: volume.format)
            if let file = volume.imageFile {
                PropRow(label: "Image file:", value: file.path)
                PropRow(label: "Stored on:", value: "Macintosh HD (C:) — \(WinFormat.friendly(volume.imageFileSize)) file")
            }
            PropDivider()
            legend(usedColor, "Used space:", volume.used)
            legend(freeColor, "Free space:", volume.available)
            PropDivider()
            legend(nil, "Capacity:", volume.total)
            HStack {
                Spacer()
                VStack(spacing: 8) {
                    PieChart(fraction: volume.usedFraction, used: usedColor, free: freeColor)
                        .frame(width: 130, height: 130)
                    Text(volume.isDiskImage ? "Disk image inside Macintosh HD (C:)" : "Drive \(volume.letter)").font(.system(size: 12.5))
                }
                Spacer()
            }
            .padding(.vertical, 8)
            Spacer(minLength: 8)
            DialogButtons(ok: { dismiss() }, cancel: { dismiss() }, apply: nil)
        }
        .padding(16)
    }

    private func legend(_ color: Color?, _ label: String, _ bytes: Int64) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(color ?? .clear).frame(width: 14, height: 14)
            Text(label).foregroundStyle(Theme.secondary).frame(width: 90, alignment: .leading)
            Text("\(WinFormat.number(bytes)) bytes").frame(maxWidth: .infinity, alignment: .trailing)
            Text(WinFormat.friendly(bytes)).frame(width: 80, alignment: .trailing)
        }
        .font(.system(size: 12.5))
    }
}

struct PieChart: View {
    let fraction: Double
    let used: Color
    let free: Color

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius = min(rect.width, rect.height) / 2
            context.fill(Path(ellipseIn: rect), with: .color(free))
            var slice = Path()
            slice.move(to: center)
            slice.addArc(center: center, radius: radius, startAngle: .degrees(-90),
                         endAngle: .degrees(-90 + 360 * fraction), clockwise: false)
            slice.closeSubpath()
            context.fill(slice, with: .color(used))
        }
    }
}

struct DialogButtons: View {
    let ok: () -> Void
    let cancel: () -> Void
    let apply: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("OK", action: ok).keyboardShortcut(.defaultAction).frame(minWidth: 70)
            Button("Cancel", action: cancel).keyboardShortcut(.cancelAction).frame(minWidth: 70)
            if let apply { Button("Apply", action: apply).frame(minWidth: 70) }
        }
        .controlSize(.regular)
    }
}

// MARK: - Replace or Skip Files

struct ConflictView: View {
    let request: ConflictRequest
    @State private var answered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Replace or Skip Files").font(.system(size: 18, weight: .semibold))
            Text("\(request.verb) \(request.count == 1 ? "1 item" : "\(request.count) items") to \(request.destination)")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.secondary)
            Text(request.count == 1
                 ? "The destination already has a file named “\(request.firstName)”"
                 : "The destination has \(request.count) files with the same names")
                .font(.system(size: 15))
                .padding(.vertical, 6)
            choice("checkmark", request.count == 1 ? "Replace the file in the destination"
                                                   : "Replace the files in the destination", .replace)
            choice("arrow.uturn.right", request.count == 1 ? "Skip this file" : "Skip these files", .skip)
            choice("doc.on.doc", request.count == 1 ? "Keep both files" : "Keep all files (add a number to the new names)", .keepBoth)
            HStack {
                Spacer()
                Button("Cancel") { answer(.cancel) }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(Theme.chrome)
        .foregroundStyle(Theme.text)
        .preferredColorScheme(Prefs.shared.colorScheme)
        .onDisappear { if !answered { request.respond(.cancel) } }
    }

    private func choice(_ symbol: String, _ title: String, _ value: ConflictChoice) -> some View {
        ChoiceButton(symbol: symbol, title: title) { answer(value) }
    }

    private func answer(_ choice: ConflictChoice) {
        guard !answered else { return }
        answered = true
        request.respond(choice)
        FileOps.shared.conflict = nil
    }
}

struct ChoiceButton: View {
    let symbol: String
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(Theme.accent).frame(width: 22)
                Text(title).font(.system(size: 13.5))
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Theme.hover : Theme.content.opacity(0.4)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(hovering ? Theme.accent : Theme.divider))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Folder Options

enum OptionsWindow {
    @MainActor private static var window: NSWindow?

    @MainActor static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Folder Options"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: OptionsView())
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

struct OptionsView: View {
    @ObservedObject private var prefs = Prefs.shared
    @State private var cleared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Theme") {
                Picker("", selection: $prefs.theme) {
                    ForEach(AppTheme.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            GroupBox("Advanced settings") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Hidden files and folders", selection: $prefs.showHidden) {
                        Text("Don't show hidden files, folders, or drives").tag(false)
                        Text("Show hidden files, folders, and drives").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                    Toggle("Hide extensions for known file types", isOn: Binding(
                        get: { !prefs.showExtensions }, set: { prefs.showExtensions = !$0 }))
                    Toggle("Use check boxes to select items", isOn: $prefs.showCheckboxes)
                    Toggle("Decrease space between items (compact view)", isOn: $prefs.compact)
                    Toggle("Show the navigation pane", isOn: $prefs.showNavPane)
                }
                .toggleStyle(.checkbox)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            GroupBox("Privacy") {
                HStack {
                    Text("Clear File Explorer history")
                    Spacer()
                    Button(cleared ? "Cleared" : "Clear") {
                        PinStore.shared.clearHistory()
                        cleared = true
                    }
                    .disabled(cleared)
                }
                .padding(6)
            }
            Spacer()
            HStack {
                Button("Restore Defaults") {
                    prefs.theme = .dark
                    prefs.showHidden = false
                    prefs.showExtensions = false
                    prefs.showCheckboxes = true
                    prefs.compact = false
                    prefs.showNavPane = true
                }
                Spacer()
                Button("OK") { NSApp.keyWindow?.close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 520)
    }
}
