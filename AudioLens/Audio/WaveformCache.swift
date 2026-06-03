import Foundation
import CryptoKit

/// On-disk cache for waveform overviews. Keyed on the source file's path, size,
/// and modification date, so editing or replacing a file invalidates its entry.
/// Stored under the sandbox container's Caches directory (writable without any
/// entitlement).
enum WaveformCache {

    private static let magic: UInt32 = 0x414C5746  // "ALWF"
    private static let version: UInt32 = 1

    static func load(for fileURL: URL) -> (mins: [Float], maxs: [Float])? {
        guard let url = cacheURL(for: fileURL),
              let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    static func save(mins: [Float], maxs: [Float], for fileURL: URL) {
        guard mins.count == maxs.count, !mins.isEmpty,
              let url = cacheURL(for: fileURL) else { return }
        try? encode(mins: mins, maxs: maxs).write(to: url, options: .atomic)
    }

    // MARK: - Keying

    private static func cacheURL(for fileURL: URL) -> URL? {
        guard let dir = cacheDirectory() else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let keyString = "\(fileURL.path)|\(size)|\(mtime)"
        let digest = SHA256.hash(data: Data(keyString.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(hex).appendingPathExtension("overview")
    }

    private static func cacheDirectory() -> URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent("AudioLens/waveforms", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Binary format
    // [magic UInt32][version UInt32][count UInt32][mins Float32 × count][maxs Float32 × count]

    private static func encode(mins: [Float], maxs: [Float]) -> Data {
        let count = UInt32(mins.count)
        var data = Data()
        data.reserveCapacity(12 + mins.count * 8)
        withUnsafeBytes(of: magic.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: version.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: count.littleEndian) { data.append(contentsOf: $0) }
        mins.withUnsafeBytes { data.append(contentsOf: $0) }
        maxs.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    private static func decode(_ data: Data) -> (mins: [Float], maxs: [Float])? {
        let headerSize = 12
        guard data.count >= headerSize else { return nil }
        return data.withUnsafeBytes { raw -> (mins: [Float], maxs: [Float])? in
            let m = raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian
            let v = raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian
            let count = Int(raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian)
            guard m == magic, v == version, count > 0 else { return nil }
            let expected = headerSize + count * 8
            guard data.count >= expected else { return nil }
            var mins = [Float](repeating: 0, count: count)
            var maxs = [Float](repeating: 0, count: count)
            for i in 0..<count {
                mins[i] = Float(bitPattern: raw.loadUnaligned(fromByteOffset: headerSize + i * 4, as: UInt32.self))
            }
            let maxsBase = headerSize + count * 4
            for i in 0..<count {
                maxs[i] = Float(bitPattern: raw.loadUnaligned(fromByteOffset: maxsBase + i * 4, as: UInt32.self))
            }
            return (mins, maxs)
        }
    }
}
