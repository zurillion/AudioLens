import AVFoundation
import SFBAudioEngine

/// Decodes any supported audio file into a single in-memory `AVAudioPCMBuffer`.
///
/// SFBAudioEngine sits on top of FLAC, libopus, libvorbis, libmpg123, libwavpack,
/// libmpc, MAC (Monkey's Audio), Shorten, True Audio, libsndfile, plus everything
/// Core Audio handles natively. We decode the whole file upfront so the rest of
/// the pipeline can work on a single buffer (cheap region slicing, easy loop
/// playback via scheduleBuffer's .loops option). Memory cost is the file's PCM
/// size; chunked streaming will replace this when we need very long files.
///
/// SFBAudioEngine 0.12.x's AudioDecoder doesn't expose a `frameLength` property
/// (you'd have to know the source format and seek), so we decode in chunks until
/// the decoder reports EOF (a partial or empty chunk), then concatenate.
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

    private static let chunkCapacity: AVAudioFrameCount = 65_536

    static func decode(url: URL) throws -> AVAudioPCMBuffer {
        let decoder = try AudioDecoder(url: url)
        try decoder.open()
        defer { try? decoder.close() }

        let format = decoder.processingFormat
        var chunks: [(buffer: AVAudioPCMBuffer, length: AVAudioFrameCount)] = []

        while true {
            guard let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkCapacity) else {
                throw LoadError.allocationFailed
            }
            try decoder.decode(into: chunk)
            let got = chunk.frameLength
            if got == 0 { break }
            chunks.append((chunk, got))
            if got < chunkCapacity { break }
        }

        let totalFrames = chunks.reduce(AVAudioFrameCount(0)) { $0 + $1.length }
        guard totalFrames > 0,
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else {
            throw LoadError.emptyFile
        }

        var written: AVAudioFrameCount = 0
        let channels = Int(format.channelCount)
        let frameSize = MemoryLayout<Float>.size
        for (chunk, length) in chunks {
            if let src = chunk.floatChannelData, let dst = output.floatChannelData {
                for ch in 0..<channels {
                    memcpy(dst[ch].advanced(by: Int(written)),
                           src[ch],
                           Int(length) * frameSize)
                }
            }
            written += length
        }
        output.frameLength = written
        return output
    }
}
