//
//  GlobalHotKey.swift
//  Mos
//
//  基于 Carbon RegisterEventHotKey 的全局热键，不依赖辅助功能权限。
//  只支持「修饰键 + 单个按键」的组合。
//

import AppKit
import Carbon.HIToolbox

struct HotKeyCombo: Equatable {
    /// 虚拟键码（与 NSEvent.keyCode 一致）
    let keyCode: UInt32
    /// Carbon 修饰符（controlKey / optionKey / shiftKey / cmdKey）
    let modifiers: UInt32

    /// 默认组合: ⌃⌥⌘M
    static let `default` = HotKeyCombo(keyCode: 46, modifiers: UInt32(controlKey | optionKey | cmdKey))

    /// 必须带 ⌃ / ⌥ / ⌘ 之一，避免把普通按键注册成全局热键。
    var isValid: Bool {
        modifiers & UInt32(controlKey | optionKey | cmdKey) != 0
    }

    /// 仅显示的字母，例如 "⌃⌥⌘M"。
    var displayString: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        text += KeyCode.keyMap[UInt16(keyCode)] ?? "Key\(keyCode)"
        return text
    }

    /// NSEvent 修饰符 -> Carbon 修饰符
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        return carbon
    }
}

final class GlobalHotKey {
    static let shared = GlobalHotKey()

    /// 热键按下（主线程回调）。
    var onPress: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var registeredCombo: HotKeyCombo?

    private init() {}

    /// 注册失败返回 false（例如已被别的应用占用）。
    @discardableResult
    func register(_ combo: HotKeyCombo) -> Bool {
        guard combo.isValid else { return false }
        if registeredCombo == combo, hotKeyRef != nil { return true }
        unregister()

        installHandlerIfNeeded()

        var hotKeyID = EventHotKeyID(signature: OSType(0x4D4F5346), id: 1) // 'MOSF'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            NSLog("MosDockDiag: hotkey register failed status=\(status) combo=\(combo.displayString)")
            return false
        }
        _ = hotKeyID // 保留语义: 处理器只关心唯一的 id
        hotKeyRef = ref
        registeredCombo = combo
        NSLog("MosDockDiag: hotkey registered \(combo.displayString)")
        return true
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
            registeredCombo = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return OSStatus(eventNotHandledErr) }
                DispatchQueue.main.async {
                    GlobalHotKey.shared.onPress?()
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &handlerRef
        )
    }
}
