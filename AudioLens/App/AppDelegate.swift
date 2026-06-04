import AppKit

// NOTE: no @main. In AppKit, @main / NSApplicationMain does not connect the
// delegate without a storyboard or nib, so applicationDidFinishLaunching never
// fires and no window appears. The app is created and the delegate assigned
// explicitly in main.swift instead.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var mainWindowController: MainWindowController?
    private var preferencesWindowController: PreferencesWindowController?
    private let recentMenuDelegate = RecentFilesMenuDelegate()
    private let bookmarksMenuDelegate = BookmarksMenuDelegate()

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()

        let controller = MainWindowController()
        mainWindowController = controller
        bookmarksMenuDelegate.windowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// Files dropped on the Dock icon (or opened via the Finder "Open With").
    /// We're a single-window player, so open the last URL.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.last else { return }
        mainWindowController?.openURL(url)
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        // Application menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About AudioLens",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Settings…",
                        action: #selector(showPreferences(_:)),
                        keyEquivalent: ",")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide AudioLens",
                        action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit AudioLens",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        // File menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open…",
                         action: #selector(MainWindowController.openFile(_:)),
                         keyEquivalent: "o")

        let openRecentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let openRecentMenu = NSMenu(title: "Open Recent")
        openRecentMenu.delegate = recentMenuDelegate
        // Cocoa autoenablesItems is true by default; recompute on open.
        openRecentMenu.autoenablesItems = false
        openRecentItem.submenu = openRecentMenu
        fileMenu.addItem(openRecentItem)
        fileMenuItem.submenu = fileMenu

        // Controls menu. The keyboard shortcuts for these actions are not set
        // here as menu key equivalents — they're handled by
        // AudioLensWindow.sendEvent reading KeyBindings.shared, so they stay in
        // sync with what the user sets in Preferences. The menu items remain
        // clickable, and shortcuts can be inspected/changed in Preferences.
        let controlsMenuItem = NSMenuItem()
        mainMenu.addItem(controlsMenuItem)
        let controlsMenu = NSMenu(title: "Controls")
        controlsMenu.addItem(NSMenuItem(
            title: "Play / Pause",
            action: #selector(MainWindowController.togglePlayPause(_:)),
            keyEquivalent: ""
        ))
        controlsMenu.addItem(NSMenuItem(
            title: "Stop",
            action: #selector(MainWindowController.stopPlayback(_:)),
            keyEquivalent: ""
        ))
        controlsMenu.addItem(NSMenuItem(
            title: "Go to Start",
            action: #selector(MainWindowController.goToStart(_:)),
            keyEquivalent: ""
        ))
        controlsMenuItem.submenu = controlsMenu

        // Bookmarks menu. Add / navigation items are clickable here; their
        // keyboard shortcuts live in KeyBindings (Preferences). The list of
        // bookmarks is filled on open by the delegate.
        let bookmarksMenuItem = NSMenuItem()
        bookmarksMenuItem.title = "Bookmarks"
        mainMenu.addItem(bookmarksMenuItem)
        let bookmarksMenu = NSMenu(title: "Bookmarks")
        bookmarksMenu.autoenablesItems = false
        bookmarksMenu.delegate = bookmarksMenuDelegate
        bookmarksMenuItem.submenu = bookmarksMenu

        NSApp.mainMenu = mainMenu
    }

    @objc func showPreferences(_ sender: Any?) {
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController()
        }
        preferencesWindowController?.showWindow(nil)
        preferencesWindowController?.window?.makeKeyAndOrderFront(nil)
    }
}

/// Populates the "Open Recent" submenu from NSDocumentController's recent
/// document list. NSDocumentController works fine in non-NSDocument apps and
/// handles security-scoped bookmark persistence transparently under the App
/// Sandbox.
@MainActor
final class RecentFilesMenuDelegate: NSObject, NSMenuDelegate {

    private let maxItems = 10

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let urls = NSDocumentController.shared.recentDocumentURLs

        if urls.isEmpty {
            let item = NSMenuItem(title: "No Recent Files", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }

        for url in urls.prefix(maxItems) {
            let item = NSMenuItem(
                title: url.lastPathComponent,
                action: #selector(MainWindowController.openRecentFile(_:)),
                keyEquivalent: ""
            )
            item.representedObject = url
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Clear Menu",
            action: #selector(NSDocumentController.clearRecentDocuments(_:)),
            keyEquivalent: ""
        ))
    }
}

/// Builds the Bookmarks menu on open: add/navigation commands, then the list
/// of bookmarks (timecoded, time-ordered) which seek when chosen.
@MainActor
final class BookmarksMenuDelegate: NSObject, NSMenuDelegate {

    weak var windowController: MainWindowController?

    func menuNeedsUpdate(_ menu: NSMenu) {
        BookmarksMenuBuilder.populate(menu, entries: windowController?.bookmarkEntries ?? [])
    }
}
