import AVFoundation
import Foundation

enum AudioCaptureError: Error {
    case noInput
    case format
    case startFailed

    var message: String {
        switch self {
        case .noInput: return "没有可用的麦克风。"
        case .format: return "麦克风格式无法转换。"
        case .startFailed: return "麦克风启动失败。"
        }
    }
}

final class AudioCaptureService: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var pending = Data()
    private var onChunk: (@Sendable (Data, Float) -> Void)?
    private var onDeviceChange: (@Sendable () -> Void)?
    private var running = false
    private var observer: NSObjectProtocol?

    func start(
        onChunk: @escaping @Sendable (Data, Float) -> Void,
        onDeviceChange: @escaping @Sendable () -> Void
    ) throws {
        self.onChunk = onChunk
        self.onDeviceChange = onDeviceChange
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioCaptureError.noInput
        }
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw AudioCaptureError.format
        }
        self.converter = converter
        self.targetFormat = target
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioCaptureError.startFailed
        }
        running = true
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.running else { return }
            self.onDeviceChange?()
        }
    }

    func stop() -> Data {
        running = false
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        let tail = pending
        pending.removeAll(keepingCapacity: false)
        lock.unlock()
        converter = nil
        return tail
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let targetFormat else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard capacity > 0,
              let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return
        }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.int16ChannelData else { return }
        let byteCount = Int(output.frameLength) * MemoryLayout<Int16>.size
        guard byteCount > 0 else { return }
        let data = Data(bytes: channel[0], count: byteCount)
        lock.lock()
        pending.append(data)
        var chunks: [Data] = []
        while pending.count >= SessionLimits.audioChunkBytes {
            chunks.append(Data(pending.prefix(SessionLimits.audioChunkBytes)))
            pending.removeFirst(SessionLimits.audioChunkBytes)
        }
        lock.unlock()
        for chunk in chunks {
            onChunk?(chunk, AudioLevel.rms(chunk))
        }
    }
}
