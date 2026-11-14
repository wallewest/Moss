//
//  FillScreenBelowController.swift
//  Mos
//
//  「窗口铺满下屏」执行器（热键切换）。
//
//  时序：
//    1. 快照 Dock 的 autohide 原值，写 autohide=true + killall Dock；
//    2. 轮询目标屏的 visibleFrame，按「可用区是否真的在变化」判断 Dock 是否让位，
//       长时间无变化会重新请求 Dock 重启（不按固定次数草率放弃）；
//    3. 把窗口顶边/宽度对齐目标，再以约 30fps、0.35 秒的插值把底边推到屏幕底；
//       恢复时用同一套动画把底边收回原 frame；
//    4. 动画结束后写回原 autohide + killall Dock，并按 PID 确认 Dock 真的重启。
//
//  可靠性：
//    - 每次触发启动 3 秒看门狗，超时无论处于哪个阶段都强制还原 Dock 并回滚窗口；
//    - 所有失败路径都会还原 Dock、回滚窗口（用户主动拖动除外），并弹出 Toast 提示；
//    - 失败日志统一以「失败分支=」开头，可直接区分选窗失败 / Dock 未让位 / 写入被夹等。
//
//  切换语义：第一次按记录窗口原 frame 并铺满，再按一次恢复；
//  若窗口已关闭或前台换了应用/窗口，则视为新的一次铺满，不会恢复错窗口。
//
//  触发入口：偏好设置里的热键 / 「立即执行一次」按钮，两者都只在开关打开时生效。
//

import AppKit
import ApplicationServices

final class FillScreenBelowController {
    static let shared = FillScreenBelowController()

    /// 动画时长（实测单次 AX 写入远小于一帧预算，缩短时长是体感提升最直接的一段）
    private static let animationDuration: TimeInterval = 0.24
    /// 单帧间隔 (60fps; 单次 AX 尺寸写入实测 avg 0.78ms / max 3.54ms, 余量充足)
    private static let animationFrameInterval: TimeInterval = 1.0 / 60.0
    /// Dock 让位轮询间隔（25ms 才能第一时间发现可用区变大）
    private static let readinessPollInterval: TimeInterval = 0.025
    /// Dock 让位最长等待（必须小于看门狗 3s）
    private static let readinessTimeout: TimeInterval = 2.8
    /// 实测 Dock 重启后要 ~1050ms 才会自己收起, 只有明显超出才催一次重启
    private static let dockYieldObservationWindow: TimeInterval = 2.0
    /// 重新请求 Dock 重启的次数上限
    private static let maxDockNudges = 2
    /// 看门狗：Dock 最多被隐藏多久
    private static let watchdogTimeout: TimeInterval = 3.0
    /// 收尾写入的重试次数（部分应用异步应用尺寸）
    private static let finalVerifyAttempts = 3
    private static let finalVerifyInterval: TimeInterval = 0.12
    /// 判定窗口被用户移动/缩放的容差
    private static let dragTolerance: CGFloat = 3
    /// 这些进程没有可铺满的普通窗口
    private static let blockedBundleIDs: Set<String> = [
        "com.apple.dock",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.WindowManager"
    ]

    /// 失败分支：日志与用户提示都从这里出
    private enum FailureReason {
        case accessibilityNotTrusted
        case noTargetApplication
        case blockedApplication(String)
        case noUsableWindow(String)
        case windowClosed
        case noScreen
        case dockNotYielded(String)
        case windowNotWritable(String)
        case windowAlignment(String)
        case sizeClamped(String)
        case userMovedWindow
        case watchdogTimeout

        /// 日志中直接可检索的失败分支
        var diagnostic: String {
            switch self {
            case .accessibilityNotTrusted: return "辅助功能未授权"
            case .noTargetApplication: return "没有目标应用"
            case .blockedApplication(let detail): return "目标不是普通应用 \(detail)"
            case .noUsableWindow(let detail): return "没有可铺满的窗口 \(detail)"
            case .windowClosed: return "窗口已关闭"
            case .noScreen: return "窗口不在任何屏幕内"
            case .dockNotYielded(let detail): return "Dock未让出空间 \(detail)"
            case .windowNotWritable(let detail): return "窗口不可写 \(detail)"
            case .windowAlignment(let detail): return "顶边/宽度无法对齐 \(detail)"
            case .sizeClamped(let detail): return "窗口尺寸被限制 \(detail)"
            case .userMovedWindow: return "动画期间窗口被用户移动"
            case .watchdogTimeout: return "看门狗超时"
            }
        }

        /// Toast 里的简短技术细节
        var technical: String {
            switch self {
            case .accessibilityNotTrusted: return "accessibility permission missing"
            case .noTargetApplication: return "no frontmost app"
            case .blockedApplication: return "system UI app"
            case .noUsableWindow: return "no writable window"
            case .windowClosed: return "window closed"
            case .noScreen: return "window off-screen"
            case .dockNotYielded(let detail): return "Dock did not yield \(detail)"
            case .windowNotWritable(let detail): return "window not resizable \(detail)"
            case .windowAlignment(let detail): return "cannot align \(detail)"
            case .sizeClamped(let detail): return "size clamped \(detail)"
            case .userMovedWindow: return "window moved during animation"
            case .watchdogTimeout: return "timeout watchdog fired"
            }
        }

        /// 失败后是否把窗口写回原 frame
        var shouldRollback: Bool {
            switch self {
            case .accessibilityNotTrusted, .noTargetApplication, .blockedApplication,
                 .noUsableWindow, .windowClosed, .noScreen, .userMovedWindow:
                return false
            case .dockNotYielded, .windowNotWritable, .windowAlignment,
                 .sizeClamped, .watchdogTimeout:
                return true
            }
        }
    }

    /// 一次铺满的会话：用于判断"第二次按是不是同一个窗口"
    private struct FillSession {
        let pid: pid_t
        let bundleID: String?
        let window: AXUIElement
        let originalFrame: CGRect
    }

    /// 一次动画的参数
    private struct AnimationJob {
        let window: AXUIElement
        let target: CGRect
        let startBottom: CGFloat
        let endBottom: CGFloat
        let startedAt: Date
        let token: Int
        let label: String
        let completion: (FailureReason?) -> Void
    }

    /// 热键注册失败（被占用 / 系统拒绝），供偏好界面提示
    private(set) var hotKeyRegistrationFailed = false

    private var enabled = false
    private var running = false
    private var started = false
    private var observeOptionsInstalled = false
    private var workspaceObserver: NSObjectProtocol?
    /// Mos 自己是 LSUIElement，点「立即执行一次」时前台会变成 Mos，这里记住上一个真实应用
    private var lastActiveAppPID: pid_t?
    /// 当前会话（nil 表示下一次触发是铺满而不是恢复）
    private var session: FillSession?
    /// 动画/轮询的代次，用于中止过期回调
    private var animationToken = 0
    /// 看门狗的代次
    private var watchdogToken = 0
    /// 本次操作开始时间（阶段耗时日志）
    private var operationStartedAt: Date?
    /// 操作进行中用户关掉了开关：等操作结束再恢复窗口
    private var pendingRestoreAfterRun = false

    // MARK: - 阶段耗时（毫秒，一次触发从按下到画面稳定）

    private var triggerStartedAt = Date()
    private var selectWindowMs = 0
    private var dockTouched = false
    private var dockWriteMs = 0
    private var dockHideRequestMs = 0
    private var dockRestartReadyMs = -1
    private var dockYieldMs = 0
    private var animationStartedAt: Date?
    private var firstFrameWriteMs = 0
    private var animationFrameCount = 0
    private var animationFrameWriteTotalMs = 0.0
    private var animationFrameWriteMaxMs = 0.0
    private var animationDurationMs = 0
    private var lastFrameWriteMs = 0
    /// 只有铺满流程才输出阶段耗时报告（恢复流程不重复刷）
    private var phaseReportEnabled = false

    private init() {}

    // MARK: - 生命周期

    func start() {
        guard !started else { return }
        started = true

        // 上次被强杀时残留的临时 Dock 状态先补还原
        if DockAutoHideBridge.shared.hasPendingRestore {
            FillDiagnostics.log("启动时发现未完成的 Dock 还原, 补执行")
        }
        DockAutoHideBridge.shared.restoreIfNeeded()

        if !observeOptionsInstalled {
            observeOptionsInstalled = true
            Options.shared.observe([.dock]) { [weak self] _ in
                self?.applySetting()
            }
        }
        installWorkspaceObserver()
        rememberActiveApp(NSWorkspace.shared.frontmostApplication)
        applySetting()
        FillDiagnostics.markSessionStart()
        FillDiagnostics.log(
            "start enabled=\(enabled) trusted=\(AXIsProcessTrusted()) "
                + "combo=\(Self.composedDisplayString()) failed=\(hotKeyRegistrationFailed)"
        )
    }

    func stop() {
        started = false
        enabled = false
        GlobalHotKey.shared.unregister()
        hotKeyRegistrationFailed = false
        animationToken += 1
        watchdogToken += 1
        running = false
        restoreSessionImmediately(reason: "退出")
        DockAutoHideBridge.shared.restoreIfNeeded()
    }

    /// 开关入口：打开时注册热键，关闭时注销并恢复窗口。
    func setEnabledBySetting(_ enabled: Bool) {
        self.enabled = enabled
        guard enabled else {
            GlobalHotKey.shared.unregister()
            hotKeyRegistrationFailed = false
            FillDiagnostics.log("功能关闭: 热键已注销")
            if running {
                pendingRestoreAfterRun = true
                FillDiagnostics.log("功能关闭时操作仍在进行, 结束后恢复窗口")
            } else {
                restoreSessionImmediately(reason: "功能关闭")
            }
            return
        }
        guard let combo = Self.configuredCombo() else {
            GlobalHotKey.shared.unregister()
            hotKeyRegistrationFailed = false
            FillDiagnostics.log("未配置热键, 只保留按钮路径")
            return
        }
        GlobalHotKey.shared.onPress = { [weak self] in
            self?.trigger()
        }
        hotKeyRegistrationFailed = !GlobalHotKey.shared.register(combo)
        if hotKeyRegistrationFailed {
            FillDiagnostics.log("热键注册失败(可能被占用) \(combo.displayString)")
        }
    }

    /// 立即执行一次（按钮 / 热键）
    func trigger() {
        guard enabled else {
            FillDiagnostics.log("trigger 忽略: 功能未开启")
            return
        }
        guard !running else {
            FillDiagnostics.log("trigger 忽略: 上一次操作仍在进行")
            return
        }
        guard AXIsProcessTrusted() else {
            // 权限不足时直接把用户带到「隐私与安全性 → 辅助功能」，并给出可见提示
            Self.openAccessibilitySettings()
            reportFailure(.accessibilityNotTrusted)
            return
        }

        let triggerAt = Date()
        triggerStartedAt = triggerAt
        resetPhaseTimings()

        guard let app = targetApplication() else {
            reportFailure(.noTargetApplication)
            return
        }

        let bundleID = app.bundleIdentifier ?? "-"
        FillDiagnostics.log(
            "trigger 应用=\(app.localizedName ?? "-") bundle=\(bundleID) pid=\(app.processIdentifier) "
                + "active=\(app.isActive) frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-")"
        )
        if let bundleID = app.bundleIdentifier, Self.blockedBundleIDs.contains(bundleID) {
            reportFailure(.blockedApplication(bundleID))
            return
        }

        let (selection, rejections) = AXWindowReader.selectWindow(forPID: app.processIdentifier)
        selectWindowMs = milliseconds(since: triggerAt)
        if !rejections.isEmpty {
            FillDiagnostics.log("选窗被拒: " + rejections.joined(separator: " | "))
        }
        guard let selection else {
            if let session, AXWindowReader.frame(of: session.window) == nil {
                self.session = nil
                FillDiagnostics.log("原窗口已关闭, 清空会话")
            }
            let detail = rejections.prefix(2).joined(separator: "; ")
            reportFailure(.noUsableWindow(detail))
            return
        }
        FillDiagnostics.log("选中窗口 \(selection.description)")

        guard let screen = Self.screen(forQuartz: selection.frame) else {
            reportFailure(.noScreen)
            return
        }

        if let session,
           session.pid == app.processIdentifier,
           CFEqual(session.window, selection.window) {
            FillDiagnostics.log("切换=恢复 original=\(NSStringFromRect(session.originalFrame))")
            beginOperation(on: screen) { [weak self] in
                self?.performRestore(session: session)
            }
        } else {
            if let old = session {
                FillDiagnostics.log(
                    "放弃上次会话 bundle=\(old.bundleID ?? "-") original=\(NSStringFromRect(old.originalFrame))"
                )
            }
            let newSession = FillSession(
                pid: app.processIdentifier,
                bundleID: app.bundleIdentifier,
                window: selection.window,
                originalFrame: selection.frame
            )
            session = newSession
            FillDiagnostics.log("切换=铺满 original=\(NSStringFromRect(selection.frame))")
            beginOperation(on: screen) { [weak self] in
                self?.performFill(session: newSession)
            }
        }
    }

    // MARK: - 设置

    private func applySetting() {
        setEnabledBySetting(Options.shared.dock.fillScreenBelow)
    }

    /// 配置的热键：从未设置过用默认 ⌃⌥⌘M，清空后返回 nil（只保留按钮路径）。
    static func configuredCombo() -> HotKeyCombo? {
        let dock = Options.shared.dock
        guard dock.fillScreenHotKeyCustomized else { return .default }
        guard dock.fillScreenHotKeyCode >= 0 else { return nil }
        return HotKeyCombo(
            keyCode: UInt32(dock.fillScreenHotKeyCode),
            modifiers: UInt32(dock.fillScreenHotKeyModifiers)
        )
    }

    static func composedDisplayString() -> String {
        configuredCombo()?.displayString ?? "-"
    }

    /// 打开「系统设置 → 隐私与安全性 → 辅助功能」
    static func openAccessibilitySettings() {
        let string = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 操作流程

    /// 临时隐藏 Dock -> 等待让位（按可用区变化判断）-> 执行体
    private func beginOperation(on screen: NSScreen, _ body: @escaping () -> Void) {
        running = true
        animationToken += 1
        let token = animationToken
        let beganAt = Date()
        operationStartedAt = triggerStartedAt
        startWatchdog(token: token)

        let baseline = Self.refreshedScreen(matching: screen.frame)?.visibleFrame ?? screen.visibleFrame

        // Dock 本来就不在底部占位（用户开着自动隐藏且此刻已收起）时完全不碰 Dock：
        // 省掉一次 killall 和 1 秒量级的重排等待，这一路径几乎是即时的。
        if Self.isDockSpaceAvailable(visibleFrame: baseline, screenFrame: screen.frame) {
            dockTouched = false
            dockYieldMs = milliseconds(since: beganAt)
            FillDiagnostics.log("Dock 已让出空间, 无需重启, visible=\(NSStringFromRect(baseline))")
            body()
            return
        }

        dockTouched = true
        let hide = DockAutoHideBridge.shared.beginTemporaryHide()
        dockWriteMs = hide.writeMs
        dockHideRequestMs = hide.totalMs
        FillDiagnostics.log(
            "Dock 阶段: \(hide.diagnostic) 初始可用区=\(NSStringFromRect(baseline)) "
                + "screen=\(NSStringFromRect(screen.frame))"
        )
        waitForDockSpace(
            screenFrame: screen.frame,
            baseline: baseline,
            nudges: 0,
            lastChangeAt: Date(),
            deadline: Date().addingTimeInterval(Self.readinessTimeout)
        ) { [weak self] yielded in
            guard let self, self.running, self.animationToken == token else { return }
            guard yielded else {
                let visible = Self.refreshedScreen(matching: screen.frame)?.visibleFrame ?? .zero
                self.abortOperation(
                    .dockNotYielded(
                        "visible=\(Int(visible.height))@\(Int(visible.minY)) "
                            + "screen=\(Int(screen.frame.height))"
                    )
                )
                return
            }
            self.dockYieldMs = self.milliseconds(since: beganAt)
            let bridge = DockAutoHideBridge.shared
            if let requested = bridge.lastRestartRequestedAt, let confirmed = bridge.lastRestartConfirmedAt {
                self.dockRestartReadyMs = Int(confirmed.timeIntervalSince(requested) * 1000)
            }
            FillDiagnostics.log(
                "Dock 让位耗时=\(self.dockYieldMs)ms (killall→Dock就绪=\(self.dockRestartReadyMs)ms), 开始动窗口"
            )
            body()
        }
    }

    /// 看门狗：3 秒内没结束就强制还原 Dock 并回滚，避免 Dock 停在隐藏状态
    private func startWatchdog(token: Int) {
        watchdogToken += 1
        let current = watchdogToken
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.watchdogTimeout) { [weak self] in
            guard let self, self.watchdogToken == current, self.running else { return }
            self.abortOperation(.watchdogTimeout)
        }
    }

    private func waitForDockSpace(
        screenFrame: CGRect,
        baseline: CGRect,
        nudges: Int,
        lastChangeAt: Date,
        deadline: Date,
        _ completion: @escaping (Bool) -> Void
    ) {
        guard let screen = Self.refreshedScreen(matching: screenFrame) else {
            completion(false)
            return
        }
        let visible = screen.visibleFrame
        if Self.isDockSpaceAvailable(on: screen) {
            FillDiagnostics.log("Dock 已让出空间 visible=\(NSStringFromRect(visible)) nudges=\(nudges)")
            completion(true)
            return
        }

        let now = Date()
        var nextLastChange = lastChangeAt
        if visible != baseline {
            nextLastChange = now
            FillDiagnostics.log(
                "Dock 可用区变化中 visible=\(NSStringFromRect(visible)) 目标=\(NSStringFromRect(screen.frame))"
            )
        }

        var nextNudges = nudges
        // 实测 Dock 重启后要 ~1050ms 才自己收起（系统空闲延时），太早重启只会打断它；
        // 所以只有明显超出这个窗口、且此刻没有重启在途时才再催一次。
        if !DockAutoHideBridge.shared.restartInFlight,
           nextNudges < Self.maxDockNudges,
           now < deadline,
           now.timeIntervalSince(nextLastChange) >= Self.dockYieldObservationWindow {
            nextNudges += 1
            FillDiagnostics.log(
                "Dock 可用区 \(Int(Self.dockYieldObservationWindow * 1000))ms 无变化, "
                    + "重新请求重启(\(nextNudges)/\(Self.maxDockNudges)) visible=\(NSStringFromRect(visible))"
            )
            DockAutoHideBridge.shared.nudgeDock(reason: "可用区无变化")
            nextLastChange = now
        }

        guard now < deadline else {
            completion(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.readinessPollInterval) { [weak self] in
            self?.waitForDockSpace(
                screenFrame: screenFrame,
                baseline: visible,
                nudges: nextNudges,
                lastChangeAt: nextLastChange,
                deadline: deadline,
                completion
            )
        }
    }

    private func performFill(session: FillSession) {
        phaseReportEnabled = true
        guard let current = AXWindowReader.frame(of: session.window) else {
            self.session = nil
            finish("铺满中止: 窗口已关闭", failure: .windowClosed, rollback: false)
            return
        }
        guard let screen = Self.screen(forQuartz: current) else {
            finish("铺满中止: 找不到目标屏幕", failure: .noScreen, rollback: false)
            return
        }

        // 菜单栏高度 = 屏顶到 visibleFrame 顶边的距离，与 Dock 是否让位无关
        let menuBarHeight = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        let targetAppKit = CGRect(
            x: screen.frame.minX,
            y: screen.frame.minY,
            width: screen.frame.width,
            height: screen.frame.height - menuBarHeight
        )
        let target = Self.quartzRect(fromAppKit: targetAppKit)
        FillDiagnostics.log(
            "铺满目标 \(NSStringFromRect(target)) menuBar=\(Int(menuBarHeight)) "
                + "current=\(NSStringFromRect(current))"
        )

        animate(window: session.window, to: target, label: "fill") { [weak self] failure in
            guard let self else { return }
            if let failure {
                FillDiagnostics.log("铺满失败: \(failure.diagnostic)")
                self.finish("铺满失败", failure: failure)
            } else {
                FillDiagnostics.log("铺满完成 \(NSStringFromRect(target))")
                self.finish("铺满完成")
            }
        }
    }

    private func performRestore(session: FillSession) {
        phaseReportEnabled = false
        guard AXWindowReader.frame(of: session.window) != nil else {
            self.session = nil
            finish("原窗口已关闭, 无需恢复", rollback: false)
            return
        }
        FillDiagnostics.log("开始恢复原 frame \(NSStringFromRect(session.originalFrame))")
        animate(window: session.window, to: session.originalFrame, label: "restore") { [weak self] failure in
            guard let self else { return }
            if let failure {
                // 保留会话, 用户可以再按一次重试恢复
                FillDiagnostics.log("恢复失败: \(failure.diagnostic) (保留会话)")
                self.finish("恢复失败", failure: failure, rollback: false)
            } else {
                FillDiagnostics.log("恢复完成")
                self.session = nil
                self.finish("恢复完成")
            }
        }
    }

    /// 正常结束：取消看门狗与动画、还原 Dock、处理延迟恢复。
    private func finish(_ reason: String, failure: FailureReason? = nil, rollback: Bool = true) {
        animationToken += 1
        watchdogToken += 1
        running = false
        let totalMs = operationStartedAt.map { milliseconds(since: $0) } ?? 0
        FillDiagnostics.log("finish: \(reason) 总耗时=\(totalMs)ms")
        // 一行可复制的阶段耗时报告（按下 -> 画面稳定），只在铺满流程输出
        if phaseReportEnabled {
            FillDiagnostics.log("阶段耗时 " + phaseSummary(totalMs: totalMs))
        }
        operationStartedAt = nil
        if let failure {
            if rollback, failure.shouldRollback {
                restoreSessionImmediately(reason: "失败回滚(\(failure.diagnostic))")
            }
            reportFailure(failure)
        }
        DockAutoHideBridge.shared.endTemporaryHide()
        if pendingRestoreAfterRun {
            pendingRestoreAfterRun = false
            restoreSessionImmediately(reason: "操作结束后补恢复(开关已关闭)")
        }
    }

    // MARK: - 阶段耗时

    private func resetPhaseTimings() {
        selectWindowMs = 0
        dockTouched = false
        dockWriteMs = 0
        dockHideRequestMs = 0
        dockRestartReadyMs = -1
        dockYieldMs = 0
        resetAnimationTimings()
    }

    private func resetAnimationTimings() {
        animationStartedAt = nil
        firstFrameWriteMs = 0
        animationFrameCount = 0
        animationFrameWriteTotalMs = 0
        animationFrameWriteMaxMs = 0
        animationDurationMs = 0
        lastFrameWriteMs = 0
    }

    /// 分段耗时报告：选窗 / 写 Dock / killall→Dock 就绪 / 让位等待 /
    /// 首帧写入 / 动画帧数与每帧 AX 写入 / 最后一帧 / 总耗时。
    private func phaseSummary(totalMs: Int) -> String {
        let averageFrameMs = animationFrameCount > 0
            ? animationFrameWriteTotalMs / Double(animationFrameCount)
            : 0
        var parts = ["选窗=\(selectWindowMs)ms"]
        if dockTouched {
            parts.append("写Dock=\(dockWriteMs)ms")
            parts.append("Dock请求=\(dockHideRequestMs)ms")
            parts.append("killall→Dock就绪=\(dockRestartReadyMs)ms")
            parts.append("让位等待=\(dockYieldMs)ms")
        } else {
            parts.append("Dock=已让位(未重启)")
        }
        parts.append("首帧写入=\(firstFrameWriteMs)ms")
        parts.append("动画=\(animationDurationMs)ms/\(animationFrameCount)帧")
        parts.append(String(format: "每帧AX avg=%.2fms max=%.2fms", averageFrameMs, animationFrameWriteMaxMs))
        parts.append("最后一帧=\(lastFrameWriteMs)ms")
        parts.append("总耗时=\(totalMs)ms")
        return parts.joined(separator: " ")
    }

    private func milliseconds(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }

    /// 异常中止（看门狗 / Dock 未让位）：强制还原 Dock，必要时回滚窗口。
    private func abortOperation(_ failure: FailureReason) {
        animationToken += 1
        watchdogToken += 1
        running = false
        FillDiagnostics.log("操作中止: \(failure.diagnostic)\(operationElapsedText())")
        operationStartedAt = nil
        if failure.shouldRollback {
            restoreSessionImmediately(reason: "失败回滚(\(failure.diagnostic))")
        }
        DockAutoHideBridge.shared.forceRestore(reason: failure.diagnostic)
        reportFailure(failure)
        if pendingRestoreAfterRun {
            pendingRestoreAfterRun = false
            restoreSessionImmediately(reason: "中止后补恢复(开关已关闭)")
        }
    }

    /// 直接写回原 frame（恢复是缩小高度，系统不会夹紧），用于关闭开关 / 退出 / 失败回滚。
    private func restoreSessionImmediately(reason: String) {
        guard let session else { return }
        let result = AXWindowReader.setFrame(session.originalFrame, on: session.window)
        FillDiagnostics.log("\(reason): 直接恢复原 frame matched=\(result.matched) \(result.diagnostic)")
        if result.matched {
            self.session = nil
        } else {
            FillDiagnostics.log("失败分支=回滚未生效, 保留会话待重试")
        }
    }

    /// 失败时给出可见反馈（Toast），不再静默失败
    private func reportFailure(_ failure: FailureReason) {
        FillDiagnostics.log("失败分支=\(failure.diagnostic)")
        let title = NSLocalizedString("Fill Screen Below failed", comment: "")
        Toast.show("\(title) — \(failure.technical)", style: .error, duration: 4)
    }

    private func operationElapsedText() -> String {
        guard let startedAt = operationStartedAt else { return "" }
        return " 总耗时=\(Int(Date().timeIntervalSince(startedAt) * 1000))ms"
    }

    // MARK: - 动画

    /// 顶边/宽度/左边立即对齐目标，只把高度与底边做插值。
    private func animate(
        window: AXUIElement,
        to target: CGRect,
        label: String,
        completion: @escaping (FailureReason?) -> Void
    ) {
        guard let current = AXWindowReader.frame(of: window) else {
            completion(.windowClosed)
            return
        }

        resetAnimationTimings()

        let anchor = CGRect(
            x: target.minX,
            y: target.minY,
            width: target.width,
            height: max(1, current.maxY - target.minY)
        )
        let anchorStartedAt = Date()
        let anchorResult = AXWindowReader.setFrame(anchor, on: window)
        firstFrameWriteMs = milliseconds(since: anchorStartedAt)
        guard let anchored = anchorResult.actual else {
            completion(.windowNotWritable(anchorResult.diagnostic))
            return
        }
        let drift = max(
            abs(anchored.minX - target.minX),
            abs(anchored.minY - target.minY),
            abs(anchored.width - target.width)
        )
        guard drift <= Self.dragTolerance else {
            completion(.windowAlignment("实际 \(NSStringFromRect(anchored))"))
            return
        }
        FillDiagnostics.log(
            "\(label) 动画起点=\(NSStringFromRect(anchored)) 终点=\(NSStringFromRect(target))"
        )

        let job = AnimationJob(
            window: window,
            target: target,
            startBottom: anchored.maxY,
            endBottom: target.maxY,
            startedAt: Date(),
            token: animationToken,
            label: label,
            completion: completion
        )
        animationStartedAt = job.startedAt
        guard abs(job.endBottom - job.startBottom) > 0.5 else {
            finalize(
                window: window,
                target: target,
                label: label,
                token: job.token,
                attemptsLeft: Self.finalVerifyAttempts,
                completion: completion
            )
            return
        }
        runAnimation(job)
    }

    private func runAnimation(_ job: AnimationJob) {
        guard job.token == animationToken, running else {
            // 已被新的操作或看门狗接管, 不再回调
            return
        }

        let elapsed = Date().timeIntervalSince(job.startedAt)
        let progress = min(1, CGFloat(elapsed / Self.animationDuration))
        let eased = Self.easeInOut(progress)
        let bottom = job.startBottom + (job.endBottom - job.startBottom) * eased
        let size = CGSize(width: job.target.width, height: max(1, bottom - job.target.minY))

        let frameStartedAt = Date()
        let result = AXWindowReader.setSize(size, on: job.window)
        let frameMs = Date().timeIntervalSince(frameStartedAt) * 1000
        animationFrameCount += 1
        animationFrameWriteTotalMs += frameMs
        animationFrameWriteMaxMs = max(animationFrameWriteMaxMs, frameMs)
        guard result.matched else {
            let failure: FailureReason = result.settable
                ? .sizeClamped(result.failureReason ?? result.diagnostic)
                : .windowNotWritable(result.diagnostic)
            job.completion(failure)
            return
        }
        if let actual = result.actual {
            let drift = max(
                abs(actual.minX - job.target.minX),
                abs(actual.minY - job.target.minY),
                abs(actual.width - job.target.width)
            )
            if drift > Self.dragTolerance {
                FillDiagnostics.log(
                    "\(job.label) 动画中窗口被用户移动/缩放, actual=\(NSStringFromRect(actual)), 中止"
                )
                job.completion(.userMovedWindow)
                return
            }
        }

        guard progress < 1 else {
            finalize(
                window: job.window,
                target: job.target,
                label: job.label,
                token: job.token,
                attemptsLeft: Self.finalVerifyAttempts,
                completion: job.completion
            )
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.animationFrameInterval) { [weak self] in
            self?.runAnimation(job)
        }
    }

    /// 收尾写入：部分应用异步应用尺寸，短时间内多试几次，只有确认写不进去才判失败。
    private func finalize(
        window: AXUIElement,
        target: CGRect,
        label: String,
        token: Int,
        attemptsLeft: Int,
        completion: @escaping (FailureReason?) -> Void
    ) {
        guard token == animationToken, running else { return }

        let finalStartedAt = Date()
        let result = AXWindowReader.setFrame(target, on: window)
        lastFrameWriteMs = milliseconds(since: finalStartedAt)
        if let startedAt = animationStartedAt {
            animationDurationMs = milliseconds(since: startedAt)
        }
        if result.matched {
            if attemptsLeft < Self.finalVerifyAttempts {
                FillDiagnostics.log(
                    "\(label) 收尾写入成功, 第\(Self.finalVerifyAttempts - attemptsLeft + 1)次尝试"
                )
            }
            completion(nil)
            return
        }

        if attemptsLeft > 1 {
            FillDiagnostics.log(
                "失败分支=最终写入未匹配 label=\(label) 剩余重试=\(attemptsLeft - 1) \(result.diagnostic)"
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.finalVerifyInterval) { [weak self] in
                self?.finalize(
                    window: window,
                    target: target,
                    label: label,
                    token: token,
                    attemptsLeft: attemptsLeft - 1,
                    completion: completion
                )
            }
            return
        }

        let failure: FailureReason = result.sizeSettable
            ? .sizeClamped(result.failureReason ?? result.diagnostic)
            : .windowNotWritable(result.diagnostic)
        completion(failure)
    }

    /// smoothstep，接近系统窗口动画的加减速
    private static func easeInOut(_ progress: CGFloat) -> CGFloat {
        let t = min(max(progress, 0), 1)
        return t * t * (3 - 2 * t)
    }

    // MARK: - 目标窗口

    /// 目标应用 = 用户点击 / 按热键之前最近一次活跃的非 Mos 应用。
    ///
    /// 只用 NSWorkspace 的激活历史：Mos 是 LSUIElement，点「立即执行一次」时
    /// 偏好窗口是 key window，frontmost 会变成 Mos 自己；如果为了拿目标应用
    /// 去激活/前置任何窗口，就会把用户的工作窗口拽到前台。
    /// 全流程不调用 activate / AXRaise / makeKeyAndOrderFront。
    private func targetApplication() -> NSRunningApplication? {
        if let pid = lastActiveAppPID,
           let app = NSRunningApplication(processIdentifier: pid),
           !app.isTerminated {
            return app
        }
        // 激活历史缺失（刚启动 / 之前的应用已退出）时才回退到前台应用；同样不做任何激活。
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != getpid(),
              !front.isTerminated else {
            return nil
        }
        return front
    }

    private func installWorkspaceObserver() {
        guard workspaceObserver == nil else { return }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.rememberActiveApp(
                notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            )
        }
    }

    private func rememberActiveApp(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != getpid(), !app.isTerminated else { return }
        lastActiveAppPID = app.processIdentifier
    }

    // MARK: - 坐标 / 屏幕

    private static var primaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    /// AX/Quartz(左上原点) -> AppKit(左下原点)
    private static func appKitRect(fromQuartz rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryScreenHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// AppKit(左下原点) -> AX/Quartz(左上原点)
    private static func quartzRect(fromAppKit rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryScreenHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private static func screen(forQuartz rect: CGRect) -> NSScreen? {
        screen(containing: appKitRect(fromQuartz: rect))
    }

    /// 窗口落在哪块屏（取交集面积最大的）
    private static func screen(containing rect: CGRect) -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for screen in screens {
            let intersection = screen.frame.intersection(rect)
            let area = intersection.isNull ? 0 : intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                best = screen
            }
        }
        return best ?? screens.first
    }

    /// Dock 重启后 NSScreen 实例可能变化，按 frame 重新匹配
    private static func refreshedScreen(matching frame: CGRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame == frame }
    }

    /// Dock 是否已经让出底部占位带（AppKit 坐标：visibleFrame 底边贴住屏幕底边）
    private static func isDockSpaceAvailable(on screen: NSScreen) -> Bool {
        isDockSpaceAvailable(visibleFrame: screen.visibleFrame, screenFrame: screen.frame)
    }

    /// 底部空间是否已经可用。Dock 在底部时 visibleFrame.minY 会被抬高；
    /// 已经自动隐藏（或 Dock 在左右两侧）时 minY 与屏幕底边重合。
    private static func isDockSpaceAvailable(visibleFrame: CGRect, screenFrame: CGRect) -> Bool {
        visibleFrame.minY - screenFrame.minY <= 2
    }
}
