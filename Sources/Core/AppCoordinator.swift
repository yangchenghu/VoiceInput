import AppKit
import SwiftUI

final class KeyWatcher: NSObject, NSWindowDelegate {
    var onKey: (Bool) -> Void = { _ in }
    func windowDidBecomeKey(_ notification: Notification) { onKey(true) }
    func windowDidResignKey(_ notification: Notification) { onKey(false) }
}

final class AppCoordinator: NSObject, ObservableObject, NSMenuDelegate, @unchecked Sendable {
    @Published var settings: AppSettings
    @Published var capsule: CapsuleStatus?
    @Published var inputLevel = 0.0
    @Published var statusText = "空闲"
    @Published var hint: String?
    @Published var lastResult: String?
    @Published var canRetryAudio = false
    @Published var asrTestMessage = ""
    @Published var correctionTestMessage = ""
    @Published var isCapturingHotkey = false
    @Published var captureMessage = ""
    @Published var hasDoubaoAPIKey = false
    @Published var hasDoubaoAppKey = false
    @Published var hasDoubaoAccessKey = false
    @Published var hasCorrectionKey = false
    @Published var microphoneText = "未知"
    @Published var accessibilityText = "未知"
    @Published var listenText = "未知"
    @Published var hotkeyText = "未启动"
    @Published private(set) var isBusy = false

    private let store: SettingsStore
    private let credentials = CredentialStore()
    private let audio = AudioCaptureService()
    private let correction = CorrectionService()
    private let inserter = TextInsertionService()
    private var hotkey: HotkeyService!
    private let overlay = OverlayController()
    private let settingsWatcher = KeyWatcher()
    private let resultWatcher = KeyWatcher()
    private var state = SessionState()
    private var asr: DoubaoStreamingASR?
    private var focus: FocusSnapshot?
    private var retryAudio = Data()
    private var recordStarted = Date()
    private var confirmTask: Task<Void, Never>?
    private var maxDurationTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var hintTask: Task<Void, Never>?
    private var pipelineTask: Task<Void, Never>?
    private var latencyStop: Date?
    private var sessionInsertionMode: InsertionMode = .unicode
    private var settingsWindow: NSWindow?
    private var resultWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var statusMenuItem: NSMenuItem?
    private var recentMenuItem: NSMenuItem?
    private var insertPause = false
    private var settingsIsKey = false
    private var resultIsKey = false
    private var pendingHotkeyApply = false
    private var levelTick = Date.distantPast

    override init() {
        let store = SettingsStore()
        self.store = store
        settings = store.load()
        super.init()
        hotkey = HotkeyService(mode: settings.recordMode, binding: settings.hotkey)
        bindServices()
    }

    func start() {
        installStatusItem()
        overlay.install(model: self)
        hotkey.shouldCancelOnEscape = { [weak self] in
            self?.state.isPipelineActive ?? false
        }
        _ = hotkey.start()
        refreshPermissions()
        refreshCredentialFlags()
        if !settings.didShowOnboarding {
            mutateSettings { $0.didShowOnboarding = true }
            openSettings()
        }
        AppLog.event("app.start")
    }

    func shutdown() {
        confirmTask?.cancel()
        maxDurationTask?.cancel()
        pipelineTask?.cancel()
        hideTask?.cancel()
        _ = audio.stop()
        let client = asr
        asr = nil
        Task { await client?.cancel() }
        hotkey.stop()
        retryAudio.removeAll()
        AppLog.event("app.shutdown")
    }

    func setRecordMode(_ mode: RecordMode) { mutateSettings { $0.recordMode = mode } }
    func setInsertionMode(_ mode: InsertionMode) { mutateSettings { $0.insertionMode = mode } }
    func setCorrectionEnabled(_ enabled: Bool) { mutateSettings { $0.correctionEnabled = enabled } }
    func setCorrectionBaseURL(_ value: String) { mutateSettings { $0.correctionBaseURL = value } }
    func setCorrectionModel(_ value: String) { mutateSettings { $0.correctionModel = value } }
    func setASREndpoint(_ value: String) { mutateSettings { $0.asrEndpoint = value } }
    func setASRResourceID(_ value: String) { mutateSettings { $0.asrResourceID = value } }
    func setASRAuthMode(_ mode: ASRAuthMode) { mutateSettings { $0.asrAuthMode = mode } }

    func beginCapture() {
        isCapturingHotkey = true
        captureMessage = "请按下快捷键。只按下右 Command 后松开，也会保存为右 Command。Esc 取消。"
        hotkey.setCapturing(true)
        refreshHotkeyPause()
    }

    func restoreDefaultHotkey() {
        mutateSettings {
            $0.hotkey = .defaultRightCommand
            $0.recordMode = .hold
        }
        captureMessage = "已恢复为右 Command，按住录音。"
    }

    func saveDoubaoAPIKey(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? credentials.save(trimmed, account: .doubaoAPIKey)
        refreshCredentialFlags()
    }

    func saveLegacyCredentials(appKey: String, accessKey: String) {
        let app = appKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let access = accessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !app.isEmpty { try? credentials.save(app, account: .doubaoAppKey) }
        if !access.isEmpty { try? credentials.save(access, account: .doubaoAccessKey) }
        refreshCredentialFlags()
    }

    func saveCorrectionKey(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? credentials.save(trimmed, account: .correctionAPIKey)
        refreshCredentialFlags()
    }

    func clearDoubaoCredentials() {
        credentials.delete(.doubaoAPIKey)
        credentials.delete(.doubaoAppKey)
        credentials.delete(.doubaoAccessKey)
        refreshCredentialFlags()
    }

    func clearCorrectionKey() {
        credentials.delete(.correctionAPIKey)
        refreshCredentialFlags()
    }

    func testASR() {
        guard !state.isPipelineActive else {
            asrTestMessage = "正在处理语音，请稍后再测试。"
            return
        }
        asrTestMessage = "正在连接。会发送约 0.2 秒静音，可能产生少量费用。"
        Task {
            do {
                let config = try self.makeConfig()
                let client = DoubaoStreamingASR()
                try await client.open(config)
                await client.sendAudio(Data(count: SessionLimits.audioChunkBytes))
                _ = try await client.finish()
                self.onMain { self.asrTestMessage = "已连通。" }
            } catch let error as ASRError {
                let text: String
                if case let .server(code) = error, code == 45_000_002 {
                    text = "已连通。这段静音没有识别出文字。"
                } else {
                    text = error.message
                }
                self.onMain { self.asrTestMessage = text }
            } catch {
                self.onMain { self.asrTestMessage = "连接失败。" }
            }
        }
    }

    func testCorrection() {
        guard !state.isPipelineActive else {
            correctionTestMessage = "正在处理语音，请稍后再测试。"
            return
        }
        correctionTestMessage = "正在测试，可能产生少量费用。"
        let config = correctionConfig()
        Task {
            do {
                _ = try await self.correction.test(config)
                self.onMain { self.correctionTestMessage = "纠错接口已连通。" }
            } catch let error as CorrectionServiceError {
                self.onMain { self.correctionTestMessage = error.message }
            } catch {
                self.onMain { self.correctionTestMessage = "纠错测试失败，正式使用时会回退到原转写。" }
            }
        }
    }

    func refreshPermissions() {
        microphoneText = PermissionChecker.microphoneGranted() ? "已允许" : "未允许"
        accessibilityText = PermissionChecker.accessibilityGranted() ? "已允许" : "未允许"
        listenText = PermissionChecker.listenEventGranted() ? "已允许" : "未允许"
        if !hotkey.tapInstalled {
            _ = hotkey.start()
        }
        hotkeyText = hotkey.tapInstalled ? "监听已开启" : "还不能监听按键"
    }

    func promptMicrophone() {
        Task {
            _ = await PermissionChecker.ensureMicrophone()
            self.onMain { self.refreshPermissions() }
        }
    }

    func promptAccessibility() {
        PermissionChecker.promptAccessibility()
        refreshPermissions()
    }

    func promptListen() {
        PermissionChecker.promptListenEvent()
        refreshPermissions()
    }

    func openPrivacy(_ pane: PrivacyPane) {
        PermissionChecker.open(pane)
    }

    func cancelFromUser() {
        if state.isPipelineActive {
            apply(.cancelled)
        } else {
            apply(.dismiss)
        }
    }

    func dismissCapsule() {
        apply(.dismiss)
    }

    func retryAudioAction() {
        guard !retryAudio.isEmpty, !state.isPipelineActive else {
            hint = retryAudio.isEmpty ? "没有可重试的录音，请重新说一次。" : "正在处理上一段"
            return
        }
        apply(.retryAudio(sessionID: UUID(), correctionEnabled: settings.correctionEnabled))
    }

    func showResult() {
        openResult()
    }

    func copyLastResult() {
        guard let lastResult, !lastResult.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastResult, forType: .string)
        hint = "已复制。这次会替换剪贴板。"
    }

    func armManualInsert() {
        guard let text = lastResult, !text.isEmpty else { return }
        resultWindow?.orderOut(nil)
        settingsWindow?.orderOut(nil)
        resultIsKey = false
        settingsIsKey = false
        refreshHotkeyPause()
        let mode = settings.insertionMode
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let outcome = await self.inserter.insertManual(text, mode: mode)
            self.onMain {
                switch outcome {
                case .inserted:
                    self.hint = "已输入。"
                case let .blocked(message), let .failed(message):
                    self.hint = message
                }
            }
        }
    }

    func closeResult() {
        resultWindow?.orderOut(nil)
        resultIsKey = false
        refreshHotkeyPause()
    }

    @objc func openSettingsAction() { openSettings() }
    @objc func openResultAction() { openResult() }
    @objc func quitAction() {
        shutdown()
        NSApp.terminate(nil)
    }

    func menuWillOpen(_ menu: NSMenu) {
        statusMenuItem?.title = "状态：\(statusText)"
        recentMenuItem?.isEnabled = !(lastResult ?? "").isEmpty
    }

    private func bindServices() {
        hotkey.onAction = { [weak self] output in
            self?.handleHotkey(output)
        }
        hotkey.onCapture = { [weak self] result in
            self?.handleCapture(result)
        }
        inserter.pausedHotkeys = { [weak self] paused in
            self?.onMain {
                self?.insertPause = paused
                self?.refreshHotkeyPause()
            }
        }
        settingsWatcher.onKey = { [weak self] isKey in
            self?.settingsIsKey = isKey
            self?.refreshHotkeyPause()
            if isKey { self?.refreshPermissions() }
        }
        resultWatcher.onKey = { [weak self] isKey in
            self?.resultIsKey = isKey
            self?.refreshHotkeyPause()
        }
    }

    private func handleHotkey(_ output: HotkeyOutput) {
        switch output {
        case .none:
            break
        case .beginCandidate, .toggleStart:
            apply(.hotkeyBegan(sessionID: UUID(), correctionEnabled: settings.correctionEnabled))
        case .endAndSubmit, .toggleStop:
            apply(.hotkeyEnded)
        case .cancel:
            apply(.cancelled)
        case .busyIgnored:
            showBusy()
        }
    }

    private func handleCapture(_ result: HotkeyCaptureResult) {
        isCapturingHotkey = false
        hotkey.setCapturing(false)
        switch result {
        case .none:
            break
        case let .committed(binding):
            mutateSettings { $0.hotkey = binding }
            captureMessage = "已保存：\(binding.displayName)。请实际试一次，确认没有和现有快捷键冲突。"
        case let .rejected(message):
            captureMessage = message
        case .cancelled:
            captureMessage = "已取消录制。"
        }
        refreshHotkeyPause()
    }

    private func apply(_ event: SessionEvent) {
        let reduced = SessionReducer.reduce(state, event)
        state = reduced.state
        isBusy = state.isPipelineActive
        hotkey.setBusy(state.isPipelineActive)
        if !state.isPipelineActive, pendingHotkeyApply {
            pendingHotkeyApply = false
            hotkey.apply(mode: settings.recordMode, binding: settings.hotkey)
        }
        switch reduced.effect {
        case .none:
            syncUI()
        case .beginAudio:
            beginAudio()
        case .openSocket:
            openSocket()
        case .finishAudio:
            finishAudio()
        case let .stopInput(keepRetryAudio):
            discardAudio(keepRetry: keepRetryAudio)
        case let .requestCorrection(text):
            runCorrection(text)
        case let .requestInsert(text):
            runInsert(text)
        case .replayAudio:
            replayAudio()
        case .busy:
            showBusy()
        }
    }

    private func beginAudio() {
        recordStarted = Date()
        focus = FocusGuard.capture()
        retryAudio.removeAll()
        canRetryAudio = false
        sessionInsertionMode = settings.insertionMode
        asr = DoubaoStreamingASR()
        syncUI()
        Task {
            let granted = await PermissionChecker.ensureMicrophone()
            self.onMain {
                guard self.state.phase == .candidate || self.state.phase == .recording else { return }
                guard granted else {
                    self.apply(.audioFailed("没有麦克风权限。"))
                    return
                }
                self.startEngine()
            }
        }
        confirmTask?.cancel()
        confirmTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(SessionLimits.candidateDelayMilliseconds) * 1_000_000)
            guard !Task.isCancelled else { return }
            self.apply(.candidateConfirmed)
        }
        maxDurationTask?.cancel()
        maxDurationTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(SessionLimits.maxRecordingSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.apply(.maxDuration)
        }
    }

    private func startEngine() {
        do {
            try audio.start { [weak self] data, level in
                DispatchQueue.main.async {
                    self?.ingest(data, level: level)
                }
            } onDeviceChange: { [weak self] in
                DispatchQueue.main.async {
                    self?.apply(.audioDeviceChanged)
                }
            }
        } catch let error as AudioCaptureError {
            apply(.audioFailed(error.message))
        } catch {
            apply(.audioFailed(AudioCaptureError.startFailed.message))
        }
    }

    private func ingest(_ data: Data, level: Float) {
        guard state.acceptsAudio else { return }
        appendRetry(data)
        let client = asr
        Task { await client?.sendAudio(data) }
        let now = Date()
        if now.timeIntervalSince(levelTick) > 0.06 {
            levelTick = now
            inputLevel = Double(level)
        }
    }

    private func openSocket() {
        let id = state.sessionID
        let client = asr
        Task {
            do {
                let config = try self.makeConfig()
                try await client?.open(config)
            } catch let error as ASRError {
                if case .cancelled = error { return }
                self.onMain {
                    guard self.state.sessionID == id else { return }
                    self.canRetryAudio = !self.retryAudio.isEmpty
                    self.apply(.asrFailed(sessionID: id, message: error.message))
                }
            } catch is CancellationError {
                return
            } catch {
                self.onMain {
                    guard self.state.sessionID == id else { return }
                    self.apply(.asrFailed(sessionID: id, message: "连接语音识别服务失败。"))
                }
            }
        }
    }

    private func finishAudio() {
        confirmTask?.cancel()
        maxDurationTask?.cancel()
        latencyStop = Date()
        let tail = audio.stop()
        if !tail.isEmpty { appendRetry(tail) }
        let id = state.sessionID
        let client = asr
        syncUI()
        pipelineTask = Task {
            if !tail.isEmpty {
                await client?.sendAudio(tail)
            }
            do {
                let config = try self.makeConfig()
                try await client?.open(config)
                let text = try await client?.finish() ?? ""
                self.onMain { self.apply(.finalTranscript(sessionID: id, text: text)) }
            } catch let error as ASRError {
                if case .cancelled = error { return }
                let interim = await client?.latest() ?? ""
                self.onMain {
                    if !interim.isEmpty { self.lastResult = interim }
                    self.canRetryAudio = !self.retryAudio.isEmpty
                    self.apply(.asrFailed(sessionID: id, message: error.message))
                }
            } catch is CancellationError {
                return
            } catch {
                self.onMain {
                    self.canRetryAudio = !self.retryAudio.isEmpty
                    self.apply(.asrFailed(sessionID: id, message: "识别失败。"))
                }
            }
        }
    }

    private func discardAudio(keepRetry: Bool = false) {
        confirmTask?.cancel()
        maxDurationTask?.cancel()
        pipelineTask?.cancel()
        _ = audio.stop()
        let client = asr
        Task { await client?.cancel() }
        if !keepRetry {
            retryAudio.removeAll()
            canRetryAudio = false
        } else {
            canRetryAudio = !retryAudio.isEmpty
        }
        inputLevel = 0
        syncUI()
    }

    private func runCorrection(_ text: String) {
        let id = state.sessionID
        let config = correctionConfig()
        syncUI()
        pipelineTask = Task {
            let corrected = await self.correction.correct(text, config: config)
            if Task.isCancelled { return }
            self.onMain { self.apply(.correctionResolved(sessionID: id, text: corrected)) }
        }
    }

    private func runInsert(_ text: String) {
        let id = state.sessionID
        let mode = sessionInsertionMode
        let snapshot = focus ?? FocusGuard.capture()
        syncUI()
        pipelineTask = Task { @MainActor in
            guard self.state.sessionID == id, self.state.phase == .inserting else { return }
            let outcome = await self.inserter.insertAutomatic(text, mode: mode, focus: snapshot)
            let chunks = UnicodeChunker.chunks(text).count
            self.onMain {
                guard self.state.sessionID == id else { return }
                switch outcome {
                case .inserted:
                    self.lastResult = text
                    self.logLatency(chunks: chunks)
                    self.retryAudio.removeAll()
                    self.canRetryAudio = false
                    self.apply(.insertSucceeded(sessionID: id))
                case let .blocked(reason):
                    self.lastResult = text
                    self.apply(.insertBlocked(sessionID: id, text: text, reason: reason))
                case let .failed(reason):
                    self.lastResult = text
                    self.apply(.insertFailed(sessionID: id, message: reason))
                }
            }
        }
    }

    private func replayAudio() {
        let payload = retryAudio
        let id = state.sessionID
        let client = DoubaoStreamingASR()
        asr = client
        focus = FocusGuard.capture()
        sessionInsertionMode = settings.insertionMode
        syncUI()
        pipelineTask = Task {
            do {
                let config = try self.makeConfig()
                try await client.open(config)
                var offset = 0
                while offset < payload.count {
                    if Task.isCancelled { return }
                    let end = min(offset + SessionLimits.audioChunkBytes, payload.count)
                    let chunk = payload.subdata(in: offset..<end)
                    await client.sendAudio(chunk)
                    offset = end
                    if offset < payload.count {
                        try await Task.sleep(nanoseconds: 200_000_000)
                    }
                }
                let text = try await client.finish()
                self.onMain { self.apply(.finalTranscript(sessionID: id, text: text)) }
            } catch let error as ASRError {
                if case .cancelled = error { return }
                self.onMain {
                    self.canRetryAudio = !self.retryAudio.isEmpty
                    self.apply(.asrFailed(sessionID: id, message: error.message))
                }
            } catch is CancellationError {
                return
            } catch {
                self.onMain { self.apply(.asrFailed(sessionID: id, message: "重试失败。")) }
            }
        }
    }

    private func showBusy() {
        hint = "正在处理上一段"
        statusText = "正在处理"
        hintTask?.cancel()
        hintTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if self.hint == "正在处理上一段" { self.hint = nil }
            if !self.state.isPipelineActive { self.statusText = "空闲" }
        }
    }

    private func syncUI() {
        switch state.phase {
        case .idle:
            statusText = "空闲"
            capsule = nil
            inputLevel = 0
        case .candidate, .recording:
            statusText = "录音中"
            if case .recording = capsule {
            } else {
                capsule = .recording(recordStarted)
            }
        case .waitingFinal:
            statusText = "转写中"
            capsule = .transcribing
        case .correcting:
            statusText = "纠错中"
            capsule = .correcting
        case .inserting:
            statusText = "输入中"
            capsule = .inserting
        case .completed:
            statusText = "空闲"
            if state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                capsule = nil
                inputLevel = 0
            } else {
                capsule = .completed
                lastResult = state.text
                scheduleHide()
            }
        case .cancelled:
            statusText = "空闲"
            capsule = nil
            inputLevel = 0
        case .failed:
            statusText = "失败"
            capsule = .failed(state.banner.isEmpty ? "识别失败。" : state.banner)
            canRetryAudio = !retryAudio.isEmpty
        case .pendingUser:
            statusText = "等待输入"
            capsule = .pending(state.banner)
            if !state.text.isEmpty { lastResult = state.text }
        }
        overlay.sync(visible: capsule != nil)
        statusItem?.button?.toolTip = "轻语 · \(statusText)"
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(SessionLimits.completedVisibleSeconds * 1_000_000_000))
            guard self.state.phase == .completed else { return }
            self.apply(.dismiss)
        }
    }

    private func appendRetry(_ data: Data) {
        guard retryAudio.count < SessionLimits.retryAudioBytes else { return }
        let room = SessionLimits.retryAudioBytes - retryAudio.count
        retryAudio.append(data.prefix(room))
    }

    private func logLatency(chunks: Int) {
        guard let stop = latencyStop else { return }
        let full = Int(Date().timeIntervalSince(stop) * 1000)
        let typing = max(0, (chunks - 1) * 5)
        AppLog.event("latency", "firstMs=\(max(0, full - typing)) fullMs=\(full) chunks=\(chunks)")
    }

    private func mutateSettings(_ body: (inout AppSettings) -> Void) {
        body(&settings)
        store.save(settings)
        if state.isPipelineActive {
            pendingHotkeyApply = true
        } else {
            hotkey.apply(mode: settings.recordMode, binding: settings.hotkey)
        }
    }

    private func makeConfig() throws -> DoubaoConfig {
        let endpoint = settings.asrEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let resource = settings.asrResourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        switch settings.asrAuthMode {
        case .apiKey:
            guard let key = credentials.load(.doubaoAPIKey), !key.isEmpty else { throw ASRError.missingCredential }
            return DoubaoConfig(
                endpoint: endpoint,
                resourceID: resource,
                authMode: .apiKey,
                apiKey: key,
                appKey: "",
                accessKey: "",
                connectID: UUID().uuidString
            )
        case .legacy:
            guard let app = credentials.load(.doubaoAppKey), !app.isEmpty,
                  let access = credentials.load(.doubaoAccessKey), !access.isEmpty else {
                throw ASRError.missingCredential
            }
            return DoubaoConfig(
                endpoint: endpoint,
                resourceID: resource,
                authMode: .legacy,
                apiKey: "",
                appKey: app,
                accessKey: access,
                connectID: UUID().uuidString
            )
        }
    }

    private func correctionConfig() -> CorrectionConfig {
        CorrectionConfig(
            baseURL: settings.correctionBaseURL,
            model: settings.correctionModel,
            apiKey: credentials.load(.correctionAPIKey) ?? ""
        )
    }

    private func refreshCredentialFlags() {
        hasDoubaoAPIKey = credentials.exists(.doubaoAPIKey)
        hasDoubaoAppKey = credentials.exists(.doubaoAppKey)
        hasDoubaoAccessKey = credentials.exists(.doubaoAccessKey)
        hasCorrectionKey = credentials.exists(.correctionAPIKey)
    }

    private func refreshHotkeyPause() {
        let windowPause = (settingsIsKey || resultIsKey) && !isCapturingHotkey
        hotkey.setPaused(insertPause || windowPause)
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "轻语") {
            image.isTemplate = true
            item.button?.image = image
        }
        item.button?.toolTip = "轻语"
        let menu = NSMenu()
        menu.delegate = self
        let status = NSMenuItem(title: "状态：空闲", action: nil, keyEquivalent: "")
        status.isEnabled = false
        let settingsItem = NSMenuItem(title: "打开设置", action: #selector(openSettingsAction), keyEquivalent: ",")
        let recent = NSMenuItem(title: "查看最近结果", action: #selector(openResultAction), keyEquivalent: "")
        recent.isEnabled = false
        let quit = NSMenuItem(title: "退出", action: #selector(quitAction), keyEquivalent: "q")
        for entry in [settingsItem, recent, quit] {
            entry.target = self
        }
        menu.addItem(status)
        menu.addItem(settingsItem)
        menu.addItem(recent)
        menu.addItem(.separator())
        menu.addItem(quit)
        statusMenuItem = status
        recentMenuItem = recent
        item.menu = menu
        statusItem = item
    }

    private func openSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(model: self))
            let window = NSWindow(contentViewController: hosting)
            window.title = "轻语设置"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = settingsWatcher
            settingsWindow = window
        }
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        refreshPermissions()
    }

    private func openResult() {
        if resultWindow == nil {
            let hosting = NSHostingController(rootView: ResultView(model: self))
            let window = NSWindow(contentViewController: hosting)
            window.title = "最近结果"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = resultWatcher
            resultWindow = window
        }
        resultWindow?.center()
        resultWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated(body)
            }
        }
    }
}
