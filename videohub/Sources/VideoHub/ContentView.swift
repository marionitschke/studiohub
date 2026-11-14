import SwiftUI
import ImageIO

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        Group {
            if let document = model.document {
                EditorView(document: document)
            } else if model.isOpening {
                ProgressView("Video wird geöffnet …")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyStateView()
            }
        }
        .navigationTitle("VideoHub")
        .navigationSubtitle(model.document.map { "\($0.url.lastPathComponent) · \($0.summary)" } ?? "")
        .toolbar {
            ToolbarItem {
                Button("Öffnen", systemImage: "folder") { model.showOpenPanel() }
                    .help("Video öffnen (⌘O)")
                    .disabled(model.isExporting)
            }
            ToolbarItem {
                Menu {
                    ForEach(AudioFormat.allCases, id: \.self) { format in
                        Button("Als \(format.title) …") { model.exportAudio(format) }
                    }
                } label: {
                    Label("Ton exportieren", systemImage: "waveform")
                }
                .help("Den Ton des Schnitts als eigene Datei speichern")
                .disabled(!model.canExportAudio)
            }
            ToolbarItem {
                Button("Video exportieren", systemImage: "square.and.arrow.up") { model.exportVideo() }
                    .help(model.exportReencodes
                          ? "Den Schnitt mit seinen Effekten als neues Video speichern – neu kodiert, SDR (⌘E)"
                          : "Den Schnitt als neues Video speichern – ohne Neukodierung, in Originalqualität (⌘E)")
                    .disabled(!model.canExport)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty, !model.isExporting else { return false }
            // After the drop has finished: opening may ask first.
            DispatchQueue.main.async { model.open(urls) }
            return true
        }
        .onAppear { model.undoManager = undoManager }
        // With unexported cuts the app outlives its window; it should not go on playing unseen.
        .onDisappear { model.pause() }
        .onChange(of: undoManager) { _, manager in model.undoManager = manager }
        .sheet(isPresented: Binding(get: { model.isExporting }, set: { _ in })) {
            ExportSheet()
        }
        .alert(
            "Das hat nicht geklappt",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

// MARK: - Empty state

private struct EmptyStateView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "film")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Color(nsColor: Style.ink))
            Text("Video hierher ziehen")
                .font(.title2)
            Text("VideoHub öffnet MOV- und MP4-Videos, zum Beispiel vom iPhone.\nOhne Effekte wird ohne Neukodierung exportiert – in Originalqualität, auch HDR. Schnitte werden nicht gespeichert.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Video öffnen …") { model.showOpenPanel() }
                .primaryAction(.video)
                .controlSize(.large)
                .padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Editor

private struct EditorView: View {
    @Environment(AppModel.self) private var model
    let document: VideoDocument

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                PreviewArea(document: document)
                if model.selection != nil {
                    Divider()
                    Inspector(document: document)
                        .frame(width: 260)
                }
            }
            .frame(minHeight: 200, maxHeight: .infinity)
            Divider()
            TransportBar(document: document)
            Divider()
            HStack(spacing: 0) {
                LaneHeaders()
                    .frame(width: 78)
                Divider()
                TimelineArea(document: document)
            }
            .frame(height: TimelineNSView.totalHeight)
            Divider()
            FooterBar(document: document)
        }
    }
}

/// Kept apart, so that only the timeline redraws while playing.
private struct TimelineArea: View {
    @Environment(AppModel.self) private var model
    let document: VideoDocument

    var body: some View {
        let edit = model.edit
        let layout = edit.hasEffects ? edit.effectLayout(frame: document.frameTicks) : EffectLayout()
        TimelineView(state: TimelineState(parts: edit.parts, playhead: model.playhead, visibleStart: model.visibleStart,
                                          visibleLength: model.visibleLength, timescale: Double(document.timescale),
                                          frameTicks: document.frameTicks, aspectRatio: document.aspectRatio,
                                          hasAudio: document.audioTrack != nil, peaks: model.peaks,
                                          audioRate: document.audioSampleRate, titles: edit.placedTitles,
                                          selectedTitle: model.selectedTitleID,
                                          transitions: (0...edit.parts.count).map { edit.transition(at: $0) },
                                          regions: layout.regions),
                     model: model)
    }
}

/// Lane names, aligned with the lanes of the timeline (ruler on top, scroll bar below).
private struct LaneHeaders: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: TimelineNSView.rulerHeight)
                .background(Color(nsColor: Darcula.surface))
                .overlay(alignment: .bottom) { Divider() }
            Label("Titel", systemImage: "textformat")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: TimelineNSView.titleHeight)
                .overlay(alignment: .bottom) { Divider() }
                .help("Titel: ziehen verschiebt, Ränder ziehen ändert die Länge, Doppelklick fügt einen hinzu (T)")
            Label("Bild", systemImage: "film")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: TimelineNSView.videoHeight)
                .overlay(alignment: .bottom) { Divider() }
            VStack(alignment: .leading, spacing: 6) {
                Label("Ton", systemImage: "waveform")
                if let progress = model.peaksProgress {
                    ProgressView(value: progress)
                        .controlSize(.small)
                        .help("Die Wellenform wird gelesen")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .frame(height: TimelineNSView.audioHeight)
            .overlay(alignment: .bottom) { Divider() }
            Color.clear.frame(height: TimelineNSView.scrollerHeight)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

private struct TransportBar: View {
    @Environment(AppModel.self) private var model
    let document: VideoDocument

    var body: some View {
        @Bindable var model = model

        HStack(spacing: 10) {
            Button { model.jumpToPart(forward: false) } label: { Image(systemName: "backward.end.fill") }
                .help("Zum Anfang des Teils, dann zum vorherigen Teil (⌥←)")
            Button { model.step(frames: -1) } label: { Image(systemName: "chevron.left") }
                .help("Ein Bild zurück (←, mit ⇧ eine Sekunde)")
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 22)
            }
            .help(model.isPlaying ? "Pause (Leertaste)" : "Abspielen (Leertaste)")
            Button { model.step(frames: 1) } label: { Image(systemName: "chevron.right") }
                .help("Ein Bild vor (→, mit ⇧ eine Sekunde)")
            Button { model.jumpToPart(forward: true) } label: { Image(systemName: "forward.end.fill") }
                .help("Zum nächsten Teil (⌥→)")

            PlayheadTime()
                .fixedSize()
                .padding(.leading, 6)

            Spacer(minLength: 12)

            // Labels while there is room, icons in a narrow window.
            ViewThatFits(in: .horizontal) {
                editTools(labels: true)
                editTools(labels: false)
            }

            Divider().frame(height: 18)

            Button { model.zoom(by: 0.5) } label: { Image(systemName: "minus.magnifyingglass") }
                .buttonStyle(.borderless)
                .help("Verkleinern (⌘−)")
            Slider(value: $model.zoomFraction, in: 0...1)
                .frame(width: 110)
                .help("Zoom (Trackpad: zwei Finger spreizen, Maus: ⌥ + Scrollrad, alles zeigen: ⌘0)")
            Button { model.zoom(by: 2) } label: { Image(systemName: "plus.magnifyingglass") }
                .buttonStyle(.borderless)
                .help("Vergrößern (⌘+)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func editTools(labels: Bool) -> some View {
        HStack(spacing: 10) {
            Button { model.cutAtPlayhead() } label: {
                Label("Schneiden", systemImage: "scissors")
                    .labelStyle(labels ? AnyLabelStyle(.titleAndIcon) : AnyLabelStyle(.iconOnly))
            }
            .help("Schnitt an der Abspielposition setzen (S). Einen Schnitt verschieben: ziehen oder , und . (ein Bild, mit ⇧ zehn)")
            Button { model.deleteCurrentPart() } label: {
                Label("Teil löschen", systemImage: "trash")
                    .labelStyle(labels ? AnyLabelStyle(.titleAndIcon) : AnyLabelStyle(.iconOnly))
            }
            .help("Den Teil an der Abspielposition löschen (⌫). Rückgängig mit ⌘Z – oder den Rand des Nachbarteils wieder aufziehen.")
            .disabled(model.currentIndex == nil)
            if model.currentSound.isDetached {
                Button { model.toggleDetachedSound() } label: {
                    Label("Ton anlegen", systemImage: "link")
                        .labelStyle(labels ? AnyLabelStyle(.titleAndIcon) : AnyLabelStyle(.iconOnly))
                }
                .help("Den Ton dieses Teils wieder unverändert unter sein Bild legen (L)")
                .disabled(!model.canEditSound)
            } else {
                Button { model.toggleDetachedSound() } label: {
                    Label("Ton lösen", systemImage: "rectangle.split.1x2")
                        .labelStyle(labels ? AnyLabelStyle(.titleAndIcon) : AnyLabelStyle(.iconOnly))
                }
                .help("Den Ton dieses Teils vom Bild lösen (L): Dann lässt er sich in der Tonspur verschieben und an den Rändern kürzen oder verlängern. Ein Bild früher oder später: ⌥, und ⌥. (mit ⇧ zehn Bilder)")
                .disabled(!model.canEditSound)
            }
            Button { model.toggleMute() } label: {
                Label(model.currentSound == .muted ? "Ton an" : "Stumm",
                      systemImage: model.currentSound == .muted ? "speaker.wave.2" : "speaker.slash")
                    .labelStyle(labels ? AnyLabelStyle(.titleAndIcon) : AnyLabelStyle(.iconOnly))
            }
            .help(model.currentSound == .muted ? "Diesem Teil seinen Ton zurückgeben (M)" : "Den Ton dieses Teils stummschalten (M)")
            .disabled(!model.canEditSound)
            Button { model.addTitle() } label: {
                Label("Titel", systemImage: "textformat")
                    .labelStyle(labels ? AnyLabelStyle(.titleAndIcon) : AnyLabelStyle(.iconOnly))
            }
            .help("Einen Titel an der Abspielposition einfügen (T)")
            .disabled(model.edit.parts.isEmpty)
            Button { model.addOrSelectLogo() } label: {
                Label("Logo", systemImage: "seal")
                    .labelStyle(labels ? AnyLabelStyle(.titleAndIcon) : AnyLabelStyle(.iconOnly))
            }
            .help(model.edit.logo == nil
                  ? "Ein Logo über das ganze Video legen – VideoHub merkt sich Bild und Platz für das nächste Video"
                  : "Das Logo bearbeiten")
            .disabled(model.edit.parts.isEmpty)
        }
        .fixedSize()
    }
}

private struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView

    init<S: LabelStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// Position and length of the edit; kept apart because it changes with every frame.
private struct PlayheadTime: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let length = model.seconds(model.sequenceLength)
        let hours = length >= 3600
        HStack(spacing: 4) {
            Text(TimeFormat.string(model.seconds(model.playhead), forceHours: hours))
            Text("/").foregroundStyle(.tertiary)
            Text(TimeFormat.string(length, forceHours: hours)).foregroundStyle(.secondary)
        }
        .font(.system(.body, design: .monospaced))
    }
}

private struct FooterBar: View {
    @Environment(AppModel.self) private var model
    let document: VideoDocument

    var body: some View {
        HStack(spacing: 12) {
            Text(summary)
                .foregroundStyle(.secondary)
                .fixedSize()
            if let status = model.statusMessage {
                Text(status)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !model.exportedFiles.isEmpty {
                    Button("Im Finder zeigen") { model.showExportedFiles() }
                        .buttonStyle(.link)
                }
            }
            Spacer(minLength: 12)
            if model.hasUnexportedChanges {
                Label("Nicht exportiert", systemImage: "circle.fill")
                    .labelStyle(.titleAndIcon)
                    .imageScale(.small)
                    .foregroundStyle(Color(nsColor: Darcula.warn))
                    .help("Die Schnitte gehen beim Beenden verloren, wenn das Video nicht exportiert wird.")
            }
            Text(model.exportReencodes ? "Export mit Neukodierung · Effekte · SDR" : "Export ohne Neukodierung · Originalqualität")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(model.exportReencodes
                      ? "Übergänge, Titel und Logo werden ins Bild gerechnet: Das Video wird als H.264 oder HEVC neu kodiert, in SDR."
                      : "Bild und Ton werden kopiert – ohne Qualitätsverlust, HDR bleibt.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var summary: String {
        let count = model.edit.parts.count
        let parts = count == 1 ? "1 Teil" : "\(count) Teile"
        guard model.edit.hasEdits else { return parts }
        return "\(parts) · \(TimeFormat.string(model.seconds(model.sequenceLength), decimals: 0)) von \(TimeFormat.string(document.seconds(document.length), decimals: 0))"
    }
}

// MARK: - Effects in the preview

/// The preview with the frames of the titles at the playhead and of the logo; kept apart, because
/// it changes with the playhead.
private struct PreviewArea: View {
    @Environment(AppModel.self) private var model
    let document: VideoDocument

    var body: some View {
        PlayerView(player: model.player, pictureSize: document.displaySize, items: items, hasSelection: model.selection != nil,
                   model: model)
            .background(.black, ignoresSafeAreaEdges: [])
    }

    private var items: [OverlayItem] {
        let canvas = document.displaySize
        guard canvas.width > 0, canvas.height > 0 else { return [] }
        var result: [OverlayItem] = []
        for placed in model.edit.placedTitles where placed.range.contains(model.playhead) {
            guard let size = TitleArt.size(placed.title, canvas: canvas) else { continue }
            let width = size.width / canvas.width, height = size.height / canvas.height
            result.append(OverlayItem(target: .title(placed.title.id),
                                      frame: CGRect(x: placed.title.x - width / 2, y: placed.title.y - height / 2, width: width, height: height),
                                      selected: model.selectedTitleID == placed.title.id))
        }
        if let logo = model.edit.logo, let aspect = LogoAspect.ratio(logo.file) {
            let height = logo.width * canvas.width / aspect / canvas.height
            result.append(OverlayItem(target: .logo,
                                      frame: CGRect(x: logo.x - logo.width / 2, y: logo.y - height / 2, width: logo.width, height: height),
                                      selected: model.selection == .logo))
        }
        return result
    }
}

/// Width ÷ height of logo images, read once.
@MainActor
private enum LogoAspect {
    private static var cache: [URL: CGFloat] = [:]

    static func ratio(_ url: URL) -> CGFloat? {
        if let known = cache[url] { return known }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat, let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
              width > 0, height > 0 else { return nil }
        cache[url] = width / height
        return width / height
    }
}

// MARK: - Inspector

private struct Inspector: View {
    @Environment(AppModel.self) private var model
    let document: VideoDocument

    var body: some View {
        ScrollView {
            switch model.selection {
            case .title(let id):
                if let title = model.edit.title(id), let placed = model.edit.placedTitle(id) {
                    TitleInspector(id: id, title: title, placed: placed, document: document)
                }
            case .logo:
                if let logo = model.edit.logo { LogoInspector(logo: logo) }
            case nil:
                EmptyView()
            }
        }
        .background(Color(nsColor: Darcula.surface))
    }
}

private struct InspectorHeader: View {
    @Environment(AppModel.self) private var model
    let title: String
    let symbol: String

    var body: some View {
        HStack {
            Label(title, systemImage: symbol)
                .font(.headline)
            Spacer()
            Button { model.clearSelection() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Schließen (esc)")
        }
    }
}

private struct TitleInspector: View {
    @Environment(AppModel.self) private var model
    let id: UUID
    let title: Title
    let placed: PlacedTitle
    let document: VideoDocument
    @FocusState private var textFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            InspectorHeader(title: "Titel", symbol: "textformat")
            VStack(alignment: .leading, spacing: 4) {
                TextField("Text", text: Binding(get: { title.text }, set: { text in
                    model.changeTitle(id, "Titeltext ändern") { $0.text = text }
                }), axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.roundedBorder)
                .focused($textFocused)
                .onSubmit { model.finishLiveChange() }
                Text("Neue Zeile: ⌥↩")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Größe")
                Slider(value: Binding(get: { title.size }, set: { size in
                    model.changeTitle(id, "Titelgröße ändern") { $0.size = size }
                }), in: Title.minimumSize...Title.maximumSize) { editing in
                    if !editing { model.finishLiveChange() }
                }
            }
            Picker("Farbe", selection: Binding(get: { title.dark }, set: { dark in
                model.changeTitle(id, "Titelfarbe ändern") { $0.dark = dark }
                model.finishLiveChange()
            })) {
                Text("Weiß").tag(false)
                Text("Schwarz").tag(true)
            }
            .darculaSegments(.video)
            Toggle("Halbdurchsichtiger Kasten dahinter", isOn: Binding(get: { title.bar }, set: { bar in
                model.changeTitle(id, bar ? "Titelkasten einschalten" : "Titelkasten ausschalten") { $0.bar = bar }
                model.finishLiveChange()
            }))
            HStack {
                Button("Waagerecht mittig") {
                    model.changeTitle(id, "Titel verschieben") { $0.x = 0.5 }
                    model.finishLiveChange()
                }
                .disabled(title.x == 0.5)
                Spacer()
                Button(role: .destructive) { model.deleteTitle(id) } label: { Label("Löschen", systemImage: "trash") }
                    .help("Diesen Titel löschen (⌫)")
            }
            Text("\(TimeFormat.string(document.seconds(placed.start))) – \(TimeFormat.string(document.seconds(placed.end)))")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("Im Bild ziehen verschiebt den Titel. Wann und wie lange er zu sehen ist: in der Titelspur ziehen. Er gehört zu dem Teil, in dem er beginnt.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .onChange(of: textFocused) { _, focused in
            if !focused { model.finishLiveChange() }
        }
        .onAppear { takeFocus() }
        .onChange(of: model.focusTitleText) { _, _ in takeFocus() }
        .onChange(of: id) { _, _ in takeFocus() }
    }

    private func takeFocus() {
        guard model.focusTitleText else { return }
        model.focusTitleText = false
        DispatchQueue.main.async { textFocused = true }
    }
}

private struct LogoInspector: View {
    @Environment(AppModel.self) private var model
    let logo: Logo

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            InspectorHeader(title: "Logo", symbol: "seal")
            if let image = NSImage(contentsOf: logo.file) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 64)
                    .padding(8)
                    .background(Color(nsColor: Darcula.raised), in: RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Größe")
                Slider(value: Binding(get: { logo.width }, set: { width in
                    model.changeLogo("Logogröße ändern") { $0.width = width }
                }), in: Logo.minimumWidth...Logo.maximumWidth) { editing in
                    if !editing { model.finishLiveChange() }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Deckkraft")
                Slider(value: Binding(get: { logo.opacity }, set: { opacity in
                    model.changeLogo("Deckkraft ändern") { $0.opacity = opacity }
                }), in: 0.1...1) { editing in
                    if !editing { model.finishLiveChange() }
                }
            }
            HStack {
                Button("Anderes Bild …") { model.chooseLogo() }
                Spacer()
                Button(role: .destructive) { model.removeLogo() } label: { Label("Entfernen", systemImage: "trash") }
                    .help("Das Logo aus diesem Video entfernen (⌫)")
            }
            Text("Im Bild ziehen verschiebt das Logo. Es liegt über dem ganzen Video. VideoHub merkt sich Bild und Platz: Beim nächsten Video setzt „Logo“ es mit einem Klick wieder ein.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
    }
}

private struct ExportSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(model.exportLabel) wird exportiert …")
                .font(.headline)
            ProgressView(value: model.exportProgress)
            HStack {
                Text("\(Int(model.exportProgress * 100)) %")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Abbrechen") { model.cancelExport() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 400)
        .interactiveDismissDisabled()
    }
}
