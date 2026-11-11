import AVFoundation
import Darwin
import Foundation

/// Scoring for `TranscriptionBenchmark`. Pure, so the numbers can be trusted.
enum TranscriptScore {
    /// Lowercased, no punctuation, apostrophes and hyphens split, accents kept.
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// Word-level Levenshtein distance.
    static func edits(_ hypothesis: [String], _ reference: [String]) -> Int {
        guard !reference.isEmpty else { return hypothesis.count }
        var row = Array(0...reference.count)
        for (i, word) in hypothesis.enumerated() {
            var diagonal = row[0]
            row[0] = i + 1
            for (j, target) in reference.enumerated() {
                let above = row[j + 1]
                row[j + 1] = min(above + 1, row[j] + 1, diagonal + (word == target ? 0 : 1))
                diagonal = above
            }
        }
        return row[reference.count]
    }

    static func contains(_ term: String, in text: String) -> Bool {
        let needle = words(term)
        let haystack = words(text)
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        return (0...(haystack.count - needle.count)).contains {
            Array(haystack[$0..<($0 + needle.count)]) == needle
        }
    }

    /// Listed terms written where the reference does not have them.
    static func falseInsertions(vocabulary: [String], text: String, expected: String) -> Int {
        vocabulary.filter { contains($0, in: text) && !contains($0, in: expected) }.count
    }

    /// The value at `fraction` of the sorted list. Nil for an empty list.
    static func percentile(_ values: [Int], _ fraction: Double) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count) * fraction).rounded(.down)))]
    }
}

/// Hidden developer mode: scores the real engines and gate on a manifest of clips,
/// then exits, before any app state exists. See Docs/research/transcription-benchmark.md.
///
/// `MODICT_BENCH_MANIFEST=manifest.json MODICT_BENCH_OUT=results.jsonl`, optionally
/// `MODICT_BENCH_MODEL` and `MODICT_BENCH_PASSES`. Never cloud, never the microphone,
/// never a model download. Transcripts go only to the output path asked for.
enum TranscriptionBenchmark {

    struct Manifest: Decodable {
        struct Clip: Decodable {
            let id: String
            let audio: String
            var expected: String?
            var expected_terms: [String]?
            var group: String?
            var expect_speech: Bool?
        }
        var language: String?
        var vocabulary: [String]?
        let clips: [Clip]
    }

    private struct ClipRow: Encodable {
        let kind = "clip"
        let id: String
        let group: String
        let gate: String
        let text: String
        let ms: [Int]
        let edits: Int
        let ref_words: Int
        let terms_found: Int
        let terms_expected: Int
        let false_insertions: Int
    }

    private struct LoadRow: Encodable {
        let kind = "load"
        let load_ms: Int
        let reload_ms: Int
        let loaded_mb: Int
        let after_decodes_mb: Int
        let unloaded_mb: Int
    }

    /// One clip played to the live preview at the speed it was spoken.
    private struct PreviewRow: Encodable {
        let kind = "preview"
        let id: String
        let expect_speech: Bool
        let audio_s: Double
        let updates: Int
        let first_update_ms: Int?
        let longest_gap_ms: Int
        /// Words of the last preview that the final text does not keep.
        let edits_to_final: Int
        let final_words: Int
        let last_preview: String
    }

    private struct SummaryRow: Encodable {
        let kind = "summary"
        let group: String
        let clips: Int
        let wer_percent: Double?
        let edits: Int
        let ref_words: Int
        let term_recall: String
        let false_insertions: Int
        let no_speech_clips: Int
        let no_speech_with_text: Int
        let speech_clips_rejected_by_gate: Int
        let p50_ms: Int?
        let p95_ms: Int?
        let max_ms: Int?
        let peak_footprint_mb: Int
    }

    /// Returns the process exit code.
    static func run(manifestPath: String, environment: [String: String]) async -> Int32 {
        do {
            try await execute(manifestPath: manifestPath, environment: environment)
            return EXIT_SUCCESS
        } catch {
            FileHandle.standardError.write(Data("benchmark: \(error)\n".utf8))
            return EXIT_FAILURE
        }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func execute(manifestPath: String, environment: [String: String]) async throws {
        let manifestURL = URL(fileURLWithPath: manifestPath)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        guard let outPath = environment["MODICT_BENCH_OUT"] else {
            throw Failure(description: "MODICT_BENCH_OUT is required")
        }
        let passes = max(1, Int(environment["MODICT_BENCH_PASSES"] ?? "") ?? 3)
        let gate = SpeechGate()
        await gate.prepare()
        await gate.waitForLoad()

        let loadStarted = ContinuousClock.now
        let engine = try await loadEngine(
            named: environment["MODICT_BENCH_MODEL"] ?? SpeechModel.parakeetV3.rawValue, gate: gate)
        let loadMilliseconds = milliseconds(since: loadStarted)
        let loadedFootprint = footprintMegabytes(peak: false)
        let vocabulary = manifest.vocabulary ?? []
        await engine.setVocabularyHints(vocabulary)

        FileManager.default.createFile(atPath: outPath, contents: nil, attributes: [.posixPermissions: 0o600])
        let out = try FileHandle(forWritingTo: URL(fileURLWithPath: outPath))
        defer { try? out.close() }
        func write<T: Encodable>(_ row: T) throws {
            try out.write(contentsOf: JSONEncoder().encode(row) + Data("\n".utf8))
        }

        let base = manifestURL.deletingLastPathComponent()
        var rows: [(clip: Manifest.Clip, row: ClipRow)] = []
        var isFirstClip = true
        for clip in manifest.clips {
            let samples = try loadAudio(base.appendingPathComponent(clip.audio))
            let verdict = await gate.evaluate(samples)
            if isFirstClip {
                // Warm-up, excluded: the first decode pays one-time placement costs.
                _ = try await engine.transcribe(samples, languageHint: manifest.language)
                isFirstClip = false
            }
            var text = ""
            var times: [Int] = []
            if case .speech = verdict {
                for _ in 0..<passes {
                    let started = ContinuousClock.now
                    let result = try await engine.transcribe(samples, languageHint: manifest.language)
                    times.append(milliseconds(since: started))
                    text = TranscriptSanitizer.clean(result.text)
                }
            }
            let reference = TranscriptScore.words(clip.expected ?? "")
            let terms = clip.expected_terms ?? []
            let row = ClipRow(
                id: clip.id,
                group: clip.group ?? "all",
                gate: label(verdict),
                text: text,
                ms: times,
                edits: TranscriptScore.edits(TranscriptScore.words(text), reference),
                ref_words: reference.count,
                terms_found: terms.filter { TranscriptScore.contains($0, in: text) }.count,
                terms_expected: terms.count,
                false_insertions: TranscriptScore.falseInsertions(
                    vocabulary: vocabulary, text: text, expected: clip.expected ?? ""))
            rows.append((clip, row))
            try write(row)
        }

        if environment["MODICT_BENCH_PREVIEW"] == "1" {
            for (clip, row) in rows {
                let samples = try loadAudio(base.appendingPathComponent(clip.audio))
                try write(await preview(of: samples, id: clip.id, finalText: row.text,
                                        expectSpeech: clip.expect_speech != false,
                                        language: manifest.language, engine: engine))
            }
        }

        // What keeping the model costs, and what releasing it between dictations
        // would: memory while loaded and after a decode, then after unloading, and
        // the time to load it again.
        let afterDecodes = footprintMegabytes(peak: false)
        await engine.unload()
        // MLX hands its buffers back a moment after the last reference goes.
        try await Task.sleep(for: .seconds(2))
        let unloaded = footprintMegabytes(peak: false)
        let reloadStarted = ContinuousClock.now
        try await engine.prepare { _ in }
        await engine.wake()
        try write(LoadRow(
            load_ms: loadMilliseconds, reload_ms: milliseconds(since: reloadStarted),
            loaded_mb: loadedFootprint, after_decodes_mb: afterDecodes, unloaded_mb: unloaded))

        let groups = Dictionary(grouping: rows, by: \.row.group)
        for name in groups.keys.sorted() {
            try write(summary(name, groups[name] ?? []))
        }
        try write(summary("overall", rows))
    }

    /// Feeds the clip to a streaming session in 100 ms chunks, in real time, the way
    /// the microphone does, and records what the preview showed.
    private static func preview(
        of samples: [Float], id: String, finalText: String, expectSpeech: Bool, language: String?,
        engine: any TranscriptionEngine
    ) async -> PreviewRow {
        let log = PreviewLog()
        let started = ContinuousClock.now
        let session = engine.startStreamingSession(languageHint: language) { partial in
            let text = [partial.confirmedText, partial.volatileText]
                .filter { !$0.isEmpty }.joined(separator: " ")
            log.add(text, at: milliseconds(since: started))
        }
        let chunk = 1_600
        var offset = 0
        while offset < samples.count {
            session?.feed(Array(samples[offset..<min(offset + chunk, samples.count)]))
            offset += chunk
            let due = started + .milliseconds(offset / 16)
            try? await Task.sleep(until: due, clock: .continuous)
        }
        // The app cancels the preview at release; a last decode may still land.
        try? await Task.sleep(for: .milliseconds(1_200))
        await session?.cancel()
        let (texts, times) = log.snapshot()
        var longestGap = 0
        for index in times.indices.dropFirst() {
            longestGap = max(longestGap, times[index] - times[index - 1])
        }
        let final = TranscriptScore.words(finalText)
        return PreviewRow(
            id: id,
            expect_speech: expectSpeech,
            audio_s: (Double(samples.count) / 1_600).rounded() / 10,
            updates: texts.count,
            first_update_ms: times.first,
            longest_gap_ms: longestGap,
            edits_to_final: TranscriptScore.edits(TranscriptScore.words(texts.last ?? ""), final),
            final_words: final.count,
            last_preview: texts.last ?? "")
    }

    private final class PreviewLog: @unchecked Sendable {
        private let lock = NSLock()
        private var texts: [String] = []
        private var times: [Int] = []

        func add(_ text: String, at time: Int) {
            lock.lock()
            texts.append(text)
            times.append(time)
            lock.unlock()
        }

        func snapshot() -> ([String], [Int]) {
            lock.lock()
            defer { lock.unlock() }
            return (texts, times)
        }
    }

    private static func summary(_ group: String, _ rows: [(clip: Manifest.Clip, row: ClipRow)]) -> SummaryRow {
        let scored = rows.filter { $0.clip.expect_speech != false }
        let silent = rows.filter { $0.clip.expect_speech == false }
        let edits = scored.reduce(0) { $0 + $1.row.edits }
        let words = scored.reduce(0) { $0 + $1.row.ref_words }
        let times = rows.flatMap(\.row.ms)
        return SummaryRow(
            group: group,
            clips: rows.count,
            wer_percent: words > 0 ? (Double(edits) / Double(words) * 1_000).rounded() / 10 : nil,
            edits: edits,
            ref_words: words,
            term_recall: "\(rows.reduce(0) { $0 + $1.row.terms_found })/\(rows.reduce(0) { $0 + $1.row.terms_expected })",
            false_insertions: rows.reduce(0) { $0 + $1.row.false_insertions },
            no_speech_clips: silent.count,
            no_speech_with_text: silent.filter { !$0.row.text.isEmpty }.count,
            speech_clips_rejected_by_gate: scored.filter { $0.row.gate != "speech" }.count,
            p50_ms: TranscriptScore.percentile(times, 0.5),
            p95_ms: TranscriptScore.percentile(times, 0.95),
            max_ms: times.max(),
            peak_footprint_mb: footprintMegabytes(peak: true))
    }

    private static func label(_ verdict: SpeechGate.Verdict) -> String {
        switch verdict {
        case .speech: "speech"
        case .noSpeech(.tooQuiet): "too-quiet"
        case .noSpeech(.noVoiceDetected): "no-voice"
        }
    }

    private static func loadEngine(named name: String, gate: SpeechGate) async throws -> any TranscriptionEngine {
        guard let model = SpeechModel(rawValue: name), !model.isCloud else {
            throw Failure(description: "unknown or cloud model: \(name)")
        }
        guard model.isDownloaded else {
            throw Failure(description: "\(name) is not downloaded; this mode never downloads")
        }
        let engine: any TranscriptionEngine
        switch model {
        case .parakeetV3: engine = FluidAudioEngine()
        case .cohereTranscribe2B: engine = CohereAudioEngine(hasVoice: { await gate.evaluate($0) == .speech })
        case .qwen3ASR1_7B: engine = QwenAudioEngine()
        case .maiTranscribe2, .museVoiceTranscribe, .gptTranscribe:
            throw Failure(description: "cloud model: \(name)")
        }
        try await engine.prepare { _ in }
        await engine.wake()
        return engine
    }

    /// Any readable file, as 16 kHz mono Float32, through a real resampler.
    static func loadAudio(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                           frameCapacity: AVAudioFrameCount(file.length)),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw Failure(description: "cannot read \(url.lastPathComponent)")
        }
        try file.read(into: input)
        converter.sampleRateConverterQuality = .max
        let capacity = AVAudioFrameCount(Double(input.frameLength) * 16_000 / file.processingFormat.sampleRate) + 4_096
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw Failure(description: "cannot allocate for \(url.lastPathComponent)")
        }
        var handedOver = false
        var failure: NSError?
        let status = converter.convert(to: output, error: &failure) { _, state in
            if handedOver {
                state.pointee = .endOfStream
                return nil
            }
            handedOver = true
            state.pointee = .haveData
            return input
        }
        guard status != .error, let channel = output.floatChannelData?[0] else {
            throw failure ?? Failure(description: "cannot convert \(url.lastPathComponent)")
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = start.duration(to: .now).components
        return Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
    }

    private static func footprintMegabytes(peak: Bool) -> Int {
        var info = rusage_info_current()
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0)
            }
        }
        guard status == 0 else { return -1 }
        return Int((peak ? info.ri_lifetime_max_phys_footprint : info.ri_phys_footprint) / 1_048_576)
    }
}
