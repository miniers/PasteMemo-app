import AppKit
import SwiftUI

/// 剪贴板条目删除后的撤销提示条 — 绑定到 `DeleteUndoCoordinator`。
/// 替代原本的"删除前弹确认框"交互：立即删除，底部显示 toast，点击"撤销"或按 ⌘Z 恢复。
/// 若在撤销窗口内再次删除，则上一次的 undo 自动失效（没有叠加式撤销）。
struct ClipItemUndoToast: View {
    @ObservedObject private var coordinator = DeleteUndoCoordinator.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let pending = coordinator.pending {
                toastBody(count: pending.snapshots.count)
                    .id(pending.expiresAt)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(
            // ⌘Z 用 NSEvent 监听器，而不是 SwiftUI keyboardShortcut：
            //   1. SwiftUI 的 keyboardShortcut 只在 view 处于 first-responder 链上
            //      才生效，toast 是 overlay 里的被动视图，绑定不稳定。
            //   2. 焦点在搜索框等 NSTextView 时，文本框会先吃掉 ⌘Z 做文本撤销，
            //      导致 toast 的撤销时有时无。监听器在本窗口级别优先拦截。
            // monitor 生命周期跟随 `pending`：删除发生时注册，失效/撤销后注销。
            UndoShortcutInstaller(isActive: coordinator.pending != nil) {
                coordinator.undo()
            }
        )
    }

    // MARK: - Adaptive palette (Paper White in light mode / Dark Card in dark mode)

    private var isDark: Bool { colorScheme == .dark }

    private var panelFill: Color {
        isDark ? Color(red: 0.17, green: 0.17, blue: 0.19) : Color(red: 0.99, green: 0.99, blue: 0.98)
    }
    private var panelStroke: Color {
        isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.05)
    }
    private var textColor: Color {
        isDark ? Color(red: 0.93, green: 0.93, blue: 0.94) : Color(red: 0.08, green: 0.09, blue: 0.11)
    }
    private var checkColor: Color {
        Color(red: 0.13, green: 0.63, blue: 0.35)
    }
    private var actionColor: Color {
        isDark ? Color(red: 0.50, green: 0.73, blue: 1.00) : Color(red: 0.00, green: 0.31, blue: 0.78)
    }
    private var actionBackground: Color {
        isDark ? Color(red: 0.50, green: 0.73, blue: 1.00).opacity(0.18)
               : Color(red: 0.00, green: 0.31, blue: 0.78).opacity(0.10)
    }
    private var actionStroke: Color {
        isDark ? Color(red: 0.50, green: 0.73, blue: 1.00).opacity(0.22) : Color.clear
    }
    private var shadowColor: Color {
        isDark ? Color.black.opacity(0.48) : Color.black.opacity(0.14)
    }

    private func toastBody(count: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(checkColor)
                .font(.system(size: 14))
            Text(L10n.tr("delete.undo.toast", count))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(textColor)
                .lineLimit(1)
            HStack(spacing: 4) {
                Text(L10n.tr("action.undo"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(actionColor)
                Text("⌘Z")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(actionColor.opacity(0.55))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(actionBackground, in: Capsule())
            .overlay(Capsule().stroke(actionStroke, lineWidth: 0.5))
            .contentShape(Capsule())
            .onTapGesture { coordinator.undo() }
            .padding(.leading, 2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(panelFill)
                .shadow(color: shadowColor, radius: 18, y: 6)
                .shadow(color: shadowColor.opacity(0.5), radius: 4, y: 1)
        )
        .overlay(
            Capsule()
                .stroke(panelStroke, lineWidth: 0.5)
        )
        .fixedSize()
    }
}

/// 把 ⌘Z 的全局监听 wrap 成一个 SwiftUI 视图，方便靠 `isActive` 的切换自动
/// 装卸。用 `NSEvent.addLocalMonitorForEvents` 拦截窗口级的 keyDown 事件，比
/// `keyboardShortcut` 更可靠（不受 first-responder 影响），代价是要手动管理生命周期。
private struct UndoShortcutInstaller: NSViewRepresentable {
    let isActive: Bool
    let action: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.refresh(isActive: isActive, action: action)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.refresh(isActive: isActive, action: action)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var monitor: Any?
        private var action: (() -> Void)?

        func refresh(isActive: Bool, action: @escaping () -> Void) {
            self.action = action
            if isActive {
                if monitor == nil {
                    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                        guard let self, let fire = self.action else { return event }
                        let isCmdZ = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
                            && event.charactersIgnoringModifiers?.lowercased() == "z"
                        guard isCmdZ else { return event }
                        fire()
                        return nil
                    }
                }
            } else {
                teardown()
            }
        }

        func teardown() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { teardown() }
    }
}
