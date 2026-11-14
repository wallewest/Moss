//
//  PreferencesDockViewController.swift
//  Mos
//  程序坞选项界面
//

import Cocoa
import ApplicationServices

class PreferencesDockViewController: NSViewController {

    // UI Elements
    private let sectionLabel = NSTextField(labelWithString: "")
    private let fillScreenCheckBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let descriptionLabel = NSTextField(wrappingLabelWithString: "")
    private let hotKeyLabel = NSTextField(labelWithString: "")
    private let hotKeyButton = HotKeyRecorderButton(title: "", target: nil, action: nil)
    private let runOnceButton = NSButton(title: "", target: nil, action: nil)
    private let hotKeyStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let permissionLabel = NSTextField(wrappingLabelWithString: "")
    private let openAccessibilityButton = NSButton(title: "", target: nil, action: nil)

    override func loadView() {
        view = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 450, height: 285))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupView()
        // 从系统设置授权完切回来时刷新提示
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        // 读取设置
        syncViewWithOptions()
    }

    @objc private func applicationDidBecomeActive() {
        syncViewWithOptions()
    }

    // 窗口铺满下屏
    @IBAction func fillScreenBelowClick(_ sender: NSButton) {
        let enabled = sender.state == .on
        Options.shared.dock.fillScreenBelow = enabled
        FillScreenBelowController.shared.setEnabledBySetting(enabled)
        syncViewWithOptions()
    }

    // 立即执行一次
    @IBAction func runOnceClick(_ sender: NSButton) {
        FillScreenBelowController.shared.trigger()
    }

    // 打开辅助功能设置
    @IBAction func openAccessibilityClick(_ sender: NSButton) {
        FillScreenBelowController.openAccessibilitySettings()
    }
}

/**
 * 界面构建
 **/
extension PreferencesDockViewController {

    private func setupView() {
        let visualEffectView = view as? NSVisualEffectView
        visualEffectView?.blendingMode = NSVisualEffectView.BlendingMode.behindWindow
        if #available(OSX 10.14, *) {
            visualEffectView?.material = NSVisualEffectView.Material.toolTip
        }

        // 分组标题
        sectionLabel.stringValue = NSLocalizedString("Dock", comment: "")
        sectionLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        sectionLabel.textColor = NSColor.secondaryLabelColor
        sectionLabel.alignment = .right
        sectionLabel.translatesAutoresizingMaskIntoConstraints = false

        // 开关
        fillScreenCheckBox.title = NSLocalizedString("Fill Screen Below", comment: "")
        fillScreenCheckBox.target = self
        fillScreenCheckBox.action = #selector(fillScreenBelowClick(_:))
        fillScreenCheckBox.translatesAutoresizingMaskIntoConstraints = false

        // 功能说明
        descriptionLabel.stringValue = NSLocalizedString(
            "Press the hotkey (or the button below) to fill the frontmost window to the bottom of the screen: the Dock flashes briefly, and if the window is resized again it snaps back — just trigger it again.",
            comment: ""
        )
        descriptionLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        descriptionLabel.textColor = NSColor.secondaryLabelColor
        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false

        // 热键
        hotKeyLabel.stringValue = NSLocalizedString("Hotkey", comment: "")
        hotKeyLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        hotKeyLabel.textColor = NSColor.secondaryLabelColor
        hotKeyLabel.alignment = .right
        hotKeyLabel.translatesAutoresizingMaskIntoConstraints = false

        hotKeyButton.bezelStyle = .rounded
        hotKeyButton.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        hotKeyButton.translatesAutoresizingMaskIntoConstraints = false
        hotKeyButton.onCapture = { [weak self] combo in
            self?.saveHotKey(combo)
        }

        // 立即执行一次
        runOnceButton.title = NSLocalizedString("Fill Now", comment: "")
        runOnceButton.bezelStyle = .rounded
        runOnceButton.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        runOnceButton.target = self
        runOnceButton.action = #selector(runOnceClick(_:))
        runOnceButton.translatesAutoresizingMaskIntoConstraints = false

        // 热键注册失败提示
        hotKeyStatusLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        hotKeyStatusLabel.textColor = NSColor.systemRed
        hotKeyStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        hotKeyStatusLabel.isHidden = true

        // 辅助功能未授权提示 + 直达入口
        permissionLabel.stringValue = NSLocalizedString(
            "Moss needs Accessibility permission to move windows.",
            comment: ""
        )
        permissionLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        permissionLabel.textColor = NSColor.systemOrange
        permissionLabel.translatesAutoresizingMaskIntoConstraints = false
        permissionLabel.isHidden = true

        openAccessibilityButton.title = NSLocalizedString("Open Accessibility Settings", comment: "")
        openAccessibilityButton.bezelStyle = .rounded
        openAccessibilityButton.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        openAccessibilityButton.target = self
        openAccessibilityButton.action = #selector(openAccessibilityClick(_:))
        openAccessibilityButton.translatesAutoresizingMaskIntoConstraints = false
        openAccessibilityButton.isHidden = true

        view.addSubview(sectionLabel)
        view.addSubview(fillScreenCheckBox)
        view.addSubview(descriptionLabel)
        view.addSubview(hotKeyLabel)
        view.addSubview(hotKeyButton)
        view.addSubview(runOnceButton)
        view.addSubview(hotKeyStatusLabel)
        view.addSubview(permissionLabel)
        view.addSubview(openAccessibilityButton)

        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 450),

            sectionLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            sectionLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            sectionLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 136),

            fillScreenCheckBox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 171),
            fillScreenCheckBox.centerYAnchor.constraint(equalTo: sectionLabel.centerYAnchor),
            fillScreenCheckBox.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -18),

            descriptionLabel.leadingAnchor.constraint(equalTo: fillScreenCheckBox.leadingAnchor),
            descriptionLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            descriptionLabel.topAnchor.constraint(equalTo: fillScreenCheckBox.bottomAnchor, constant: 8),

            hotKeyLabel.trailingAnchor.constraint(equalTo: fillScreenCheckBox.leadingAnchor, constant: -9),
            hotKeyLabel.centerYAnchor.constraint(equalTo: hotKeyButton.centerYAnchor),

            hotKeyButton.leadingAnchor.constraint(equalTo: fillScreenCheckBox.leadingAnchor),
            hotKeyButton.topAnchor.constraint(equalTo: descriptionLabel.bottomAnchor, constant: 14),
            hotKeyButton.widthAnchor.constraint(equalToConstant: 110),

            runOnceButton.leadingAnchor.constraint(equalTo: hotKeyButton.trailingAnchor, constant: 8),
            runOnceButton.centerYAnchor.constraint(equalTo: hotKeyButton.centerYAnchor),
            runOnceButton.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -18),

            hotKeyStatusLabel.leadingAnchor.constraint(equalTo: fillScreenCheckBox.leadingAnchor),
            hotKeyStatusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            hotKeyStatusLabel.topAnchor.constraint(equalTo: hotKeyButton.bottomAnchor, constant: 8),

            permissionLabel.leadingAnchor.constraint(equalTo: fillScreenCheckBox.leadingAnchor),
            permissionLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            permissionLabel.topAnchor.constraint(equalTo: hotKeyStatusLabel.bottomAnchor, constant: 10),

            openAccessibilityButton.leadingAnchor.constraint(equalTo: fillScreenCheckBox.leadingAnchor),
            openAccessibilityButton.topAnchor.constraint(equalTo: permissionLabel.bottomAnchor, constant: 8),
            openAccessibilityButton.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -18),
            openAccessibilityButton.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -18)
        ])
    }
}

/**
 * 设置同步
 **/
extension PreferencesDockViewController {
    // 同步界面与设置
    func syncViewWithOptions() {
        let enabled = Options.shared.dock.fillScreenBelow
        fillScreenCheckBox.state = NSControl.StateValue(rawValue: enabled ? 1 : 0)
        runOnceButton.isEnabled = enabled
        hotKeyButton.setDisplay(FillScreenBelowController.configuredCombo())

        let failed = enabled && FillScreenBelowController.shared.hotKeyRegistrationFailed
        hotKeyStatusLabel.isHidden = !failed
        hotKeyStatusLabel.stringValue = failed
            ? NSLocalizedString("Hotkey is already used by another app and could not be registered.", comment: "")
            : ""

        // 辅助功能未授权时显著提示 + 给出直达入口
        let trusted = AXIsProcessTrusted()
        permissionLabel.isHidden = trusted
        openAccessibilityButton.isHidden = trusted
    }

    // 保存录制结果并重新注册
    private func saveHotKey(_ combo: HotKeyCombo?) {
        if let combo {
            Options.shared.dock.fillScreenHotKeyCode = Int(combo.keyCode)
            Options.shared.dock.fillScreenHotKeyModifiers = UInt(combo.modifiers)
        } else {
            Options.shared.dock.fillScreenHotKeyCode = -1
            Options.shared.dock.fillScreenHotKeyModifiers = 0
        }
        Options.shared.dock.fillScreenHotKeyCustomized = true
        FillScreenBelowController.shared.setEnabledBySetting(Options.shared.dock.fillScreenBelow)
        syncViewWithOptions()
    }
}
