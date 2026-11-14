// MusicHub checks (scripts/check.sh): edit list, formatting, ID3 tags and chapters, cue sheets, pause
// finder, loudness, peaks, MP3 export, joined files, stored edits. Works only in temporary folders.
import AppKit
import AVFoundation
import Foundation

@main
enum Checks {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passed = 0

    static func check(_ condition: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
        if condition {
            passed += 1
        } else {
            failures += 1
            let extra = detail()
            print("✗ \(label)" + (extra.isEmpty ? "" : " – \(extra)"))
        }
    }

    static func equal<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        check(actual == expected, label, "\(actual) ≠ \(expected)")
    }

    static func near(_ actual: Double, _ expected: Double, _ tolerance: Double, _ label: String) {
        check(abs(actual - expected) <= tolerance, label, "\(actual) ≉ \(expected) (±\(tolerance))")
    }

    static func main() {
        editList()
        deletedParts()
        fades()
        formatting()
        id3()
        cueSheets()
        pauses()
        preview()
        loudness()
        let root = temp("audio")
        peaks(root)
        cueFiles(root)
        export(root)
        normalizedExport(root)
        formats(root)
        joinedFiles(root)
        artwork(root)
        editStore(root)
        // Not in a defer: exit() below would skip it.
        try? FileManager.default.removeItem(at: root)
        print("\(passed) Prüfungen bestanden, \(failures) fehlgeschlagen.")
        exit(failures == 0 ? 0 : 1)
    }

    static func temp(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("musichub-check-\(name)-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Edit list

    static func deletedParts() {
        var edit = EditList(length: 1000)
        edit.cut(at: [250, 500, 750], minimumLength: 10)
        edit.setTrack(2, for: edit.segments[3].id)
        edit.rename(edit.segments[1].id, to: "Ansage")
        edit.setDeleted(true, for: edit.segments[1].id)
        check(edit.segments[1].deleted && edit.segments[1].track == 1, "a deleted part keeps its track")
        equal(edit.deletedCount, 1, "one part deleted")
        equal(edit.ranges(onTrack: 1), [0..<250, 500..<750], "a deleted part is not on its track")
        equal(edit.segments(onTrack: 1).count, 2, "track 1 lists only the kept parts")
        equal(edit.length(onTrack: 1), 500, "length of track 1 without the deleted part")
        equal(edit.keptRanges, [0..<250, 500..<1000], "playback of all tracks skips the deleted part")
        equal(AppModel.previewRanges(around: 250, in: edit.keptRanges, span: 100), [150..<250, 500..<600],
              "the transition preview jumps over the deleted part")

        var split = edit
        split.cut(at: 400, minimumLength: 10)
        check(split.segments[1].deleted && split.segments[2].deleted, "both halves of a deleted part stay deleted")

        var joinedLeft = edit
        joinedLeft.removeCut(0)
        check(!joinedLeft.segments[0].deleted, "joining a kept part with a deleted one keeps it")
        var joinedRight = edit
        joinedRight.removeCut(1)
        check(!joinedRight.segments[1].deleted && joinedRight.segments[1].track == 1, "a deleted part on the left takes the kept part's state")
        equal(joinedRight.segments[1].name, "Ansage", "the name survives the join")
        var both = edit
        both.setDeleted(true, for: both.segments[2].id)
        both.removeCut(1)
        check(both.segments[1].deleted, "two deleted parts join into a deleted one")

        var restored = edit
        restored.setTrack(3, for: restored.segments[1].id)
        check(!restored.segments[1].deleted && restored.segments[1].track == 3, "choosing a track restores a deleted part")
        restored.setDeleted(false, for: restored.segments[1].id)
        equal(restored.deletedCount, 0, "restoring twice changes nothing")

        var single = EditList(length: 1000)
        single.setDeleted(true, for: single.segments[0].id)
        check(single.hasEdits, "a deleted part is an edit")
        equal(single.keptRanges, [], "everything deleted: nothing to play")

        if let data = try? JSONEncoder().encode(edit.segments),
           let decoded = try? JSONDecoder().decode([Segment].self, from: data) {
            equal(EditList(length: 1000, segments: decoded), edit, "deleted parts are stored and restored")
        } else {
            check(false, "deleted parts can be encoded")
        }
        let old = Data(#"[{"start":0,"end":1000,"track":2}]"#.utf8)
        let decoded = (try? JSONDecoder().decode([Segment].self, from: old)) ?? []
        check(decoded.count == 1 && !decoded[0].deleted, "older stored parts are not deleted")
    }

    static func editList() {
        var edit = EditList(length: 1000)
        equal(edit.segments.count, 1, "new edit has one segment")
        check(!edit.hasEdits, "new edit has no edits")
        check(edit.cut(at: 400, minimumLength: 100), "cut at 400")
        check(!edit.cut(at: 450, minimumLength: 100), "cut too close to the last one is refused")
        check(!edit.cut(at: 50, minimumLength: 100), "cut too close to the start is refused")
        check(edit.cut(at: 700, minimumLength: 100), "cut at 700")
        equal(edit.cuts, [400, 700], "cut positions")
        equal(edit.index(at: 0), 0, "frame 0 is in the first segment")
        equal(edit.index(at: 399), 0, "frame 399 is in the first segment")
        equal(edit.index(at: 400), 1, "frame 400 starts the second segment")
        equal(edit.index(at: 1000), 2, "the end belongs to the last segment")

        equal(edit.segments.map(\.track), [1, 1, 1], "new parts stay on track 1")
        edit.setTrack(2, for: edit.segments[1].id)
        equal(edit.ranges(onTrack: 1), [0..<400, 700..<1000], "track 1 skips the part on track 2")
        equal(edit.ranges(onTrack: 2), [400..<700], "track 2 has only its part")
        equal(edit.ranges(onTrack: 3), [], "track 3 is empty")
        equal(edit.length(onTrack: 1), 700, "length of track 1")
        check(edit.hasEdits, "a part on another track is an edit")
        edit.setTrack(4, for: edit.segments[0].id)
        equal(edit.segments[0].track, 1, "there are only three tracks")

        var joined = EditList(length: 1000)
        joined.cut(at: 500, minimumLength: 10)
        equal(joined.ranges(onTrack: 1), [0..<1000], "neighbouring parts on one track form one range")

        edit.rename(edit.segments[2].id, to: "Outro")
        edit.moveCut(0, to: 10, minimumLength: 100)
        equal(edit.cuts[0], 100, "moving a cut stops at the minimum length (left)")
        edit.moveCut(0, to: 900, minimumLength: 100)
        equal(edit.cuts[0], 600, "moving a cut stops at the minimum length (right)")
        edit.removeCut(1)
        equal(edit.segments.count, 2, "removing a cut joins two parts")
        equal(edit.segments[1].track, 2, "joined part stays on the left track")
        equal(edit.segments[1].name, "Outro", "joined part takes the right name if the left one is empty")
        equal(edit.segments[1].end, 1000, "joined part reaches the end")

        let gap = [Segment(start: 0, end: 400), Segment(start: 500, end: 1000)]
        equal(EditList(length: 1000, segments: gap).segments.count, 1, "stored segments with a gap are dropped")
        let wrongLength = [Segment(start: 0, end: 400), Segment(start: 400, end: 900)]
        equal(EditList(length: 1000, segments: wrongLength).segments.count, 1, "stored segments of another length are dropped")
        let badTrack = [Segment(start: 0, end: 400, track: 7), Segment(start: 400, end: 1000)]
        equal(EditList(length: 1000, segments: badTrack).segments.count, 1, "stored segments on unknown tracks are dropped")
        let valid = [Segment(start: 0, end: 400, track: 3), Segment(start: 400, end: 1000)]
        equal(EditList(length: 1000, segments: valid).segments, valid, "valid stored segments are restored")
        let absurdFades = [Segment(start: 0, end: 1000, fadeIn: .max, fadeOut: 1)]
        equal(EditList(length: 1000, segments: absurdFades).segments[0].fadeIn, 0, "stored absurd fades are dropped, not overflowed")

        var several = EditList(length: 1000)
        equal(several.cut(at: [700, 300, 310, 950], minimumLength: 100), 2, "several cuts at once skip those too close")
        equal(several.cuts, [300, 700], "several cuts in order")
        equal(several.cutIndex(nearest: 650), 1, "nearest cut")
        equal(EditList(length: 1000).cutIndex(nearest: 5), nil, "no cut, no nearest cut")
        let longer = several.extended(to: 1500)
        equal(longer.length, 1500, "extended edit has the new length")
        equal(longer.cuts, [300, 700], "extended edit keeps its cuts")
        equal(longer.segments.last?.end, 1500, "the last part grows over appended files")

        equal(RecentFiles.adding(["/b"], to: [["/a"], ["/b"]]), [["/b"], ["/a"]], "reopened recording moves to the top")
        let many = (0..<20).map { ["/\($0)"] }
        equal(RecentFiles.adding(["/x"], to: many).count, RecentFiles.limit, "recent list is limited")
        equal(RecentFiles.name(["/a/Teil 1.wav", "/a/Teil 2.wav", "/a/Teil 3.wav"]), "Teil 1.wav + 2 weitere", "name of a joined recording")
        equal(AppModel.sortedByName([URL(fileURLWithPath: "/R10.wav"), URL(fileURLWithPath: "/R2.wav")]).map(\.lastPathComponent),
              ["R2.wav", "R10.wav"], "files are joined in natural name order")
    }

    static func fades() {
        var edit = EditList(length: 1000)
        edit.setFade(.fadeIn, of: 0, to: 100)
        edit.setFade(.fadeOut, of: 0, to: 200)
        check(edit.hasEdits, "a fade is an edit")
        edit.setFade(.fadeIn, of: 0, to: 5000)
        equal(edit.segments[0].fadeIn, 800, "fade-in stops where the fade-out begins")
        edit.setFade(.fadeIn, of: 0, to: -5)
        equal(edit.segments[0].fadeIn, 0, "no negative fades")
        edit.setFade(.fadeIn, of: 0, to: 100)
        edit.cut(at: 500, minimumLength: 10)
        equal([edit.segments[0].fadeIn, edit.segments[0].fadeOut], [100, 0], "left half keeps the fade-in")
        equal([edit.segments[1].fadeIn, edit.segments[1].fadeOut], [0, 200], "right half keeps the fade-out")
        edit.moveCut(0, to: 50, minimumLength: 10)
        equal(edit.segments[0].fadeIn, 50, "a shorter part shortens its fade")
        edit.removeCut(0)
        equal([edit.segments[0].fadeIn, edit.segments[0].fadeOut], [50, 200], "joining keeps the outer fades")

        let range: Range<Int64> = 0..<1000
        equal(Fade.gain(at: 0, range: range, fadeIn: 100, fadeOut: 0), 0, "fade-in starts silent")
        near(Double(Fade.gain(at: 50, range: range, fadeIn: 100, fadeOut: 0)), 0.5, 0.001, "half way is half")
        equal(Fade.gain(at: 100, range: range, fadeIn: 100, fadeOut: 0), 1, "full volume after the fade-in")
        check(Fade.gain(at: 999, range: range, fadeIn: 0, fadeOut: 100) < 0.001, "fade-out ends silent")
        equal(Fade.gain(at: 899, range: range, fadeIn: 0, fadeOut: 100), 1, "full volume before the fade-out")

        // Pieces: own fades kept, short fades only where the audio jumps.
        let parts = [Segment(start: 0, end: 1000, fadeIn: 300), Segment(start: 1000, end: 2000),
                     Segment(start: 5000, end: 6000, fadeOut: 10)]
        let pieces = Exporter.pieces(for: parts, sourceLength: 6000, sampleRate: 10_000) // 6 ms = 60 frames
        equal(pieces.map(\.fadeIn), [300, 0, 60], "fade-ins: own, none at a seamless join, short after a jump")
        equal(pieces.map(\.fadeOut), [0, 60, 10], "fade-outs: none at a seamless join, short before a jump, own at the end of the file")

        let old = Data(#"{"start":0,"end":10}"#.utf8)
        let decoded = try? JSONDecoder().decode(Segment.self, from: old)
        equal(decoded?.track, 1, "older stored parts land on track 1")
        equal(decoded?.fadeIn, 0, "older stored parts have no fades")
    }

    static func formatting() {
        equal(TimeFormat.string(1.15), "0:01.15", "no rounding error at 1.15 s")
        equal(TimeFormat.string(3723.5), "1:02:03.50", "hours")
        equal(TimeFormat.string(5, forceHours: true), "0:00:05.00", "forced hours")
        equal(TimeFormat.string(59.99, decimals: 0), "0:59", "whole seconds are cut, not rounded")
        equal(FileNames.sanitize("Intro/Teil: 1"), "Intro-Teil- 1", "no path separators in file names")
        equal(FileNames.sanitize("  ..versteckt  "), "versteckt", "no hidden file names")
        equal(FileNames.sanitize(String(repeating: "x", count: 300)).count, 120, "long names are shortened")
        for wide in [String(repeating: "音", count: 150), String(repeating: "👩‍👩‍👧", count: 50), String(repeating: "\u{E4}", count: 150)] {
            let name = FileNames.sanitize(wide)
            check(!name.isEmpty && name.decomposedStringWithCanonicalMapping.utf8.count <= 200,
                  "long names in wide characters fit into a file name", "\(name.utf8.count) bytes")
        }

        equal(Player.pieces(of: 0..<10, maximum: 4), [0..<4, 4..<8, 8..<10], "playback ranges in schedulable pieces")
        equal(Player.pieces(of: 5..<5), [], "an empty range has no pieces")
        equal(Player.pieces(of: 0..<(Int64(UInt32.max) + 10)).map(\.count), [Int(UInt32.max), 10],
              "more than 2^32 frames are scheduled in two pieces")
    }

    // MARK: ID3

    static func id3() {
        equal([UInt8](ID3Tag.syncsafe(200)), [0, 0, 1, 0x48], "syncsafe 200")
        equal([UInt8](ID3Tag.syncsafe(0x0FFF_FFFF)), [0x7F, 0x7F, 0x7F, 0x7F], "syncsafe maximum")
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
        let tag = ID3Tag(title: "Grüße", artist: "Ärzte", album: nil, track: 2, trackCount: 5, artwork: jpeg).data()
        equal([UInt8](tag.prefix(6)), [0x49, 0x44, 0x33, 3, 0, 0], "ID3v2.3 header")
        let size = tag[6...9].reduce(0) { $0 << 7 | Int($1) }
        equal(size, tag.count - 10, "tag size matches")
        check(tag.range(of: Data("TIT2".utf8)) != nil, "title frame")
        check(tag.range(of: Data("TALB".utf8)) == nil, "no frame for a missing album")
        check(tag.range(of: "Grüße".data(using: .utf16LittleEndian)!) != nil, "title as UTF-16")
        check(tag.range(of: "2/5".data(using: .utf16LittleEndian)!) != nil, "track number with count")
        check(tag.range(of: Data("image/jpeg".utf8)) != nil, "cover as JPEG")
        check(ID3Tag(artwork: Data([1, 2, 3])).data().range(of: Data("APIC".utf8)) == nil, "unknown image data is left out")

        // Chapters: a table of contents and one CHAP frame per part with its times in ms.
        let chapters = ID3Tag.chapters(titles: ["Eins", "Zwei"], lengths: [3_969_000, 1_323_000], sampleRate: 44_100)
        equal(chapters.map { $0.start }, [0, 90_000], "chapter starts in ms")
        equal(chapters.map { $0.end }, [90_000, 120_000], "chapter ends in ms")
        let chaptered = ID3Tag(title: "Set", chapters: chapters).data()
        equal(chaptered[6...9].reduce(0) { $0 << 7 | Int($1) }, chaptered.count - 10, "tag size with chapters")
        if let toc = chaptered.range(of: Data("CTOC".utf8)) {
            let body = chaptered[(toc.upperBound + 6)...]
            equal([UInt8](body.prefix(6)), [0x74, 0x6F, 0x63, 0, 0x03, 2], "table of contents: id, top level + ordered, two entries")
        } else {
            check(false, "table of contents frame")
        }
        var chapterStarts: [UInt32] = []
        var search = chaptered.startIndex
        while let frame = chaptered.range(of: Data("CHAP".utf8), in: search..<chaptered.endIndex) {
            let body = frame.upperBound + 6
            let idEnd = chaptered[body...].firstIndex(of: 0) ?? body
            chapterStarts.append(chaptered[(idEnd + 1)..<(idEnd + 5)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            search = frame.upperBound
        }
        equal(chapterStarts, [0, 90_000], "CHAP frames carry the start times")
        check(chaptered.range(of: "Zwei".data(using: .utf16LittleEndian)!) != nil, "chapter titles inside")
        let tooMany = ID3Tag(chapters: Array(repeating: ID3Tag.Chapter(title: "x", start: 0, end: 1), count: 300)).data()
        check(tooMany.range(of: Data([0x74, 0x6F, 0x63, 0, 0x03, 255])) != nil, "at most 255 chapters")
    }

    // MARK: Cue sheets

    static func cueSheets() {
        let text = """
        \u{FEFF}REM GENRE Electronic
        PERFORMER "DJ Test"
        TITLE "Live im Club"
        FILE "Set 2024.wav" WAVE
          TRACK 01 AUDIO
            TITLE "Intro"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "Größer "als" gedacht"
            PERFORMER "Gast"
            INDEX 00 03:59:00
            INDEX 01 04:00:37
          TRACK 03 AUDIO
            TITLE Ohne
            PERFORMER "DJ Test"
            INDEX 01 125:30:00
        """
        let sheet = CueSheet.parse(text)
        equal(sheet.performer, "DJ Test", "cue performer")
        equal(sheet.title, "Live im Club", "cue title")
        equal(sheet.files, ["Set 2024.wav"], "cue file name with spaces")
        equal(sheet.tracks.map(\.title), ["Intro", "Größer \"als\" gedacht", "Ohne"], "cue track titles")
        near(sheet.tracks[1].start, 240 + 37.0 / 75, 0.0001, "INDEX 01 wins over INDEX 00")
        near(sheet.tracks[2].start, 125 * 60 + 30, 0.0001, "minutes above 99")
        equal(sheet.tracks.map { sheet.name(of: $0) }, ["Intro", "Gast – Größer \"als\" gedacht", "Ohne"],
              "the track's own performer goes into the name")
        equal(CueSheet.timestamp(240 + 37.0 / 75), "04:00:37", "cue timestamp")
        equal(CueSheet.seconds("04:61:00"), nil, "invalid timestamp")

        let document = AudioDocument(url: URL(fileURLWithPath: "/tmp/Set 2024.wav"), length: 44_100 * 60 * 130, sampleRate: 44_100,
                                     channels: 2, fileSize: 1)
        if let edit = sheet.edit(for: document, minimumLength: 4410) {
            equal(edit.cuts, [document.frame(240 + 37.0 / 75), document.frame(125 * 60 + 30)], "cuts at the track starts")
            equal(edit.segments.map(\.name), ["Intro", "Gast – Größer \"als\" gedacht", "Ohne"], "parts named after the tracks")
        } else {
            check(false, "cue sheet becomes an edit")
        }

        let written = CueSheet.text(file: "Spur 1.mp3", title: "Album", performer: "Band",
                                    tracks: [("Eins", 0), ("Zwei \"2\"", 61.5)])
        let back = CueSheet.parse(written)
        equal(back.files, ["Spur 1.mp3"], "written cue names the MP3")
        equal(back.tracks.map(\.title), ["Eins", "Zwei '2'"], "written titles, quotes replaced")
        near(back.tracks[1].start, 61.5, 0.014, "written start time")
        check(written.contains("FILE \"Spur 1.mp3\" MP3"), "FILE line for an MP3")

        // Several FILE entries map to the files of a joined recording by name.
        let joined = AudioDocument(files: [
            .init(url: URL(fileURLWithPath: "/r/A.wav"), start: 0, length: 441_000, size: 1),
            .init(url: URL(fileURLWithPath: "/r/B.wav"), start: 441_000, length: 441_000, size: 1),
        ], sampleRate: 44_100, channels: 2)
        let multi = CueSheet.parse("""
        FILE "A.flac" WAVE
          TRACK 01 AUDIO
            TITLE "Eins"
            INDEX 01 00:00:00
        FILE "B.flac" WAVE
          TRACK 02 AUDIO
            TITLE "Zwei"
            INDEX 01 00:02:00
        """)
        equal(multi.edit(for: joined, minimumLength: 100)?.cuts, [529_200], "times of the second FILE count from its file")

        // Untrusted sheets: absurd or negative times are refused instead of overflowing into a crash.
        equal(CueSheet.seconds("200000000000000000:00:00"), nil, "absurd minutes are refused")
        equal(CueSheet.seconds("4000000000000:00:00"), nil, "minutes beyond any recording are refused")
        equal(CueSheet.seconds("-5:00:00"), nil, "negative minutes are refused")
        equal(CueSheet.seconds("00:-1:-2"), nil, "negative seconds and frames are refused")
        let absurd = CueSheet.parse("FILE \"a.wav\" WAVE\n  TRACK 01 AUDIO\n    INDEX 01 4000000000000:00:00\n  TRACK 02 AUDIO\n    INDEX 01 00:10:00\n")
        equal(absurd.edit(for: document, minimumLength: 4410)?.cuts, [441_000], "a sheet with an absurd time still loads")
        let multiline = CueSheet.text(file: "a.mp3", title: "Erste\nZweite", performer: nil, tracks: [("Eins\r\nZwei", 0)])
        let reread = CueSheet.parse(multiline)
        check(reread.tracks.count == 1 && !reread.tracks[0].title.contains("\n") && reread.title?.contains("Zweite") == true,
              "line breaks in names do not break the written sheet", multiline)
    }

    /// Cue sheets from disk: UTF-16 with BOM, and files far too big to be one.
    static func cueFiles(_ root: URL) {
        let text = "PERFORMER \"Künstler\"\r\nFILE \"Set.wav\" WAVE\r\n  TRACK 01 AUDIO\r\n    TITLE \"Grüße\"\r\n    INDEX 01 00:00:00\r\n"
        let utf16 = root.appendingPathComponent("unicode.cue")
        try? (Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!).write(to: utf16)
        let sheet = try? CueSheet.read(utf16)
        equal(sheet?.files, ["Set.wav"], "UTF-16 cue sheet: file")
        equal(sheet?.tracks.map(\.title), ["Grüße"], "UTF-16 cue sheet: titles with umlauts")
        equal(sheet?.performer, "Künstler", "UTF-16 cue sheet: performer")
        let big = root.appendingPathComponent("riesig.cue")
        try? Data(count: CueSheet.maximumSize + 1).write(to: big)
        check((try? CueSheet.read(big)) == nil, "a file far too big for a cue sheet is not read")
    }

    // MARK: Pauses

    static func pauses() {
        // Blocks of 256 frames: loud, a quiet stretch, loud, silence at the end.
        func blocks(_ value: Float, _ count: Int) -> [Float] { Array(repeating: value, count: count) }
        let maximum = blocks(0.5, 100) + blocks(0.001, 100) + blocks(0.5, 100) + blocks(0, 50)
        let peaks = Peaks(length: Int64(maximum.count * 256), minimum: maximum.map { -$0 }, maximum: maximum)
        let found = PauseFinder.pauses(in: peaks, thresholdDB: -40, minimumFrames: 50 * 256)
        // The level is averaged over 8 blocks on each side, so the loud neighbours trim the edges.
        equal(found, [27_648..<49_152], "one pause; silence at the end does not count")
        equal(PauseFinder.pauses(in: peaks, thresholdDB: -70, minimumFrames: 50 * 256), [], "a lower threshold finds nothing")
        equal(PauseFinder.pauses(in: peaks, thresholdDB: -40, minimumFrames: 200 * 256), [], "too short for the minimum length")
        equal(PauseFinder.cuts(for: found, existing: []), [38_400], "cut in the middle of the pause")
        equal(PauseFinder.cuts(for: found, existing: [30_000]), [], "no second cut in a pause that has one")
        // Room noise: peaks at −34 dB, but an RMS around −45 dB is a pause.
        let noise = blocks(0.5, 100) + blocks(0.02, 100) + blocks(0.5, 100)
        let noisy = Peaks(length: Int64(noise.count * 256), minimum: noise.map { -$0 }, maximum: noise,
                          rms: noise.map { $0 == 0.02 ? 0.0056 : 0.35 })
        equal(PauseFinder.pauses(in: noisy, thresholdDB: -40, minimumFrames: 50 * 256).count, 1, "noise with single peaks is a pause")
        // A clap in the middle: two quiet halves, joined when the gap is bridged.
        var clap = maximum
        clap[150] = 0.4
        let clapped = Peaks(length: Int64(clap.count * 256), minimum: clap.map { -$0 }, maximum: clap)
        equal(PauseFinder.pauses(in: clapped, thresholdDB: -40, minimumFrames: 50 * 256), [], "a clap splits a pause …")
        equal(PauseFinder.pauses(in: clapped, thresholdDB: -40, minimumFrames: 50 * 256, bridgeFrames: 30 * 256), [27_648..<49_152],
              "… unless short loud bits are bridged")
        let leading = blocks(0, 80) + blocks(0.5, 100)
        equal(PauseFinder.pauses(in: Peaks(length: Int64(leading.count * 256), minimum: leading.map { -$0 }, maximum: leading),
                                 thresholdDB: -40, minimumFrames: 256), [], "silence at the start does not count")
    }

    static func preview() {
        let whole: [Range<Int64>] = [0..<1000]
        equal(AppModel.previewRanges(around: 500, in: whole, span: 100), [400..<600], "preview around a cut in one range")
        equal(AppModel.previewRanges(around: 50, in: whole, span: 100), [0..<150], "preview near the start")
        // A track with a gap: the join across the gap is what the export does.
        let track: [Range<Int64>] = [0..<300, 700..<1000]
        equal(AppModel.previewRanges(around: 300, in: track, span: 100), [200..<300, 700..<800], "preview across a gap")
        equal(AppModel.previewRanges(around: 500, in: track, span: 100), [200..<300, 700..<800], "cut inside the gap")
        equal(AppModel.previewRanges(around: 720, in: [0..<10, 700..<1000], span: 100), [0..<10, 700..<820],
              "short ranges before the cut are taken whole")
    }

    // MARK: Loudness

    static func loudness() {
        func measure(rate: Double, seconds: Double, channels: Int = 2, _ sample: (Double) -> Float) -> LoudnessMeter {
            let meter = LoudnessMeter(sampleRate: rate, channels: channels)
            let total = Int(rate * seconds)
            let chunk = 10_000
            let buffers = (0..<channels).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: chunk) }
            defer { buffers.forEach { $0.deallocate() } }
            var position = 0
            while position < total {
                let count = min(chunk, total - position)
                for i in 0..<count {
                    let value = sample(Double(position + i) / rate)
                    for channel in 0..<channels { buffers[channel][i] = value }
                }
                buffers.withUnsafeBufferPointer { meter.add($0.baseAddress!, count: count) }
                position += count
            }
            return meter
        }
        // A 1 kHz sine with peak A on both channels reads 20·log10(A) LUFS.
        let sine = measure(rate: 44_100, seconds: 10) { 0.1 * Float(sin(2 * .pi * 1000 * $0)) }
        near(sine.integrated ?? 0, -20, 0.1, "1 kHz at −20 dBFS is −20 LUFS (44.1 kHz)")
        near(Double(sine.peak), 0.1, 0.001, "sample peak")
        let sine48 = measure(rate: 48_000, seconds: 10) { 0.1 * Float(sin(2 * .pi * 1000 * $0)) }
        near(sine48.integrated ?? 0, -20, 0.1, "1 kHz at −20 dBFS is −20 LUFS (48 kHz)")
        let gated = measure(rate: 44_100, seconds: 20) { $0 < 10 ? 0.1 * Float(sin(2 * .pi * 1000 * $0)) : 0 }
        near(gated.integrated ?? 0, -20, 0.2, "silence is gated out")
        let silent = measure(rate: 44_100, seconds: 2) { _ in 0 }
        equal(silent.integrated, nil, "silence has no loudness")
        equal(silent.gain(), 1, "silence is left alone")
        near(Double(sine.gain()), pow(10, 6.0 / 20), 0.02, "−20 LUFS is raised by 6 dB")
        // Raising stops 1 dB below full scale.
        let peaky = measure(rate: 44_100, seconds: 10) { t in t > 5 && t < 5.0001 ? 0.5 : 0.05 * Float(sin(2 * .pi * 1000 * t)) }
        near(Double(peaky.gain()), pow(10, -1.0 / 20) / 0.5, 0.01, "raising is limited by the peak")
        let clipping = measure(rate: 44_100, seconds: 10) { t in t > 5 && t < 5.0001 ? 0.95 : 0.05 * Float(sin(2 * .pi * 1000 * t)) }
        equal(clipping.gain(), 1, "quiet audio with a peak near full scale is not made quieter")
        let loud = measure(rate: 44_100, seconds: 10) { 0.8 * Float(sin(2 * .pi * 1000 * $0)) }
        check(loud.gain() < 0.3, "loud audio is lowered", "\(loud.gain())")
        let low = LoudnessMeter.coefficients(sampleRate: 48_000)
        near(low[0], 1.53512485958697, 0.000001, "K-weighting shelf b0 at 48 kHz (BS.1770 table)")
        near(low[3], -1.69065929318241, 0.000001, "K-weighting shelf a1 at 48 kHz")
        near(low[8], -1.99004745483398, 0.000001, "K-weighting high pass a1 at 48 kHz")
    }

    // MARK: Test audio

    /// Writes a 16-bit PCM file; `sample(seconds, channel)` gives the value.
    static func writeAudio(_ url: URL, sampleRate: Double, channels: Int = 2, layout: AudioChannelLayoutTag? = nil,
                           seconds: Double, _ sample: (Double, Int) -> Float) {
        let format = layout.map { AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: AVAudioChannelLayout(layoutTag: $0)!) }
            ?? AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels))!
        var settings = format.settings
        settings[AVFormatIDKey] = kAudioFormatLinearPCM
        settings[AVLinearPCMBitDepthKey] = 16
        settings[AVLinearPCMIsFloatKey] = false
        settings[AVLinearPCMIsBigEndianKey] = false
        settings[AVLinearPCMIsNonInterleaved] = false
        let file = try! AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let total = Int(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32_768)!
        var position = 0
        while position < total {
            let count = min(32_768, total - position)
            for channel in 0..<Int(file.processingFormat.channelCount) {
                for i in 0..<count { buffer.floatChannelData![channel][i] = sample(Double(position + i) / sampleRate, channel) }
            }
            buffer.frameLength = AVAudioFrameCount(count)
            try! file.write(from: buffer)
            position += count
        }
    }

    static func sine(_ frequency: Double, _ amplitude: Float, _ seconds: Double) -> Float {
        amplitude * Float(sin(2 * .pi * frequency * seconds))
    }

    /// RMS of the first channel between two times.
    static func rms(_ url: URL, from: Double, to: Double) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return -1 }
        let rate = file.processingFormat.sampleRate
        var sum = 0.0, count = 0
        try? AudioLoader.decode(url, from: Int64(from * rate), to: Int64(to * rate), token: CancelToken()) { buffer, _ in
            let samples = buffer.floatChannelData![0]
            for i in 0..<Int(buffer.frameLength) {
                sum += Double(samples[i] * samples[i])
                count += 1
            }
        }
        return count == 0 ? 0 : (sum / Double(count)).squareRoot()
    }

    static func tags(_ url: URL) -> SourceTags {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result = SourceTags()
        Task.detached {
            result = await AudioLoader.tags(for: url)
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    // MARK: Peaks

    static func peaks(_ root: URL) {
        // 70 s, so that the file is decoded in parallel chunks: loud first half, quiet second half.
        let url = root.appendingPathComponent("long.wav")
        writeAudio(url, sampleRate: 8000, channels: 1, seconds: 70) { t, _ in sine(200, t < 35 ? 0.8 : 0.2, t) }
        guard let document = try? AudioLoader.open(url) else { return check(false, "open long.wav") }
        equal(document.length, 560_000, "length of long.wav")
        let progress = ProgressCounter()
        guard let peaks = try? AudioLoader.peaks(for: document, token: CancelToken(), progress: { _ in _ = progress.add(1) }) else {
            return check(false, "peaks of long.wav")
        }
        let base = peaks.levels[0]
        equal(base.maximum.count, (560_000 + 255) / 256, "one block per 256 frames")
        let loud = base.maximum[0..<Int(34 * 8000 / 256)]
        let quiet = base.maximum[Int(36 * 8000 / 256)...]
        check(loud.allSatisfy { $0 > 0.7 && $0 < 0.85 }, "every block of the loud half is filled", "\(loud.min() ?? 0)")
        check(quiet.allSatisfy { $0 > 0.15 && $0 < 0.25 }, "every block of the quiet half is filled", "\(quiet.min() ?? 0)")
        near(Double(peaks.peak), 0.8, 0.05, "overall peak")
        check(peaks.levels.count > 1, "coarser levels exist")
        if let top = peaks.levels.last {
            near(Double(top.maximum.max() ?? 0), Double(peaks.peak), 0.0001, "coarse level keeps the peak")
        }
        check(progress.total > 0, "progress is reported")
        let level = peaks.level(forFramesPerPoint: 5000)
        check(peaks.levels[level].block <= 5000, "chosen level is not coarser than a point")

        let token = CancelToken()
        token.cancel()
        check((try? AudioLoader.peaks(for: document, token: token, progress: { _ in })) == nil, "cancelled reading stops")
    }

    // MARK: Export

    static func export(_ root: URL) {
        // 24 s: 440 Hz loud, silence, 880 Hz quiet (8 s each).
        let source = root.appendingPathComponent("Quelle.wav")
        writeAudio(source, sampleRate: 44_100, seconds: 24) { t, _ in
            t < 8 ? sine(440, 0.5, t) : (t < 16 ? 0 : sine(880, 0.25, t))
        }
        guard let document = try? AudioLoader.open(source) else { return check(false, "open Quelle.wav") }
        let rate = 44_100.0

        // Joined: 0–4 s and 16–20 s, so the silence in between is gone.
        let joined = root.appendingPathComponent("geschnitten.mp3")
        let joinedParts = [Segment(start: 0, end: Int64(4 * rate)), Segment(start: Int64(16 * rate), end: Int64(20 * rate))]
        let job = ExportJob(pieces: Exporter.pieces(for: joinedParts, sourceLength: document.length, sampleRate: rate),
                            destination: joined, tag: ID3Tag(title: "Grüße – geschnitten", artist: "Test", album: "Album"))
        var reported: Int64 = 0
        do {
            try Exporter.export(job, source: source, token: CancelToken()) { reported += $0 }
        } catch {
            return check(false, "joined export", "\(error)")
        }
        equal(reported, Int64(8 * rate), "progress covers every frame")
        if let result = try? AVAudioFile(forReading: joined) {
            near(Double(result.length), 8 * rate, 1152, "joined length is 8 s")
            equal(result.processingFormat.sampleRate, 44_100, "sample rate kept")
            equal(result.processingFormat.channelCount, 2, "stereo kept")
        } else {
            check(false, "exported MP3 can be opened")
        }
        near(rms(joined, from: 0.5, to: 3.5), 0.5 / 2.squareRoot(), 0.05, "first part is the loud 440 Hz tone")
        near(rms(joined, from: 4.5, to: 7.5), 0.25 / 2.squareRoot(), 0.03, "second part is the quiet 880 Hz tone")
        let atJoin = rms(joined, from: 3.9985, to: 4.0015)
        check(atJoin < 0.1, "fade at the join", "\(atJoin)")

        if let data = try? Data(contentsOf: joined) {
            equal([UInt8](data.prefix(3)), [0x49, 0x44, 0x33], "starts with an ID3 tag")
            let tagSize = 10 + data[6...9].reduce(0) { $0 << 7 | Int($1) }
            let header = [UInt8](data[tagSize..<tagSize + 4])
            check(header[0] == 0xFF && header[1] & 0xFE == 0xFA, "MPEG-1 Layer III frame after the tag", "\(header)")
            equal(header[2] >> 4, 14, "320 kbit/s")
            check(data[tagSize..<min(data.count, tagSize + 200)].range(of: Data("Info".utf8)) != nil, "LAME tag in the first frame")
        }
        let read = tags(joined)
        equal(read.title, "Grüße – geschnitten", "title readable with umlauts")
        equal(read.artist, "Test", "artist readable")
        equal(read.album, "Album", "album readable")

        // Parts named by the table.
        var edit = EditList(length: document.length)
        edit.cut(at: Int64(8 * rate), minimumLength: 100)
        edit.cut(at: Int64(16 * rate), minimumLength: 100)
        edit.setTrack(3, for: edit.segments[1].id)
        edit.rename(edit.segments[0].id, to: "Grüße/Intro")
        let parts = AppModel.partJobs(edit.segments(onTrack: 1), document: document, tags: SourceTags(artist: "Band"), folder: root)
        equal(parts.map(\.destination.lastPathComponent), ["01 Grüße-Intro.mp3", "Quelle – Teil 02.mp3"], "part file names")
        equal(parts.map(\.tag.title), ["Grüße/Intro", "Quelle – Teil 02"], "part titles")
        equal(parts.map(\.tag.track), [1, 2], "track numbers")
        equal(parts[0].tag.album, "Quelle", "album falls back to the file name")
        for part in parts {
            do {
                try Exporter.export(part, source: source, token: CancelToken()) { _ in }
                let length = (try? AVAudioFile(forReading: part.destination).length) ?? 0
                near(Double(length), 8 * rate, 1152, "\(part.destination.lastPathComponent) is 8 s")
            } catch {
                check(false, "export \(part.destination.lastPathComponent)", "\(error)")
            }
        }
        // Fades of 1 s at both ends of the loud part (0–4 s).
        let faded = root.appendingPathComponent("geblendet.mp3")
        let fadedPart = Segment(start: 0, end: Int64(4 * rate), fadeIn: Int64(rate), fadeOut: Int64(rate))
        do {
            try Exporter.export(ExportJob(pieces: Exporter.pieces(for: [fadedPart], sourceLength: document.length, sampleRate: rate),
                                          destination: faded, tag: ID3Tag()), source: source, token: CancelToken()) { _ in }
            check(rms(faded, from: 0, to: 0.2) < 0.02, "fade-in starts quietly", "\(rms(faded, from: 0, to: 0.2))")
            near(rms(faded, from: 1.5, to: 2.5), 0.5 / 2.squareRoot(), 0.05, "full volume between the fades")
            check(rms(faded, from: 3.8, to: 4.0) < 0.02, "fade-out ends quietly", "\(rms(faded, from: 3.8, to: 4.0))")
            let middle = rms(faded, from: 0.45, to: 0.55)
            check(middle > 0.1 && middle < 0.25, "half way through the fade-in is about half as loud", "\(middle)")
        } catch {
            check(false, "export with fades", "\(error)")
        }

        let twins = [Segment(start: 0, end: 100, name: "Gleich"), Segment(start: 100, end: 200, name: "Gleich")]
        let twinNames = AppModel.partJobs(twins, document: document, tags: SourceTags(), folder: root).map(\.destination.lastPathComponent)
        equal(Set(twinNames).count, 2, "equal names get different files")

        // Refusals and cancelling leave nothing behind.
        let overwrite = ExportJob(pieces: [ExportPiece(range: 0..<1000)], destination: source, tag: ID3Tag())
        check((try? Exporter.export(overwrite, source: source, token: CancelToken()) { _ in }) == nil,
              "the source is never overwritten")
        let token = CancelToken()
        token.cancel()
        let cancelled = ExportJob(pieces: [ExportPiece(range: 0..<Int64(4 * rate))], destination: root.appendingPathComponent("abgebrochen.mp3"),
                                  tag: ID3Tag())
        check((try? Exporter.export(cancelled, source: source, token: token) { _ in }) == nil,
              "cancelled export throws")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: root.path))?.filter { $0.hasSuffix(".musichub") || $0 == "abgebrochen.mp3" } ?? []
        equal(leftovers, [], "no temporary or half-written files")

        // The source under another spelling (case-insensitive volume) or as a hard link is still the source.
        let link = root.appendingPathComponent("Verweis.mp3")
        try? FileManager.default.linkItem(at: source, to: link)
        check(document.contains(link), "a hard link to the source counts as the source")
        let sizeBefore = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int) ?? -1
        check((try? Exporter.export(ExportJob(pieces: [ExportPiece(range: 0..<1000)], destination: link, tag: ID3Tag()),
                                    source: document, token: CancelToken()) { _ in }) == nil, "exporting onto a hard link of the source is refused")
        let otherCase = root.appendingPathComponent("QUELLE.wav")
        if FileManager.default.fileExists(atPath: otherCase.path) {
            check(document.contains(otherCase), "the source spelled differently counts as the source (case-insensitive volume)")
        }
        check(FileManager.default.fileExists(atPath: source.path)
              && (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int) == sizeBefore, "the source is untouched")
        check(!document.contains(root.appendingPathComponent("geschnitten.mp3")), "another existing file is not the source")
        check(!document.contains(root.appendingPathComponent("gibt es nicht.mp3")), "a missing file is not the source")

        // Long names in wide characters: the hidden temporary file must still fit into a file name.
        let wide = root.appendingPathComponent(String(repeating: "\u{E4}", count: 120) + ".mp3")
        do {
            try Exporter.export(ExportJob(pieces: [ExportPiece(range: 0..<Int64(rate))], destination: wide, tag: ID3Tag()),
                                source: document, token: CancelToken()) { _ in }
            check(FileManager.default.fileExists(atPath: wide.path), "export under a 240-byte name")
        } catch {
            check(false, "export under a 240-byte name", "\(error)")
        }
        var cjk = EditList(length: document.length)
        cjk.rename(cjk.segments[0].id, to: String(repeating: "音", count: 120))
        let cjkJob = AppModel.partJobs(cjk.segments, document: document, tags: SourceTags(), folder: root)[0]
        do {
            try Exporter.export(ExportJob(pieces: [ExportPiece(range: 0..<Int64(rate))], destination: cjkJob.destination, tag: cjkJob.tag),
                                source: document, token: CancelToken()) { _ in }
            check(FileManager.default.fileExists(atPath: cjkJob.destination.path), "part named in 120 wide characters is exported")
        } catch {
            check(false, "part named in 120 wide characters is exported", "\(error)")
        }
    }

    /// Other channel counts and sample rates.
    static func formats(_ root: URL) {
        let mono = root.appendingPathComponent("mono.wav")
        writeAudio(mono, sampleRate: 48_000, channels: 1, seconds: 3) { t, _ in sine(300, 0.4, t) }
        exportWhole(mono) { result in
            equal(result.processingFormat.channelCount, 1, "mono stays mono")
            equal(result.processingFormat.sampleRate, 48_000, "48 kHz stays 48 kHz")
            near(Double(result.length), 3 * 48_000, 1152, "mono length")
        }

        let low = root.appendingPathComponent("low.wav")
        writeAudio(low, sampleRate: 22_050, seconds: 3) { t, _ in sine(300, 0.4, t) }
        exportWhole(low) { result in
            equal(result.processingFormat.sampleRate, 44_100, "22.05 kHz is resampled to 44.1 kHz")
            near(Double(result.length) / 44_100, 3, 0.05, "resampled length")
        }

        let surround = root.appendingPathComponent("surround.caf")
        writeAudio(surround, sampleRate: 48_000, layout: kAudioChannelLayoutTag_MPEG_5_1_A, seconds: 3) { t, channel in
            channel == 2 ? sine(300, 0.4, t) : 0 // only the centre channel
        }
        exportWhole(surround) { result in
            equal(result.processingFormat.channelCount, 2, "5.1 is mixed down to stereo")
        }
        let surroundMP3 = root.appendingPathComponent("surround.mp3")
        check(rms(surroundMP3, from: 0.5, to: 2.5) > 0.05, "the centre channel is in the stereo mix")
    }

    /// Loudness is brought to −14 LUFS in the export; the cue sheet lands next to the MP3.
    static func normalizedExport(_ root: URL) {
        let source = root.appendingPathComponent("leise.wav")
        writeAudio(source, sampleRate: 44_100, seconds: 6) { t, _ in sine(1000, 0.05, t) } // −26 LUFS
        let destination = root.appendingPathComponent("laut.mp3")
        var job = ExportJob(pieces: [ExportPiece(range: 0..<Int64(6 * 44_100))], destination: destination, tag: ID3Tag(), normalize: true)
        job.cueSheet = CueSheet.text(file: "laut.mp3", title: nil, performer: nil, tracks: [("Eins", 0), ("Zwei", 3)])
        var reported: Int64 = 0
        do {
            try Exporter.export(job, source: source, token: CancelToken()) { reported += $0 }
            equal(reported, Int64(12 * 44_100), "progress counts the measuring pass")
            near(rms(destination, from: 1, to: 5), 0.2 / 2.squareRoot(), 0.01, "raised by 12 dB to −14 LUFS")
            let cue = (try? String(contentsOf: root.appendingPathComponent("laut.cue"), encoding: .utf8)) ?? ""
            check(cue.contains("FILE \"laut.mp3\" MP3") && cue.contains("INDEX 01 00:03:00"), "cue sheet next to the MP3", cue)
        } catch {
            check(false, "normalized export", "\(error)")
        }
        let plain = root.appendingPathComponent("unveraendert.mp3")
        do {
            try Exporter.export(ExportJob(pieces: [ExportPiece(range: 0..<Int64(6 * 44_100))], destination: plain, tag: ID3Tag()),
                                source: source, token: CancelToken()) { _ in }
            near(rms(plain, from: 1, to: 5), 0.05 / 2.squareRoot(), 0.005, "without the option the level stays")
        } catch {
            check(false, "plain export", "\(error)")
        }
    }

    /// Several files of the same format as one recording.
    static func joinedFiles(_ root: URL) {
        let first = root.appendingPathComponent("Teil 1.wav"), second = root.appendingPathComponent("Teil 2.wav")
        writeAudio(first, sampleRate: 44_100, seconds: 3) { t, _ in sine(440, 0.5, t) }
        writeAudio(second, sampleRate: 44_100, seconds: 2) { t, _ in sine(880, 0.25, t) }
        let other = root.appendingPathComponent("anders.wav")
        writeAudio(other, sampleRate: 48_000, seconds: 1) { t, _ in sine(440, 0.5, t) }
        check((try? AudioLoader.open([first, other])) == nil, "files of different formats are not joined")

        guard let document = try? AudioLoader.open([first, second]) else { return check(false, "open two files") }
        equal(document.length, 5 * 44_100, "joined length")
        equal(document.fileStarts, [132_300], "second file starts after the first")
        equal(document.displayName, "Teil 1.wav + 1 weitere", "joined name")
        equal(document.parts(of: 100_000..<200_000).map(\.local), [100_000..<132_300, 0..<67_700], "range split at the border")
        check(document.contains(second), "the second file is a source too")

        var positions: [Int64] = []
        var frames: Int64 = 0
        try? AudioLoader.decode(document, from: 120_000, to: 150_000, token: CancelToken(), chunkSize: 10_000) { buffer, position in
            positions.append(position)
            frames += Int64(buffer.frameLength)
        }
        equal(frames, 30_000, "decoding across the border reads every frame")
        check(positions.contains(132_300), "the second file continues at its position", "\(positions)")

        if let peaks = try? AudioLoader.peaks(for: document, token: CancelToken(), progress: { _ in }) {
            let base = peaks.levels[0].maximum
            check(base[10] > 0.45 && base[600] > 0.2 && base[600] < 0.3, "peaks of both files", "\(base[10]) \(base[600])")
        } else {
            check(false, "peaks of joined files")
        }

        // 2–4 s: the end of the first file and the start of the second.
        let destination = root.appendingPathComponent("verbunden.mp3")
        let job = ExportJob(pieces: [ExportPiece(range: Int64(2 * 44_100)..<Int64(4 * 44_100))], destination: destination, tag: ID3Tag())
        do {
            try Exporter.export(job, source: document, token: CancelToken()) { _ in }
            near(rms(destination, from: 0.2, to: 0.8), 0.5 / 2.squareRoot(), 0.05, "export across files: first file")
            near(rms(destination, from: 1.2, to: 1.8), 0.25 / 2.squareRoot(), 0.03, "export across files: second file")
        } catch {
            check(false, "export across files", "\(error)")
        }
        let overwrite = ExportJob(pieces: [ExportPiece(range: 0..<1000)], destination: second, tag: ID3Tag())
        check((try? Exporter.export(overwrite, source: document, token: CancelToken()) { _ in }) == nil,
              "no file of a joined recording is overwritten")
    }

    static func artwork(_ root: URL) {
        func image(_ width: Int, _ height: Int, _ type: NSBitmapImageRep.FileType) -> Data {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            return rep.representation(using: type, properties: [:])!
        }
        let png = image(300, 300, .png)
        equal(Artwork.prepare(png), png, "a small PNG goes in as it is")
        let tiff = image(200, 100, .tiff)
        if let converted = Artwork.prepare(tiff) {
            equal(ID3Tag.imageType(converted), "image/jpeg", "other formats become JPEG")
        } else {
            check(false, "TIFF can be converted")
        }
        if let big = Artwork.prepare(image(3000, 1500, .png)), let rep = NSBitmapImageRep(data: big) {
            equal([rep.pixelsWide, rep.pixelsHigh], [1400, 700], "big covers are scaled down")
        } else {
            check(false, "big cover can be converted")
        }
        check(Artwork.prepare(Data([1, 2, 3])) == nil, "no image, no cover")

        let source = SourceTags(title: "T", artist: "Quelle", album: "Album", artwork: png)
        equal(CustomTags().applied(to: source, artwork: nil), source, "no changes keep the source tags")
        let changed = CustomTags(artist: "Neu", album: "", cover: .none).applied(to: source, artwork: nil)
        equal([changed.artist, changed.album], ["Neu", nil], "changed artist, album left out")
        equal(changed.artwork, nil, "cover removed")
        equal(CustomTags(cover: .file("/x.png")).applied(to: source, artwork: tiff).artwork, tiff, "cover from a file")
    }

    static func exportWhole(_ url: URL, _ inspect: (AVAudioFile) -> Void) {
        guard let document = try? AudioLoader.open(url) else { return check(false, "open \(url.lastPathComponent)") }
        let destination = url.deletingPathExtension().appendingPathExtension("mp3")
        let job = ExportJob(pieces: [ExportPiece(range: 0..<document.length)], destination: destination, tag: ID3Tag())
        do {
            try Exporter.export(job, source: url, token: CancelToken()) { _ in }
            inspect(try AVAudioFile(forReading: destination))
        } catch {
            check(false, "export \(url.lastPathComponent)", "\(error)")
        }
    }

    // MARK: Stored edits

    static func editStore(_ root: URL) {
        let store = EditStore(directory: root.appendingPathComponent("support"))
        let document = AudioDocument(url: URL(fileURLWithPath: "/tmp/x.mp3"), length: 1000, sampleRate: 44_100, channels: 2, fileSize: 5000)
        check(store.load(for: document).edit == nil, "nothing stored yet")
        var edit = EditList(length: 1000)
        edit.cut(at: 300, minimumLength: 10)
        edit.setTrack(2, for: edit.segments[0].id)
        store.save(edit, for: document)
        equal(store.load(for: document).edit, edit, "edit comes back")
        let changed = AudioDocument(url: document.url, length: 1000, sampleRate: 44_100, channels: 2, fileSize: 6000)
        check(store.load(for: changed).edit == nil, "a changed file starts fresh")
        store.save(EditList(length: 1000), for: document)
        check(store.load(for: document).edit == nil, "an untouched edit is forgotten")

        let tags = CustomTags(artist: "Band", album: nil, cover: .file("/tmp/cover.jpg"))
        store.save(EditList(length: 1000), tags: tags, for: document)
        equal(store.load(for: document).tags, tags, "changed tags are kept without cuts")
        equal(store.load(for: document).edit, nil, "… and no edit comes back with them")

        let joined = AudioDocument(files: [
            .init(url: URL(fileURLWithPath: "/tmp/x.mp3"), start: 0, length: 1000, size: 5000),
            .init(url: URL(fileURLWithPath: "/tmp/y.mp3"), start: 1000, length: 500, size: 2000),
        ], sampleRate: 44_100, channels: 2)
        var joinedEdit = EditList(length: 1500)
        joinedEdit.cut(at: 1000, minimumLength: 10)
        store.save(joinedEdit, for: joined)
        equal(store.load(for: joined).edit, joinedEdit, "a joined recording has its own edit")
        equal(store.load(for: document).tags, tags, "… next to the one of its first file")

        let old = Data(#"{"/tmp/old.mp3":{"size":1,"length":1000,"saved":"2026-01-01T00:00:00Z","segments":[{"start":0,"end":500,"track":2},{"start":500,"end":1000}]}}"#.utf8)
        let oldStore = EditStore(directory: root.appendingPathComponent("old"))
        try? FileManager.default.createDirectory(at: oldStore.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? old.write(to: oldStore.url)
        let oldDocument = AudioDocument(url: URL(fileURLWithPath: "/tmp/old.mp3"), length: 1000, sampleRate: 44_100, channels: 2, fileSize: 1)
        equal(oldStore.load(for: oldDocument).edit?.cuts, [500], "edits stored by the first version still load")

        // One damaged entry must not take the others with it when the next edit is saved.
        let damaged = Data(#"{"/tmp/old.mp3":{"size":1,"length":1000,"saved":"2026-01-01T00:00:00Z","segments":[{"start":0,"end":500,"track":2},{"start":500,"end":1000}]},"/tmp/bad.mp3":{"size":"x"}}"#.utf8)
        let damagedStore = EditStore(directory: root.appendingPathComponent("damaged"))
        try? FileManager.default.createDirectory(at: damagedStore.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? damaged.write(to: damagedStore.url)
        equal(damagedStore.load(for: oldDocument).edit?.cuts, [500], "a damaged entry does not hide the others")
        damagedStore.save(edit, for: document)
        equal(damagedStore.load(for: oldDocument).edit?.cuts, [500], "… and they survive saving another recording")
        equal(damagedStore.load(for: document).edit, edit, "… next to the new one")

        // A file that cannot be read at all is put aside, not overwritten.
        let brokenFolder = root.appendingPathComponent("broken")
        let brokenStore = EditStore(directory: brokenFolder)
        try? FileManager.default.createDirectory(at: brokenFolder, withIntermediateDirectories: true)
        try? Data("{ kaputt".utf8).write(to: brokenStore.url)
        check(brokenStore.load(for: document).edit == nil, "an unreadable store restores nothing")
        brokenStore.save(edit, for: document)
        let aside = (try? FileManager.default.contentsOfDirectory(atPath: brokenFolder.path))?.filter { $0.hasPrefix("edits-unreadable-") } ?? []
        equal(aside.count, 1, "the unreadable store is kept aside")
        if let name = aside.first {
            equal(try? Data(contentsOf: brokenFolder.appendingPathComponent(name)), Data("{ kaputt".utf8), "… unchanged")
        }
        equal(brokenStore.load(for: document).edit, edit, "saving works again afterwards")
    }
}
