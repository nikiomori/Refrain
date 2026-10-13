import Foundation

/// A `multipart/form-data` body already on disk. Text fields are read into memory; the `file`
/// part is copied out to a file of its own, keeping the client's extension, which AVFoundation
/// goes by. The body is memory-mapped, so a long recording is never loaded whole.
struct Multipart {
    var fields: [String: String] = [:]
    var file: URL?

    static func boundary(in contentType: String) -> String? {
        guard contentType.lowercased().hasPrefix("multipart/form-data") else { return nil }
        return contentType.firstMatch(of: #/;\s*boundary="?([^";]+)"?/#.ignoresCase()).map { String($0.1) }
    }

    init(body: URL, boundary: String, fileDirectory: URL) throws {
        let data = try Data(contentsOf: body, options: .alwaysMapped)
        let malformed = HTTPError(400, "The multipart body is malformed.")
        try data.withUnsafeBytes { bytes in
            let delimiter = Array("\r\n--\(boundary)".utf8)
            // The first delimiter isn't preceded by a line break.
            guard let first = Self.find(Array(delimiter.dropFirst(2)), in: bytes, from: 0) else { throw malformed }
            var cursor = first + delimiter.count - 2
            // After a delimiter, a line break starts a part and "--" ends the body.
            while cursor + 2 <= bytes.count, bytes[cursor] == 0x0D, bytes[cursor + 1] == 0x0A {
                guard let headersEnd = Self.find(Array("\r\n\r\n".utf8), in: bytes, from: cursor + 2),
                      let next = Self.find(delimiter, in: bytes, from: headersEnd + 4)
                else { throw malformed }
                let headers = String(decoding: UnsafeRawBufferPointer(rebasing: bytes[(cursor + 2)..<headersEnd]), as: UTF8.self)
                let content = UnsafeRawBufferPointer(rebasing: bytes[(headersEnd + 4)..<next])
                try take(headers: headers, content: content, fileDirectory: fileDirectory)
                cursor = next + delimiter.count
            }
        }
    }

    private mutating func take(headers: String, content: UnsafeRawBufferPointer, fileDirectory: URL) throws {
        guard let name = headers.firstMatch(of: #/;\s*name="([^"]*)"/#)?.1 else { return }
        guard name == "file" else {
            fields[String(name)] = String(decoding: content, as: UTF8.self)
            return
        }
        guard file == nil else { return }  // one file per request; a second would be left on disk
        let filename = headers.firstMatch(of: #/;\s*filename="([^"]*)"/#).map { String($0.1) } ?? ""
        let suffix = URL(filePath: filename).pathExtension
        let ext = !suffix.isEmpty && suffix.count <= 8 && suffix.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } ? suffix : "m4a"
        let url = fileDirectory.appending(path: "\(UUID().uuidString).\(ext)")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        file = url
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: content)
    }

    private static func find(_ needle: [UInt8], in haystack: UnsafeRawBufferPointer, from start: Int) -> Int? {
        guard let base = haystack.baseAddress, start < haystack.count else { return nil }
        return needle.withUnsafeBytes { needle in
            memmem(base + start, haystack.count - start, needle.baseAddress, needle.count).map { base.distance(to: $0) }
        }
    }
}
