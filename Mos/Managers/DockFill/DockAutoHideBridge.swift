//
//  DockAutoHideBridge.swift
//  Mos
//
//  「窗口铺满下屏」的临时 Dock 让位桥。
//
//  时序（用户实机验证过的 Hammerspoon 方案）：
//    1. 快照 com.apple.dock 的 autohide 原值，落盘 pending 标记；
//    2. 写 autohide=true + killall Dock；
//    3. 等 Dock 重排（约 1 秒）后由调用方把窗口铺到屏幕底；
//    4. 写回原 autohide + killall Dock，Dock 立即恢复常驻。
//
//  只碰 autohide 一个键：autohide-delay / tilesize 不读不写。
//  实测: 叠加 autohide-delay>0 会改变 Dock 让位行为, 铺满失效, 因此不能残留该键.
//
//  还原可靠性：
//    - 动 Dock 之前先写 pending 标记，进程被强杀时下次启动会补还原；
//    - 每次 killall 之后按 Dock 的 PID 变化确认真实重启，失败最多重试 3 次；
//    - 只有确认 Dock 重启后才清除 pending；否则保留标记，下次启动再补一次；
//    - 还原请求在途时不会重复 killall（避免频繁重启 Dock 触发系统节流）。
//

import AppKit
import Foundation

final class DockAutoHideBridge {
    static let shared = DockAutoHideBridge()

    /// 一次「临时隐藏 Dock」请求的耗时明细（毫秒），用于阶段耗时报告
    struct HideRequest {
        let changed: Bool
        let snapshotMs: Int
        let writeMs: Int
        let pidLookupMs: Int
        let killallMs: Int
        let totalMs: Int

        var diagnostic: String {
            "写autohide=\(writeMs)ms 快照=\(snapshotMs)ms PID查询=\(pidLookupMs)ms "
                + "killall发起=\(killallMs)ms 合计=\(totalMs)ms 值变化=\(changed)"
        }
    }

    private static let dockDomain = "com.apple.dock" as CFString
    private static let dockBundleID = "com.apple.dock"
    /// 轮询 Dock 新 PID 的间隔
    private static let pollInterval: TimeInterval = 0.025
    /// 单次 killall 后等待 Dock 重启的上限
    private static let restartConfirmTimeout: TimeInterval = 1.5
    /// killall 重试次数上限
    private static let maxRestartAttempts = 3

    private enum StoreKey {
        static let pending = "dockFillDockPendingRestore"
        static let autohideExists = "dockFillDockOriginalAutohideExists"
        static let autohideValue = "dockFillDockOriginalAutohide"
    }

    private let defaults = UserDefaults.standard
    private let lock = NSRecursiveLock()
    /// 每次写 Dock 递增, 用于丢弃过期的重启确认回调
    private var generation = 0
    private var restoreInFlight = false
    /// 已发起 killall、还没确认 Dock 回来
    private(set) var restartInFlight = false
    /// 最近一次请求重启 / 确认重启完成的时间, 供调用方判断"该不该催"
    private(set) var lastRestartRequestedAt: Date?
    private(set) var lastRestartConfirmedAt: Date?
    /// 最近一次还原请求开始 / 完成的时间
    private(set) var lastRestoreStartedAt: Date?
    private(set) var lastRestoreCompletedAt: Date?
    /// 异步 killall 的子进程, 持有引用直到退出
    private var children: [Process] = []

    private init() {}

    // MARK: - 对外

    /// 是否有未完成的还原（进程被强杀 / Dock 未确认重启）
    var hasPendingRestore: Bool {
        lock.lock()
        defer { lock.unlock() }
        return defaults.bool(forKey: StoreKey.pending)
    }

    /// 临时把 Dock 设为自动隐藏。
    /// 返回本次的耗时明细；changed 表示 autohide 值是否真的变化（Dock 重启始终会发起）。
    @discardableResult
    func beginTemporaryHide() -> HideRequest {
        lock.lock()
        defer { lock.unlock() }

        let beganAt = Date()
        var snapshotMs = 0
        var writeMs = 0

        // 没有 pending 时才是新一轮会话, 先记录用户原值
        if !defaults.bool(forKey: StoreKey.pending) {
            let snapshotStartedAt = Date()
            snapshotOriginals()
            snapshotMs = milliseconds(since: snapshotStartedAt)
        }
        // 先落标记再改系统，保证中途被杀也能在下次启动补还原。
        defaults.set(true, forKey: StoreKey.pending)
        restoreInFlight = false

        let readStartedAt = Date()
        let current = readDockValue("autohide") as? Bool
        let readMs = milliseconds(since: readStartedAt)
        let changed = current != true
        if changed {
            let writeStartedAt = Date()
            writeDockBool(true, forKey: "autohide")
            writeMs = milliseconds(since: writeStartedAt)
        }

        generation += 1
        let gen = generation
        let pidStartedAt = Date()
        let previous = dockPID()
        let pidLookupMs = milliseconds(since: pidStartedAt)

        let killallStartedAt = Date()
        // Dock 只有在重启后才会重新读取 autohide 并重排可用区, killall 是硬前提
        restartDock(restore: false, reason: "临时隐藏", generation: gen, attempt: 1, previousPID: previous)
        let killallMs = milliseconds(since: killallStartedAt)

        FillDiagnostics.log(
            "Dock autohide=true 已写入(值变化=\(changed)), 请求重启 Dock, 原值 exists=\(defaults.bool(forKey: StoreKey.autohideExists)) "
                + "value=\(defaults.bool(forKey: StoreKey.autohideValue))"
                + " 读值=\(readMs)ms"
        )
        return HideRequest(
            changed: changed,
            snapshotMs: snapshotMs,
            writeMs: writeMs,
            pidLookupMs: pidLookupMs,
            killallMs: killallMs,
            totalMs: milliseconds(since: beganAt)
        )
    }

    /// 把 Dock 还原成用户原来的状态（常驻 / 自动隐藏），并重启 Dock。
    func endTemporaryHide() {
        restoreIfNeeded()
    }

    /// 启动 / 退出 / 失败中止时调用：上次没来得及还原（崩溃、强杀、看门狗）就在这里补上。
    func restoreIfNeeded() {
        lock.lock()
        defer { lock.unlock() }

        guard defaults.bool(forKey: StoreKey.pending) else { return }
        guard !restoreInFlight else {
            FillDiagnostics.log("Dock 还原已在进行, 跳过重复请求")
            return
        }
        restoreInFlight = true
        lastRestoreStartedAt = Date()
        lastRestoreCompletedAt = nil

        let exists = defaults.bool(forKey: StoreKey.autohideExists)
        let value = defaults.bool(forKey: StoreKey.autohideValue)
        writeOriginalAutohide(exists: exists, value: value)

        generation += 1
        let gen = generation
        FillDiagnostics.log("Dock autohide 写回原值 exists=\(exists) value=\(value), 请求重启 Dock")
        restartDock(restore: true, reason: "还原", generation: gen, attempt: 1, previousPID: dockPID())
    }

    /// 看门狗 / 异常中止：与 restoreIfNeeded 同义，额外记录强制原因。
    func forceRestore(reason: String) {
        FillDiagnostics.log("强制还原 Dock: \(reason)")
        restoreIfNeeded()
    }

    /// Dock 可用区长时间没有变化时，重新请求一次重启（不改变 autohide 值）。
    func nudgeDock(reason: String) {
        lock.lock()
        defer { lock.unlock() }

        generation += 1
        let gen = generation
        FillDiagnostics.log("重新请求 Dock 重启: \(reason)")
        restartDock(restore: false, reason: "重试(\(reason))", generation: gen, attempt: 1, previousPID: dockPID())
    }

    // MARK: - 重启与确认

    private func restartDock(
        restore: Bool,
        reason: String,
        generation gen: Int,
        attempt: Int,
        previousPID: pid_t?
    ) {
        guard gen == generation else { return }
        let before = previousPID ?? dockPID()
        let startedAt = Date()
        lastRestartRequestedAt = startedAt
        restartInFlight = true
        spawn("/usr/bin/killall", ["Dock"], label: "killall Dock(\(reason) attempt=\(attempt))")
        pollDockRestart(
            restore: restore,
            reason: reason,
            generation: gen,
            attempt: attempt,
            previousPID: before,
            startedAt: startedAt,
            deadline: startedAt.addingTimeInterval(Self.restartConfirmTimeout)
        )
    }

    private func pollDockRestart(
        restore: Bool,
        reason: String,
        generation gen: Int,
        attempt: Int,
        previousPID: pid_t?,
        startedAt: Date,
        deadline: Date
    ) {
        guard gen == generation else { return }

        if let current = dockPID(), current != previousPID {
            restartInFlight = false
            lastRestartConfirmedAt = Date()
            FillDiagnostics.log(
                "Dock 已重启 reason=\(reason) attempt=\(attempt) pid=\(previousPID.map(String.init) ?? "nil")->\(current) "
                    + "耗时=\(Int(Date().timeIntervalSince(startedAt) * 1000))ms"
            )
            if restore {
                finishRestore()
            }
            return
        }

        guard Date() < deadline else {
            if attempt < Self.maxRestartAttempts {
                FillDiagnostics.log("失败分支=Dock未确认重启 reason=\(reason) attempt=\(attempt), 重试 killall")
                restartDock(
                    restore: restore,
                    reason: reason,
                    generation: gen,
                    attempt: attempt + 1,
                    previousPID: previousPID
                )
            } else {
                restartInFlight = false
                FillDiagnostics.log("失败分支=Dock未确认重启 reason=\(reason) 已重试\(attempt)次, 保留 pending 供下次补还原")
                if restore {
                    lock.lock()
                    restoreInFlight = false
                    lock.unlock()
                }
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pollInterval) { [weak self] in
            self?.pollDockRestart(
                restore: restore,
                reason: reason,
                generation: gen,
                attempt: attempt,
                previousPID: previousPID,
                startedAt: startedAt,
                deadline: deadline
            )
        }
    }

    private func finishRestore() {
        lock.lock()
        defer { lock.unlock() }
        restoreInFlight = false
        guard defaults.bool(forKey: StoreKey.pending) else { return }

        // 进程重启不代表 autohide 已生效: 回读确认, 不一致就保留 pending 让下次补还原
        let exists = defaults.bool(forKey: StoreKey.autohideExists)
        let value = defaults.bool(forKey: StoreKey.autohideValue)
        let current = readDockValue("autohide") as? Bool
        let matched = exists ? (current == value) : (current == nil)
        guard matched else {
            FillDiagnostics.log(
                "失败分支=Dock还原值未生效 current=\(current.map(String.init) ?? "nil") "
                    + "expected=\(exists ? String(value) : "nil"), 保留 pending"
            )
            return
        }

        clearSnapshot()
        lastRestoreCompletedAt = Date()
        let elapsed = lastRestoreStartedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
        FillDiagnostics.log("Dock 还原完成(值已回读 + 进程已重启), 清除 pending 标记 耗时=\(elapsed)ms")
    }

    // MARK: - 快照

    private func snapshotOriginals() {
        if let autohide = readDockValue("autohide") as? Bool {
            defaults.set(true, forKey: StoreKey.autohideExists)
            defaults.set(autohide, forKey: StoreKey.autohideValue)
        } else {
            defaults.set(false, forKey: StoreKey.autohideExists)
            defaults.removeObject(forKey: StoreKey.autohideValue)
        }
    }

    private func clearSnapshot() {
        defaults.removeObject(forKey: StoreKey.pending)
        defaults.removeObject(forKey: StoreKey.autohideExists)
        defaults.removeObject(forKey: StoreKey.autohideValue)
    }

    /// 写回原值；当前值已经一致时不重复写。
    private func writeOriginalAutohide(exists: Bool, value: Bool) {
        let current = readDockValue("autohide") as? Bool
        if exists {
            if current != value {
                writeDockBool(value, forKey: "autohide")
            }
        } else if current != nil {
            deleteDockKey("autohide")
        }
    }

    // MARK: - 系统读写

    /// 外部修改（系统设置 / killall Dock）不会自动进入本进程缓存，读之前先同步。
    private func readDockValue(_ key: String) -> Any? {
        CFPreferencesAppSynchronize(Self.dockDomain)
        return CFPreferencesCopyAppValue(key as CFString, Self.dockDomain)
    }

    /// 进程内直接写 com.apple.dock。
    /// 实测 `defaults write` 子进程约 200ms，CFPreferences 写 + 同步在个位数毫秒内完成。
    private func writeDockBool(_ value: Bool, forKey key: String) {
        CFPreferencesSetAppValue(
            key as CFString,
            value ? kCFBooleanTrue : kCFBooleanFalse,
            Self.dockDomain
        )
        guard !CFPreferencesAppSynchronize(Self.dockDomain) else { return }
        FillDiagnostics.log("CFPreferences 写 Dock 失败, 退回 defaults 命令")
        run("/usr/bin/defaults", ["write", "com.apple.dock", key, "-bool", value ? "true" : "false"])
    }

    /// 当前 Dock 进程 PID；Dock 未运行时返回 nil。
    /// NSRunningApplication 查询约 1ms，比每次拉起 pgrep 子进程快一个数量级。
    private func dockPID() -> pid_t? {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.dockBundleID)
            .first?
            .processIdentifier
    }

    private func deleteDockKey(_ key: String) {
        run("/usr/bin/defaults", ["delete", "com.apple.dock", key])
    }

    private func milliseconds(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }

    /// 异步拉起子进程：killall 的结果由"PID 是否变化"判定，不需要阻塞等它退出。
    private func spawn(_ executable: String, _ arguments: [String], label: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            DispatchQueue.main.async {
                self?.children.removeAll { $0 === finished }
                if status != 0 {
                    FillDiagnostics.log("\(label) exit=\(status)")
                }
            }
        }
        do {
            children.append(process)
            try process.run()
        } catch {
            FillDiagnostics.log("\(label) 执行失败: \(error.localizedDescription)")
        }
    }

    private func run(_ executable: String, _ arguments: [String], label: String) {
        let startedAt = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                FillDiagnostics.log(
                    "\(label) exit=\(process.terminationStatus) 耗时=\(milliseconds(since: startedAt))ms"
                )
            }
        } catch {
            FillDiagnostics.log("\(label) 执行失败: \(error.localizedDescription)")
        }
    }

    private func run(_ executable: String, _ arguments: [String]) {
        run(executable, arguments, label: "\(executable) \(arguments.joined(separator: " "))")
    }
}
