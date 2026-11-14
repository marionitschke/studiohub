import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The three dates Finder shows for a file: created, modified, added.
struct FileDates: Sendable, Equatable {
    var created: Date?
    var modified: Date?
    var added: Date?

    static func all(_ date: Date) -> FileDates {
        FileDates(created: date, modified: date, added: date)
    }

    static func read(_ url: URL) -> FileDates {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .addedToDirectoryDateKey])
        return FileDates(created: values?.creationDate, modified: values?.contentModificationDate, added: values?.addedToDirectoryDate)
    }

    /// Do all available dates match `date` to the second? Dates the file system doesn't provide are ignored.
    func matches(_ date: Date) -> Bool {
        [created, modified, added].allSatisfy { value in value.map { abs($0.timeIntervalSince(date)) < 1 } ?? true }
    }

    /// Writes the available dates. The path is text so umlauts in the name are not decomposed.
    @discardableResult
    static func write(_ dates: FileDates, toPath path: String) -> Bool {
        var attributes: [FileAttributeKey: Any] = [:]
        attributes[.creationDate] = dates.created
        attributes[.modificationDate] = dates.modified
        var success = true
        if !attributes.isEmpty {
            do { try FileManager.default.setAttributes(attributes, ofItemAtPath: path) } catch { success = false }
        }
        if let added = dates.added, !setAddedDate(added, path: path) { success = false }
        return success
    }

    /// `FileManager` can't set “date added”, `setattrlist` with ATTR_CMN_ADDEDTIME can. Otherwise Finder shows
    /// the time the file arrived in the folder.
    private static func setAddedDate(_ date: Date, path: String) -> Bool {
        var attributes = attrlist()
        attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(ATTR_CMN_ADDEDTIME)
        let seconds = date.timeIntervalSince1970.rounded(.down)
        var time = timespec(tv_sec: Int(seconds), tv_nsec: Int((date.timeIntervalSince1970 - seconds) * 1_000_000_000))
        return setattrlist(path, &attributes, &time, MemoryLayout<timespec>.size, 0) == 0
    }
}

/// Capture time from metadata – shared by the export sorter and the date fix.
enum CaptureDate {
    static func isMovie(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .audiovisualContent) == true
    }

    /// Like `organize_photos.py`: original before digitized before modified date from the metadata.
    /// Photos via ImageIO (with EXIF time zone, else local time), videos via AVFoundation. nil without a date.
    static func read(_ url: URL) async -> Date? {
        isMovie(url) ? await movie(url) : image(url)
    }

    static func movie(_ url: URL) async -> Date? {
        let asset = AVURLAsset(url: url)
        guard let item = try? await asset.load(.creationDate) else { return nil }
        return try? await item.load(.dateValue)
    }

    /// Reads only the file header but blocks briefly, so it belongs on GCD threads (`PhotoScanner.parallelMap`).
    static func image(_ url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let candidates: [(Any?, Any?)] = [
            (exif[kCGImagePropertyExifDateTimeOriginal], exif[kCGImagePropertyExifOffsetTimeOriginal]),
            (exif[kCGImagePropertyExifDateTimeDigitized], exif[kCGImagePropertyExifOffsetTimeDigitized]),
            (tiff[kCGImagePropertyTIFFDateTime], exif[kCGImagePropertyExifOffsetTime]),
        ]
        for (value, offset) in candidates {
            if let text = value as? String, let date = exifDate(text, offset: offset as? String) { return date }
        }
        return nil
    }

    /// “2026:08:01 14:30:00” plus an optional “+02:00”.
    private static func exifDate(_ text: String, offset: String?) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        if let offset, let zone = timeZone(fromOffset: offset) { formatter.timeZone = zone }
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: String(text.prefix(19)))
    }

    private static func timeZone(fromOffset offset: String) -> TimeZone? {
        let parts = offset.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2, let hours = Int(parts[0]), let minutes = Int(parts[1]) else { return nil }
        let sign = parts[0].hasPrefix("-") ? -1 : 1
        return TimeZone(secondsFromGMT: hours * 3600 + sign * minutes * 60)
    }
}
