import AppKit
import UniformTypeIdentifiers

/// Window subclass that intercepts plain Tab in `sendEvent` and forwards it
/// to the controller. NSEvent's local key monitor approach trips Swift 6's
/// Sendable checking when reaching back into a MainActor-isolated controller,
/// and a "\t" menu key equivalent never fires because AppKit's key-view focus
/// loop consumes Tab first. Subclassing skips both problems: sendEvent runs
/// on the main thread by definition (no Sendable closure crossing) and
/// catches the event before any responder processing.
@MainActor
final class AudioLensWindow: NSWindow {
    var onTabKey: (() -> Void)?
    /// Signed seconds to seek (negative = backward), computed from the arrow
    /// key direction and its modifiers.
    var onSeekRelative: ((Double) -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            let mods = event.modifierFlags
            switch event.keyCode {
            case 48:  // Tab
                if !mods.contains(.command), !mods.contains(.option), !mods.contains(.control) {
                    onTabKey?()
                    return
                }
            case 123, 124:  // Left, Right arrows
                let magnitude = Self.seekSeconds(for: mods)
                let direction: Double = (event.keyCode == 123) ? -1 : 1
                AudioLog.log("arrow seek: keyCode=\(event.keyCode) seconds=\(magnitude * direction)")
                onSeekRelative?(magnitude * direction)
                return
            default:
                break
            }
        }
        super.sendEvent(event)
    }

    /// Step size for arrow-key seeking, per the requested modifier mapping.
    private static func seekSeconds(for mods: NSEvent.ModifierFlags) -> Double {
        if mods.contains(.command) { return 30 }
        if mods.contains(.option) { return 10 }
        if mods.contains(.control) { return 5 }
        return 2.5
    }
}

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {

    private let audioEngine = AudioEngine()
    private let rootViewController: MainViewController

    init() {
        rootViewController = MainViewController(audioEngine: audioEngine)

        let window = AudioLensWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "AudioLens"
        window.titlebarAppearsTransparent = false
        window.contentViewController = rootViewController
        // Below this size the EQ row's height (computed from the residual
        // space after the waveform / transport / pitch-time bands) becomes
        // negative and AppKit logs "Invalid view geometry" warnings.
        window.contentMinSize = NSSize(width: 800, height: 520)
        window.center()

        super.init(window: window)
        window.delegate = self
        window.onTabKey = { [weak self] in
            self?.audioEngine.seekToStart()
        }
        window.onSeekRelative = { [weak self] seconds in
            self?.audioEngine.seekRelative(seconds: seconds)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc func openFile(_ sender: Any?) {
        Task {
            guard let window = self.window else { return }
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.allowedContentTypes = AudioFileLoader.supportedContentTypes

            let response = await panel.beginSheetModal(for: window)
            guard response == .OK, let url = panel.url else { return }
            await load(url: url)
        }
    }

    @objc func openRecentFile(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        Task {
            // Bookmarks resolved by NSDocumentController are session-valid,
            // but we still ask for security-scoped access in case the URL
            // came from a different scope.
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            await load(url: url)
        }
    }

    @objc func togglePlayPause(_ sender: Any?) {
        audioEngine.togglePlayPause()
    }

    @objc func stopPlayback(_ sender: Any?) {
        audioEngine.stop()
    }

    @objc func goToStart(_ sender: Any?) {
        audioEngine.seekToStart()
    }

    private func load(url: URL) async {
        do {
            try await audioEngine.load(url: url)
            rootViewController.didLoadAudio()
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            showError(error)
        }
    }

    private func showError(_ error: any Error) {
        guard let window else { return }
        let alert = NSAlert(error: error)
        alert.beginSheetModal(for: window, completionHandler: nil)
    }
}
