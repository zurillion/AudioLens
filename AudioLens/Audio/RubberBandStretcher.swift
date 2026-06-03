import AVFoundation
import CRubberBand

/// Swift wrapper around Rubber Band's C API. Owns the underlying
/// `RubberBandState` and translates Swift-side calls into the C interface.
/// Used in real-time mode by RubberBandTimePitchUnit (added in phase 2).
///
/// Rubber Band's "R3" / Finer engine is selected for highest quality.
/// Real-time mode is required so pitch / rate changes apply live without
/// needing to re-process the whole buffer.
final class RubberBandStretcher {

    private let state: RubberBandState
    let channelCount: Int

    init(sampleRate: Double, channels: Int) {
        self.channelCount = channels
        // The C typedef RubberBandOptions is `int` (Int32), but Swift imports
        // the underlying enum's RawValue as UInt32. Bit-pattern conversion
        // bridges them without overflow even if a future option uses the
        // high bit.
        let optionsBits = RubberBandOptionEngineFiner.rawValue |
                          RubberBandOptionProcessRealTime.rawValue
        self.state = rubberband_new(
            UInt32(sampleRate),
            UInt32(channels),
            Int32(bitPattern: optionsBits),
            1.0,   // initial time ratio (1.0 = unchanged speed)
            1.0    // initial pitch scale (1.0 = unchanged pitch)
        )
    }

    deinit {
        rubberband_delete(state)
    }

    // MARK: - Parameters

    /// Time ratio: 1.0 = no change, 2.0 = double duration (half speed),
    /// 0.5 = half duration (double speed).
    var timeRatio: Double {
        get { rubberband_get_time_ratio(state) }
        set { rubberband_set_time_ratio(state, newValue) }
    }

    /// Pitch scale: 1.0 = no change, 2.0 = up one octave, 0.5 = down one octave.
    /// Use `setPitchCents` for the cents-based interface used by the UI.
    var pitchScale: Double {
        get { rubberband_get_pitch_scale(state) }
        set { rubberband_set_pitch_scale(state, newValue) }
    }

    func setPitchCents(_ cents: Double) {
        pitchScale = pow(2.0, cents / 1200.0)
    }

    func reset() {
        rubberband_reset(state)
    }

    // MARK: - Latency

    /// Number of output samples to discard at the start of the stream to
    /// account for the engine's startup transient. Used to compensate
    /// latency end-to-end.
    var startDelay: Int {
        Int(rubberband_get_start_delay(state))
    }

    /// Steady-state latency of the stretcher in samples.
    var latency: Int {
        Int(rubberband_get_latency(state))
    }

    /// Number of samples of silence that should be processed at the start of
    /// playback to "prime" the stretcher.
    var preferredStartPad: Int {
        Int(rubberband_get_preferred_start_pad(state))
    }

    // MARK: - Real-time processing

    /// How many input frames the stretcher needs right now to produce some
    /// output. The render loop should pull at least this many samples from
    /// upstream and pass them to `process(...)`.
    var samplesRequired: Int {
        Int(rubberband_get_samples_required(state))
    }

    /// Feed input frames. `channels` must be a pointer to an array of per-
    /// channel pointers (non-interleaved float32), one per channel.
    func process(input: UnsafePointer<UnsafePointer<Float>?>,
                 sampleCount: Int,
                 final: Bool) {
        rubberband_process(state, input, UInt32(sampleCount), final ? 1 : 0)
    }

    /// Number of output frames available to retrieve right now.
    var available: Int {
        Int(rubberband_available(state))
    }

    /// Pull processed frames out into `output` (per-channel pointers).
    /// Returns the number actually written, which can be less than `sampleCount`.
    func retrieve(output: UnsafePointer<UnsafeMutablePointer<Float>?>,
                  sampleCount: Int) -> Int {
        Int(rubberband_retrieve(state, output, UInt32(sampleCount)))
    }
}
