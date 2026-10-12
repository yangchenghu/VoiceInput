# 阶段 A 验证记录

日期：2026-10-12。机器：macOS 26.6.2，arm64，Xcode 27。

## 已在本机自动跑过

`xcodebuild -scheme VoiceInput test` 通过了 35 个测试，没有失败。覆盖：

- 右 Command 按下松开会开始并结束；左 Command 不会开始。
- 右 Command 按住后再按其他键会取消，松开时不会提交。
- 点击切换模式下，组合键不会被当成停止。
- Esc、忙碌中的新触发、设置录制快捷键时的暂停。
- 取消之后迟到的识别结果不会输入；session 不一致不会输入；空文本和换行不会自动输入。
- 纠错路径先纠正再输入；失败回退原文；过长或带解释的结果回退。
- Unicode 按字符簇切分，不拆代理对，超长字素单独成片。
- 豆包二进制帧可以编码再解回，全量 `result.text` 按覆盖理解，结束包和错误包能区分。
- gzip 往返。
- 剪贴板恢复只在 changeCount 没变时进行；音频缓冲超限丢掉最旧的数据。

这些测试不经过真实键盘、真实 Cursor，也不连接豆包。

## 需要你本机点一次

### 右 Command

```bash
open build/DerivedData/Build/Products/Debug/HotkeySpike.app
```

系统如果要求输入监控或辅助功能，允许后重新打开。按窗口里的 5 步看日志。通过标准：

- 右 Command 按下出现 beginCandidate，松开出现 endAndSubmit。
- 左 Command 没有 beginCandidate。
- 右 Command+C / V / Tab 出现 cancel，不出现 endAndSubmit，原来的复制、粘贴、切换仍然有效。

### Cursor 无剪贴板输入

```bash
open build/DerivedData/Build/Products/Debug/InsertSpike.app
```

点每个按钮后，在 2 秒内点进 Cursor。每种都在「先选中一段文字」和「中文输入法开着 / 关着」时各试一次。窗口会写剪贴板 changeCount 有没有变。通过标准是 Cursor 里文字正确，changeCount 不变，多行没有把聊天消息发出去。

如果某一类失败，把失败的按钮名称和 Cursor 里实际出现的内容记在下面，再决定要不要改输入路线。不要因此自动改成剪贴板方案。

| 用例 | 结果 | 备注 |
| --- | --- | --- |
| 中文和标点 | 待测 | |
| 英文和符号 | 待测 | |
| Emoji 和组合字符 | 待测 | |
| 选区替换 | 待测 | |
| 多行 | 待测 | |
| 长文本 2000 字 | 待测 | |
| 中文输入法开着 | 待测 | |
| 剪贴板 changeCount | 待测 | |
