import AppKit

/// Window subclass that, while recording is active, captures the next
/// keyDown via its sendEvent override and hands it to the controller. The
/// override is a regular @MainActor method, so it sidesteps the Sendable
/// issues we'd hit with NSEvent.addLocalMonitorForEvents under Swift 6.
@MainActor
final class PreferencesWindow: NSWindow {
    weak var keyRecorder: PreferencesWindowController?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyRecorder?.handleRecordingKeyDown(event) == true {
            return
        }
        super.sendEvent(event)
    }
}

@MainActor
final class PreferencesWindowController: NSWindowController,
                                         NSTableViewDelegate,
                                         NSTableViewDataSource,
                                         NSTabViewDelegate {

    private let tableView = NSTableView()
    private let actions = KeyboardAction.allCases
    private let statusLabel = NSTextField(labelWithString: "Select a row and click Record to assign a new shortcut.")
    private let recordButton = NSButton(title: "Record…", target: nil, action: nil)

    private let cacheSizeLabel = NSTextField(labelWithString: "")
    private let cacheStatusLabel = NSTextField(labelWithString: "")

    private var bindingsObserver: (any NSObjectProtocol)?
    private var recordingAction: KeyboardAction?

    init() {
        let window = PreferencesWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Preferences"
        window.contentMinSize = NSSize(width: 380, height: 320)
        window.center()
        super.init(window: window)
        window.keyRecorder = self
        setupContent()
        bindingsObserver = NotificationCenter.default.addObserver(
            forName: .keyBindingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.tableView.reloadData() }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setupContent() {
        guard let content = window?.contentView else { return }

        let tabView = NSTabView()
        tabView.delegate = self
        tabView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tabView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            tabView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            tabView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])

        let shortcutsItem = NSTabViewItem(identifier: "shortcuts")
        shortcutsItem.label = "Shortcuts"
        shortcutsItem.view = makeShortcutsView()
        tabView.addTabViewItem(shortcutsItem)

        let themesItem = NSTabViewItem(identifier: "themes")
        themesItem.label = "Themes"
        themesItem.view = makeThemesView()
        tabView.addTabViewItem(themesItem)

        let cacheItem = NSTabViewItem(identifier: "cache")
        cacheItem.label = "Cache"
        cacheItem.view = makeCacheView()
        tabView.addTabViewItem(cacheItem)

        tableView.reloadData()
    }

    private func makeThemesView() -> NSView {
        let container = NSView()

        let title = NSTextField(labelWithString: "Interface Theme")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        let desc = NSTextField(wrappingLabelWithString:
            "Themes tint the waveform stroke, the filename label, and the "
            + "follow-playhead button. Semantic colours (playhead, loop, "
            + "bookmarks, VU meter) stay constant across themes.")
        desc.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        desc.textColor = .secondaryLabelColor

        // One radio button per theme, with a colour swatch on its right.
        let currentID = ThemeManager.shared.current.id
        var rows: [NSView] = []
        for theme in AppTheme.all {
            let radio = NSButton(radioButtonWithTitle: theme.displayName,
                                 target: self,
                                 action: #selector(themeSelected(_:)))
            radio.identifier = NSUserInterfaceItemIdentifier(theme.id)
            radio.state = (theme.id == currentID) ? .on : .off
            // Three tiny swatches showing waveform / filename / follow tones.
            let swatchRow = NSStackView(views: [
                makeSwatch(color: theme.waveformRGB.nsColor),
                makeSwatch(color: theme.filenameRGB.nsColor),
                makeSwatch(color: theme.followOnRGB.nsColor),
            ])
            swatchRow.orientation = .horizontal
            swatchRow.spacing = 3
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let row = NSStackView(views: [radio, spacer, swatchRow])
            row.orientation = .horizontal
            row.alignment = .centerY
            rows.append(row)
        }

        let radioStack = NSStackView(views: rows)
        radioStack.orientation = .vertical
        radioStack.alignment = .leading
        radioStack.spacing = 6
        radioStack.distribution = .fill

        let stack = NSStackView(views: [title, desc, radioStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            desc.widthAnchor.constraint(equalTo: stack.widthAnchor),
            radioStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return container
    }

    private func makeSwatch(color: NSColor) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = color.cgColor
        v.layer?.cornerRadius = 3
        v.layer?.borderWidth = 0.5
        v.layer?.borderColor = NSColor.separatorColor.cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 14).isActive = true
        v.heightAnchor.constraint(equalToConstant: 14).isActive = true
        return v
    }

    @objc private func themeSelected(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let theme = AppTheme.all.first(where: { $0.id == id }) else { return }
        ThemeManager.shared.setTheme(theme)
    }

    private func makeShortcutsView() -> NSView {
        let container = NSView()

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        let actionCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("action"))
        actionCol.title = "Action"
        actionCol.minWidth = 160
        actionCol.width = 240
        tableView.addTableColumn(actionCol)

        let shortcutCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("shortcut"))
        shortcutCol.title = "Shortcut"
        shortcutCol.minWidth = 120
        shortcutCol.width = 160
        tableView.addTableColumn(shortcutCol)

        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.style = .inset
        tableView.allowsMultipleSelection = false
        tableView.doubleAction = #selector(beginRecording(_:))
        tableView.target = self

        recordButton.target = self
        recordButton.action = #selector(beginRecording(_:))
        recordButton.keyEquivalent = "\r"

        let resetButton = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults(_:)))

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 2
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let buttonStack = NSStackView(views: [resetButton, spacer, recordButton])
        buttonStack.orientation = .horizontal
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(statusLabel)
        container.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -10),

            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            statusLabel.bottomAnchor.constraint(equalTo: buttonStack.topAnchor, constant: -10),

            buttonStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            buttonStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            buttonStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        return container
    }

    private func makeCacheView() -> NSView {
        let container = NSView()

        let title = NSTextField(labelWithString: "Waveform Preview Cache")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        let desc = NSTextField(wrappingLabelWithString:
            "AudioLens stores each file's computed waveform overview on disk so it "
            + "reloads instantly the next time you open it. Clearing the cache is "
            + "always safe — overviews are simply recomputed on next open.")
        desc.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        desc.textColor = .secondaryLabelColor

        cacheSizeLabel.font = .systemFont(ofSize: NSFont.systemFontSize)

        cacheStatusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        cacheStatusLabel.textColor = .secondaryLabelColor

        let clearButton = NSButton(title: "Clear Cache", target: self, action: #selector(clearCache(_:)))
        let revealButton = NSButton(title: "Reveal in Finder", target: self, action: #selector(revealCache(_:)))
        let buttonRow = NSStackView(views: [clearButton, revealButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let stack = NSStackView(views: [title, desc, cacheSizeLabel, buttonRow, cacheStatusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            // Pin the wrapping description to the full content width so it wraps
            // instead of collapsing to its longest token.
            desc.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        updateCacheSizeLabel()
        return container
    }

    // MARK: - Cache

    private func updateCacheSizeLabel() {
        let bytes = WaveformCache.totalSize()
        let count = WaveformCache.entryCount()
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        let fileWord = count == 1 ? "file" : "files"
        cacheSizeLabel.stringValue = "Current size: \(size)  (\(count) \(fileWord))"
    }

    @objc private func clearCache(_ sender: NSButton) {
        let freed = WaveformCache.clear()
        updateCacheSizeLabel()
        let size = ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)
        cacheStatusLabel.stringValue = freed > 0 ? "Freed \(size)." : "Cache was already empty."
    }

    @objc private func revealCache(_ sender: NSButton) {
        guard let dir = WaveformCache.directoryURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        if tabViewItem?.identifier as? String == "cache" {
            updateCacheSizeLabel()
            cacheStatusLabel.stringValue = ""
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { actions.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let action = actions[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "action":   text = action.displayName
        case "shortcut": text = KeyBindings.shared.shortcut(for: action).displayString
        default:         text = ""
        }
        let field = NSTextField(labelWithString: text)
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    // MARK: - Recording

    @objc private func beginRecording(_ sender: Any?) {
        let row = tableView.selectedRow
        guard row >= 0 && row < actions.count else {
            statusLabel.stringValue = "Select an action first, then click Record."
            return
        }
        let action = actions[row]
        recordingAction = action
        recordButton.isEnabled = false
        statusLabel.stringValue = "Press the new shortcut for \(action.displayName) (Esc to cancel)…"
        // Make the window key so its sendEvent override receives the next keydown.
        window?.makeFirstResponder(window)
    }

    /// Called from PreferencesWindow.sendEvent for every keyDown while the
    /// window is key. Returns true to consume the event.
    func handleRecordingKeyDown(_ event: NSEvent) -> Bool {
        guard let action = recordingAction else { return false }

        if event.keyCode == 53 {  // Esc: cancel
            statusLabel.stringValue = "Cancelled."
            finishRecording()
            return true
        }

        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let shortcut = KeyShortcut(keyCode: event.keyCode, modifiers: mods)

        if let conflict = conflictingAction(for: shortcut, excluding: action) {
            statusLabel.stringValue = "\(shortcut.displayString) is already used by \"\(conflict.displayName)\"."
            presentConflictAlert(shortcut: shortcut, existingAction: conflict)
            finishRecording()
            return true
        }

        KeyBindings.shared.setShortcut(shortcut, for: action)
        statusLabel.stringValue = "Set \(action.displayName) → \(shortcut.displayString)"
        finishRecording()
        return true
    }

    /// Returns the first other action whose current binding matches `shortcut`,
    /// or nil if there's no conflict.
    private func conflictingAction(for shortcut: KeyShortcut,
                                   excluding action: KeyboardAction) -> KeyboardAction? {
        for candidate in KeyboardAction.allCases where candidate != action {
            if KeyBindings.shared.shortcut(for: candidate) == shortcut {
                return candidate
            }
        }
        return nil
    }

    private func presentConflictAlert(shortcut: KeyShortcut,
                                      existingAction: KeyboardAction) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Shortcut already in use"
        alert.informativeText = "\(shortcut.displayString) is assigned to \"\(existingAction.displayName)\". "
            + "Choose a different shortcut, or change the existing assignment first."
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    private func finishRecording() {
        recordingAction = nil
        recordButton.isEnabled = true
    }

    @objc private func restoreDefaults(_ sender: NSButton) {
        KeyBindings.shared.restoreDefaults()
        statusLabel.stringValue = "Restored default shortcuts."
    }
}
