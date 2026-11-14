//
//  AXWindowReader.swift
//  Mos
//
//  Ported from Tungsten Edge (https://github.com/moonbai-studio/tungsten-edge)
//  Original: Platform/Accessibility/AXWindowReader.swift
//  Copyright (c) Tungsten Edge contributors.
//  License: GNU General Public License v3.0 (GPL-3.0) — same as Mos.
//
//  裁剪说明 (Mos): 只保留"选前台窗口 / 读 frame / 写 frame 并回读校验"的最小路径.
//  选窗顺序: AXFocusedWindow -> AXWindows 中的主窗口 -> AXWindows 第一个可用窗口.
//  所有拒绝原因都会写进诊断日志, 不再静默跳过.
//

import ApplicationServices
import CoreGraphics
import Foundation

/// 前台窗口的 AX 读写。所有调用都是跨进程同步调用，调用方需自行保证不在热路径上。
enum AXWindowReader {
    /// AX 消息超时：对方应用卡死时不拖住调用方。
    /// Electron / 系统设置等应用首次响应较慢, 1s 比 0.1s 更稳。
    static let messagingTimeout: Float = 1.0
    /// 回读校验容差
    static let verificationTolerance: CGFloat = 2

    /// 选中窗口的诊断信息
    struct Selection {
        let window: AXUIElement
        let source: String
        let role: String
        let subrole: String?
        let title: String?
        let frame: CGRect

        var description: String {
            "source=\(source) role=\(role) subrole=\(subrole ?? "-") "
                + "title=\"\(title ?? "")\" frame=\(NSStringFromRect(frame))"
        }
    }

    /// 整帧写入结果
    struct WriteResult {
        let requested: CGRect
        let actual: CGRect?
        let sizeSettable: Bool
        let positionSettable: Bool
        let sizeError: AXError?
        let positionError: AXError?
        let matched: Bool
        let failureReason: String?

        var diagnostic: String {
            "sizeSettable=\(sizeSettable) posSettable=\(positionSettable) "
                + "sizeError=\(AXWindowReader.describe(sizeError)) "
                + "posError=\(AXWindowReader.describe(positionError)) "
                + "requested=\(NSStringFromRect(requested)) "
                + "actual=\(actual.map(NSStringFromRect) ?? "nil") "
                + "matched=\(matched)"
                + (failureReason.map { " reason=\($0)" } ?? "")
        }
    }

    /// 只写尺寸(高度)的结果, 动画每帧使用。
    struct SizeWriteResult {
        let requested: CGSize
        let actual: CGRect?
        let settable: Bool
        let error: AXError?
        let matched: Bool
        let failureReason: String?

        var diagnostic: String {
            "settable=\(settable) error=\(AXWindowReader.describe(error)) "
                + "requested=\(Int(requested.width))x\(Int(requested.height)) "
                + "actual=\(actual.map { "\(Int($0.width))x\(Int($0.height))@\(Int($0.minX)),\(Int($0.minY))" } ?? "nil") "
                + "matched=\(matched)"
                + (failureReason.map { " reason=\($0)" } ?? "")
        }
    }

    // MARK: - 选窗

    /// 选择目标窗口。返回选中的窗口与所有被拒绝候选的原因。
    static func selectWindow(forPID pid: pid_t) -> (selection: Selection?, rejections: [String]) {
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app, messagingTimeout)
        var rejections: [String] = []

        // 1. 前台窗口
        if let focused = elementAttribute(app, kAXFocusedWindowAttribute as CFString) {
            if let selection = evaluate(focused, source: "AXFocusedWindow", rejections: &rejections) {
                return (selection, rejections)
            }
        } else {
            rejections.append("AXFocusedWindow=nil")
        }

        // 2. 窗口列表: 主窗口优先, 其余按 AX 顺序
        guard let windows = attribute(app, kAXWindowsAttribute as CFString) as? [AXUIElement] else {
            rejections.append("AXWindows=nil")
            return (nil, rejections)
        }
        if windows.isEmpty {
            rejections.append("AXWindows=empty")
        }
        let mains = windows.filter { boolAttribute($0, kAXMainAttribute as CFString) == true }
        let others = windows.filter { boolAttribute($0, kAXMainAttribute as CFString) != true }
        for (index, window) in mains.enumerated() {
            if let selection = evaluate(window, source: "AXWindows.main[\(index)]", rejections: &rejections) {
                return (selection, rejections)
            }
        }
        for (index, window) in others.enumerated() {
            if let selection = evaluate(window, source: "AXWindows[\(index)]", rejections: &rejections) {
                return (selection, rejections)
            }
        }
        return (nil, rejections)
    }

    /// 对话框 / 浮层不参与铺满
    private static let blockedSubroles: Set<String> = [
        "AXDialog", "AXSystemDialog", "AXSheet",
        "AXFloatingWindow", "AXSystemFloatingWindow"
    ]

    private static func evaluate(
        _ window: AXUIElement,
        source: String,
        rejections: inout [String]
    ) -> Selection? {
        _ = AXUIElementSetMessagingTimeout(window, messagingTimeout)

        let role = stringAttribute(window, kAXRoleAttribute as CFString) ?? "?"
        guard role == "AXWindow" else {
            rejections.append("\(source): role=\(role) 不是 AXWindow")
            return nil
        }
        let subrole = stringAttribute(window, kAXSubroleAttribute as CFString)
        if let subrole, blockedSubroles.contains(subrole) {
            rejections.append("\(source): subrole=\(subrole) 属于对话框/浮层")
            return nil
        }
        if boolAttribute(window, kAXMinimizedAttribute as CFString) == true {
            rejections.append("\(source): 已最小化")
            return nil
        }
        if boolAttribute(window, "AXFullScreen" as CFString) == true {
            rejections.append("\(source): 处于系统全屏")
            return nil
        }
        guard let frame = frame(of: window) else {
            rejections.append("\(source): frame 读取失败")
            return nil
        }
        guard frame.width >= 100, frame.height >= 100 else {
            rejections.append("\(source): 尺寸过小 \(Int(frame.width))x\(Int(frame.height))")
            return nil
        }
        if isDesktopFrame(frame) {
            rejections.append("\(source): 桌面窗口")
            return nil
        }
        guard touchesDisplay(frame) else {
            rejections.append("\(source): 不在任何屏幕内 \(NSStringFromRect(frame))")
            return nil
        }

        let sizeSettable = isSettable(window, kAXSizeAttribute as CFString)
        let positionSettable = isSettable(window, kAXPositionAttribute as CFString)
        guard sizeSettable || positionSettable else {
            rejections.append("\(source): size/position 都不可写(不可缩放窗口)")
            return nil
        }

        return Selection(
            window: window,
            source: source,
            role: role,
            subrole: subrole,
            title: stringAttribute(window, kAXTitleAttribute as CFString),
            frame: frame
        )
    }

    /// 桌面窗口的 frame 恰好等于某块屏幕的完整 frame。
    private static func isDesktopFrame(_ frame: CGRect) -> Bool {
        displayBounds().contains(frame)
    }

    /// 窗口是否与任意活跃屏幕有足够交集
    private static func touchesDisplay(_ frame: CGRect) -> Bool {
        let bounds = displayBounds()
        guard !bounds.isEmpty else { return true }
        for display in bounds {
            let intersection = display.intersection(frame)
            if !intersection.isNull, intersection.width >= 50, intersection.height >= 50 {
                return true
            }
        }
        return false
    }

    private static func displayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return []
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else {
            return []
        }
        return displays[0..<Int(count)].map { CGDisplayBounds($0) }
    }

    // MARK: - 坐标

    /// 读取窗口 frame（AX 全局坐标，左上原点）。
    static func frame(of window: AXUIElement) -> CGRect? {
        guard let positionValue = valueAttribute(window, kAXPositionAttribute as CFString),
              let sizeValue = valueAttribute(window, kAXSizeAttribute as CFString) else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    /// 整帧写入: **先位置后尺寸**，随后回读校验。
    ///
    /// 顺序是关键: 窗口从屏幕中间放大到整屏时，如果先写尺寸，系统会按
    /// 当前左边/顶边到屏幕右/下边的剩余距离夹住新尺寸（实测 1290x795@161,243
    /// 请求 2016x1008 只得到 1855x891，看起来就是"没铺满"）。
    /// 先把左上角挪到目标位置再放大，窗口就有完整的空间可以长。
    @discardableResult
    static func setFrame(_ target: CGRect, on window: AXUIElement) -> WriteResult {
        let original = frame(of: window)
        let sizeSettable = isSettable(window, kAXSizeAttribute as CFString)
        let positionSettable = isSettable(window, kAXPositionAttribute as CFString)
        var sizeError: AXError?
        var positionError: AXError?

        let needsSize = original.map {
            abs($0.width - target.width) > verificationTolerance
                || abs($0.height - target.height) > verificationTolerance
        } ?? true
        let needsPosition = original.map {
            abs($0.minX - target.minX) > verificationTolerance
                || abs($0.minY - target.minY) > verificationTolerance
        } ?? true

        if needsPosition, positionSettable {
            var position = target.origin
            if let value = AXValueCreate(.cgPoint, &position) {
                positionError = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
            }
        }
        if needsSize, sizeSettable {
            var size = target.size
            if let value = AXValueCreate(.cgSize, &size) {
                sizeError = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
            }
        }

        let actual = frame(of: window)
        let matched = actual.map { framesMatch($0, target, tolerance: verificationTolerance) } ?? false
        let reason = matched ? nil : failureReason(
            requested: target,
            actual: actual,
            sizeSettable: sizeSettable,
            positionSettable: positionSettable
        )
        let result = WriteResult(
            requested: target,
            actual: actual,
            sizeSettable: sizeSettable,
            positionSettable: positionSettable,
            sizeError: sizeError,
            positionError: positionError,
            matched: matched,
            failureReason: reason
        )
        FillDiagnostics.log("setFrame \(result.diagnostic)")
        return result
    }

    /// 只写尺寸, 保持顶边/左边不动。动画每帧使用。
    @discardableResult
    static func setSize(_ size: CGSize, on window: AXUIElement) -> SizeWriteResult {
        let settable = isSettable(window, kAXSizeAttribute as CFString)
        var error: AXError?
        if settable {
            var value = size
            if let axValue = AXValueCreate(.cgSize, &value) {
                error = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, axValue)
            }
        }
        let actual = frame(of: window)
        let matched = actual.map {
            abs($0.width - size.width) <= verificationTolerance
                && abs($0.height - size.height) <= verificationTolerance
        } ?? false
        let reason: String?
        if matched {
            reason = nil
        } else if let actual {
            if actual.height < size.height - verificationTolerance {
                reason = "高度被夹在 \(Int(actual.height))pt (目标 \(Int(size.height))pt): "
                    + "Dock 仍占位或窗口有最大尺寸约束"
            } else {
                reason = "尺寸与目标不符 \(NSStringFromRect(actual))"
            }
        } else {
            reason = "frame 读取失败"
        }
        let result = SizeWriteResult(
            requested: size,
            actual: actual,
            settable: settable,
            error: error,
            matched: matched,
            failureReason: reason
        )
        if !matched {
            FillDiagnostics.log("setSize \(result.diagnostic)")
        }
        return result
    }

    // MARK: - 基础读取

    private static func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else {
            return nil
        }
        return value
    }

    private static func elementAttribute(_ element: AXUIElement, _ name: CFString) -> AXUIElement? {
        guard let value = attribute(element, name),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private static func valueAttribute(_ element: AXUIElement, _ name: CFString) -> AXValue? {
        guard let value = attribute(element, name),
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        return (value as! AXValue)
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: CFString) -> String? {
        attribute(element, name) as? String
    }

    private static func boolAttribute(_ element: AXUIElement, _ name: CFString) -> Bool? {
        attribute(element, name) as? Bool
    }

    private static func isSettable(_ element: AXUIElement, _ name: CFString) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, name, &settable) == .success else {
            return false
        }
        return settable.boolValue
    }

    private static func framesMatch(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    /// 写入失败的具体原因, 避免"静默不改"
    private static func failureReason(
        requested: CGRect,
        actual: CGRect?,
        sizeSettable: Bool,
        positionSettable: Bool
    ) -> String {
        guard let actual else {
            return "frame 读取失败, 窗口可能已关闭"
        }
        if !sizeSettable, abs(actual.height - requested.height) > verificationTolerance {
            return "size 属性不可写(窗口不可缩放)"
        }
        if !positionSettable,
           abs(actual.minX - requested.minX) > verificationTolerance
            || abs(actual.minY - requested.minY) > verificationTolerance {
            return "position 属性不可写"
        }
        if actual.height < requested.height - verificationTolerance {
            return "高度被夹在 \(Int(actual.height))pt (目标 \(Int(requested.height))pt): "
                + "Dock 仍占位或窗口有最大高度约束"
        }
        if actual.height > requested.height + verificationTolerance {
            return "高度大于目标 \(Int(actual.height))pt (目标 \(Int(requested.height))pt)"
        }
        if abs(actual.width - requested.width) > verificationTolerance {
            return "宽度被夹在 \(Int(actual.width))pt (目标 \(Int(requested.width))pt): 窗口有最小/最大宽度约束"
        }
        if abs(actual.minY - requested.minY) > verificationTolerance {
            return "顶边停在 \(Int(actual.minY))pt (目标 \(Int(requested.minY))pt): 窗口最小高度约束"
        }
        if abs(actual.minX - requested.minX) > verificationTolerance {
            return "左边停在 \(Int(actual.minX))pt (目标 \(Int(requested.minX))pt)"
        }
        return "回读 frame 与目标不一致"
    }

    /// AXError 名称, 便于日志定位
    static func describe(_ error: AXError?) -> String {
        guard let error else { return "none" }
        switch error {
        case .success: return "success(0)"
        case .failure: return "failure(-25200)"
        case .illegalArgument: return "illegalArgument(-25201)"
        case .invalidUIElement: return "invalidUIElement(-25202)"
        case .invalidUIElementObserver: return "invalidUIElementObserver(-25203)"
        case .cannotComplete: return "cannotComplete(-25204)"
        case .attributeUnsupported: return "attributeUnsupported(-25205)"
        case .actionUnsupported: return "actionUnsupported(-25206)"
        case .notificationUnsupported: return "notificationUnsupported(-25207)"
        case .notImplemented: return "notImplemented(-25208)"
        case .apiDisabled: return "apiDisabled(-25211)"
        case .noValue: return "noValue(-25212)"
        case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported(-25213)"
        case .notEnoughPrecision: return "notEnoughPrecision(-25214)"
        @unknown default: return "unknown(\(error.rawValue))"
        }
    }
}
