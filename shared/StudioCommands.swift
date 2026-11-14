import SwiftUI

/// The StudioHub menu for the SwiftUI apps; `StudioMenu` builds the same menu for AppKit.
struct StudioCommands: Commands {
    var body: some Commands {
        CommandMenu("StudioHub") {
            ForEach(StudioApp.allCases, id: \.self) { app in
                Button(app.name) { app.open() }
                    .keyboardShortcut(KeyEquivalent(app.shortcut), modifiers: [.control, .command])
                    .disabled(app == StudioApp.current)
            }
        }
    }
}
