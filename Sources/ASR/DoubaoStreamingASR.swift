import Foundation

/// 边录音边上传。中间结果只保存在连接内部，调用方只能在最终帧或失败后读取。
actor DoubaoStreamingASR {
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var sequence: Int32 = 1
    private var queued: [Data] = []
    private var queuedBytes = 0
    private var ready = false
    private var opening: Task<Void, Error>?
    private var pumpRunning = false
    private var pumpWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishing = false
    private var cancelled = false
    private var endSent = false
    private var latestText = ""
    private var finalText: String?
    private var failure: ASRError?
    private var waiter: CheckedContinuation<String, Error>?
    private var receiveTask: Task<Void, Never>?
    private var useGzip = true
    private(set) var logID: String?

    func open(_ config: DoubaoConfig) async throws {
        if ready { return }
        if let opening {
            try await opening.value
            return
        }
        let job = Task { try await self.connect(config) }
        opening = job
        try await job.value
    }

    func sendAudio(_ pcm: Data) {
        guard !pcm.isEmpty, !finishing, !cancelled, !endSent else { return }
        queued.append(pcm)
        queuedBytes += pcm.count
        trimQueue()
        if ready {
            Task { await self.pump() }
        }
    }

    func finish() async throws -> String {
        if let opening {
            try await opening.value
        }
        guard ready else { throw failure ?? ASRError.notConnected }
        finishing = true
        if pumpRunning {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.pumpWaiters.append(continuation)
            }
        }
        await pump()
        if !endSent {
            let frame = DoubaoFrameCodec.encodeAudio(
                pcm: Data(),
                sequence: nextSequence(last: true),
                isLast: true,
                gzip: useGzip
            )
            endSent = true
            try await transmit(frame)
        }
        return try await waitForFinal()
    }

    func latest() -> String {
        latestText
    }

    func cancel() {
        cancelled = true
        opening?.cancel()
        receiveTask?.cancel()
        fail(.cancelled)
    }

    private func connect(_ config: DoubaoConfig) async throws {
        let request = try config.urlRequest()
        let waiter = SocketOpenWaiter()
        let session = URLSession(configuration: .ephemeral, delegate: waiter, delegateQueue: nil)
        self.session = session
        let socket = session.webSocketTask(with: request)
        task = socket
        socket.resume()
        let http: HTTPURLResponse?
        do {
            // 握手完成后再发 full client request。提前 send 时，升级失败会被系统记成 -1011。
            http = try await withTaskCancellationHandler {
                try await waiter.wait()
            } onCancel: {
                socket.cancel(with: .goingAway, reason: nil)
            }
        } catch {
            let mapped = ASRError.classifyTransport(error, http: waiter.lastResponse)
            noteHandshake(mapped, http: waiter.lastResponse)
            fail(mapped)
            throw mapped
        }
        if cancelled {
            fail(.cancelled)
            throw ASRError.cancelled
        }
        logID = http?.value(forHTTPHeaderField: "X-Tt-Logid")
        AppLog.event("asr.connected", logID.map { "logid=\($0)" } ?? "")
        let json = DoubaoRequestBuilder.json(uid: config.connectID)
        useGzip = Gzip.compress(Data([0x00])) != nil
        let frame = DoubaoFrameCodec.encodeFullClient(
            json: json,
            sequence: nextSequence(last: false),
            gzip: useGzip
        )
        receiveTask = Task { await self.receiveLoop() }
        do {
            try await transmit(frame)
        } catch {
            let mapped = ASRError.classifyTransport(error, http: nil)
            fail(mapped)
            throw mapped
        }
        ready = true
        await pump()
    }

    private func noteHandshake(_ error: ASRError, http: HTTPURLResponse?) {
        guard case let .handshakeRejected(status) = error else { return }
        let code = status.map(String.init) ?? "-"
        let logid = http?.value(forHTTPHeaderField: "X-Tt-Logid") ?? "-"
        AppLog.error("asr.handshake", "http=\(code) logid=\(logid)")
    }

    private func pump() async {
        if pumpRunning || !ready || cancelled { return }
        pumpRunning = true
        defer {
            pumpRunning = false
            let waiters = pumpWaiters
            pumpWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        while !queued.isEmpty && !cancelled && !endSent {
            let chunk = queued.removeFirst()
            queuedBytes = max(0, queuedBytes - chunk.count)
            let frame = DoubaoFrameCodec.encodeAudio(
                pcm: chunk,
                sequence: nextSequence(last: false),
                isLast: false,
                gzip: useGzip
            )
            do {
                try await transmit(frame)
            } catch {
                fail(ASRError.classifyTransport(error, http: nil))
                return
            }
        }
    }

    private func transmit(_ data: Data) async throws {
        guard let task, !cancelled else { throw ASRError.cancelled }
        do {
            try await task.send(.data(data))
        } catch {
            throw ASRError.classifyTransport(error, http: nil)
        }
    }

    private func receiveLoop() async {
        guard let task else { return }
        while !cancelled {
            do {
                let message = try await task.receive()
                guard case let .data(data) = message else { continue }
                let frame = try DoubaoFrameCodec.decode(data)
                if frame.messageType == .error {
                    let code = frame.errorCode ?? 0
                    AppLog.error("asr.server", "code=\(code)")
                    fail(.server(code: code))
                    return
                }
                if let text = ASRResultParser.text(from: frame.payload) {
                    latestText = text
                }
                if frame.isLast {
                    finalText = latestText
                    AppLog.event("asr.final")
                    resume(with: .success(latestText))
                    return
                }
            } catch {
                if cancelled {
                    fail(.cancelled)
                } else if endSent {
                    fail(.connectionFailed)
                }
                return
            }
        }
    }

    private func waitForFinal() async throws -> String {
        if let finalText { return finalText }
        if let failure { throw failure }
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await self.awaitFinal() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(SessionLimits.finalTimeoutSeconds * 1_000_000_000))
                throw ASRError.finalTimeout
            }
            do {
                guard let value = try await group.next() else {
                    throw ASRError.finalTimeout
                }
                group.cancelAll()
                return value
            } catch let error as ASRError {
                group.cancelAll()
                if case .finalTimeout = error {
                    self.fail(.finalTimeout)
                }
                throw error
            } catch {
                group.cancelAll()
                self.fail(.finalTimeout)
                throw ASRError.finalTimeout
            }
        }
    }

    private func awaitFinal() async throws -> String {
        if let finalText { return finalText }
        if let failure { throw failure }
        return try await withCheckedThrowingContinuation { continuation in
            if let finalText {
                continuation.resume(returning: finalText)
                return
            }
            if let failure {
                continuation.resume(throwing: failure)
                return
            }
            waiter = continuation
        }
    }

    private func fail(_ error: ASRError) {
        teardownSocket()
        if failure == nil {
            failure = error
        }
        resume(with: .failure(failure ?? error))
    }

    private func teardownSocket() {
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }

    private func resume(with result: Result<String, Error>) {
        guard let waiter else { return }
        self.waiter = nil
        switch result {
        case let .success(text):
            finalText = text
            waiter.resume(returning: text)
        case let .failure(error):
            waiter.resume(throwing: error)
        }
    }

    private func nextSequence(last: Bool) -> Int32 {
        let value = sequence
        sequence += 1
        return last ? -abs(value) : value
    }

    private func trimQueue() {
        while queuedBytes > SessionLimits.prebufferBytes, queued.count > 1 {
            queuedBytes -= queued.removeFirst().count
        }
    }
}

/// 等 WebSocket 的 HTTP 升级结束。成功和失败都只恢复一次。
private final class SocketOpenWaiter: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HTTPURLResponse?, Error>?
    private var early: Result<HTTPURLResponse?, Error>?
    private var settled = false
    private var storedResponse: HTTPURLResponse?

    var lastResponse: HTTPURLResponse? {
        lock.lock()
        defer { lock.unlock() }
        return storedResponse
    }

    func wait() async throws -> HTTPURLResponse? {
        try await withCheckedThrowingContinuation { continuation in
            self.lock.lock()
            if let early = self.early {
                self.lock.unlock()
                continuation.resume(with: early)
                return
            }
            self.continuation = continuation
            self.lock.unlock()
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        remember(webSocketTask.response as? HTTPURLResponse)
        finish(.success(webSocketTask.response as? HTTPURLResponse))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let http = task.response as? HTTPURLResponse
        remember(http)
        guard let error else { return }
        finish(.failure(error))
    }

    private func remember(_ http: HTTPURLResponse?) {
        guard let http else { return }
        lock.lock()
        if storedResponse == nil { storedResponse = http }
        lock.unlock()
    }

    private func finish(_ result: Result<HTTPURLResponse?, Error>) {
        lock.lock()
        if settled {
            lock.unlock()
            return
        }
        settled = true
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil {
            early = result
        }
        lock.unlock()
        continuation?.resume(with: result)
    }
}
