import Foundation
import RefrainKit
import Network
import Testing
@testable import RefrainServer

/// Real HTTP over loopback against a stub engine: request parsing, multipart, the web-page
/// guards and the response formats, everything but the speech models.
@Suite struct ServerTests {
    let server: Server
    let seen = Seen()

    init() async throws {
        let ready = AsyncStream.makeStream(of: Server.State.self)
        let seen = seen
        server = try Server(port: 0, transcribe: { request in
            await seen.record(request)
            return Transcript(text: "Привет, мир.", segments: [.init(start: 0, end: 1.5, text: "Привет, мир.")],
                              language: "ru", duration: 1.5)
        }, onState: { ready.continuation.yield($0) })
        for await state in ready.stream { #expect(state == .ready); break }
    }

    @Test func transcribesAMultipartUpload() async throws {
        let audio = Data((0..<100_000).map { UInt8($0 % 251) })
        let (status, body) = try await send(upload(audio, fields: ["language": "ru", "prompt": "Звонок с Дубиной"]))
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
        let (status, body) = try await send(upload(Data([1, 2, 3]), fields: ["response_format": "verbose_json"]))
        #expect(status == 200)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["language"] as? String == "russian")
        #expect(json["duration"] as? Double == 1.5)
        let segment = try #require((json["segments"] as? [[String: Any]])?.first)
        #expect(segment["end"] as? Double == 1.5)
        #expect(segment["text"] as? String == "Привет, мир.")
    }

    @Test func plainText() async throws {
        let (status, body) = try await send(upload(Data([1]), fields: ["response_format": "text"]))
        #expect(status == 200)
        #expect(String(decoding: body, as: UTF8.self) == "Привет, мир.\n")
    }

    @Test func listsTheOneModel() async throws {
        let (status, body) = try await send(Data("GET /v1/models HTTP/1.1\r\nHost: localhost:\(server.port)\r\n\r\n".utf8))
        #expect(status == 200)
        #expect(String(decoding: body, as: UTF8.self).contains(#""id":"auto""#))
    }

    @Test func refusesAnotherHost() async throws {
        let (status, _) = try await send(Data("GET /v1/models HTTP/1.1\r\nHost: evil.example:\(server.port)\r\n\r\n".utf8))
        #expect(status == 403)
    }

    @Test func refusesWebPages() async throws {
        for origin in ["https://evil.example", "http://localhost:3000", "null"] {
            let (status, _) = try await send(upload(Data([1]), fields: [:], extraHeaders: "Origin: \(origin)\r\n"))
            #expect(status == 403)
        }
        let (status, _) = try await send(upload(Data([1]), fields: [:], extraHeaders: "Origin: app://obsidian.md\r\n"))
        #expect(status == 200)
    }

    @Test func answersExpectContinue() async throws {
        let (status, _) = try await send(upload(Data([1]), fields: [:], extraHeaders: "Expect: 100-continue\r\n"))
        #expect(status == 200)
    }

    private func upload(_ audio: Data, fields: [String: String], extraHeaders: String = "") -> Data {
        let boundary = "----test\(UUID().uuidString)"
        var body = Data()
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)
        }
        body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"call.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)
        body += audio + Data("\r\n--\(boundary)--\r\n".utf8)
        let head = "POST /v1/audio/transcriptions HTTP/1.1\r\nHost: 127.0.0.1:\(server.port)\r\n\(extraHeaders)"
            + "Content-Type: multipart/form-data; boundary=\(boundary)\r\nContent-Length: \(body.count)\r\n\r\n"
        return Data(head.utf8) + body
    }

    /// Raw TCP, since URLSession won't let a test forge `Host`.
    private func send(_ request: Data) async throws -> (Int, Data) {
        let connection = NWConnection(host: "127.0.0.1", port: .init(rawValue: server.port)!, using: .tcp)
        connection.start(queue: .global())
        defer { connection.cancel() }
        try await connection.send(request)
        var response = Data()
        while let chunk = try await connection.receive(upTo: 1 << 20) { response += chunk }
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
    func record(_ request: TranscriptionRequest) {
        self.request = request
        bytes = try? Data(contentsOf: request.file)
    }
}
