import Foundation
import Darwin

/// A dedicated JSON-RPC session with the local Codex app server.
final class AppServerClient: @unchecked Sendable {
    struct Notification: Sendable {
        let method: String
        let data: Data
    }
    let notifications: AsyncThrowingStream<Notification, Error>
    private let notificationContinuation: AsyncThrowingStream<Notification, Error>.Continuation
    private struct Pending {
        let completion: (Result<Data, Error>) -> Void
        let timeout: DispatchWorkItem
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var pending: [Int: Pending] = [:]
    private var nextID = 1
    private var closed = false
    private var terminalError: Error = UsageProviderError.disconnected
    private let maximumMessageBytes = 4 * 1024 * 1024

    /// Start the child and drain both pipes without retaining diagnostic or account data.
    init(executable: URL) throws {
        var continuation: AsyncThrowingStream<Notification, Error>.Continuation!
        notifications = AsyncThrowingStream(bufferingPolicy: .bufferingNewest(32)) { continuation = $0 }
        notificationContinuation = continuation
        process.executableURL = executable
        process.arguments = ["app-server"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty { self.failAll(UsageProviderError.disconnected) }
            else { self.receive(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        process.terminationHandler = { [weak self] _ in
            self?.failAll(UsageProviderError.disconnected)
        }
        do { try process.run() }
        catch {
            stop()
            throw UsageProviderError.launchFailed
        }
    }

    /// Request one result with a deadline; cancellation closes this entire dedicated session.
    func request<T: Decodable>(_ method: String, params: [String: Any]? = nil, timeout: TimeInterval = 12) async throws -> T {
        try Task.checkCancellation()
        let data: Data = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                sendRequest(method, params: params, timeout: timeout) { result in
                    continuation.resume(with: result)
                }
            }
        }, onCancel: { self.stop(reason: CancellationError()) })
        try Task.checkCancellation()
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw UsageProviderError.invalidResponse }
    }

    /// Send the initialization acknowledgement, which has no response ID.
    func initialized() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw terminalError }
        do { try write(["method": "initialized"]) }
        catch { throw UsageProviderError.disconnected }
    }

    /// Close the pipes and child without blocking the main thread on process shutdown.
    func stop(reason: Error = UsageProviderError.disconnected) {
        failAll(reason)
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            let child = process
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
    }

    /// Register completion before writing so fast responses cannot miss their waiter.
    private func sendRequest(_ method: String, params: [String: Any]?, timeout: TimeInterval, completion: @escaping (Result<Data, Error>) -> Void) {
        lock.lock()
        if closed {
            let error = terminalError
            lock.unlock()
            completion(.failure(error))
            return
        }
        let id = nextID
        nextID += 1
        let deadline = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.failAll(UsageProviderError.timedOut, onlyIfPending: id) { self.stop() }
        }
        pending[id] = Pending(completion: completion, timeout: deadline)
        var message: [String: Any] = ["id": id, "method": method]
        if let params { message["params"] = params }
        do {
            try write(message)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
            lock.unlock()
        } catch {
            lock.unlock()
            stop(reason: UsageProviderError.disconnected)
        }
    }

    /// Encode one newline-delimited protocol message; callers serialize writes under the lock.
    private func write(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: .withoutEscapingSlashes)
        data.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    /// Assemble partial reads and buffer notifications, including early login completion.
    private func receive(_ data: Data) {
        var completions: [(Pending, Result<Data, Error>)] = []
        var notices: [Notification] = []
        var failure: Error?
        lock.lock()
        guard !closed else { lock.unlock(); return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if line.isEmpty { continue }
            guard line.count <= maximumMessageBytes,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                failure = UsageProviderError.invalidResponse
                break
            }
            guard let id = object["id"] as? Int else {
                if let method = object["method"] as? String,
                   let params = object["params"],
                   let data = try? JSONSerialization.data(withJSONObject: params, options: .fragmentsAllowed) {
                    notices.append(Notification(method: method, data: data))
                }
                continue
            }
            guard let waiter = pending.removeValue(forKey: id) else { continue }
            waiter.timeout.cancel()
            if let error = object["error"] as? [String: Any] {
                let code = (error["code"] as? Int) ?? 0
                completions.append((waiter, .failure(UsageProviderError.rpcFailure(code: code))))
            } else if let result = object["result"],
                      let resultData = try? JSONSerialization.data(withJSONObject: result, options: .fragmentsAllowed) {
                completions.append((waiter, .success(resultData)))
            } else {
                completions.append((waiter, .failure(UsageProviderError.invalidResponse)))
            }
        }
        if buffer.count > maximumMessageBytes { failure = UsageProviderError.invalidResponse }
        lock.unlock()
        for notice in notices { notificationContinuation.yield(notice) }
        for (waiter, result) in completions { waiter.completion(result) }
        if let failure { stop(reason: failure) }
    }

    /// Resume each waiter exactly once, preserving the first terminal failure.
    @discardableResult
    private func failAll(_ error: Error, onlyIfPending id: Int? = nil) -> Bool {
        lock.lock()
        guard !closed, id == nil || pending[id!] != nil else { lock.unlock(); return false }
        closed = true
        terminalError = error
        let waiters = Array(pending.values)
        pending.removeAll()
        buffer.removeAll()
        lock.unlock()
        notificationContinuation.finish(throwing: error)
        for waiter in waiters {
            waiter.timeout.cancel()
            waiter.completion(.failure(error))
        }
        return true
    }
}
