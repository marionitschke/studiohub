import AppKit

/// The look of all StudioHub apps: Darcula as in WebStorm and DiaryHub – always dark, neutral grey
/// surfaces, a grey accent for controls and selections; each app's main color only marks primary
/// actions and its own content.
enum Darcula {
    /// Window, lists, timeline lanes.
    static let background = color(0x2B2B2B)
    /// Panels, cards, rulers, track headers.
    static let surface = color(0x313335)
    /// Controls and raised areas on a surface; also the row lines of lists.
    static let raised = color(0x3C3F41)
    static let border = color(0x4B4F52)
    static let text = color(0xC4C7CA)
    static let muted = color(0x8F9395)
    static let faint = color(0x65696C)
    static let accent = color(0x8A8E91)
    static let danger = color(0xF26B6B)
    /// Filled danger buttons and markers, with white text.
    static let dangerFill = color(0xB91C1C)
    static let warn = color(0xF59E0B)
    static let success = color(0x3FBF63)

    static func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// Must run before `NSApplication.shared` exists – AppKit reads the accent color once when it starts.
    /// Without Xcode there is no asset catalog for an app accent color; the argument domain is not
    /// saved and wins over the system setting, so the apps' controls turn graphite.
    static func prepare() {
        let defaults = UserDefaults.standard
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["AppleAccentColor"] = -1
        arguments["AppleAquaColorVariant"] = 6
        arguments["AppleHighlightColor"] = "0.847059 0.847059 0.862745 Graphite"
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    /// Dark for every window, sheet, alert and menu, whatever the system uses.
    @MainActor
    static func applyAppearance() {
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }
}

extension StudioApp {
    /// The app's main color, as in its icon: primary buttons, its own content in timelines.
    var color: NSColor {
        switch self {
        case .photo: Darcula.color(0x6A3FD4)
        case .video: Darcula.color(0x2A9D5C)
        case .music: Darcula.color(0xB23BB0)
        }
    }

    /// The main color lightened for symbols, text and waveforms on the dark background.
    var ink: NSColor {
        switch self {
        case .photo: Darcula.color(0xA288E6)
        case .video: Darcula.color(0x3DC47A)
        case .music: Darcula.color(0xD06FCE)
        }
    }

    /// Selected tabs and segments, with white text: 55 % main color on the surface grey. The graphite
    /// accent selects in a light grey on which the Darcula text colors reached only about 2:1.
    var selection: NSColor { color.blended(withFraction: 0.45, of: Darcula.surface) ?? color }
}
