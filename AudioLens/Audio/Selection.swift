import AVFoundation

/// A region within an audio file the player should focus on.
/// Multi-region selection (queue of regions) will be added once the single-region
/// path is working end-to-end.
enum Selection: Equatable {
    case whole
    case region(start: AVAudioFramePosition, length: AVAudioFrameCount, loops: Bool)
}
