//
//  HotKeyRecorderButton.swift
//  Mos
//  热键录制控件: 点一下进入录制, 按下组合即保存, Delete 清空, Esc 取消.
//

import Cocoa

final class HotKeyRecorderButton: NSButton {

    /// 录制结果: nil 表示清空
    var onCapture: ((HotKeyCombo?) -> Void)?

    private var isRecording = false
    private var displayText = ""

    override var acceptsFirstResponder: Bool { true }

    /// 展示当前热键
    func setDisplay(_ combo: HotKeyCombo?) {
        displayText = combo?.displayString ?? NSLocalizedString("Not Set", comment: "")
        guard !isRecording else { return }
        title = displayText
    }

    override func mouseDown(with event: NSEvent) {
        beginRecording()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 53: // Esc: 取消
            endRecording()
        case 51, 117: // Delete / Forward Delete: 清空
            endRecording()
            onCapture?(nil)
        default:
            guard !KeyCode.modifierKeys.contains(event.keyCode) else { return }
            let combo = HotKeyCombo(
                keyCode: UInt32(event.keyCode),
                modifiers: HotKeyCombo.carbonModifiers(from: event.modifierFlags)
            )
            guard combo.isValid else {
                NSSound.beep()
                return
            }
            endRecording()
            onCapture?(combo)
        }
    }

    override func resignFirstResponder() -> Bool {
        if isRecording { endRecording() }
        return super.resignFirstResponder()
    }

    private func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        title = NSLocalizedString("Press keys…", comment: "")
        window?.makeFirstResponder(self)
    }

    private func endRecording() {
        isRecording = false
        title = displayText
    }
}
