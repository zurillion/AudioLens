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
/// Why convert per-chunk instead of after the concat: SFB's processingFormat
/// for some files (notably WAV via libsndfile) can be interleaved or non-
/// float32. Concatenating those buffers via `floatChannelData` silently
/// produces zeros — leading to a silent buffer downstream. Running each chunk
/// through AVAudioConverter forces a known float32 non-interleaved layout
/// before we touch the data ourselves.
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

    private static let chunkCapacity: AVAudioFrameCount = 65_536
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

        let rateRatio = targetRate / sourceFormat.sampleRate
        let targetChunkCapacity = AVAudioFrameCount(Double(chunkCapacity) * rateRatio) + 256

        var convertedChunks: [AVAudioPCMBuffer] = []

        while true {
            guard let sourceChunk = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: chunkCapacity) else {
                throw LoadError.allocationFailed
            }
            try decoder.decode(into: sourceChunk)
            let sourceFrames = sourceChunk.frameLength
            if sourceFrames == 0 { break }

            guard let targetChunk = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetChunkCapacity) else {
                throw LoadError.allocationFailed
            }

            // AVAudioConverterInputBlock is @Sendable; capture state through a class.
            final class Provider: @unchecked Sendable {
                var consumed = false
                let buffer: AVAudioPCMBuffer
                init(_ b: AVAudioPCMBuffer) { self.buffer = b }
            }
            let provider = Provider(sourceChunk)
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                if provider.consumed {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                provider.consumed = true
                outStatus.pointee = .haveData
                return provider.buffer
            }

            var error: NSError?
            let status = converter.convert(to: targetChunk, error: &error, withInputFrom: inputBlock)
            if status == .error {
                throw error ?? LoadError.converterCreationFailed
            }

            if targetChunk.frameLength > 0 {
                convertedChunks.append(targetChunk)
            }
            if sourceFrames < chunkCapacity { break }
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
