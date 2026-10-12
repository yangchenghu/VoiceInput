import Foundation

enum SessionPhase: Equatable {
    case idle
    case candidate
    case recording
    case waitingFinal
    case correcting
    case inserting
    case completed
    case cancelled
    case failed
    case pendingUser
}

struct SessionState: Equatable {
    var phase: SessionPhase = .idle
    var sessionID = UUID()
    var correctionEnabled = false
    var inserted = false
    var text = ""
    var banner = ""

    var isPipelineActive: Bool {
        switch phase {
        case .candidate, .recording, .waitingFinal, .correcting, .inserting:
            return true
        case .idle, .completed, .cancelled, .failed, .pendingUser:
            return false
        }
    }

    var acceptsAudio: Bool {
        phase == .candidate || phase == .recording
    }
}

enum SessionEvent: Equatable {
    case hotkeyBegan(sessionID: UUID, correctionEnabled: Bool)
    case candidateConfirmed
    case hotkeyEnded
    case cancelled
    case audioDeviceChanged
    case audioFailed(String)
    case finalTranscript(sessionID: UUID, text: String)
    case asrFailed(sessionID: UUID, message: String)
    case correctionResolved(sessionID: UUID, text: String)
    case insertSucceeded(sessionID: UUID)
    case insertBlocked(sessionID: UUID, text: String, reason: String)
    case insertFailed(sessionID: UUID, message: String)
    case dismiss
    case retryInsert(sessionID: UUID)
    case retryAudio(sessionID: UUID, correctionEnabled: Bool)
    case maxDuration
}

enum SessionEffect: Equatable {
    case none
    case beginAudio
    case openSocket
    case finishAudio
    case stopInput(keepRetryAudio: Bool)
    case requestCorrection(String)
    case requestInsert(String)
    case replayAudio
    case busy
}

struct SessionReduce: Equatable {
    var state: SessionState
    var effect: SessionEffect
}

enum SessionReducer {
    static func reduce(_ state: SessionState, _ event: SessionEvent) -> SessionReduce {
        switch event {
        case let .hotkeyBegan(id, correctionEnabled):
            if state.isPipelineActive {
                return SessionReduce(state: state, effect: .busy)
            }
            var next = state
            next.phase = .candidate
            next.sessionID = id
            next.correctionEnabled = correctionEnabled
            next.inserted = false
            next.text = ""
            next.banner = ""
            return SessionReduce(state: next, effect: .beginAudio)

        case .candidateConfirmed:
            guard state.phase == .candidate else { return ignore(state) }
            var next = state
            next.phase = .recording
            return SessionReduce(state: next, effect: .openSocket)

        case .hotkeyEnded, .maxDuration:
            guard state.phase == .candidate || state.phase == .recording else { return ignore(state) }
            var next = state
            next.phase = .waitingFinal
            return SessionReduce(state: next, effect: .finishAudio)

        case .cancelled:
            guard state.isPipelineActive else { return ignore(state) }
            var next = state
            next.phase = .cancelled
            next.banner = ""
            return SessionReduce(state: next, effect: .stopInput(keepRetryAudio: false))

        case .audioDeviceChanged:
            guard state.phase == .candidate || state.phase == .recording else { return ignore(state) }
            var next = state
            next.phase = .failed
            next.banner = "麦克风设备变了，请重新开始。"
            return SessionReduce(state: next, effect: .stopInput(keepRetryAudio: false))

        case let .audioFailed(message):
            guard state.phase == .candidate || state.phase == .recording else { return ignore(state) }
            var next = state
            next.phase = .failed
            next.banner = message
            return SessionReduce(state: next, effect: .stopInput(keepRetryAudio: false))

        case let .finalTranscript(id, text):
            guard id == state.sessionID, state.phase == .waitingFinal, !state.inserted else { return ignore(state) }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            var next = state
            next.text = text
            if trimmed.isEmpty {
                next.phase = .completed
                next.banner = ""
                return SessionReduce(state: next, effect: .none)
            }
            if text.contains("\n") || text.contains("\r") {
                next.phase = .pendingUser
                next.banner = "文本含换行，已保留。自动输入可能在聊天框里触发发送，请手动处理。"
                return SessionReduce(state: next, effect: .none)
            }
            if state.correctionEnabled {
                next.phase = .correcting
                return SessionReduce(state: next, effect: .requestCorrection(text))
            }
            next.phase = .inserting
            return SessionReduce(state: next, effect: .requestInsert(text))

        case let .asrFailed(id, message):
            guard id == state.sessionID else { return ignore(state) }
            guard state.phase == .candidate || state.phase == .recording || state.phase == .waitingFinal else {
                return ignore(state)
            }
            var next = state
            next.phase = .failed
            next.banner = message
            let stillCapturing = state.phase == .candidate || state.phase == .recording
            return SessionReduce(state: next, effect: stillCapturing ? .stopInput(keepRetryAudio: true) : .none)

        case let .correctionResolved(id, text):
            guard id == state.sessionID, state.phase == .correcting, !state.inserted else { return ignore(state) }
            var next = state
            next.text = text
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                next.phase = .completed
                return SessionReduce(state: next, effect: .none)
            }
            if text.contains("\n") || text.contains("\r") {
                next.phase = .pendingUser
                next.banner = "文本含换行，已保留。请手动处理。"
                return SessionReduce(state: next, effect: .none)
            }
            next.phase = .inserting
            return SessionReduce(state: next, effect: .requestInsert(text))

        case let .insertSucceeded(id):
            guard id == state.sessionID, state.phase == .inserting, !state.inserted else { return ignore(state) }
            var next = state
            next.inserted = true
            next.phase = .completed
            next.banner = ""
            return SessionReduce(state: next, effect: .none)

        case let .insertBlocked(id, text, reason):
            guard id == state.sessionID, state.phase == .inserting, !state.inserted else { return ignore(state) }
            var next = state
            next.phase = .pendingUser
            next.text = text
            next.banner = reason
            return SessionReduce(state: next, effect: .none)

        case let .insertFailed(id, message):
            guard id == state.sessionID, state.phase == .inserting, !state.inserted else { return ignore(state) }
            var next = state
            next.phase = .failed
            next.banner = message
            return SessionReduce(state: next, effect: .none)

        case .dismiss:
            switch state.phase {
            case .failed, .pendingUser, .completed, .cancelled:
                var next = state
                next.phase = .idle
                next.banner = ""
                return SessionReduce(state: next, effect: .none)
            default:
                return ignore(state)
            }

        case let .retryInsert(id):
            guard id == state.sessionID, state.phase == .pendingUser, !state.inserted else { return ignore(state) }
            let trimmed = state.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return ignore(state) }
            var next = state
            next.phase = .inserting
            return SessionReduce(state: next, effect: .requestInsert(state.text))

        case let .retryAudio(id, correctionEnabled):
            if state.isPipelineActive {
                return SessionReduce(state: state, effect: .busy)
            }
            var next = state
            next.phase = .waitingFinal
            next.sessionID = id
            next.correctionEnabled = correctionEnabled
            next.inserted = false
            next.text = ""
            next.banner = ""
            return SessionReduce(state: next, effect: .replayAudio)
        }
    }

    private static func ignore(_ state: SessionState) -> SessionReduce {
        SessionReduce(state: state, effect: .none)
    }
}
