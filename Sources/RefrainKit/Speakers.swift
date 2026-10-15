import CoreML
import FluidAudio
import Foundation

/// Who speaks when, for `diarized_json`: FluidAudio's offline pipeline (pyannote community-1,
/// WeSpeaker, VBx clustering; DER ~11% on AMI, an hour in ~12 s). Reprise asks for it on the
/// others' side of a call. ~22 MB in FluidAudio's shared cache, downloaded only from a button.
public enum Speakers {
    /// One voice's stretch of speech, as the diarizer labels it.
    struct Turn: Equatable {
        var speaker: String
        var start: TimeInterval
        var end: TimeInterval
    }

    static var folder: URL { MLModelConfigurationUtils.defaultModelsDirectory(for: .diarizer) }

    /// The Neural Engine, as Parakeet. FluidAudio's default lets the GPU in, which held ~630 MB
    /// of graphics memory through every request for five minutes of audio.
    static var neuralEngine: MLModelConfiguration {
        MLModelConfigurationUtils.defaultConfiguration(computeUnits: .cpuAndNeuralEngine)
    }

    public static var isDownloaded: Bool {
        ModelNames.OfflineDiarizer.requiredModels.allSatisfy {
            FileManager.default.fileExists(atPath: folder.appending(path: $0).path)
        }
    }

    public static func delete() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Downloads the models if they're missing (the Download button), then loads and compiles
    /// them, so the first request after an update of macOS doesn't.
    public static func warmUp() async throws {
        try await diarizer.run { _ in }
    }

    /// None when no voice speaks long enough to tell (a muted side, one "yeah"): the words then
    /// come back as one phrase rather than as an error.
    static func turns(in file: URL) async throws -> [Turn] {
        try await diarizer.run { diarizer in
            do {
                return try await diarizer.process(file).segments.map {
                    Turn(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
                }
            } catch OfflineDiarizationError.noSpeechDetected {
                return []
            }
        }
    }

    private static let diarizer = Diarizer()

    /// Loaded at the first use and kept: in Refrain's engine, which quits when idle, that costs
    /// nothing at rest, and a call's two sides come one after the other (0.09 s less each).
    /// One use at a time, each after the last, since FluidAudio's diarizer is not to be shared.
    private actor Diarizer {
        private var loaded: Unshared?
        private var tail: Task<Void, Never>?

        func run<T: Sendable>(_ use: @escaping @Sendable (OfflineDiarizerManager) async throws -> T) async throws -> T {
            let previous = tail
            let job = Task {
                await previous?.value
                try Task.checkCancellation()
                return try await use(try await load().value)
            }
            tail = Task { _ = try? await job.value }
            return try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
        }

        private func load() async throws -> Unshared {
            // Deleted from Settings since: the Download button downloads again.
            if let loaded, Speakers.isDownloaded { return loaded }
            let diarizer = OfflineDiarizerManager()
            try await diarizer.prepareModels(configuration: Speakers.neuralEngine)
            loaded = Unshared(value: diarizer)
            return loaded!
        }
    }

    /// Used by one job at a time: `Diarizer` runs them one after another.
    private struct Unshared: @unchecked Sendable {
        let value: OfflineDiarizerManager
    }

    /// The words in phrases, each phrase one voice's: a word goes to the turn that overlaps it
    /// most, or the nearest one when none does (a word heard between turns). Voices are "A",
    /// "B"… in the order they first speak, as OpenAI labels them.
    /// ponytail: words × turns, ~25 ms for an hour (M4 Max); a sweep if that ever shows.
    static func phrases(_ words: [Transcript.Segment], turns: [Turn]) -> [Transcript.Segment] {
        guard !turns.isEmpty, !words.isEmpty else { return [] }
        var letters: [String: String] = [:]
        let voices = words.map { word in
            let overlap = { (turn: Turn) in min(turn.end, word.end) - max(turn.start, word.start) }
            let middle = (word.start + word.end) / 2
            let distance = { (turn: Turn) in max(turn.start - middle, middle - turn.end, 0) }
            let best = turns.max { overlap($0) < overlap($1) }!
            let turn = overlap(best) > 0 ? best : turns.min { distance($0) < distance($1) }!
            if letters[turn.speaker] == nil {
                let index = letters.count
                letters[turn.speaker] = index < 26 ? String(UnicodeScalar(UInt8(65 + index))) : "S\(index + 1)"
            }
            return letters[turn.speaker]!
        }
        var phrases: [Transcript.Segment] = []
        var start = 0
        for end in 1...words.count where end == words.count || voices[end] != voices[start] {
            phrases += Parakeet.segments(from: Array(words[start..<end])).map {
                .init(start: $0.start, end: $0.end, text: $0.text, speaker: voices[start])
            }
            start = end
        }
        return phrases
    }
}
