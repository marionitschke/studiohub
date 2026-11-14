// VideoHub checks (scripts/check.sh): edit list, detached and muted sound, opening videos, the
// composition, export without re-encoding (frame-accurate cuts between keyframes, moved parts, sound
// in sync or shifted, rotation, recording date and metadata, MP4 or MOV, ProRes only in MOV), sound
// export as M4A, WAV and MP3, waveform. Test videos are generated; works only in temporary folders.
import AppKit
import AVFoundation
import Foundation

@main
enum Checks {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passed = 0
    /// The video step running, for the message if one throws.
    nonisolated(unsafe) static var step = ""

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

    static func main() async {
        editList()
        trimming()
        sound()
        effects()
        exportFormat()
        formatting()
        let root = temp("video")
        // VIDEOHUB_KEEP=1 keeps the test files for a look with other tools.
        let keep = ProcessInfo.processInfo.environment["VIDEOHUB_KEEP"] == "1"
        do {
            try movieHeader(root)
            try await videos(root)
        } catch {
            check(false, "video checks ran through (last step: \(step))", "\(error)")
        }
        // Not in a defer: exit() below ends the program before a defer would run.
        if keep { print("Testdateien: \(root.path)") } else { try? FileManager.default.removeItem(at: root) }
        print("\(passed) Prüfungen bestanden, \(failures) fehlgeschlagen.")
        exit(failures == 0 ? 0 : 1)
    }

    static func temp(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("videohub-check-\(name)-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Sound

    static func sound() {
        func segment(_ position: Int64, _ source: Range<Int64>) -> SoundSegment { SoundSegment(position: position, source: source) }

        var single = EditList(bounds: 0..<1000)
        single.detachSound(0)
        check(single.hasEdits, "a detached sound is an edit")
        equal(single.soundSegments, [segment(0, 0..<1000)], "detaching alone changes nothing you hear")
        equal(SoundSegment.following([600..<700, 100..<200]), [segment(0, 600..<700), segment(100, 100..<200)],
              "the sound of parts follows their pictures")

        // Two parts, 0–300 and 300–1000; the sound of the first one 100 later.
        var edit = EditList(bounds: 0..<1000)
        edit.cut(at: 300, minimumLength: 50)
        equal(edit.soundSegments, [segment(0, 0..<1000)], "a cut does not interrupt the sound")
        edit.detachSound(0)
        edit.shiftSound(0, to: 100, minimumLength: 50)
        let shifted = [segment(100, 0..<300), segment(400, 400..<1000)]
        equal(edit.soundSegments, shifted, "a later sound leaves silence and replaces the start of the next part's sound")

        var split = edit
        split.cut(at: 150, minimumLength: 50)
        equal(split.soundSegments, shifted, "cutting under a shifted sound changes nothing you hear")
        split.join(0)
        equal(split.parts[0].sound, edit.parts[0].sound, "removing that cut joins the sound again")

        var early = edit
        early.cut(at: 60, minimumLength: 50)
        equal(early.parts[0].sound, .muted, "a cut before the shifted sound starts leaves the first half without sound")
        equal(early.soundSegments, shifted, "and nothing you hear changes")
        early.join(0)
        equal(early.parts[0].sound, edit.parts[0].sound, "removing that cut gives the sound back to the whole part")

        var moved = edit
        moved.move(0, before: 2)
        equal(moved.soundSegments, [segment(0, 300..<1000), segment(800, 0..<200)],
              "the sound moves with its part and stops at the end of the edit")

        var trimmedPicture = edit
        trimmedPicture.trim(0, .start, to: 100, minimumLength: 50)
        equal(trimmedPicture.soundSegments, [segment(0, 0..<300), segment(300, 400..<1000)],
              "a detached sound stays in sync with its picture when the picture is trimmed")
        var movedCut = edit
        movedCut.moveCut(0, to: 400, minimumLength: 50)
        equal(movedCut.soundSegments, shifted, "moving a cut leaves a detached sound where it is")

        var longer = edit
        longer.trimSound(0, .end, to: 450, minimumLength: 50)
        equal(longer.soundSegments, [segment(100, 0..<450), segment(550, 550..<1000)], "a longer sound replaces more of the next part")
        longer.trimSound(0, .start, to: -20, minimumLength: 50)
        equal(longer.parts[0].soundAsDetached?.start, 0, "a sound starts at the earliest at the start of the video")
        longer.trimSound(0, .end, to: 10, minimumLength: 50)
        equal(longer.parts[0].soundAsDetached?.range, 0..<50, "a sound keeps the minimum length")

        var far = edit
        far.shiftSound(0, to: 5000, minimumLength: 50)
        equal(far.soundSegments, [segment(300, 300..<950), segment(950, 0..<50)], "a sound shifted far keeps a little in the edit (end)")
        far.shiftSound(0, to: -5000, minimumLength: 50)
        equal(far.soundSegments, [segment(0, 250..<300), segment(300, 300..<1000)], "a sound shifted far keeps a little in the edit (start)")

        var muted = EditList(bounds: 0..<1000)
        muted.cut(at: 300, minimumLength: 50)
        muted.cut(at: 600, minimumLength: 50)
        muted.setMuted(1, true)
        equal(muted.soundSegments, [segment(0, 0..<300), segment(600, 600..<1000)], "a muted part is silent")
        muted.join(0)
        equal(muted.soundSegments, [segment(0, 0..<1000)], "removing the cut next to a muted part brings its sound back")

        var both = EditList(bounds: 0..<1000)
        both.cut(at: 500, minimumLength: 50)
        both.detachSound(0)
        both.shiftSound(0, to: 100, minimumLength: 50)
        both.detachSound(1)
        both.shiftSound(1, to: -100, minimumLength: 50)
        equal(both.soundSegments, [segment(100, 0..<300), segment(400, 500..<1000)],
              "where two detached sounds overlap, the one changed last is heard")
        both.shiftSound(0, to: 100, minimumLength: 50)
        equal(both.soundSegments, [segment(100, 0..<500), segment(600, 700..<1000)], "changing the other one brings it to the top")
        both.attachSound(0)
        both.attachSound(1)
        equal(both.soundSegments, [segment(0, 0..<1000)], "attached sounds follow the pictures again")
    }

    // MARK: Edit list

    static func editList() {
        var edit = EditList(bounds: 0..<1000)
        check(!edit.hasEdits, "a new edit has no edits")
        equal(edit.sequenceLength, 1000, "a new edit is the whole video")
        check(edit.cut(at: 300, minimumLength: 10), "cut at 300")
        check(edit.cut(at: 600, minimumLength: 10), "cut at 600")
        equal(edit.ranges, [0..<300, 300..<600, 600..<1000], "three parts")
        check(edit.hasEdits, "cuts are edits")
        check(edit.isCut(0) && edit.isCut(1), "both boundaries are cuts")
        check(!edit.cut(at: 305, minimumLength: 10), "no cut closer than the minimum length")
        check(!edit.cut(at: 1000, minimumLength: 10), "no cut at the end")

        var moved = edit
        moved.move(2, before: 0)
        equal(moved.ranges, [600..<1000, 0..<300, 300..<600], "the last part moved to the front")
        check(!moved.isCut(0) && moved.isCut(1), "a jump after the moved part, the old cut stays")
        equal(moved.index(at: 399), 0, "position 399 is in the first part")
        equal(moved.index(at: 400), 1, "position 400 starts the second part")
        equal(moved.index(at: 1000), 2, "the end belongs to the last part")
        equal(moved.sourcePosition(at: 450), 50, "source position in the second part")
        equal(moved.sequencePosition(ofSource: 350, inPart: 2), 750, "sequence position of a source position")
        equal(moved.starts, [0, 400, 700], "starts of the parts")
        var same = moved
        same.move(1, before: 2)
        equal(same, moved, "moving a part in front of its neighbour changes nothing")
        same.move(1, before: 1)
        equal(same, moved, "moving a part in front of itself changes nothing")
        moved.move(0, before: 3)
        equal(moved.ranges, [0..<300, 300..<600, 600..<1000], "moving it to the end restores the order")
        equal(moved.parts.map(\.id), edit.parts.map(\.id), "parts keep their identity when moved")

        var joined = edit
        joined.join(0)
        equal(joined.ranges, [0..<600, 600..<1000], "removing a cut joins the parts")
        var jump = edit
        jump.move(2, before: 1)
        let before = jump
        jump.join(0)
        equal(jump, before, "a jump cannot be removed like a cut")

        var cutMoved = edit
        cutMoved.moveCut(0, to: 250, minimumLength: 10)
        equal(cutMoved.ranges, [0..<250, 250..<600, 600..<1000], "a cut moves both parts")
        cutMoved.moveCut(0, to: 595, minimumLength: 10)
        equal(cutMoved.ranges[0], 0..<590, "a moved cut leaves the minimum length")

        var deleted = edit
        deleted.delete(1)
        equal(deleted.ranges, [0..<300, 600..<1000], "deleting the middle part")
        equal(deleted.sequenceLength, 700, "the edit is shorter")
        check(!deleted.isCut(0), "after deleting, the boundary is a jump")
        deleted.delete(0)
        deleted.delete(0)
        check(deleted.parts.isEmpty && deleted.index(at: 0) == nil, "everything can be deleted")
    }

    static func trimming() {
        var edit = EditList(bounds: 0..<1000)
        edit.cut(at: 300, minimumLength: 10)
        edit.cut(at: 600, minimumLength: 10)
        edit.delete(1)                                     // [0..300, 600..1000]
        equal(edit.room(for: 0), 0..<600, "a part can grow into deleted material")
        equal(edit.room(for: 1), 300..<1000, "… on both sides")
        edit.trim(0, .end, to: 450, minimumLength: 10)
        equal(edit.ranges, [0..<450, 600..<1000], "lengthening the end takes back deleted material")
        edit.trim(0, .end, to: 900, minimumLength: 10)
        equal(edit.ranges, [0..<600, 600..<1000], "but never material of another part")
        check(edit.isCut(0), "parts that meet again form a cut")
        edit.trim(0, .start, to: 100, minimumLength: 10)
        equal(edit.ranges[0], 100..<600, "shortening the start")
        edit.trim(0, .start, to: 599, minimumLength: 10)
        equal(edit.ranges[0], 590..<600, "a part keeps the minimum length")
        edit.trim(0, .start, to: -50, minimumLength: 10)
        equal(edit.ranges[0], 0..<600, "the start stops at the beginning of the video")
        edit.trim(1, .end, to: 5000, minimumLength: 10)
        equal(edit.ranges[1], 600..<1000, "the end stops at the end of the video")
        edit.trim(1, .end, to: 700, minimumLength: 10)
        equal(edit.ranges, [0..<600, 600..<700], "shortening the end")
        check(edit.hasEdits, "a shortened video is an edit")

        var moved = EditList(bounds: 0..<1000)
        moved.cut(at: 500, minimumLength: 10)
        moved.move(1, before: 0)                           // [500..1000, 0..500]
        moved.trim(0, .start, to: 0, minimumLength: 10)
        equal(moved.ranges[0], 500..<1000, "a moved part cannot grow over its neighbour in the source")

        var short = EditList(bounds: 0..<1000, parts: [Part(start: 0, end: 5), Part(start: 10, end: 1000)])
        short.trim(0, .start, to: 3, minimumLength: 10)
        equal(short.ranges[0], 0..<5, "a part shorter than the minimum is not shortened further")
        short.trim(0, .end, to: 8, minimumLength: 10)
        equal(short.ranges[0], 0..<8, "… but it can grow")

        let offset = EditList(bounds: 20..<500)
        equal(offset.ranges, [20..<500], "a video track starting later is used from its start")
        check(!offset.hasEdits, "… without counting as an edit")
    }

    // MARK: Effects

    static func effects() {
        typealias Clip = EffectLayout.Clip
        typealias Blend = EffectLayout.Blend
        typealias Ramp = EffectLayout.Ramp
        let frame: Int64 = 10, bounds: Range<Int64> = 0..<3000
        func edit(_ ranges: [Range<Int64>], _ transitions: [Transition?] = []) -> EditList {
            EditList(bounds: bounds, parts: ranges.enumerated().map { index, range in
                Part(start: range.lowerBound, end: range.upperBound, transition: index < transitions.count ? transitions[index] : nil)
            })
        }
        let dissolve = Transition(kind: .dissolve, duration: 300), black = Transition(kind: .black, duration: 300)

        var whole = EditList(bounds: bounds)
        check(!whole.hasEffects && !whole.hasEdits, "a plain video has no effects")
        whole.setTransition(Transition(kind: .dissolve, duration: 150), at: 0)
        whole.setTransition(Transition(kind: .black, duration: 200), at: 1)
        check(whole.hasEffects && whole.hasEdits, "fades are effects and edits")
        var layout = whole.effectLayout(frame: frame)
        equal(layout.ramps, [Ramp(range: 0..<150, from: 0, to: 1), Ramp(range: 2800..<3000, from: 1, to: 0)], "fade in and out")
        equal(layout.clips, [Clip(position: 0, source: 0..<3000, track: 0)], "fades need no second track")
        equal(layout.level(at: 0, frame: frame), 0, "the first frame of a fade in is black")
        equal(layout.level(at: 140, frame: frame), 1, "its last frame is the normal picture")
        equal(layout.level(at: 2990, frame: frame), 0, "the last frame of a fade out is black")
        near(layout.level(at: 70, frame: frame), 0.5, 0.001, "half way through the fade in")

        // A dissolve centred on the cut, with material beyond it on both sides.
        layout = edit([1000..<2000, 500..<900], [nil, dissolve]).effectLayout(frame: frame)
        equal(layout.clips, [Clip(position: 0, source: 1000..<2150, track: 0), Clip(position: 850, source: 350..<900, track: 1)],
              "a dissolve puts the next part on the other track, with material beyond the cut")
        equal(layout.blends, [Blend(range: 850..<1150, from: 0, to: 1)], "the dissolve is centred on the cut")
        equal(layout.length, 1400, "a dissolve keeps the length of the edit")
        // No material before the next part: the dissolve runs after the cut only, and is shorter.
        layout = edit([1000..<2000, 0..<400], [nil, dissolve]).effectLayout(frame: frame)
        equal(layout.blends, [Blend(range: 1000..<1200, from: 0, to: 1)], "without material before the cut it runs after it")
        equal(layout.regions.map(\.shortened), [true], "… and is marked as shortened")
        equal(layout.clips[0].source, 1000..<2200, "the first part plays on under the second")
        // Neither material nor room: no dissolve at all, everything stays on one track.
        layout = edit([2000..<3000, 0..<1000], [Transition(kind: .dissolve, duration: 300), dissolve]).effectLayout(frame: frame)
        check(layout.blends.isEmpty && layout.trackCount == 1, "a dissolve without material does not happen", "\(layout.blends)")
        equal(layout.ramps.first, Ramp(range: 0..<300, from: 0, to: 1), "on the first part a dissolve fades in from black")

        // Three dissolves: the tracks alternate.
        layout = edit([0..<500, 1000..<1500, 2000..<2500, 2600..<2900], [nil, dissolve, dissolve, dissolve]).effectLayout(frame: frame)
        equal(layout.clips.map(\.track), [0, 1, 0, 1], "the tracks alternate")
        check(zip(layout.clips, layout.clips.dropFirst(2)).allSatisfy { $0.end <= $1.position },
              "clips on the same track do not overlap")
        // Dip to black: the end of one part and the start of the next, no extra material.
        layout = edit([0..<1000, 2000..<2200], [nil, black]).effectLayout(frame: frame)
        equal(layout.ramps, [Ramp(range: 850..<1000, from: 1, to: 0), Ramp(range: 1000..<1100, from: 0, to: 1)],
              "a dip to black takes at most half of a part")
        equal(layout.clips.map(\.track), [0, 0], "a dip to black needs no second track")
        equal(layout.regions.map(\.range), [850..<1100], "the dip as shown in the timeline")

        // Transitions stay with their part.
        var moved = edit([0..<1000, 1000..<2000], [nil, black])
        moved.move(1, before: 0)
        equal(moved.transition(at: 0), black, "moved to the front, the transition becomes the fade in")
        equal(moved.transition(at: 1), nil, "the other part keeps having none")
        var joined = edit([0..<1000, 1000..<2000], [dissolve, black])
        joined.join(0)
        equal(joined.transition(at: 0), dissolve, "joining keeps the transition of the first part")
        var cut = edit([0..<2000], [black])
        cut.cut(at: 1000, minimumLength: 10)
        equal(cut.transition(at: 1), nil, "a new cut has no transition")

        // Titles belong to the pictures they start on.
        var titled = edit([0..<1000, 2000..<3000])
        titled.addTitle(Title(text: "A", anchor: 0, length: 400), at: 1200)
        titled.addTitle(Title(text: "B", anchor: 0, length: 5000), at: 300)
        equal(titled.placedTitles.map(\.title.text), ["B", "A"], "titles in order of their start")
        equal(titled.placedTitles.map(\.range), [300..<2000, 1200..<1600], "a title is cut off at the end of the edit")
        equal(titled.parts[1].titles.first?.anchor, 2200, "a title remembers the source position it starts on")
        let titleA = titled.parts[1].titles[0].id, titleB = titled.parts[0].titles[0].id
        titled.move(1, before: 0)
        equal(titled.placedTitle(titleA)?.range, 200..<600, "a title moves with its part")
        titled.trim(0, .start, to: 2100, minimumLength: 10)
        equal(titled.placedTitle(titleA)?.range, 100..<500, "trimming the part keeps the title on its picture")
        titled.trim(0, .start, to: 2500, minimumLength: 10)
        equal(titled.placedTitle(titleA)?.start, 0, "a title whose start was trimmed away starts with the part")
        titled.trim(0, .start, to: 2000, minimumLength: 10)
        titled.moveTitle(titleA, to: 1100)
        equal(titled.placedTitle(titleA)?.part, 1, "a moved title belongs to the part it now starts on")
        equal(titled.title(titleA)?.anchor, 100, "… at the source position there")
        titled.trimTitle(titleA, .start, to: 1000, minimumLength: 50)
        equal(titled.placedTitle(titleA)?.range, 1000..<1500, "moving the start of a title keeps its end")
        titled.trimTitle(titleA, .end, to: 1020, minimumLength: 50)
        equal(titled.placedTitle(titleA)?.range, 1000..<1050, "a title keeps its minimum length")
        titled.delete(1)
        check(titled.title(titleA) == nil && titled.title(titleB) == nil, "deleting a part deletes its titles")

        var split = edit([0..<2000])
        split.addTitle(Title(text: "früh", anchor: 0, length: 100), at: 200)
        split.addTitle(Title(text: "spät", anchor: 0, length: 100), at: 1500)
        split.cut(at: 1000, minimumLength: 10)
        equal(split.parts.map { $0.titles.map(\.text) }, [["früh"], ["spät"]], "a cut hands the later titles to the second part")
        split.moveCut(0, to: 1600, minimumLength: 10)
        equal(split.parts.map { $0.titles.map(\.text) }, [["früh", "spät"], []], "moving the cut takes the titles along")
        split.join(0)
        equal(split.placedTitles.map(\.start), [200, 1500], "joining keeps all titles in place")
        check(split.hasEffects, "titles are effects")
    }

    static func exportFormat() {
        let mov = URL(fileURLWithPath: "/tmp/a.MOV"), mp4 = URL(fileURLWithPath: "/tmp/a.mp4"), m4v = URL(fileURLWithPath: "/tmp/a.m4v")
        equal(VideoFormat(of: mov), .mov, "a .MOV file is a MOV")
        equal(VideoFormat(of: m4v), .mp4, "an M4V counts as MP4")
        equal(VideoFormat.preferred(remembered: nil, source: mov, mp4Possible: true), .mov, "first export: the container of the source")
        equal(VideoFormat.preferred(remembered: nil, source: mp4, mp4Possible: true), .mp4, "… MP4 for an MP4")
        equal(VideoFormat.preferred(remembered: "mp4", source: mov, mp4Possible: true), .mp4, "then the last choice")
        equal(VideoFormat.preferred(remembered: "mp4", source: mov, mp4Possible: false), .mov, "MOV when MP4 is not possible")
        equal(VideoFormat.preferred(remembered: "xyz", source: mp4, mp4Possible: true), .mp4, "an unknown stored value is ignored")
    }

    static func formatting() {
        equal(TimeFormat.string(65.25), "1:05.25", "minutes and hundredths")
        equal(TimeFormat.string(3725, decimals: 0), "1:02:05", "with hours")
        equal(TimeFormat.string(5, decimals: 0, forceHours: true), "0:00:05", "forced hours")
        equal(FileNames.sanitize("../a/b:c"), "-a-b-c", "file names lose separators and leading dots")
        let temp = Exporter.temporaryURL(for: URL(fileURLWithPath: "/tmp/Film (gekürzt).mov"))
        check(temp.lastPathComponent.hasPrefix(".Film (gekürzt)-") && temp.pathExtension == "mov",
              "the temporary export file is hidden and keeps the extension", temp.lastPathComponent)
    }

    // MARK: Videos

    static let fps: Int32 = 30
    static let width = 320, height = 180
    static let sampleRate = 48_000.0

    static func videos(_ root: URL) async throws {
        let source = root.appendingPathComponent("Quelle.mov")
        step = "test video"
        // 8 s, a keyframe every 2 s, a beep in the first 0.1 s of every second, and the metadata an iPhone writes.
        try await makeVideo(source, frames: 240, keyInterval: 60, metadata: iPhoneMetadata.map { metadataItem($0.key, $0.value) })
        try MovieHeader.setCreationTime(recorded, of: source)
        equal(try MovieHeader.creationTime(of: source), recorded, "the recording time is set in the movie header")
        let document = try await VideoDocument.open(source)
        check(document.summary.hasPrefix("H.264 · 320 × 180 · 30 fps"), "summary of the test video", document.summary)
        check(document.audioTrack != nil && document.audioIsAAC, "the sound track is found and is AAC")
        near(document.seconds(document.bounds.upperBound), 8, 0.001, "length of the video")
        equal(document.ticks(seconds: 1) / document.frameTicks, 30, "one second is 30 frames")
        equal(document.snapped(document.ticks(seconds: 1.0 / 30 * 4.4)), 4 * document.frameTicks, "snapping to the nearest frame")
        equal(document.snapped(-5), document.bounds.lowerBound, "snapping stays in the video")
        equal(try await frameNumbers(source).prefix(5).map { $0 }, [0, 1, 2, 3, 4], "the test pattern decodes")

        step = "waveform"
        let peaks = try AudioReader.peaks(for: document, token: CancelToken()) { _ in }
        check(peaks != nil, "the waveform is read")
        if let peaks {
            near(Double(peaks.length) / sampleRate, 8, 0.05, "the waveform covers the whole sound")
            let beep = peaks.range(from: Int64(sampleRate * 3.02), to: Int64(sampleRate * 3.08), level: 0)
            let quiet = peaks.range(from: Int64(sampleRate * 3.4), to: Int64(sampleRate * 3.6), level: 0)
            check((beep?.1 ?? 0) > 0.3, "the beep is in the waveform", "\(String(describing: beep))")
            check((quiet?.1 ?? 1) < 0.05, "the pause is quiet in the waveform", "\(String(describing: quiet))")
        }

        // Parts that start and end between keyframes, the later one first: 6.2–7.6 s, then 1.0–2.5 s.
        let ranges = [(6.2, 7.6), (1.0, 2.5)].map { document.ticks(seconds: $0.0)..<document.ticks(seconds: $0.1) }
        let expected = Array(186..<228) + Array(30..<75)
        for name in ["Schnitt.mp4", "Schnitt.mov"] {
            let output = root.appendingPathComponent(name)
            step = "video export \(name)"
            try await Exporter.exportVideo(document, ranges: ranges, to: output) { _ in }
            let frames = try await frameNumbers(output)
            equal(frames, expected, "\(name): exactly the frames of both parts, in the new order")
            let exported = try await VideoDocument.open(output)
            near(exported.seconds(exported.bounds.upperBound), 2.9, 0.001, "\(name): length of the edit")
            check(exported.summary.hasPrefix("H.264"), "\(name): the picture was copied, not re-encoded", exported.summary)
            try await checkRecordingTime(output, name)
            if name.hasSuffix(".mov") {
                try await checkMetadata(output, iPhoneMetadata, name)
            } else {
                // QuickTime metadata does not fit in an MP4: date and place go over as ISO user data.
                try await checkCommonMetadata(output, [(.commonKeyCreationDate, "2026-05-01T14:30:00+0200"),
                                                       (.commonKeyLocation, "+52.5163+013.3777+034.000/")], name)
            }
            let sound = try await samples(of: output)
            // Beeps where the source had a full second: 7 s → 0.8 s, 1 s → 1.4 s, 2 s → 2.4 s.
            for at in [0.8, 1.4, 2.4] {
                check(rms(sound, from: at + 0.03, to: at + 0.07) > 0.2, "\(name): beep at \(at) s, in sync with the picture")
            }
            for at in [0.5, 1.2, 2.0, 2.7] {
                check(rms(sound, from: at, to: at + 0.08) < 0.02, "\(name): quiet at \(at) s")
            }
        }

        var overwrote = false
        do {
            try await Exporter.exportVideo(document, ranges: ranges, to: source) { _ in }
        } catch ExportError.overwritesSource {
            overwrote = true
        }
        check(overwrote, "the original cannot be overwritten")
        equal(try await frameNumbers(source).count, 240, "the original is unchanged")

        step = "sound export"
        for format in AudioFormat.allCases {
            let output = root.appendingPathComponent("Ton.\(format.fileExtension)")
            step = "sound export \(format.title)"
            try await Exporter.exportAudio(document, ranges: ranges, format: format, to: output) { _ in }
            let file = try AVAudioFile(forReading: output)
            let seconds = Double(file.length) / file.fileFormat.sampleRate
            near(seconds, 2.9, format == .mp3 ? 0.06 : 0.03, "\(format.title): length of the sound")
            let sound = try readAll(file)
            for at in [0.8, 1.4, 2.4] {
                check(rms(sound, from: at + 0.03, to: at + 0.07) > 0.2, "\(format.title): beep at \(at) s")
            }
            check(rms(sound, from: 0.5, to: 0.6) < 0.02, "\(format.title): quiet between the beeps")
        }
        step = "sound of the whole video"
        let whole = root.appendingPathComponent("Ganzer Ton.m4a")
        try await Exporter.exportAudio(document, ranges: [document.bounds], format: .m4a, to: whole) { _ in }
        let copied = try AVAudioFile(forReading: whole)
        // The test sound itself ends a little early (AAC priming of the generated file).
        let soundEnd = min(8, document.audioTimeRange?.end.seconds ?? 0)
        check(soundEnd > 7.9, "the test sound covers almost the whole video", "\(soundEnd)")
        near(Double(copied.length) / copied.fileFormat.sampleRate, soundEnd, 0.01, "the sound of the whole video has its full length")
        let copiedSound = try readAll(copied)
        check(rms(copiedSound, from: 5.03, to: 5.07) > 0.2 && rms(copiedSound, from: 5.5, to: 5.6) < 0.02,
              "the sound of the whole video is in time")

        // The sound of the first part (1–3 s) half a second later, over the start of the second (5–6 s):
        // silence at first, the beeps of 1 s and 2 s at 0.5 s and 1.5 s, the beep of 5 s replaced.
        step = "detached sound"
        let t = document.ticks(seconds:)
        let detached = EditList(bounds: document.bounds, parts: [
            Part(start: t(1), end: t(3), sound: .detached(Sound(start: t(1), end: t(3), shift: t(0.5), layer: 1))),
            Part(start: t(5), end: t(6)),
        ])
        equal(detached.soundSegments, [SoundSegment(position: t(0.5), source: t(1)..<t(3)), SoundSegment(position: t(2.5), source: t(5.5)..<t(6))],
              "the shifted sound replaces the start of the next part")
        for name in ["Versetzt.mov", "Versetzt.mp4", "Versetzt.wav"] {
            let output = root.appendingPathComponent(name)
            step = "detached sound \(name)"
            let sound: [Float]
            if name.hasSuffix(".wav") {
                try await Exporter.exportAudio(document, ranges: detached.ranges, sound: detached.soundSegments, format: .wav, to: output) { _ in }
                let file = try AVAudioFile(forReading: output)
                near(Double(file.length) / file.fileFormat.sampleRate, 3, 0.03, "\(name): the sound starts with the silence")
                sound = try readAll(file)
            } else {
                try await Exporter.exportVideo(document, ranges: detached.ranges, sound: detached.soundSegments, to: output) { _ in }
                equal(try await frameNumbers(output), Array(30..<90) + Array(150..<180), "\(name): the pictures stay as they were")
                sound = try await samples(of: output)
            }
            for at in [0.5, 1.5] {
                check(rms(sound, from: at + 0.03, to: at + 0.07) > 0.2, "\(name): beep at \(at) s, half a second later")
            }
            check(rms(sound, from: 0, to: 0.08) < 0.02, "\(name): silence where the sound moved away")
            check(rms(sound, from: 2.0, to: 2.08) < 0.02, "\(name): the next part's beep is replaced")
            check(rms(sound, from: 2.6, to: 2.9) < 0.02, "\(name): quiet at the end")
        }

        try await effectExports(root, document)
        try await hardening(root, document)

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".") }
        equal(leftovers, [], "no temporary files are left behind")

        // Portrait video from a phone: stored landscape with a rotation, which the export keeps.
        step = "portrait video"
        let portrait = root.appendingPathComponent("Hochkant.mp4")
        try await makeVideo(portrait, frames: 60, keyInterval: 30, codec: .hevc, transform: CGAffineTransform(rotationAngle: .pi / 2),
                            metadata: mp4Metadata.map { metadataItem($0.key, $0.value) })
        try MovieHeader.setCreationTime(recorded, of: portrait)
        let upright = try await VideoDocument.open(portrait)
        equal(upright.displaySize, CGSize(width: height, height: width), "a portrait video is shown upright")
        check(upright.summary.hasPrefix("HEVC"), "the codec is recognised", upright.summary)
        let portraitCut = root.appendingPathComponent("Hochkant (gekürzt).mp4")
        try await Exporter.exportVideo(upright, ranges: [upright.ticks(seconds: 0.5)..<upright.ticks(seconds: 1.5)], to: portraitCut) { _ in }
        let cutTrack = try await AVURLAsset(url: portraitCut).loadTracks(withMediaType: .video)[0]
        let transform = try await cutTrack.load(.preferredTransform)
        check(abs(transform.b - 1) < 0.001 && abs(transform.c + 1) < 0.001, "the rotation is kept", "\(transform)")
        equal(try await frameNumbers(portraitCut), Array(15..<45), "the portrait cut has the right frames")
        try await checkRecordingTime(portraitCut, "MP4 from an MP4")
        try await checkMetadata(portraitCut, mp4Metadata, "MP4 from an MP4")
        let portraitMOV = root.appendingPathComponent("Hochkant (gekürzt).mov")
        try await Exporter.exportVideo(upright, ranges: [upright.ticks(seconds: 0.5)..<upright.ticks(seconds: 1.5)], to: portraitMOV) { _ in }
        let movTrack = try await AVURLAsset(url: portraitMOV).loadTracks(withMediaType: .video)[0]
        let movTransform = try await movTrack.load(.preferredTransform)
        check(abs(movTransform.b - 1) < 0.001 && abs(movTransform.c + 1) < 0.001, "MOV from an MP4: the rotation is kept")
        equal(try await frameNumbers(portraitMOV), Array(15..<45), "MOV from an MP4: the right frames")
        try await checkRecordingTime(portraitMOV, "MOV from an MP4")

        // ProRes fits only in a MOV without re-encoding.
        step = "ProRes"
        let proRes = root.appendingPathComponent("ProRes.mov")
        try await makeVideo(proRes, frames: 30, keyInterval: 1, codec: .proRes422)
        let master = try await VideoDocument.open(proRes)
        check(master.summary.hasPrefix("ProRes") && !master.copiesIntoMP4, "ProRes is recognised and kept out of MP4", master.summary)
        let proResRanges = [master.ticks(seconds: 0.5)..<master.ticks(seconds: 0.8)]
        var refusedMP4 = false
        do {
            try await Exporter.exportVideo(master, ranges: proResRanges, to: root.appendingPathComponent("ProRes.mp4")) { _ in }
        } catch ExportError.notMP4 {
            refusedMP4 = true
        }
        check(refusedMP4, "ProRes into MP4 is refused with a clear message")
        let proResCut = root.appendingPathComponent("ProRes (gekürzt).mov")
        try await Exporter.exportVideo(master, ranges: proResRanges, to: proResCut) { _ in }
        equal(try await frameNumbers(proResCut), Array(15..<24), "ProRes can be cut into a MOV")
        var proResTitle = EditList(bounds: master.bounds)
        proResTitle.addTitle(Title(text: "ProRes", anchor: 0, length: master.ticks(seconds: 0.5), y: 0.2), at: 0)
        let proResMP4 = root.appendingPathComponent("ProRes mit Titel.mp4")
        try await Exporter.exportEffects(master, edit: proResTitle, codec: .h264, to: proResMP4) { _ in }
        let proResEncoded = try await VideoDocument.open(proResMP4)
        check(proResEncoded.summary.hasPrefix("H.264"), "with effects ProRes is encoded anew and fits in an MP4", proResEncoded.summary)
        try await checkPortraitEffects(root, upright)

        // A video without sound.
        step = "video without sound"
        let silent = root.appendingPathComponent("Stumm.mov")
        try await makeVideo(silent, frames: 30, keyInterval: 30, withAudio: false)
        let mute = try await VideoDocument.open(silent)
        check(mute.audioTrack == nil, "a video without sound has no sound track")
        let mutePeaks = try AudioReader.peaks(for: mute, token: CancelToken()) { _ in }
        check(mutePeaks == nil, "… and no waveform")
        let muteCut = root.appendingPathComponent("Stumm (gekürzt).mov")
        try await Exporter.exportVideo(mute, ranges: [mute.ticks(seconds: 0.2)..<mute.ticks(seconds: 0.6)], to: muteCut) { _ in }
        equal(try await frameNumbers(muteCut), Array(6..<18), "a video without sound can be cut")

        var refused = false
        do {
            _ = try await VideoDocument.open(root.appendingPathComponent("Ton.wav"))
        } catch VideoError.noVideo {
            refused = true
        }
        check(refused, "a sound file is refused with a clear message")
        let fake = root.appendingPathComponent("Kaputt.mkv")
        try Data("kein Video".utf8).write(to: fake)
        var unreadable = false
        do {
            _ = try await VideoDocument.open(fake)
        } catch VideoError.cannotOpen {
            unreadable = true
        }
        check(unreadable, "a file macOS cannot open is refused")
    }

    // MARK: Effects export

    static func effectExports(_ root: URL, _ document: VideoDocument) async throws {
        let t = document.ticks(seconds:)
        // Fade in (0.5 s), a dip to black (0.4 s) between the parts and a fade out (0.5 s): 42 + 45 frames.
        step = "effects: fades"
        var faded = EditList(bounds: document.bounds, parts: [
            Part(start: t(6.2), end: t(7.6), transition: Transition(kind: .dissolve, duration: t(0.5))),
            Part(start: t(1.0), end: t(2.5), transition: Transition(kind: .black, duration: t(0.4))),
        ])
        faded.fadeOut = t(0.5)
        let fadedURL = root.appendingPathComponent("Blenden.mov")
        try await Exporter.exportEffects(document, edit: faded, codec: .h264, to: fadedURL) { _ in }
        let fadedDocument = try await VideoDocument.open(fadedURL)
        check(fadedDocument.summary.hasPrefix("H.264 · 320 × 180 · 30 fps"), "effects: H.264 in the size and rate of the source",
              fadedDocument.summary)
        near(fadedDocument.seconds(fadedDocument.bounds.upperBound), 2.9, 0.001, "effects: the length stays")
        try await checkSDR(fadedURL, "effects")
        try await checkRecordingTime(fadedURL, "effects")
        try await checkMetadata(fadedURL, iPhoneMetadata, "effects")
        let numbers = try await frameNumbers(fadedURL)
        let pictures = try await grayPictures(fadedURL)
        equal(pictures.count, 87, "effects: every frame is there")
        if pictures.count == 87 {
            check(pictures[0].maximum() < 12, "the first frame of the fade in is black", "\(pictures[0].maximum())")
            let rising = (0..<15).map { pictures[$0].value(80, 90) }
            check(zip(rising, rising.dropFirst()).allSatisfy { $0 <= $1 + 2 } && rising[7] > 20 && rising[7] < 165,
                  "the fade in brightens step by step", "\(rising)")
            equal(Array(numbers[14..<36]), Array(200..<222), "after the fade in the frames are the right ones")
            check(pictures[41].maximum() < 12 && pictures[42].maximum() < 12, "black on both sides of the dip",
                  "\(pictures[41].maximum()) \(pictures[42].maximum())")
            check(pictures[39].value(80, 90) < pictures[36].value(80, 90), "the picture darkens towards the dip")
            equal(Array(numbers[48..<72]), Array(36..<60), "after the dip the frames are the right ones")
            check(pictures[86].maximum() < 12, "the last frame of the fade out is black", "\(pictures[86].maximum())")
        }
        let sound = try await samples(of: fadedURL)
        let loud = rms(sound, from: 0.83, to: 0.87)
        check(loud > 0.2, "effects: a beep outside the fades is as loud as before")
        // 1.43–1.47 s lies 15–35 % into the fade in after the dip.
        check(rms(sound, from: 1.43, to: 1.47) < loud * 0.4, "effects: the sound fades in with the picture after the dip",
              "\(rms(sound, from: 1.43, to: 1.47)) of \(loud)")
        let layout = faded.effectLayout(frame: document.frameTicks)
        let fadedSound = root.appendingPathComponent("Blenden.wav")
        try await Exporter.exportAudio(document, ranges: faded.ranges, sound: faded.soundSegments, ramps: layout.ramps, format: .wav,
                                       to: fadedSound) { _ in }
        let fadedSamples = try readAll(try AVAudioFile(forReading: fadedSound))
        let fadedLoud = rms(fadedSamples, from: 0.83, to: 0.87)
        check(fadedLoud > 0.2 && rms(fadedSamples, from: 1.43, to: 1.47) < fadedLoud * 0.4, "the sound export follows the fades")

        // A dissolve of 0.4 s (frames 24–35), a title with a box at the top and a half-transparent logo.
        step = "effects: dissolve, title, logo"
        let logoURL = root.appendingPathComponent("Logo.png")
        try writeLogo(logoURL)
        var mixed = EditList(bounds: document.bounds, parts: [
            Part(start: t(1.0), end: t(2.0)),
            Part(start: t(5.0), end: t(6.0), transition: Transition(kind: .dissolve, duration: t(0.4))),
        ])
        mixed.addTitle(Title(text: "VideoHub", anchor: 0, length: t(1.0), y: 0.18, size: 0.12, bar: true), at: t(0.1))
        mixed.logo = Logo(file: logoURL, x: 0.2, y: 0.8, width: 0.25, opacity: 0.5)
        let mixedURL = root.appendingPathComponent("Überblendung.mp4")
        try await Exporter.exportEffects(document, edit: mixed, codec: .hevc, to: mixedURL) { _ in }
        let mixedDocument = try await VideoDocument.open(mixedURL)
        check(mixedDocument.summary.hasPrefix("HEVC · 320 × 180"), "effects: HEVC on request", mixedDocument.summary)
        try await checkSDR(mixedURL, "effects in HEVC")
        let mixedNumbers = try await frameNumbers(mixedURL)
        let mixedPictures = try await grayPictures(mixedURL)
        equal(mixedNumbers.count, 60, "a dissolve keeps the length")
        if mixedNumbers.count == 60, mixedPictures.count == 60 {
            equal(Array(mixedNumbers[0..<25]), Array(30..<55), "before and at the start of the dissolve: the first part")
            equal(Array(mixedNumbers[35..<60]), Array(155..<180), "at the end of the dissolve and after it: the second part")
            let middle = mixedPictures[30].value(80, 90)
            check(middle > 64 && middle < 128, "in the middle of the dissolve both pictures blend", "\(middle)")
            let titleBox = (x: 90..<230, y: 10..<56), below = (x: 0..<320, y: 60..<120)
            check(mixedPictures[18].maximum(titleBox) > 200, "the title is drawn", "\(mixedPictures[18].maximum(titleBox))")
            check(mixedPictures[18].maximum(below) < 70, "nothing else is drawn on the picture", "\(mixedPictures[18].maximum(below))")
            check(mixedPictures[3].maximum(titleBox) < 160, "the title fades in", "\(mixedPictures[3].maximum(titleBox))")
            let clear = (x: titleBox.x, y: 60..<120)
            check(mixedPictures[40].maximum(titleBox) <= mixedPictures[40].maximum(clear) + 8, "after its end the title is gone",
                  "\(mixedPictures[40].maximum(titleBox)) vs. \(mixedPictures[40].maximum(clear))")
            for frame in [3, 18, 30, 59] {
                let logo = mixedPictures[frame].value(64, 144)
                check(logo > 120 && logo < 230, "frame \(frame): the logo is there, half transparent", "\(logo)")
            }
        }
    }

    // MARK: Hardening

    /// The movie header patch on hand-made files: 64-bit and open-ended boxes work; anything malformed is
    /// left exactly as it is.
    static func movieHeader(_ root: URL) throws {
        step = "movie header"
        func box(_ type: String, _ content: [UInt8]) -> [UInt8] { be(UInt32(8 + content.count)) + Array(type.utf8) + content }
        func be(_ value: UInt32) -> [UInt8] { (0..<4).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
        func be64(_ value: UInt64) -> [UInt8] { (0..<8).reversed().map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) } }
        let mvhd0 = box("mvhd", [0, 0, 0, 0] + be(1234) + be(1234) + be(600) + be(6000) + [UInt8](repeating: 0, count: 80))
        let mvhd1 = box("mvhd", [1, 0, 0, 0] + be64(5_000_000_000) + be64(5_000_000_000) + be(600) + be64(6000)
                        + [UInt8](repeating: 0, count: 80))
        let ftyp = box("ftyp", Array("qt  ".utf8) + be(0))
        // mdat with a 64-bit size (size field 1), 32 bytes in all.
        let mdat64 = be(1) + Array("mdat".utf8) + be64(32) + [UInt8](repeating: 0xAB, count: 16)

        func write(_ name: String, _ bytes: [UInt8]) throws -> URL {
            let url = root.appendingPathComponent(name)
            try Data(bytes).write(to: url)
            return url
        }
        let valid = try write("Kopf.mov", ftyp + mdat64 + box("moov", mvhd0 + box("trak", [])))
        equal(try MovieHeader.creationTime(of: valid), 1234, "movie header: read behind a 64-bit mdat")
        try MovieHeader.setCreationTime(recorded, of: valid)
        equal(try MovieHeader.creationTime(of: valid), recorded, "movie header: written in place")
        equal(try Data(contentsOf: valid).count, ftyp.count + mdat64.count + 8 + mvhd0.count + 8, "movie header: the file keeps its size")
        let version1 = try write("Kopf v1.mov", ftyp + box("moov", mvhd1))
        equal(try MovieHeader.creationTime(of: version1), 5_000_000_000, "movie header: version 1 has 64-bit times")
        // A size of 0 means "up to the end of the file".
        let openEnded = try write("Kopf offen.mov", ftyp + be(0) + Array("moov".utf8) + mvhd0)
        equal(try MovieHeader.creationTime(of: openEnded), 1234, "movie header: a box running to the end of the file")

        let moov = box("moov", mvhd0)
        let malformed: [(String, [UInt8])] = [
            ("empty", []),
            ("garbage", Array("this is not a movie at all".utf8)),
            ("box larger than the file", ftyp + be(4000) + Array("moov".utf8) + mvhd0),
            ("box smaller than its header", be(4) + Array("free".utf8) + moov),
            ("truncated 64-bit header", ftyp + be(1) + Array("mdat".utf8) + [0, 0]),
            ("64-bit size past the end", ftyp + be(1) + Array("mdat".utf8) + be64(UInt64.max) + moov),
            ("mvhd too short", ftyp + box("moov", box("mvhd", [0, 0, 0, 0, 1, 2]))),
            ("unknown mvhd version", ftyp + box("moov", box("mvhd", [7] + Array(mvhd0[9...])))),
            ("child larger than moov", ftyp + be(16) + Array("moov".utf8) + mvhd0),
            ("truncated file", Array((ftyp + moov).prefix(ftyp.count + 20))),
        ]
        for (name, bytes) in malformed {
            let url = try write("Kaputt \(name).mov", bytes)
            equal(try? MovieHeader.creationTime(of: url), nil, "movie header (\(name)): nothing is read")
            try? MovieHeader.setCreationTime(recorded, of: url)
            equal([UInt8](try Data(contentsOf: url)), bytes, "movie header (\(name)): the file stays as it was")
        }
    }

    /// The source is never replaced, a sound export without sound fails clearly, cancelled exports and
    /// a damaged source leave nothing behind.
    static func hardening(_ root: URL, _ document: VideoDocument) async throws {
        let manager = FileManager.default
        let original = try Data(contentsOf: document.url)
        let ranges = [document.ticks(seconds: 1)..<document.ticks(seconds: 2)]
        step = "hardening: the source under another name"
        let link = root.appendingPathComponent("Quelle (Link).mov")
        try manager.linkItem(at: document.url, to: link)
        let otherCase = document.url.deletingLastPathComponent().appendingPathComponent(document.url.lastPathComponent.uppercased())
        for (name, target) in [("a hard link", link), ("other letter case", otherCase)] {
            var refused = false
            do {
                try await Exporter.exportVideo(document, ranges: ranges, to: target) { _ in }
            } catch ExportError.overwritesSource {
                refused = true
            }
            check(refused, "the source cannot be overwritten through \(name)")
        }
        try manager.removeItem(at: link)
        check(try Data(contentsOf: document.url) == original, "the source is unchanged")

        step = "hardening: everything muted"
        var muted = EditList(bounds: document.bounds)
        muted.cut(at: document.ticks(seconds: 4), minimumLength: document.frameTicks)
        muted.setMuted(0, true)
        muted.setMuted(1, true)
        var silent = false
        do {
            try await Exporter.exportAudio(document, ranges: muted.ranges, sound: muted.soundSegments, format: .m4a,
                                           to: root.appendingPathComponent("Ohne Ton.m4a")) { _ in }
        } catch ExportError.failed(let reason) {
            silent = reason.contains("kein Ton")
        }
        check(silent, "a sound export without any sound says so")
        check(!manager.fileExists(atPath: root.appendingPathComponent("Ohne Ton.m4a").path), "… and writes no file")
        let mutedVideo = root.appendingPathComponent("Ohne Ton.mov")
        try await Exporter.exportVideo(document, ranges: muted.ranges, sound: muted.soundSegments, to: mutedVideo) { _ in }
        equal(try await AVURLAsset(url: mutedVideo).loadTracks(withMediaType: .audio).count, 0, "a muted video is exported without sound")
        muted.fadeOut = document.ticks(seconds: 0.5)
        let mutedEffects = root.appendingPathComponent("Ohne Ton mit Blende.mov")
        try await Exporter.exportEffects(document, edit: muted, codec: .h264, to: mutedEffects) { _ in }
        equal(try await frameNumbers(mutedEffects).count, 240, "a muted video with effects is exported")

        step = "hardening: cancelled exports"
        var fadeOut = EditList(bounds: document.bounds)
        fadeOut.fadeOut = document.ticks(seconds: 0.5)
        let faded = fadeOut
        let exports: [(String, @Sendable (URL) async throws -> Void)] = [
            ("Abbruch.mov", { try await Exporter.exportVideo(document, ranges: [document.bounds], to: $0) { _ in } }),
            ("Abbruch mit Blende.mov", { try await Exporter.exportEffects(document, edit: faded, codec: .h264, to: $0) { _ in } }),
            ("Abbruch.wav", { try await Exporter.exportAudio(document, ranges: [document.bounds], format: .wav, to: $0) { _ in } }),
        ]
        for (name, export) in exports {
            let output = root.appendingPathComponent(name)
            let task = Task { try await export(output) }
            task.cancel()
            let cancelled: Bool
            do {
                try await task.value
                cancelled = false
            } catch {
                cancelled = error is CancellationError
            }
            check(cancelled, "\(name): a cancelled export stops")
            check(!manager.fileExists(atPath: output.path), "\(name): a cancelled export leaves no file")
        }

        // The end of the movie data is missing (header in front): opening, the waveform and the export
        // must fail or work, but never crash or leave anything behind.
        step = "hardening: damaged source"
        let front = root.appendingPathComponent("Vorne.mov")
        guard let session = AVAssetExportSession(asset: document.asset, presetName: AVAssetExportPresetPassthrough) else { return }
        session.shouldOptimizeForNetworkUse = true
        try await session.export(to: front, as: .mov)
        let bytes = try Data(contentsOf: front)
        let damagedURL = root.appendingPathComponent("Beschädigt.mov")
        try bytes.prefix(bytes.count / 2).write(to: damagedURL)
        try manager.removeItem(at: front)
        if let damaged = try? await VideoDocument.open(damagedURL) {
            _ = try? AudioReader.peaks(for: damaged, token: CancelToken()) { _ in }
            let output = root.appendingPathComponent("Aus Beschädigt.mov")
            try? await Exporter.exportVideo(damaged, ranges: [damaged.bounds], to: output) { _ in }
            try? await Exporter.exportAudio(damaged, ranges: [damaged.bounds], format: .mp3,
                                            to: root.appendingPathComponent("Aus Beschädigt.mp3")) { _ in }
            check(true, "a damaged source does not crash the editor")
        } else {
            check(true, "a damaged source is refused")
        }
    }

    /// A portrait video stays upright when it is encoded anew: compared with AVFoundation's own picture.
    static func checkPortraitEffects(_ root: URL, _ upright: VideoDocument) async throws {
        step = "effects: portrait video"
        var edit = EditList(bounds: upright.bounds)
        edit.fadeOut = upright.ticks(seconds: 0.2)
        let output = root.appendingPathComponent("Hochkant mit Blende.mov")
        try await Exporter.exportEffects(upright, edit: edit, codec: .h264, to: output) { _ in }
        let track = try await AVURLAsset(url: output).loadTracks(withMediaType: .video)[0]
        let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
        equal(size, CGSize(width: 180, height: 320), "the portrait video is rendered upright")
        check(transform.isIdentity, "… and needs no rotation any more")
        let generator = AVAssetImageGenerator(asset: upright.asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let expected = grayPicture(try await generator.image(at: upright.time(upright.ticks(seconds: 0.5))).image)
        let actual = try await grayPictures(output)
        guard actual.count > 15 else {
            check(false, "the portrait video has its frames")
            return
        }
        for (x, y) in [(90, 40), (90, 280), (30, 160), (150, 160)] {
            check(abs(actual[15].value(x, y) - expected.value(x, y)) <= 12, "portrait: the picture at (\(x), \(y)) is upright",
                  "\(actual[15].value(x, y)) ≠ \(expected.value(x, y))")
        }
    }

    static func checkSDR(_ url: URL, _ name: String) async throws {
        let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)[0]
        guard let format = try await track.load(.formatDescriptions).first else { return }
        let primaries = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String
        let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        check(primaries == (kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String)
              && transfer == (kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String),
              "\(name): the video is marked as SDR (Rec. 709)", "\(primaries ?? "–") \(transfer ?? "–")")
    }

    /// A white box of 40 × 20 pixels.
    static func writeLogo(_ url: URL) throws {
        guard let context = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw ExportError.failed("logo")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.failed("logo") }
    }

    /// The green channel of a frame (the test pictures are grey).
    struct GrayPicture {
        let width: Int
        let height: Int
        let values: [UInt8]

        func value(_ x: Int, _ y: Int) -> Int { Int(values[min(height - 1, y) * width + min(width - 1, x)]) }

        func maximum(_ area: (x: Range<Int>, y: Range<Int>)? = nil) -> Int {
            let xs = area?.x ?? 0..<width, ys = area?.y ?? 0..<height
            var result = 0
            for y in ys.clamped(to: 0..<height) {
                for x in xs.clamped(to: 0..<width) { result = max(result, Int(values[y * width + x])) }
            }
            return result
        }
    }

    static func grayPictures(_ url: URL) async throws -> [GrayPicture] {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        reader.startReading()
        var pictures: [GrayPicture] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(image, .readOnly)
            let base = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(image)
            let w = CVPixelBufferGetWidth(image), h = CVPixelBufferGetHeight(image)
            var values = [UInt8](repeating: 0, count: w * h)
            for y in 0..<h {
                for x in 0..<w { values[y * w + x] = base[y * row + x * 4 + 1] }
            }
            CVPixelBufferUnlockBaseAddress(image, .readOnly)
            pictures.append(GrayPicture(width: w, height: h, values: values))
        }
        return pictures
    }

    static func grayPicture(_ image: CGImage) -> GrayPicture {
        let w = image.width, h = image.height
        var values = [UInt8](repeating: 0, count: w * h)
        values.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return GrayPicture(width: w, height: h, values: values)
    }

    // MARK: Test material

    /// 2026-05-01 12:30 UTC in the movie header: seconds since 1904.
    static let recordedDate = Date(timeIntervalSince1970: 1_777_638_600)
    static let recorded = UInt64(recordedDate.timeIntervalSince1970) + 2_082_844_800

    static func checkRecordingTime(_ url: URL, _ name: String) async throws {
        equal(try MovieHeader.creationTime(of: url), recorded, "\(name): the recording time in the movie header is kept")
        let date = try await AVURLAsset(url: url).load(.creationDate)?.load(.dateValue)
        equal(date, recordedDate, "\(name): AVFoundation reads the same recording date")
    }

    static func checkMetadata(_ url: URL, _ expected: [(key: AVMetadataIdentifier, value: String)], _ name: String) async throws {
        let metadata = try await AVURLAsset(url: url).load(.metadata)
        for (identifier, value) in expected {
            let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier).first
            equal(try await item?.load(.stringValue) ?? "–", value, "\(name): \(identifier.rawValue) is kept")
        }
    }

    static func checkCommonMetadata(_ url: URL, _ expected: [(key: AVMetadataKey, value: String)], _ name: String) async throws {
        let metadata = try await AVURLAsset(url: url).load(.commonMetadata)
        for (key, value) in expected {
            let item = AVMetadataItem.metadataItems(from: metadata, withKey: key, keySpace: .common).first
            equal(try await item?.load(.stringValue) ?? "–", value, "\(name): \(key.rawValue) is kept")
        }
    }

    /// Tags as converters write them into an MP4.
    static let mp4Metadata: [(key: AVMetadataIdentifier, value: String)] = [
        (.iTunesMetadataReleaseDate, "2026-05-01"),
        (.iTunesMetadataSongName, "Hochkant"),
    ]

    /// Recording date, place and camera as an iPhone stores them in a MOV.
    static let iPhoneMetadata: [(key: AVMetadataIdentifier, value: String)] = [
        (.quickTimeMetadataCreationDate, "2026-05-01T14:30:00+0200"),
        (.quickTimeMetadataLocationISO6709, "+52.5163+013.3777+034.000/"),
        (.quickTimeMetadataMake, "Apple"),
        (.quickTimeMetadataModel, "iPhone 17 Pro"),
    ]

    static func metadataItem(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }

    /// A video whose frames show their number (left half: tens of 16, right half: ones of 16) with
    /// an optional sound track: a 1 kHz beep in the first 0.1 s of every second.
    static func makeVideo(_ url: URL, frames: Int, keyInterval: Int, codec: AVVideoCodecType = .h264,
                          transform: CGAffineTransform = .identity, withAudio: Bool = true,
                          metadata: [AVMetadataItem] = []) async throws {
        let folder = url.deletingLastPathComponent()
        let videoURL = folder.appendingPathComponent("bild-\(UUID().uuidString.prefix(6)).mov")
        let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mov)
        var settings: [String: Any] = [AVVideoCodecKey: codec, AVVideoWidthKey: width, AVVideoHeightKey: height]
        if codec != .proRes422 {   // ProRes has only keyframes and no bit rate setting
            settings[AVVideoCompressionPropertiesKey] = [AVVideoMaxKeyFrameIntervalKey: keyInterval, AVVideoAverageBitRateKey: 4_000_000]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ExportError.failed("writer") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { throw ExportError.failed("pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(buffer)
            let coarse = UInt8(frame / 16 * 16), fine = UInt8(frame % 16 * 16)
            for y in 0..<height {
                for x in 0..<width {
                    let value = x < width / 2 ? coarse : fine
                    let pixel = base + y * row + x * 4
                    pixel[0] = value; pixel[1] = value; pixel[2] = value; pixel[3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: fps)) else {
                throw writer.error ?? ExportError.failed("append")
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ExportError.failed("finish") }
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let composition = AVMutableComposition()
        let duration = CMTime(value: Int64(frames), timescale: fps)
        let picture = AVURLAsset(url: videoURL)
        let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration),
                                       of: try await picture.loadTracks(withMediaType: .video)[0], at: .zero)
        videoTrack.preferredTransform = transform
        var soundURL: URL?
        if withAudio {
            let audioURL = folder.appendingPathComponent("ton-\(UUID().uuidString.prefix(6)).m4a")
            soundURL = audioURL
            try writeBeeps(audioURL, seconds: duration.seconds)
            let sound = AVURLAsset(url: audioURL)
            let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration),
                                           of: try await sound.loadTracks(withMediaType: .audio)[0], at: .zero)
        }
        defer { if let soundURL { try? FileManager.default.removeItem(at: soundURL) } }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw ExportError.failed("session")
        }
        session.metadata = metadata
        try await session.export(to: url, as: VideoDocument.fileType(for: url))
    }

    static func writeBeeps(_ url: URL, seconds: Double) throws {
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let count = Int(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for frame in 0..<count {
            let time = Double(frame) / sampleRate
            let value = time.truncatingRemainder(dividingBy: 1) < 0.1 ? Float(0.5 * sin(2 * .pi * 1000 * time)) : 0
            buffer.floatChannelData![0][frame] = value
            buffer.floatChannelData![1][frame] = value
        }
        try file.write(from: buffer)
    }

    /// The frame numbers shown by the frames of a video, in display order.
    static func frameNumbers(_ url: URL) async throws -> [Int] {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        reader.startReading()
        var numbers: [Int] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(image, .readOnly)
            let base = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(image)
            let w = CVPixelBufferGetWidth(image), h = CVPixelBufferGetHeight(image)
            let left = Double(base[h / 2 * row + w / 4 * 4 + 1]), right = Double(base[h / 2 * row + w * 3 / 4 * 4 + 1])
            CVPixelBufferUnlockBaseAddress(image, .readOnly)
            numbers.append(Int((left / 16).rounded()) * 16 + Int((right / 16).rounded()))
        }
        return numbers
    }

    /// The sound of a video as mono samples (48 kHz) from time 0.
    static func samples(of url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .audio)[0]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        reader.startReading()
        var result: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            let start = Int((CMSampleBufferGetPresentationTimeStamp(sample).seconds * sampleRate).rounded())
            if start > result.count { result += [Float](repeating: 0, count: start - result.count) }
            guard let data = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(data)
            var chunk = [Float](repeating: 0, count: length / 4)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            result += chunk
        }
        return result
    }

    static func readAll(_ file: AVAudioFile) throws -> [Float] {
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let channel = buffer.floatChannelData![0]
        let factor = file.processingFormat.sampleRate / sampleRate
        // Resampled to 48 kHz positions by picking (the files here are all 48 kHz).
        return (0..<Int(Double(buffer.frameLength) / factor)).map { channel[Int(Double($0) * factor)] }
    }

    static func rms(_ samples: [Float], from start: Double, to end: Double) -> Double {
        let first = max(0, Int(start * sampleRate)), last = min(samples.count, Int(end * sampleRate))
        guard last > first else { return 0 }
        let sum = samples[first..<last].reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sum / Double(last - first)).squareRoot()
    }
}
