# 轻语

用 AI coding 练手做的 macOS 语音输入小工具。平时主要用闪电说，觉得有点臃肿，就自己做了更轻的一版：按住快捷键说话，松开后把文字打进当前输入框，默认不碰剪贴板。欢迎试用。

按住右 Command 说话，松开后把语音转成文字，输入到当前输入框。

## 环境

- macOS 14 或更高，当前只在 Apple Silicon 上编过
- Xcode 27 / Swift 6
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

签名使用本机已有的 Apple Development 证书，Team ID 写在 `project.yml` 的 `DEVELOPMENT_TEAM`（当前是 `57FVQX3F2U`）。辅助功能和输入监控是按签名记住的，换证书后需要重新授权。不使用 App Sandbox。

## 构建

```bash
xcodegen generate
xcodebuild -scheme VoiceInput -configuration Debug -destination 'platform=macOS,arch=arm64' build
xcodebuild -scheme VoiceInput -configuration Debug -destination 'platform=macOS,arch=arm64' test
```

产物是 `build/DerivedData/Build/Products/Debug/VoiceInput.app`。直接打开它即可，它没有 Dock 图标。

阶段 A 的两个验证工具：

```bash
xcodebuild -scheme HotkeySpike -configuration Debug -destination 'platform=macOS,arch=arm64' build
xcodebuild -scheme InsertSpike -configuration Debug -destination 'platform=macOS,arch=arm64' build
open build/DerivedData/Build/Products/Debug/HotkeySpike.app
open build/DerivedData/Build/Products/Debug/InsertSpike.app
```

## 第一次使用

1. 打开轻语，菜单栏会出现波形图标。
2. 在设置里填写豆包语音凭证。密钥只进钥匙串，不会写进仓库或 UserDefaults。
3. 允许麦克风、辅助功能和输入监控。快捷键监听实际用到哪一项，以系统弹出的授权为准。
4. 在 Cursor 里放好光标，按住右 Command 说话，松开后出字。

凭证示例（空值）见 [Config/settings.example.json](Config/settings.example.json)。

### 豆包语音

实现依据火山引擎《大模型流式语音识别 API》，文档更新时间 2026-08-06：

- https://www.volcengine.com/docs/6561/1354869

默认地址是双向流式优化版 `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async`，默认资源 ID 是模型 2.0 小时版 `volc.seedasr.sauc.duration`。这是文档里的推荐值，不是对你这个账号的实测。控制台如果是 1.0，把资源 ID 改成 `volc.bigasr.sauc.duration`。另外两个地址：

- `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel`
- `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream`

新版控制台填 API Key。旧版填 App ID 和 Access Token。点「连接测试」才会发约 0.2 秒静音，可能产生少量费用。

### 轻度纠错

默认关闭。打开后把转写文本发给一个 Chat Completions 兼容接口，超时约 2 秒。失败、空结果或明显跑偏时，用原来的转写继续输入。不要和语音识别共用同一把钥匙，除非你确认服务商允许。

## 快捷键

- 默认是右 Command。左 Command 不会开始录音。
- 按住期间如果再按 C、V、Tab 或其他键，这次录音会取消，原来的组合键照常生效。
- 设置里可以改成点击切换，或录一个带修饰键的组合。恢复默认会回到右 Command、按住录音。
- 不能保证检测出所有应用的全局快捷键冲突，改完请自己试一次。
- 设置窗口或结果窗口在前面时，快捷键暂停，避免在设置里打字时开始录音。

## 剪贴板

默认用 Unicode 键盘事件输入，不读、不写剪贴板。验收时可以用复制一个网址，语音输入后再粘贴，网址应该还在。

兼容粘贴模式要在设置里手动打开。它会在真正粘贴前保存剪贴板，粘贴后如果剪贴板仍是这次写入的内容，再恢复。如果中间又复制了别的东西，就不会用旧内容覆盖。这不是系统级原子操作，应用崩溃时也可能来不及恢复。

只有点「复制结果」才会有意改剪贴板。

## 已知限制

- 含换行的文本不会自动输入，避免聊天框把换行当成发送。结果会留在「最近结果」里，可以手动输入。手动输入用的是换行字符，不是 Return 键。
- 录音开始后如果前台应用变了，不会把文字送进新应用。
- 同一时间只有一段语音在处理。处理中再按快捷键，会提示正在处理。
- 麦克风中途断开或切换时，这次录音取消。
- 单次录音最长约 60 秒。
- 最近一次结果和可重试的音频只放在内存里，退出就没了。
- 没有账号、订阅、历史记录、截图或读屏。
- 还没有用真实豆包账号测过延迟。日志里会记 `latency firstMs=… fullMs=…`，不含文本内容。

## 验证状态

| 项目 | 状态 |
| --- | --- |
| 协议帧、状态机、快捷键逻辑、Unicode 分片、纠错回退、剪贴板恢复策略 | 单元测试已通过 |
| 右 Command 和 Cursor 实际输入 | 需要在本机打开 HotkeySpike、InsertSpike 看，见 [docs/阶段A验证记录.md](docs/阶段A验证记录.md) |
| 豆包真实账号和端到端延迟 | 需要你在设置里保存凭证后试，见 [docs/实机验收清单.md](docs/实机验收清单.md) |

## 协议

[MIT License](LICENSE)
