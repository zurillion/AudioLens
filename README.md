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

### SFBAudioEngine (required)

Multi-format audio decoding (Opus, FLAC, Vorbis, WavPack, Musepack, Monkey's
Audio, Shorten, True Audio, plus everything Core Audio handles natively).
Add it through Xcode the first time you build:

1. With `AudioLens.xcodeproj` open in Xcode: **File → Add Package Dependencies…**
2. Enter the URL `https://github.com/sbooth/SFBAudioEngine`
3. Dependency Rule: **Up to Next Major Version** from the version Xcode pre-fills
   (currently `0.12.x`)
4. Add the `SFBAudioEngine` product to the **AudioLens** target

Once added, `import SFBAudioEngine` in `Audio/SFBAudioLoader.swift` resolves and
the project builds.

### Rubber Band Library (planned)

High-quality pitch shifting and time stretching. Will be vendored as a git
submodule and wrapped in a custom `AUAudioUnit`. GPL-3.0.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
