import AVFoundation
import AudioToolbox
import SFBAudioEngine

/// Lightweight, value-type description of the *original* file (before AudioLens
/// resamples it to its canonical processing format). Shown in the transport.
struct AudioFileInfo: Sendable {
    let formatName: String     // e.g. "WAV", "FLAC", "MP3"
    let sampleRate: Double     // original sample rate, Hz
    let channelCount: Int      // original channel count
    let bitDepth: Int          // 0 when not applicable (compressed formats)

    var channelDescription: String {
        switch channelCount {
        case 1:  return "Mono"
        case 2:  return "Stereo"
        default: return "\(channelCount) ch"
        }
    }

    /// "WAV · 44.1 kHz · Stereo · 16-bit"
    var summary: String {
        var parts = [formatName, Self.formatSampleRate(sampleRate), channelDescription]
        if bitDepth > 0 { parts.append("\(bitDepth)-bit") }
        return parts.joined(separator: " · ")
    }

    private static func formatSampleRate(_ hz: Double) -> String {
        let khz = hz / 1000.0
        return khz == khz.rounded()
            ? String(format: "%.0f kHz", khz)
            : String(format: "%.1f kHz", khz)
    }
}

/// Decodes any supported audio file into a single in-memory `AVAudioPCMBuffer`
/// in a canonical processing format (float32 non-interleaved stereo at the
/// source sample rate when it is one of the standard rates, or 48 kHz).
///
/// SFBAudioEngine sits on top of FLAC, libopus, libvorbis, libmpg123, libwavpack,
/// libmpc, MAC (Monkey's Audio), Shorten, True Audio, libsndfile, plus everything
/// Core Audio handles natively.
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

    static func decode(url: URL) throws -> (buffer: AVAudioPCMBuffer, info: AudioFileInfo) {
        let decoder = try AudioDecoder(url: url)
        try decoder.open()
        defer { try? decoder.close() }

        let info = fileInfo(decoder: decoder, url: url)
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

        let inputBlock = makeInputBlock(decoder: decoder, sourceFormat: sourceFormat)

        // Preferred path: if we can estimate the output length up front (true
        // for WAV/AIFF/MP3/AAC/ALAC/FLAC via AVAudioFile's header), allocate ONE
        // output buffer and let a single convert() call fill it. Peak memory is
        // 1× the decoded size. The old chunk-accumulate path held every chunk
        // AND the final buffer simultaneously (2× peak), which OOM-killed the
        // app on large WAVs.
        if let capacity = estimatedTargetFrameCapacity(url: url, targetRate: targetRate) {
            if let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) {
                output.frameLength = 0
                var error: NSError?
                let status = converter.convert(to: output, error: &error, withInputFrom: inputBlock)
                if status != .error, output.frameLength > 0 {
                    return (output, info)
                }
                // .haveData (under-estimated) or .error → fall through to the
                // robust accumulation path with a fresh decoder/converter.
            }
        }

        let buffer = try decodeByAccumulation(url: url, targetFormat: targetFormat)
        return (buffer, info)
    }

    // MARK: - File info

    private static func fileInfo(decoder: AudioDecoder, url: URL) -> AudioFileInfo {
        // The decoder decodes at the file's native rate/channels, so the
        // processing format carries the original rate and channel count.
        // The source format additionally carries the encoded bit depth / codec.
        let proc = decoder.processingFormat
        let src = decoder.sourceFormat
        let asbd = src.streamDescription.pointee
        let isPCM = asbd.mFormatID == kAudioFormatLinearPCM
        return AudioFileInfo(
            formatName: formatName(url: url, formatID: asbd.mFormatID),
            sampleRate: proc.sampleRate > 0 ? proc.sampleRate : src.sampleRate,
            channelCount: Int(proc.channelCount > 0 ? proc.channelCount : src.channelCount),
            bitDepth: isPCM ? Int(asbd.mBitsPerChannel) : 0)
    }

    /// Friendly format label: prefer the file extension (what the user sees),
    /// falling back to the codec's four-char format ID.
    private static func formatName(url: URL, formatID: AudioFormatID) -> String {
        let ext = url.pathExtension.uppercased()
        if !ext.isEmpty { return ext }
        switch formatID {
        case kAudioFormatLinearPCM:     return "PCM"
        case kAudioFormatMPEG4AAC:      return "AAC"
        case kAudioFormatMPEGLayer3:    return "MP3"
        case kAudioFormatAppleLossless: return "ALAC"
        case kAudioFormatFLAC:          return "FLAC"
        default:                        return "Audio"
        }
    }

    // MARK: - Length estimate

    /// Estimate the number of target-rate frames using AVAudioFile's O(1) header
    /// read, scaled by the resample ratio, plus a safety margin. Returns nil for
    /// formats AVAudioFile can't open (we then fall back to chunk accumulation).
    private static func estimatedTargetFrameCapacity(url: URL, targetRate: Double) -> AVAudioFrameCount? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let sourceRate = file.processingFormat.sampleRate
        let sourceFrames = file.length
        guard sourceFrames > 0, sourceRate > 0 else { return nil }
        // Scale to target rate, then pad 2% + 2 seconds so a single convert()
        // call won't run out of room (which would truncate the tail).
        let scaled = Double(sourceFrames) * targetRate / sourceRate
        let padded = scaled * 1.02 + targetRate * 2
        guard padded > 0, padded < Double(AVAudioFrameCount.max) else { return nil }
        return AVAudioFrameCount(padded)
    }

    // MARK: - Streaming input

    /// Builds the AVAudioConverter input block that lazily pulls source chunks
    /// from the SFB decoder. The converter is stateful (resampling carries
    /// filter history), so a single input stream is used across all convert()
    /// calls, signalling endOfStream only when the decoder is exhausted.
    private static func makeInputBlock(decoder: AudioDecoder,
                                       sourceFormat: AVAudioFormat) -> AVAudioConverterInputBlock {
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
        return { _, outStatus in
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
    }

    // MARK: - Fallback path (unknown length)

    /// Chunk-accumulate decode for formats whose length we can't estimate.
    /// Holds the converted chunks then concatenates (2× peak), so it's reserved
    /// for the fallback case — typically smaller/compressed exotic formats.
    private static func decodeByAccumulation(url: URL,
                                             targetFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let decoder = try AudioDecoder(url: url)
        try decoder.open()
        defer { try? decoder.close() }
        let sourceFormat = decoder.processingFormat
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw LoadError.converterCreationFailed
        }
        let inputBlock = makeInputBlock(decoder: decoder, sourceFormat: sourceFormat)

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
