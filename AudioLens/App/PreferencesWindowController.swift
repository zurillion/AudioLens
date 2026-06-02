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
                                         NSTableViewDataSource {

    private let tableView = NSTableView()
    private let actions = KeyboardAction.allCases
    private let statusLabel = NSTextField(labelWithString: "Select a row and click Record to assign a new shortcut.")
    private let recordButton = NSButton(title: "Record…", target: nil, action: nil)

    private var bindingsObserver: NSObjectProtocol?
    private var recordingAction: KeyboardAction?

    init() {
        let window = PreferencesWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Preferences — Keyboard Shortcuts"
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

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scrollView)

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

        content.addSubview(statusLabel)
        content.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -10),

            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            statusLabel.bottomAnchor.constraint(equalTo: buttonStack.topAnchor, constant: -10),

            buttonStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            buttonStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttonStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])

        tableView.reloadData()
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
