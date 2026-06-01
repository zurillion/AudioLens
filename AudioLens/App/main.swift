import AppKit

// Explicit, programmatic AppKit entry point (no @main, no storyboard).
// NSApplicationMain alone never connects the AppDelegate without a storyboard,
// which is why the launch callback never fired and no window appeared. Here we
// create the application, assign the delegate by hand, and start the run loop.
// In a file named exactly `main.swift`, this top-level code is the entry point
// (and runs on the main actor under Swift 6 strict concurrency).
let application = NSApplication.shared
application.setActivationPolicy(.regular)
let delegate = AppDelegate()
application.delegate = delegate
application.run()
