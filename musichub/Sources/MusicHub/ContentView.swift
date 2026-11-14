import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        Group {
            if let document = model.document {
                EditorView(document: document)
                    .overlay {
                        if model.isLoading {
                            LoadingView().background(.regularMaterial)
                        }
                    }
            } else if model.isLoading {
                LoadingView()
            } else {
                EmptyStateView()
            }
        }
        .navigationTitle("MusicHub")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem {
                Button("Anhängen", systemImage: "doc.badge.plus") { model.showAppendPanel() }
                    .help("Weitere Dateien hinten an die Aufnahme anhängen – z. B. wenn der Rekorder sie geteilt hat")
                    .disabled(model.document == nil || model.isExporting || model.isLoading)
            }
            ToolbarItem {
                Button("Öffnen", systemImage: "folder") { model.showOpenPanel() }
                    .help("Audiodatei öffnen – mehrere werden aneinandergehängt (⌘O)")
                    .disabled(model.isExporting)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty, !model.isExporting else { return false }
            model.open(urls)
            return true
        }
        .onAppear { model.undoManager = undoManager }
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

    private var subtitle: String {
        guard let document = model.document else { return "" }
        return "\(document.displayName) · \(document.summary) · \(TimeFormat.string(document.duration, decimals: 0))"
    }
}

// MARK: - Empty and loading states

private struct EmptyStateView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Color(nsColor: StudioApp.music.ink))
            Text("Audiodatei hierher ziehen")
                .font(.title2)
            Text("MusicHub öffnet MP3, M4A/AAC, ALAC, FLAC, WAV, AIFF, OGG und Opus – auch den Ton aus MP4- und MOV-Videos.\nMehrere Dateien auf einmal werden aneinandergehängt. Exportiert wird immer als MP3 mit 320 kbit/s.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Datei öffnen …") { model.showOpenPanel() }
                .primaryAction(.music)
                .controlSize(.large)
                .padding(.top, 6)
            let recent = Array(model.recentRecordings.prefix(5))
            if !recent.isEmpty {
                VStack(spacing: 5) {
                    Text("Zuletzt geöffnet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(recent, id: \.self) { paths in
                        Button(RecentFiles.name(paths)) { model.openRecent(paths) }
                            .buttonStyle(.link)
                            .help(paths.joined(separator: "\n"))
                    }
                }
                .padding(.top, 18)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LoadingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 12) {
            Text("„\(model.loadingName)“ wird gelesen …")
            ProgressView(value: model.loadProgress)
                .frame(width: 280)
            Button("Abbrechen") { model.cancelLoading() }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Editor

private struct EditorView: View {
    @Environment(AppModel.self) private var model
    let document: AudioDocument

    var body: some View {
        VStack(spacing: 0) {
            TransportBar(document: document)
            Divider()
            HStack(spacing: 0) {
                TrackHeaders()
                    .frame(width: 186)
                Divider()
                TimelineArea()
            }
            .frame(minHeight: 300)
            Divider()
            PartsTable(document: document)
                .frame(minHeight: 110, idealHeight: 170, maxHeight: 170)
            Divider()
            FooterBar()
        }
    }
}

/// Kept apart, so that only the timeline redraws while playing.
private struct TimelineArea: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let peaks = model.peaks, let document = model.document {
            TimelineView(state: TimelineState(peaks: peaks, sampleRate: document.sampleRate, segments: model.edit.segments,
                                              playhead: model.playhead, visibleStart: model.visibleStart,
                                              visibleLength: model.visibleLength, soloTrack: model.soloTrack,
                                              proposedCuts: model.proposedCuts,
                                              fileStarts: document.files.dropFirst().map { ($0.start, $0.url.lastPathComponent) }),
                         model: model)
        }
    }
}

/// One header per track, aligned with the lanes of the timeline (ruler on top, scroll bar below).
private struct TrackHeaders: View {
    var body: some View {
        VStack(spacing: 0) {
            Text("Spuren")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: TimelineNSView.rulerHeight)
                .background(Color(nsColor: Darcula.surface))
                .overlay(alignment: .bottom) { Divider() }
            ForEach(Array(EditList.tracks), id: \.self) { track in
                TrackHeader(track: track)
                    .frame(maxHeight: .infinity)
                    .overlay(alignment: .bottom) { Divider() }
            }
            Color.clear.frame(height: TimelineNSView.scrollerHeight)
        }
    }
}

private struct TrackHeader: View {
    @Environment(AppModel.self) private var model
    let track: Int

    var body: some View {
        let parts = model.edit.segments(onTrack: track)
        let solo = model.soloTrack == track
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(nsColor: TrackStyle.color(track)))
                    .frame(width: 10, height: 10)
                Text("Spur \(track)")
                    .font(.headline)
                Spacer()
                Button { model.toggleSolo(track) } label: {
                    Image(systemName: solo ? "headphones.circle.fill" : "headphones")
                        .foregroundStyle(solo ? Color(nsColor: TrackStyle.color(track)) : .secondary)
                        .font(.system(size: 15))
                }
                .buttonStyle(.borderless)
                .help(solo ? "Wieder alle Spuren abspielen" : "Nur diese Spur abspielen – so, wie sie exportiert wird")
            }
            Text(summary(parts))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Menu("Exportieren …") {
                Button("Als eine MP3 exportieren …") { model.exportTrack(track) }
                Button("Als eine MP3 mit Cue-Datei exportieren …") { model.exportTrack(track, withCue: true) }
                Button(parts.count == 1 ? "Teil einzeln exportieren …" : "\(parts.count) Teile einzeln exportieren …") {
                    model.exportTrackParts(track)
                }
            } primaryAction: {
                model.exportTrack(track)
            }
            .fixedSize()
            .disabled(!model.canExport(track: track))
            .help("Klick: alle Teile der Spur als eine MP3, jeder Teil ein Kapitel (⌘\(track)) · Pfeil: mit Cue-Datei oder jeden Teil als eigene MP3")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(model.soloTrack.map { $0 == track } ?? false ? Color(nsColor: TrackStyle.color(track)).opacity(0.08) : .clear)
    }

    private func summary(_ parts: [Segment]) -> String {
        guard let document = model.document, !parts.isEmpty else { return "leer" }
        let duration = TimeFormat.string(document.seconds(parts.reduce(0) { $0 + $1.length }), decimals: 0)
        return (parts.count == 1 ? "1 Teil" : "\(parts.count) Teile") + " · " + duration
    }
}

private struct TransportBar: View {
    @Environment(AppModel.self) private var model
    let document: AudioDocument

    var body: some View {
        @Bindable var model = model

        HStack(spacing: 10) {
            Button { model.jumpToCut(forward: false) } label: {
                Image(systemName: "backward.end.fill")
            }
            .help("Zum vorherigen Schnitt (⌥←)")
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 22)
            }
            .help(model.isPlaying ? "Pause (Leertaste)" : "Abspielen (Leertaste)")
            Button { model.jumpToCut(forward: true) } label: {
                Image(systemName: "forward.end.fill")
            }
            .help("Zum nächsten Schnitt (⌥→)")
            Button { model.previewCut() } label: {
                Image(systemName: "ear")
            }
            .help("Übergang am nächsten Schnitt vorhören: 2 s davor bis 2 s danach (V). Mit Kopfhörer-Solo so, wie die Spur exportiert wird. Den Schnitt verschieben: , und . (10 ms), mit ⇧ 100 ms")
            .disabled(model.edit.cuts.isEmpty)

            PlayheadTime(duration: document.duration)
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
                .help("Zoom (Trackpad: zwei Finger spreizen, Maus: ⌥ + Scrollrad, ganze Datei: ⌘0)")
            Button { model.zoom(by: 2) } label: { Image(systemName: "plus.magnifyingglass") }
                .buttonStyle(.borderless)
                .help("Vergrößern (⌘+)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func editTools(labels: Bool) -> some View {
        @Bindable var model = model
        return HStack(spacing: 10) {
            Button { model.cutAtPlayhead() } label: {
                Label("Schneiden", systemImage: "scissors")
                    .labelStyle(labels ? AnyLabelStyle(.titleAndIcon) : AnyLabelStyle(.iconOnly))
            }
            .help("Schnitt an der Abspielposition setzen (S)")
            Button { model.isFindingPauses = true } label: {
                Label("Pausen finden …", systemImage: "waveform.badge.magnifyingglass")
                    .labelStyle(labels ? AnyLabelStyle(.titleAndIcon) : AnyLabelStyle(.iconOnly))
            }
            .help("Pausen finden: leise Stellen zwischen den Stücken suchen und dort schneiden")
            .popover(isPresented: $model.isFindingPauses, arrowEdge: .bottom) {
                PauseFinderView(model: model)
            }
            if let current = model.currentSegment {
                HStack(spacing: 6) {
                    if labels {
                        Text("Teil \((model.edit.segments.firstIndex(of: current) ?? 0) + 1) " + (current.deleted ? "gelöscht" : "auf"))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    TrackPicker(segment: current) { model.setTrack($0, for: current.id) }
                        .help(current.deleted
                              ? "Den gelöschten Teil auf einer Spur wiederherstellen (Tasten 1, 2, 3)"
                              : "Den Teil an der Abspielposition auf eine Spur legen (Tasten 1, 2, 3 – oder den Teil im Zeitstrahl nach oben/unten ziehen)")
                    DeleteButton(model: model, segment: current)
                }
                .fixedSize()
            }
        }
        .fixedSize()
    }
}

/// Lets a label switch between title and icon depending on the room.
private struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView

    init<Style: LabelStyle>(_ style: Style) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// Segmented 1 | 2 | 3; nothing is selected for a deleted part.
private struct TrackPicker: View {
    let segment: Segment
    let onChange: (Int) -> Void

    var body: some View {
        Picker("Spur", selection: Binding(get: { segment.deleted ? 0 : segment.track }, set: onChange)) {
            ForEach(Array(EditList.tracks), id: \.self) { Text("\($0)").tag($0) }
        }
        .labelsHidden()
        .darculaSegments(.music)
        .fixedSize()
    }
}

/// Deletes a part, or restores a deleted one on its track. Gets the model passed in, because it
/// also sits in table cells.
private struct DeleteButton: View {
    let model: AppModel
    let segment: Segment

    var body: some View {
        Button { model.setDeleted(!segment.deleted, for: segment.id) } label: {
            Image(systemName: segment.deleted ? "arrow.uturn.backward" : "trash")
                .frame(width: 16)
        }
        .buttonStyle(.borderless)
        .help(segment.deleted ? "Teil wiederherstellen (auf Spur \(segment.track))"
                              : "Teil löschen: wird nicht exportiert und beim Abspielen übersprungen (⌫)")
    }
}

/// Own view, so that the 30 updates per second while playing stay inside it.
private struct PlayheadTime: View {
    @Environment(AppModel.self) private var model
    let duration: Double

    var body: some View {
        let hours = duration >= 3600
        HStack(spacing: 4) {
            Text(TimeFormat.string(Double(model.playhead) / (model.document?.sampleRate ?? 1), decimals: 2, forceHours: hours))
                .font(.title3.monospacedDigit())
            Text("/ " + TimeFormat.string(duration, decimals: 2, forceHours: hours))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Parts

private struct PartRow: Identifiable {
    let number: Int
    let segment: Segment
    var id: Segment.ID { segment.id }
}

private struct PartsTable: View {
    @Environment(AppModel.self) private var model
    let document: AudioDocument

    var body: some View {
        let rows = model.edit.segments.enumerated().map { PartRow(number: $0.offset + 1, segment: $0.element) }
        let hours = document.duration >= 3600
        Table(rows, selection: Binding(get: { model.currentSegmentID }, set: { if let id = $0 { model.select(id) } })) {
            TableColumn("Nr.") { row in
                HStack(spacing: 6) {
                    Circle()
                        .fill(row.segment.deleted ? Color.secondary.opacity(0.4) : Color(nsColor: TrackStyle.color(row.segment.track)))
                        .frame(width: 8, height: 8)
                    Text("\(row.number)")
                        .monospacedDigit()
                }
                .opacity(dimmed(row))
            }
            .width(44)
            TableColumn("Spur") { row in
                TrackPicker(segment: row.segment) { model.setTrack($0, for: row.id) }
                    .controlSize(.small)
                    .help(row.segment.deleted ? "Gelöscht – eine Spur wählen, um den Teil dort wiederherzustellen" : "Spur, mit der der Teil exportiert wird")
            }
            .width(92)
            TableColumn("Name (für den Export einzelner Teile)") { row in
                NameField(model: model, row: row)
                    .opacity(dimmed(row))
            }
            TableColumn("Anfang") { row in time(row.segment.start, hours).opacity(dimmed(row)) }
                .width(96)
            TableColumn("Ende") { row in time(row.segment.end, hours).opacity(dimmed(row)) }
                .width(96)
            TableColumn("Länge") { row in time(row.segment.length, hours).opacity(dimmed(row)) }
                .width(96)
            TableColumn("Einblenden") { row in fade(row.segment.fadeIn).opacity(dimmed(row)) }
                .width(78)
            TableColumn("Ausblenden") { row in fade(row.segment.fadeOut).opacity(dimmed(row)) }
                .width(78)
            TableColumn("") { row in
                HStack(spacing: 8) {
                    Button { model.exportPart(row.id) } label: {
                        Image(systemName: "square.and.arrow.up")
                            .frame(width: 16)
                    }
                    .buttonStyle(.borderless)
                    .help("Nur diesen Teil als MP3 exportieren")
                    .disabled(model.isExporting || row.segment.deleted)
                    DeleteButton(model: model, segment: row.segment)
                }
            }
            .width(52)
        }
        .alternatingRowBackgrounds(.disabled)
        .scrollContentBackground(.hidden)
    }

    private func dimmed(_ row: PartRow) -> Double { row.segment.deleted ? 0.4 : 1 }

    private func fade(_ frames: Int64) -> some View {
        Text(frames == 0 ? "–" : document.seconds(frames).formatted(.number.precision(.fractionLength(1))) + " s")
            .monospacedDigit()
            .foregroundStyle(frames == 0 ? .tertiary : .primary)
            .help("Ziehe im Zeitstrahl den runden Griff oben am Teil nach innen")
    }

    private func time(_ frame: Int64, _ hours: Bool) -> some View {
        Text(TimeFormat.string(document.seconds(frame), decimals: 2, forceHours: hours))
            .monospacedDigit()
    }
}

/// Edits locally and hands the name to the model when editing ends, so that every keystroke
/// does not rewrite the stored edits. Gets the model passed in: table cells do not reliably
/// inherit the environment.
private struct NameField: View {
    let model: AppModel
    let row: PartRow
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Teil \(row.number)", text: $text)
            .textFieldStyle(.plain)
            .focused($focused)
            .onAppear { text = row.segment.name }
            .onChange(of: row.segment.name) { _, name in if !focused { text = name } }
            .onChange(of: focused) { _, isFocused in if !isFocused { save() } }
            .onSubmit { save() }
    }

    private func save() {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name != row.segment.name { model.rename(row.id, to: name) }
    }
}

// MARK: - Footer

private struct FooterBar: View {
    @Environment(AppModel.self) private var model
    @State private var showsTags = false

    var body: some View {
        @Bindable var model = model

        HStack(spacing: 12) {
            Text((model.edit.segments.count == 1 ? "1 Teil" : "\(model.edit.segments.count) Teile")
                 + (model.edit.deletedCount > 0 ? " · \(model.edit.deletedCount) gelöscht" : ""))
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
                if model.suggestedCue != nil {
                    Button("Titel als Schnitte übernehmen") { model.acceptSuggestedCue() }
                        .buttonStyle(.link)
                }
            }
            Spacer(minLength: 12)
            Button { showsTags = true } label: {
                Label(tagSummary, systemImage: "tag")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 220, alignment: .trailing)
            }
            .buttonStyle(.borderless)
            .help("Interpret, Album und Cover der exportierten MP3s")
            .popover(isPresented: $showsTags, arrowEdge: .top) {
                TagsView(model: model)
            }
            Toggle("Lautheit angleichen", isOn: $model.normalizeLoudness)
                .toggleStyle(.checkbox)
                .help("Jede exportierte Datei auf −14 LUFS bringen – so laut, wie Spotify und YouTube Musik abspielen. Leise Aufnahmen werden höchstens bis 1 dB unter die Übersteuerung angehoben.")
            Text("MP3 · 320 kbit/s")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var tagSummary: String {
        let tags = model.exportTags
        let text = [tags.artist, tags.album].compactMap { $0 }.joined(separator: " – ")
        return text.isEmpty ? "Tags" : text
    }
}

// MARK: - Pause finder

private struct PauseFinderView: View {
    let model: AppModel

    var body: some View {
        @Bindable var model = model
        let count = model.proposedCuts.count

        VStack(alignment: .leading, spacing: 12) {
            Text("Pausen finden")
                .font(.headline)
            Text("Leise Stellen zwischen den Stücken werden zu Schnitten, jeweils in der Mitte der Pause.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Leiser als")
                        .fixedSize()
                    Slider(value: $model.pauseThreshold, in: -70...(-20), step: 1)
                        .frame(width: 170)
                    Text("\(Int(model.pauseThreshold)) dB")
                        .monospacedDigit()
                        .frame(width: 50, alignment: .trailing)
                }
                GridRow {
                    Text("Mindestens")
                        .fixedSize()
                    Slider(value: $model.pauseMinimum, in: 0.5...10, step: 0.5)
                        .frame(width: 170)
                    Text(model.pauseMinimum.formatted(.number.precision(.fractionLength(1))) + " s")
                        .monospacedDigit()
                        .frame(width: 50, alignment: .trailing)
                }
            }
            Text(count == 0 ? "Keine Pause gefunden. Schiebe „Leiser als“ nach rechts oder verkürze die Mindestlänge."
                 : (count == 1 ? "1 Pause gefunden" : "\(count) Pausen gefunden") + " – im Zeitstrahl gestrichelt.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Abbrechen") { model.isFindingPauses = false }
                    .keyboardShortcut(.cancelAction)
                Button(count == 1 ? "1 Schnitt setzen" : "\(count) Schnitte setzen") { model.applyProposedCuts() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(count == 0)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}

// MARK: - Tags

/// Interpret, album and cover for the export. What the fields show goes into the MP3s; they start
/// with the tags of the source file. Saved when the popover closes or Return is pressed.
private struct TagsView: View {
    let model: AppModel
    @State private var artist = ""
    @State private var album = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tags für den Export")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Interpret")
                    TextField("leer", text: $artist)
                        .frame(width: 230)
                }
                GridRow {
                    Text("Album")
                    TextField(model.tags.title ?? model.document?.name ?? "leer", text: $album)
                        .frame(width: 230)
                }
                GridRow(alignment: .top) {
                    Text("Cover")
                    HStack(alignment: .top, spacing: 12) {
                        cover
                        VStack(alignment: .leading, spacing: 6) {
                            Button("Bild wählen …") { model.chooseCover() }
                            Button("Kein Cover") { setCover(.none) }
                                .disabled(model.exportTags.artwork == nil)
                            Button("Cover der Datei") { setCover(.source) }
                                .disabled(model.customTags.cover == .source)
                        }
                        .controlSize(.small)
                    }
                }
            }
            Text("Als Titel kommt der Name des Teils bzw. der Aufnahme in die MP3.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .onAppear {
            artist = model.exportTags.artist ?? ""
            album = model.exportTags.album ?? ""
        }
        .onDisappear { save() }
        .onSubmit { save() }
    }

    private var cover: some View {
        Group {
            if let data = model.exportTags.artwork, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: Darcula.raised))
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.setCover(url)
            return true
        }
        .help("Ein Bild hierher ziehen")
    }

    private func setCover(_ cover: CustomTags.Cover) {
        var tags = model.customTags
        tags.cover = cover
        model.setCustomTags(tags)
    }

    /// A field equal to the source's value keeps following the source; anything else is the user's.
    private func save() {
        var tags = model.customTags
        let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = album.trimmingCharacters(in: .whitespacesAndNewlines)
        tags.artist = artist == (model.tags.artist ?? "") ? nil : artist
        tags.album = album == (model.tags.album ?? "") ? nil : album
        model.setCustomTags(tags)
    }
}

// MARK: - Export progress

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
