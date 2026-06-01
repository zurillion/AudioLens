import AppKit

// Minimal AppKit window with no Xcode project at all.
// Run from Terminal:   cd HelloWorldSPM && swift run
// If a window with "Hello, World!" appears, the AppKit code is fine and the
// earlier failures were entirely about the hand-written .xcodeproj.

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
    styleMask: [.titled, .closable, .miniaturizable, .resizable],
    backing: .buffered,
    defer: false
)
window.center()
window.title = "Hello World (SwiftPM)"

let label = NSTextField(labelWithString: "Hello, World!")
label.font = NSFont.systemFont(ofSize: 36, weight: .semibold)
label.alignment = .center
label.translatesAutoresizingMaskIntoConstraints = false

let content = NSView()
content.addSubview(label)
NSLayoutConstraint.activate([
    label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
    label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
])
window.contentView = content
window.makeKeyAndOrderFront(nil)

app.activate(ignoringOtherApps: true)
app.run()
