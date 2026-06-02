import AVFoundation
import SFBAudioEngine

/// Decodes any supported audio file into a single in-memory `AVAudioPCMBuffer`.
///
/// SFBAudioEngine sits on top of FLAC, libopus, libvorbis, libmpg123, libwavpack,
/// libmpc, MAC (Monkey's Audio), Shorten, True Audio, libsndfile, plus everything
/// Core Audio handles natively. We decode the entire file upfront so the rest of
/// the pipeline can work on a single buffer (cheap region slicing for loops,
/// straightforward playhead math). Memory cost is the file's PCM size; chunked
/// streaming will replace this when we need to handle very long files.
enum SFBAudioLoader {

    enum LoadError: Error, LocalizedError {
        case allocationFailed
        case emptyFile

        var errorDescription: String? {
            switch self {
            case .allocationFailed: return "Could not allocate an audio buffer for this file."
            case .emptyFile: return "The audio file contains no audio frames."
            }
        }
    }

    static func decode(url: URL) throws -> AVAudioPCMBuffer {
        let decoder = try AudioDecoder(url: url)
        try decoder.open()
        defer { try? decoder.close() }

        let format = decoder.processingFormat
        let totalFrames = AVAudioFrameCount(decoder.frameLength)
        guard totalFrames > 0 else { throw LoadError.emptyFile }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else {
            throw LoadError.allocationFailed
        }
        try decoder.decode(into: buffer, length: totalFrames)
        return buffer
    }
}
