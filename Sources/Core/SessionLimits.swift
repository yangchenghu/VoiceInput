import Foundation

enum SessionLimits {
    static let maxRecordingSeconds: TimeInterval = 60
    static let candidateDelayMilliseconds = 200
    static let prebufferBytes = 96_000
    static let retryAudioBytes = 1_920_000
    static let connectTimeoutSeconds: TimeInterval = 8
    static let finalTimeoutSeconds: TimeInterval = 8
    static let correctionTimeoutSeconds: TimeInterval = 2
    static let unicodeMaxUTF16Units = 20
    static let audioChunkBytes = 6400
    static let pasteSettleMilliseconds = 250
    static let completedVisibleSeconds: TimeInterval = 1.2
}
