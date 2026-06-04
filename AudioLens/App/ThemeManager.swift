import AppKit
import Foundation

/// A named UI tint. Themes change the most visible accents (waveform stroke,
/// filename label, follow-toggle "on" background); semantic colours (playhead
/// red, loop orange, bookmark teal, VU green/amber/red, trim grey) are
/// constant across themes — they encode meaning the eye learns.
struct AppTheme: Sendable {
    let id: String
    let displayName: String
    let waveformRGB: ColorRGB
    let filenameRGB: ColorRGB
    let followOnRGB: ColorRGB
}

/// RGB-as-Sendable so the AppTheme catalog can be a plain `static let` without
/// upsetting Swift 6's concurrency checker (NSColor isn't Sendable).
struct ColorRGB: Sendable {
    let r: Double
    let g: Double
    let b: Double

    @MainActor
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0) }

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r; self.g = g; self.b = b
    }
}

extension AppTheme {
    /// The eight built-in themes, in the order shown in Preferences.
    static let all: [AppTheme] = [
        AppTheme(id: "default", displayName: "Default",
                 waveformRGB: ColorRGB(0.00, 0.48, 1.00),   // system blue-ish
                 filenameRGB: ColorRGB(0.45, 0.82, 0.50),   // soft green
                 followOnRGB: ColorRGB(0.00, 0.48, 1.00)),

        AppTheme(id: "aurora", displayName: "Aurora",
                 waveformRGB: ColorRGB(0.30, 0.85, 0.85),   // teal-cyan
                 filenameRGB: ColorRGB(0.55, 0.95, 0.85),
                 followOnRGB: ColorRGB(0.25, 0.75, 0.80)),

        AppTheme(id: "sunset", displayName: "Sunset",
                 waveformRGB: ColorRGB(0.98, 0.55, 0.25),   // warm orange
                 filenameRGB: ColorRGB(1.00, 0.78, 0.55),
                 followOnRGB: ColorRGB(0.95, 0.45, 0.20)),

        AppTheme(id: "forest", displayName: "Forest",
                 waveformRGB: ColorRGB(0.30, 0.75, 0.40),   // leaf green
                 filenameRGB: ColorRGB(0.60, 0.95, 0.55),
                 followOnRGB: ColorRGB(0.25, 0.65, 0.30)),

        AppTheme(id: "lavender", displayName: "Lavender",
                 waveformRGB: ColorRGB(0.70, 0.55, 0.90),   // soft violet
                 filenameRGB: ColorRGB(0.85, 0.75, 1.00),
                 followOnRGB: ColorRGB(0.60, 0.45, 0.85)),

        AppTheme(id: "ocean", displayName: "Ocean",
                 waveformRGB: ColorRGB(0.20, 0.50, 0.90),   // deep blue
                 filenameRGB: ColorRGB(0.50, 0.75, 1.00),
                 followOnRGB: ColorRGB(0.15, 0.40, 0.85)),

        AppTheme(id: "crimson", displayName: "Crimson",
                 waveformRGB: ColorRGB(0.90, 0.30, 0.40),   // bold red
                 filenameRGB: ColorRGB(1.00, 0.55, 0.60),
                 followOnRGB: ColorRGB(0.85, 0.25, 0.35)),

        AppTheme(id: "mono", displayName: "Mono",
                 waveformRGB: ColorRGB(0.78, 0.78, 0.78),   // neutral
                 filenameRGB: ColorRGB(0.92, 0.92, 0.92),
                 followOnRGB: ColorRGB(0.55, 0.55, 0.55)),
    ]
}

/// Singleton holding the currently selected theme, persisted to UserDefaults.
/// Posts `.themeChanged` whenever the user picks a different one.
@MainActor
final class ThemeManager {
    static let shared = ThemeManager()

    private(set) var current: AppTheme

    private static let defaultsKey = "AudioLens.selectedThemeID"

    private init() {
        let savedID = UserDefaults.standard.string(forKey: Self.defaultsKey) ?? ""
        current = AppTheme.all.first { $0.id == savedID } ?? AppTheme.all[0]
    }

    func setTheme(_ theme: AppTheme) {
        guard current.id != theme.id else { return }
        current = theme
        UserDefaults.standard.set(theme.id, forKey: Self.defaultsKey)
        NotificationCenter.default.post(name: .themeChanged, object: nil)
    }

    // Convenience accessors for the views.
    var waveformColor: NSColor { current.waveformRGB.nsColor }
    var filenameColor: NSColor { current.filenameRGB.nsColor }
    var followOnColor: NSColor { current.followOnRGB.nsColor }
}

extension Notification.Name {
    static let themeChanged = Notification.Name("AudioLens.themeChanged")
}
