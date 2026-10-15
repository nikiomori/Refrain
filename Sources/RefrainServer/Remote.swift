import Foundation

/// A model of another OpenAI-compatible service that apps reach through Refrain by `id`: the
/// request goes on to the service's own `POST …/audio/transcriptions`, its answer comes back as is.
public struct Remote: Sendable {
    /// What apps ask for: `groq/whisper-large-v3-turbo`.
    public var id: String
    /// The service's base address: `https://api.groq.com/openai/v1`.
    public var url: URL
    /// The service's own name for it.
    public var model: String
    /// Read when a request goes out, not for every request that names a model: Pretype sends
    /// `auto` every second while it dictates.
    public var key: @Sendable () -> String?

    public init(id: String, url: URL, model: String, key: @escaping @Sendable () -> String?) {
        self.id = id
        self.url = url
        self.model = model
        self.key = key
    }

    /// The request's fields and file, but for the model's own name. The service's status, type
    /// and body are passed back untouched: its errors are already in OpenAI's shape.
    func forward(_ form: Multipart, file: URL) async throws -> Response {
        let boundary = "refrain-\(UUID().uuidString)"
        var head = ""
        // A name that would break out of its header line is dropped.
        for (name, value) in form.fields where name != "model" && !name.contains(where: { "\r\n\"".contains($0) }) {
            head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
        }
        head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(model)\r\n"
        // The extension is how the service tells the format.
        head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.\(file.pathExtension)\"\r\n"
            + "Content-Type: application/octet-stream\r\n\r\n"

        // On disk beside the upload, gone with it, and swept at launch like it.
        let body = Server.uploads.appending(path: "\(UUID().uuidString).body")
        defer { try? FileManager.default.removeItem(at: body) }
        FileManager.default.createFile(atPath: body.path, contents: nil)
        let handle = try FileHandle(forWritingTo: body)
        try handle.write(contentsOf: Data(head.utf8))
        try handle.write(contentsOf: Data(contentsOf: file, options: .alwaysMapped))
        try handle.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        try handle.close()

        // Long files take the service a while before the first byte of its answer.
        var request = URLRequest(url: url.appending(path: "audio/transcriptions"), timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let key = key(), !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        do {
            let (data, response) = try await URLSession.shared.upload(for: request, fromFile: body)
            let http = response as? HTTPURLResponse
            return Response(status: http?.statusCode ?? 502,
                            type: http?.value(forHTTPHeaderField: "Content-Type") ?? "application/json", body: data)
        } catch let error as URLError where error.code != .cancelled {
            throw HTTPError(502, "\(url.host() ?? id) didn't answer: \(error.localizedDescription)")
        }
    }
}
