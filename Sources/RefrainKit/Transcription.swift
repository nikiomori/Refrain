import Accelerate
import AVFoundation
import FluidAudio
import Foundation
import os
import Speech
import Synchronization

let log = Logger(subsystem: "dev.nikiomori.refrain", category: "transcription")

/// What a file turned into. Times are seconds from the start of the file.
public struct Transcript: Sendable, Equatable {
    public struct Segment: Sendable, Equatable {
        public var start: TimeInterval
        public var end: TimeInterval
        public var text: String
        /// "A", "B"… when the voices were told apart.
        public var speaker: String?

        public init(start: TimeInterval, end: TimeInterval, text: String, speaker: String? = nil) {
            self.start = start
            self.end = end
            self.text = text
            self.speaker = speaker
        }
    }

    public var text: String
    public var segments: [Segment]
    /// One segment per word.
    public var words: [Segment]
    /// ISO 639-1 code of the language the engine was told, nil when Parakeet detected it.
    public var language: String?
    public var duration: TimeInterval

    public init(text: String, segments: [Segment], words: [Segment] = [], language: String?, duration: TimeInterval) {
        self.text = text
        self.segments = segments
        self.words = words
        self.language = language
        self.duration = duration
    }
}

public enum TranscriptionError: LocalizedError {
    case unsupportedSystem
    case unsupportedLanguage(String)
    case unreadableAudio
    case noSpeakerModel

    public var errorDescription: String? {
        switch self {
        case .unsupportedSystem: "Transcription needs macOS 26 or later."
        case .unsupportedLanguage(let code): "No speech model on this Mac knows the language “\(code)”."
        case .unreadableAudio: "The file isn't audio that macOS can read (m4a, mp3, wav, caf, mp4…)."
        case .noSpeakerModel: "Telling voices apart needs the speaker model: download it in Refrain's Settings, under Models."
        }
    }
}

/// On-device speech recognition: picks an engine by language and runs a file through it.
///
/// **Which engine** (measured on FLEURS in Pretype's `Eval/asr`):
/// Apple's `SpeechTranscriber` for its 30 locales — system models, zero bytes of ours;
/// Parakeet for the European languages it skips (Russian: as-typed WER 30.1 → 12.3);
/// Apple's older `DictationTranscriber` for everything else.
///
/// `supportedLocale(equivalentTo:)` is never a support test on its own: it canonicalizes
/// "ru" → "ru_RU" whether or not a model exists, which reads as support and fails at load.
public enum Transcription {
    /// Text, segments and words, as an engine returns them.
    typealias Pieces = (text: String, segments: [Transcript.Segment], words: [Transcript.Segment])

    public enum Engine: Sendable, Equatable {
        /// `preferred`: `SpeechTranscriber`; otherwise `DictationTranscriber`.
        case apple(Locale, preferred: Bool)
        /// nil: Parakeet detects the language itself.
        case parakeet(String?)
    }

    /// Transcribe `file`. `keywords` are spellings to listen for, ahead of the names in `prompt`.
    /// With `speakers`, each segment says which voice it is, told apart while the words are heard.
    /// `progress` gets the seconds of audio done so far and the file's length.
    @available(macOS 26.0, *)
    public static func transcribe(file: URL, language: String?, prompt: String?, keywords: [String] = [], speakers: Bool = false,
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
        guard !speakers || Speakers.isDownloaded else { throw TranscriptionError.noSpeakerModel }
        async let turns = speakers ? Speakers.turns(in: file) : []
        let started = ContinuousClock.now
        progress(0, duration)
        let progress: @Sendable (TimeInterval) -> Void = { progress(min($0, duration), duration) }
        var (text, segments, words): (String, [Transcript.Segment], [Transcript.Segment])
        switch engine {
        case .parakeet(let code):
            // ponytail: no hints — FluidAudio's vocabulary boosting knows only English, which goes to Apple.
            (text, segments, words) = try await Parakeet.transcribe(file: file, duration: duration, language: code, progress: progress)
        case .apple(let locale, let preferred):
            (text, segments, words) = try await transcribeWithApple(audio, locale: locale, preferred: preferred,
                                                                    hints: hints(keywords: keywords, prompt: prompt), progress: progress)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if speakers { segments = Speakers.phrases(words, turns: try await turns) }
        if segments.isEmpty, !text.isEmpty { segments = [.init(start: 0, end: duration, text: text)] }
        // Durations only: the words never reach the log.
        let name = switch engine {
        case .parakeet(let code): "Parakeet, \(code ?? "auto")"
        case .apple(let locale, let preferred): "\(preferred ? "SpeechTranscriber" : "DictationTranscriber"), \(locale.identifier)"
        }
        log.notice("\(Int(duration)) s of audio in \(started.duration(to: .now), privacy: .public) (\(name, privacy: .public))")
        return Transcript(text: text, segments: segments, words: words, language: Self.code(of: engine), duration: duration)
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

    /// What the engine listens for: `keywords` as given, then the names in `prompt`.
    /// At most 100, no repeats whatever the case. Only Apple's older model hears them: measured
    /// on macOS 27, `SpeechTranscriber` spells names the same with them or without, while
    /// `DictationTranscriber` gets every one right.
    static func hints(keywords: [String], prompt: String?) -> [String] {
        var seen = Set<String>()
        let words = keywords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } + biasWords(in: prompt ?? "")
        return Array(words.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }.prefix(100))
    }

    /// Names and jargon in a `prompt`, most recent first, deduplicated: words capitalized
    /// mid-sentence and words with an inner capital or digit (iPhone, MLX, GPT4).
    /// Sentence-initial capitals carry no signal. The prompt's own first word is not taken
    /// for a sentence start: clients send a tail cut mid-text (Reprise) or a list of names
    /// (Pretype's "Dubina, MLX"), where it is the likeliest name of all.
    public static func biasWords(in text: String, limit: Int = 50) -> [String] {
        var picked: [String] = []
        for (index, line) in text.split(whereSeparator: \.isNewline).enumerated() {
            var atStart = index > 0  // a new line starts a sentence (or a list item)
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
    private static func transcribeWithApple(_ audio: AVAudioFile, locale: Locale, preferred: Bool, hints: [String],
                                            progress: @escaping @Sendable (TimeInterval) -> Void) async throws -> Pieces {
        if preferred {
            return try await analyze(audio, locale: locale, hints: hints, progress: progress, module: {
                SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
            }, result: { ($0.range, $0.text) })
        }
        // The older model writes no punctuation unless asked.
        return try await analyze(audio, locale: locale, hints: hints, progress: progress, module: {
            DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                                 reportingOptions: [], attributeOptions: [.audioTimeRange])
        }, result: { ($0.range, $0.text) })
    }

    /// `SpeechAnalyzer` over the file in up to four parts at once, cut at quiet moments. Each
    /// analyzer runs in a process of macOS's own, so an hour of English takes ~15 s, not 38,
    /// with the same accuracy. Each part is read a buffer at a time, as its analyzer asks for
    /// one: an hour of audio never sits in memory. Each final result becomes a segment, each
    /// of its timed runs a word; the text is the results as written, since they carry their
    /// own spacing (none in Chinese).
    @available(macOS 26.0, *)
    private static func analyze<Module: SpeechModule>(
        _ audio: AVAudioFile, locale: Locale, hints: [String],
        progress: @escaping @Sendable (TimeInterval) -> Void,
        module: @escaping @Sendable () -> Module,
        result: @escaping @Sendable (Module.Result) -> (CMTimeRange, AttributedString)
    ) async throws -> Pieces {
        // No `SpeechDetector`: beside four analyzers it made a half-silent call slower, not faster.
        try await install(module(), locale: locale)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module()], considering: audio.processingFormat)
        else { throw TranscriptionError.unsupportedLanguage(locale.identifier) }
        let rate = audio.processingFormat.sampleRate
        // A part under half a minute costs more in start-up than it saves.
        let cuts = try quietCuts(in: audio, parts: min(4, max(1, Int(Double(audio.length) / rate / 30))))
        let url = audio.url
        let done = Mutex([TimeInterval](repeating: 0, count: cuts.count - 1))

        let parts = try await withThrowingTaskGroup(of: (Int, Pieces).self) { group in
            for part in 0..<cuts.count - 1 {
                let start = Double(cuts[part]) / rate
                group.addTask {
                    let module = module()
                    let analyzer = SpeechAnalyzer(modules: [module])
                    if !hints.isEmpty {
                        let context = AnalysisContext()
                        context.contextualStrings[.general] = hints
                        do { try await analyzer.setContext(context) } catch {
                            log.error("contextual strings refused: \(error.localizedDescription, privacy: .public)")
                        }
                    }
                    // Started before the analyzer, so no result arrives with nobody listening.
                    let collector = Task {
                        var pieces: Pieces = ("", [], [])
                        for try await piece in module.results where piece.isFinal {
                            let (range, attributed) = result(piece)
                            progress(done.withLock { $0[part] = range.end.seconds - start; return $0.reduce(0, +) })
                            let said = String(attributed.characters)
                            pieces.text += said
                            let trimmed = said.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { continue }
                            let words = attributed.runs.compactMap { run -> Transcript.Segment? in
                                guard let time = run.audioTimeRange else { return nil }
                                let word = String(attributed[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                                return word.isEmpty ? nil : .init(start: time.start.seconds, end: time.end.seconds, text: word)
                            }
                            pieces.words += words
                            // From its first word to its last: a result's own range runs on through
                            // the silence after it, up to the next one.
                            pieces.segments.append(.init(start: words.first?.start ?? range.start.seconds,
                                                         end: words.last?.end ?? range.end.seconds, text: trimmed))
                        }
                        return pieces
                    }
                    let reader = try PartReader(url, from: cuts[part], to: cuts[part + 1], as: format)
                    do {
                        if let end = try await analyzer.analyzeSequence(AsyncThrowingStream(unfolding: reader.next)) {
                            try await analyzer.finalizeAndFinish(through: end)
                        } else {
                            await analyzer.cancelAndFinishNow()
                        }
                    } catch {
                        collector.cancel()
                        throw error
                    }
                    return (part, try await collector.value)
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return parts.reduce(into: ("", [], [])) { all, part in
            // Parts meet with a space unless one is there already; Chinese, Japanese and Thai take none.
            if let last = all.text.last, let first = part.text.first, !last.isWhitespace, !first.isWhitespace,
               !["zh", "ja", "yue", "th"].contains(locale.language.languageCode?.identifier ?? "") {
                all.text += " "
            }
            all.text += part.text
            all.segments += part.segments
            all.words += part.words
        }
    }

    /// Frames to cut the file at for `parts` analyzers, from 0 to its length: the even shares,
    /// each moved to the quietest tenth of a second within 3 s, so no word is cut in two.
    static func quietCuts(in audio: AVAudioFile, parts: Int) throws -> [AVAudioFramePosition] {
        let rate = audio.processingFormat.sampleRate
        let window = Int(rate / 10), reach = AVAudioFramePosition(rate * 3)
        var cuts: [AVAudioFramePosition] = [0]
        for part in 1..<max(parts, 1) {
            let even = audio.length * AVAudioFramePosition(part) / AVAudioFramePosition(parts)
            audio.framePosition = even - reach
            let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(2 * reach))!
            try audio.read(into: buffer)
            var quietest = (energy: Float.infinity, at: even)
            for offset in stride(from: 0, through: Int(buffer.frameLength) - window, by: window / 2) {
                var energy: Float = 0
                for channel in 0..<Int(buffer.format.channelCount) {
                    var sum: Float = 0
                    vDSP_svesq(buffer.floatChannelData![channel] + offset, 1, &sum, vDSP_Length(window))
                    energy += sum
                }
                if energy < quietest.energy { quietest = (energy, even - reach + AVAudioFramePosition(offset + window / 2)) }
            }
            cuts.append(quietest.at)
        }
        audio.framePosition = 0
        return cuts + [audio.length]
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

/// One part of a file in the analyzer's format, read a buffer at a time as the analyzer pulls
/// it: a part never sits in memory whole, as it would if pushed faster than it's analyzed.
@available(macOS 26.0, *)
private final class PartReader: @unchecked Sendable {
    private let file: AVAudioFile
    private let format: AVAudioFormat
    private let converter: AVAudioConverter?
    private var position: AVAudioFramePosition
    private let end: AVAudioFramePosition
    private var started = false

    init(_ url: URL, from start: AVAudioFramePosition, to end: AVAudioFramePosition, as format: AVAudioFormat) throws {
        file = try AVAudioFile(forReading: url)
        file.framePosition = start
        position = start
        self.end = end
        self.format = format
        converter = file.processingFormat == format ? nil : AVAudioConverter(from: file.processingFormat, to: format)
        converter?.downmix = true  // a call with a side in each channel keeps both
    }

    @Sendable func next() async throws -> AnalyzerInput? {
        let count = AVAudioFrameCount(min(end - position, 1 << 16))
        guard count > 0 else { return nil }
        let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count)!
        try file.read(into: input, frameCount: count)
        guard input.frameLength > 0 else { return nil }
        // The first buffer says where the part starts, so its timestamps are the file's.
        let time = started ? nil : CMTime(value: position, timescale: CMTimeScale(input.format.sampleRate))
        started = true
        position += AVAudioFramePosition(input.frameLength)
        guard let converter else { return AnalyzerInput(buffer: input, bufferStartTime: time) }
        let capacity = AVAudioFrameCount(Double(input.frameLength) * format.sampleRate / input.format.sampleRate) + 64
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return AnalyzerInput(buffer: output, bufferStartTime: time)
    }
}
