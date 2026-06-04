import AppKit
import AVFoundation

/// Modal sheet that edits a bookmark's name. Shared by the loop/bookmark
/// handle (Cmd-click) and the bookmark menus (Cmd-select).
@MainActor
enum BookmarkRenamePrompt {

    static func present(in window: NSWindow?, engine: AudioEngine, frame: AVAudioFramePosition) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Name Bookmark"
        alert.informativeText = "At \(AudioEngine.formatTimecode(Double(frame) / engine.sampleRate))"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = engine.nameOfBookmark(at: frame) ?? ""
        field.placeholderString = "Bookmark name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                engine.renameBookmark(at: frame, to: field.stringValue)
            }
        }
    }
}
