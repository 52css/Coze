import Cocoa
import ApplicationServices
import Darwin
import UserNotifications

#if !COZE_TESTING
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
#endif

struct CozePreferences: Codable {
    var threshold: Int
    var lidHours: Int
    var tunnelIdleMinutes: Int

    init(threshold: Int = 10000, lidHours: Int = 2, tunnelIdleMinutes: Int = 30) {
        self.threshold = threshold
        self.lidHours = lidHours
        self.tunnelIdleMinutes = Self.normalizedIdleMinutes(tunnelIdleMinutes)
    }

    static func normalizedIdleMinutes(_ value: Int) -> Int {
        [0, 15, 30, 60].contains(value) ? value : 30
    }

    private enum CodingKeys: String, CodingKey {
        case threshold
        case lidHours
        case tunnelIdleMinutes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        threshold = try values.decodeIfPresent(Int.self, forKey: .threshold) ?? 10000
        lidHours = try values.decodeIfPresent(Int.self, forKey: .lidHours) ?? 2
        tunnelIdleMinutes = Self.normalizedIdleMinutes(try values.decodeIfPresent(Int.self, forKey: .tunnelIdleMinutes) ?? 30)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(threshold, forKey: .threshold)
        try values.encode(lidHours, forKey: .lidHours)
        try values.encode(tunnelIdleMinutes, forKey: .tunnelIdleMinutes)
    }
}

enum CozePreferencesStore {
    private static let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".coze/preferences.json")

    static func load() -> CozePreferences {
        guard let data = try? Data(contentsOf: file), let preferences = try? JSONDecoder().decode(CozePreferences.self, from: data) else { return CozePreferences() }
        return CozePreferences(threshold: max(1, preferences.threshold), lidHours: min(max(1, preferences.lidHours), 8), tunnelIdleMinutes: preferences.tunnelIdleMinutes)
    }

    static func save(_ preferences: CozePreferences) {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(preferences).write(to: file, options: .atomic)
        } catch { }
    }
}

enum TunnelIdleTick: Equatable {
    case inactive
    case remaining(Int)
    case expired
}

struct TunnelIdleSession {
    private(set) var minutes: Int
    private var deadline: Date?

    init(minutes: Int) {
        self.minutes = CozePreferences.normalizedIdleMinutes(minutes)
    }

    mutating func start(now: Date = Date()) {
        deadline = minutes == 0 ? nil : now.addingTimeInterval(TimeInterval(minutes * 60))
    }

    mutating func renew(now: Date = Date()) {
        start(now: now)
    }

    mutating func stop() {
        deadline = nil
    }

    mutating func setMinutes(_ value: Int, now: Date = Date(), isConnected: Bool) {
        minutes = CozePreferences.normalizedIdleMinutes(value)
        isConnected ? start(now: now) : stop()
    }

    mutating func tick(now: Date = Date()) -> TunnelIdleTick {
        guard let deadline else { return .inactive }
        let remaining = Int(ceil(deadline.timeIntervalSince(now)))
        guard remaining > 0 else {
            self.deadline = nil
            return .expired
        }
        return .remaining(remaining)
    }
}

struct TunnelTrafficSample: Equatable {
    let bytesIn: UInt64
    let bytesOut: UInt64

    init?(csvLine: String) {
        let columns = csvLine.split(separator: ",", omittingEmptySubsequences: false)
        guard columns.count >= 3,
              !columns[0].isEmpty,
              let bytesIn = UInt64(columns[1]),
              let bytesOut = UInt64(columns[2]) else { return nil }
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}

struct TunnelTrafficActivityTracker {
    private var previous: TunnelTrafficSample?

    mutating func observe(csvLine: String) -> Bool {
        guard let sample = TunnelTrafficSample(csvLine: csvLine) else { return false }
        defer { previous = sample }
        guard let previous else { return sample.bytesIn > 0 || sample.bytesOut > 0 }
        return sample.bytesIn > previous.bytesIn || sample.bytesOut > previous.bytesOut
    }
}

struct TunnelTrafficLineBuffer {
    private var pending = ""

    mutating func append(_ chunk: String) -> [String] {
        pending += chunk
        var lines: [String] = []
        while let separator = pending.firstIndex(where: \.isNewline) {
            let line = String(pending[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            pending.removeSubrange(...separator)
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }
}

struct TunnelRoute: Codable, Equatable {
    var name = "服务"
    var localPort = 8080
    var targetHost = ""
    var targetPort = 80
    var path = "/"
}

struct TunnelSettings: Codable, Equatable {
    var host = ""
    var port = 22
    var username = ""
    var identityFile = ""
    var routes: [TunnelRoute] = []
}

enum TunnelSettingsStore {
    private static var file: URL {
#if COZE_TESTING || COZE_UI_TESTING
        if let override = ProcessInfo.processInfo.environment["COZE_TUNNEL_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
#endif
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".coze/tunnel.json")
    }

    static func load() -> TunnelSettings {
        secureExistingPaths()
        guard let data = try? Data(contentsOf: file), let value = try? JSONDecoder().decode(TunnelSettings.self, from: data) else { return TunnelSettings() }
        return value
    }

    static func save(_ value: TunnelSettings) {
        do {
            let directory = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try JSONEncoder().encode(value).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { }
    }

    private static func secureExistingPaths() {
        let directory = file.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        if FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }
}

enum TunnelCommandMatcher {
    static func matches(arguments: [String], settings: TunnelSettings) -> Bool {
        guard let executable = arguments.first,
              URL(fileURLWithPath: executable).lastPathComponent == "ssh",
              arguments.contains("-N"),
              arguments.last == "\(settings.username)@\(settings.host)" else { return false }

        let ports = values(after: "-p", in: arguments)
        let forwards = values(after: "-L", in: arguments)
        let identities = values(after: "-i", in: arguments)
        guard ports == [String(settings.port)] else { return false }
        let expectedForwards = settings.routes.map { "127.0.0.1:\($0.localPort):\($0.targetHost):\($0.targetPort)" }.sorted()
        guard forwards.sorted() == expectedForwards else { return false }
        return settings.identityFile.isEmpty ? identities.isEmpty : identities == [settings.identityFile]
    }

    private static func values(after option: String, in arguments: [String]) -> [String] {
        var values: [String] = []
        for index in arguments.indices where arguments[index] == option {
            guard arguments.indices.contains(index + 1) else { return [] }
            values.append(arguments[index + 1])
        }
        return values
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
    private let tunnelAction = NSButton()
    private let tunnelServiceButtons = NSStackView()
    private let tunnelConfigAction = NSButton()
    private let tunnelIdleOptions = NSStackView()
    private var tunnelIdleOptionButtons: [NSButton] = []
    private let tunnelIdleStatus = NSTextField(labelWithString: "连接后开始计时")
    private let tunnelIdleRenewAction = NSButton()
    private let wechatState = NSTextField(labelWithString: "未开启")
    private let claudeState = NSTextField(labelWithString: "未开启")
    private let openCodeState = NSTextField(labelWithString: "未开启")
    private let lidState = NSTextField(labelWithString: "未开启")
    private let tunnelState = NSTextField(labelWithString: "未连接")
    private let tunnelQuickPassword = NSSecureTextField()
    private var wechatIsOn = false
    private var lidIsOn = false
    private var claudeIsOn = false
    private var openCodeIsOn = false
    private let tunnel = LocalSSHTunnel()
    private let tunnelTrafficMonitor = TunnelTrafficMonitor()
    private var tunnelSettings = TunnelSettingsStore.load()
    private var tunnelWindow: NSWindow?
    private let tunnelHost = NSTextField()
    private let tunnelPort = NSTextField()
    private let tunnelUsername = NSTextField()
    private let tunnelLocalPort = NSTextField()
    private let tunnelTargetHost = NSTextField()
    private let tunnelTargetPort = NSTextField()
    private let tunnelRoutesStack = NSStackView()
    private var tunnelRouteEditors: [TunnelRouteEditor] = []
    private let tunnelIdentityFile = NSTextField()
    private let tunnelPassword = NSSecureTextField()
    private let tunnelWindowStatus = NSTextField(labelWithString: "填写服务器信息后启用。密码不会保存。")
    private var preferences = CozePreferencesStore.load()
    private var tunnelIdleSession = TunnelIdleSession(minutes: 30)
    private var tunnelIdleTimer: Timer?
    private var tunnelIdleFailSafe = false

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

    func applicationWillTerminate(_ notification: Notification) { tunnelTrafficMonitor.stop(); tunnel.stopOwned() }

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
            if #available(macOS 14.0, *) {
                NSRunningApplication.current.activate(options: [.activateAllWindows])
            } else {
                NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            }
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
        let wechat = wechatCard(), agent = agentCard(), tunnel = tunnelCard(), lid = lidCard()
        [wechat, agent, tunnel, lid].forEach { card in grid.addArrangedSubview(card); card.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true }
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.documentView = grid; scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)
        status.textColor = muted; status.font = .systemFont(ofSize: 12); status.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(status)
        NSLayoutConstraint.activate([
            brand.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 34), brand.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            motto.leadingAnchor.constraint(equalTo: brand.trailingAnchor, constant: 14), motto.centerYAnchor.constraint(equalTo: brand.centerYAnchor),
            rule.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 34), rule.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -34), rule.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 19), rule.heightAnchor.constraint(equalToConstant: 1),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 34), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22), scroll.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 22), scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -14),
            grid.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
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
        let card = cardView(), number = label("04", size: 13, weight: .bold, color: .systemOrange), title = label("合盖继续运行", size: 18, weight: .semibold, color: .white), copy = label("默认关闭。仅在有长任务时限时允许合盖继续运行；保持通风，绝不要放进密闭背包。", size: 13, weight: .regular, color: muted), hours = label("小时", size: 12, weight: .regular, color: muted)
        prepareField(lidHours, alignment: .center); prepareState(lidState); prepareAction(lidAction, title: "开启", action: #selector(lidActionTapped))
        [number,title,copy,lidHours,hours,lidState,lidAction].forEach { card.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([number.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 19), number.topAnchor.constraint(equalTo: card.topAnchor, constant: 18), title.leadingAnchor.constraint(equalTo: number.trailingAnchor, constant: 12), title.centerYAnchor.constraint(equalTo: number.centerYAnchor), copy.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 19), copy.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10), copy.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -19), lidState.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 19), lidState.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18), lidHours.leadingAnchor.constraint(equalTo: lidState.trailingAnchor, constant: 16), lidHours.centerYAnchor.constraint(equalTo: lidState.centerYAnchor), lidHours.widthAnchor.constraint(equalToConstant: 48), lidHours.heightAnchor.constraint(equalToConstant: 28), hours.leadingAnchor.constraint(equalTo: lidHours.trailingAnchor, constant: 7), hours.centerYAnchor.constraint(equalTo: lidState.centerYAnchor), lidAction.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -19), lidAction.centerYAnchor.constraint(equalTo: lidState.centerYAnchor), lidAction.widthAnchor.constraint(equalToConstant: 92), lidAction.heightAnchor.constraint(equalToConstant: 30), card.heightAnchor.constraint(equalToConstant: 144)])
        return card
    }

    private func tunnelCard() -> NSView {
        let card = cardView(), number = label("03", size: 13, weight: .bold, color: accent), title = label("SSH 内网访问", size: 18, weight: .semibold, color: .white), copy = label("输入密码启用后，点击蓝色按钮打开内网页面；网页刷新或请求会自动续期。", size: 13, weight: .regular, color: muted), passwordLabel = label("SSH 密码", size: 12, weight: .medium, color: muted), idleLabel = label("闲置自动断开", size: 12, weight: .medium, color: muted)
        let tunnelHelp = NSButton()
        prepareState(tunnelState); prepareField(tunnelQuickPassword, alignment: .left); tunnelQuickPassword.placeholderString = "每次启用时输入；不会保存"
        prepareAction(tunnelAction, title: "启用隧道", action: #selector(tunnelActionTapped)); prepareLink(tunnelConfigAction, title: "配置服务", action: #selector(showTunnelConfig)); prepareLink(tunnelHelp, title: "如何填写？", action: #selector(showTunnelHelp))
        tunnelServiceButtons.orientation = .horizontal; tunnelServiceButtons.alignment = .centerY; tunnelServiceButtons.spacing = 8
        tunnelIdleOptions.orientation = .horizontal; tunnelIdleOptions.alignment = .centerY; tunnelIdleOptions.spacing = 7
        tunnelIdleOptionButtons = [(15, "15 分钟"), (30, "30 分钟"), (60, "60 分钟"), (0, "关闭")].map { minutes, title in
            let option = NSButton(title: title, target: self, action: #selector(setTunnelIdleMinutes(_:)))
            option.tag = minutes
            option.setButtonType(.toggle)
            option.isBordered = false
            option.wantsLayer = true
            option.layer?.cornerRadius = 7
            option.translatesAutoresizingMaskIntoConstraints = false
            option.widthAnchor.constraint(equalToConstant: minutes == 0 ? 54 : 66).isActive = true
            option.heightAnchor.constraint(equalToConstant: 28).isActive = true
            tunnelIdleOptions.addArrangedSubview(option)
            return option
        }
        tunnelIdleStatus.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium); tunnelIdleStatus.textColor = muted
        prepareLink(tunnelIdleRenewAction, title: "续期", action: #selector(renewTunnelIdle(_:)))
        [number, title, copy, passwordLabel, tunnelQuickPassword, idleLabel, tunnelIdleOptions, tunnelIdleStatus, tunnelIdleRenewAction, tunnelState, tunnelConfigAction, tunnelHelp, tunnelServiceButtons, tunnelAction].forEach { card.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([number.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 19), number.topAnchor.constraint(equalTo: card.topAnchor, constant: 18), title.leadingAnchor.constraint(equalTo: number.trailingAnchor, constant: 12), title.centerYAnchor.constraint(equalTo: number.centerYAnchor), copy.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 19), copy.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10), copy.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -19), passwordLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 19), passwordLabel.topAnchor.constraint(equalTo: copy.bottomAnchor, constant: 13), tunnelQuickPassword.leadingAnchor.constraint(equalTo: passwordLabel.trailingAnchor, constant: 12), tunnelQuickPassword.centerYAnchor.constraint(equalTo: passwordLabel.centerYAnchor), tunnelQuickPassword.widthAnchor.constraint(equalToConstant: 250), tunnelQuickPassword.heightAnchor.constraint(equalToConstant: 28), tunnelAction.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -19), tunnelAction.centerYAnchor.constraint(equalTo: passwordLabel.centerYAnchor), tunnelAction.widthAnchor.constraint(equalToConstant: 108), tunnelAction.heightAnchor.constraint(equalToConstant: 30), idleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 19), idleLabel.topAnchor.constraint(equalTo: passwordLabel.bottomAnchor, constant: 17), tunnelIdleOptions.leadingAnchor.constraint(equalTo: idleLabel.trailingAnchor, constant: 12), tunnelIdleOptions.centerYAnchor.constraint(equalTo: idleLabel.centerYAnchor), tunnelIdleStatus.leadingAnchor.constraint(equalTo: tunnelIdleOptions.trailingAnchor, constant: 14), tunnelIdleStatus.centerYAnchor.constraint(equalTo: idleLabel.centerYAnchor), tunnelIdleRenewAction.leadingAnchor.constraint(equalTo: tunnelIdleStatus.trailingAnchor, constant: 12), tunnelIdleRenewAction.centerYAnchor.constraint(equalTo: idleLabel.centerYAnchor), tunnelIdleRenewAction.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -19), tunnelState.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 19), tunnelState.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18), tunnelConfigAction.leadingAnchor.constraint(equalTo: tunnelState.trailingAnchor, constant: 18), tunnelConfigAction.centerYAnchor.constraint(equalTo: tunnelState.centerYAnchor), tunnelHelp.leadingAnchor.constraint(equalTo: tunnelConfigAction.trailingAnchor, constant: 14), tunnelHelp.centerYAnchor.constraint(equalTo: tunnelState.centerYAnchor), tunnelServiceButtons.leadingAnchor.constraint(equalTo: tunnelHelp.trailingAnchor, constant: 14), tunnelServiceButtons.centerYAnchor.constraint(equalTo: tunnelState.centerYAnchor), tunnelServiceButtons.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -19), card.heightAnchor.constraint(equalToConstant: 222)])
        refreshTunnelServiceButtons(enabled: false)
        refreshTunnelIdleUI()
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
    @objc private func tunnelActionTapped() {
        if tunnel.synchronize(settings: tunnelSettings) { tunnel.stop(); stopTunnelIdleSession(); setState(tunnelState, "未连接", active: false); setAction(tunnelAction, "启用隧道"); refreshTunnelServiceButtons(enabled: false); update("SSH 内网访问已断开。"); return }
        guard !tunnelSettings.host.isEmpty, !tunnelSettings.routes.isEmpty, tunnelSettings.routes.allSatisfy({ !$0.targetHost.isEmpty }) else { showTunnelWindow(); return }
        guard !tunnelQuickPassword.stringValue.isEmpty || !tunnelSettings.identityFile.isEmpty else { update("请输入 SSH 密码，或在配置中选择私钥。") ; return }
        startTunnel(settings: tunnelSettings, password: tunnelQuickPassword.stringValue, statusLabel: nil)
    }
    @objc private func showTunnelConfig() { showTunnelWindow() }
    @objc private func showTunnelHelp() { let alert = NSAlert(); alert.messageText = "SSH 内网访问怎么用"; alert.informativeText = "1. 点击“配置服务”。\n2. 向运维或服务器管理员获取：堡垒机主机、SSH 用户名，以及每个内网服务的目标主机和端口。\n3. 服务数量不限；本地端口、HTTP 端口和路径均可按需修改。\n4. 保存后回到主界面，每次输入 SSH 密码并点击“启用隧道”。\n5. 连接成功后，直接点击蓝色服务按钮打开对应内网页面。\n6. 默认闲置 30 分钟自动断开；网页刷新、跳转、接口请求、点击服务或“续期”都会重新计时，也可选择 15、60 分钟或关闭。\n\n密码不会保存，服务只对本机 127.0.0.1 开放。"; alert.addButton(withTitle: "知道了"); alert.runModal() }
    @objc private func openTunnelService(_ sender: NSButton) {
        guard synchronizeTunnelUI() else {
            update("请先输入 SSH 密码并启用隧道，再打开内网页面。")
            window?.makeFirstResponder(tunnelQuickPassword)
            return
        }
        if openTunnelRoute(at: sender.tag) { renewTunnelIdle(nil) }
    }
    @discardableResult
    private func openTunnelRoute(at index: Int) -> Bool { guard tunnel.isRunning, tunnelSettings.routes.indices.contains(index) else { return false }; let route = tunnelSettings.routes[index]; let path = route.path.hasPrefix("/") ? route.path : "/\(route.path)"; guard let url = URL(string: "http://127.0.0.1:\(route.localPort)\(path)") else { return false }; return NSWorkspace.shared.open(url) }
    @objc private func chooseIdentityFile() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false; panel.message = "选择 SSH 私钥文件（推荐）"
        if panel.runModal() == .OK { tunnelIdentityFile.stringValue = panel.url?.path ?? "" }
    }
    @objc private func startTunnelTapped() {
        let routes = tunnelRouteEditors.map { $0.route }
        let settings = TunnelSettings(host: tunnelHost.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), port: tunnelPort.integerValue, username: tunnelUsername.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), identityFile: tunnelIdentityFile.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), routes: routes)
        guard !settings.host.isEmpty, !settings.username.isEmpty, !settings.routes.isEmpty, settings.routes.allSatisfy({ !$0.name.isEmpty && !$0.targetHost.isEmpty && (1...65535).contains($0.localPort) && (1...65535).contains($0.targetPort) }), (1...65535).contains(settings.port) else { tunnelWindowStatus.stringValue = "至少添加一条服务，并完整填写堡垒机和端口。"; return }
        if tunnel.synchronize(settings: tunnelSettings), settings != tunnelSettings { tunnelWindowStatus.stringValue = "请先在主界面断开当前隧道，再保存新的连接配置。"; return }
        tunnelSettings = settings; TunnelSettingsStore.save(settings); _ = synchronizeTunnelUI(); tunnelWindowStatus.stringValue = "配置已保存。回主界面输入密码并启用；密码不会保存。"
    }
    private func startTunnel(settings: TunnelSettings, password: String, statusLabel: NSTextField?) {
        statusLabel?.stringValue = "正在建立 SSH 通道…"; setAction(tunnelAction, "连接中…")
        tunnel.start(settings: settings, password: password) { [weak self] result in DispatchQueue.main.async { guard let self else { return }; switch result { case .success: self.tunnelPassword.stringValue = ""; self.tunnelQuickPassword.stringValue = ""; statusLabel?.stringValue = "已连接：回主界面点击蓝色服务按钮打开页面。"; self.setState(self.tunnelState, "已连接", active: true); self.setAction(self.tunnelAction, "断开"); self.refreshTunnelServiceButtons(enabled: true); self.beginTunnelIdleSession(); self.update("SSH 通道已建立，可直接点击蓝色服务按钮打开内网页面。")
            case .failure(let error): self.stopTunnelIdleSession(); statusLabel?.stringValue = error.localizedDescription; self.setState(self.tunnelState, "连接失败", active: false); self.setAction(self.tunnelAction, "启用隧道"); self.update("SSH 通道连接失败：\(error.localizedDescription)") } } }
    }
    private func refreshTunnelServiceButtons(enabled: Bool) {
        for view in tunnelServiceButtons.arrangedSubviews {
            tunnelServiceButtons.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, route) in tunnelSettings.routes.enumerated() {
            let title = route.name
            let serviceButton = NSButton(title: title, target: self, action: #selector(openTunnelService(_:)))
            serviceButton.tag = index
            serviceButton.isBordered = false
            serviceButton.wantsLayer = true
            serviceButton.layer?.backgroundColor = (enabled ? accent : NSColor(calibratedRed: 0.16, green: 0.36, blue: 0.56, alpha: 1)).cgColor
            serviceButton.layer?.cornerRadius = 7
            serviceButton.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold)
            ])
            serviceButton.toolTip = enabled ? "打开 \(route.name)" : "请先输入 SSH 密码并启用隧道"
            serviceButton.translatesAutoresizingMaskIntoConstraints = false
            serviceButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
            serviceButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 66).isActive = true
            serviceButton.widthAnchor.constraint(lessThanOrEqualToConstant: 112).isActive = true
            tunnelServiceButtons.addArrangedSubview(serviceButton)
        }
    }
    @discardableResult
    private func synchronizeTunnelUI() -> Bool {
        let active = tunnel.synchronize(settings: tunnelSettings)
        setState(tunnelState, active ? "已连接" : "未连接", active: active)
        setAction(tunnelAction, active ? "断开" : "启用隧道")
        refreshTunnelServiceButtons(enabled: active)
        if !active { stopTunnelIdleSession() } else { refreshTunnelIdleUI() }
        return active
    }
    @objc private func setTunnelIdleMinutes(_ sender: NSButton) {
        let minutes = CozePreferences.normalizedIdleMinutes(sender.tag)
        tunnelIdleFailSafe = false
        preferences.tunnelIdleMinutes = minutes
        savePreferences()
        let active = tunnel.synchronize(settings: tunnelSettings)
        tunnelIdleSession.setMinutes(minutes, isConnected: active)
        if active && minutes > 0 { scheduleTunnelIdleTimer(); startTunnelTrafficMonitoring() }
        else { tunnelIdleTimer?.invalidate(); tunnelIdleTimer = nil; tunnelTrafficMonitor.stop() }
        refreshTunnelIdleUI()
        update(minutes == 0 ? "闲置自动断开已关闭。" : "闲置自动断开已设置为 \(minutes) 分钟。")
    }
    @objc private func renewTunnelIdle(_ sender: Any?) {
        guard tunnel.synchronize(settings: tunnelSettings) else {
            synchronizeTunnelUI()
            update("SSH 隧道未连接，无法续期。")
            return
        }
        guard preferences.tunnelIdleMinutes > 0 else {
            update("闲置自动断开当前已关闭。")
            return
        }
        tunnelIdleSession.renew()
        scheduleTunnelIdleTimer()
        tickTunnelIdleSession()
        update("SSH 隧道已续期 \(preferences.tunnelIdleMinutes) 分钟。")
    }
    private func beginTunnelIdleSession() {
        tunnelIdleFailSafe = false
        tunnelIdleSession.setMinutes(preferences.tunnelIdleMinutes, isConnected: true)
        if preferences.tunnelIdleMinutes > 0 { scheduleTunnelIdleTimer(); startTunnelTrafficMonitoring() }
        else { tunnelIdleTimer?.invalidate(); tunnelIdleTimer = nil }
        refreshTunnelIdleUI()
    }
    private func stopTunnelIdleSession() {
        tunnelIdleTimer?.invalidate()
        tunnelIdleTimer = nil
        tunnelTrafficMonitor.stop()
        tunnelIdleFailSafe = false
        tunnelIdleSession.stop()
        refreshTunnelIdleUI()
    }
    @discardableResult
    private func startTunnelTrafficMonitoring() -> Bool {
        guard let pid = tunnel.processIdentifier else { tunnelTrafficMonitor.stop(); pauseTunnelIdleForMonitorFailure(); return false }
        let started = tunnelTrafficMonitor.start(processIdentifier: pid, onActivity: { [weak self] in
            DispatchQueue.main.async { self?.recordTunnelTrafficActivity() }
        }, onFailure: { [weak self] in
            DispatchQueue.main.async { self?.pauseTunnelIdleForMonitorFailure() }
        })
        if !started { pauseTunnelIdleForMonitorFailure() }
        return started
    }
    private func recordTunnelTrafficActivity() {
        guard preferences.tunnelIdleMinutes > 0, tunnel.isRunning else { return }
        tunnelIdleSession.renew()
        tickTunnelIdleSession()
    }
    private func pauseTunnelIdleForMonitorFailure() {
        guard preferences.tunnelIdleMinutes > 0, tunnel.isRunning else { return }
        tunnelIdleTimer?.invalidate()
        tunnelIdleTimer = nil
        tunnelIdleSession.stop()
        tunnelIdleFailSafe = true
        tunnelIdleStatus.stringValue = "流量监测不可用，自动断开已暂停"
        tunnelIdleRenewAction.isHidden = true
        update("无法监测网页流量；为避免误断开，闲置自动断开已暂停。")
    }
    private func scheduleTunnelIdleTimer() {
        tunnelIdleTimer?.invalidate()
        guard preferences.tunnelIdleMinutes > 0 else { tunnelIdleTimer = nil; return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tickTunnelIdleSession() }
        timer.tolerance = 0.15
        RunLoop.main.add(timer, forMode: .common)
        tunnelIdleTimer = timer
    }
    private func tickTunnelIdleSession() {
        guard tunnel.isRunning else {
            tunnelIdleTimer?.invalidate()
            tunnelIdleTimer = nil
            tunnelTrafficMonitor.stop()
            tunnelIdleSession.stop()
            setState(tunnelState, "未连接", active: false)
            setAction(tunnelAction, "启用隧道")
            refreshTunnelServiceButtons(enabled: false)
            refreshTunnelIdleUI()
            return
        }
        switch tunnelIdleSession.tick() {
        case .inactive:
            tunnelIdleStatus.stringValue = preferences.tunnelIdleMinutes == 0 ? "自动断开已关闭" : "连接后开始计时"
        case .remaining(let seconds):
            tunnelIdleStatus.stringValue = String(format: "%02d:%02d 后自动断开", seconds / 60, seconds % 60)
        case .expired:
            let minutes = preferences.tunnelIdleMinutes
            tunnelIdleTimer?.invalidate()
            tunnelIdleTimer = nil
            tunnelTrafficMonitor.stop()
            tunnel.stop()
            setState(tunnelState, "已自动断开", active: false)
            setAction(tunnelAction, "启用隧道")
            refreshTunnelServiceButtons(enabled: false)
            tunnelIdleStatus.stringValue = "连接后开始计时"
            tunnelIdleRenewAction.isHidden = true
            update("已闲置 \(minutes) 分钟，SSH 隧道已自动断开。")
        }
    }
    private func refreshTunnelIdleUI() {
        let selectedMinutes = preferences.tunnelIdleMinutes
        for option in tunnelIdleOptionButtons {
            let selected = option.tag == selectedMinutes
            option.state = selected ? .on : .off
            option.layer?.backgroundColor = (selected ? accent : NSColor(calibratedRed: 0.16, green: 0.26, blue: 0.39, alpha: 1)).cgColor
            option.attributedTitle = NSAttributedString(string: option.title, attributes: [
                .foregroundColor: selected ? NSColor.white : muted,
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold)
            ])
            option.toolTip = selected ? "当前选择：\(option.title)" : "将闲置自动断开设置为 \(option.title)"
        }
        let active = tunnel.isRunning
        tunnelIdleRenewAction.isHidden = !active || selectedMinutes == 0 || tunnelIdleFailSafe
        if !active { tunnelIdleStatus.stringValue = "连接后开始计时" }
        else if selectedMinutes == 0 { tunnelIdleStatus.stringValue = "自动断开已关闭" }
        else if tunnelIdleFailSafe { tunnelIdleStatus.stringValue = "流量监测不可用，自动断开已暂停" }
        else { tickTunnelIdleSession() }
    }
    @objc private func addTunnelRoute() { let nextPort = max(8079, (tunnelRouteEditors.map { $0.route.localPort }.max() ?? 8079)) + 1; addTunnelRouteEditor(TunnelRoute(name: "服务 \(tunnelRouteEditors.count + 1)", localPort: nextPort)) }
    @objc private func removeTunnelRoute(_ sender: NSButton) { guard tunnelRouteEditors.count > 1, tunnelRouteEditors.indices.contains(sender.tag) else { return }; let editor = tunnelRouteEditors.remove(at: sender.tag); tunnelRoutesStack.removeArrangedSubview(editor); editor.removeFromSuperview(); refreshTunnelRouteEditorTags() }
    private func addTunnelRouteEditor(_ route: TunnelRoute) { let editor = TunnelRouteEditor(route: route); editor.removeButton.target = self; editor.removeButton.action = #selector(removeTunnelRoute(_:)); tunnelRouteEditors.append(editor); tunnelRoutesStack.addArrangedSubview(editor); refreshTunnelRouteEditorTags() }
    private func refreshTunnelRouteEditorTags() { for (index, editor) in tunnelRouteEditors.enumerated() { editor.removeButton.tag = index; editor.title.stringValue = "服务 \(index + 1)" } }
    private func showTunnelWindow() {
        if let tunnelWindow { tunnelWindow.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 700), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false); window.title = "SSH 内网访问配置"; window.isReleasedWhenClosed = false; window.center(); window.contentView?.wantsLayer = true; window.contentView?.layer?.backgroundColor = NSColor(calibratedRed: 0.055, green: 0.075, blue: 0.11, alpha: 1).cgColor
        let root = window.contentView!; let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.translatesAutoresizingMaskIntoConstraints = false; let panel = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 920)); panel.wantsLayer = true; panel.layer?.backgroundColor = NSColor(calibratedRed: 0.055, green: 0.075, blue: 0.11, alpha: 1).cgColor; scroll.documentView = panel; root.addSubview(scroll); NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor), scroll.topAnchor.constraint(equalTo: root.topAnchor), scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -94), panel.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor), panel.heightAnchor.constraint(greaterThanOrEqualToConstant: 920)])
        let title = label("配置本地 SSH 隧道", size: 21, weight: .semibold, color: .white); let note = label("仅本机 127.0.0.1 可访问。配置保存后，主界面只需输入密码启用。", size: 12, weight: .regular, color: muted); let form = NSStackView(); form.orientation = .vertical; form.alignment = .leading; form.spacing = 9
        [tunnelHost, tunnelPort, tunnelUsername, tunnelIdentityFile].forEach { prepareField($0, alignment: .left); $0.translatesAutoresizingMaskIntoConstraints = false; $0.widthAnchor.constraint(equalToConstant: 330).isActive = true; $0.heightAnchor.constraint(equalToConstant: 26).isActive = true }
        tunnelHost.placeholderString = "例如 bastion.example.com"; tunnelPort.stringValue = String(tunnelSettings.port); tunnelUsername.stringValue = tunnelSettings.username; tunnelHost.stringValue = tunnelSettings.host; tunnelIdentityFile.stringValue = tunnelSettings.identityFile
        func row(_ name: String, _ field: NSTextField) -> NSStackView { let line = NSStackView(); line.orientation = .horizontal; line.spacing = 12; let nameLabel = label(name, size: 12, weight: .medium, color: muted); nameLabel.widthAnchor.constraint(equalToConstant: 102).isActive = true; line.addArrangedSubview(nameLabel); line.addArrangedSubview(field); return line }
        tunnelRoutesStack.orientation = .vertical; tunnelRoutesStack.alignment = .width; tunnelRoutesStack.spacing = 12; tunnelRouteEditors.removeAll(); let initialRoutes = tunnelSettings.routes.isEmpty ? [TunnelRoute(name: "服务 1", localPort: 8080)] : tunnelSettings.routes; initialRoutes.forEach { addTunnelRouteEditor($0) }
        let routesTitle = label("访问服务", size: 14, weight: .semibold, color: accent); let routesHint = label("只需填写目标主机；本地端口、HTTP 端口和路径已自动预填，可按需修改。", size: 12, weight: .regular, color: muted); let add = button("＋ 添加服务", action: #selector(addTunnelRoute)); let choose = button("选择私钥…", action: #selector(chooseIdentityFile)); let save = button("保存配置", action: #selector(startTunnelTapped)); [add, choose, save].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; $0.widthAnchor.constraint(equalToConstant: 108).isActive = true; $0.heightAnchor.constraint(equalToConstant: 30).isActive = true }
        [row("堡垒机主机", tunnelHost), row("SSH 端口", tunnelPort), row("用户名", tunnelUsername), row("SSH 私钥（可选）", tunnelIdentityFile), routesTitle, routesHint, tunnelRoutesStack].forEach { form.addArrangedSubview($0) }
        tunnelWindowStatus.textColor = muted; tunnelWindowStatus.font = .systemFont(ofSize: 12); [title, note, form].forEach { panel.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }; [add, choose, save, tunnelWindowStatus].forEach { root.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([title.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 28), title.topAnchor.constraint(equalTo: panel.topAnchor, constant: 24), note.leadingAnchor.constraint(equalTo: title.leadingAnchor), note.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8), note.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -28), form.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 28), form.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 18), form.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -28), form.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -24), add.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28), add.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -22), choose.leadingAnchor.constraint(equalTo: add.trailingAnchor, constant: 12), choose.centerYAnchor.constraint(equalTo: add.centerYAnchor), save.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28), save.centerYAnchor.constraint(equalTo: add.centerYAnchor), tunnelWindowStatus.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28), tunnelWindowStatus.bottomAnchor.constraint(equalTo: add.topAnchor, constant: -10), tunnelWindowStatus.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28)])
        tunnelWindow = window; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func applyDefaults() {
        tunnelIdleSession.setMinutes(preferences.tunnelIdleMinutes, isConnected: false)
        let limit = max(1, threshold.integerValue); threshold.stringValue = String(limit); savePreferences(); ClipboardRelay.shared.limit = limit; ClipboardRelay.shared.onStatus = { [weak self] in self?.update($0) }
        if ClipboardRelay.shared.start() { wechatIsOn = true; setAction(wechatAction, "关闭"); setState(wechatState, "已开启", active: true) }
        else { setAction(wechatAction, "去授权"); setState(wechatState, "需要授权", active: false) }
        claudeIsOn = ClaudeCodeHook.isInstalled(); if claudeIsOn { try? ClaudeCodeHook.install() }; setAction(claudeAction, claudeIsOn ? "关闭" : "安装并开启"); setState(claudeState, claudeIsOn ? "已开启" : "未开启", active: claudeIsOn)
        openCodeIsOn = OpenCodePlugin.isInstalled(); if openCodeIsOn { try? OpenCodePlugin.install() }; setAction(openCodeAction, openCodeIsOn ? "关闭" : "安装并开启"); setState(openCodeState, openCodeIsOn ? "已开启" : "未开启", active: openCodeIsOn)
        if synchronizeTunnelUI() { beginTunnelIdleSession() }
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
    private func savePreferences() { preferences = CozePreferences(threshold: max(1, threshold.integerValue), lidHours: min(max(1, lidHours.integerValue), 8), tunnelIdleMinutes: preferences.tunnelIdleMinutes); CozePreferencesStore.save(preferences) }
    private func prepareField(_ field: NSTextField, alignment: NSTextAlignment) { field.alignment = alignment; field.delegate = self; field.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium); field.wantsLayer = true; field.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.22).cgColor; field.layer?.cornerRadius = 7 }
    private var accent: NSColor { NSColor(calibratedRed: 0.35, green: 0.66, blue: 1.0, alpha: 1) }
    private var muted: NSColor { NSColor(calibratedRed: 0.72, green: 0.77, blue: 0.84, alpha: 1) }
}

final class TunnelRouteEditor: NSView {
    let title = NSTextField(labelWithString: "服务")
    let removeButton = NSButton(title: "删除", target: nil, action: nil)
    private let nameField = NSTextField()
    private let localPortField = NSTextField()
    private let targetHostField = NSTextField()
    private let targetPortField = NSTextField()
    private let pathField = NSTextField()
    var route: TunnelRoute { TunnelRoute(name: nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), localPort: localPortField.integerValue, targetHost: targetHostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), targetPort: targetPortField.integerValue, path: pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "/" : pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) }

    init(route: TunnelRoute) {
        super.init(frame: .zero); wantsLayer = true; layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor; layer?.cornerRadius = 10
        title.font = .systemFont(ofSize: 13, weight: .semibold); title.textColor = .white; removeButton.isBordered = false; removeButton.attributedTitle = NSAttributedString(string: "删除", attributes: [.foregroundColor: NSColor.systemRed, .font: NSFont.systemFont(ofSize: 12, weight: .medium)])
        let fields = [nameField, localPortField, targetHostField, targetPortField, pathField]; fields.forEach { $0.font = .systemFont(ofSize: 12); $0.wantsLayer = true; $0.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor; $0.layer?.cornerRadius = 6; $0.heightAnchor.constraint(equalToConstant: 25).isActive = true }
        nameField.stringValue = route.name; nameField.placeholderString = "页面名称"; localPortField.stringValue = String(route.localPort); targetHostField.stringValue = route.targetHost; targetHostField.placeholderString = "目标主机，例如 10.0.0.8"; targetPortField.stringValue = String(route.targetPort); pathField.stringValue = route.path
        func field(_ title: String, _ value: NSTextField, width: CGFloat) -> NSStackView { let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 4; let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 11, weight: .medium); label.textColor = NSColor(calibratedWhite: 0.72, alpha: 1); value.widthAnchor.constraint(equalToConstant: width).isActive = true; stack.addArrangedSubview(label); stack.addArrangedSubview(value); return stack }
        let row1 = NSStackView(views: [field("名称", nameField, width: 130), field("本地端口", localPortField, width: 90), field("目标主机", targetHostField, width: 180)]); row1.spacing = 10
        let row2 = NSStackView(views: [field("目标端口", targetPortField, width: 90), field("打开路径", pathField, width: 220)]); row2.spacing = 10
        [title, removeButton, row1, row2].forEach { addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), title.topAnchor.constraint(equalTo: topAnchor, constant: 12), removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14), removeButton.centerYAnchor.constraint(equalTo: title.centerYAnchor), row1.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), row1.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10), row2.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), row2.topAnchor.constraint(equalTo: row1.bottomAnchor, constant: 9), row2.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
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

final class TunnelTrafficMonitor {
    private let queue = DispatchQueue(label: "local.coze.tunnel-traffic")
    private let scriptPath: String
    private let nettopPath: String
    private var process: Process?
    private var input: Pipe?
    private var timer: DispatchSourceTimer?
    private var logURL: URL?
    private var readOffset = 0
    private var lines = TunnelTrafficLineBuffer()
    private var tracker = TunnelTrafficActivityTracker()
    private var onActivity: (() -> Void)?
    private var onFailure: (() -> Void)?

    init(scriptPath: String = "/usr/bin/script", nettopPath: String = "/usr/bin/nettop") {
        self.scriptPath = scriptPath
        self.nettopPath = nettopPath
    }

    @discardableResult
    func start(processIdentifier: pid_t, onActivity: @escaping () -> Void, onFailure: @escaping () -> Void) -> Bool {
        stop()
        guard FileManager.default.isExecutableFile(atPath: scriptPath), FileManager.default.isExecutableFile(atPath: nettopPath) else { return false }
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("coze-tunnel-traffic-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: logURL.path, contents: nil) else { return false }
        let task = Process()
        let input = Pipe()
        task.executableURL = URL(fileURLWithPath: scriptPath)
        task.arguments = ["-q", "-t", "0", logURL.path, "/bin/sh", "-c", "stty rows 24 cols 120; exec \"$@\"", "coze-nettop", nettopPath, "-P", "-L", "0", "-s", "2", "-n", "-x", "-t", "loopback", "-J", "bytes_in,bytes_out", "-p", String(processIdentifier)]
        task.standardInput = input
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            try? FileManager.default.removeItem(at: logURL)
            return false
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 1)
        timer.setEventHandler { [weak self] in self?.readNewSamples() }
        queue.sync {
            self.process = task
            self.input = input
            self.timer = timer
            self.logURL = logURL
            readOffset = 0
            lines = TunnelTrafficLineBuffer()
            tracker = TunnelTrafficActivityTracker()
            self.onActivity = onActivity
            self.onFailure = onFailure
        }
        timer.resume()
        return true
    }

    func stop() {
        let resources: (Process?, Pipe?, DispatchSourceTimer?, URL?) = queue.sync {
            let resources = (process, input, timer, logURL)
            process = nil
            input = nil
            timer = nil
            logURL = nil
            readOffset = 0
            lines = TunnelTrafficLineBuffer()
            tracker = TunnelTrafficActivityTracker()
            onActivity = nil
            onFailure = nil
            return resources
        }
        resources.2?.cancel()
        resources.1?.fileHandleForWriting.closeFile()
        if resources.0?.isRunning == true { resources.0?.terminate() }
        if let logURL = resources.3 { try? FileManager.default.removeItem(at: logURL) }
    }

    private func readNewSamples() {
        guard process?.isRunning == true else { failMonitoring(); return }
        guard let logURL, let data = try? Data(contentsOf: logURL) else { return }
        if data.count < readOffset { readOffset = 0 }
        guard data.count > readOffset else { return }
        let chunk = data.subdata(in: readOffset..<data.count)
        readOffset = data.count
        for line in lines.append(String(decoding: chunk, as: UTF8.self)) {
            if tracker.observe(csvLine: line) { onActivity?() }
        }
    }

    private func failMonitoring() {
        let failure = onFailure
        timer?.cancel()
        input?.fileHandleForWriting.closeFile()
        if let logURL { try? FileManager.default.removeItem(at: logURL) }
        process = nil
        input = nil
        timer = nil
        logURL = nil
        onActivity = nil
        onFailure = nil
        failure?()
    }

    deinit { stop() }
}

private final class LockedTextBuffer {
    private let lock = NSLock()
    private var storage = ""

    func append(_ data: Data) {
        lock.lock()
        storage += String(decoding: data, as: UTF8.self)
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return storage.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class LocalSSHTunnel {
    private let lock = NSLock()
    private let sshExecutable: String
    private let readinessTimeout: TimeInterval
    private var ownedProcess: Process?
    private var adoptedPID: pid_t?
    private var activeSettings: TunnelSettings?
    private var askPassScript: URL?
    private var passwordInput: Pipe?
    private var outputPipe: Pipe?

    init(sshExecutable: String = "/usr/bin/ssh", readinessTimeout: TimeInterval = 20) {
        self.sshExecutable = sshExecutable
        self.readinessTimeout = readinessTimeout
    }

    var isRunning: Bool { runningPID() != nil }

    var processIdentifier: pid_t? { runningPID() }

    func synchronize(settings: TunnelSettings) -> Bool {
        _ = runningPID()
        lock.lock()
        if ownedProcess?.isRunning == true || adoptedPID.map(Self.isAlive) == true {
            let matches = activeSettings == settings
            lock.unlock()
            return matches
        }
        lock.unlock()

        guard let matchingPID = Self.findMatchingProcess(settings: settings) else { return false }
        lock.lock()
        defer { lock.unlock() }
        if ownedProcess?.isRunning == true || adoptedPID.map(Self.isAlive) == true { return activeSettings == settings }
        adoptedPID = matchingPID
        activeSettings = settings
        return Self.isAlive(matchingPID)
    }

    func start(settings: TunnelSettings, password: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard !isRunning else { completion(.failure(NSError(domain: "Coze", code: 1, userInfo: [NSLocalizedDescriptionKey: "已有 SSH 通道正在运行；请先断开再切换配置。"]))); return }
        let task = Process(); task.executableURL = URL(fileURLWithPath: sshExecutable)
        var arguments = ["-N", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3", "-o", "StrictHostKeyChecking=accept-new", "-p", String(settings.port)]
        for route in settings.routes { arguments += ["-L", "127.0.0.1:\(route.localPort):\(route.targetHost):\(route.targetPort)"] }
        if !settings.identityFile.isEmpty { arguments += ["-i", settings.identityFile] }
        arguments.append("\(settings.username)@\(settings.host)")
        task.arguments = arguments
        let output = Pipe(); task.standardError = output; task.standardOutput = output
        let failureBuffer = LockedTextBuffer()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            failureBuffer.append(data)
        }
        var environment = ProcessInfo.processInfo.environment
        var credentialResources: (script: URL, input: Pipe)?
        if !password.isEmpty {
            let script = FileManager.default.temporaryDirectory.appendingPathComponent("coze-ssh-askpass-\(UUID().uuidString)")
            let input = Pipe()
            let scriptContents = "#!/bin/sh\nIFS= read -r password\nprintf '%s\\n' \"$password\"\nunset password\n"
            guard FileManager.default.createFile(atPath: script.path, contents: Data(scriptContents.utf8), attributes: [.posixPermissions: 0o700]) else {
                completion(.failure(NSError(domain: "Coze", code: 3, userInfo: [NSLocalizedDescriptionKey: "无法创建临时 SSH 认证助手。"])))
                return
            }
            input.fileHandleForWriting.write(Data((password + "\n").utf8))
            input.fileHandleForWriting.closeFile()
            credentialResources = (script, input)
            environment["SSH_ASKPASS"] = script.path
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = "coze"
            task.standardInput = input
        }
        task.environment = environment
        task.terminationHandler = { [weak self] terminated in self?.ownedProcessDidTerminate(terminated) }

        lock.lock()
        guard !(ownedProcess?.isRunning == true || adoptedPID.map(Self.isAlive) == true) else {
            lock.unlock()
            output.fileHandleForReading.readabilityHandler = nil
            Self.removeCredentialResources((credentialResources?.script, credentialResources?.input))
            completion(.failure(NSError(domain: "Coze", code: 1, userInfo: [NSLocalizedDescriptionKey: "已有 SSH 通道正在运行；请先断开再切换配置。"])))
            return
        }
        do {
            try task.run()
            ownedProcess = task
            adoptedPID = nil
            activeSettings = settings
            askPassScript = credentialResources?.script
            passwordInput = credentialResources?.input
            outputPipe = output
            lock.unlock()
        } catch {
            lock.unlock()
            output.fileHandleForReading.readabilityHandler = nil
            Self.removeCredentialResources((credentialResources?.script, credentialResources?.input))
            completion(.failure(error))
            return
        }

        awaitForwardingReady(task: task, settings: settings, failureBuffer: failureBuffer, deadline: Date().addingTimeInterval(readinessTimeout), completion: completion)
    }

    func stop() {
        let resources = detachState(ownedOnly: false)
        resources.pipe?.fileHandleForReading.readabilityHandler = nil
        Self.removeCredentialResources((resources.script, resources.input))
        if let process = resources.process, process.isRunning { process.terminate() }
        else if let adoptedPID = resources.adoptedPID, Self.isAlive(adoptedPID) { Darwin.kill(adoptedPID, SIGTERM) }
    }

    func stopOwned() {
        let resources = detachState(ownedOnly: true)
        resources.pipe?.fileHandleForReading.readabilityHandler = nil
        Self.removeCredentialResources((resources.script, resources.input))
        if let process = resources.process, process.isRunning { process.terminate() }
    }

    private func isOwnedProcessRunning(_ task: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ownedProcess === task && task.isRunning
    }

    private func removeCredentialResources(for task: Process) {
        lock.lock()
        guard ownedProcess === task else { lock.unlock(); return }
        let resources = (askPassScript, passwordInput)
        askPassScript = nil
        passwordInput = nil
        lock.unlock()
        Self.removeCredentialResources(resources)
    }

    private func awaitForwardingReady(task: Process, settings: TunnelSettings, failureBuffer: LockedTextBuffer, deadline: Date, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            guard self.isOwnedProcessRunning(task) else {
                let failure = failureBuffer.text
                completion(.failure(NSError(domain: "Coze", code: 2, userInfo: [NSLocalizedDescriptionKey: failure.isEmpty ? "SSH 连接未能建立。请检查主机、认证方式和端口。" : failure])))
                return
            }
            if settings.routes.allSatisfy({ Self.isLoopbackPortListening($0.localPort, ownedBy: task.processIdentifier) }) {
                self.removeCredentialResources(for: task)
                completion(.success(()))
                return
            }
            guard Date() < deadline else {
                self.stopOwned()
                let failure = failureBuffer.text
                completion(.failure(NSError(domain: "Coze", code: 4, userInfo: [NSLocalizedDescriptionKey: failure.isEmpty ? "SSH 连接超时，尚未建立本地转发端口。" : failure])))
                return
            }
            self.awaitForwardingReady(task: task, settings: settings, failureBuffer: failureBuffer, deadline: deadline, completion: completion)
        }
    }

    private func ownedProcessDidTerminate(_ task: Process) {
        lock.lock()
        guard ownedProcess === task else { lock.unlock(); return }
        let resources = (askPassScript, passwordInput)
        let pipe = outputPipe
        ownedProcess = nil
        activeSettings = nil
        askPassScript = nil
        passwordInput = nil
        outputPipe = nil
        lock.unlock()
        pipe?.fileHandleForReading.readabilityHandler = nil
        Self.removeCredentialResources(resources)
    }

    private func detachState(ownedOnly: Bool) -> (process: Process?, adoptedPID: pid_t?, script: URL?, input: Pipe?, pipe: Pipe?) {
        lock.lock()
        defer { lock.unlock() }
        if ownedOnly && ownedProcess == nil { return (nil, nil, nil, nil, nil) }
        let resources = (ownedProcess, ownedOnly ? nil : adoptedPID, askPassScript, passwordInput, outputPipe)
        ownedProcess = nil
        if !ownedOnly { adoptedPID = nil }
        activeSettings = nil
        askPassScript = nil
        passwordInput = nil
        outputPipe = nil
        return resources
    }

    private func runningPID() -> pid_t? {
        lock.lock()
        if let ownedProcess, ownedProcess.isRunning {
            let pid = ownedProcess.processIdentifier
            lock.unlock()
            return pid
        }
        if let adoptedPID, Self.isAlive(adoptedPID) {
            lock.unlock()
            return adoptedPID
        }
        let resources = (askPassScript, passwordInput)
        let pipe = outputPipe
        ownedProcess = nil
        adoptedPID = nil
        activeSettings = nil
        askPassScript = nil
        passwordInput = nil
        outputPipe = nil
        lock.unlock()
        pipe?.fileHandleForReading.readabilityHandler = nil
        Self.removeCredentialResources(resources)
        return nil
    }

    private static func removeCredentialResources(_ resources: (script: URL?, input: Pipe?)) {
        resources.input?.fileHandleForReading.closeFile()
        resources.input?.fileHandleForWriting.closeFile()
        if let script = resources.script { try? FileManager.default.removeItem(at: script) }
    }

    private static func isLoopbackPortListening(_ port: Int, ownedBy processIdentifier: pid_t) -> Bool {
        guard (1...65535).contains(port) else { return false }
        let probe = Process()
        let output = Pipe()
        probe.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        probe.arguments = ["-nP", "-a", "-p", String(processIdentifier), "-iTCP@127.0.0.1:\(port)", "-sTCP:LISTEN", "-Fp"]
        probe.standardOutput = output
        probe.standardError = FileHandle.nullDevice
        do { try probe.run() } catch { return false }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        probe.waitUntilExit()
        guard probe.terminationStatus == 0 else { return false }
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).contains("p\(processIdentifier)")
    }

    private static func isAlive(_ pid: pid_t) -> Bool { Darwin.kill(pid, 0) == 0 || errno == EPERM }

    private static func findMatchingProcess(settings: TunnelSettings) -> pid_t? {
        guard !settings.host.isEmpty, !settings.username.isEmpty, !settings.routes.isEmpty else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-x", "ssh"]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        for value in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace) {
            guard let pid = pid_t(value), isAlive(pid), let arguments = processArguments(pid: pid) else { continue }
            if TunnelCommandMatcher.matches(arguments: arguments, settings: settings) { return pid }
        }
        return nil
    }

    private static func processArguments(pid: pid_t) -> [String]? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0 else { return nil }
        var index = MemoryLayout<Int32>.size
        while index < size && buffer[index] != 0 { index += 1 }
        while index < size && buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        for _ in 0..<argc {
            guard index < size else { break }
            let start = index
            while index < size && buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            while index < size && buffer[index] == 0 { index += 1 }
        }
        return arguments.count == Int(argc) ? arguments : nil
    }
}

enum LidRun {
    static func enable(hours: Int, completion: @escaping (String) -> Void) { privileged("/usr/bin/pmset -a disablesleep 1; /usr/bin/nohup /bin/sh -c 'sleep \(hours * 3600); /usr/bin/pmset -a disablesleep 0' >/dev/null 2>&1 &") { ok in completion(ok ? "Closed-lid run enabled for \(hours) hour(s). Coze will restore sleep automatically." : "Could not enable closed-lid mode.") } }
    static func disable(completion: @escaping (String) -> Void) { privileged("/usr/bin/pmset -a disablesleep 0") { completion($0 ? "Normal sleep behavior restored." : "Could not restore sleep behavior.") } }
    private static func privileged(_ command: String, completion: @escaping (Bool) -> Void) { DispatchQueue.global(qos: .userInitiated).async { let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript"); p.arguments = ["-e", "do shell script \"\(command.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"]; do { try p.run(); p.waitUntilExit(); completion(p.terminationStatus == 0) } catch { completion(false) } } }
}
