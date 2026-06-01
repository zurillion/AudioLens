import AppKit

// Programmatic AppKit entry point. A file named exactly `main.swift` lets its
// top-level code act as the executable's entry point (and it runs on the main
// actor under Swift concurrency). This bootstraps NSApplication explicitly
// instead of relying on @main / @NSApplicationMain, which is the reliable way
// to launch a storyboard-less AppKit app.
NSLog("[AudioLens] main.swift entry")
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
NSLog("[AudioLens] starting run loop")
application.run()
