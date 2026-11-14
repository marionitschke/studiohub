import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var keyMonitor: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        Darcula.applyAppearance()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when the binary is started without an .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        // Single keys (space, S, V, comma, period, arrows) work everywhere in the main window except in text fields.
        // Menu shortcuts without ⌘ would also swallow these keys while typing a name.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return handled ? nil : event
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let window = event.window, !(window is NSPanel), window.attachedSheet == nil,
              NSApp.modalWindow == nil else { return false }
        if let text = window.firstResponder as? NSTextView, text.isEditable { return false }
        return model.handleKey(event)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        model.open(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.isExporting else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Der Export läuft noch."
        alert.informativeText = "Beim Beenden wird er abgebrochen; halb fertige Dateien werden gelöscht."
        alert.addButton(withTitle: "Weiter exportieren")
        alert.addButton(withTitle: "Abbrechen und beenden")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        // The export may have ended while the alert was open; then nothing would answer a later reply.
        guard model.isExporting else { return .terminateNow }
        model.quitAfterExport = true
        model.cancelExport()
        return .terminateLater
    }
}

@main
struct MusicHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        Darcula.prepare()
    }

    var body: some Scene {
        let model = appDelegate.model
        Window("MusicHub", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 600)
                .darculaWindow()
        }
        .defaultSize(width: 1200, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Öffnen …") { model.showOpenPanel() }
                    .keyboardShortcut("o")
                    .disabled(model.isExporting)
                Menu("Zuletzt geöffnet") {
                    ForEach(model.recentRecordings, id: \.self) { paths in
                        Button(RecentFiles.name(paths)) { model.openRecent(paths) }
                    }
                    Divider()
                    Button("Liste leeren") { model.clearRecent() }
                }
                .disabled(model.recentRecordings.isEmpty || model.isExporting)
                Button("Dateien anhängen …") { model.showAppendPanel() }
                    .disabled(model.document == nil || model.isExporting || model.isLoading)
                Button("Cue-Datei laden …") { model.showCuePanel() }
                    .disabled(model.document == nil || model.isExporting)
                Divider()
                ForEach(Array(EditList.tracks), id: \.self) { track in
                    Button("Spur \(track) exportieren …") { model.exportTrack(track) }
                        .keyboardShortcut(KeyEquivalent(Character("\(track)")))
                        .disabled(!model.canExport(track: track))
                }
                Menu("Teile einzeln exportieren") {
                    ForEach(Array(EditList.tracks), id: \.self) { track in
                        Button("Teile von Spur \(track) …") { model.exportTrackParts(track) }
                            .keyboardShortcut(KeyEquivalent(Character("\(track)")), modifiers: [.command, .option])
                            .disabled(!model.canExport(track: track))
                    }
                }
                Menu("Mit Cue-Datei exportieren") {
                    ForEach(Array(EditList.tracks), id: \.self) { track in
                        Button("Spur \(track) …") { model.exportTrack(track, withCue: true) }
                            .disabled(!model.canExport(track: track))
                    }
                }
            }
            CommandMenu("Schnitt") {
                Button(model.isPlaying ? "Pause" : "Abspielen") { model.togglePlay() }
                    .disabled(model.document == nil)
                Menu("Abspielen") {
                    Picker("Abspielen", selection: Binding(get: { model.soloTrack ?? 0 }, set: { model.soloTrack = $0 == 0 ? nil : $0 })) {
                        Text("Alle Spuren").tag(0)
                        ForEach(Array(EditList.tracks), id: \.self) { Text("Nur Spur \($0)").tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                .disabled(model.document == nil)
                Button("Übergang vorhören") { model.previewCut() }
                    .disabled(model.edit.cuts.isEmpty)
                Divider()
                Button("Schnitt setzen") { model.cutAtPlayhead() }
                    .keyboardShortcut("b")
                    .disabled(model.document == nil)
                Button("Schnitt 10 ms früher") { model.nudgeCut(by: -0.01) }
                    .disabled(model.edit.cuts.isEmpty)
                Button("Schnitt 10 ms später") { model.nudgeCut(by: 0.01) }
                    .disabled(model.edit.cuts.isEmpty)
                Button("Pausen finden …") { model.isFindingPauses = true }
                    .disabled(model.document == nil)
                Menu("Teil auf Spur") {
                    ForEach(Array(EditList.tracks), id: \.self) { track in
                        Button("Spur \(track)") { model.moveCurrentPart(toTrack: track) }
                    }
                }
                .disabled(model.document == nil)
                Button(model.currentSegment?.deleted == true ? "Teil wiederherstellen" : "Teil löschen") {
                    model.toggleDeletedCurrentPart()
                }
                .disabled(model.currentSegment == nil)
                Button("Alle Schnitte entfernen") { model.resetEdits() }
                    .disabled(model.document == nil || !model.edit.hasEdits)
                Divider()
                Button("Vergrößern") { model.zoom(by: 2) }
                    .keyboardShortcut("+")
                    .disabled(model.document == nil)
                Button("Verkleinern") { model.zoom(by: 0.5) }
                    .keyboardShortcut("-")
                    .disabled(model.document == nil)
                Button("Ganze Datei zeigen") { model.zoomToFit() }
                    .keyboardShortcut("0")
                    .disabled(model.document == nil)
            }
            StudioCommands()
        }
    }
}
