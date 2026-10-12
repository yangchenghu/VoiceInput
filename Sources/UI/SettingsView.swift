import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppCoordinator
    @State private var apiKey = ""
    @State private var appKey = ""
    @State private var accessKey = ""
    @State private var correctionKey = ""

    var body: some View {
        ScrollView {
            Form {
                Section("输入操作") {
                    LabeledContent("当前快捷键") {
                        Text(model.settings.hotkey.displayName)
                    }
                    HStack {
                        Button(model.isCapturingHotkey ? "正在录制…" : "录制快捷键") {
                            model.beginCapture()
                        }
                        Button("恢复默认") { model.restoreDefaultHotkey() }
                    }
                    if !model.captureMessage.isEmpty {
                        Text(model.captureMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Picker("录音模式", selection: recordMode) {
                        Text("按住录音，松开结束").tag(RecordMode.hold)
                        Text("点击开始，再点击结束").tag(RecordMode.toggle)
                    }
                    Text("默认是右 Command。按住期间如果按下其他键，会当成普通组合键并取消这次录音。左 Command 不会开始录音。这里不能保证和其他应用的全局快捷键一定不冲突，请实际试一下。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("语音识别") {
                    Picker("鉴权方式", selection: authMode) {
                        Text("新版 API Key").tag(ASRAuthMode.apiKey)
                        Text("旧版 App ID + Access Token").tag(ASRAuthMode.legacy)
                    }
                    TextField("WebSocket 地址", text: endpoint)
                    TextField("资源 ID", text: resourceID)
                    Text("文档推荐双向流式优化版和模型 2.0 小时版。若控制台是 1.0，把资源 ID 改成 volc.bigasr.sauc.duration。这些默认值来自官方文档，不是对本账号的实测。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.settings.asrAuthMode == .apiKey {
                        SecureField(model.hasDoubaoAPIKey ? "API Key（已保存，留空不修改）" : "API Key", text: $apiKey)
                        Button("保存 API Key") {
                            model.saveDoubaoAPIKey(apiKey)
                            apiKey = ""
                        }
                        .disabled(apiKey.isEmpty)
                    } else {
                        SecureField(model.hasDoubaoAppKey ? "App ID（已保存，留空不修改）" : "App ID", text: $appKey)
                        SecureField(model.hasDoubaoAccessKey ? "Access Token（已保存，留空不修改）" : "Access Token", text: $accessKey)
                        Button("保存旧版凭证") {
                            model.saveLegacyCredentials(appKey: appKey, accessKey: accessKey)
                            appKey = ""
                            accessKey = ""
                        }
                    }
                    HStack {
                        Button("清除语音凭证") { model.clearDoubaoCredentials() }
                        Button("连接测试") { model.testASR() }
                            .disabled(model.isBusy)
                    }
                    Text("连接测试会发送约 0.2 秒静音，可能产生少量费用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !model.asrTestMessage.isEmpty {
                        Text(model.asrTestMessage)
                            .font(.caption)
                    }
                    Text("使用系统默认麦克风。录音时如果耳机或麦克风断开，这次会取消，需要重新开始。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("轻度纠错") {
                    Toggle("开启轻度纠错", isOn: correctionEnabled)
                    Text("默认关闭。开启后才会把转写文本发给下面的文本模型。失败或超时会用原来的转写，不会卡住输入。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Base URL", text: correctionURL, prompt: Text("https://example.com/v1"))
                    TextField("模型名称", text: correctionModel)
                    SecureField(model.hasCorrectionKey ? "API Key（已保存，留空不修改）" : "API Key", text: $correctionKey)
                    HStack {
                        Button("保存纠错密钥") {
                            model.saveCorrectionKey(correctionKey)
                            correctionKey = ""
                        }
                        .disabled(correctionKey.isEmpty)
                        Button("清除") { model.clearCorrectionKey() }
                        Button("测试") { model.testCorrection() }
                            .disabled(model.isBusy)
                    }
                    Text("测试会发送一句固定文本，可能产生少量费用。接口需要兼容 Chat Completions。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !model.correctionTestMessage.isEmpty {
                        Text(model.correctionTestMessage)
                            .font(.caption)
                    }
                }

                Section("文字输入") {
                    Picker("输入方式", selection: insertionMode) {
                        Text("默认：直接输入，不使用剪贴板").tag(InsertionMode.unicode)
                        Text("兼容：临时粘贴").tag(InsertionMode.clipboard)
                    }
                    Text("默认方式不读取、不修改剪贴板。兼容方式会在粘贴前保存剪贴板，粘贴后尽量恢复；如果期间剪贴板又被别的内容更新，就不会用旧内容覆盖。这个恢复不是原子操作，崩溃时也可能来不及恢复。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("权限") {
                    LabeledContent("麦克风", value: model.microphoneText)
                    LabeledContent("辅助功能", value: model.accessibilityText)
                    LabeledContent("输入监控", value: model.listenText)
                    LabeledContent("快捷键", value: model.hotkeyText)
                    HStack {
                        Button("请求麦克风") { model.promptMicrophone() }
                        Button("请求辅助功能") { model.promptAccessibility() }
                        Button("请求输入监控") { model.promptListen() }
                    }
                    HStack {
                        Button("麦克风设置") { model.openPrivacy(.microphone) }
                        Button("辅助功能设置") { model.openPrivacy(.accessibility) }
                        Button("输入监控设置") { model.openPrivacy(.listenEvent) }
                        Button("刷新") { model.refreshPermissions() }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 640, height: 720)
    }

    private var recordMode: Binding<RecordMode> {
        Binding(get: { model.settings.recordMode }, set: { model.setRecordMode($0) })
    }
    private var authMode: Binding<ASRAuthMode> {
        Binding(get: { model.settings.asrAuthMode }, set: { model.setASRAuthMode($0) })
    }
    private var endpoint: Binding<String> {
        Binding(get: { model.settings.asrEndpoint }, set: { model.setASREndpoint($0) })
    }
    private var resourceID: Binding<String> {
        Binding(get: { model.settings.asrResourceID }, set: { model.setASRResourceID($0) })
    }
    private var correctionEnabled: Binding<Bool> {
        Binding(get: { model.settings.correctionEnabled }, set: { model.setCorrectionEnabled($0) })
    }
    private var correctionURL: Binding<String> {
        Binding(get: { model.settings.correctionBaseURL }, set: { model.setCorrectionBaseURL($0) })
    }
    private var correctionModel: Binding<String> {
        Binding(get: { model.settings.correctionModel }, set: { model.setCorrectionModel($0) })
    }
    private var insertionMode: Binding<InsertionMode> {
        Binding(get: { model.settings.insertionMode }, set: { model.setInsertionMode($0) })
    }
}

struct ResultView: View {
    @ObservedObject var model: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("最近一次结果只保存在内存里，退出后就没有了。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(model.lastResult?.isEmpty == false ? model.lastResult! : "没有结果")
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button("2 秒后输入") { model.armManualInsert() }
                    .disabled(model.lastResult?.isEmpty != false)
                Button("复制结果") { model.copyLastResult() }
                    .disabled(model.lastResult?.isEmpty != false)
                Button("关闭") { model.closeResult() }
            }
            Text("点“2 秒后输入”后，请在 2 秒内点进目标输入框。换行会作为换行字符输入，不会按 Return 键；聊天软件是否因此发送，取决于那个软件。复制结果会有意修改剪贴板。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let hint = model.hint, !hint.isEmpty {
                Text(hint).font(.caption)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
