import SwiftUI
import UniformTypeIdentifiers

/// The two areas of the window, switched in the middle of the title bar like PhotoHub's tabs.
enum AppTab: String, CaseIterable, Identifiable {
    case edit, batch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .edit: "Schnitt"
        case .batch: "Stapelverarbeitung"
        }
    }

    static let defaultsKey = "selectedTab"
}

/// The tab switcher: the selected tab in the selection color with white text.
struct TabStrip: View {
    @Binding var selection: AppTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppTab.allCases) { tab in
                let selected = tab == selection
                Button { selection = tab } label: {
                    Text(tab.title)
                        .font(.system(size: NSFont.systemFontSize, weight: .semibold))
                        .foregroundStyle(selected ? Color.white : Color(nsColor: Darcula.text))
                        .padding(.horizontal, 14)
                        .frame(height: 26)
                        .background(selected ? Color(nsColor: StudioApp.video.selection) : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(.horizontal, 2)
    }
}

// MARK: - Batch tab

struct BatchView: View {
    @Environment(BatchModel.self) private var batch

    var body: some View {
        HStack(spacing: 0) {
            BatchSettingsPane()
                .frame(width: 300)
            Divider()
            VStack(spacing: 0) {
                BatchPreview()
                    .frame(minHeight: 220, idealHeight: 340, maxHeight: 420)
                Divider()
                BatchList()
                    .frame(minHeight: 140, maxHeight: .infinity)
                Divider()
                BatchFooter()
            }
        }
        .onAppear { batch.appear() }
        .dropDestination(for: URL.self) { urls, _ in
            guard let folder = urls.first(where: { $0.hasDirectoryPath }), !batch.isRunning else { return false }
            DispatchQueue.main.async { batch.setSource(folder) }
            return true
        }
    }
}

private struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

private struct BatchSettingsPane: View {
    @Environment(BatchModel.self) private var batch

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(text: "Ordner")
                        FolderRow(label: "Quelle", url: batch.source, placeholder: "Ordner mit den Videos") { batch.chooseSource() }
                            .help("Bearbeitet werden die Videos direkt in diesem Ordner, ohne Unterordner. Die Originale bleiben unverändert.")
                        FolderRow(label: "Ziel", url: batch.destination, placeholder: "Ordner für die fertigen Videos") { batch.chooseDestination() }
                            .help("Die fertigen Videos bekommen den Namen des Originals. Was hier schon liegt, wird übersprungen.")
                    }
                    WatermarkSection()
                    OutputSection()
                    RecipeSection()
                }
                .padding(14)
            }
            Divider()
            StartArea()
                .padding(14)
        }
        .background(Color(nsColor: Darcula.surface))
    }
}

private struct FolderRow: View {
    let label: String
    let url: URL?
    let placeholder: String
    let choose: () -> Void
    @Environment(BatchModel.self) private var batch

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
            HStack(spacing: 6) {
                Label {
                    Text(url.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? placeholder)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(url == nil ? .tertiary : .primary)
                } icon: {
                    Image(systemName: "folder")
                        .foregroundStyle(Color(nsColor: StudioApp.video.ink))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(Color(nsColor: Darcula.raised), in: RoundedRectangle(cornerRadius: 6))
                .help(url?.path ?? placeholder)
                Button("Wählen …", action: choose)
            }
            .disabled(batch.isRunning)
        }
    }
}

private struct WatermarkSection: View {
    @Environment(BatchModel.self) private var batch

    var body: some View {
        let settings = batch.settings
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Wasserzeichen links unten")
            HStack(spacing: 10) {
                Group {
                    if let file = settings.watermark, let image = NSImage(contentsOf: file) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .padding(6)
                    } else {
                        Image(systemName: "seal")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 92, height: 52)
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 6) {
                    Button(settings.watermark == nil ? "Bild wählen …" : "Anderes Bild …") { batch.chooseWatermark() }
                    if settings.watermark != nil {
                        Button("Entfernen") { batch.removeWatermark() }
                            .buttonStyle(.link)
                    }
                }
            }
            SliderRow(title: "Größe", value: settings.watermarkSize, range: BatchSettings.sizeRange) { value in
                batch.change { $0.watermarkSize = value }
            }
            .help("Breite des Wasserzeichens im Verhältnis zur Bildhöhe")
            SliderRow(title: "Deckkraft", value: settings.watermarkOpacity, range: BatchSettings.opacityRange) { value in
                batch.change { $0.watermarkOpacity = value }
            }
            Text("Videos, die links unten schon ein Logo haben, bekommen keins dazu. Ändern per Rechtsklick in der Liste.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(batch.isRunning)
    }
}

private struct SliderRow: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let set: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int((value * 100).rounded())) %")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { value }, set: set), in: range)
        }
    }
}

private struct OutputSection: View {
    @Environment(BatchModel.self) private var batch

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Ausgabe")
            Picker("Format", selection: Binding(get: { batch.settings.format }, set: { format in batch.change { $0.format = format } })) {
                Text("MP4").tag(VideoFormat.mp4)
                Text("MOV").tag(VideoFormat.mov)
            }
            .darculaSegments(.video)
            Picker("Codec", selection: Binding(get: { batch.settings.codec }, set: { codec in batch.change { $0.codec = codec } })) {
                Text("H.264").tag(VideoCodec.h264)
                Text("HEVC").tag(VideoCodec.hevc)
            }
            .darculaSegments(.video)
            Text(batch.settings.codec == .h264 ? "H.264 läuft überall, auch auf alten Geräten." : "HEVC: kleinere Dateien, braucht neuere Geräte.")
                .font(.caption)
                .foregroundStyle(.secondary)
            // A menu: "Komprimiert (Social Media)" is too wide for a segment in this column.
            Picker("Qualität", selection: Binding(get: { batch.settings.quality }, set: { quality in batch.change { $0.quality = quality } })) {
                Text("Höchste Qualität").tag(VideoQuality.highest)
                Text("Komprimiert (Social Media)").tag(VideoQuality.compact)
            }
            .pickerStyle(.menu)
            .fixedSize()
            Text(batch.settings.quality == .compact
                 ? "Für WhatsApp, Instagram und Co.: viel kleinere Dateien, Bildgröße und Bildrate bleiben."
                 : "So gut, wie der Codec kann – große Dateien.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(batch.isRunning)
    }
}

private struct RecipeSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: "Immer dabei")
            RecipeLine(symbol: "textformat", text: "Titel aus dem Dateinamen, in den ersten 10 Sekunden ein- und ausgeblendet")
            RecipeLine(symbol: "circle.lefthalf.filled", text: "Am Anfang aus Schwarz einblenden, am Ende in Schwarz ausblenden – Bild und Ton")
            RecipeLine(symbol: "waveform", text: "Ton normalisiert: gleich laut (−16 LUFS), Spitzen begrenzt")
            RecipeLine(symbol: "film", text: "Größe und Bildrate wie das Original, SDR")
        }
    }
}

private struct RecipeLine: View {
    let symbol: String
    let text: String

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(Color(nsColor: StudioApp.video.ink))
                .frame(width: 18)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

private struct StartArea: View {
    @Environment(BatchModel.self) private var batch

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if batch.isRunning {
                Button { batch.cancel() } label: {
                    Text("Abbrechen")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .help("Das Video, an dem gerade gearbeitet wird, wird verworfen; fertige Videos bleiben. Ein neuer Start macht beim nächsten weiter.")
            } else {
                let waiting = batch.waitingItems.count
                Button { batch.start() } label: {
                    Text(waiting > 0 && batch.startProblem == nil ? "\(waiting == 1 ? "1 Video" : "\(waiting) Videos") bearbeiten" : "Starten")
                        .frame(maxWidth: .infinity)
                }
                .primaryAction(.video)
                .controlSize(.large)
                .disabled(batch.startProblem != nil)
                if let problem = batch.startProblem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct BatchPreview: View {
    @Environment(BatchModel.self) private var batch

    var body: some View {
        ZStack {
            Color.black
            if let preview = batch.preview {
                Image(nsImage: preview)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else if let problem = batch.previewProblem {
                Text(problem)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(30)
            } else if batch.source == nil {
                VStack(spacing: 12) {
                    Image(systemName: "square.stack.3d.down.right")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(Color(nsColor: StudioApp.video.ink))
                    Text("Ordner mit Videos wählen oder hierher ziehen")
                        .font(.title3)
                    Text("Alle Videos bekommen dasselbe Wasserzeichen, ihren Titel, Blenden am Anfang und Ende und gleich lauten Ton.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .padding(30)
            } else if !batch.items.isEmpty {
                ProgressView()
            }
        }
        .overlay(alignment: .topLeading) {
            if batch.preview != nil, let item = batch.selectedItem, item.getsWatermark == false {
                Label(item.watermarkChoice == false ? "Ohne Wasserzeichen (von Hand gewählt)" : "Hat schon ein Logo – kein Wasserzeichen",
                      systemImage: "checkmark.seal")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(10)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if batch.preview != nil, let time = batch.previewTime {
                Text("Vorschau bei \(TimeFormat.string(time, decimals: 0))")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(10)
                    .help("Ein anderes Video in der Liste wählen, um es in der Vorschau zu sehen.")
            }
        }
    }
}

private struct BatchList: View {
    @Environment(BatchModel.self) private var batch

    var body: some View {
        @Bindable var batch = batch
        Table(batch.items, selection: $batch.selection) {
            TableColumn("Video") { item in
                Text(item.source.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.source.lastPathComponent)
            }
            .width(min: 140, ideal: 210)
            TableColumn("Titel") { item in
                Text(item.title.replacingOccurrences(of: "\n", with: " · "))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(item.title)
            }
            .width(min: 140, ideal: 240)
            TableColumn("Länge") { item in
                Text(item.duration.map { TimeFormat.string($0, decimals: 0) } ?? "")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help(item.summary ?? "")
            }
            .width(min: 44, ideal: 52, max: 80)
            TableColumn("Wasserzeichen") { item in
                WatermarkCell(item: item)
            }
            .width(min: 90, ideal: 118, max: 160)
            TableColumn("Status") { item in
                StatusCell(status: item.status)
            }
            .width(min: 140, ideal: 200)
        }
        .alternatingRowBackgrounds(.disabled)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: Darcula.background))
        .contextMenu(forSelectionType: URL.self) { ids in
            if let id = ids.first, let item = batch.items.first(where: { $0.id == id }) {
                Picker("Wasserzeichen", selection: Binding(get: { item.watermarkChoice }, set: { batch.setWatermark($0, for: id) })) {
                    Text(item.hasLogo == true ? "Automatisch (hat schon ein Logo)" : "Automatisch").tag(Bool?.none)
                    Text("Wasserzeichen hinzufügen").tag(Bool?.some(true))
                    Text("Kein Wasserzeichen").tag(Bool?.some(false))
                }
                .pickerStyle(.inline)
                .disabled({ if case .running = item.status { true } else if case .done = item.status { true } else { false } }())
                Divider()
                Button("Original im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([item.source]) }
                if case .done = item.status {
                    Button("Ergebnis im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([item.destination]) }
                    Button("Ergebnis abspielen") { NSWorkspace.shared.open(item.destination) }
                }
            }
        }
        .overlay {
            if batch.items.isEmpty, batch.source != nil, !batch.isScanning {
                Text("Im Quellordner liegen keine Videos.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct WatermarkCell: View {
    let item: BatchItem

    var body: some View {
        switch item.getsWatermark {
        case nil:
            if case .unreadable = item.status { Text("") } else { Text("…").foregroundStyle(.tertiary).help("Wird noch geprüft") }
        case true?:
            Text(item.watermarkChoice == true ? "Ja (von Hand)" : "Ja")
                .foregroundStyle(.secondary)
        case false?:
            if item.watermarkChoice == false {
                Text("Nein (von Hand)").foregroundStyle(.secondary)
            } else {
                Label("Hat schon eins", systemImage: "checkmark.seal")
                    .foregroundStyle(.secondary)
                    .help("Links unten ist schon ein Logo im Video – es kommt keins dazu. Ändern per Rechtsklick.")
            }
        }
    }
}

private struct StatusCell: View {
    let status: BatchItem.Status

    var body: some View {
        switch status {
        case .waiting:
            Text("Wartet").foregroundStyle(.secondary)
        case .exists:
            Text("Schon im Ziel – wird übersprungen").foregroundStyle(.tertiary)
        case .unreadable(let problem):
            Label("Lässt sich nicht öffnen", systemImage: "exclamationmark.triangle")
                .foregroundStyle(Color(nsColor: Darcula.warn))
                .help(problem)
        case .running(let phase, let value):
            HStack(spacing: 8) {
                ProgressView(value: value)
                    .controlSize(.small)
                    .tint(Color(nsColor: StudioApp.video.ink))
                    .frame(maxWidth: 90)
                Text(phase == .sound ? "Ton" : "\(Int(value * 100)) %")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        case .done(let sound):
            HStack(spacing: 6) {
                Label("Fertig", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color(nsColor: Darcula.success))
                if let sound {
                    Text(Self.describe(sound))
                        .foregroundStyle(.secondary)
                        .help(Self.details(sound))
                } else {
                    Text("ohne Ton").foregroundStyle(.secondary)
                }
            }
        case .failed(let message):
            Label("Fehler", systemImage: "xmark.octagon.fill")
                .foregroundStyle(Color(nsColor: Darcula.danger))
                .help(message)
        case .cancelled:
            Text("Abgebrochen").foregroundStyle(.secondary)
        }
    }

    static func decibels(_ value: Double) -> String {
        let text = String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",").replacingOccurrences(of: "-", with: "−")
        return value > 0.05 ? "+\(text)" : text
    }

    static func describe(_ sound: SoundNormalizer.Result) -> String {
        "Ton \(decibels(sound.gain)) dB"
    }

    static func details(_ sound: SoundNormalizer.Result) -> String {
        var lines: [String] = []
        if let measured = sound.measured {
            lines.append("Vorher \(decibels(measured)) LUFS, jetzt \(decibels(SoundNormalizer.target)) LUFS (\(decibels(sound.gain)) dB).")
        } else {
            lines.append("Der Ton ist still; die Lautstärke blieb.")
        }
        lines.append("Spitze \(decibels(sound.peak)) dBFS" + (sound.limited > 0.1 ? ", Spitzen um bis zu \(decibels(sound.limited)) dB begrenzt." : "."))
        return lines.joined(separator: "\n")
    }
}

private struct BatchFooter: View {
    @Environment(BatchModel.self) private var batch

    var body: some View {
        HStack(spacing: 12) {
            Text(summary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let message = batch.finishedMessage, !batch.isRunning {
                Text(message)
                    .lineLimit(1)
                Button("Im Finder zeigen") { batch.showResults() }
                    .buttonStyle(.link)
            }
            Spacer(minLength: 12)
            if batch.isScanning || batch.isCheckingLogos {
                ProgressView()
                    .controlSize(.small)
                    .help(batch.isScanning ? "Die Videos werden gelesen" : "Die Videos werden auf ein vorhandenes Logo geprüft")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var summary: String {
        let items = batch.items
        guard !items.isEmpty else { return batch.source == nil ? "Kein Quellordner gewählt" : "Keine Videos" }
        let total = items.compactMap(\.duration).reduce(0, +)
        var parts = [items.count == 1 ? "1 Video" : "\(items.count) Videos"]
        if total > 0 { parts.append(Self.duration(total)) }
        if batch.isRunning {
            let finished = items.filter { if case .done = $0.status { true } else { false } }.count
            let open = items.filter {
                switch $0.status {
                case .waiting, .running: true
                default: false
                }
            }.count
            parts = ["\(finished) fertig, \(open) offen"]
            if let left = batch.remainingSeconds { parts.append("noch etwa \(Self.duration(left))") }
        } else {
            let existing = items.filter { $0.status == .exists }.count
            let unreadable = items.filter { if case .unreadable = $0.status { true } else { false } }.count
            let withLogo = items.filter { $0.getsWatermark == false }.count
            if withLogo > 0 { parts.append("\(withLogo) ohne Wasserzeichen") }
            if existing > 0 { parts.append("\(existing) schon im Ziel") }
            if unreadable > 0 { parts.append("\(unreadable) nicht lesbar") }
        }
        return parts.joined(separator: " · ")
    }

    /// "3 h 20 min", "12 min", "40 s".
    static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if seconds < 60 { return "\(Int(seconds.rounded())) s" }
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}
