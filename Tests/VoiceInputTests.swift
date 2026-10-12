import XCTest

final class SessionReducerTests: XCTestCase {
    func testHappyPathInsertsOnce() {
        var state = SessionState()
        let id = UUID()
        state = SessionReducer.reduce(state, .hotkeyBegan(sessionID: id, correctionEnabled: false)).state
        state = SessionReducer.reduce(state, .candidateConfirmed).state
        let ended = SessionReducer.reduce(state, .hotkeyEnded)
        XCTAssertEqual(ended.effect, .finishAudio)
        let final = SessionReducer.reduce(ended.state, .finalTranscript(sessionID: id, text: "你好"))
        XCTAssertEqual(final.effect, .requestInsert("你好"))
        let done = SessionReducer.reduce(final.state, .insertSucceeded(sessionID: id))
        XCTAssertEqual(done.state.phase, .completed)
        XCTAssertTrue(done.state.inserted)
        let again = SessionReducer.reduce(done.state, .insertSucceeded(sessionID: id))
        XCTAssertEqual(again.effect, .none)
    }

    func testCancelDropsLateTranscript() {
        var state = SessionState()
        let id = UUID()
        state = SessionReducer.reduce(state, .hotkeyBegan(sessionID: id, correctionEnabled: false)).state
        state = SessionReducer.reduce(state, .cancelled).state
        XCTAssertEqual(state.phase, .cancelled)
        let late = SessionReducer.reduce(state, .finalTranscript(sessionID: id, text: "迟到了"))
        XCTAssertEqual(late.effect, .none)
        XCTAssertEqual(late.state.phase, .cancelled)
        XCTAssertFalse(late.state.inserted)
    }

    func testMismatchedSessionDoesNotInsert() {
        var state = SessionState()
        let id = UUID()
        state = SessionReducer.reduce(state, .hotkeyBegan(sessionID: id, correctionEnabled: false)).state
        state = SessionReducer.reduce(state, .hotkeyEnded).state
        let late = SessionReducer.reduce(state, .finalTranscript(sessionID: UUID(), text: "别的任务"))
        XCTAssertEqual(late.effect, .none)
        XCTAssertEqual(late.state.phase, .waitingFinal)
    }

    func testEmptyTranscriptDoesNotInsert() {
        var state = SessionState()
        let id = UUID()
        state = SessionReducer.reduce(state, .hotkeyBegan(sessionID: id, correctionEnabled: true)).state
        state = SessionReducer.reduce(state, .hotkeyEnded).state
        let final = SessionReducer.reduce(state, .finalTranscript(sessionID: id, text: "  \n"))
        XCTAssertEqual(final.effect, .none)
        XCTAssertEqual(final.state.phase, .completed)
    }

    func testNewlineIsHeld() {
        var state = SessionState()
        let id = UUID()
        state = SessionReducer.reduce(state, .hotkeyBegan(sessionID: id, correctionEnabled: false)).state
        state = SessionReducer.reduce(state, .hotkeyEnded).state
        let final = SessionReducer.reduce(state, .finalTranscript(sessionID: id, text: "第一行\n第二行"))
        XCTAssertEqual(final.effect, .none)
        XCTAssertEqual(final.state.phase, .pendingUser)
    }

    func testCorrectionThenInsert() {
        var state = SessionState()
        let id = UUID()
        state = SessionReducer.reduce(state, .hotkeyBegan(sessionID: id, correctionEnabled: true)).state
        state = SessionReducer.reduce(state, .hotkeyEnded).state
        let final = SessionReducer.reduce(state, .finalTranscript(sessionID: id, text: "测式"))
        XCTAssertEqual(final.effect, .requestCorrection("测式"))
        let corrected = SessionReducer.reduce(final.state, .correctionResolved(sessionID: id, text: "测试"))
        XCTAssertEqual(corrected.effect, .requestInsert("测试"))
    }

    func testBusyWhileActive() {
        var state = SessionState()
        state = SessionReducer.reduce(state, .hotkeyBegan(sessionID: UUID(), correctionEnabled: false)).state
        let busy = SessionReducer.reduce(state, .hotkeyBegan(sessionID: UUID(), correctionEnabled: false))
        XCTAssertEqual(busy.effect, .busy)
        XCTAssertEqual(busy.state.phase, .candidate)
    }

    func testDeviceChangeFailsCandidate() {
        var state = SessionState()
        state = SessionReducer.reduce(state, .hotkeyBegan(sessionID: UUID(), correctionEnabled: false)).state
        let failed = SessionReducer.reduce(state, .audioDeviceChanged)
        XCTAssertEqual(failed.state.phase, .failed)
        XCTAssertEqual(failed.effect, .stopInput(keepRetryAudio: false))
    }

    func testRetryInsertOnlyFromPending() {
        var state = SessionState()
        let id = UUID()
        state = SessionReducer.reduce(state, .hotkeyBegan(sessionID: id, correctionEnabled: false)).state
        state = SessionReducer.reduce(state, .hotkeyEnded).state
        state = SessionReducer.reduce(state, .finalTranscript(sessionID: id, text: "甲\n乙")).state
        let retry = SessionReducer.reduce(state, .retryInsert(sessionID: id))
        XCTAssertEqual(retry.effect, .requestInsert("甲\n乙"))
        let done = SessionReducer.reduce(retry.state, .insertSucceeded(sessionID: id))
        XCTAssertTrue(done.state.inserted)
        XCTAssertEqual(SessionReducer.reduce(done.state, .retryInsert(sessionID: id)).effect, .none)
    }
}

final class HotkeyMachineTests: XCTestCase {
    func testRightCommandHold() {
        var machine = HotkeyStateMachine()
        XCTAssertEqual(machine.handle(.flags(rightCommand: true, leftCommand: false, shift: false, option: false, control: false)), .beginCandidate)
        XCTAssertEqual(machine.handle(.flags(rightCommand: false, leftCommand: false, shift: false, option: false, control: false)), .endAndSubmit)
    }

    func testLeftCommandIgnored() {
        var machine = HotkeyStateMachine()
        XCTAssertEqual(machine.handle(.flags(rightCommand: false, leftCommand: true, shift: false, option: false, control: false)), .none)
        XCTAssertEqual(machine.handle(.flags(rightCommand: false, leftCommand: false, shift: false, option: false, control: false)), .none)
    }

    func testComboCancelsAndDoesNotSubmit() {
        var machine = HotkeyStateMachine()
        XCTAssertEqual(machine.handle(.flags(rightCommand: true, leftCommand: false, shift: false, option: false, control: false)), .beginCandidate)
        XCTAssertEqual(machine.handle(.keyDown(0x08)), .cancel)
        XCTAssertEqual(machine.handle(.keyUp(0x08)), .none)
        XCTAssertEqual(machine.handle(.flags(rightCommand: false, leftCommand: false, shift: false, option: false, control: false)), .none)
    }

    func testRepeatDoesNotChangeKeysByItself() {
        var machine = HotkeyStateMachine()
        _ = machine.handle(.flags(rightCommand: true, leftCommand: false, shift: false, option: false, control: false))
        XCTAssertEqual(machine.handle(.keyDown(0x08)), .cancel)
        machine = HotkeyStateMachine()
        _ = machine.handle(.flags(rightCommand: true, leftCommand: false, shift: false, option: false, control: false))
        XCTAssertEqual(machine.handle(.keyDown(0x08)), .cancel)
        XCTAssertEqual(machine.handle(.keyDown(0x08)), .none)
    }

    func testEscapeCancelsHold() {
        var machine = HotkeyStateMachine()
        _ = machine.handle(.flags(rightCommand: true, leftCommand: false, shift: false, option: false, control: false))
        XCTAssertEqual(machine.handle(.escape), .cancel)
    }

    func testBusyIgnored() {
        var machine = HotkeyStateMachine()
        machine.busy = true
        XCTAssertEqual(machine.handle(.flags(rightCommand: true, leftCommand: false, shift: false, option: false, control: false)), .busyIgnored)
    }

    func testToggleIgnoresComboAndStopsOnCleanClick() {
        var machine = HotkeyStateMachine(mode: .toggle)
        XCTAssertEqual(machine.handle(.flags(rightCommand: true, leftCommand: false, shift: false, option: false, control: false)), .none)
        XCTAssertEqual(machine.handle(.flags(rightCommand: false, leftCommand: false, shift: false, option: false, control: false)), .toggleStart)
        XCTAssertEqual(machine.handle(.flags(rightCommand: true, leftCommand: false, shift: false, option: false, control: false)), .none)
        XCTAssertEqual(machine.handle(.keyDown(0x08)), .none)
        XCTAssertEqual(machine.handle(.keyUp(0x08)), .none)
        XCTAssertEqual(machine.handle(.flags(rightCommand: false, leftCommand: false, shift: false, option: false, control: false)), .none)
        XCTAssertEqual(machine.handle(.flags(rightCommand: true, leftCommand: false, shift: false, option: false, control: false)), .none)
        XCTAssertEqual(machine.handle(.flags(rightCommand: false, leftCommand: false, shift: false, option: false, control: false)), .toggleStop)
    }

    func testPausedDoesNotStart() {
        var machine = HotkeyStateMachine()
        machine.paused = true
        XCTAssertEqual(machine.handle(.flags(rightCommand: true, leftCommand: false, shift: false, option: false, control: false)), .none)
    }
}

final class HotkeyCaptureTests: XCTestCase {
    func testRightCommandOnly() {
        var capture = HotkeyCaptureMachine()
        XCTAssertEqual(capture.handle(.flags(rightCommand: true, leftCommand: false, shift: false, option: false, control: false)), .none)
        XCTAssertEqual(
            capture.handle(.flags(rightCommand: false, leftCommand: false, shift: false, option: false, control: false)),
            .committed(.defaultRightCommand)
        )
    }

    func testChord() {
        var capture = HotkeyCaptureMachine()
        _ = capture.handle(.flags(rightCommand: true, leftCommand: false, shift: false, option: false, control: false))
        XCTAssertEqual(capture.handle(.keyDown(0x08)), .committed(HotkeyBinding(keyCode: 0x08, modifiers: HotkeyBinding.commandBit, requireRightCommand: true)))
    }

    func testBareKeyRejected() {
        var capture = HotkeyCaptureMachine()
        XCTAssertEqual(capture.handle(.keyDown(0x09)), .rejected("请至少带一个修饰键，例如右 Command，或 Control + 字母。"))
    }

    func testEscapeCancels() {
        var capture = HotkeyCaptureMachine()
        XCTAssertEqual(capture.handle(.escape), .cancelled)
    }
}

final class DoubaoCodecTests: XCTestCase {
    func testFullClientRoundTrip() throws {
        let json = DoubaoRequestBuilder.json(uid: "qingyu")
        let object = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        let request = object?["request"] as? [String: Any]
        XCTAssertEqual(request?["model_name"] as? String, "bigmodel")
        XCTAssertEqual(request?["result_type"] as? String, "full")
        XCTAssertEqual(request?["enable_ddc"] as? Bool, false)
        let frame = try DoubaoFrameCodec.decode(DoubaoFrameCodec.encodeFullClient(json: json, sequence: 1, gzip: true))
        XCTAssertEqual(frame.messageType, .fullClient)
        XCTAssertEqual(frame.sequence, 1)
        XCTAssertEqual(frame.payload, json)
    }

    func testServerTextReplacesRatherThanAppends() throws {
        let first = #"{"result":{"text":"你好"}}"#.data(using: .utf8)!
        let second = #"{"result":{"text":"你好世界"}}"#.data(using: .utf8)!
        XCTAssertEqual(ASRResultParser.text(from: first), "你好")
        XCTAssertEqual(ASRResultParser.text(from: second), "你好世界")
        let list = #"{"result":[{"text":"甲"},{"text":"乙"}]}"#.data(using: .utf8)!
        XCTAssertEqual(ASRResultParser.text(from: list), "甲乙")
    }

    func testLastPacketFlagAndErrorFrame() throws {
        let json = #"{"result":{"text":"完成"}}"#.data(using: .utf8)!
        let frame = try DoubaoFrameCodec.decode(
            DoubaoFrameCodec.encodeServerResponse(json: json, sequence: -3, isLast: true, gzip: true)
        )
        XCTAssertTrue(frame.isLast)
        XCTAssertEqual(frame.sequence, -3)
        XCTAssertEqual(ASRResultParser.text(from: frame.payload), "完成")

        let error = try DoubaoFrameCodec.decode(DoubaoFrameCodec.encodeServerError(code: 45_000_002, message: "empty"))
        XCTAssertEqual(error.messageType, .error)
        XCTAssertEqual(error.errorCode, 45_000_002)
        XCTAssertEqual(String(data: error.payload, encoding: .utf8), "empty")
    }

    func testGzipRoundTrip() throws {
        let source = Data("轻语语音".utf8)
        let compressed = try XCTUnwrap(Gzip.compress(source))
        XCTAssertNotEqual(compressed, source)
        XCTAssertEqual(Gzip.decompress(compressed), source)
        XCTAssertNotNil(Gzip.compress(Data()))
    }

    func testHandshakeRejectionExplainsCredentialAndResource() {
        let rejected = ASRError.classifyTransport(URLError(.badServerResponse), http: nil)
        XCTAssertEqual(rejected, .handshakeRejected(httpStatus: nil))
        XCTAssertTrue(rejected.message.contains("资源 ID"))

        let url = URL(string: "https://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!
        let unauthorized = HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)!
        let auth = ASRError.classifyTransport(URLError(.badServerResponse), http: unauthorized)
        XCTAssertEqual(auth, .handshakeRejected(httpStatus: 401))
        XCTAssertTrue(auth.message.contains("API Key"))

        let forbidden = HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!
        let resource = ASRError.classifyTransport(URLError(.badServerResponse), http: forbidden)
        XCTAssertEqual(resource, .handshakeRejected(httpStatus: 403))
        XCTAssertTrue(resource.message.contains("volc.seedasr.sauc.duration"))
        XCTAssertEqual(ASRError.classifyTransport(URLError(.notConnectedToInternet), http: nil), .connectionFailed)
        XCTAssertEqual(ASRError.classifyTransport(URLError(.cancelled), http: nil), .cancelled)
    }

    func testAudioFrameKeepsPCM() throws {
        let pcm = Data([0x00, 0x01, 0x02, 0x03])
        let encoded = DoubaoFrameCodec.encodeAudio(pcm: pcm, sequence: 2, isLast: false, gzip: false)
        let frame = try DoubaoFrameCodec.decode(encoded)
        XCTAssertEqual(frame.messageType, .audioOnly)
        XCTAssertEqual(frame.payload, pcm)
        XCTAssertFalse(frame.isLast)
        let last = try DoubaoFrameCodec.decode(DoubaoFrameCodec.encodeAudio(pcm: pcm, sequence: 4, isLast: true, gzip: false))
        XCTAssertTrue(last.isLast)
        XCTAssertEqual(last.sequence, -4)
    }
}

final class UnicodeChunkerTests: XCTestCase {
    func testDoesNotSplitCharacters() {
        let text = "你好👋，e\u{0301}!"
        let chunks = UnicodeChunker.chunks(text, maxUTF16Units: 2)
        XCTAssertEqual(chunks.joined(), text)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.utf16.count, 2)
            XCTAssertFalse(chunk.utf16.contains { $0 >= 0xD800 && $0 <= 0xDBFF && chunk.utf16.count == 1 })
        }
    }

    func testOversizedGraphemeStaysWhole() {
        let cluster = "e" + String(repeating: "\u{0301}", count: 30)
        XCTAssertEqual(cluster.count, 1)
        let chunks = UnicodeChunker.chunks("前" + cluster + "后", maxUTF16Units: 4)
        XCTAssertEqual(chunks.joined(), "前" + cluster + "后")
        XCTAssertTrue(chunks.contains(cluster))
    }

    func testEmojiFamilyRoundTrip() {
        let text = "家庭👨‍👩‍👧‍👦结束"
        XCTAssertEqual(UnicodeChunker.chunks(text).joined(), text)
    }
}

final class CorrectionPolicyTests: XCTestCase {
    func testFailureFallsBack() {
        XCTAssertEqual(CorrectionPolicy.choose(original: "原文", modelOutput: "改写", failed: true), "原文")
        XCTAssertEqual(CorrectionPolicy.choose(original: "原文", modelOutput: "  ", failed: false), "原文")
        XCTAssertEqual(CorrectionPolicy.choose(original: "测式", modelOutput: "测试", failed: false), "测试")
    }

    func testExpansionAndFenceRejectedOrStripped() {
        let original = "这是一段足够长的原始转写文本"
        let expanded = String(repeating: "扩写", count: 40)
        XCTAssertEqual(CorrectionPolicy.choose(original: original, modelOutput: expanded, failed: false), original)
        let fenced = "```text\n测试\n```"
        XCTAssertEqual(CorrectionPolicy.choose(original: "测式", modelOutput: fenced, failed: false), "测试")
        XCTAssertEqual(CorrectionPolicy.choose(original: "测式", modelOutput: "纠正后：测试", failed: false), "测式")
    }

    func testResponseParser() throws {
        let data = #"{"choices":[{"message":{"content":"测试"}}]}"#.data(using: .utf8)!
        XCTAssertEqual(CorrectionResponseParser.content(from: data), "测试")
        let url = try XCTUnwrap(CorrectionEndpoint.url(from: "https://example.com/v1/"))
        XCTAssertEqual(url.absoluteString, "https://example.com/v1/chat/completions")
        let full = try XCTUnwrap(CorrectionEndpoint.url(from: "https://example.com/v1/chat/completions"))
        XCTAssertEqual(full.absoluteString, "https://example.com/v1/chat/completions")
    }
}

final class ClipboardAndBufferTests: XCTestCase {
    func testRestoreOnlyWhenChangeCountMatches() {
        XCTAssertTrue(ClipboardRestorePolicy.shouldRestore(writtenChangeCount: 4, currentChangeCount: 4))
        XCTAssertFalse(ClipboardRestorePolicy.shouldRestore(writtenChangeCount: 4, currentChangeCount: 5))
    }

    func testBufferDropsOldest() {
        var buffer = BoundedAudioBuffer(maxBytes: 4)
        buffer.append(Data([1, 2, 3]))
        buffer.append(Data([4, 5]))
        XCTAssertEqual(Array(buffer.data), [2, 3, 4, 5])
        XCTAssertEqual(Array(buffer.drain()), [2, 3, 4, 5])
        XCTAssertTrue(buffer.data.isEmpty)
    }

    func testLevelOfSilenceIsZero() {
        XCTAssertEqual(AudioLevel.rms(Data(count: 320)), 0)
    }
}
