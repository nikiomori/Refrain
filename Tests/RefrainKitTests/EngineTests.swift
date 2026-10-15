import Foundation
import Synchronization
import Testing
@testable import RefrainKit

/// The app and its engine over a real XPC connection, an anonymous one in this process, with a
/// stub for the models: what crosses it, and when the service quits.
@Suite struct EngineTests {
    @available(macOS 26.0, *)
    private func engine(idle: Duration = .seconds(60), quit: @escaping @Sendable () -> Void = {},
                        perform: @escaping EngineService.Perform) -> Engine {
        nonisolated(unsafe) let listener = NSXPCListener.anonymous()
        let service = EngineService(idle: idle, quit: quit, perform: perform)
        listener.delegate = service
        listener.resume()
        let endpoint = listener.endpoint
        return Engine {
            _ = (listener, service)  // kept alive with the engine
            return NSXPCConnection(listenerEndpoint: endpoint)
        }
    }

    @Test func transcriptsProgressAndRefusalsCross() async throws {
        guard #available(macOS 26.0, *) else { return }
        let engine = engine { work, progress in
            guard case .transcribe(let file, _, _, _, _) = work else { return .done(nil) }
            if file.lastPathComponent == "noise" { return .refused(.unreadableAudio) }
            progress(1.5, 3)
            return .done(Transcript(text: "Привет, мир.", segments: [.init(start: 0, end: 3, text: "Привет, мир.", speaker: "A")],
                                    language: "ru", duration: 3))
        }
        let reports = Mutex<[Double]>([])
        let transcript = try await engine.transcribe(file: URL(filePath: "/call.m4a"), language: "ru", prompt: nil, keywords: [],
                                                     speakers: true) { done, _ in reports.withLock { $0.append(done) } }
        #expect(transcript.text == "Привет, мир.")
        #expect(transcript.segments.first?.speaker == "A")
        for _ in 0..<100 where reports.withLock({ $0.isEmpty }) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(reports.withLock { $0 } == [1.5])
        // A request's own fault stays one: the server answers it with a 400.
        await #expect(throws: TranscriptionError.unreadableAudio) {
            try await engine.transcribe(file: URL(filePath: "/noise"), language: nil, prompt: nil, keywords: [],
                                        speakers: false) { _, _ in }
        }
    }

    /// A request given up stops in the service too, rather than holding up the queue there.
    @Test func cancellingStopsTheWork() async throws {
        guard #available(macOS 26.0, *) else { return }
        let stopped = Mutex(false)
        let engine = engine { _, _ in
            do { try await Task.sleep(for: .seconds(30)) } catch { stopped.withLock { $0 = true } }
            return .failed("slept")
        }
        let request = Task { try await engine.warmUpParakeet() }
        try await Task.sleep(for: .milliseconds(200))
        request.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
        for _ in 0..<100 where !stopped.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(stopped.withLock { $0 })
    }

    /// Idle, the service quits, which gives back everything the models left behind.
    @Test func theServiceQuitsWhenIdle() async throws {
        guard #available(macOS 26.0, *) else { return }
        let quits = Mutex(0)
        let engine = engine(idle: .milliseconds(300), quit: { quits.withLock { $0 += 1 } }) { _, _ in
            try? await Task.sleep(for: .milliseconds(500))  // longer than `idle`: no quitting mid-job
            return .done(nil)
        }
        try await engine.warmUpSpeakers()
        #expect(quits.withLock { $0 } == 0)
        try await Task.sleep(for: .milliseconds(600))
        #expect(quits.withLock { $0 } == 1)
    }
}
