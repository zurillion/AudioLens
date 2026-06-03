// swift-tools-version:5.9
import PackageDescription

// Local Swift Package that exposes Rubber Band Library (installed via
// Homebrew) as a system module importable from Swift.
//
// User setup (one-time):
//   brew install pkg-config rubberband
//
// In Xcode: File > Add Package Dependencies... > Add Local... and select
// this `Packages/SystemRubberBand` directory. Then add the `CRubberBand`
// product to the AudioLens target.

let package = Package(
    name: "SystemRubberBand",
    products: [
        .library(name: "CRubberBand", targets: ["CRubberBand"]),
    ],
    targets: [
        .systemLibrary(
            name: "CRubberBand",
            path: "Sources/CRubberBand",
            pkgConfig: "rubberband",
            providers: [
                .brew(["rubberband"]),
            ]
        ),
    ]
)
