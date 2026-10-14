import AppIntents
import RefrainServer

/// A file in, its words out: Shortcuts, Spotlight and Siri. A shortcut that receives files from
/// Quick Actions puts it in Finder's context menu. Waits in the same queue as the server's requests.
struct TranscribeFile: AppIntent {
    static let title: LocalizedStringResource = "Transcribe Audio File"
    static let description = IntentDescription("Turns the speech in an audio or video file into text, on this Mac.")

    @Parameter(title: "File", supportedContentTypes: [.audio, .movie])
    var file: IntentFile

    @Parameter(title: "Language", description: "A code such as en or ru. Without one, Refrain chooses.")
    var language: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Transcribe \(\.$file)") { \.$language }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        // A file on disk is read where it is; one handed over as data is written out first,
        // keeping its extension, which AVFoundation goes by.
        var copy: URL?
        let url: URL
        if let fileURL = file.fileURL {
            url = fileURL
        } else {
            try FileManager.default.createDirectory(at: Server.uploads, withIntermediateDirectories: true)
            let ext = URL(filePath: file.filename).pathExtension
            url = Server.uploads.appending(path: "\(UUID().uuidString).\(ext.isEmpty ? "m4a" : ext)")
            try file.data.write(to: url)
            copy = url
        }
        defer { copy.map { try? FileManager.default.removeItem(at: $0) } }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let transcript = try await AppModel.shared.transcribe(.init(file: url, language: language, prompt: nil))
        return .result(value: transcript.text)
    }
}

struct RefrainShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TranscribeFile(), phrases: ["Transcribe an audio file with \(.applicationName)"],
                    shortTitle: "Transcribe Audio File", systemImageName: "waveform")
    }
}
