import Foundation

struct BoundedAudioBuffer: Equatable {
    private(set) var data = Data()
    let maxBytes: Int

    init(maxBytes: Int) {
        self.maxBytes = max(1, maxBytes)
    }

    mutating func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        data.append(chunk)
        if data.count > maxBytes {
            data.removeFirst(data.count - maxBytes)
        }
    }

    mutating func drain() -> Data {
        let output = data
        data.removeAll(keepingCapacity: true)
        return output
    }

    mutating func clear() {
        data.removeAll(keepingCapacity: true)
    }
}
