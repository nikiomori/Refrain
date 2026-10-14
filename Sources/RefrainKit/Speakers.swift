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
        try await OfflineDiarizerManager().prepareModels()
    }

    /// ponytail: loaded per request (22 MB, compiled once); keep a loader like Parakeet's if it shows.
    static func turns(in file: URL) async throws -> [Turn] {
        let diarizer = OfflineDiarizerManager()
        try await diarizer.prepareModels()
        return try await diarizer.process(file).segments.map {
            Turn(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
        }
    }

    /// The words in phrases, each phrase one voice's: a word goes to the turn that overlaps it
    /// most, or the nearest one when none does (a word heard between turns). Voices are "A",
    /// "B"… in the order they first speak, as OpenAI labels them.
    /// ponytail: words × turns, ~10 million steps for an hour; a sweep if that ever shows.
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
