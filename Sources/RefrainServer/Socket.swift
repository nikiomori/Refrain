import Darwin
import Dispatch
import Foundation
import os

/// A non-blocking TCP socket on 127.0.0.1, awaited with dispatch sources: no thread waits on a
/// connection, and a wait can be given up without closing it. Closed when let go of.
final class Socket: @unchecked Sendable {
    private let fd: Int32

    private init(_ fd: Int32) {
        self.fd = fd
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        set(SO_NOSIGPIPE)  // a client gone mid-response is an error to throw, not a signal that ends the app
    }

    deinit { close(fd) }

    /// Listening on 127.0.0.1:`port`, any free one for 0. `POSIXError.EADDRINUSE` when another app has it.
    static func listen(port: UInt16) throws -> Socket {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError.current }
        let socket = Socket(fd)
        socket.set(SO_REUSEADDR)  // free again at once after a restart, not after TIME_WAIT
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, SOMAXCONN) == 0 else { throw POSIXError.current }
        return socket
    }

    var port: UInt16 {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return UInt16(bigEndian: address.sin_port)
    }

    func accept() async throws -> Socket {
        while true {
            let client = Darwin.accept(fd, nil, nil)
            if client >= 0 { return Socket(client) }
            switch errno {
            case EAGAIN: try await ready(for: .read)
            case EINTR, ECONNABORTED: continue
            case EMFILE, ENFILE, ENOBUFS, ENOMEM: try await Task.sleep(for: .milliseconds(100))  // out of descriptors: wait, don't spin
            default: throw POSIXError.current
            }
        }
    }

    /// Up to `count` bytes, as soon as there are any; empty once the client has closed its side.
    func receive(atMost count: Int) async throws -> Data {
        while true {
            // Not zeroed: only what arrives is touched.
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 1)
            let (read, error) = (recv(fd, buffer, count, 0), errno)
            if read >= 0 { return Data(bytesNoCopy: buffer, count: read, deallocator: .custom { pointer, _ in pointer.deallocate() }) }
            buffer.deallocate()
            switch error {
            case EAGAIN: try await ready(for: .read)
            case EINTR: continue
            default: throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
            }
        }
    }

    func send(_ data: Data) async throws {
        var sent = 0
        while sent < data.count {
            let (written, error) = data.withUnsafeBytes { (Darwin.send(fd, $0.baseAddress! + sent, $0.count - sent, 0), errno) }
            if written >= 0 {
                sent += written
                continue
            }
            switch error {
            case EAGAIN: try await ready(for: .write)
            case EINTR: continue
            default: throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
            }
        }
    }

    /// The end of the stream, once the response is out; then whatever the client still sends
    /// (a body refused unread) is read until it closes, a second at most. Closed on unread
    /// bytes, a socket resets the connection, and the response can be lost on its way.
    func finish() async {
        shutdown(fd, SHUT_WR)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { while let chunk = try? await self.receive(atMost: 1 << 16), !chunk.isEmpty {} }
            group.addTask { try? await Task.sleep(for: .seconds(1)) }
            await group.next()
            group.cancelAll()
        }
    }

    private enum Readiness { case read, write }

    /// Until the socket can be read or written. A cancelled task stops waiting and throws, the
    /// socket left as it was.
    private func ready(for readiness: Readiness) async throws {
        try Task.checkCancellation()
        let source: Source
        if readiness == .read {
            source = Source(DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global()))
        } else {
            source = Source(DispatchSource.makeWriteSource(fileDescriptor: fd, queue: .global()))
        }
        let fired = OSAllocatedUnfairLock(initialState: false)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Resumed from the cancel handler alone, which runs once and after the event handler:
                // the socket may close right after, and libdispatch needs it open until then.
                source.value.setEventHandler {
                    fired.withLock { $0 = true }
                    source.value.cancel()
                }
                source.value.setCancelHandler {
                    if fired.withLock({ $0 }) { continuation.resume() } else { continuation.resume(throwing: CancellationError()) }
                }
                source.value.resume()
            }
        } onCancel: {
            source.value.cancel()
        }
    }

    /// Dispatch sources are safe to use from any thread.
    private struct Source: @unchecked Sendable {
        let value: any DispatchSourceProtocol
        init(_ value: any DispatchSourceProtocol) { self.value = value }
    }

    private func set(_ option: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, option, &on, socklen_t(MemoryLayout<Int32>.size))
    }
}

extension POSIXError {
    static var current: POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
