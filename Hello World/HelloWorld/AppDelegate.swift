import Cocoa

// NOTE: no @main here. In AppKit, @main / NSApplicationMain does not connect
// the delegate unless a storyboard/nib does it. For a programmatic app the
// delegate is created and assigned explicitly in main.swift.
class AppDelegate: NSObject, NSApplicationDelegate {

    var window: NSWindow!

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        NSLog("[HelloWorld] applicationDidFinishLaunching FIRED")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Hello World"

        let label = NSTextField(labelWithString: "Hello, World!")
        label.font = NSFont.systemFont(ofSize: 36, weight: .semibold)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
        window.contentView = contentView

        window.makeKeyAndOrderFront(nil)
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
