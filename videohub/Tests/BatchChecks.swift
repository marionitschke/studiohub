// Batch checks: titles from file names, loudness measurement (EBU R128) and limiter, file names in
// the destination folder, and a whole batch run on a generated video (fades, title, watermark,
// normalised sound, preview the same as the export, cancelling).
import AppKit
import AVFoundation
import Foundation

extension Checks {
    // MARK: Titles, folders, watermark

    static func batch() {
        let titles: [(file: String, title: String)] = [
            ("Heaven Shall Burn 17.10.03 Emil in Zittau +tokka video+.mp4", "HEAVEN SHALL BURN\n17.10.03 EMIL IN ZITTAU"),
            ("Narziß 29.12.06 Kaff-Cafe in Reihenfelden +tokka video+.mp4", "NARZISS\n29.12.06 KAFF-CAFE IN REIHENFELDEN"),
            ("Axt am 21.02.04 in Hammerstadt_analog +tokka video+.mp4", "AXT\nAM 21.02.04 IN HAMMERSTADT ANALOG"),
            ("Liar 1999 Basta in Görlitz +tokka video+.mp4", "LIAR\n1999 BASTA IN GÖRLITZ"),
            ("100 Demons 13.10.2004 Conne Island in Leipzig +tokka video+.mp4", "100 DEMONS\n13.10.2004 CONNE ISLAND IN LEIPZIG"),
            ("Ravelin 7 29.09.07 Emil in Zittau +tokka video+.mp4", "RAVELIN 7\n29.09.07 EMIL IN ZITTAU"),
            ("Black Friday '29 18.12.05 Kato in Berlin.mov", "BLACK FRIDAY '29\n18.12.05 KATO IN BERLIN"),
            ("Narziß 18.02.05  Scheune in Dresden +tokka video+.mp4", "NARZISS\n18.02.05 SCHEUNE IN DRESDEN"),
            ("H.O.L.Z. Konzert.mov", "H.O.L.Z. KONZERT"),
            ("Konzert [HD] - .mp4", "KONZERT"),
            ("2005.mp4", "2005"),
            ("+tokka video+.mp4", "+TOKKA VIDEO+"),
            ("Mo\u{0308}rser 07.04.07 Kommärzbanck.m4v", "MÖRSER\n07.04.07 KOMMÄRZBANCK"),
        ]
        for (file, title) in titles {
            equal(BatchRecipe.title(forFile: URL(fileURLWithPath: "/Videos/\(file)")), title, "title of \"\(file)\"")
        }

        let folder = URL(fileURLWithPath: "/Ziel")
        let names = BatchRecipe.destinations(for: [
            URL(fileURLWithPath: "/a/Konzert.mov"), URL(fileURLWithPath: "/a/Konzert.mp4"), URL(fileURLWithPath: "/a/konzert.m4v"),
            URL(fileURLWithPath: "/a/Mörser.mov"), URL(fileURLWithPath: "/a/Mo\u{0308}rser.mp4"), URL(fileURLWithPath: "/a/Andere.mov"),
        ], in: folder, format: .mp4).map(\.lastPathComponent)
        equal(names, ["Konzert.mp4", "Konzert 2.mp4", "konzert 3.mp4", "Mörser.mp4", "Mo\u{0308}rser 2.mp4", "Andere.mp4"],
              "results get the format's extension, a number where two would share a name")
        equal(BatchRecipe.destinations(for: [URL(fileURLWithPath: "/a/Konzert.mp4")], in: folder, format: .mov).map(\.path),
              ["/Ziel/Konzert.mov"], "a result lands in the destination folder")

        check(BurnedInLogo.Score(left: 0.2, right: 0).hasLogo, "edges that stay in the bottom left corner are a logo")
        check(!BurnedInLogo.Score(left: 0.2, right: 0.1).hasLogo, "edges that stay in both corners are a still scene")
        check(!BurnedInLogo.Score(left: 0.01, right: 0).hasLogo, "a few edges that stay are no logo")
        var item = BatchItem(source: URL(fileURLWithPath: "/a/Konzert.mp4"), destination: URL(fileURLWithPath: "/Ziel/Konzert.mp4"), title: "KONZERT")
        equal(item.getsWatermark, nil, "before the check it is open whether a video gets the watermark")
        item.hasLogo = true
        equal(item.getsWatermark, false, "a video with a logo of its own gets no watermark")
        item.watermarkChoice = true
        equal(item.getsWatermark, true, "the choice in the list wins over the check")
    }

    static func batchFiles(_ root: URL) throws {
        step = "batch: folders"
        let folder = root.appendingPathComponent("Ordner")
        let manager = FileManager.default
        try manager.createDirectory(at: folder.appendingPathComponent("Unterordner"), withIntermediateDirectories: true)
        try manager.createDirectory(at: folder.appendingPathComponent("Ordner.mov"), withIntermediateDirectories: true)
        for name in ["Clip 10.mov", "Clip 2.mp4", "Clip 1.m4v", "Notizen.txt", ".versteckt.mp4", "Unterordner/Tief.mp4", "Bild.png"] {
            try Data().write(to: folder.appendingPathComponent(name))
        }
        equal(try BatchRecipe.videos(in: folder).map(\.lastPathComponent), ["Clip 1.m4v", "Clip 2.mp4", "Clip 10.mov"],
              "the batch takes the videos directly in the folder, sorted like the Finder")
        let link = root.appendingPathComponent("Verweis")
        try manager.createSymbolicLink(at: link, withDestinationURL: folder)
        check(BatchRecipe.sameFolder(folder, link), "a folder and a link to it are the same folder")
        check(BatchRecipe.sameFolder(folder, folder.appendingPathComponent("Unterordner/..")), "a path with .. is the same folder")
        check(!BatchRecipe.sameFolder(folder, folder.appendingPathComponent("Unterordner")), "a subfolder is another folder")

        step = "batch: watermark"
        let logo = root.appendingPathComponent("Zeichen.png")
        try writeLogo(logo)
        var settings = BatchSettings()
        settings.watermark = logo
        for canvas in [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920)] {
            guard let placed = BatchRecipe.watermark(settings, canvas: canvas) else {
                check(false, "the watermark is placed on \(canvas)")
                continue
            }
            let canvasWidth = Double(canvas.width), canvasHeight = Double(canvas.height), name = "\(Int(canvasWidth)) × \(Int(canvasHeight))"
            let width: Double = placed.width * canvasWidth
            let left: Double = (placed.x - placed.width / 2) * canvasWidth
            let bottom: Double = (1 - placed.y) * canvasHeight - width / 4
            near(width, 237.6, 0.01, "watermark on \(name): width from the shorter side")
            near(left, 43.2, 0.01, "watermark on \(name): margin to the left")
            near(bottom, 43.2, 0.01, "watermark on \(name): margin to the bottom")
            near(placed.opacity, 0.7, 0.0001, "watermark on \(name): the opacity of the settings")
        }
        settings.watermark = root.appendingPathComponent("fehlt.png")
        check(BatchRecipe.watermark(settings, canvas: CGSize(width: 1920, height: 1080)) == nil, "no watermark without its image")

        // The visible part of a picture with transparent margins: 20 px left, 10 px top.
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: 100, height: 50, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 20, y: 50 - 10 - 20, width: 40, height: 20))
        equal(LogoStore.visibleBox(of: context.makeImage()!), CGRect(x: 20, y: 10, width: 40, height: 20),
              "transparent margins of a watermark are cut away (rows from the top)")
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 50))
        check(LogoStore.visibleBox(of: context.makeImage()!) == nil, "nothing to cut on a picture without transparent margins")
    }

    // MARK: Loudness

    /// Float buffers of 3000 frames (not a multiple of the 100 ms sub-block) with `signal(frame)` on every channel.
    static func pcm(seconds: Double, rate: Double = 48_000, channels: Int = 2, _ signal: (Int) -> Float) -> [AVAudioPCMBuffer] {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: AVAudioChannelCount(channels), interleaved: false)!
        let total = Int(seconds * rate)
        return stride(from: 0, to: total, by: 3000).map { start in
            let count = min(3000, total - start)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            for frame in 0..<count {
                let value = signal(start + frame)
                for channel in 0..<channels { buffer.floatChannelData![channel][frame] = value }
            }
            return buffer
        }
    }

    static func sine(_ amplitude: Double, rate: Double = 48_000) -> (Int) -> Float {
        { Float(amplitude * sin(2 * .pi * 1000 * Double($0) / rate)) }
    }

    static func measure(_ buffers: [AVAudioPCMBuffer]) -> (lufs: Double?, peak: Float) {
        let format = buffers[0].format
        var meter = LoudnessMeter(sampleRate: format.sampleRate, channels: Int(format.channelCount))
        for buffer in buffers { meter.add(buffer) }
        return (meter.integrated, meter.peak)
    }

    /// Runs buffers through a normaliser, the held-back tail included; the first channel.
    static func normalized(_ normalizer: LoudnessNormalizer, _ buffers: [AVAudioPCMBuffer]) -> [Float] {
        let format = buffers[0].format
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        var result: [Float] = []
        for buffer in buffers {
            let count = normalizer.process(buffer, into: output)
            result += UnsafeBufferPointer(start: output.floatChannelData![0], count: count)
        }
        let tail = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(normalizer.flushCapacity))!
        let count = normalizer.flush(into: tail)
        result += UnsafeBufferPointer(start: tail.floatChannelData![0], count: count)
        return result
    }

    static func peak(_ samples: [Float], from start: Double = 0, to end: Double = .infinity, rate: Double = 48_000) -> Float {
        let first = max(0, Int(start * rate)), last = min(samples.count, end == .infinity ? samples.count : Int(end * rate))
        return last > first ? samples[first..<last].reduce(0) { max($0, abs($1)) } : 0
    }

    static func loudness() {
        // BS.1770: a 1 kHz tone at −20 dBFS on both channels is −20 LUFS; mono counts as dual mono.
        for rate in [44_100.0, 48_000.0] {
            for channels in [1, 2] {
                let tone = measure(pcm(seconds: 5, rate: rate, channels: channels, sine(0.1, rate: rate)))
                near(tone.lufs ?? 0, -20, 0.05, "loudness of a tone at −20 dBFS (\(channels) channel(s), \(Int(rate)) Hz)")
            }
        }
        let tone = measure(pcm(seconds: 10, sine(0.1)) + pcm(seconds: 10) { _ in 0 })
        near(tone.lufs ?? 0, -20, 0.1, "silence after the music does not count (absolute gate)")
        near(Double(tone.peak), 0.1, 0.001, "the meter finds the peak")
        let quieter = sine(0.003)
        let gated = measure(pcm(seconds: 10, sine(0.1)) + pcm(seconds: 10) { quieter($0 + 480_000) })
        near(gated.lufs ?? 0, -20, 0.15, "passages far below the rest do not count (relative gate)")
        let even = measure(pcm(seconds: 10, sine(0.1)) + pcm(seconds: 10, sine(0.05)))
        check((even.lufs ?? 0) < -20.5 && (even.lufs ?? 0) > -23.5, "a passage 6 dB lower counts", "\(even.lufs ?? 0)")
        equal(measure(pcm(seconds: 5) { _ in 0 }).lufs, nil, "silence has no loudness")
        equal(measure(pcm(seconds: 0.3, sine(0.1))).lufs, nil, "less than 400 ms of sound has no loudness")

        let ceiling = Float(pow(10, SoundNormalizer.ceiling / 20))
        let impulse = normalized(LoudnessNormalizer(gain: 1, ceiling: ceiling, sampleRate: 48_000, channels: 2),
                                 pcm(seconds: 1) { $0 == 10_000 ? 0.5 : 0 })
        equal(impulse.count, 48_000, "the limiter gives back every frame, the held-back ones included")
        let loudest: Int = impulse.indices.max { abs(impulse[$0]) < abs(impulse[$1]) } ?? -1
        equal(loudest, 10_000, "the limiter does not shift the sound")
        near(Double(impulse[10_000]), 0.5, 0.001, "a sample below the ceiling stays as it is")

        let doubled = LoudnessNormalizer(gain: 2, ceiling: ceiling, sampleRate: 48_000, channels: 1)
        let louder = normalized(doubled, pcm(seconds: 1, channels: 1, sine(0.1)))
        near(Double(peak(louder, from: 0.5)), 0.2, 0.002, "the gain is applied")
        equal(doubled.deepestReduction, 1, "below the ceiling the limiter does nothing")

        let loud = LoudnessNormalizer(gain: 4, ceiling: ceiling, sampleRate: 48_000, channels: 2)
        let limited = normalized(loud, pcm(seconds: 1, sine(0.5)))
        check(peak(limited) <= ceiling * 1.0001, "the limiter keeps every sample below the ceiling", "\(peak(limited)) > \(ceiling)")
        check(peak(limited, from: 0.5) > ceiling * 0.97, "a loud passage is held just below the ceiling", "\(peak(limited, from: 0.5))")
        check(loud.deepestReduction < 0.45 && loud.peak <= ceiling * 1.0001, "the limiter reports how far it went down",
              "\(loud.deepestReduction) \(loud.peak)")

        let quiet = sine(0.05), blast = sine(0.95)
        func burst(_ frame: Int) -> Float { (24_000..<48_000).contains(frame) ? blast(frame) : quiet(frame) }
        let sudden = normalized(LoudnessNormalizer(gain: 1, ceiling: ceiling, sampleRate: 48_000, channels: 2), pcm(seconds: 2, burst))
        check(peak(sudden) <= ceiling * 1.0001, "the look-ahead catches a sudden loud passage", "\(peak(sudden))")
        near(Double(peak(sudden, from: 0, to: 0.49)), 0.05, 0.001, "before the loud passage the sound is untouched")
        near(Double(peak(sudden, from: 1.6)), 0.05, 0.001, "after the loud passage the limiter recovers")

        let offset = sine(0.1)
        let centred = normalized(LoudnessNormalizer(gain: 1, ceiling: ceiling, sampleRate: 48_000, channels: 1),
                                 pcm(seconds: 2, channels: 1) { 0.3 + offset($0) })
        let tail = centred[72_000...]
        near(Double(tail.reduce(0, +)) / Double(tail.count), 0, 0.002, "an offset (DC) is removed")
        near(Double(peak(centred, from: 1.5)), 0.1, 0.003, "the sound itself stays when an offset is removed")
    }

    // MARK: A batch run

    /// Progress reports of a batch run, from the export's threads.
    final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(BatchProcessor.Phase, Double)] = []

        func add(_ phase: BatchProcessor.Phase, _ value: Double) { lock.withLock { entries.append((phase, value)) } }
        var all: [(BatchProcessor.Phase, Double)] { lock.withLock { entries } }
    }

    static func batchExports(_ root: URL) async throws {
        let folder = root.appendingPathComponent("Stapel"), output = folder.appendingPathComponent("Ziel")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        step = "batch: test video"
        // 12 s, frames as numbers, a beep (−6 dBFS) in the first 0.1 s of every second.
        let source = folder.appendingPathComponent("Band 12.11.26 Halle +tokka video+.mov")
        try await makeVideo(source, frames: 360, keyInterval: 30)
        let document = try await VideoDocument.open(source)
        let title = BatchRecipe.title(forFile: source)
        equal(BatchRecipe.titleRange(document), document.ticks(seconds: 1)..<document.ticks(seconds: 9), "batch: the title runs from 1 s to 9 s")
        equal(BatchRecipe.previewPosition(document), document.ticks(seconds: 5), "batch: the preview shows the middle of the title")

        step = "batch: sound"
        let soundURL = folder.appendingPathComponent("Ton.m4a")
        let sound = try await SoundNormalizer.normalize(document, to: soundURL, token: CancelToken()) { _ in }
        if let sound, let measured = sound.measured {
            near(sound.gain, SoundNormalizer.target - measured, 0.0001, "batch: the gain brings the sound to −16 LUFS")
            equal(sound.limited, 0, "batch: the beeps need no limiter")
            // The AAC of the test video overshoots its −6 dBFS a little.
            let peak: Double = 20 * log10(0.5) + sound.gain
            near(sound.peak, peak, 0.6, "batch: the peak after normalising")
        } else {
            check(false, "batch: the sound is measured", "\(String(describing: sound))")
        }
        let file = try AVAudioFile(forReading: soundURL)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let original = try await samples(of: source)
        // Read through a composition, the AAC loses its last 2112 frames (the encoder delay), as in the sound export.
        near(Double(buffer.frameLength), Double(original.count), 2200, "batch: the normalised sound is as long as the original")
        let normalisedLoudness = measure([buffer]).lufs ?? 0
        near(normalisedLoudness, SoundNormalizer.target, 0.2, "batch: the normalised sound measures −16 LUFS")
        let channel = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let onset = channel[Int(2.9 * sampleRate)...].firstIndex { abs($0) > 0.05 } ?? 0
        near(Double(onset) / sampleRate, 3.0, 0.002, "batch: the normalised sound stays in sync")

        step = "batch: run"
        let logo = folder.appendingPathComponent("Wasserzeichen.png")
        try writeLogo(logo)
        var settings = BatchSettings()
        settings.watermark = logo
        let destination = BatchRecipe.destinations(for: [source], in: output, format: settings.format)[0]
        let log = ProgressLog()
        let processed = try await BatchProcessor.process(source, title: title, to: destination, settings: settings) { log.add($0, $1) }
        // Decoding the AAC twice differs in the last digits.
        check(processed != nil && abs((processed?.gain ?? 0) - (sound?.gain ?? 1)) < 0.001 && processed?.limited == sound?.limited,
              "batch: the run normalises the sound the same way", "\(String(describing: processed)) vs. \(String(describing: sound))")
        let phases = log.all, values = phases.map(\.1)
        let forward = zip(values, values.dropFirst()).allSatisfy { $0 <= $1 + 0.0001 }
        // The export reports every 0.1 s, so the last report can be anywhere near the end.
        let firstVideo = phases.firstIndex { $0.0 == .video } ?? phases.count
        let sequence = firstVideo > 0 && firstVideo < phases.count && !phases[firstVideo...].contains { $0.0 == .sound }
        let backwards = zip(values, values.dropFirst()).filter { $0 > $1 + 0.0001 }.map { "\($0) → \($1)" }
        check(sequence && forward, "batch: progress runs from the sound to the video, never backwards",
              "\(phases.count) reports, \(backwards.prefix(5))")
        equal(try FileManager.default.contentsOfDirectory(atPath: output.path), [destination.lastPathComponent],
              "batch: only the result is in the destination folder")
        let result = try await VideoDocument.open(destination)
        check(result.summary.hasPrefix("H.264 · 320 × 180 · 30 fps"), "batch: H.264 in the size and rate of the source", result.summary)
        near(result.seconds(result.bounds.upperBound), 12, 0.001, "batch: the length stays")
        try await checkSDR(destination, "batch")

        let pictures = try await grayPictures(destination)
        equal(pictures.count, 360, "batch: every frame is there")
        if pictures.count == 360 {
            check(pictures[0].maximum() < 12, "batch: the video starts black", "\(pictures[0].maximum())")
            check(pictures[359].maximum() < 12, "batch: the video ends black", "\(pictures[359].maximum())")
            // On the right frame 22 (0.73 s, half way into the fade in) shows 96, frames 60 and 300 192; the fade out starts at 10.5 s.
            let fading = pictures[22].value(280, 40)
            check(fading > 10 && fading < 80, "batch: the picture fades in", "\(fading)")
            near(Double(pictures[60].value(280, 40)), 192, 8, "batch: after the fade in the picture is as bright as before")
            near(Double(pictures[300].value(280, 40)), 192, 8, "batch: before the fade out the picture is as bright as before")
            check(pictures[345].value(280, 40) < 110, "batch: the picture fades out", "\(pictures[345].value(280, 40))")

            // The left half of frame 20 (before the title), 40 (fading in), 150 (full) and 276 (gone) is dark.
            let centre = (x: 100..<158, y: 70..<110)
            check(pictures[20].maximum(centre) < 40, "batch: no title before 1 s", "\(pictures[20].maximum(centre))")
            let fadingTitle = pictures[40].maximum(centre)
            check(fadingTitle > 60 && fadingTitle < 215, "batch: the title fades in", "\(fadingTitle)")
            check(pictures[150].maximum(centre) > 230, "batch: the title is in the middle", "\(pictures[150].maximum(centre))")
            check(pictures[150].maximum((x: 100..<158, y: 0..<50)) < 150, "batch: nothing is drawn above the title")
            check(pictures[276].maximum(centre) < 40, "batch: the title is gone after 9 s", "\(pictures[276].maximum(centre))")

            // The watermark (40 × 20 at 22 % of 180 px, 7 px from the edges) over the dark frame 276.
            let mark = pictures[276].value(27, 163)
            check(mark > 150 && mark < 245, "batch: the watermark is at the bottom left, partly transparent", "\(mark)")
            check(pictures[276].value(27, 30) < 40 && pictures[276].value(70, 163) < 40 && pictures[276].value(27, 177) < 40,
                  "batch: the watermark stays in its place")
            check(pictures[150].value(27, 163) > 200, "batch: the watermark is there all the time", "\(pictures[150].value(27, 163))")

            step = "batch: preview"
            let edit = BatchRecipe.edit(for: document, title: title, settings: settings)
            let renderer = EffectRenderer(document: document, content: EffectContent(edit: edit, layout: edit.effectLayout(frame: document.frameTicks)))
            let frame = try await BatchRecipe.previewFrame(document)
            if let image = BatchRecipe.preview(frame, document: document, renderer: renderer) {
                let preview = grayPicture(image), exported = pictures[150]
                equal(preview.width * 1000 + preview.height, 320 * 1000 + 180, "batch: the preview has the size of the video")
                func bright(_ picture: GrayPicture) -> Int {
                    var count = 0
                    for y in centre.y {
                        for x in 60..<260 where picture.value(x, y) > 230 { count += 1 }
                    }
                    return count
                }
                let previewText = bright(preview), exportedText = bright(exported)
                check(previewText > 50 && abs(previewText - exportedText) < max(20, exportedText / 5),
                      "batch: the preview shows the title like the export", "\(previewText) vs. \(exportedText) bright pixels")
                near(Double(preview.value(27, 163)), Double(exported.value(27, 163)), 12, "batch: the preview shows the watermark like the export")
            } else {
                check(false, "batch: the preview is drawn")
            }
        }

        let samples = try await samples(of: destination)
        let beep = rms(samples, from: 5.01, to: 5.08)
        let gain: Double = sound?.gain ?? 0
        let expected: Double = rms(original, from: 5.01, to: 5.08) * pow(10.0, gain / 20)
        near(beep / expected, 1, 0.05, "batch: the sound of the result is normalised")
        check(rms(samples, from: 0, to: 0.08) < expected * 0.15, "batch: the sound fades in", "\(rms(samples, from: 0, to: 0.08))")
        check(rms(samples, from: 11.01, to: 11.08) < expected * 0.8, "batch: the sound fades out", "\(rms(samples, from: 11.01, to: 11.08))")

        step = "batch: logo already there"
        check(!(try await BurnedInLogo.detect(document).hasLogo), "batch: the test video has no logo of its own")
        let again = try await VideoDocument.open(destination)
        let score = try await BurnedInLogo.detect(again)
        check(score.hasLogo, "batch: a video with a watermark burned in is recognised", "\(score)")
        check(BatchRecipe.edit(for: document, title: title, settings: settings, watermark: false).logo == nil,
              "batch: without the watermark the edit has no logo")

        step = "batch: no sound"
        let silent = folder.appendingPathComponent("Stumm 2001.mov")
        try await makeVideo(silent, frames: 60, keyInterval: 30, withAudio: false)
        let silentDocument = try await VideoDocument.open(silent)
        equal(BatchRecipe.titleRange(silentDocument), silentDocument.ticks(seconds: 0.2)..<silentDocument.ticks(seconds: 1.8),
              "batch: in a short video the title stays within the first and last tenth")
        let silentResult = output.appendingPathComponent("Stumm 2001.mp4")
        let silentSound = try await BatchProcessor.process(silent, title: "STUMM\n2001", watermark: false, to: silentResult,
                                                           settings: settings) { _, _ in }
        check(silentSound == nil, "batch: a video without sound needs no normalising")
        let silentPictures = try await grayPictures(silentResult)
        check(silentPictures.count == 60 && silentPictures[30].value(27, 163) < 40, "batch: a video with a logo of its own gets no watermark")
        let silentTracks = try await AVURLAsset(url: silentResult).loadTracks(withMediaType: .audio)
        check(silentTracks.isEmpty, "batch: a video without sound stays without sound")

        step = "batch: cancel"
        let cancelled = output.appendingPathComponent("Abgebrochen.mp4")
        let cancelLog = ProgressLog()
        let run = Task {
            try await BatchProcessor.process(source, title: title, to: cancelled, settings: settings) { cancelLog.add($0, $1) }
        }
        while !cancelLog.all.contains(where: { $0.0 == .video }) {
            try await Task.sleep(nanoseconds: 5_000_000)
            if cancelLog.all.count > 100_000 { break }
        }
        run.cancel()
        if case .success = await run.result { check(false, "batch: a cancelled video does not finish") }
        check(!FileManager.default.fileExists(atPath: cancelled.path), "batch: a cancelled video leaves no result")
        let hidden = try FileManager.default.contentsOfDirectory(atPath: output.path).filter { $0.hasPrefix(".") }
        equal(hidden, [], "batch: no temporary files are left behind")
    }
}
