import AppKit

/// Minimal modal sheet shown during stem separation. Just an indeterminate
/// spinner + a Cancel button — demucs.cpp doesn't report intermediate
/// progress today, so a real progress bar would lie. Phase 5 will replace
/// this with an integrated transport-row indicator and a time estimate.
@MainActor
final class StemProgressSheet {

    var onCancel: (() -> Void)?

    private let panel: NSPanel
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private weak var attachedWindow: NSWindow?

    init(filename: String) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 140),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        panel.title = "Separating Stems"
        panel.isFloatingPanel = true

        label.stringValue = "Separating “\(filename)”…\nThis can take a few minutes."
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.lineBreakMode = .byWordWrapping

        spinner.style = .spinning
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)
        spinner.controlSize = .regular

        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped(_:))

        let stack = NSStackView(views: [label, spinner, cancelButton])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        guard let content = panel.contentView else { return }
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
        ])
    }

    func attach(to parent: NSWindow?) {
        guard let parent else { return }
        attachedWindow = parent
        parent.beginSheet(panel)
    }

    func detach() {
        spinner.stopAnimation(nil)
        attachedWindow?.endSheet(panel)
        attachedWindow = nil
    }

    @objc private func cancelTapped(_ sender: NSButton) {
        cancelButton.isEnabled = false
        label.stringValue = "Cancelling…"
        onCancel?()
    }
}
