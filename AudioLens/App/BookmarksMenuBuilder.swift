import AppKit
import AVFoundation

/// Builds the Bookmarks menu contents, shared by the menu-bar menu and the
/// in-window popup so both stay identical. Item actions target nil and travel
/// the responder chain to MainWindowController.
@MainActor
enum BookmarksMenuBuilder {

    static func populate(_ menu: NSMenu,
                         entries: [(frame: AVAudioFramePosition, label: String)]) {
        menu.removeAllItems()

        menu.addItem(commandItem("Add Bookmark", #selector(MainWindowController.addBookmark(_:))))
        menu.addItem(.separator())
        menu.addItem(commandItem("Next Bookmark", #selector(MainWindowController.nextBookmark(_:))))
        menu.addItem(commandItem("Previous Bookmark", #selector(MainWindowController.previousBookmark(_:))))
        menu.addItem(commandItem("First Bookmark", #selector(MainWindowController.firstBookmark(_:))))
        menu.addItem(commandItem("Last Bookmark", #selector(MainWindowController.lastBookmark(_:))))
        menu.addItem(.separator())

        if entries.isEmpty {
            let item = NSMenuItem(title: "No Bookmarks", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }

        let hint = NSMenuItem(title: "⌥-select to delete · ⌘-select to rename",
                              action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        for (index, entry) in entries.enumerated() {
            let item = NSMenuItem(title: "\(index + 1).  \(entry.label)",
                                  action: #selector(MainWindowController.openBookmark(_:)),
                                  keyEquivalent: "")
            item.representedObject = NSNumber(value: entry.frame)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(commandItem("Clear Bookmarks", #selector(MainWindowController.clearBookmarks(_:))))
    }

    private static func commandItem(_ title: String, _ selector: Selector) -> NSMenuItem {
        NSMenuItem(title: title, action: selector, keyEquivalent: "")
    }
}
