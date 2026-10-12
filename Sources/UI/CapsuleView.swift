import AppKit
import SwiftUI

enum CapsuleStatus: Equatable {
    case recording(Date)
    case transcribing
    case correcting
    case inserting
    case completed
    case failed(String)
    case pending(String)
}

struct CapsuleView: View {
    @ObservedObject var model: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                statusMark
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                if showsWave {
                    Waveform(level: model.inputLevel)
                }
                if case .recording(let start) = model.capsule {
                    TimelineView(.periodic(from: start, by: 0.2)) { context in
                        Text(Self.clock(context.date.timeIntervalSince(start)))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if showsActions {
                HStack(spacing: 8) {
                    Button("取消") { model.cancelFromUser() }
                        .keyboardShortcut(.cancelAction)
                    if model.canRetryAudio, case .failed = model.capsule {
                        Button("重试") { model.retryAudioAction() }
                    }
                    if case .failed = model.capsule {
                        Button("查看") { model.showResult() }
                    }
                    if case .pending = model.capsule {
                        Button("查看") { model.showResult() }
                    }
                    if case .failed = model.capsule {
                        Button("关闭") { model.dismissCapsule() }
                    }
                    if case .pending = model.capsule {
                        Button("关闭") { model.dismissCapsule() }
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minWidth: 280)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var title: String {
        switch model.capsule {
        case .recording: return "录音中"
        case .transcribing: return "正在转写…"
        case .correcting: return "正在轻度纠错…"
        case .inserting: return "正在输入…"
        case .completed: return "已完成"
        case let .failed(message): return message
        case let .pending(message): return message
        case nil: return ""
        }
    }

    private var subtitle: String? {
        if let hint = model.hint, !hint.isEmpty { return hint }
        switch model.capsule {
        case .recording, .transcribing, .correcting, .inserting:
            return "Esc 取消"
        default:
            return nil
        }
    }

    private var showsWave: Bool {
        if case .recording = model.capsule { return true }
        return false
    }

    private var showsActions: Bool {
        switch model.capsule {
        case .failed, .pending, .recording, .transcribing, .correcting, .inserting:
            return true
        default:
            return false
        }
    }

    @ViewBuilder
    private var statusMark: some View {
        switch model.capsule {
        case .recording:
            Circle().fill(Color.red).frame(width: 8, height: 8)
        case .failed, .pending:
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
        case .completed:
            Image(systemName: "checkmark.circle").foregroundStyle(.green)
        default:
            ProgressView().controlSize(.small)
        }
    }

    private static func clock(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

struct Waveform: View {
    var level: Double

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.red.opacity(0.9))
                    .frame(width: 3, height: height(index))
            }
        }
        .frame(width: 28, height: 16)
    }

    private func height(_ index: Int) -> CGFloat {
        let weights: [Double] = [0.45, 0.75, 1, 0.7, 0.4]
        return max(3, 16 * min(1, level) * weights[index])
    }
}

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class OverlayController {
    private var panel: OverlayPanel?
    private var hosting: NSHostingView<CapsuleView>?
    private weak var model: AppCoordinator?

    func install(model: AppCoordinator) {
        self.model = model
        let hosting = NSHostingView(rootView: CapsuleView(model: model))
        hosting.sizingOptions = [.intrinsicContentSize]
        let panel = OverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.contentView = hosting
        self.panel = panel
        self.hosting = hosting
    }

    func sync(visible: Bool) {
        guard let panel, let hosting else { return }
        if !visible {
            panel.orderOut(nil)
            return
        }
        let size = hosting.fittingSize
        let width = min(max(size.width, 280), 520)
        let height = max(size.height, 52)
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let frame = NSRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.minY + 28,
            width: width,
            height: height
        )
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }
}
