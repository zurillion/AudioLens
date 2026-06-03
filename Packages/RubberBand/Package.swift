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
                // Things alongside Package.swift / submodule that SwiftPM
                // would otherwise complain about as "unhandled".
                "README.md",
                // Plugin formats and unrelated bindings we don't compile.
                "rubberband/com",
                "rubberband/cross",
                "rubberband/dotnet",
                "rubberband/ladspa-lv2",
                "rubberband/main",
                "rubberband/otherbuilds",
                "rubberband/single",
                "rubberband/vamp",
                // Internal subdirs of src/ we don't need.
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
                "rubberband/src/rubberband-c.cpp",
                "rubberband/src/RubberBandStretcher.cpp",
                "rubberband/src/RubberBandLiveShifter.cpp",
                "rubberband/src/faster",
                "rubberband/src/common",
                "rubberband/src/finer",
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
            ],
            linkerSettings: [
                .linkedFramework("Accelerate"),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
