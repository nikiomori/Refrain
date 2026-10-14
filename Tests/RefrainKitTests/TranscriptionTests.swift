import AVFoundation
import Testing
@testable import RefrainKit

@Test func segmentsEndAtSentencesAndPauses() {
    let words = [("Привет,", 0.0, 0.4), ("мир.", 0.5, 0.9), ("Как", 1.0, 1.2), ("дела", 1.3, 1.6),
                 ("потом", 3.0, 3.4), ("пауза", 3.5, 3.9)]
        .map { Transcript.Segment(start: $0.1, end: $0.2, text: $0.0) }
    #expect(Parakeet.segments(from: words) == [
        .init(start: 0, end: 0.9, text: "Привет, мир."),
        .init(start: 1.0, end: 1.6, text: "Как дела"),
        .init(start: 3.0, end: 3.9, text: "потом пауза"),
    ])
}

@Test func biasWordsPickNamesAndJargonNotSentenceStarts() {
    let words = Transcription.biasWords(in: """
    the call went on. Yesterday I met Nikolai at the office. We talked about MLX and the iPhone.
    Then GPT4 came up, and Dubina laughed.
    """)
    #expect(Set(words) == ["Nikolai", "MLX", "iPhone", "GPT4", "Dubina"])
    // Most recent first: what was said last is likeliest to be said next.
    #expect(words.first == "Dubina")
    #expect(Transcription.biasWords(in: "вчера говорил с Николаем про Pretype.") == ["Pretype", "Николаем"])
}

/// Pretype sends the names already in the field as a list, most recent first.
@Test func biasWordsKeepTheFirstNameOfAList() {
    #expect(Set(Transcription.biasWords(in: "Dubina, Nikolai, MLX")) == ["Dubina", "Nikolai", "MLX"])
}

/// The request's keywords first, as given; then the prompt's names; no repeats, at most 100.
@Test func hintsPutKeywordsFirst() {
    #expect(Transcription.hints(keywords: [" Refrain ", "MLX", ""], prompt: "talked about mlx with Dubina")
        == ["Refrain", "MLX", "Dubina"])
    #expect(Transcription.hints(keywords: (0..<150).map { "Word\($0)" }, prompt: nil).count == 100)
}

@Test func aBareLanguageGetsItsMainRegion() {
    #expect(Transcription.locale(for: "pt").region == "BR")
    #expect(Transcription.locale(for: "zh").identifier.hasPrefix("zh-Hans"))
    #expect(Transcription.locale(for: "en-GB").region == "GB")
}

/// A file is cut for parallel analyzers where it's quiet, not at the even share inside a word.
@Test func cutsLandInTheQuiet() throws {
    let rate = 16_000.0
    let url = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).caf")
    defer { try? FileManager.default.removeItem(at: url) }
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(20 * rate))!
    buffer.frameLength = buffer.frameCapacity
    for frame in 0..<Int(buffer.frameLength) {
        let quiet = (11.0..<11.5).contains(Double(frame) / rate)  // a pause past the middle
        buffer.floatChannelData![0][frame] = quiet ? 0 : sin(Float(frame) * 2 * .pi * 440 / Float(rate)) * 0.5
    }
    try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    let cuts = try Transcription.quietCuts(in: AVAudioFile(forReading: url), parts: 2)
    #expect(cuts.count == 3 && cuts.first == 0 && cuts.last == AVAudioFramePosition(20 * rate))
    #expect((11.0...11.5).contains(Double(cuts[1]) / rate))
}

/// Words go to the voice whose turn covers them, or the nearest one; a change of voice ends the phrase.
@Test func phrasesFollowTheVoices() {
    let words = [("Hi,", 0.0, 0.3), ("there.", 0.4, 0.8), ("Hello", 1.0, 1.4), ("again", 1.5, 1.9), ("Bye.", 2.6, 2.9)]
        .map { Transcript.Segment(start: $0.1, end: $0.2, text: $0.0) }
    let turns = [Speakers.Turn(speaker: "S7", start: 0, end: 0.9), .init(speaker: "S2", start: 1.0, end: 2.0),
                 .init(speaker: "S7", start: 3.0, end: 3.5)]  // "Bye." falls between turns, nearer the last
    #expect(Speakers.phrases(words, turns: turns) == [
        .init(start: 0, end: 0.8, text: "Hi, there.", speaker: "A"),
        .init(start: 1.0, end: 1.9, text: "Hello again", speaker: "B"),
        .init(start: 2.6, end: 2.9, text: "Bye.", speaker: "A"),
    ])
    #expect(Speakers.phrases([], turns: turns).isEmpty)
}
