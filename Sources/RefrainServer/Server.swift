import Foundation
import RefrainKit

/// What a `POST /v1/audio/transcriptions` asks for. `file` is a temporary copy of the upload,
/// deleted once the response is sent.
public struct TranscriptionRequest: Sendable {
    public var file: URL
    public var language: String?
    public var prompt: String?
    /// Spellings to listen for, ahead of the names in `prompt`.
    public var keywords: [String] = []
    /// Tell the voices apart (`diarized_json`).
    public var speakers = false
    /// How many voices the client says there are (`min_speakers`, `max_speakers`); none: as many as are heard.
    public var minSpeakers: Int?
    public var maxSpeakers: Int?

    public init(file: URL, language: String?, prompt: String?, keywords: [String] = [], speakers: Bool = false,
                minSpeakers: Int? = nil, maxSpeakers: Int? = nil) {
        self.file = file
        self.language = language
        self.prompt = prompt
        self.keywords = keywords
        self.speakers = speakers
        self.minSpeakers = minSpeakers
        self.maxSpeakers = maxSpeakers
    }
}

/// The OpenAI-compatible endpoint on 127.0.0.1, one HTTP/1.1 request per connection, on BSD
/// sockets: Network.framework's listener held ~0.3 MB at rest for one loopback port.
///
/// Web pages are kept out: only the loopback address listens, `Host` must
/// name it (no DNS rebinding), a browser's `Origin` is refused, and there are no CORS headers.
/// Native clients and Electron (`app://`) send neither.
public final class Server: Sendable {
    /// Big enough for an hour of uncompressed stereo; the file is streamed to disk, never held.
    static let maxBody = 2 << 30

    /// Uploads in flight, beside the 16 kHz copies made of them. The app deletes it whole at launch:
    /// what a crash left behind is someone's voice.
    public static let uploads = Transcription.scratch

    /// The one it listens on; the free one picked for 0.
    public let port: UInt16

    private let listener: Socket
    private let remotes: @Sendable () async -> [Remote]
    private let transcribe: @Sendable (TranscriptionRequest) async throws -> Transcript

    /// Listening from here on; `port` 0 picks a free one (tests). Throws `POSIXError.EADDRINUSE`
    /// when another app has the port. `remotes` are asked for at each request, so they're current.
    public init(port: UInt16, remotes: @escaping @Sendable () async -> [Remote] = { [] },
                transcribe: @escaping @Sendable (TranscriptionRequest) async throws -> Transcript) throws {
        listener = try Socket.listen(port: port)
        self.port = listener.port
        self.remotes = remotes
        self.transcribe = transcribe
    }

    /// Serves until the task is cancelled, which also cuts off the requests in progress.
    public func run() async {
        await withDiscardingTaskGroup { group in
            while let connection = try? await listener.accept() {
                group.addTask { await self.serve(connection) }
            }
        }
    }

    private func serve(_ connection: Socket) async {
        let response: Response
        do {
            response = try await respond(on: connection)
        } catch let error as HTTPError {
            response = .error(error.status, error.message)
        } catch {
            response = .error(500, error.localizedDescription)  // the disk, or a client already gone
        }
        try? await connection.send(response.serialized)
        await connection.finish()
    }

    private func respond(on connection: Socket) async throws -> Response {
        var buffer = Data()
        while buffer.firstRange(of: Data("\r\n\r\n".utf8)) == nil {
            guard buffer.count < 16_384 else { throw HTTPError(431, "The request headers are too large.") }
            let chunk = try await connection.receive(atMost: 16_384)
            guard !chunk.isEmpty else { throw HTTPError(400, "The request ended early.") }
            buffer.append(chunk)
        }
        let end = buffer.firstRange(of: Data("\r\n\r\n".utf8))!
        let head = try Head(String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
        try head.check(port: port)

        switch (head.method, head.path) {
        case ("GET", "/v1/models"):
            // Reprise knows Refrain by `"owned_by":"refrain"`.
            let others = await remotes().map { Models.Model(id: $0.id, owned_by: $0.url.host() ?? "") }
            return .json(Models(data: [.init(id: "auto", owned_by: "refrain")] + others))
        case ("POST", "/v1/audio/transcriptions"):
            break
        case (_, "/v1/models"), (_, "/v1/audio/transcriptions"):
            throw HTTPError(405, "\(head.method) isn't supported here.")
        default:
            throw HTTPError(404, "Refrain serves POST /v1/audio/transcriptions and GET /v1/models.")
        }

        guard let length = head.headers["content-length"].flatMap(Int.init), length >= 0 else {
            throw HTTPError(411, "Send the body with a Content-Length.")
        }
        guard length <= Self.maxBody else { throw HTTPError(413, "The upload is larger than 2 GB.") }
        guard let type = head.headers["content-type"], let boundary = Multipart.boundary(in: type) else {
            throw HTTPError(415, "Send the audio as multipart/form-data, as for OpenAI.")
        }
        if head.headers["expect"]?.lowercased() == "100-continue" {
            try await connection.send(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
        }

        // Streamed to disk: an upload is never held in memory, and it's gone after the response.
        try FileManager.default.createDirectory(at: Self.uploads, withIntermediateDirectories: true)
        let body = Self.uploads.appending(path: "\(UUID().uuidString).body")
        defer { try? FileManager.default.removeItem(at: body) }
        FileManager.default.createFile(atPath: body.path, contents: nil)
        let handle = try FileHandle(forWritingTo: body)
        var received = buffer.count - end.upperBound
        try handle.write(contentsOf: buffer[end.upperBound...])
        while received < length {
            let chunk = try await connection.receive(atMost: min(1 << 20, length - received))
            guard !chunk.isEmpty else { throw HTTPError(400, "The upload ended early.") }
            try handle.write(contentsOf: chunk)
            received += chunk.count
        }
        try handle.close()

        let form = try Multipart(body: body, boundary: boundary, fileDirectory: Self.uploads)
        try? FileManager.default.removeItem(at: body)  // the file is out of it: not kept through the transcription
        defer { form.file.map { try? FileManager.default.removeItem(at: $0) } }
        guard let file = form.file else { throw HTTPError(400, "The request has no `file`.") }
        // Another service's model: on to it, outside the queue, which is for this Mac's engines.
        if let id = form["model"], let remote = await remotes().first(where: { $0.id == id }) {
            return try await whileConnected(connection) { try await remote.forward(form, file: file) }
        }
        let format = form["response_format"] ?? "json"
        guard ["json", "text", "verbose_json", "diarized_json", "srt", "vtt"].contains(format) else {
            throw HTTPError(400, "response_format must be json, text, verbose_json, diarized_json, srt or vtt.")
        }
        // `languages[]` and `keywords[]` are what OpenAI's gpt-transcribe takes; the first language picks the engine.
        let language = form["language"] ?? form.list("languages").first

        // pyannote's and whisperX's servers take these: a call's mix has at least two voices, and
        // untold, one that speaks little is taken for the one that speaks most.
        func count(_ name: String) throws -> Int? {
            guard let value = form[name] else { return nil }
            guard let count = Int(value), count >= 1 else { throw HTTPError(400, "\(name) must be a whole number from 1.") }
            return count
        }
        let minSpeakers = try count("min_speakers"), maxSpeakers = try count("max_speakers")
        if let minSpeakers, let maxSpeakers, minSpeakers > maxSpeakers {
            throw HTTPError(400, "min_speakers can't be more than max_speakers.")
        }
        let request = TranscriptionRequest(file: file, language: language, prompt: form["prompt"],
                                           keywords: form.list("keywords"), speakers: format == "diarized_json",
                                           minSpeakers: minSpeakers, maxSpeakers: maxSpeakers)
        let transcript: Transcript
        do {
            transcript = try await whileConnected(connection) { [transcribe] in try await transcribe(request) }
        } catch let error as TranscriptionError {
            if case .unsupportedSystem = error { throw HTTPError(500, error.localizedDescription) }
            throw HTTPError(400, error.localizedDescription)
        } catch {
            throw HTTPError(500, error.localizedDescription)
        }
        switch format {
        case "text": return .text(transcript.text + "\n")
        case "srt": return .text(Subtitles.srt(transcript.segments))
        case "vtt": return .text(Subtitles.vtt(transcript.segments), type: "text/vtt")
        case "diarized_json": return .json(Diarized(transcript))
        case "verbose_json":
            let granularities = Set(form.list("timestamp_granularities"))
            return .json(Verbose(transcript, segments: granularities.isEmpty || granularities.contains("segment"),
                                 words: granularities.contains("word")))
        default: return .json(["text": transcript.text])
        }
    }

    /// `work`, for as long as the client waits for it. One that hangs up (a timeout, an SDK's
    /// retry, a newer take) cancels it rather than leaving it to hold up the queue: a client sends
    /// nothing after its request, so the connection's next read ends only when it's gone.
    private func whileConnected<T: Sendable>(_ connection: Socket,
                                             _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await work() }
            group.addTask {
                while let chunk = try? await connection.receive(atMost: 1 << 16), !chunk.isEmpty {}
                return nil
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() ?? nil else { throw CancellationError() }
            return result
        }
    }
}

/// The request line and headers, header names lowercased.
struct Head {
    var method: String
    var path: String
    var headers: [String: String] = [:]

    init(_ text: String) throws {
        let lines = text.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { throw HTTPError(400, "Not an HTTP/1.1 request.") }
        method = String(parts[0])
        path = String(parts[1].prefix { $0 != "?" })
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
    }

    /// `Host` names this server, so a rebound DNS name can't reach it, and no browser `Origin`
    /// (`null` is a sandboxed frame or a local file). `host.docker.internal` is how Docker Desktop
    /// reaches the Mac (Open WebUI, LibreChat); `.internal` never resolves publicly, so no page can rebind it.
    func check(port: UInt16) throws {
        guard let host = headers["host"]?.lowercased(),
              ["127.0.0.1:\(port)", "localhost:\(port)", "host.docker.internal:\(port)"].contains(host) else {
            throw HTTPError(403, "Use http://127.0.0.1:\(port)/v1.")
        }
        if let origin = headers["origin"]?.lowercased(),
           origin == "null" || origin.hasPrefix("http:") || origin.hasPrefix("https:") {
            throw HTTPError(403, "Web pages can't use Refrain.")
        }
    }
}

struct HTTPError: Error {
    var status: Int
    var message: String
    init(_ status: Int, _ message: String) {
        self.status = status
        self.message = message
    }
}

struct Response {
    var status: Int
    var type: String
    var body: Data

    static func json(_ value: some Encodable) -> Response {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return Response(status: 200, type: "application/json", body: (try? encoder.encode(value)) ?? Data())
    }

    static func json(_ text: String) -> Response {
        Response(status: 200, type: "application/json", body: Data(text.utf8))
    }

    static func text(_ text: String, type: String = "text/plain") -> Response {
        Response(status: 200, type: "\(type); charset=utf-8", body: Data(text.utf8))
    }

    /// OpenAI's error shape, which clients already know how to show.
    static func error(_ status: Int, _ message: String) -> Response {
        let type = status >= 500 ? "server_error" : "invalid_request_error"
        var response = json(["error": ["message": message, "type": type]])
        response.status = status
        return response
    }

    /// No reason phrase: HTTP/1.1 makes it optional, and clients go by the code.
    var serialized: Data {
        let head = "HTTP/1.1 \(status) \r\nContent-Type: \(type)\r\n"
            + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

/// `GET /v1/models`: `auto`, this Mac's engines, and other services' models.
struct Models: Encodable {
    struct Model: Encodable {
        var id: String
        var object = "model"
        var created = 0
        var owned_by: String
    }

    var object = "list"
    var data: [Model]
}

/// `verbose_json` as OpenAI writes it: segments unless only words were asked for, words if asked for.
struct Verbose: Encodable {
    struct Segment: Encodable {
        var id: Int
        var start: Double
        var end: Double
        var text: String
    }

    struct Word: Encodable {
        var word: String
        var start: Double
        var end: Double
    }

    var task = "transcribe"
    /// OpenAI names the language in English ("russian"), not by code.
    var language: String?
    var duration: Double
    var text: String
    var segments: [Segment]?
    var words: [Word]?

    init(_ transcript: Transcript, segments: Bool = true, words: Bool = false) {
        language = transcript.language.flatMap { Locale(identifier: "en").localizedString(forLanguageCode: $0)?.lowercased() }
        duration = transcript.duration
        text = transcript.text
        if segments {
            self.segments = transcript.segments.enumerated().map { .init(id: $0, start: $1.start, end: $1.end, text: $1.text) }
        }
        if words { self.words = transcript.words.map { .init(word: $0.text, start: $0.start, end: $0.end) } }
    }
}

/// `diarized_json` as OpenAI writes it for gpt-4o-transcribe-diarize: phrases with their voice.
struct Diarized: Encodable {
    struct Segment: Encodable {
        var type = "transcript.text.segment"
        var id: String
        var start: Double
        var end: Double
        var text: String
        var speaker: String
    }

    var task = "transcribe"
    var duration: Double
    var text: String
    var segments: [Segment]

    init(_ transcript: Transcript) {
        duration = transcript.duration
        text = transcript.text
        segments = transcript.segments.enumerated().map {
            .init(id: "seg_\($0)", start: $1.start, end: $1.end, text: $1.text, speaker: $1.speaker ?? "A")
        }
    }
}

/// SubRip and WebVTT, one cue per segment.
enum Subtitles {
    static func srt(_ segments: [Transcript.Segment]) -> String {
        segments.enumerated().map { "\($0 + 1)\n\(time($1.start, ",")) --> \(time($1.end, ","))\n\($1.text)\n\n" }.joined()
    }

    static func vtt(_ segments: [Transcript.Segment]) -> String {
        "WEBVTT\n\n" + segments.map { "\(time($0.start, ".")) --> \(time($0.end, "."))\n\($0.text)\n\n" }.joined()
    }

    /// 01:02:03,456 — SubRip separates the milliseconds with a comma, WebVTT with a dot.
    static func time(_ seconds: Double, _ separator: String) -> String {
        let ms = Int((seconds * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, separator, ms % 1000)
    }
}
