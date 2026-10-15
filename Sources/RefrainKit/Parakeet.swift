import FluidAudio
import Foundation

/// NVIDIA's Parakeet TDT v3 (0.6B, Core ML on the Neural Engine via FluidAudio), as moondream's
/// Parakeet Ultra post-training: the European languages Apple serves only with its older model.
/// Russian on FLEURS (Pretype's `Eval/asr`): as-typed WER 30.1 → 12.3, punctuation F1 0.02 → 0.85.
///
/// The models live in FluidAudio's shared cache, so a copy Pretype downloaded is this one too.
/// Never downloaded on its own: `download()` is called only from a button, which is the consent.
public enum Parakeet {
    /// The 25 languages v3 was trained on.
    public static let languages: Set<String> = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
        "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
    ]

    /// Ultra, or the v3 an earlier Pretype left behind (same languages, a little less accurate).
    public static var isDownloaded: Bool { exists(.ultra) || exists(.v3) }

    /// Bytes on disk of the copy in use, for Settings. A v3 left beside Ultra is Pretype's to
    /// delete, at its next launch.
    public static var size: Int64 {
        let files = FileManager.default.enumerator(at: AsrModels.defaultCacheDirectory(for: exists(.ultra) ? .ultra : .v3),
                                                   includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        var total: Int64 = 0
        while let url = files?.nextObject() as? URL {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    public static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await AsrModels.download(version: .ultra) { progress($0.fractionCompleted) }
    }

    /// Also Pretype's copy, if it uses Parakeet: it downloads it again when it next needs it.
    public static func delete() async {
        await loader.unload()
        for version in [AsrModelVersion.ultra, .v3] {
            try? FileManager.default.removeItem(at: AsrModels.defaultCacheDirectory(for: version))
        }
    }

    static func exists(_ version: AsrModelVersion) -> Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
    }

    /// Loads the model once, so the first request after an update of macOS doesn't wait
    /// ~11 s for the Neural Engine to compile it. It unloads on its own, as after a request.
    public static func warmUp() async throws {
        _ = try await loader.acquire()
        await loader.release()
    }

    /// `file` is 16 kHz mono (`Transcription.mono`).
    static func transcribe(file: URL, duration: TimeInterval, language: String?,
                           progress: @escaping @Sendable (TimeInterval) -> Void) async throws -> Transcription.Pieces {
        let manager = try await loader.acquire()
        defer { Task { await loader.release() } }
        let hint = language.flatMap(Language.init(rawValue:))
        var state = TdtDecoderState.make()
        let result: ASRResult
        if duration < 30 {
            // Already 16 kHz mono, so read as it is. The model refuses a clip under its minimum;
            // padded with silence it reads fine.
            var samples = try AudioConverter().resampleAudioFile(file)
            let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: 16_000)
            if samples.count < minimum { samples += [Float](repeating: 0, count: minimum - samples.count) }
            result = try await manager.transcribe(samples, decoderState: &state, language: hint)
        } else {
            // Longer files go through FluidAudio's disk-backed path: copied a piece at a time into
            // a temporary file it maps, never whole in memory.
            let fractions = await manager.transcriptionProgressStream
            let watcher = Task { for try await fraction in fractions { progress(fraction * duration) } }
            defer { watcher.cancel() }
            result = try await manager.transcribe(file, decoderState: &state, language: hint)
        }
        let words = buildWordTimings(from: result.tokenTimings ?? []).map {
            Transcript.Segment(start: $0.startTime, end: $0.endTime, text: $0.word)
        }
        return (result.text, segments(from: words), words)
    }

    /// Sentences, as Parakeet punctuates them; a pause of a second or 30 s without a full stop
    /// also ends one, so an unpunctuated stretch still gets timestamps to seek to.
    static func segments(from words: [Transcript.Segment]) -> [Transcript.Segment] {
        var segments: [Transcript.Segment] = []
        var current: [Transcript.Segment] = []
        for (index, word) in words.enumerated() {
            current.append(word)
            let next = index + 1 < words.count ? words[index + 1] : nil
            let sentenceEnds = word.text.last.map { ".?!…".contains($0) } ?? false
            if next == nil || sentenceEnds || next!.start - word.end >= 1 || word.end - current[0].start >= 30 {
                segments.append(.init(start: current[0].start, end: word.end,
                                      text: current.map(\.text).joined(separator: " ")))
                current = []
            }
        }
        return segments
    }

    private static let loader = Loader()

    /// Loaded on the first request, unloaded after five idle minutes. Counted, so a
    /// `release` that arrives late can't start the idle clock under a transcription in progress.
    /// Loaded once however many ask at a time (a warm-up and a request).
    private actor Loader {
        private var manager: AsrManager?
        private var loading: Task<AsrManager, Error>?
        private var users = 0
        private var idle: Task<Void, Never>?

        func acquire() async throws -> AsrManager {
            users += 1
            idle?.cancel()
            if let manager { return manager }
            let loading = self.loading ?? Task {
                let version: AsrModelVersion = Parakeet.exists(.ultra) ? .ultra : .v3
                let models = try await AsrModels.load(from: AsrModels.defaultCacheDirectory(for: version), version: version)
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                return manager
            }
            self.loading = loading
            do {
                let manager = try await loading.value
                self.manager = manager
                self.loading = nil
                return manager
            } catch {
                self.loading = nil
                users -= 1
                throw error
            }
        }

        func release() {
            users -= 1
            guard users == 0 else { return }
            idle = Task {
                try? await Task.sleep(for: .seconds(300))
                if !Task.isCancelled { await unload() }
            }
        }

        func unload() async {
            guard users == 0, let manager else { return }
            self.manager = nil  // before the wait: a request meanwhile loads a fresh one, not this
            await manager.cleanup()
            log.notice("Parakeet unloaded")
        }
    }
}
