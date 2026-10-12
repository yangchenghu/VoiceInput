# 轻语：给后续改动的约束

个人使用的 macOS 菜单栏语音输入工具。按住右 Command 说话，松开后把文字输入当前输入框。需求以 [docs/语音输入工具开发说明.md](docs/语音输入工具开发说明.md) 为准；实现和验证状态以 [README.md](README.md)、[docs/阶段A验证记录.md](docs/阶段A验证记录.md) 为准。

## 不要改的决定

- 形态是菜单栏工具（`LSUIElement`），不是 InputMethodKit 输入法。
- 默认输入是 Unicode 键盘事件，不读、不写剪贴板。识别或输入失败时不要自动改成粘贴。
- 兼容粘贴只有用户在设置里打开后才能用。粘贴前保存剪贴板；若 `changeCount` 已变，不要用旧快照覆盖。只有「复制结果」可以有意改剪贴板。
- 默认快捷键是右 Command（keyCode 54，设备标志 `0x10`）。左 Command 不能开始录音。右 Command 加任何其他键必须仍是普通组合键，并取消本次录音。监听用 `CGEventTap` 的 listen-only，不要吞掉原事件。
- 自己合成的事件带 `EventMark.userData`，监听端必须忽略，避免输入再次触发录音。
- 含换行的文本不要自动输入，也不要合成 Return 键。结果留在内存里给用户手动处理。
- 不自动按回车，不把文字送进已经换掉的前台应用。
- 同一时间只有一个任务。异步回调先对 `sessionID`；取消或过期的结果不得输入。
- 中间识别结果可以覆盖保存，不能写入编辑器。只有最终结果才能提交。
- 轻度纠错默认关闭。失败、超时、空结果或明显扩写时回退原文，不要阻断输入。
- 第一版不做：读屏、Agent、账号、订阅、翻译扩写、多家 ASR、本地模型、历史文件、Windows/iOS、沙盒。

## 代码放哪

| 目录 | 职责 |
| --- | --- |
| `Sources/Core` | `AppCoordinator`、`SessionReducer`、日志与限额 |
| `Sources/Hotkey` | 快捷键状态机、录制、`CGEventTap` |
| `Sources/Audio` | 采集、16 kHz PCM、有界缓冲 |
| `Sources/ASR` | 豆包二进制帧、WebSocket |
| `Sources/Correction` | 纠错策略与 Chat Completions 请求 |
| `Sources/Insertion` | Unicode 分片、焦点、剪贴板恢复 |
| `Sources/UI` | 设置、胶囊、结果 |
| `Sources/Storage` | UserDefaults 与钥匙串 |
| `Spikes/` | 右 Command 与 Cursor 输入的独立验证 App |
| `Tests/` | 纯逻辑；协议、状态机、分片、纠错、剪贴板策略 |

状态机以 `SessionReducer` 为单一规则。新的阶段转换先改 reducer 和测试，再让 coordinator 执行副作用。

## 豆包协议

帧格式以火山引擎《大模型流式语音识别 API》（文档更新 2026-08-06）为准：https://www.volcengine.com/docs/6561/1354869

`DoubaoDefaults` 里的地址和资源 ID 是文档推荐值，不是对本账号的实测。改默认值前先核对当时的官方文档，并在注释和 README 里写明依据。`result.text` 在 `result_type=full` 时是全量文本，覆盖而不是拼接。凭证只放钥匙串，不要进仓库、UserDefaults、日志或崩溃信息。

日志只记状态、耗时、错误类别和请求标识。不要记录音频、转写全文、Authorization 或带密钥的 URL。

## 构建与验证

```bash
xcodegen generate
xcodebuild -scheme VoiceInput -configuration Debug -destination 'platform=macOS,arch=arm64' build
xcodebuild -scheme VoiceInput -configuration Debug -destination 'platform=macOS,arch=arm64' test
```

改 `project.yml` 的源文件后必须重新 `xcodegen generate`。不要打开 App Sandbox。`DEVELOPMENT_TEAM` 保持现有开发证书，否则辅助功能和输入监控会因签名变化失效。入口文件不要命名为 `main.swift`，否则会和 `@main` 冲突。

交付时分开写清：已实现、单测通过、真实服务验证通过、仍需用户在本机验证。右 Command、Cursor 实际输入、豆包账号延迟都不能用单测代替。交互验证用 HotkeySpike 和 InsertSpike，步骤见阶段 A 记录。核心交互做不到时先说明证据，不要悄悄换方案。
