import SwiftUI

extension View {
    /// Darcula for a whole window: its background, and the palette's text colors as the primary,
    /// secondary and tertiary foreground styles.
    func darculaWindow() -> some View {
        foregroundStyle(DarculaText.primary, DarculaText.secondary, DarculaText.tertiary)
            .containerBackground(Color(nsColor: Darcula.background), for: .window)
    }

    /// A primary action in the app's main color with white text, like DiaryHub's primary buttons.
    func primaryAction(_ app: StudioApp) -> some View {
        buttonStyle(.borderedProminent)
            .tint(Color(nsColor: app.color))
            .foregroundStyle(.white)
    }

    /// A segmented picker whose selected segment is the app's selection color with white text.
    func darculaSegments(_ app: StudioApp) -> some View {
        pickerStyle(.segmented)
            .tint(Color(nsColor: app.selection))
    }
}

/// The Darcula text colors, white on selected rows of lists and tables: their selection is a grey on
/// which the palette's light greys are hard to read.
struct DarculaText: ShapeStyle {
    static let primary = DarculaText(level: 0)
    static let secondary = DarculaText(level: 1)
    static let tertiary = DarculaText(level: 2)

    let level: Int

    func resolve(in environment: EnvironmentValues) -> Color {
        if environment.backgroundProminence == .increased { return .white.opacity([1, 0.8, 0.6][level]) }
        return Color(nsColor: [Darcula.text, Darcula.muted, Darcula.faint][level])
    }
}
