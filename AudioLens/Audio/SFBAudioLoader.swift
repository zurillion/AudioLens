import AVFoundation
import SFBAudioEngine

/// Decodes any supported audio file into a single in-memory `AVAudioPCMBuffer`
/// in a canonical processing format (float32 non-interleaved stereo at the
/// source sample rate when it is one of the standard rates, or 48 kHz).
///
/// SFBAudioEngine sits on top of FLAC, libopus, libvorbis, libmpg123, libwavpack,
/// libmpc, MAC (Monkey's Audio), Shorten, True Audio, libsndfile, plus everything
/// Core Audio handles natively.
///
/// Why a streaming AVAudioConverter rather than chunked-then-converted:
/// AVAudioConverter is stateful (resampling carries filter history). Telling it
/// `.endOfStream` after each chunk would make subsequent convert() calls
/// produce nothing — leading to one or two seconds of audio followed by
/// silence. Instead, the converter is invoked repeatedly with a single input
/// block that lazily pulls source chunks from the SFB decoder, only signalling
/// endOfStream when the decoder is truly exhausted.
enum SFBAudioLoader {

    enum LoadError: Error, LocalizedError {
        case allocationFailed
        case emptyFile
        case converterCreationFailed

        var errorDescription: String? {
            switch self {
            case .allocationFailed: return "Could not allocate an audio buffer for this file."
            case .emptyFile: return "The audio file contains no audio frames."
            case .converterCreationFailed: return "Could not create an audio format converter for this file."
            }
        }
    }

    private static let sourceChunkCapacity: AVAudioFrameCount = 65_536
    private static let targetChunkCapacity: AVAudioFrameCount = 65_536
    private static let supportedSampleRates: Set<Double> = [22_050, 44_100, 48_000, 88_200, 96_000]

    static func decode(url: URL) throws -> AVAudioPCMBuffer {
        let decoder = try AudioDecoder(url: url)
        try decoder.open()
        defer { try? decoder.close() }

        let sourceFormat = decoder.processingFormat
        let targetRate = supportedSampleRates.contains(sourceFormat.sampleRate)
            ? sourceFormat.sampleRate
            : 48_000
        guard let targetFormat = AVAudioFormat(standardFormatWithSampleRate: targetRate, channels: 2) else {
            throw LoadError.allocationFailed
        }
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw LoadError.converterCreationFailed
        }

        // Streaming input state shared across input-block invocations. The
        // converter calls the block until it has filled its output buffer or
        // the block returns endOfStream. Holding the current chunk keeps it
        // alive for the converter to read from.
        final class Stream: @unchecked Sendable {
            let decoder: AudioDecoder
            let sourceFormat: AVAudioFormat
            var current: AVAudioPCMBuffer?
            var exhausted = false
            init(decoder: AudioDecoder, sourceFormat: AVAudioFormat) {
                self.decoder = decoder
                self.sourceFormat = sourceFormat
            }
        }
        let stream = Stream(decoder: decoder, sourceFormat: sourceFormat)
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if stream.exhausted {
                outStatus.pointee = .endOfStream
                return nil
            }
            guard let chunk = AVAudioPCMBuffer(pcmFormat: stream.sourceFormat,
                                               frameCapacity: sourceChunkCapacity) else {
                stream.exhausted = true
                outStatus.pointee = .endOfStream
                return nil
            }
            do {
                try stream.decoder.decode(into: chunk)
            } catch {
                stream.exhausted = true
                outStatus.pointee = .endOfStream
                return nil
            }
            if chunk.frameLength == 0 {
                stream.exhausted = true
                outStatus.pointee = .endOfStream
                return nil
            }
            stream.current = chunk
            outStatus.pointee = .haveData
            return chunk
        }

        var convertedChunks: [AVAudioPCMBuffer] = []
        while true {
            guard let targetChunk = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                                     frameCapacity: targetChunkCapacity) else {
                throw LoadError.allocationFailed
            }
            var error: NSError?
            let status = converter.convert(to: targetChunk, error: &error, withInputFrom: inputBlock)
            if status == .error {
                throw error ?? LoadError.converterCreationFailed
            }
            if targetChunk.frameLength > 0 {
                convertedChunks.append(targetChunk)
            }
            if status == .endOfStream {
                break
            }
        }

        let totalFrames = convertedChunks.reduce(AVAudioFrameCount(0)) { $0 + $1.frameLength }
        guard totalFrames > 0,
              let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: totalFrames) else {
            throw LoadError.emptyFile
        }

        var written: AVAudioFrameCount = 0
        let frameSize = MemoryLayout<Float>.size
        for chunk in convertedChunks {
            guard let src = chunk.floatChannelData, let dst = output.floatChannelData else { continue }
            for ch in 0..<Int(targetFormat.channelCount) {
                memcpy(dst[ch].advanced(by: Int(written)),
                       src[ch],
                       Int(chunk.frameLength) * frameSize)
            }
            written += chunk.frameLength
        }
        output.frameLength = written
        return output
    }
}
