# Folders

**A Windows-style file manager for Mac.** If you've switched from Windows and miss File Explorer, Folders gives you the layout and habits you already know: This PC, tabs, a navigation pane, the Windows 11 right-click menu, and Ctrl+C / Ctrl+V for files (⌘C / ⌘V on a Mac).

Folders is an independent project. It isn't made by, affiliated with, or endorsed by Microsoft or Apple.

## Features

- **This PC** with your Mac's disk shown as **Macintosh HD (C:)**, its free space bar, and opened disk images inside it
- **Tabs**: new, duplicate, close, close others, close to the right, ⌃Tab to switch
- **Navigation pane**: Home, Gallery, iCloud Drive, pinned Quick access folders, This PC tree
- **Address bar** with clickable path, plus typing paths, including Windows ones like `C:\Users`
- **8 views**: Extra large, Large, Medium and Small icons, List, Details, Tiles, Content, plus Compact view
- **Sort and group** by name, date, type and size (Downloads groups by date, like Windows)
- **Windows 11 right-click menu** with the Cut / Copy / Rename / Share / Delete row, flyouts and *Show more options*
- **Cut, copy, paste** with progress and a *Replace or Skip Files* dialog
- **Undo** for rename, move, copy, new and delete
- **Delete** to the Trash, or **Shift+Delete** for permanent delete
- **Compress to ZIP / Extract All**, **Rotate** pictures, **Set as desktop background**, **Copy as path**, **Open in Terminal**
- **Search** in the current folder, or **Search This PC** across the whole Mac with Spotlight
- **Details pane**, **Preview pane**, and **Space bar preview** (tap to open, hold to peek)
- **Properties** for files, folders and drives, with a pie chart for disk space
- **Dark and light themes**, sizes shown in MB / GB, Windows-style dates and names (`New folder (2)`, `Report - Copy.pdf`)

## Install

1. Download **Folders-x.y.dmg** from [Releases](../../releases).
2. Open it and drag **Folders** onto **Applications**.
3. Open Folders from Launchpad or Spotlight.

Requires macOS 14 (Sonoma) or newer. Works on Apple silicon and Intel Macs.

### "Apple could not verify Folders…"

Folders isn't notarized by Apple yet, so the first time you open it macOS shows a warning with no Open button. To open it anyway:

1. Click **Done** on the warning.
2. Open **System Settings → Privacy & Security** and scroll down.
3. Next to *"Folders" was blocked to protect your Mac*, click **Open Anyway**.
4. Confirm with your password or Touch ID, then click **Open**.

You only need to do this once per version. The full source code is in this repository, so you can check what it does or build it yourself.

## Keyboard shortcuts

Windows' **Ctrl** is **⌘** on a Mac.

| Action | Shortcut |
|---|---|
| Copy / Cut / Paste | ⌘C / ⌘X / ⌘V |
| Undo | ⌘Z |
| Delete (to Trash) | ⌘⌫ or Fn+⌫ |
| Delete permanently | ⌥⌘⌫ or Shift+Fn+⌫ |
| Rename | F2 |
| Preview | Space |
| Properties | ⌘I or ⌥↩ |
| New folder | ⇧⌘N |
| New tab / Close tab | ⌘T / ⌘W |
| Back / Forward / Up | ⌘[ / ⌘] / ⌘↑ (or ⌫ for Back) |
| Address bar / Search | ⌘L / ⌘F |
| Refresh | ⌘R or F5 |
| Views | ⇧⌘1 … ⇧⌘8 |

## Build it yourself

You need Xcode (or the Xcode command-line tools).

```bash
./build.sh       # makes build/Folders.app (universal: Apple silicon + Intel)
./make-dmg.sh    # makes build/Folders-<version>.dmg
```

Run the built-in self-test (it uses a scratch folder and never touches your files or clipboard):

```bash
MYMAC_SELFTEST=/tmp/folders-selftest "build/Folders.app/Contents/MacOS/MyMac"
```

## Licence

MIT. See [LICENSE](LICENSE).
