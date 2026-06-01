import AppKit
import UniformTypeIdentifiers

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {

    private let audioEngine = AudioEngine()
    private let rootViewController: MainViewController

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
        window.center()
        window.setFrameAutosaveName("AudioLensMainWindow")

        super.init(window: window)
        window.delegate = self
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

    private func load(url: URL) async {
        do {
            try await audioEngine.load(url: url)
            rootViewController.didLoadAudio()
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
