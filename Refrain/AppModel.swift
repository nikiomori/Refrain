import AppKit
import RefrainKit
import RefrainServer
import Network
import Observation
import os

nonisolated let log = Logger(subsystem: "dev.nikiomori.refrain", category: "app")

/// The server, the one-at-a-time queue in front of the engines, and what the menu shows.
@Observable final class AppModel {
    static let shared = AppModel()

    enum Status: Equatable {
        case starting
        case ready
        case transcribing(done: TimeInterval, of: TimeInterval)
        case failed(String)
    }

    private(set) var status = Status.starting
    /// Requests in the queue, the running one included.
    private(set) var queued = 0
    /// Parakeet's download, 0…1, while one runs.
    private(set) var downloading: Double?
    private(set) var downloadError: String?
    private(set) var parakeetDownloaded = Parakeet.isDownloaded

    static let defaultPort = 8178
    private(set) var port = UserDefaults.standard.object(forKey: "port") as? Int ?? defaultPort
    var address: String { "http://127.0.0.1:\(port)/v1" }

    @ObservationIgnored private var server: Server?
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var running: UUID?

    private init() {
        try? FileManager.default.removeItem(at: Server.uploads)
        listen()
        warmUp()
    }

    /// After an update of macOS the Neural Engine compiles Parakeet anew, ~11 s: done now, in
    /// the background, rather than in the first request. Also right after the download.
    private func warmUp() {
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        guard Parakeet.isDownloaded, UserDefaults.standard.string(forKey: "warmedUpOn") != system else { return }
        Task(priority: .background) {
            do {
                try await Parakeet.warmUp()
                UserDefaults.standard.set(system, forKey: "warmedUpOn")
                log.notice("Parakeet compiled for \(system, privacy: .public)")
            } catch {
                log.error("Parakeet warm-up: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Never another port on its own: clients have this one written in their settings.
    func setPort(_ port: Int) {
        // The same port again is a retry, after another app let go of it.
        if case .failed = status {} else if port == self.port { return }
        self.port = port
        UserDefaults.standard.set(port, forKey: "port")
        listen()
    }

    private func listen() {
        server?.stop()
        server = nil
        status = .starting
        guard let port = UInt16(exactly: port), port >= 1024 else {
            status = .failed(String(localized: "Choose a port from 1024 to 65535."))
            return
        }
        do {
            server = try Server(port: port, transcribe: { [self] request in try await transcribe(request) }, onState: { state in
                Task { @MainActor in AppModel.shared.serverChanged(state, port: port) }
            })
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func serverChanged(_ state: Server.State, port: UInt16) {
        guard port == self.port else { return }  // a server already replaced
        switch state {
        case .ready:
            if case .starting = status { status = .ready }
            log.notice("Listening on 127.0.0.1:\(port)")
        case .failed(let error):
            status = .failed(error == .posix(.EADDRINUSE)
                ? String(localized: "Port \(String(port)) is used by another app.")
                : error.localizedDescription)
            log.error("Can't listen on \(port): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// One at a time, in order: the Neural Engine does one file faster than two at once.
    /// From the server and from Shortcuts alike.
    func transcribe(_ request: TranscriptionRequest) async throws -> Transcript {
        let previous = tail
        let job = Task {
            await previous?.value
            let id = UUID()
            running = id
            defer {
                running = nil
                if case .transcribing = status { status = .ready }
            }
            return try await Transcription.transcribe(file: request.file, language: request.language,
                                                      prompt: request.prompt, keywords: request.keywords) { done, total in
                Task { @MainActor in
                    // Late reports of a finished file don't bring its status back.
                    if AppModel.shared.running == id { AppModel.shared.status = .transcribing(done: done, of: total) }
                }
            }
        }
        tail = Task { _ = try? await job.value }
        queued += 1
        defer { queued -= 1 }
        return try await job.value
    }

    func downloadParakeet() {
        guard downloading == nil else { return }
        downloading = 0
        downloadError = nil
        Task {
            do {
                try await Parakeet.download { fraction in
                    Task { @MainActor in
                        if AppModel.shared.downloading != nil { AppModel.shared.downloading = fraction }
                    }
                }
            } catch {
                downloadError = error.localizedDescription
            }
            downloading = nil
            parakeetDownloaded = Parakeet.isDownloaded
            warmUp()
        }
    }

    func deleteParakeet() {
        Task {
            await Parakeet.delete()
            parakeetDownloaded = Parakeet.isDownloaded
        }
    }

    #if DEBUG
    /// For DebugSnapshots: the menu as it looks mid-transcription.
    func debugShow(_ status: Status) { self.status = status }
    #endif

    func copyAddress() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
    }

    var statusText: String {
        switch status {
        case .starting: String(localized: "Starting…")
        case .ready: String(localized: "Ready")
        case .failed(let message): message
        case .transcribing(let done, let total):
            queued > 1
                ? String(localized: "Transcribing — \(done.clock) of \(total.clock), \(queued - 1) waiting")
                : String(localized: "Transcribing — \(done.clock) of \(total.clock)")
        }
    }
}

extension TimeInterval {
    /// 12:30, or 1:02:00 from an hour on.
    var clock: String {
        Duration.seconds(self).formatted(.time(pattern: self >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}
