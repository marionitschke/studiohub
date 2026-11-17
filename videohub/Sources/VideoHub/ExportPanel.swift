import AppKit
import UniformTypeIdentifiers

/// The container of an exported video.
enum VideoFormat: String, CaseIterable, Sendable {
    case mp4, mov

    var fileExtension: String { rawValue }
    var contentType: UTType { self == .mp4 ? .mpeg4Movie : .quickTimeMovie }

    var title: String {
        switch self {
        case .mp4: "MP4"
        case .mov: "MOV (QuickTime)"
        }
    }

    /// The container a file name stands for (M4V counts as MP4).
    init(of url: URL) {
        self = ["mp4", "m4v"].contains(url.pathExtension.lowercased()) ? .mp4 : .mov
    }

    /// What the save panel offers first: the last choice, else the container of the source; MOV
    /// when the source does not fit in an MP4 without re-encoding.
    static func preferred(remembered: String?, source: URL, mp4Possible: Bool) -> VideoFormat {
        let format = remembered.flatMap(VideoFormat.init(rawValue:)) ?? VideoFormat(of: source)
        return format == .mp4 && !mp4Possible ? .mov : format
    }

    static let defaultsKey = "videoFormat"
}

/// The popups in the save panel: format (switching it changes the extension in the name field),
/// quality and codec. The codec counts only when the video is encoded anew – with effects, or
/// compressed for sharing.
@MainActor
final class FormatAccessory: NSObject {
    private let panel: NSSavePanel
    private let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let qualityPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let codecPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let effects: Bool
    private let copiesIntoMP4: Bool
    private let message: (VideoQuality, VideoCodec) -> String

    var quality: VideoQuality { VideoQuality.allCases[max(0, qualityPopup.indexOfSelectedItem)] }
    var codec: VideoCodec { VideoCodec.allCases[max(0, codecPopup.indexOfSelectedItem)] }
    /// Whether the video is encoded anew (else it is copied as it is).
    var reencodes: Bool { effects || quality == .compact }

    /// `copiesIntoMP4`: the source fits in an MP4 without re-encoding. `message`: the panel's text for a choice.
    init(panel: NSSavePanel, format: VideoFormat, effects: Bool, copiesIntoMP4: Bool, quality: VideoQuality, codec: VideoCodec,
         message: @escaping (VideoQuality, VideoCodec) -> String) {
        self.panel = panel
        self.effects = effects
        self.copiesIntoMP4 = copiesIntoMP4
        self.message = message
        super.init()
        formatPopup.autoenablesItems = false
        formatPopup.addItems(withTitles: VideoFormat.allCases.map(\.title))
        formatPopup.selectItem(at: VideoFormat.allCases.firstIndex(of: format) ?? 0)
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged)
        for option in VideoQuality.allCases {
            switch option {
            case .highest: qualityPopup.addItem(withTitle: effects ? "Höchste Qualität" : "Original – ohne Neukodierung")
            case .compact: qualityPopup.addItem(withTitle: "Komprimiert (Social Media)")
            }
        }
        qualityPopup.selectItem(at: VideoQuality.allCases.firstIndex(of: quality) ?? 0)
        qualityPopup.target = self
        qualityPopup.action = #selector(choiceChanged)
        codecPopup.addItems(withTitles: VideoCodec.allCases.map(\.title))
        codecPopup.selectItem(at: VideoCodec.allCases.firstIndex(of: codec) ?? 0)
        codecPopup.target = self
        codecPopup.action = #selector(choiceChanged)

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Format:"), formatPopup],
            [NSTextField(labelWithString: "Qualität:"), qualityPopup],
            [NSTextField(labelWithString: "Codec:"), codecPopup],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.columnSpacing = 8
        grid.rowSpacing = 8
        let container = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        ])
        container.frame = NSRect(origin: .zero, size: container.fittingSize)
        panel.accessoryView = container
        update()
        apply(selectedFormat)
    }

    private var selectedFormat: VideoFormat { VideoFormat.allCases[max(0, formatPopup.indexOfSelectedItem)] }

    @objc private func formatChanged() {
        apply(selectedFormat)
    }

    @objc private func choiceChanged() {
        update()
    }

    /// ProRes fits in an MP4 only when it is encoded anew; the codec matters only then.
    private func update() {
        let mp4 = copiesIntoMP4 || reencodes
        if let item = formatPopup.item(at: VideoFormat.allCases.firstIndex(of: .mp4) ?? 0) {
            item.isEnabled = mp4
            item.toolTip = mp4 ? nil : "ProRes passt ohne Neukodierung nur in MOV. Mit Effekten oder komprimiert geht auch MP4."
        }
        if !mp4, selectedFormat == .mp4 {
            formatPopup.selectItem(at: VideoFormat.allCases.firstIndex(of: .mov) ?? 0)
            apply(.mov)
        }
        codecPopup.isEnabled = reencodes
        panel.message = message(quality, codec)
    }

    private func apply(_ format: VideoFormat) {
        panel.allowedContentTypes = [format.contentType]
        let name = panel.nameFieldStringValue as NSString
        let known = ["mp4", "m4v", "mov"].contains(name.pathExtension.lowercased())
        let base = known ? name.deletingPathExtension : name as String
        panel.nameFieldStringValue = "\(base).\(format.fileExtension)"
    }
}
