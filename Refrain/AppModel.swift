import AppKit
import RefrainKit
import RefrainServer
import Observation
import os
import Security

nonisolated let log = Logger(subsystem: "dev.nikiomori.refrain", category: "app")

/// The server, the one-at-a-time queue in front of the engines, and what the menu shows.
@Observable final class AppModel {
    static let shared = AppModel()

    enum Status: Equatable {
        case ready
        case transcribing
        case failed(String)
    }

    private(set) var status = Status.ready
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

    /// When the menu bar item shows. Hidden, Refrain opened again from Finder or Spotlight shows Settings.
    enum MenuBarIcon: String { case always, working, never }
    var menuBarIcon = MenuBarIcon(rawValue: UserDefaults.standard.string(forKey: "menuBarIcon") ?? "") ?? .always {
        didSet { UserDefaults.standard.set(menuBarIcon.rawValue, forKey: "menuBarIcon") }
    }

    /// Another OpenAI-compatible service, whose models apps ask Refrain for as `name/model`.
    /// Its key is in the Keychain, under its `id`.
    struct Provider: Codable, Identifiable, Hashable {
        var id = UUID()
        /// The first half of its models' names for apps: `groq` in `groq/whisper-large-v3-turbo`.
        var name: String
        /// Its base address: `https://api.groq.com/openai/v1`.
        var url: String
        /// Its own names for them, separated by commas or spaces.
        var models: String

        /// Its models as the server forwards them; none until it has a name, an address and a model.
        var remotes: [Remote] {
            guard !name.isEmpty, let url = URL(string: url.trimmingCharacters(in: .whitespaces)),
                  url.scheme == "https" || url.scheme == "http", url.host() != nil else { return [] }
            let account = id.uuidString
            return models.split { $0 == "," || $0.isWhitespace }.map {
                Remote(id: "\(name)/\($0)", url: url, model: String($0), key: { Keychain.read(account: account) })
            }
        }

        static let presets: [(title: String, provider: Provider)] = [
            ("OpenAI", Provider(name: "openai", url: "https://api.openai.com/v1", models: "gpt-transcribe, gpt-4o-transcribe-diarize")),
            ("Groq", Provider(name: "groq", url: "https://api.groq.com/openai/v1", models: "whisper-large-v3-turbo")),
            ("Mistral", Provider(name: "mistral", url: "https://api.mistral.ai/v1", models: "voxtral-mini-latest")),
            (String(localized: "Other"), Provider(name: "", url: "", models: "")),
        ]
    }

    var providers = (try? JSONDecoder().decode([Provider].self, from: UserDefaults.standard.data(forKey: "providers") ?? Data())) ?? [] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(providers), forKey: "providers") }
    }

    func addProvider(_ preset: Provider) {
        var provider = preset
        provider.id = UUID()
        providers.append(provider)
    }

    func removeProvider(_ provider: Provider) {
        providers.removeAll { $0.id == provider.id }
        Keychain.write(nil, account: provider.id.uuidString)
    }

    /// What the server forwards, read at each request.
    var remotes: [Remote] { providers.flatMap(\.remotes) }

    static let defaultPort = 8178
    private(set) var port = UserDefaults.standard.object(forKey: "port") as? Int ?? defaultPort
    var address: String { "http://127.0.0.1:\(port)/v1" }

    /// Parakeet, the speaker model and Apple's analyzers run in Refrain's XPC service, which quits
    /// when idle: what they load goes with it, and a crash in them doesn't take the server down.
    @ObservationIgnored private let engine = Engine()
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
    /// Also right after a download. The compiled models are the engine process's own, so the keys
    /// are too: what the app compiled before the engine moved out doesn't count.
    private func warmUp() {
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        let models: [(name: String, key: String, ready: Bool, load: @Sendable () async throws -> Void)] = [
            ("Parakeet", "engineWarmedUpOn", Parakeet.isDownloaded, engine.warmUpParakeet),
            ("The speaker model", "engineSpeakersWarmedUpOn", Speakers.isDownloaded, engine.warmUpSpeakers),
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
        guard let port = UInt16(exactly: port), port >= 1024 else {
            status = .failed(String(localized: "Choose a port from 1024 to 65535."))
            return
        }
        do {
            let server = try Server(port: port, remotes: { [self] in await remotes },
                                    transcribe: { [self] request in try await transcribe(request) })
            self.server = Task { await server.run() }
            status = .ready
            log.notice("Listening on 127.0.0.1:\(port)")
        } catch {
            status = .failed((error as? POSIXError)?.code == .EADDRINUSE
                ? String(localized: "Port \(String(port)) is used by another app.")
                : error.localizedDescription)
            log.error("Can't listen on \(port): \(error.localizedDescription, privacy: .public)")
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
            return try await engine.transcribe(file: request.file, language: request.language,
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
                try await engine.downloadParakeet { fraction in
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
            do { try await engine.warmUpSpeakers() } catch { speakersError = error.localizedDescription }
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
            await engine.deleteParakeet()
            parakeetDownloaded = Parakeet.isDownloaded
        }
    }

    func copyAddress() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
    }

    var statusText: String {
        switch status {
        case .ready: String(localized: "Ready")
        case .failed(let message): message
        case .transcribing:
            queued > 1
                ? String(localized: "Transcribing — \(progress.done.clock) of \(progress.of.clock), \(queued - 1) waiting")
                : String(localized: "Transcribing — \(progress.done.clock) of \(progress.of.clock)")
        }
    }
}

/// Services' keys, in the login Keychain: never in preferences, never in the log.
nonisolated enum Keychain {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dev.nikiomori.refrain.provider",
         kSecAttrAccount as String: account]
    }

    static func read(account: String) -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Empty or nil deletes it.
    static func write(_ value: String?, account: String) {
        SecItemDelete(query(account) as CFDictionary)
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
        var item = query(account)
        item[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
}

extension TimeInterval {
    /// 12:30, or 1:02:00 from an hour on.
    var clock: String {
        Duration.seconds(self).formatted(.time(pattern: self >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}
