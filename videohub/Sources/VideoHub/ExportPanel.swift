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

/// The format popup in the save panel (switching it changes the extension in the name field) and,
/// when the video is encoded anew, the codec popup.
@MainActor
final class FormatAccessory: NSObject {
    private let panel: NSSavePanel
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let codecPopup: NSPopUpButton?

    /// The chosen codec; nil when the video is copied without re-encoding.
    var codec: VideoCodec? {
        codecPopup.map { VideoCodec.allCases[max(0, $0.indexOfSelectedItem)] }
    }

    init(panel: NSSavePanel, format: VideoFormat, mp4Possible: Bool, codec: VideoCodec? = nil) {
        self.panel = panel
        codecPopup = codec.map { codec in
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.addItems(withTitles: VideoCodec.allCases.map(\.title))
            popup.selectItem(at: VideoCodec.allCases.firstIndex(of: codec) ?? 0)
            return popup
        }
        super.init()
        popup.autoenablesItems = false
        for option in VideoFormat.allCases {
            popup.addItem(withTitle: option.title)
            if option == .mp4, !mp4Possible {
                popup.lastItem?.isEnabled = false
                popup.lastItem?.toolTip = "ProRes passt ohne Neukodierung nur in MOV. Mit Effekten geht auch MP4."
            }
        }
        popup.selectItem(at: VideoFormat.allCases.firstIndex(of: format) ?? 0)
        popup.target = self
        popup.action = #selector(changed)

        var rows: [[NSView]] = [[NSTextField(labelWithString: "Format:"), popup]]
        if let codecPopup { rows.append([NSTextField(labelWithString: "Codec:"), codecPopup]) }
        let grid = NSGridView(views: rows)
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
        apply(format)
    }

    @objc private func changed() {
        apply(VideoFormat.allCases[max(0, popup.indexOfSelectedItem)])
    }

    private func apply(_ format: VideoFormat) {
        panel.allowedContentTypes = [format.contentType]
        let name = panel.nameFieldStringValue as NSString
        let known = ["mp4", "m4v", "mov"].contains(name.pathExtension.lowercased())
        let base = known ? name.deletingPathExtension : name as String
        panel.nameFieldStringValue = "\(base).\(format.fileExtension)"
    }
}
