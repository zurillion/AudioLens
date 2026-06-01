import Cocoa

// Explicit, programmatic AppKit entry point (no @main, no storyboard).
// This is the part that was missing: NSApplicationMain alone never connects
// the AppDelegate without a storyboard, so its launch callback never fires.
// Here we create the application, assign the delegate by hand, and run.
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
