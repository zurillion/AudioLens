# AudioLens

A native macOS audio player for musicians, built with Swift + AppKit.

**Status:** Early scaffolding. The architecture is in place; DSP wiring is in progress.

## Feature Goals

1. **Multi-format playback** — anything the OS can't decode natively (Opus, WavPack, Musepack, …) via [SFBAudioEngine](https://github.com/sbooth/SFBAudioEngine).
2. **Waveform visualization** — Metal-rendered, with on-disk overview cache.
3. **Section selection + looping** — one or more regions, scheduled through `AVAudioPlayerNode`.
4. **High-quality pitch shifting & time stretching** — [Rubber Band Library](https://breakfastquay.com/rubberband/) (R3 "finer" engine) wrapped in a custom `AUAudioUnit`. Cent-by-cent and semitone-by-semitone pitch, large stretch factors.
5. **Graphic equalizer** — multi-band, built on `AVAudioUnitEQ`.

## Architecture

```
File → SFBAudioEngine decoder → AVAudioPCMBuffer
                                        ↓
AVAudioPlayerNode → RubberBandAU → AVAudioUnitEQ → MainMixer → Output
                         ↓
                    Tap → Waveform / level meters
```

Stereo only. Real-time and offline pitch/time changes both supported (RT for live control, offline for highest-quality renders).

## Requirements

- macOS 26 (Tahoe) or later
- Xcode 17+
- Swift 6

## Building

```bash
open AudioLens.xcodeproj
```

If the `.xcodeproj` ever drifts from `project.yml`, regenerate it with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
xcodegen generate
```

## Dependencies

Added via Swift Package Manager from within Xcode (not yet wired in pbxproj — see TODO):

- **SFBAudioEngine** — MIT — multi-format decoding
- **Rubber Band Library** — GPL-3.0 — vendored as git submodule (TODO)

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
