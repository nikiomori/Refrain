import FluidAudio
import Testing
@testable import RefrainKit

@Test func segmentsEndAtSentencesAndPauses() {
    let words = [("Привет,", 0.0, 0.4), ("мир.", 0.5, 0.9), ("Как", 1.0, 1.2), ("дела", 1.3, 1.6),
                 ("потом", 3.0, 3.4), ("пауза", 3.5, 3.9)]
        .map { WordTiming(word: $0.0, startTime: $0.1, endTime: $0.2) }
    #expect(Parakeet.segments(from: words) == [
        .init(start: 0, end: 0.9, text: "Привет, мир."),
        .init(start: 1.0, end: 1.6, text: "Как дела"),
        .init(start: 3.0, end: 3.9, text: "потом пауза"),
    ])
}

@Test func biasWordsPickNamesAndJargonNotSentenceStarts() {
    let words = Transcription.biasWords(in: """
    Yesterday I met Nikolai at the office. We talked about MLX and the iPhone.
    Then GPT4 came up, and Dubina laughed.
    """)
    #expect(Set(words) == ["Nikolai", "MLX", "iPhone", "GPT4", "Dubina"])
    // Most recent first: what was said last is likeliest to be said next.
    #expect(words.first == "Dubina")
    #expect(Transcription.biasWords(in: "Вчера говорил с Николаем про Pretype.") == ["Pretype", "Николаем"])
}

@Test func aBareLanguageGetsItsMainRegion() {
    #expect(Transcription.locale(for: "pt").region == "BR")
    #expect(Transcription.locale(for: "zh").identifier.hasPrefix("zh-Hans"))
    #expect(Transcription.locale(for: "en-GB").region == "GB")
}
