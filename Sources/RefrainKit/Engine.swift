import Foundation
import os

/// The engines in a process of their own, the app's XPC service: the models, and what CoreML and
/// Speech keep after them, go with it when it quits after five idle minutes, and a crash in them
/// takes down a request rather than the server. The app holds an `Engine`; the service runs an
/// `EngineService`.
@objc public protocol EngineProtocol {
    /// A `Job`, JSON-encoded; the reply is its `Outcome`.
    func run(_ job: Data, reply: @escaping @Sendable (Data) -> Void)
    func cancel(_ id: String)
}

/// What the service reports while it works: seconds of audio done, or a download's fraction of 1.
@objc public protocol EngineClientProtocol {
    func progress(_ id: String, done: Double, of total: Double)
}

struct Job: Codable {
    enum Work: Codable {
        case transcribe(file: URL, language: String?, prompt: String?, keywords: [String], speakers: Bool)
        case warmUpParakeet, downloadParakeet, warmUpSpeakers, deleteParakeet
    }

    var id: String
    var work: Work
}

enum Outcome: Codable {
    case done(Transcript?)
    /// The request's fault, not the engine's: a 400.
    case refused(TranscriptionError)
    case failed(String)
}

public enum EngineError: LocalizedError {
    case stopped
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .stopped: "The speech engine stopped. Try again."
        case .failed(let message): message
        }
    }
}

/// The app's side: each call a job for the service, which macOS starts when one comes.
@available(macOS 26.0, *)
public final class Engine: NSObject, EngineClientProtocol, @unchecked Sendable {
    private let connect: @Sendable () -> NSXPCConnection
    private let lock = OSAllocatedUnfairLock()
    private var current: NSXPCConnection?
    private var progressions: [String: @Sendable (Double, Double) -> Void] = [:]

    /// The app's XPC service, `<the app's bundle identifier>.engine`.
    override public convenience init() {
        let name = (Bundle.main.bundleIdentifier ?? "dev.nikiomori.refrain") + ".engine"
        self.init { NSXPCConnection(serviceName: name) }
    }

    init(connect: @escaping @Sendable () -> NSXPCConnection) {
        self.connect = connect
    }

    public func transcribe(file: URL, language: String?, prompt: String?, keywords: [String], speakers: Bool,
                           progress: @escaping @Sendable (_ done: TimeInterval, _ total: TimeInterval) -> Void) async throws -> Transcript {
        let work = Job.Work.transcribe(file: file, language: language, prompt: prompt, keywords: keywords, speakers: speakers)
        guard let transcript = try await run(work, progress: progress) else { throw EngineError.failed("No transcript came back.") }
        return transcript
    }

    public func warmUpParakeet() async throws { _ = try await run(.warmUpParakeet) }
    public func downloadParakeet(progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await run(.downloadParakeet) { done, _ in progress(done) }
    }
    /// Also the speaker model's download.
    public func warmUpSpeakers() async throws { _ = try await run(.warmUpSpeakers) }
    public func deleteParakeet() async { _ = try? await run(.deleteParakeet) }

    public func progress(_ id: String, done: Double, of total: Double) {
        lock.withLock { progressions[id] }?(done, total)
    }

    private func run(_ work: Job.Work, progress: (@Sendable (Double, Double) -> Void)? = nil) async throws -> Transcript? {
        let id = UUID().uuidString
        let job = try JSONEncoder().encode(Job(id: id, work: work))
        let connection = Unchecked(connection())
        lock.withLock { progressions[id] = progress }
        defer { lock.withLock { progressions[id] = nil } }
        let reply: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Exactly one of the two is called; the guard makes sure of it.
                let once = OSAllocatedUnfairLock(initialState: Optional(continuation))
                let resume = { @Sendable (result: Result<Data, Error>) in once.withLock { $0.take() }?.resume(with: result) }
                let proxy = connection.value.remoteObjectProxyWithErrorHandler { _ in resume(.failure(EngineError.stopped)) }
                (proxy as? EngineProtocol)?.run(job) { resume(.success($0)) }
            }
        } onCancel: {
            (connection.value.remoteObjectProxy as? EngineProtocol)?.cancel(id)
        }
        try Task.checkCancellation()
        switch try JSONDecoder().decode(Outcome.self, from: reply) {
        case .done(let transcript): return transcript
        case .refused(let error): throw error
        case .failed(let message): throw EngineError.failed(message)
        }
    }

    /// Made again after it's invalidated; an interrupted one (the service quit or crashed) starts
    /// the service again by itself at the next call.
    private func connection() -> NSXPCConnection {
        lock.withLockUnchecked {
            if let current { return current }
            let connection = connect()
            connection.remoteObjectInterface = NSXPCInterface(with: EngineProtocol.self)
            connection.exportedInterface = NSXPCInterface(with: EngineClientProtocol.self)
            connection.exportedObject = self
            connection.invalidationHandler = { [weak self] in
                guard let self else { return }
                lock.withLock { current = nil }
            }
            connection.resume()
            current = connection
            return connection
        }
    }
}

/// The service's side. It quits once it has had nothing to do for `idle`, giving back all it loaded.
@available(macOS 26.0, *)
public final class EngineService: NSObject, NSXPCListenerDelegate, EngineProtocol, @unchecked Sendable {
    typealias Perform = @Sendable (Job.Work, @escaping @Sendable (Double, Double) -> Void) async -> Outcome

    private let idle: Duration
    private let quit: @Sendable () -> Void
    private let perform: Perform
    private let lock = OSAllocatedUnfairLock()
    private var jobs: [String: Task<Void, Never>] = [:]
    private var timer: Task<Void, Never>?

    /// The XPC service's whole main.
    public static func main() -> Never {
        let service = EngineService()
        let listener = NSXPCListener.service()
        listener.delegate = service
        listener.resume()
        fatalError("An XPC service's listener never returns.")
    }

    init(idle: Duration = .seconds(300), quit: @escaping @Sendable () -> Void = { exit(0) },
         perform: @escaping Perform = EngineService.perform) {
        self.idle = idle
        self.quit = quit
        self.perform = perform
        super.init()
        lock.withLock { armTimer() }
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: EngineProtocol.self)
        connection.exportedObject = self
        connection.remoteObjectInterface = NSXPCInterface(with: EngineClientProtocol.self)
        connection.resume()
        return true
    }

    public func run(_ job: Data, reply: @escaping @Sendable (Data) -> Void) {
        guard let job = try? JSONDecoder().decode(Job.self, from: job) else {
            return reply(Self.encode(.failed("The app and its engine don't match: reinstall Refrain.")))
        }
        let client = Unchecked(NSXPCConnection.current()?.remoteObjectProxy as? EngineClientProtocol)
        lock.withLock {
            timer?.cancel()
            jobs[job.id] = Task {
                let outcome = await perform(job.work) { client.value?.progress(job.id, done: $0, of: $1) }
                reply(Self.encode(outcome))
                lock.withLock {
                    jobs[job.id] = nil
                    if jobs.isEmpty { armTimer() }
                }
            }
        }
    }

    public func cancel(_ id: String) {
        lock.withLock { jobs[id] }?.cancel()
    }

    /// Called with the lock held.
    private func armTimer() {
        timer = Task { [idle, quit] in
            try? await Task.sleep(for: idle)
            if !Task.isCancelled { quit() }
        }
    }

    static func perform(_ work: Job.Work, progress: @escaping @Sendable (Double, Double) -> Void) async -> Outcome {
        do {
            switch work {
            case let .transcribe(file, language, prompt, keywords, speakers):
                return .done(try await Transcription.transcribe(file: file, language: language, prompt: prompt,
                                                                keywords: keywords, speakers: speakers, progress: progress))
            case .warmUpParakeet: try await Parakeet.warmUp()
            case .downloadParakeet: try await Parakeet.download { progress($0, 1) }
            case .warmUpSpeakers: try await Speakers.warmUp()
            case .deleteParakeet: await Parakeet.delete()
            }
            return .done(nil)
        } catch let error as TranscriptionError {
            return .refused(error)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func encode(_ outcome: Outcome) -> Data {
        (try? JSONEncoder().encode(outcome)) ?? Data()
    }
}

/// XPC connections and their proxies are safe to use from any thread.
private struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
