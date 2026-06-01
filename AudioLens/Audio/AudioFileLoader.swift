import AVFoundation
import UniformTypeIdentifiers

/// Initial loader uses AVAudioFile, which covers WAV, AIFF, CAF, ALAC, AAC, MP3,
/// and FLAC on recent macOS. SFBAudioEngine will be added as an SPM dependency
/// to extend this to Opus, WavPack, Musepack, APE, OGG Vorbis, etc.
enum AudioFileLoader {

    static let supportedContentTypes: [UTType] = {
        var types: [UTType] = [.audio, .wav, .aiff, .mp3, .mpeg4Audio]
        if let flac = UTType(filenameExtension: "flac") { types.append(flac) }
        if let alac = UTType(filenameExtension: "m4a") { types.append(alac) }
        return types
    }()
}
