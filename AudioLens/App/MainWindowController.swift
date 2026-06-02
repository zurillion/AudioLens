import AppKit
import UniformTypeIdentifiers

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {

    private let audioEngine = AudioEngine()
    private let rootViewController: MainViewController
    private var tabKeyMonitor: Any?

    init() {
        rootViewController = MainViewController(audioEngine: audioEngine)

        let window = NSWindow(
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
        installTabKeyMonitor()
    }

    /// Tab (keyCode 48) is consumed by AppKit's key-view focus loop before it
    /// ever reaches a menu key equivalent, so a "\t" menu shortcut never fires.
    /// Intercept it with a local event monitor instead. This app has no text
    /// fields that need Tab for focus traversal, so consuming it is safe.
    private func installTabKeyMonitor() {
        tabKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local key monitors are delivered on the main thread; assume the
            // isolation so we can touch the MainActor-bound engine directly.
            MainActor.assumeIsolated {
                guard let self,
                      event.window === self.window,
                      event.keyCode == 48,
                      !event.modifierFlags.contains(.command) else {
                    return event
                }
                self.audioEngine.seekToStart()
                return nil  // consume
            }
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
