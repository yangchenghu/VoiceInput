import Foundation

enum AudioLevel {
    static func rms(_ pcm: Data) -> Float {
        let count = pcm.count / MemoryLayout<Int16>.size
        guard count > 0 else { return 0 }
        var sum: Float = 0
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for sample in samples.prefix(count) {
                let value = Float(sample) / 32768
                sum += value * value
            }
        }
        return min(1, sqrt(sum / Float(count)) * 4)
    }
}
