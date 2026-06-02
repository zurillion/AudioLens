import AVFoundation
import UniformTypeIdentifiers

/// Content types shown in the open panel. We list common ones explicitly so
/// they appear named in the file dialog; SFBAudioEngine handles many more
/// formats than what's listed here, and `.audio` keeps the panel permissive
/// enough to pick up anything with a recognized audio UTI.
enum AudioFileLoader {

    static let supportedContentTypes: [UTType] = {
        var types: [UTType] = [.audio, .wav, .aiff, .mp3, .mpeg4Audio]
        let extraExtensions = [
            "flac", "m4a", "ogg", "oga", "opus",
            "wv", "mpc", "ape", "shn", "tta", "caf"
        ]
        for ext in extraExtensions {
            if let t = UTType(filenameExtension: ext) {
                types.append(t)
            }
        }
        return types
    }()
}
