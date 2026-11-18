import AppKit
import SwiftUI

// MARK: - Model

/// One line of a Windows 11 right-click menu.
struct WinMenuEntry: Identifiable {
    enum Kind {
        case item
        case submenu([WinMenuEntry])
        case separator
        case toolbar([WinToolButton])
    }

    let id = UUID()
    var kind: Kind = .item
    var title = ""
    var symbol: String?
    var image: NSImage?
    var tint: Color?
    var shortcut = ""
    var enabled = true
    var radio = false          // shows the "•" used for the current View / Sort choice
    var action: (() -> Void)?

    static func item(_ title: String, _ symbol: String? = nil, shortcut: String = "", image: NSImage? = nil,
                     tint: Color? = nil, enabled: Bool = true, radio: Bool = false,
                     _ action: @escaping () -> Void) -> WinMenuEntry {
        WinMenuEntry(kind: .item, title: title, symbol: symbol, image: image, tint: tint, shortcut: shortcut,
                     enabled: enabled, radio: radio, action: action)
    }

    static func submenu(_ title: String, _ symbol: String?, enabled: Bool = true, _ entries: [WinMenuEntry]) -> WinMenuEntry {
        WinMenuEntry(kind: .submenu(entries), title: title, symbol: symbol, enabled: enabled && !entries.isEmpty)
    }

    static var separator: WinMenuEntry { WinMenuEntry(kind: .separator) }

    static func toolbar(_ buttons: [WinToolButton]) -> WinMenuEntry { WinMenuEntry(kind: .toolbar(buttons)) }

    var height: CGFloat {
        switch kind {
        case .separator: return 9
        case .toolbar: return 44
        default: return 32
        }
    }
}

/// The icon row at the top of a Windows 11 menu: Cut, Copy, Paste, Rename, Share, Delete.
struct WinToolButton: Identifiable {
    let id = UUID()
    let symbol: String
    let help: String
    var enabled = true
    let action: () -> Void
}

// MARK: - Presenter

@MainActor
final class WinMenu: ObservableObject {
    static let shared = WinMenu()

    struct OpenSub: Equatable {
        let rowID: UUID
        let entries: [WinMenuEntry]
        let y: CGFloat
        static func == (a: OpenSub, b: OpenSub) -> Bool { a.rowID == b.rowID && a.y == b.y }
    }

    @Published var sub: OpenSub?
    private(set) var root: [WinMenuEntry] = []
    private(set) var classic: [WinMenuEntry] = []
    private(set) var rootX: CGFloat = 0
    private(set) var subX: CGFloat = 0
    private(set) var visibleHeight: CGFloat = 0
    /// Where the menu was opened (screen coordinates), for Share and Show more options.
    private(set) var origin: NSPoint = .zero
    private weak var ownerWindow: NSWindow?
    private var panel: NSPanel?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []

    static let rootWidth: CGFloat = 300
    static let subWidth: CGFloat = 260
    static let overlap: CGFloat = 4

    var isOpen: Bool { panel != nil }

    static func height(of entries: [WinMenuEntry]) -> CGFloat { entries.reduce(8) { $0 + $1.height } }

    /// Opens the menu with its top-left corner at `point` (screen coordinates), like Windows.
    /// `classic` is the longer list shown by "Show more options".
    func show(_ entries: [WinMenuEntry], classic: [WinMenuEntry]? = nil, at point: NSPoint, in window: NSWindow?) {
        close()
        guard !entries.isEmpty else { return }
        root = entries
        self.classic = classic ?? entries
        origin = point
        ownerWindow = window
        sub = nil

        let screen = (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let rootH = Self.height(of: entries)
        let subH = entries.compactMap { entry -> CGFloat? in
            if case .submenu(let items) = entry.kind { return Self.height(of: items) }
            return nil
        }.max() ?? 0
        let width = Self.rootWidth + (subH > 0 ? Self.subWidth - Self.overlap : 0)

        // Flyouts open to the right, or to the left when there's no room (like Windows).
        var left = point.x
        if subH > 0, point.x + width > screen.maxX {
            left = point.x - (Self.subWidth - Self.overlap)
            rootX = Self.subWidth - Self.overlap
            subX = 0
        } else {
            rootX = 0
            subX = Self.rootWidth - Self.overlap
        }
        if left + width > screen.maxX { left = screen.maxX - width }
        if left < screen.minX { left = screen.minX }
        var top = point.y
        if top - rootH < screen.minY { top = screen.minY + rootH }
        let height = max(rootH, subH) + rootH
        let bottom = max(top - height, screen.minY)
        visibleHeight = top - bottom

        let frame = NSRect(x: left, y: bottom, width: width, height: top - bottom)
        let panel = MenuPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.appearance = NSApp.effectiveAppearance
        let host = FirstClickHostingView(rootView: WinMenuWindowView(menu: self))
        host.frame = NSRect(origin: .zero, size: frame.size)
        panel.contentView = host
        panel.orderFrontRegardless()
        panel.makeKey()
        self.panel = panel

        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window !== self.panel { self.close() }
            return event
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { self.close(); return nil }   // Esc
            return event
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            if event.window !== self?.panel { self?.close() }
            return event
        } as Any)
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        })
    }

    func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        panel?.orderOut(nil)
        panel = nil
        sub = nil
        ownerWindow?.makeKey()
    }

    /// Closes the menu, then runs the chosen command.
    func run(_ action: (() -> Void)?) {
        close()
        guard let action else { return }
        DispatchQueue.main.async { action() }
    }

    /// Test snapshots only: keeps a flyout open even if the real mouse is elsewhere.
    var freezeFlyout = false

    func hover(_ entry: WinMenuEntry, y: CGFloat) {
        if freezeFlyout, sub != nil { return }
        if case .submenu(let entries) = entry.kind, entry.enabled {
            let h = Self.height(of: entries)
            let top = min(max(y - 4, 0), max(visibleHeight - h, 0))
            let next = OpenSub(rowID: entry.id, entries: entries, y: top)
            if sub != next { sub = next }
        } else if sub != nil {
            sub = nil
        }
    }

    /// "Show more options": the classic (Windows 10 style) menu with every command.
    func showMoreOptions() {
        let entries = classic
        let point = origin
        let window = ownerWindow
        close()
        DispatchQueue.main.async {
            guard let view = window?.contentView else { return }
            let menu = ClassicMenu.make(entries)
            let local = view.convert(window?.convertPoint(fromScreen: point) ?? .zero, from: nil)
            menu.popUp(positioning: nil, at: local, in: view)
        }
    }

    /// Share sheet anchored where the menu was opened.
    func share(_ urls: [URL]) {
        let point = origin
        let window = ownerWindow
        close()
        DispatchQueue.main.async {
            guard let view = window?.contentView, let window else { return }
            let local = view.convert(window.convertPoint(fromScreen: point), from: nil)
            NSSharingServicePicker(items: urls).show(relativeTo: NSRect(origin: local, size: CGSize(width: 1, height: 1)),
                                                     of: view, preferredEdge: .maxY)
        }
    }
}

final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Lets the first click on a menu item work straight away.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The classic NSMenu used by "Show more options".
enum ClassicMenu {
    final class Item: NSMenuItem {
        var handler: (() -> Void)?
        @objc func fire() { handler?() }
    }

    static func make(_ entries: [WinMenuEntry]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            switch entry.kind {
            case .separator:
                if menu.items.last.map({ !$0.isSeparatorItem }) ?? false { menu.addItem(.separator()) }
            case .toolbar(let buttons):
                for b in buttons {
                    let item = Item(title: b.help, action: #selector(Item.fire), keyEquivalent: "")
                    item.target = item
                    item.handler = b.action
                    item.isEnabled = b.enabled
                    menu.addItem(item)
                }
                menu.addItem(.separator())
            case .submenu(let children):
                let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
                item.submenu = make(children)
                item.isEnabled = entry.enabled
                menu.addItem(item)
            case .item:
                let item = Item(title: entry.title, action: #selector(Item.fire), keyEquivalent: "")
                item.target = item
                item.handler = entry.action
                item.isEnabled = entry.enabled
                item.state = entry.radio ? .on : .off
                if let image = entry.image {
                    let small = image.copy() as? NSImage
                    small?.size = NSSize(width: 16, height: 16)
                    item.image = small
                }
                menu.addItem(item)
            }
        }
        if menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
        return menu
    }
}

// MARK: - Look (Windows 11)

private enum MenuColors {
    static let background = Theme.dynamic(0x2C2C2C, 0xF9F9F9)
    static let border = Theme.dynamic(0xFFFFFF, 0x000000, 0.10, 0.10)
    static let hover = Theme.dynamic(0xFFFFFF, 0x000000, 0.08, 0.05)
    static let separator = Theme.dynamic(0xFFFFFF, 0x000000, 0.10, 0.08)
}

struct WinMenuWindowView: View {
    @ObservedObject var menu: WinMenu

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Clicking outside the menu closes it.
            Color.clear.contentShape(Rectangle()).onTapGesture { menu.close() }
            WinMenuList(menu: menu, entries: menu.root, isRoot: true)
                .frame(width: WinMenu.rootWidth)
                .offset(x: menu.rootX)
            if let sub = menu.sub {
                WinMenuList(menu: menu, entries: sub.entries, isRoot: false)
                    .frame(width: WinMenu.subWidth)
                    .offset(x: menu.subX, y: sub.y)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.easeOut(duration: 0.08), value: menu.sub)
    }
}

struct WinMenuList: View {
    @ObservedObject var menu: WinMenu
    let entries: [WinMenuEntry]
    let isRoot: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                let y = 4 + entries[..<index].reduce(0) { $0 + $1.height }
                switch entry.kind {
                case .separator:
                    Rectangle().fill(MenuColors.separator).frame(height: 1).padding(.vertical, 4)
                case .toolbar(let buttons):
                    HStack(spacing: 2) {
                        ForEach(buttons) { b in ToolbarIcon(button: b, menu: menu) }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 44)
                    .onHover { if $0 && isRoot { menu.hover(entry, y: y) } }
                default:
                    MenuLine(entry: entry, menu: menu, isSubOpen: menu.sub?.rowID == entry.id) {
                        if isRoot { menu.hover(entry, y: y) }
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(MenuColors.background))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(MenuColors.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .padding(1)
    }
}

private struct ToolbarIcon: View {
    let button: WinToolButton
    @ObservedObject var menu: WinMenu
    @State private var hovering = false

    var body: some View {
        Button { if button.enabled { menu.run(button.action) } } label: {
            Image(systemName: button.symbol)
                .font(.system(size: 15))
                .foregroundStyle(Theme.text)
                .frame(width: 40, height: 34)
                .background(RoundedRectangle(cornerRadius: 4).fill(hovering && button.enabled ? MenuColors.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(button.enabled ? 1 : 0.35)
        .onHover { hovering = $0 }
        .help(button.help)
        .accessibilityLabel(button.help)
    }
}

private struct MenuLine: View {
    let entry: WinMenuEntry
    @ObservedObject var menu: WinMenu
    let isSubOpen: Bool
    let onHover: () -> Void
    @State private var hovering = false

    private var isSubmenu: Bool { if case .submenu = entry.kind { return true }; return false }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let image = entry.image {
                    Image(nsImage: image).resizable().interpolation(.high)
                } else if let symbol = entry.symbol {
                    Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(entry.tint ?? Theme.text)
                } else if entry.radio {
                    Circle().fill(Theme.text).frame(width: 6, height: 6)
                }
            }
            .frame(width: 18, height: 18)
            .overlay(alignment: .leading) {
                if entry.radio && (entry.symbol != nil || entry.image != nil) {
                    Circle().fill(Theme.text).frame(width: 5, height: 5).offset(x: -10)
                }
            }
            Text(entry.title).font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 8)
            if !entry.shortcut.isEmpty {
                Text(entry.shortcut).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            if isSubmenu {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
            }
        }
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 4)
            .fill((hovering || isSubOpen) && entry.enabled ? MenuColors.hover : .clear))
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .opacity(entry.enabled ? 1 : 0.4)
        .onHover { inside in
            hovering = inside
            if inside { onHover() }
        }
        .onTapGesture {
            guard entry.enabled else { return }
            if isSubmenu { onHover() } else { menu.run(entry.action) }
        }
    }
}

// MARK: - Right-click detection

/// Every view with a Windows menu registers where it is on screen; a right-click picks the
/// smallest one under the mouse (an item beats the empty space around it).
@MainActor
final class RightClickTargets {
    static let shared = RightClickTargets()

    struct Target {
        var frame: CGRect
        let build: () -> (main: [WinMenuEntry], classic: [WinMenuEntry]?)
        let prepare: (() -> Void)?
    }

    private var targets: [UUID: Target] = [:]
    private var monitor: Any?

    func set(_ id: UUID, _ target: Target?) {
        targets[id] = target
        installIfNeeded()
    }

    func updateFrame(_ id: UUID, _ frame: CGRect) { targets[id]?.frame = frame }

    private func installIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
            MainActor.assumeIsolated { RightClickTargets.shared.handle(event) }
        }
    }

    func handle(_ event: NSEvent) -> NSEvent? {
        let isContextClick = event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        guard isContextClick, let window = event.window, !(window is MenuPanel),
              let view = window.contentView else { return event }
        // Leave text fields (rename box, address bar, search) their own menu.
        if window.firstResponder is NSTextView,
           let hit = view.hitTest(view.convert(event.locationInWindow, from: nil)), hit is NSTextView || hit is NSTextField {
            return event
        }
        var p = view.convert(event.locationInWindow, from: nil)
        if !view.isFlipped { p.y = view.bounds.height - p.y }
        guard let target = targets.values
            .filter({ $0.frame.contains(p) })
            .min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return event }
        target.prepare?()
        let built = target.build()
        let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
        WinMenu.shared.show(built.main, classic: built.classic, at: screenPoint, in: window)
        return nil
    }
}

struct WinContextMenuModifier: ViewModifier {
    let prepare: (() -> Void)?
    let build: () -> (main: [WinMenuEntry], classic: [WinMenuEntry]?)
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { geo in
                let frame = Self.visibleFrame(geo)
                Color.clear
                    .onAppear {
                        RightClickTargets.shared.set(id, .init(frame: frame, build: build, prepare: prepare))
                    }
                    .onChange(of: frame) { _, new in RightClickTargets.shared.updateFrame(id, new) }
                    .onDisappear { RightClickTargets.shared.set(id, nil) }
            }
        )
        .background(RegistrationRefresher(id: id, build: build, prepare: prepare))
    }

    /// The part of the view that's actually visible inside its scroll view.
    static func visibleFrame(_ geo: GeometryProxy) -> CGRect {
        let global = geo.frame(in: .global)
        guard let clip = geo.bounds(of: .scrollView) else { return global }
        let visible = CGRect(x: global.minX + clip.minX, y: global.minY + clip.minY, width: clip.width, height: clip.height)
        return global.intersection(visible)
    }
}

/// Keeps the registered menu builder current each time the view is redrawn.
private struct RegistrationRefresher: View {
    let id: UUID
    let build: () -> (main: [WinMenuEntry], classic: [WinMenuEntry]?)
    let prepare: (() -> Void)?

    var body: some View {
        RightClickTargets.shared.refresh(id, build: build, prepare: prepare)
        return Color.clear
    }
}

extension RightClickTargets {
    func refresh(_ id: UUID, build: @escaping () -> (main: [WinMenuEntry], classic: [WinMenuEntry]?), prepare: (() -> Void)?) {
        guard let old = targets[id] else { return }
        targets[id] = Target(frame: old.frame, build: build, prepare: prepare)
    }
}

extension View {
    /// Windows 11 right-click menu. `classic` is what "Show more options" lists (defaults to the same items).
    func winContextMenu(prepare: (() -> Void)? = nil,
                        _ build: @escaping () -> (main: [WinMenuEntry], classic: [WinMenuEntry]?)) -> some View {
        modifier(WinContextMenuModifier(prepare: prepare, build: build))
    }

    func winContextMenu(prepare: (() -> Void)? = nil, _ build: @escaping () -> [WinMenuEntry]) -> some View {
        modifier(WinContextMenuModifier(prepare: prepare, build: { (build(), nil) }))
    }
}
