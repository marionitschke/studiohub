import AppKit

/// The StudioHub apps. Installed side by side in /Applications/StudioHub, they switch to each other
/// through the StudioHub menu (⌃⌘1…3).
enum StudioApp: Int, CaseIterable, Sendable {
    case photo = 1, video, music

    var name: String {
        switch self {
        case .photo: "PhotoHub"
        case .video: "VideoHub"
        case .music: "MusicHub"
        }
    }

    var bundleIdentifier: String { "local.\(name.lowercased())" }

    /// ⌃⌘ plus this digit opens the app.
    var shortcut: Character { Character(String(rawValue)) }

    /// nil in check and debug builds, which have their own bundle identifiers.
    static var current: StudioApp? { allCases.first { $0.bundleIdentifier == Bundle.main.bundleIdentifier } }

    /// The copy next to `bundle` wins, so the installed apps open each other even when Launch Services
    /// also knows copies in build folders.
    func location(nextTo bundle: URL = Bundle.main.bundleURL) -> URL? {
        let sibling = bundle.deletingLastPathComponent().appendingPathComponent("\(name).app")
        if FileManager.default.fileExists(atPath: sibling.path) { return sibling }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    /// Brings the app to the front and launches it if needed; `files` are handed over to be opened there.
    @MainActor
    func open(_ files: [URL] = []) {
        let name = name
        guard let app = location() else {
            StudioApp.showError("\(name) ist nicht installiert.",
                                detail: "Im Ordner studiohub baut „./build.sh --install“ alle Apps nach /Applications/StudioHub.")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let completion: @Sendable (NSRunningApplication?, (any Error)?) -> Void = { _, error in
            guard let error else { return }
            let detail = error.localizedDescription
            Task { @MainActor in StudioApp.showError("\(name) konnte nicht geöffnet werden.", detail: detail) }
        }
        if files.isEmpty {
            NSWorkspace.shared.openApplication(at: app, configuration: configuration, completionHandler: completion)
        } else {
            NSWorkspace.shared.open(files, withApplicationAt: app, configuration: configuration, completionHandler: completion)
        }
    }

    @MainActor
    private static func showError(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }
}

/// The StudioHub menu for an AppKit menu bar (PhotoHub); `StudioCommands` is the SwiftUI version.
@MainActor
final class StudioMenu: NSObject, NSMenuItemValidation {
    /// Menu items keep their target only weakly.
    private static let target = StudioMenu()

    static func make() -> NSMenu {
        let menu = NSMenu(title: "StudioHub")
        for app in StudioApp.allCases {
            let item = menu.addItem(withTitle: app.name, action: #selector(openApp(_:)), keyEquivalent: String(app.shortcut))
            item.keyEquivalentModifierMask = [.control, .command]
            item.tag = app.rawValue
            item.target = target
        }
        return menu
    }

    @objc private func openApp(_ sender: NSMenuItem) {
        StudioApp(rawValue: sender.tag)?.open()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        StudioApp(rawValue: menuItem.tag) != StudioApp.current
    }
}
