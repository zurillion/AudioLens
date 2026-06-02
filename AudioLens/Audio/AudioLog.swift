import Foundation

/// Centralised diagnostic logging. Bumps `buildMarker` whenever we want to
/// confirm at runtime that a fresh build is actually running (stale Xcode
/// build products have repeatedly masked changes during development).
/// Emits via both NSLog and print because Xcode 26's console has, in this
/// project, intermittently shown only one of the two.
enum AudioLog {
    static let buildMarker = "v9"

    static func log(_ message: @autoclosure () -> String) {
        let line = "[AudioLens \(buildMarker)] \(message())"
        NSLog("%@", line)
        print(line)
    }
}
