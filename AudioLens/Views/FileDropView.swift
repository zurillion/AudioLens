import AppKit
import UniformTypeIdentifiers

/// Root content view that accepts audio-file drops anywhere over the window.
/// It's used as the container view, so its interactive children (waveform,
/// transport, EQ) still receive mouse events normally — AppKit resolves a drop
/// to the nearest registered ancestor, which is this view. Calls `onDrop` with
/// the first dropped audio file URL.
@MainActor
final class FileDropView: NSView {

    var onDrop: ((URL) -> Void)?

    /// Highlight border shown while a valid drag hovers.
    private var isHighlighted = false {
        didSet {
            guard oldValue != isHighlighted else { return }
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        isHighlighted = firstAudioURL(in: sender) != nil
        return isHighlighted ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        isHighlighted = false
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        isHighlighted = false
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        firstAudioURL(in: sender) != nil
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        isHighlighted = false
        guard let url = firstAudioURL(in: sender) else { return false }
        onDrop?(url)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHighlighted, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let inset = bounds.insetBy(dx: 2, dy: 2)
        let path = NSBezierPath(roundedRect: inset, xRadius: 8, yRadius: 8)
        path.lineWidth = 3
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        path.stroke()
    }

    /// First dragged item that is a file URL with an audio-ish extension.
    private func firstAudioURL(in info: any NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        guard let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [URL] else {
            return nil
        }
        return urls.first { AudioFileLoader.isLikelyAudioFile($0) }
    }
}
