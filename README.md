# Folders

**A file manager for Mac that works the way PC users expect.** If you've switched from a PC, Folders gives you the habits you already know (a "This Mac" drive view, tabs, a navigation pane, a full right-click menu, and Ctrl+C / Ctrl+V-style copy and paste for files) in its own clean design, with a colour you choose (green by default).

## ⬇️ Download

### [**Download Folders for Mac**](https://github.com/hprathod499-dev/folders/releases/latest/download/Folders.dmg)

For macOS 14 or newer, on any Mac (Apple silicon or Intel). Free.

1. **Open** the downloaded `Folders.dmg`.
2. **Drag** Folders onto the Applications folder.
3. **Open** Folders from Launchpad.

<details>
<summary><b>macOS says "Apple could not verify Folders"?</b> (first launch only)</summary>

Folders isn't notarized by Apple yet, so the first time you open it macOS blocks it. To allow it:

1. Click **Done** on the warning.
2. Open **System Settings → Privacy & Security** and scroll down.
3. Click **Open Anyway** next to *"Folders" was blocked*, then confirm with your password or Touch ID.

You only need to do this once per version. All the source code is here, so you can see exactly what the app does.
</details>

Folders is an independent project with its own design and code. It isn't made by, affiliated with, or endorsed by Microsoft or Apple. Windows is a trademark of Microsoft Corporation; Mac and macOS are trademarks of Apple Inc. They're mentioned only to describe who the app is for.

## Features

- **This Mac**, showing your disk as **Macintosh HD (C:)** with a free-space bar and any opened disk images inside it
- **Tabs**: new, duplicate, close, close others, close to the right, ⌃Tab to switch
- **Navigation pane** with Home, Gallery, iCloud Drive, your **Pinned** folders and a This Mac tree
- **Address bar** with a clickable path; you can type paths too, including drive-letter forms like `C:\Users`
- **8 views**: Extra large, Large, Medium and Small icons, List, Details, Tiles, Content, plus Compact view
- **Sort and group** by name, date, type and size (Downloads groups by date)
- **Right-click menu** with a quick-action row (Cut, Copy, Rename, Share, Delete), submenus and *More options*
- **Cut, copy, paste** with progress and a *Replace or Skip Files* dialog
- **Undo** for rename, move, copy, new and delete
- **Delete** to the Trash, or **Shift+Delete** for permanent delete
- **Compress to ZIP / Extract All**, **Rotate** pictures, **Set as desktop background**, **Copy as path**, **Open in Terminal**
- **Search** in the current folder, or **Search This Mac** across the whole Mac with Spotlight
- **Details pane**, **Preview pane**, and **Space bar preview** (tap to open, hold to peek)
- **Properties** for files, folders and drives, with a disk-space chart
- **Dark and light themes** and **Customise** to pick your colour (green, teal, violet, coral, rose, graphite or yellow), sizes in MB / GB, and familiar names like `New folder (2)` and `Report - Copy.pdf`

## Keyboard shortcuts

A PC's **Ctrl** is **⌘** on a Mac.

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
