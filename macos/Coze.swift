import Cocoa
import ApplicationServices
import UserNotifications

@main
struct CozeMain {
    private static let delegate = CozeAppDelegate()
    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

struct CozePreferences: Codable {
    var threshold: Int = 10000
    var lidHours: Int = 2
}

enum CozePreferencesStore {
    private static let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".coze/preferences.json")

    static func load() -> CozePreferences {
        guard let data = try? Data(contentsOf: file), let preferences = try? JSONDecoder().decode(CozePreferences.self, from: data) else { return CozePreferences() }
        return CozePreferences(threshold: max(1, preferences.threshold), lidHours: min(max(1, preferences.lidHours), 8))
    }

    static func save(_ preferences: CozePreferences) {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(preferences).write(to: file, options: .atomic)
        } catch { }
    }
}

final class CozeAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate {
    private var window: NSWindow!
    private var statusItem: NSStatusItem?
    private let content = NSView()
    private let status = NSTextField(labelWithString: "Ready when you are.")
    private let threshold = NSTextField(string: "10000")
    private let lidHours = NSTextField(string: "2")
    private let wechatAction = NSButton()
    private let claudeAction = NSButton()
    private let openCodeAction = NSButton()
    private let agentTest = NSButton()
    private let lidAction = NSButton()
    private let wechatState = NSTextField(labelWithString: "未开启")
    private let claudeState = NSTextField(labelWithString: "未开启")
    private let openCodeState = NSTextField(labelWithString: "未开启")
    private let lidState = NSTextField(labelWithString: "未开启")
    private var wechatIsOn = false
    private var lidIsOn = false
    private var claudeIsOn = false
    private var openCodeIsOn = false
    private var preferences = CozePreferencesStore.load()

    func applicationDidFinishLaunching(_ notification: Notification) {
        threshold.stringValue = String(preferences.threshold)
        lidHours.stringValue = String(preferences.lidHours)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 650), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Coze"
        window.center()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedRed: 0.055, green: 0.075, blue: 0.11, alpha: 1).cgColor
        window.contentView = content
        window.delegate = self
        buildInterface()
        installStatusItem()
        applyDefaults()
        Notifier.configure()
        AgentInbox.shared.onSignal = { [weak self] provider in self?.receivedCompletionSignal(from: provider) }
        AgentInbox.shared.start()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        runReopenSelfTestIfRequested()
        runNotificationSelfTestIfRequested()
        runStatusBarSelfTestIfRequested()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DispatchQueue.main.async { [weak self] in self?.showMainWindow() }
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // The red close control hides Coze but deliberately leaves its menu-bar
        // item alive, so it can always be reopened without recreating a window.
        sender.orderOut(nil)
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === threshold { threshold.stringValue = String(max(1, threshold.integerValue)) }
        if field === lidHours { lidHours.stringValue = String(min(max(1, lidHours.integerValue), 8)) }
        savePreferences()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = item.button else { return }
        button.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "显示 Coze")
        button.image?.isTemplate = true
        button.target = self
        button.action = #selector(showMainWindowFromStatusBar)
        button.toolTip = "显示 Coze"
        statusItem = item
    }

    @objc private func showMainWindowFromStatusBar() { showMainWindow() }

    private func showMainWindow() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }
    }

    private func receivedCompletionSignal(from provider: String) {
        update("已收到 \(provider) 的完成信号，正在播放提示音并发送横幅。")
        statusItem?.button?.image = NSImage(systemSymbolName: "bell.badge.fill", accessibilityDescription: "Coze 有新完成提醒")
        statusItem?.button?.image?.isTemplate = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.statusItem?.button?.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "显示 Coze")
            self?.statusItem?.button?.image?.isTemplate = true
        }
    }

    // QA-only launch argument used to exercise the exact deferred restore path
    // without requiring Accessibility permission to automate the Dock.
    private func runReopenSelfTestIfRequested() {
        guard CommandLine.arguments.contains("--reopen-self-test") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            self.window.miniaturize(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                _ = self.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
                self.update("窗口恢复自检已通过。")
            }
        }
    }

    private func runNotificationSelfTestIfRequested() {
        guard CommandLine.arguments.contains("--notification-self-test") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            Notifier.notify(title: "Coze QA", message: "这是一条 macOS 原生横幅通知测试。")
            self?.update("已触发 macOS 原生通知自检。")
        }
    }

    private func runStatusBarSelfTestIfRequested() {
        guard CommandLine.arguments.contains("--statusbar-self-test") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            self.window.performClose(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.statusItem?.button?.performClick(nil)
                self.update("菜单栏恢复自检已通过。")
            }
        }
    }

    private func buildInterface() {
        let brand = label("C O Z E", size: 27, weight: .bold, color: .white)
        let motto = label("安静地替你完成后台琐事", size: 13, weight: .regular, color: muted)
        let rule = NSView(); rule.wantsLayer = true; rule.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        [brand, motto, rule].forEach { content.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        let grid = NSStackView(); grid.orientation = .vertical; grid.alignment = .width; grid.distribution = .fill; grid.spacing = 14; grid.translatesAutoresizingMaskIntoConstraints = false
        let wechat = wechatCard(), agent = agentCard(), lid = lidCard()
        [wechat, agent, lid].forEach { card in grid.addArrangedSubview(card); card.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true }
        content.addSubview(grid)
        status.textColor = muted; status.font = .systemFont(ofSize: 12); status.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(status)
        NSLayoutConstraint.activate([
            brand.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 34), brand.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            motto.leadingAnchor.constraint(equalTo: brand.trailingAnchor, constant: 14), motto.centerYAnchor.constraint(equalTo: brand.centerYAnchor),
            rule.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 34), rule.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -34), rule.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 19), rule.heightAnchor.constraint(equalToConstant: 1),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 34), grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -34), grid.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 22),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 36), status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22)
        ])
    }

    private func wechatCard() -> NSView {
        let card = cardView(), number = label("01", size: 13, weight: .bold, color: accent), title = label("微信长文本转 DOCX", size: 18, weight: .semibold, color: .white), copy = label("在微信聊天框粘贴超长内容时，自动生成本地 DOCX 并放入当前聊天框。", size: 13, weight: .regular, color: muted), unit = label("字符", size: 12, weight: .regular, color: muted)
        prepareField(threshold, alignment: .right); prepareState(wechatState); prepareAction(wechatAction, title: "开启", action: #selector(wechatActionTapped))
        [number,title,copy,threshold,unit,wechatState,wechatAction].forEach { card.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([number.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 19), number.topAnchor.constraint(equalTo: card.topAnchor, constant: 18), title.leadingAnchor.constraint(equalTo: number.trailingAnchor, constant: 12), title.centerYAnchor.constraint(equalTo: number.centerYAnchor), copy.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 19), copy.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10), copy.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -19), threshold.trailingAnchor.constraint(equalTo: unit.leadingAnchor, constant: -7), threshold.centerYAnchor.constraint(equalTo: wechatState.centerYAnchor), threshold.widthAnchor.constraint(equalToConstant: 88), threshold.heightAnchor.constraint(equalToConstant: 28), unit.trailingAnchor.constraint(equalTo: wechatAction.leadingAnchor, constant: -14), unit.centerYAnchor.constraint(equalTo: wechatState.centerYAnchor), wechatState.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 19), wechatState.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18), wechatAction.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -19), wechatAction.centerYAnchor.constraint(equalTo: wechatState.centerYAnchor), wechatAction.widthAnchor.constraint(equalToConstant: 92), wechatAction.heightAnchor.constraint(equalToConstant: 30), card.heightAnchor.constraint(equalToConstant: 136)])
        return card
    }

    private func agentCard() -> NSView {
        let card = cardView(), number = label("02", size: 13, weight: .bold, color: accent), title = label("Claude Code 与 OpenCode 完成提醒", size: 18, weight: .semibold, color: .white), copy = label("两项可以同时开启；无论 Warp 中运行 Claude Code 或 OpenCode，任务完成都会提醒。", size: 13, weight: .regular, color: muted), claudeName = label("Claude Code", size: 13, weight: .medium, color: .white), openCodeName = label("OpenCode", size: 13, weight: .medium, color: .white)
        prepareState(claudeState); prepareState(openCodeState); prepareAction(claudeAction, title: "安装并开启", action: #selector(claudeActionTapped)); prepareAction(openCodeAction, title: "安装并开启", action: #selector(openCodeActionTapped)); prepareLink(agentTest, title: "测试通知", action: #selector(testSignal))
        [number,title,copy,claudeName,openCodeName,claudeState,openCodeState,agentTest,claudeAction,openCodeAction].forEach { card.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([number.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 19), number.topAnchor.constraint(equalTo: card.topAnchor, constant: 18), title.leadingAnchor.constraint(equalTo: number.trailingAnchor, constant: 12), title.centerYAnchor.constraint(equalTo: number.centerYAnchor), copy.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 19), copy.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10), copy.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -19), claudeName.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 19), claudeName.topAnchor.constraint(equalTo: copy.bottomAnchor, constant: 14), claudeState.leadingAnchor.constraint(equalTo: claudeName.trailingAnchor, constant: 14), claudeState.centerYAnchor.constraint(equalTo: claudeName.centerYAnchor), claudeAction.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -19), claudeAction.centerYAnchor.constraint(equalTo: claudeName.centerYAnchor), claudeAction.widthAnchor.constraint(equalToConstant: 108), claudeAction.heightAnchor.constraint(equalToConstant: 30), openCodeName.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 19), openCodeName.topAnchor.constraint(equalTo: claudeName.bottomAnchor, constant: 14), openCodeState.leadingAnchor.constraint(equalTo: openCodeName.trailingAnchor, constant: 14), openCodeState.centerYAnchor.constraint(equalTo: openCodeName.centerYAnchor), agentTest.trailingAnchor.constraint(equalTo: openCodeAction.leadingAnchor, constant: -16), agentTest.centerYAnchor.constraint(equalTo: openCodeName.centerYAnchor), openCodeAction.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -19), openCodeAction.centerYAnchor.constraint(equalTo: openCodeName.centerYAnchor), openCodeAction.widthAnchor.constraint(equalToConstant: 108), openCodeAction.heightAnchor.constraint(equalToConstant: 30), card.heightAnchor.constraint(equalToConstant: 178)])
        return card
    }

    private func lidCard() -> NSView {
        let card = cardView(), number = label("03", size: 13, weight: .bold, color: .systemOrange), title = label("合盖继续运行", size: 18, weight: .semibold, color: .white), copy = label("默认关闭。仅在有长任务时限时允许合盖继续运行；保持通风，绝不要放进密闭背包。", size: 13, weight: .regular, color: muted), hours = label("小时", size: 12, weight: .regular, color: muted)
        prepareField(lidHours, alignment: .center); prepareState(lidState); prepareAction(lidAction, title: "开启", action: #selector(lidActionTapped))
        [number,title,copy,lidHours,hours,lidState,lidAction].forEach { card.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([number.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 19), number.topAnchor.constraint(equalTo: card.topAnchor, constant: 18), title.leadingAnchor.constraint(equalTo: number.trailingAnchor, constant: 12), title.centerYAnchor.constraint(equalTo: number.centerYAnchor), copy.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 19), copy.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10), copy.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -19), lidState.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 19), lidState.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18), lidHours.leadingAnchor.constraint(equalTo: lidState.trailingAnchor, constant: 16), lidHours.centerYAnchor.constraint(equalTo: lidState.centerYAnchor), lidHours.widthAnchor.constraint(equalToConstant: 48), lidHours.heightAnchor.constraint(equalToConstant: 28), hours.leadingAnchor.constraint(equalTo: lidHours.trailingAnchor, constant: 7), hours.centerYAnchor.constraint(equalTo: lidState.centerYAnchor), lidAction.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -19), lidAction.centerYAnchor.constraint(equalTo: lidState.centerYAnchor), lidAction.widthAnchor.constraint(equalToConstant: 92), lidAction.heightAnchor.constraint(equalToConstant: 30), card.heightAnchor.constraint(equalToConstant: 144)])
        return card
    }

    @objc private func wechatActionTapped() {
        if wechatIsOn { ClipboardRelay.shared.stop(); wechatIsOn = false; setAction(wechatAction, "开启"); setState(wechatState, "未开启", active: false); update("微信长文本转换已关闭。"); return }
        let limit = max(1, threshold.integerValue); threshold.stringValue = String(limit); savePreferences(); ClipboardRelay.shared.limit = limit; ClipboardRelay.shared.onStatus = { [weak self] in self?.update($0) }
        if ClipboardRelay.shared.start() { wechatIsOn = true; setAction(wechatAction, "关闭"); setState(wechatState, "已开启", active: true); update("微信长文本转换已开启。") }
        else { setAction(wechatAction, "去授权"); setState(wechatState, "需要授权", active: false); NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!); update("请允许 Coze 使用辅助功能，然后回到此处再次点击。") }
    }
    @objc private func claudeActionTapped() { toggleAgent(name: "Claude Code", enabled: claudeIsOn, install: ClaudeCodeHook.install, remove: ClaudeCodeHook.remove) { enabled in self.claudeIsOn = enabled; self.setAction(self.claudeAction, enabled ? "关闭" : "安装并开启"); self.setState(self.claudeState, enabled ? "已开启" : "未开启", active: enabled) } }
    @objc private func openCodeActionTapped() { toggleAgent(name: "OpenCode", enabled: openCodeIsOn, install: OpenCodePlugin.install, remove: OpenCodePlugin.remove) { enabled in self.openCodeIsOn = enabled; self.setAction(self.openCodeAction, enabled ? "关闭" : "安装并开启"); self.setState(self.openCodeState, enabled ? "已开启" : "未开启", active: enabled) } }
    private func toggleAgent(name: String, enabled: Bool, install: () throws -> Void, remove: () throws -> Void, apply: (Bool) -> Void) {
        do {
            if enabled { try remove(); apply(false); update("\(name) 完成提醒已关闭。") }
            else { try install(); apply(true); Notifier.notify(title: "Coze", message: "\(name) 完成提醒已开启。"); update("\(name) 完成提醒已开启；可与另一项同时运行。") }
        } catch { update("\(name) 设置失败：\(error.localizedDescription)") }
    }
    @objc private func testSignal() {
        update("正在检查 macOS 通知权限…")
        Notifier.notify(title: "Coze", message: "这是一条测试通知。") { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .queued:
                    self.update("测试横幅已交给 macOS；若未出现，请检查勿扰模式和通知设置。")
                case .disabled:
                    self.update("Coze 的横幅通知已被系统关闭，正在打开通知设置。")
                    self.openNotificationSettings()
                case .failed(let message):
                    self.update("测试通知发送失败：\(message)")
                }
            }
        }
    }
    private func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else { return }
        NSWorkspace.shared.open(url)
    }
    @objc private func lidActionTapped() {
        if lidIsOn { LidRun.disable { [weak self] result in self?.lidIsOn = false; self?.setAction(self?.lidAction, "开启"); self?.setState(self?.lidState, "未开启", active: false); self?.update(result) }; return }
        let hours = min(max(1, lidHours.integerValue), 8); lidHours.stringValue = String(hours); savePreferences()
        let alert = NSAlert(); alert.messageText = "Keep running with the lid closed?"; alert.informativeText = "Coze will change macOS sleep settings for \(hours) hour(s), then attempt to restore them automatically. This consumes battery and can generate heat. Keep the Mac on a ventilated hard surface — never in a backpack or sealed case."; alert.alertStyle = .warning; alert.addButton(withTitle: "Allow for \(hours) hour(s)"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        update("正在请求管理员授权…")
        LidRun.enable(hours: hours) { [weak self] result in self?.lidIsOn = result.hasPrefix("Closed-lid run enabled"); self?.setAction(self?.lidAction, self?.lidIsOn == true ? "立即停止" : "开启"); self?.setState(self?.lidState, self?.lidIsOn == true ? "运行中" : "未开启", active: self?.lidIsOn == true); self?.update(result) }
    }
    private func applyDefaults() {
        let limit = max(1, threshold.integerValue); threshold.stringValue = String(limit); savePreferences(); ClipboardRelay.shared.limit = limit; ClipboardRelay.shared.onStatus = { [weak self] in self?.update($0) }
        if ClipboardRelay.shared.start() { wechatIsOn = true; setAction(wechatAction, "关闭"); setState(wechatState, "已开启", active: true) }
        else { setAction(wechatAction, "去授权"); setState(wechatState, "需要授权", active: false) }
        claudeIsOn = ClaudeCodeHook.isInstalled(); if claudeIsOn { try? ClaudeCodeHook.install() }; setAction(claudeAction, claudeIsOn ? "关闭" : "安装并开启"); setState(claudeState, claudeIsOn ? "已开启" : "未开启", active: claudeIsOn)
        openCodeIsOn = OpenCodePlugin.isInstalled(); if openCodeIsOn { try? OpenCodePlugin.install() }; setAction(openCodeAction, openCodeIsOn ? "关闭" : "安装并开启"); setState(openCodeState, openCodeIsOn ? "已开启" : "未开启", active: openCodeIsOn)
    }
    private func update(_ text: String) { DispatchQueue.main.async { self.status.stringValue = text } }
    private func cardView() -> NSView { let view = NSView(); view.wantsLayer = true; view.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.075).cgColor; view.layer?.cornerRadius = 14; view.layer?.borderWidth = 1; view.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor; return view }
    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField { let field = NSTextField(labelWithString: text); field.font = .systemFont(ofSize: size, weight: weight); field.textColor = color; field.lineBreakMode = .byWordWrapping; field.maximumNumberOfLines = 2; return field }
    private func button(_ title: String, action: Selector) -> NSButton { let button = NSButton(title: title, target: self, action: action); button.isBordered = false; button.wantsLayer = true; button.layer?.backgroundColor = NSColor(calibratedRed: 0.16, green: 0.26, blue: 0.39, alpha: 1).cgColor; button.layer?.cornerRadius = 8; button.contentTintColor = .white; button.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 13, weight: .semibold)]); return button }
    private func prepareAction(_ button: NSButton, title: String, action: Selector) { button.target = self; button.action = action; button.translatesAutoresizingMaskIntoConstraints = false; button.isBordered = false; button.wantsLayer = true; button.layer?.backgroundColor = accent.cgColor; button.layer?.cornerRadius = 8; setAction(button, title) }
    private func prepareLink(_ button: NSButton, title: String, action: Selector) { button.target = self; button.action = action; button.isBordered = false; button.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: accent, .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .underlineStyle: NSUnderlineStyle.single.rawValue]) }
    private func setAction(_ button: NSButton?, _ title: String) { guard let button else { return }; button.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 13, weight: .semibold)]) }
    private func prepareState(_ label: NSTextField) { label.font = .systemFont(ofSize: 12, weight: .semibold); label.translatesAutoresizingMaskIntoConstraints = false; setState(label, "未开启", active: false) }
    private func setState(_ label: NSTextField?, _ title: String, active: Bool) { guard let label else { return }; label.stringValue = "●  \(title)"; label.textColor = active ? NSColor(calibratedRed: 0.38, green: 0.86, blue: 0.65, alpha: 1) : muted }
    private func savePreferences() { preferences = CozePreferences(threshold: max(1, threshold.integerValue), lidHours: min(max(1, lidHours.integerValue), 8)); CozePreferencesStore.save(preferences) }
    private func prepareField(_ field: NSTextField, alignment: NSTextAlignment) { field.alignment = alignment; field.delegate = self; field.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium); field.wantsLayer = true; field.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.22).cgColor; field.layer?.cornerRadius = 7 }
    private var accent: NSColor { NSColor(calibratedRed: 0.35, green: 0.66, blue: 1.0, alpha: 1) }
    private var muted: NSColor { NSColor(calibratedRed: 0.72, green: 0.77, blue: 0.84, alpha: 1) }
}

final class ClipboardRelay {
    static let shared = ClipboardRelay(); var limit = 10000; var onStatus: ((String) -> Void)?
    private var tap: CFMachPort?; private var source: CFRunLoopSource?; private var busy = false
    func start() -> Bool {
        guard AXIsProcessTrusted() else { return false }; stop()
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, info in
            Unmanaged<ClipboardRelay>.fromOpaque(info!).takeUnretainedValue().handle(type, event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return false }; source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0); CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes); CGEvent.tapEnable(tap: tap, enable: true); return true
    }
    func stop() { if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }; tap = nil; source = nil; busy = false }
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .keyDown, !busy, event.getIntegerValueField(.keyboardEventKeycode) == 9, event.flags.contains(.maskCommand), isWeChat(), let text = NSPasteboard.general.string(forType: .string), text.count >= limit else { return Unmanaged.passUnretained(event) }
        busy = true; DispatchQueue.main.async { self.relay(text) }; return nil
    }
    private func relay(_ text: String) {
        do { let file = try Docx.write(text); NSPasteboard.general.clearContents(); guard NSPasteboard.general.writeObjects([file as NSURL]) else { throw RelayError.clipboard }; postPaste(); onStatus?("DOCX placed in WeChat: \(file.lastPathComponent)") }
        catch { onStatus?("Could not create DOCX: \(error.localizedDescription)") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { self.busy = false }
    }
    private func isWeChat() -> Bool { (NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.lowercased() ?? "").contains("wechat") || (NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.lowercased() ?? "").contains("xinwechat") }
    private func postPaste() { let s = CGEventSource(stateID: .combinedSessionState); let d = CGEvent(keyboardEventSource: s, virtualKey: 9, keyDown: true)!; d.flags = .maskCommand; d.post(tap: .cghidEventTap); let u = CGEvent(keyboardEventSource: s, virtualKey: 9, keyDown: false)!; u.flags = .maskCommand; u.post(tap: .cghidEventTap) }
    enum RelayError: LocalizedError { case clipboard; var errorDescription: String? { "Could not put the generated file on the clipboard." } }
}

enum Docx {
    static func write(_ body: String) throws -> URL {
        let fm = FileManager.default; let folder = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Coze Messages", isDirectory: true); try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-"); let output = folder.appendingPathComponent("WeChat-message-\(stamp).docx")
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? fm.removeItem(at: dir) }; try fm.createDirectory(at: dir.appendingPathComponent("_rels"), withIntermediateDirectories: true); try fm.createDirectory(at: dir.appendingPathComponent("word"), withIntermediateDirectories: true)
        let paragraphs = body.components(separatedBy: .newlines).map { $0.isEmpty ? "<w:p/>" : "<w:p><w:r><w:t xml:space=\"preserve\">\(xml($0))</w:t></w:r></w:p>" }.joined()
        let files = [("[Content_Types].xml","<?xml version=\"1.0\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>"),("_rels/.rels","<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>"),("word/document.xml","<?xml version=\"1.0\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body><w:p><w:r><w:rPr><w:b/></w:rPr><w:t>WeChat long message</w:t></w:r></w:p>\(paragraphs)<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\"/></w:sectPr></w:body></w:document>")]
        for (name, value) in files { let url = dir.appendingPathComponent(name); try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try value.data(using: .utf8)!.write(to: url) }
        try? fm.removeItem(at: output); let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); p.arguments = ["-q","-X","-r",output.path,"."]; p.currentDirectoryURL = dir; try p.run(); p.waitUntilExit(); guard p.terminationStatus == 0 else { throw NSError(domain: "Coze", code: 1) }; return output
    }
    private static func xml(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }
}

enum OpenCodePlugin {
    static func install() throws {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/opencode/plugin", isDirectory: true); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let code = """
        export const CozeNotification = async ({ $ }) => ({
          event: async ({ event }) => {
            if (event.type === \"session.idle\") {
              await $`/bin/sh -c 'mkdir -p "$HOME/.coze/inbox"; touch "$HOME/.coze/inbox/opencode-$(uuidgen).signal"'`
            }
          }
        })
        """
        try code.data(using: .utf8)!.write(to: folder.appendingPathComponent("coze-notification.js"))
    }
    static func remove() throws {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/opencode/plugin/coze-notification.js")
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
    static func isInstalled() -> Bool { FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/opencode/plugin/coze-notification.js").path) }
}

enum ClaudeCodeHook {
    static func install() throws {
        let fm = FileManager.default
        let coze = fm.homeDirectoryForCurrentUser.appendingPathComponent(".coze", isDirectory: true)
        try fm.createDirectory(at: coze, withIntermediateDirectories: true)
        let script = coze.appendingPathComponent("claude-complete-notify.sh")
        let contents = "#!/bin/zsh\nmkdir -p \"$HOME/.coze/inbox\"\nprintf '%s  Claude Code Stop hook fired\\n' \"$(date '+%Y-%m-%d %H:%M:%S')\" >> \"$HOME/.coze/events.log\"\n/usr/bin/afplay /System/Library/Sounds/Glass.aiff >/dev/null 2>&1 &\n/usr/bin/osascript -e 'display notification \"Claude Code 已完成本轮任务。\" with title \"Coze · Claude Code\" sound name \"Glass\"' >/dev/null 2>&1 &\ntouch \"$HOME/.coze/inbox/claude-$(uuidgen).signal\"\nexit 0\n"
        try contents.data(using: .utf8)!.write(to: script)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let settings = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        try fm.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        var root: [String: Any] = [:]
        if fm.fileExists(atPath: settings.path) {
            root = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any] ?? [:]
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var stops = hooks["Stop"] as? [[String: Any]] ?? []
        let command = "'\(script.path.replacingOccurrences(of: "'", with: "'\\\"'\\\"'"))'"
        let alreadyInstalled = stops.contains { group in
            let handlers = group["hooks"] as? [[String: Any]] ?? []
            return handlers.contains { ($0["type"] as? String) == "command" && ($0["command"] as? String) == command }
        }
        if !alreadyInstalled { stops.append(["hooks": [["type": "command", "command": command]]]) }
        hooks["Stop"] = stops; root["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settings)
    }
    static func remove() throws {
        let fm = FileManager.default, settings = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        guard fm.fileExists(atPath: settings.path), var root = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any], var hooks = root["hooks"] as? [String: Any], var stops = hooks["Stop"] as? [[String: Any]] else { return }
        stops.removeAll { group in
            let handlers = group["hooks"] as? [[String: Any]] ?? []
            return handlers.contains { ($0["type"] as? String) == "command" && (($0["command"] as? String) ?? "").contains("claude-complete-notify.sh") }
        }
        if stops.isEmpty { hooks.removeValue(forKey: "Stop") } else { hooks["Stop"] = stops }
        root["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]).write(to: settings)
    }
    static func isInstalled() -> Bool {
        let settings = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: settings), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let hooks = root["hooks"] as? [String: Any], let stops = hooks["Stop"] as? [[String: Any]] else { return false }
        return stops.contains { group in (group["hooks"] as? [[String: Any]] ?? []).contains { (($0["command"] as? String) ?? "").contains("claude-complete-notify.sh") } }
    }
}

final class CozeNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound, .list] }
}

final class CompletionBanner {
    static let shared = CompletionBanner()
    private var panel: NSPanel?

    func show(title: String, message: String) {
        DispatchQueue.main.async {
            let panel = self.panel ?? self.makePanel()
            self.panel = panel
            guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 18, y: frame.maxY - panel.frame.height - 18))
            (panel.contentView?.viewWithTag(901) as? NSTextField)?.stringValue = title
            (panel.contentView?.viewWithTag(902) as? NSTextField)?.stringValue = message
            panel.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak panel] in panel?.orderOut(nil) }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 310, height: 92), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 310, height: 92))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedRed: 0.075, green: 0.10, blue: 0.14, alpha: 0.97).cgColor
        root.layer?.cornerRadius = 14
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        let dot = NSTextField(labelWithString: "●")
        dot.font = .systemFont(ofSize: 15, weight: .bold); dot.textColor = NSColor(calibratedRed: 0.38, green: 0.86, blue: 0.65, alpha: 1)
        let title = NSTextField(labelWithString: "Coze")
        title.font = .systemFont(ofSize: 14, weight: .semibold); title.textColor = .white
        let message = NSTextField(labelWithString: "")
        message.font = .systemFont(ofSize: 12); message.textColor = NSColor(calibratedWhite: 0.82, alpha: 1); message.lineBreakMode = .byTruncatingTail
        title.tag = 901; message.tag = 902
        [dot, title, message].forEach { root.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18), dot.topAnchor.constraint(equalTo: root.topAnchor, constant: 17),
            title.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 7), title.centerYAnchor.constraint(equalTo: dot.centerYAnchor),
            message.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 19), message.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18), message.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10)
        ])
        panel.contentView = root
        return panel
    }
}

enum Notifier {
    enum Result { case queued, disabled, failed(String) }
    private static let delegate = CozeNotificationDelegate()
    static func configure() {
        let center = UNUserNotificationCenter.current(); center.delegate = delegate
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }
    static func notify(title: String, message: String, completion: ((Result) -> Void)? = nil) {
        DispatchQueue.main.async { NSSound.beep() }
        CompletionBanner.shared.show(title: title, message: message)
        let center = UNUserNotificationCenter.current(); center.delegate = delegate
        center.getNotificationSettings { settings in
            func enqueue() {
                let content = UNMutableNotificationContent(); content.title = title; content.body = message; content.sound = .default
                let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                center.add(request) { error in
                    completion?(error == nil ? .queued : .failed(error!.localizedDescription))
                }
            }
            if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
                guard settings.alertSetting == .enabled else { completion?(.disabled); return }
                enqueue()
                return
            }
            guard settings.authorizationStatus == .notDetermined else { completion?(.disabled); return }
            center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                if let error { completion?(.failed(error.localizedDescription)) }
                else if granted { enqueue() }
                else { completion?(.disabled) }
            }
        }
    }
}

final class AgentInbox {
    static let shared = AgentInbox()
    private var timer: Timer?
    var onSignal: ((String) -> Void)?
    private let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".coze/inbox", isDirectory: true)
    func start() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        timer?.invalidate(); timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in self?.drain() }
    }
    private func drain() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter({ $0.pathExtension == "signal" }) else { return }
        for file in files {
            try? fm.removeItem(at: file)
            let provider = file.lastPathComponent.hasPrefix("claude-") ? "Claude Code" : "OpenCode"
            onSignal?(provider)
            Notifier.notify(title: "Coze", message: "\(provider) 的任务已完成。")
        }
    }
}

enum LidRun {
    static func enable(hours: Int, completion: @escaping (String) -> Void) { privileged("/usr/bin/pmset -a disablesleep 1; /usr/bin/nohup /bin/sh -c 'sleep \(hours * 3600); /usr/bin/pmset -a disablesleep 0' >/dev/null 2>&1 &") { ok in completion(ok ? "Closed-lid run enabled for \(hours) hour(s). Coze will restore sleep automatically." : "Could not enable closed-lid mode.") } }
    static func disable(completion: @escaping (String) -> Void) { privileged("/usr/bin/pmset -a disablesleep 0") { completion($0 ? "Normal sleep behavior restored." : "Could not restore sleep behavior.") } }
    private static func privileged(_ command: String, completion: @escaping (Bool) -> Void) { DispatchQueue.global(qos: .userInitiated).async { let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript"); p.arguments = ["-e", "do shell script \"\(command.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"]; do { try p.run(); p.waitUntilExit(); completion(p.terminationStatus == 0) } catch { completion(false) } } }
}
