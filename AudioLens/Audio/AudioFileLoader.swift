import AVFoundation
import UniformTypeIdentifiers

/// Content types shown in the open panel. We list common ones explicitly so
/// they appear named in the file dialog; SFBAudioEngine handles many more
/// formats than what's listed here, and `.audio` keeps the panel permissive
/// enough to pick up anything with a recognized audio UTI.
enum AudioFileLoader {

    static let supportedContentTypes: [UTType] = {
        var types: [UTType] = [.audio, .wav, .aiff, .mp3, .mpeg4Audio]
        for ext in extraExtensions {
            if let t = UTType(filenameExtension: ext) {
                types.append(t)
            }
        }
        return types
    }()

    /// Extensions beyond the common ones that SFBAudioEngine can decode but
    /// that don't always have a registered system UTI.
    private static let extraExtensions = [
        "flac", "m4a", "ogg", "oga", "opus",
        "wv", "mpc", "ape", "shn", "tta", "caf"
    ]

    /// Heuristic used by drag-and-drop and the Dock open handler: accept a file
    /// if its UTI conforms to `public.audio` or its extension is one we list.
    /// SFBAudioEngine is the final arbiter at decode time; this just filters
    /// obviously-wrong drops.
    static func isLikelyAudioFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if extraExtensions.contains(ext) { return true }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .audio) {
            return true
        }
        return false
    }
}
