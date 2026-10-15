import Foundation
import RefrainKit
import Network
import Testing
@testable import RefrainServer

/// Real HTTP over loopback against a stub engine: request parsing, multipart, the web-page
/// guards and the response formats, everything but the speech models.
@Suite struct ServerTests {
    let port: UInt16
    let seen = Seen()
    /// Another service, as raw HTTP.
    let upstream: Socket

    init() async throws {
        let seen = seen
        upstream = try Socket.listen(port: 0)
        let remote = Remote(id: "groq/whisper-large-v3-turbo", url: URL(string: "http://127.0.0.1:\(upstream.port)/v1")!,
                            model: "whisper-large-v3-turbo", key: { "sk-test" })
        let server = try Server(port: 0, remotes: { [remote] }, transcribe: { request in
            await seen.record(request)
            if request.prompt == "hang up" {  // a long file, for a client that won't wait
                do { try await Task.sleep(for: .seconds(30)) } catch { await seen.cancel(); throw error }
            }
            return Transcript(text: "Привет, мир.", segments: [.init(start: 0, end: 1.5, text: "Привет, мир.", speaker: "B")],
                              words: [.init(start: 0, end: 0.6, text: "Привет,"), .init(start: 0.7, end: 1.5, text: "мир.")],
                              language: "ru", duration: 1.5)
        })
        Task { await server.run() }
        port = server.port
    }

    /// Settings say which port is taken by another app, rather than listening on another.
    @Test func aTakenPortIsSaidSo() throws {
        #expect(throws: POSIXError(.EADDRINUSE)) {
            try Server(port: port) { _ in throw TranscriptionError.unreadableAudio }
        }
    }

    @Test func transcribesAMultipartUpload() async throws {
        let audio = Data((0..<100_000).map { UInt8($0 % 251) })
        let (status, body) = try await send(upload(audio, fields: [("language", "ru"), ("prompt", "Звонок с Дубиной")]))
        #expect(status == 200)
        #expect(String(decoding: body, as: UTF8.self) == #"{"text":"Привет, мир."}"#)
        let request = try #require(await seen.request)
        #expect(request.language == "ru")
        #expect(request.prompt == "Звонок с Дубиной")
        #expect(request.file.pathExtension == "wav")
        #expect(await seen.bytes == audio)
        // Nothing of the upload is left behind.
        #expect(!FileManager.default.fileExists(atPath: request.file.path))
    }

    @Test func verboseJSON() async throws {
        let (status, body) = try await send(upload(Data([1, 2, 3]), fields: [("response_format", "verbose_json")]))
        #expect(status == 200)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["language"] as? String == "russian")
        #expect(json["duration"] as? Double == 1.5)
        let segment = try #require((json["segments"] as? [[String: Any]])?.first)
        #expect(segment["end"] as? Double == 1.5)
        #expect(segment["text"] as? String == "Привет, мир.")
    }

    @Test func wordsWhenAskedFor() async throws {
        let (_, body) = try await send(upload(Data([1]), fields: [("response_format", "verbose_json"),
                                                                   ("timestamp_granularities[]", "word")]))
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        // Only words were asked for, as OpenAI answers it.
        #expect(json["segments"] == nil)
        let word = try #require((json["words"] as? [[String: Any]])?.last)
        #expect(word["word"] as? String == "мир.")
        #expect(word["start"] as? Double == 0.7)
    }

    /// OpenAI's shape for gpt-4o-transcribe-diarize, which Reprise asks for on the others' side.
    @Test func diarizedJSON() async throws {
        let (status, body) = try await send(upload(Data([1]), fields: [("response_format", "diarized_json"), ("chunking_strategy", "auto")]))
        #expect(status == 200)
        #expect(await seen.request?.speakers == true)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let segment = try #require((json["segments"] as? [[String: Any]])?.first)
        #expect(segment["type"] as? String == "transcript.text.segment")
        #expect(segment["speaker"] as? String == "B")
        #expect(segment["text"] as? String == "Привет, мир.")
    }

    @Test func subtitles() async throws {
        let (_, srt) = try await send(upload(Data([1]), fields: [("response_format", "srt")]))
        #expect(String(decoding: srt, as: UTF8.self) == "1\n00:00:00,000 --> 00:00:01,500\nПривет, мир.\n\n")
        let (_, vtt) = try await send(upload(Data([1]), fields: [("response_format", "vtt")]))
        #expect(String(decoding: vtt, as: UTF8.self) == "WEBVTT\n\n00:00:00.000 --> 00:00:01.500\nПривет, мир.\n\n")
        #expect(Subtitles.time(3723.4567, ",") == "01:02:03,457")
    }

    /// gpt-transcribe's lists: the first language picks the engine, keywords go to it as given.
    @Test func languagesAndKeywordsLists() async throws {
        _ = try await send(upload(Data([1]), fields: [("languages[]", "uk"), ("languages[]", "ru"),
                                                       ("keywords[]", "Refrain"), ("keywords[]", "Дубина")]))
        let request = try #require(await seen.request)
        #expect(request.language == "uk")
        #expect(request.keywords == ["Refrain", "Дубина"])
    }

    @Test func plainText() async throws {
        let (status, body) = try await send(upload(Data([1]), fields: [("response_format", "text")]))
        #expect(status == 200)
        #expect(String(decoding: body, as: UTF8.self) == "Привет, мир.\n")
    }

    @Test func listsTheModels() async throws {
        let (status, body) = try await send(Data("GET /v1/models HTTP/1.1\r\nHost: localhost:\(port)\r\n\r\n".utf8))
        #expect(status == 200)
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains(#""id":"auto""#) && text.contains(#""owned_by":"refrain""#))
        #expect(text.contains(#""id":"groq/whisper-large-v3-turbo""#))
    }

    /// Another service's model: the request goes on to it under the service's own name and with
    /// the key, and its answer, an error here, comes back as is.
    @Test func forwardsAnotherServicesModel() async throws {
        let upstream = upstream
        let forwarded = Task {
            let connection = try await upstream.accept()
            var request = Data()
            while !request.reversed().starts(with: Data("\n\r--".utf8)) {
                let chunk = try await connection.receive(atMost: 1 << 20)
                guard !chunk.isEmpty else { break }
                request += chunk
            }
            let answer = #"{"error":{"message":"Invalid API Key"}}"#
            try await connection.send(Data("HTTP/1.1 401 \r\nContent-Type: application/json\r\nContent-Length: \(answer.utf8.count)\r\n\r\n\(answer)".utf8))
            await connection.finish()
            return String(decoding: request, as: UTF8.self)
        }
        let (status, body) = try await send(upload(Data("RIFF".utf8), fields: [("model", "groq/whisper-large-v3-turbo"), ("language", "ru")]))
        #expect(status == 401)
        #expect(String(decoding: body, as: UTF8.self) == #"{"error":{"message":"Invalid API Key"}}"#)
        let request = try await forwarded.value
        #expect(request.hasPrefix("POST /v1/audio/transcriptions "))
        #expect(request.contains("Authorization: Bearer sk-test\r\n"))
        #expect(request.contains("name=\"model\"\r\n\r\nwhisper-large-v3-turbo\r\n"))
        #expect(request.contains("name=\"language\"\r\n\r\nru\r\n"))
        #expect(request.contains("filename=\"audio.wav\"\r\nContent-Type: application/octet-stream\r\n\r\nRIFF\r\n"))
        #expect(await seen.request == nil)  // not this Mac's engines
    }

    @Test func refusesAnotherHost() async throws {
        let (status, _) = try await send(Data("GET /v1/models HTTP/1.1\r\nHost: evil.example:\(port)\r\n\r\n".utf8))
        #expect(status == 403)
    }

    /// Open WebUI and LibreChat in Docker Desktop reach the Mac by this name.
    @Test func acceptsDocker() async throws {
        let (status, _) = try await send(Data("GET /v1/models HTTP/1.1\r\nHost: host.docker.internal:\(port)\r\n\r\n".utf8))
        #expect(status == 200)
    }

    @Test func refusesWebPages() async throws {
        for origin in ["https://evil.example", "http://localhost:3000", "null"] {
            let (status, _) = try await send(upload(Data([1]), fields: [], extraHeaders: "Origin: \(origin)\r\n"))
            #expect(status == 403)
        }
        let (status, _) = try await send(upload(Data([1]), fields: [], extraHeaders: "Origin: app://obsidian.md\r\n"))
        #expect(status == 200)
    }

    @Test func answersExpectContinue() async throws {
        let (status, _) = try await send(upload(Data([1]), fields: [], extraHeaders: "Expect: 100-continue\r\n"))
        #expect(status == 200)
    }

    /// A client that gives up stops its transcription, rather than leaving it to hold up the queue.
    @Test func aHangUpCancels() async throws {
        guard #available(macOS 26.0, *) else { return }
        let connection = NetworkConnection(to: .hostPort(host: "127.0.0.1", port: .init(rawValue: port)!)) { TCP() }
        try await connection.send(upload(Data([1]), fields: [("prompt", "hang up")]))
        while await seen.request == nil { try await Task.sleep(for: .milliseconds(10)) }
        try await connection.send(Data(), endOfStream: true)
        for _ in 0..<200 where await !seen.cancelled { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await seen.cancelled)
    }

    /// A body that breaks after its file part: the audio already copied out is deleted with the error.
    @Test func aMalformedBodyLeavesNoAudio() throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let body = folder.appending(path: "body")
        try Data("--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\n\r\nRIFF\r\n--B\r\nbroken".utf8).write(to: body)
        let audio = folder.appending(path: "audio")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        #expect(throws: HTTPError.self) { try Multipart(body: body, boundary: "B", fileDirectory: audio) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: audio.path).isEmpty)
    }

    private func upload(_ audio: Data, fields: [(String, String)], extraHeaders: String = "") -> Data {
        let boundary = "----test\(UUID().uuidString)"
        var body = Data()
        for (name, value) in fields {
            body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)
        }
        body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"call.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)
        body += audio + Data("\r\n--\(boundary)--\r\n".utf8)
        let head = "POST /v1/audio/transcriptions HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\(extraHeaders)"
            + "Content-Type: multipart/form-data; boundary=\(boundary)\r\nContent-Length: \(body.count)\r\n\r\n"
        return Data(head.utf8) + body
    }

    /// Raw TCP, since URLSession won't let a test forge `Host`.
    private func send(_ request: Data) async throws -> (Int, Data) {
        guard #available(macOS 26.0, *) else { throw TranscriptionError.unsupportedSystem }
        let connection = NetworkConnection(to: .hostPort(host: "127.0.0.1", port: .init(rawValue: port)!)) { TCP() }
        try await connection.send(request)
        var response = Data()
        while true {
            do {
                let chunk = try await connection.receive(atMost: 1 << 20).content
                if chunk.isEmpty { break }
                response += chunk
            } catch where !response.isEmpty {
                break  // at the end, Network sometimes throws ENODATA rather than reading nothing
            }
        }
        // A 100 Continue may come first.
        var text = String(decoding: response, as: UTF8.self)
        if text.hasPrefix("HTTP/1.1 100") { text = String(text.split(separator: "\r\n\r\n", maxSplits: 1)[1]) }
        let parts = text.components(separatedBy: "\r\n\r\n")
        let status = Int(parts[0].split(separator: " ")[1])!
        return (status, Data(parts.dropFirst().joined(separator: "\r\n\r\n").utf8))
    }
}

actor Seen {
    var request: TranscriptionRequest?
    var bytes: Data?
    var cancelled = false
    func cancel() { cancelled = true }
    func record(_ request: TranscriptionRequest) {
        self.request = request
        bytes = try? Data(contentsOf: request.file)
    }
}
