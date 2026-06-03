// swift-tools-version:5.9
import PackageDescription

// Rubber Band Library, vendored as a git submodule under `rubberband/` and
// compiled in-tree as part of this Swift Package — no Homebrew or any other
// external install needed.
//
// Cloning the project requires `--recurse-submodules` (or running
// `git submodule update --init --recursive` afterwards) to populate the
// `rubberband/` directory.
//
// macOS-specific build configuration (matching the upstream meson build):
//   HAVE_VDSP            FFT via Apple's Accelerate framework
//   USE_PTHREADS         pthread-based mutex/condition variables
//   MALLOC_IS_ALIGNED    standard malloc is 16-byte aligned on Darwin
//   USE_BQRESAMPLER      Cannam's portable resampler (the built-in default)
//   NO_THREAD_CHECKS,    quiet the diagnostic instrumentation
//   NO_TIMING, NDEBUG
//
// Source files are listed explicitly (rather than as directories) to match
// upstream meson.build's `library_sources` exactly. Directory-based source
// inclusion picked up stale .cpp files that are no longer part of the
// library build (e.g. VectorOpsComplex.cpp, which still references a renamed
// `system/` directory).

let package = Package(
    name: "RubberBand",
    products: [
        .library(name: "CRubberBand", targets: ["CRubberBand"]),
    ],
    targets: [
        .target(
            name: "CRubberBand",
            path: ".",
            exclude: [
                // Plugin formats / unrelated bindings / non-library subdirs.
                "rubberband/com",
                "rubberband/cross",
                "rubberband/dotnet",
                "rubberband/ladspa-lv2",
                "rubberband/main",
                "rubberband/otherbuilds",
                "rubberband/single",
                "rubberband/vamp",
                "rubberband/src/ext",
                "rubberband/src/jni",
                "rubberband/src/test",
                // Build system / docs metadata.
                "rubberband/meson.build",
                "rubberband/meson_options.txt",
                "rubberband/Doxyfile",
                "rubberband/COMPILING.md",
                "rubberband/CONTRIBUTING.md",
                "rubberband/README.md",
                "rubberband/COPYING",
                "rubberband/CHANGELOG",
                "rubberband/rubberband.pc.in",
            ],
            sources: [
                // Match upstream meson.build `library_sources` exactly.
                "rubberband/src/rubberband-c.cpp",
                "rubberband/src/RubberBandStretcher.cpp",
                "rubberband/src/RubberBandLiveShifter.cpp",
                "rubberband/src/faster/AudioCurveCalculator.cpp",
                "rubberband/src/faster/CompoundAudioCurve.cpp",
                "rubberband/src/faster/HighFrequencyAudioCurve.cpp",
                "rubberband/src/faster/SilentAudioCurve.cpp",
                "rubberband/src/faster/PercussiveAudioCurve.cpp",
                "rubberband/src/faster/R2Stretcher.cpp",
                "rubberband/src/faster/StretcherChannelData.cpp",
                "rubberband/src/faster/StretcherProcess.cpp",
                "rubberband/src/common/Allocators.cpp",
                "rubberband/src/common/BQResampler.cpp",
                "rubberband/src/common/FFT.cpp",
                "rubberband/src/common/Log.cpp",
                "rubberband/src/common/Profiler.cpp",
                "rubberband/src/common/Resampler.cpp",
                "rubberband/src/common/StretchCalculator.cpp",
                "rubberband/src/common/Thread.cpp",
                "rubberband/src/common/mathmisc.cpp",
                "rubberband/src/common/sysutils.cpp",
                "rubberband/src/finer/R3LiveShifter.cpp",
                "rubberband/src/finer/R3Stretcher.cpp",
            ],
            publicHeadersPath: "Sources/CRubberBand/include",
            cxxSettings: [
                .define("HAVE_VDSP"),
                .define("USE_PTHREADS"),
                .define("MALLOC_IS_ALIGNED"),
                .define("USE_BQRESAMPLER"),
                .define("NO_THREAD_CHECKS"),
                .define("NO_TIMING"),
                .define("NDEBUG"),
                .headerSearchPath("rubberband"),
                .headerSearchPath("rubberband/src"),
                .headerSearchPath("Sources/CRubberBand/include"),
                // Force every translation unit to see size_t / ptrdiff_t in
                // the global namespace before any Rubber Band header is read.
                // See rb_prefix.h for details.
                .unsafeFlags(["-include", "rb_prefix.h"]),
            ],
            linkerSettings: [
                .linkedFramework("Accelerate"),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
