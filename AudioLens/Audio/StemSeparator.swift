import Foundation

/// A single separated stem on disk. The audio lives in a WAV (or, after the
/// cache layer arrives, FLAC) file at `url`, produced by some `StemSeparator`.
struct StemFile: Sendable, Hashable {
    /// Stable machine-readable identifier — "vocals" / "drums" / "bass" /
    /// "other" for 4-stem models; "guitar" / "piano" join in for 6-stem
    /// variants.
    let id: String
    /// User-facing label.
    let displayName: String
    /// Location of the stem audio on disk.
    let url: URL
}

enum StemSeparationError: Error, LocalizedError, Sendable {
    case missingBinary(URL)
    case missingWeights(URL)
    case sourceFileMissing(URL)
    case launchFailed(String)
    case inferenceFailed(exitCode: Int32, stderr: String)
    case missingOutput(expected: String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingBinary(let url):
            return "Stem-separator binary not found at \(url.path)."
        case .missingWeights(let url):
            return "Model weights not found at \(url.path)."
        case .sourceFileMissing(let url):
            return "Source audio not found at \(url.path)."
        case .launchFailed(let detail):
            return "Could not launch stem-separator subprocess: \(detail)"
        case .inferenceFailed(let code, let err):
            let tail = err.split(separator: "\n").suffix(8).joined(separator: "\n")
            return "Stem separation failed (exit \(code)).\n\(tail)"
        case .missingOutput(let expected):
            return "Separator did not produce expected file '\(expected)'."
        case .cancelled:
            return "Stem separation cancelled."
        }
    }
}

/// Anything that splits a source audio file into named stems.
///
/// This is the **single boundary** between AudioLens and whatever backend is
/// doing the actual ML inference. Today we shell out to `demucs.cpp` as a
/// subprocess (slow but easy to integrate). Tomorrow we'll swap in an
/// MLX-Swift port — the engine, cache and UI on top don't need to know.
protocol StemSeparator: Sendable {
    /// Stable model identifier ("htdemucs", "htdemucs_6s", ...). Used as part
    /// of the cache key so a new model invalidates old cached stems.
    var modelID: String { get }
    /// User-facing model label.
    var modelDisplayName: String { get }
    /// The stems this backend emits, in the order the UI should show them.
    /// Typically ["vocals", "drums", "bass", "other"] — vocals first because
    /// that's what users mute/solo most.
    var stemOrder: [String] { get }

    /// Run separation. Returns the produced stem files, in `stemOrder`.
    ///
    /// `progress` is best-effort (0…1). Backends without intermediate
    /// progress reporting call it once at 0.0 and once at 1.0.
    ///
    /// Honours Swift task cancellation: cancelling the surrounding `Task`
    /// terminates the inference cleanly and throws `.cancelled`.
    func separate(
        sourceURL: URL,
        outputDirectory: URL,
        progress: @Sendable (Double) -> Void
    ) async throws -> [StemFile]
}
