import AppKit

/// "Quit Finder when Folders starts" (Folder Options → Advanced settings).
///
/// Finder can't be removed, but it can be quit like any other app once its own
/// "Quit Finder" menu item is enabled (otherwise macOS starts it again straight away).
/// At login, Folders may start before Finder does, so for a short while after Folders
/// starts it also quits Finder as soon as Finder appears. After that window, Finder is
/// left alone, so opening it yourself (Dock, AirDrop, emptying the Trash) still works.
@MainActor
enum FinderControl {
    static let finderID = "com.apple.finder"
    /// How long after Folders starts a newly launched Finder is quit.
    private static let watchSeconds: TimeInterval = 60
    private static var observer: NSObjectProtocol?

    /// Called once when Folders finishes launching.
    static func startIfEnabled() {
        guard Prefs.shared.quitFinderAtStart, !AppDefaults.isDevRun else { return }
        enableQuitMenuItem()
        quitRunningFinder()

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == finderID else { return }
            MainActor.assumeIsolated { quitRunningFinder() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + watchSeconds) {
            MainActor.assumeIsolated { stopWatching() }
        }
    }

    /// Turning the setting on applies it straight away; turning it off stops watching.
    static func settingChanged(_ on: Bool) {
        if on {
            enableQuitMenuItem()
            quitRunningFinder()
        } else {
            stopWatching()
        }
    }

    private static func stopWatching() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }

    /// Finder ignores quit requests while it is still starting up, so ask now and
    /// again a little later. A polite quit (like ⌘Q), never a kill: a killed Finder
    /// is restarted by macOS at once.
    private static func quitRunningFinder() {
        for delay in [1.5, 4.0, 8.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                for finder in NSRunningApplication.runningApplications(withBundleIdentifier: finderID)
                where !finder.isTerminated {
                    finder.terminate()
                }
            }
        }
    }

    /// Same as `defaults write com.apple.finder QuitMenuItem -bool true`.
    /// Finder reads it when it starts, so it takes effect from Finder's next launch.
    private static func enableQuitMenuItem() {
        guard let finderPrefs = UserDefaults(suiteName: finderID),
              !finderPrefs.bool(forKey: "QuitMenuItem") else { return }
        finderPrefs.set(true, forKey: "QuitMenuItem")
    }
}
