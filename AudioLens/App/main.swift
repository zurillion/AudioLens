import AppKit

// Programmatic AppKit entry point. A file named exactly `main.swift` lets its
// top-level code act as the executable's entry point (and it runs on the main
// actor under Swift concurrency). We build the menu and window explicitly here,
// before starting the run loop, rather than relying on the
// applicationDidFinishLaunching notification.
NSLog("[AudioLens] main.swift entry")
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
delegate.setUp()
application.activate(ignoringOtherApps: true)
NSLog("[AudioLens] starting run loop")
application.run()
