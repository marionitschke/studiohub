import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let batch = BatchModel()
    private var keyMonitor: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        Darcula.applyAppearance()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when the binary is started without an .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        // Single keys (space, S, arrows, comma, period, ⌫) work everywhere in the main window except in
        // text fields. Menu shortcuts without ⌘ would also swallow these keys while typing.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return handled ? nil : event
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard model.tab == .edit, let window = event.window, !(window is NSPanel), window.attachedSheet == nil,
              NSApp.modalWindow == nil else { return false }
        if let text = window.firstResponder as? NSTextView, text.isEditable { return false }
        return model.handleKey(event)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        model.show(.edit)
        model.open(urls)
    }

    /// With unexported cuts or a running batch the app stays open when the window is closed; the Dock
    /// icon brings it back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !model.hasUnexportedChanges && !model.isExporting && !batch.isRunning
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.isExporting {
            let alert = NSAlert()
            alert.messageText = "Der Export läuft noch."
            alert.informativeText = "Beim Beenden wird er abgebrochen; die halb fertige Datei wird gelöscht."
            alert.addButton(withTitle: "Weiter exportieren")
            alert.addButton(withTitle: "Abbrechen und beenden")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
            // The export may have ended while the alert was open; nothing would answer a later reply then.
            if model.isExporting {
                model.quitAfterExport = true
                model.cancelExport()
                batch.cancel()
                return .terminateLater
            }
        }
        if batch.isRunning {
            let alert = NSAlert()
            alert.messageText = "Die Stapelverarbeitung läuft noch."
            alert.informativeText = "Beim Beenden wird das Video abgebrochen, an dem sie gerade arbeitet. Fertige Videos bleiben; ein neuer Start überspringt sie."
            alert.addButton(withTitle: "Weiterlaufen lassen")
            alert.addButton(withTitle: "Abbrechen und beenden")
            guard alert.runModal() == .alertSecondButtonReturn, model.confirmDiscard(beforeOpening: false) else { return .terminateCancel }
            // Quits once the batch has removed its half-finished files.
            if batch.isRunning {
                batch.onRunEnded = { NSApp.reply(toApplicationShouldTerminate: true) }
                batch.cancel()
                return .terminateLater
            }
            return .terminateNow
        }
        return model.confirmDiscard(beforeOpening: false) ? .terminateNow : .terminateCancel
    }
}

@main
struct VideoHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        Darcula.prepare()
    }

    var body: some Scene {
        let model = appDelegate.model
        Window("VideoHub", id: "main") {
            ContentView()
                .environment(model)
                .environment(appDelegate.batch)
                .frame(minWidth: 820, minHeight: 600)
                .darculaWindow()
        }
        .defaultSize(width: 1200, height: 820)
        .commands {
            // The commands of the editor act on the video in the "Schnitt" tab only while it is shown.
            let editing = model.tab == .edit
            CommandGroup(replacing: .newItem) {
                Button("Öffnen …") {
                    model.show(.edit)
                    model.showOpenPanel()
                }
                .keyboardShortcut("o")
                .disabled(model.isExporting)
                Divider()
                Button("Video exportieren …") { model.exportVideo() }
                    .keyboardShortcut("e")
                    .disabled(!model.canExport || !editing)
                Menu("Ton exportieren") {
                    ForEach(AudioFormat.allCases, id: \.self) { format in
                        Button("Als \(format.title) …") { model.exportAudio(format) }
                    }
                }
                .disabled(!model.canExportAudio || !editing)
                Divider()
                // MusicHub reads the sound of the original file; the cuts made here are not passed on.
                Button("Originalton in MusicHub öffnen") {
                    if let url = model.document?.url { StudioApp.music.open([url]) }
                }
                .disabled(model.document == nil)
            }
            CommandGroup(before: .toolbar) {
                ForEach(Array(AppTab.allCases.enumerated()), id: \.element) { index, tab in
                    Toggle(tab.title, isOn: Binding(get: { model.tab == tab }, set: { _ in model.show(tab) }))
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                }
                Divider()
            }
            CommandMenu("Schnitt") {
                Group {
                    Button(model.isPlaying ? "Pause" : "Abspielen") { model.togglePlay() }
                        .disabled(model.document == nil)
                    Divider()
                    Button("Schneiden") { model.cutAtPlayhead() }
                        .keyboardShortcut("b")
                        .disabled(model.document == nil || model.edit.parts.isEmpty)
                    Button("Teil löschen") { model.deleteCurrentPart() }
                        .disabled(model.currentIndex == nil)
                    Button("Alle Schnitte entfernen") { model.resetEdits() }
                        .disabled(model.document == nil || !model.edit.hasEdits)
                    Divider()
                    Button(model.currentSound.isDetached ? "Ton wieder anlegen" : "Ton vom Bild lösen") { model.toggleDetachedSound() }
                        .disabled(!model.canEditSound)
                    Button(model.currentSound == .muted ? "Ton einschalten" : "Ton stummschalten") { model.toggleMute() }
                        .disabled(!model.canEditSound)
                    Button("Ton ein Bild früher") { model.nudgeSound(frames: -1) }
                        .disabled(!model.canEditSound)
                    Button("Ton ein Bild später") { model.nudgeSound(frames: 1) }
                        .disabled(!model.canEditSound)
                    Divider()
                    Button("Vergrößern") { model.zoom(by: 2) }
                        .keyboardShortcut("+")
                        .disabled(model.document == nil)
                    Button("Verkleinern") { model.zoom(by: 0.5) }
                        .keyboardShortcut("-")
                        .disabled(model.document == nil)
                    Button("Alles zeigen") { model.zoomToFit() }
                        .keyboardShortcut("0")
                        .disabled(model.document == nil)
                }
                .disabled(!editing)
            }
            CommandMenu("Effekte") {
                Group {
                    let noEdit = model.document == nil || model.edit.parts.isEmpty
                    Button("Titel hinzufügen") { model.addTitle() }
                        .disabled(noEdit)
                    Button("Titel löschen") { if let id = model.selectedTitleID { model.deleteTitle(id) } }
                        .disabled(model.selectedTitleID == nil)
                    Divider()
                    Menu("Übergang am nächsten Schnitt") {
                        Button("Überblendung") { model.setTransitionAtNearestCut(.dissolve) }
                        Button("Abblende über Schwarz") { model.setTransitionAtNearestCut(.black) }
                        Button("Kein Übergang") { model.setTransitionAtNearestCut(nil) }
                    }
                    .disabled(model.edit.parts.count < 2)
                    Toggle("Am Anfang aus Schwarz einblenden", isOn: Binding(get: { model.edit.transition(at: 0) != nil },
                                                                         set: { _ in model.toggleFadeIn() }))
                        .disabled(noEdit)
                    Toggle("Am Ende in Schwarz ausblenden", isOn: Binding(get: { model.edit.fadeOut != nil },
                                                                      set: { _ in model.toggleFadeOut() }))
                        .disabled(noEdit)
                    Divider()
                    Button(model.edit.logo == nil ? "Logo einsetzen" : "Logo bearbeiten") { model.addOrSelectLogo() }
                        .disabled(noEdit)
                    Button("Anderes Logo …") { model.chooseLogo() }
                        .disabled(noEdit)
                    Button("Logo entfernen") { model.removeLogo() }
                        .disabled(model.edit.logo == nil)
                }
                .disabled(!editing)
            }
            StudioCommands()
        }
    }
}
