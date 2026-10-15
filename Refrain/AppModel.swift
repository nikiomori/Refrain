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
        case transcribing
        case failed(String)
    }

    private(set) var status = Status.starting
    /// Seconds of audio done and the file's length, while transcribing. Apart from `status`, so
    /// the menu bar icon, which reads only that, isn't drawn anew at every step.
    private(set) var progress: (done: TimeInterval, of: TimeInterval) = (0, 0)
    /// Requests in the queue, the running one included.
    private(set) var queued = 0
    /// Parakeet's download, 0…1, while one runs.
    private(set) var downloading: Double?
    private(set) var downloadError: String?
    private(set) var parakeetDownloaded = Parakeet.isDownloaded
    private(set) var speakersDownloaded = Speakers.isDownloaded
    private(set) var downloadingSpeakers = false
    private(set) var speakersError: String?

    static let defaultPort = 8178
    private(set) var port = UserDefaults.standard.object(forKey: "port") as? Int ?? defaultPort
    var address: String { "http://127.0.0.1:\(port)/v1" }

    @ObservationIgnored private var server: Task<Void, Never>?
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var running: UUID?

    private init() {
        try? FileManager.default.removeItem(at: Server.uploads)
        listen()
        warmUp()
    }

    /// After an update of macOS the Neural Engine compiles each model anew: Parakeet ~11 s, the
    /// speaker model longer still. Done now, in the background, rather than in the first request.
    /// Also right after a download.
    private func warmUp() {
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        let models: [(name: String, key: String, ready: Bool, load: @Sendable () async throws -> Void)] = [
            ("Parakeet", "warmedUpOn", Parakeet.isDownloaded, Parakeet.warmUp),
            ("The speaker model", "speakersWarmedUpOn", Speakers.isDownloaded, Speakers.warmUp),
        ]
        for model in models where model.ready && UserDefaults.standard.string(forKey: model.key) != system {
            Task(priority: .background) {
                let started = ContinuousClock.now
                do {
                    try await model.load()
                    UserDefaults.standard.set(system, forKey: model.key)
                    log.notice("\(model.name, privacy: .public) compiled for \(system, privacy: .public) in \(started.duration(to: .now), privacy: .public)")
                } catch {
                    log.error("\(model.name, privacy: .public) warm-up: \(error.localizedDescription, privacy: .public)")
                }
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
        server?.cancel()
        server = nil
        status = .starting
        guard let port = UInt16(exactly: port), port >= 1024 else {
            status = .failed(String(localized: "Choose a port from 1024 to 65535."))
            return
        }
        do {
            let server = try Server(port: port, transcribe: { [self] request in try await transcribe(request) }, onState: { state in
                Task { @MainActor in AppModel.shared.serverChanged(state, port: port) }
            })
            self.server = Task { try? await server.run() }  // a failure reaches serverChanged too
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func serverChanged(_ state: NetworkListener<TCP>.State, port: UInt16) {
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
        default:
            break
        }
    }

    /// One at a time, in order: the Neural Engine does one file faster than two at once.
    /// From the server and from Shortcuts alike. A request whose client gives up stops, or never starts.
    func transcribe(_ request: TranscriptionRequest) async throws -> Transcript {
        let previous = tail
        let job = Task {
            await previous?.value
            try Task.checkCancellation()  // its client gave up while it waited
            let id = UUID()
            running = id
            defer {
                running = nil
                if case .transcribing = status { status = .ready }
            }
            return try await Transcription.transcribe(file: request.file, language: request.language,
                                                      prompt: request.prompt, keywords: request.keywords,
                                                      speakers: request.speakers) { done, total in
                Task { @MainActor in
                    let model = AppModel.shared
                    // Late reports of a finished file don't bring its status back.
                    guard model.running == id else { return }
                    if model.status != .transcribing { model.status = .transcribing }
                    model.progress = (done, total)
                }
            }
        }
        tail = Task { _ = try? await job.value }
        queued += 1
        defer { queued -= 1 }
        return try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
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

    /// 22 MB: a spinner, not a progress bar.
    func downloadSpeakers() {
        guard !downloadingSpeakers else { return }
        downloadingSpeakers = true
        speakersError = nil
        Task {
            do { try await Speakers.warmUp() } catch { speakersError = error.localizedDescription }
            downloadingSpeakers = false
            speakersDownloaded = Speakers.isDownloaded
        }
    }

    func deleteSpeakers() {
        Speakers.delete()
        speakersDownloaded = Speakers.isDownloaded
    }

    func deleteParakeet() {
        Task {
            await Parakeet.delete()
            parakeetDownloaded = Parakeet.isDownloaded
        }
    }

    func copyAddress() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
    }

    var statusText: String {
        switch status {
        case .starting: String(localized: "Starting…")
        case .ready: String(localized: "Ready")
        case .failed(let message): message
        case .transcribing:
            queued > 1
                ? String(localized: "Transcribing — \(progress.done.clock) of \(progress.of.clock), \(queued - 1) waiting")
                : String(localized: "Transcribing — \(progress.done.clock) of \(progress.of.clock)")
        }
    }
}

extension TimeInterval {
    /// 12:30, or 1:02:00 from an hour on.
    var clock: String {
        Duration.seconds(self).formatted(.time(pattern: self >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}
