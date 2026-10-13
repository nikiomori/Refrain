import AVFoundation
import FluidAudio
import Foundation
import os
import Speech

let log = Logger(subsystem: "dev.nikiomori.refrain", category: "transcription")

/// What a file turned into. Times are seconds from the start of the file.
public struct Transcript: Sendable, Equatable {
    public struct Segment: Sendable, Equatable {
        public var start: TimeInterval
        public var end: TimeInterval
        public var text: String

        public init(start: TimeInterval, end: TimeInterval, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
    }

    public var text: String
    public var segments: [Segment]
    /// ISO 639-1 code of the language the engine was told, nil when Parakeet detected it.
    public var language: String?
    public var duration: TimeInterval

    public init(text: String, segments: [Segment], language: String?, duration: TimeInterval) {
        self.text = text
        self.segments = segments
        self.language = language
        self.duration = duration
    }
}

public enum TranscriptionError: LocalizedError {
    case unsupportedSystem
    case unsupportedLanguage(String)
    case unreadableAudio

    public var errorDescription: String? {
        switch self {
        case .unsupportedSystem: "Transcription needs macOS 26 or later."
        case .unsupportedLanguage(let code): "No speech model on this Mac knows the language “\(code)”."
        case .unreadableAudio: "The file isn't audio that macOS can read (m4a, mp3, wav, caf, mp4…)."
        }
    }
}

/// On-device speech recognition: picks an engine by language and runs a file through it.
///
/// **Which engine** (see docs/PLAN.md 3.1, measured on FLEURS in Pretype's `Eval/asr`):
/// Apple's `SpeechTranscriber` for its 30 locales — system models, zero bytes of ours;
/// Parakeet for the European languages it skips (Russian: as-typed WER 30.1 → 12.3);
/// Apple's older `DictationTranscriber` for everything else.
///
/// `supportedLocale(equivalentTo:)` is never a support test on its own: it canonicalizes
/// "ru" → "ru_RU" whether or not a model exists, which reads as support and fails at load.
public enum Transcription {
    public enum Engine: Sendable, Equatable {
        /// `preferred`: `SpeechTranscriber`; otherwise `DictationTranscriber`.
        case apple(Locale, preferred: Bool)
        /// nil: Parakeet detects the language itself.
        case parakeet(String?)
    }

    /// Transcribe `file`. `progress` gets the seconds of audio done so far and the file's length.
    @available(macOS 26.0, *)
    public static func transcribe(file: URL, language: String?, prompt: String?,
                                  progress: @escaping @Sendable (_ done: TimeInterval, _ total: TimeInterval) -> Void = { _, _ in }
    ) async throws -> Transcript {
        guard SpeechTranscriber.isAvailable else { throw TranscriptionError.unsupportedSystem }
        let audio: AVAudioFile
        do { audio = try AVAudioFile(forReading: file) } catch { throw TranscriptionError.unreadableAudio }
        let duration = Double(audio.length) / audio.processingFormat.sampleRate
        let language = language.flatMap { $0.isEmpty ? nil : $0.lowercased() }
        guard let engine = await engine(for: language) else {
            throw TranscriptionError.unsupportedLanguage(language ?? Locale.current.identifier)
        }
        let started = ContinuousClock.now
        progress(0, duration)
        let progress: @Sendable (TimeInterval) -> Void = { progress(min($0, duration), duration) }
        var (text, segments): (String, [Transcript.Segment])
        switch engine {
        case .parakeet(let code):
            (text, segments) = try await Parakeet.transcribe(file: file, duration: duration, language: code, progress: progress)
        case .apple(let locale, let preferred):
            (text, segments) = try await transcribeWithApple(audio, locale: locale, preferred: preferred,
                                                             words: biasWords(in: prompt ?? ""), progress: progress)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if segments.isEmpty, !text.isEmpty { segments = [.init(start: 0, end: duration, text: text)] }
        // Durations only: the words never reach the log.
        let name = switch engine {
        case .parakeet(let code): "Parakeet, \(code ?? "auto")"
        case .apple(let locale, let preferred): "\(preferred ? "SpeechTranscriber" : "DictationTranscriber"), \(locale.identifier)"
        }
        log.notice("\(Int(duration)) s of audio in \(started.duration(to: .now), privacy: .public) (\(name, privacy: .public))")
        return Transcript(text: text, segments: segments, language: Self.code(of: engine), duration: duration)
    }

    /// `language` picks the engine. Without one: Parakeet if downloaded (it detects the language),
    /// otherwise Apple's model for the system language.
    @available(macOS 26.0, *)
    public static func engine(for language: String?) async -> Engine? {
        guard let language else {
            if Parakeet.isDownloaded { return .parakeet(nil) }
            return await resolve(Locale.current).map { .apple($0.locale, preferred: $0.preferred) }
        }
        let locale = locale(for: language)
        let resolved = await resolve(locale)
        if resolved?.preferred != true, Parakeet.isDownloaded,
           let code = locale.language.languageCode?.identifier, Parakeet.languages.contains(code) {
            return .parakeet(code)
        }
        return resolved.map { .apple($0.locale, preferred: $0.preferred) }
    }

    /// "en" alone is the Mac's own English if it speaks one, otherwise the language's main
    /// region (en_US, pt_BR). Left to Apple, "en" comes back as en_IE.
    static func locale(for language: String) -> Locale {
        let requested = Locale(identifier: language)
        guard requested.region == nil else { return requested }
        if Locale.current.language.languageCode == requested.language.languageCode { return Locale.current }
        return Locale(identifier: requested.language.maximalIdentifier)
    }

    private static func code(of engine: Engine) -> String? {
        switch engine {
        case .apple(let locale, _): locale.language.languageCode?.identifier
        case .parakeet(let code): code
        }
    }

    /// The transcriber's own identifier for `locale` and which model serves it, or nil.
    @available(macOS 26.0, *)
    static func resolve(_ locale: Locale) async -> (locale: Locale, preferred: Bool)? {
        if let canonical = await SpeechTranscriber.supportedLocale(equivalentTo: locale),
           await SpeechTranscriber.supportedLocales.contains(where: { $0.identifier == canonical.identifier }) {
            return (canonical, true)
        }
        if let canonical = await DictationTranscriber.supportedLocale(equivalentTo: locale),
           await DictationTranscriber.supportedLocales.contains(where: { $0.identifier == canonical.identifier }) {
            return (canonical, false)
        }
        return nil
    }

    /// Languages Apple's newer `SpeechTranscriber` serves — what Settings lists for it.
    @available(macOS 26.0, *)
    public static var appleLocales: [Locale] {
        get async { await SpeechTranscriber.supportedLocales }
    }

    /// Names and jargon in `text`, most recent first, deduplicated: words capitalized
    /// mid-sentence and words with an inner capital or digit (iPhone, MLX, GPT4).
    /// Sentence-initial capitals carry no signal.
    public static func biasWords(in text: String, limit: Int = 50) -> [String] {
        var picked: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            var atStart = true  // a new line starts a sentence (or a list item)
            for raw in line.split(whereSeparator: \.isWhitespace) {
                defer { atStart = raw.last.map { ".!?…".contains($0) } ?? false }
                let word = raw.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
                guard word.count >= 3, let first = word.first, word.contains(where: \.isLetter) else { continue }
                let inner = word.dropFirst().contains { $0.isUppercase || $0.isNumber }
                if inner || (!atStart && first.isUppercase) { picked.append(word) }
            }
        }
        var seen = Set<String>()
        return Array(picked.reversed().filter { seen.insert($0.lowercased()).inserted }.prefix(limit))
    }

    @available(macOS 26.0, *)
    private static func transcribeWithApple(_ audio: AVAudioFile, locale: Locale, preferred: Bool, words: [String],
                                            progress: @escaping @Sendable (TimeInterval) -> Void) async throws -> (String, [Transcript.Segment]) {
        if preferred {
            let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
            return try await analyze(audio, module: module, locale: locale, words: words, progress: progress) {
                ($0.range, String($0.text.characters))
            }
        }
        // The older model writes no punctuation unless asked.
        let module = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                                          reportingOptions: [], attributeOptions: [])
        return try await analyze(audio, module: module, locale: locale, words: words, progress: progress) {
            ($0.range, String($0.text.characters))
        }
    }

    /// One pass of `SpeechAnalyzer` over the file, which it reads itself, a piece at a time:
    /// an hour of audio never sits in memory. Each final result becomes a segment; the text
    /// is the results as written, since they carry their own spacing (none in Chinese).
    @available(macOS 26.0, *)
    private static func analyze<Module: SpeechModule>(
        _ audio: AVAudioFile, module: Module, locale: Locale, words: [String],
        progress: @escaping @Sendable (TimeInterval) -> Void,
        result: @escaping @Sendable (Module.Result) -> (CMTimeRange, String)
    ) async throws -> (String, [Transcript.Segment]) {
        try await install(module, locale: locale)
        let analyzer = SpeechAnalyzer(modules: [module])
        if !words.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = words
            do { try await analyzer.setContext(context) } catch {
                log.error("contextual strings refused: \(error.localizedDescription, privacy: .public)")
            }
        }
        // Started before the analyzer, so no result arrives with nobody listening.
        let collector = Task {
            var text = ""
            var segments: [Transcript.Segment] = []
            for try await piece in module.results where piece.isFinal {
                let (range, words) = result(piece)
                progress(range.end.seconds)
                text += words
                let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                segments.append(.init(start: range.start.seconds, end: range.end.seconds, text: trimmed))
            }
            return (text, segments)
        }
        do {
            if let end = try await analyzer.analyzeSequence(from: audio) {
                try await analyzer.finalizeAndFinish(through: end)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw error
        }
        return try await collector.value
    }

    /// Downloads the language pack the first time (slow exactly once per language), then
    /// reserves the locale: macOS won't load a model for an app that hasn't. The pool of
    /// reservations is small and outlives the process, so a full pool gives up stale slots
    /// one at a time until the new one fits — otherwise every new language would fail forever.
    @available(macOS 26.0, *)
    private static func install(_ module: any SpeechModule, locale: Locale) async throws {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            log.notice("downloading the \(locale.identifier, privacy: .public) speech model")
            try await request.downloadAndInstall()
        }
        do {
            let reserved = await AssetInventory.reservedLocales
            guard !reserved.contains(where: { $0.identifier == locale.identifier }) else { return }
            do {
                _ = try await AssetInventory.reserve(locale: locale)
            } catch {
                for stale in reserved {
                    _ = await AssetInventory.release(reservedLocale: stale)
                    log.notice("released the \(stale.identifier, privacy: .public) speech-model slot to make room")
                    if (try? await AssetInventory.reserve(locale: locale)) != nil { return }
                }
                _ = try await AssetInventory.reserve(locale: locale)
            }
        } catch {
            log.error("could not reserve \(locale.identifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
