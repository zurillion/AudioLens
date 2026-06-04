import AVFoundation

/// A named position within the loaded file. The timecode is derived from
/// `frame` at display time and is not part of the name.
struct Bookmark: Equatable, Sendable {
    var frame: AVAudioFramePosition
    var name: String

    init(frame: AVAudioFramePosition, name: String = "") {
        self.frame = frame
        self.name = name
    }
}
