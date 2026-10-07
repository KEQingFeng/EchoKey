// EchoKey — 菜单栏常驻应用：把有线 EarPods 线控按键映射成快捷键 / 动作
//
// 打开后常驻顶栏（菜单栏），点图标可开关映射、打开设置窗口、查看按键测试、开机自启、退出。
// 配置保存在 ~/.config/echokey/config.json（兼容 Karabiner complex_modifications 格式）。

import Cocoa
import CoreGraphics
import ApplicationServices
import IOKit
import IOKit.hid

// MARK: - 调试日志（写文件，无需截图即可排障）

let debugLogPath = NSString(string: "~/.config/echokey/debug.log").expandingTildeInPath

func hkLog(_ s: String) {
    let fmt = DateFormatter()
    fmt.dateFormat = "HH:mm:ss.SSS"
    let line = "[\(fmt.string(from: Date()))] \(s)\n"
    let dir = (debugLogPath as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    if let fh = FileHandle(forWritingAtPath: debugLogPath) {
        fh.seekToEndOfFile()
        if let d = line.data(using: .utf8) { fh.write(d) }
        fh.closeFile()
    } else {
        try? line.write(toFile: debugLogPath, atomically: true, encoding: .utf8)
    }
}

// MARK: - 媒体键编号

enum NXKey: Int {
    case soundUp = 0, soundDown = 1, mute = 7
    case play = 16, next = 17, previous = 18, fast = 19, rewind = 20
}

let consumerToNX: [String: NXKey] = [
    "play_or_pause": .play,
    "scan_next_track": .next,
    "scan_previous_track": .previous,
    "volume_increment": .soundUp,
    "volume_decrement": .soundDown,
    "mute": .mute,
    "fast_forward": .fast,
    "rewind": .rewind,
]

func nxName(_ key: Int) -> String {
    switch key {
    case 0: return "volume_increment"
    case 1: return "volume_decrement"
    case 7: return "mute"
    case 16: return "play_or_pause"
    case 17: return "scan_next_track"
    case 18: return "scan_previous_track"
    case 19: return "fast_forward"
    case 20: return "rewind"
    default: return "unknown(\(key))"
    }
}

/// HID Consumer UsagePage(0x0C) 的 usage 编号 → 内部 consumer_key_code。
/// EarPods 作为 USB HID 设备时，音量键以 Consumer 用法上报，不走 NX 媒体键通道。
func consumerKeyForUsage(_ usage: Int) -> String? {
    switch usage {
    case 0xE9: return "volume_increment"   // 233 Volume Increment
    case 0xEA: return "volume_decrement"   // 234 Volume Decrement
    case 0xE2: return "mute"               // 226 Mute
    case 0xCD: return "play_or_pause"      // 205 Play/Pause
    case 0xB5: return "scan_next_track"    // 181 Scan Next Track
    case 0xB6: return "scan_previous_track" // 182 Scan Previous Track
    case 0xB3: return "fast_forward"       // 179 Fast Forward
    case 0xB4: return "rewind"             // 180 Rewind
    default: return nil
    }
}

// MARK: - 键名 <-> 键码

let keyTable: [(String, CGKeyCode)] = [
    ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7),
    ("c", 8), ("v", 9), ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15),
    ("y", 16), ("t", 17), ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("6", 22),
    ("5", 23), ("equal_sign", 24), ("9", 25), ("7", 26), ("hyphen", 27), ("8", 28),
    ("0", 29), ("right_bracket", 30), ("o", 31), ("u", 32), ("left_bracket", 33),
    ("i", 34), ("p", 35), ("l", 37), ("j", 38), ("quote", 39), ("k", 40),
    ("semicolon", 41), ("backslash", 42), ("comma", 43), ("slash", 44), ("n", 45),
    ("m", 46), ("period", 47), ("tab", 48), ("spacebar", 49), ("grave_accent_and_tilde", 50),
    ("delete_or_backspace", 51), ("escape", 53), ("return_or_enter", 36),
    ("left_arrow", 123), ("right_arrow", 124), ("down_arrow", 125), ("up_arrow", 126),
    ("home", 115), ("end", 119), ("page_up", 116), ("page_down", 121), ("forward_delete", 117),
    ("f1", 122), ("f2", 120), ("f3", 99), ("f4", 118), ("f5", 96), ("f6", 97),
    ("f7", 98), ("f8", 100), ("f9", 101), ("f10", 109), ("f11", 103), ("f12", 111),
    ("fn", 63),
]

var nameToCode: [String: CGKeyCode] = [:]
var codeToName: [CGKeyCode: String] = [:]
for (n, c) in keyTable {
    if nameToCode[n] == nil { nameToCode[n] = c }
    if codeToName[c] == nil { codeToName[c] = n }
}

func keyDisplayName(_ name: String) -> String {
    switch name {
    case "up_arrow": return "↑"
    case "down_arrow": return "↓"
    case "left_arrow": return "←"
    case "right_arrow": return "→"
    case "spacebar": return "空格"
    case "return_or_enter": return "↩"
    case "escape": return "⎋"
    case "tab": return "⇥"
    case "delete_or_backspace": return "⌫"
    case "forward_delete": return "⌦"
    case "home": return "↖"
    case "end": return "↘"
    case "page_up": return "⇞"
    case "page_down": return "⇟"
    default: return name.count == 1 ? name.uppercased() : name
    }
}

func modifierName(for flag: CGEventFlags) -> String? {
    if flag == .maskControl { return "left_control" }
    if flag == .maskAlternate { return "left_option" }
    if flag == .maskShift { return "left_shift" }
    if flag == .maskCommand { return "left_command" }
    if flag == .maskSecondaryFn { return "fn" }
    return nil
}

func flag(for modifier: String) -> CGEventFlags? {
    switch modifier {
    case "left_control", "right_control", "control": return .maskControl
    case "left_shift", "right_shift", "shift": return .maskShift
    case "left_command", "right_command", "command": return .maskCommand
    case "left_option", "right_option", "option", "alt": return .maskAlternate
    case "fn": return .maskSecondaryFn
    default: return nil
    }
}

func shortcutDisplay(keyCode: CGKeyCode, flags: CGEventFlags) -> String {
    var s = ""
    if flags.contains(.maskControl) { s += "⌃" }
    if flags.contains(.maskAlternate) { s += "⌥" }
    if flags.contains(.maskShift) { s += "⇧" }
    if flags.contains(.maskCommand) { s += "⌘" }
    s += keyDisplayName(codeToName[keyCode] ?? "?")
    return s
}

// MARK: - 动作模型

enum ActionKind: String {
    case key, open, shell
    var label: String {
        switch self {
        case .key: return "快捷键"
        case .open: return "打开 App / 网址"
        case .shell: return "运行命令"
        }
    }
}

struct Rule {
    var consumerKey: String        // play_or_pause / scan_next_track / scan_previous_track
    var description: String
    var kind: ActionKind
    var keyCode: CGKeyCode?
    var flags: CGEventFlags = []
    var text: String = ""          // open 目标 / shell 命令
}

struct Config {
    var title = "EchoKey"
    var swallowOriginal = true
    var rules: [Rule] = []
}

// MARK: - 配置读写

let configPath = NSString(string: "~/.config/echokey/config.json").expandingTildeInPath

func defaultRules() -> [Rule] {
    [
        Rule(consumerKey: "play_or_pause", description: "中键单击 → 调度中心",
             kind: .key, keyCode: nameToCode["up_arrow"], flags: [.maskControl]),
        Rule(consumerKey: "scan_next_track", description: "中键双击 → App 窗口",
             kind: .key, keyCode: nameToCode["down_arrow"], flags: [.maskControl]),
        Rule(consumerKey: "scan_previous_track", description: "中键三击 → 区域截图",
             kind: .key, keyCode: nameToCode["4"], flags: [.maskCommand, .maskShift]),
        Rule(consumerKey: "volume_increment", description: "音量＋ → Fn",
             kind: .key, keyCode: nameToCode["fn"], flags: [.maskSecondaryFn]),
        Rule(consumerKey: "volume_decrement", description: "音量－ → Enter",
             kind: .key, keyCode: nameToCode["return_or_enter"], flags: []),
    ]
}

func loadConfig() -> Config {
    var cfg = Config()
    guard let data = FileManager.default.contents(atPath: configPath),
          let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        cfg.rules = defaultRules()
        return cfg
    }
    if let t = root["title"] as? String { cfg.title = t }
    if let s = root["swallow_original"] as? Bool { cfg.swallowOriginal = s }

    var rawRules: [[String: Any]] = []
    if let rules = root["rules"] as? [[String: Any]] {
        for rule in rules {
            if let mans = rule["manipulators"] as? [[String: Any]] {
                for m in mans {
                    var mm = m
                    if mm["description"] == nil, let d = rule["description"] as? String { mm["description"] = d }
                    rawRules.append(mm)
                }
            } else if rule["from"] != nil {
                rawRules.append(rule)
            }
        }
    }
    if let maps = root["mappings"] as? [[String: Any]] { rawRules.append(contentsOf: maps) }

    for m in rawRules {
        guard let from = m["from"] as? [String: Any],
              let ck = from["consumer_key_code"] as? String,
              consumerToNX[ck] != nil else { continue }
        let desc = (m["description"] as? String) ?? ck
        guard let toArr = m["to"] as? [[String: Any]], let to = toArr.first else { continue }
        if let kc = to["key_code"] as? String, let code = nameToCode[kc] {
            var flags: CGEventFlags = []
            for mod in (to["modifiers"] as? [String] ?? []) { if let f = flag(for: mod) { flags.insert(f) } }
            cfg.rules.append(Rule(consumerKey: ck, description: desc, kind: .key,
                                  keyCode: code, flags: flags))
        } else if let sh = to["shell_command"] as? String {
            cfg.rules.append(Rule(consumerKey: ck, description: desc, kind: .shell, text: sh))
        } else if let op = to["open"] as? String {
            cfg.rules.append(Rule(consumerKey: ck, description: desc, kind: .open, text: op))
        }
    }
    if cfg.rules.isEmpty { cfg.rules = defaultRules() }
    return cfg
}

func saveConfig(_ cfg: Config) {
    var rules: [[String: Any]] = []
    for r in cfg.rules {
        var to: [String: Any] = [:]
        switch r.kind {
        case .key:
            guard let code = r.keyCode, let name = codeToName[code] else { continue }
            to["key_code"] = name
            var mods: [String] = []
            for f in [CGEventFlags.maskControl, .maskAlternate, .maskShift, .maskCommand, .maskSecondaryFn] {
                if r.flags.contains(f), let n = modifierName(for: f) { mods.append(n) }
            }
            if !mods.isEmpty { to["modifiers"] = mods }
        case .open:
            to["open"] = r.text
        case .shell:
            to["shell_command"] = r.text
        }
        rules.append([
            "description": r.description,
            "manipulators": [[
                "type": "basic",
                "from": ["consumer_key_code": r.consumerKey],
                "to": [to],
            ]],
        ])
    }
    let root: [String: Any] = [
        "title": cfg.title,
        "swallow_original": cfg.swallowOriginal,
        "rules": rules,
    ]
    let dir = (configPath as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    if let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: URL(fileURLWithPath: configPath))
    }
}

// MARK: - 动作派发

func postKey(_ code: CGKeyCode, flags: CGEventFlags) {
    let src = CGEventSource(stateID: .hidSystemState)
    if let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true) {
        down.flags = flags; down.post(tap: .cghidEventTap)
    }
    if let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false) {
        up.flags = flags; up.post(tap: .cghidEventTap)
    }
}

func runShell(_ command: String) {
    DispatchQueue.global().async {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", command]
        try? p.run()
    }
}

func openTarget(_ target: String) {
    if target.contains("://"), let url = URL(string: target) {
        NSWorkspace.shared.open(url)
    } else {
        NSWorkspace.shared.open(URL(fileURLWithPath: (target as NSString).expandingTildeInPath))
    }
}

// MARK: - 事件监听（C 回调）

var gDelegate: AppDelegate!

let eventTapCallback: CGEventTapCallBack = { _, type, event, _ in
    // 系统可能因回调超时或用户输入而临时停用事件监听；这里立即重新启用，
    // 否则后续媒体键将不再经过监听、无法拦截（表现为「按中键启动音乐」）。
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        gDelegate?.reenableEventTap(reason: type == .tapDisabledByTimeout ? "回调超时" : "用户输入")
        return Unmanaged.passUnretained(event)
    }
    guard type.rawValue == 14, let nse = NSEvent(cgEvent: event), nse.subtype.rawValue == 8 else {
        return Unmanaged.passUnretained(event)
    }
    let data1 = nse.data1
    let keyType = Int((data1 >> 16) & 0xFFFF)
    let isDown = (Int((data1 >> 8) & 0xFF) == 0x0A)
    let swallow = gDelegate?.dispatch(consumerKey: nxName(keyType), isDown: isDown, source: "tap") ?? false
    return swallow ? nil : Unmanaged.passUnretained(event)
}

let hidDeviceMatchingCallback: IOHIDDeviceCallback = { context, _, _, device in
    guard let context = context else { return }
    Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue().hidDeviceMatched(device)
}

let hidInputValueCallback: IOHIDValueCallback = { context, _, _, value in
    guard let context = context else { return }
    Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue().hidValueReceived(value)
}

// MARK: - 快捷键录制控件

final class ShortcutField: NSTextField {
    var capturedCode: CGKeyCode?
    var capturedFlags: CGEventFlags = []
    var onChange: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { stringValue = "按下快捷键…"; textColor = .secondaryLabelColor }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        renderValue()
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        capture(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder == self { capture(event); return true }
        return super.performKeyEquivalent(with: event)
    }

    private func capture(_ event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc 清除
            capturedCode = nil; capturedFlags = []; renderValue(); onChange?(); return
        case 36, 76: // Return / Enter 结束录制（不当作快捷键）
            window?.makeFirstResponder(nil); return
        case 48: // Tab 正常切焦点
            window?.selectKeyView(following: self); return
        default: break
        }
        let chars = event.charactersIgnoringModifiers ?? ""
        if chars.isEmpty { return } // 只按了修饰键
        capturedCode = event.keyCode
        var f: CGEventFlags = []
        let m = event.modifierFlags
        if m.contains(.control) { f.insert(.maskControl) }
        if m.contains(.option) { f.insert(.maskAlternate) }
        if m.contains(.shift) { f.insert(.maskShift) }
        if m.contains(.command) { f.insert(.maskCommand) }
        if m.contains(.function) { f.insert(.maskSecondaryFn) }
        capturedFlags = f
        renderValue()
        onChange?()
    }

    func renderValue() {
        if let code = capturedCode {
            stringValue = shortcutDisplay(keyCode: code, flags: capturedFlags)
            textColor = .labelColor
        } else {
            stringValue = "未设置"
            textColor = .secondaryLabelColor
        }
    }

    /// 玻璃胶囊外观。layer 的 CGColor 不会随系统深浅色自动变，必须手动重刷。
    func refreshPill() {
        guard let layer = layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = self.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            layer.backgroundColor = (dark ? NSColor.white.withAlphaComponent(0.08)
                                          : NSColor.white.withAlphaComponent(0.78)).cgColor
            layer.borderColor = (dark ? NSColor.white.withAlphaComponent(0.16)
                                      : NSColor.black.withAlphaComponent(0.10)).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshPill()
    }
}

// MARK: - 视觉组件（毛玻璃）

/// 把窗口内容视图换成铺满全窗的毛玻璃，并让标题栏透明、内容延伸到标题栏下方。
func installVibrantBacking(_ window: NSWindow, material: NSVisualEffectView.Material = .underWindowBackground) {
    window.styleMask.insert(.fullSizeContentView)
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isMovableByWindowBackground = true

    let effect = NSVisualEffectView(frame: window.contentView?.bounds ?? .zero)
    effect.material = material
    effect.blendingMode = .behindWindow
    effect.state = .followsWindowActiveState
    effect.autoresizingMask = [.width, .height]
    window.contentView = effect
}

/// 半透明磨砂卡片。深浅色切换时靠 viewDidChangeEffectiveAppearance 自动重刷。
class GlassCard: NSView {
    var radius: CGFloat = 10 { didSet { layer?.cornerRadius = radius } }
    /// true = 强调色淡底（用于图标块）；false = 中性磨砂底（用于规则卡片）
    var accent = false { didSet { refreshGlass() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        refreshGlass()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshGlass()
    }

    func refreshGlass() {
        guard let layer = layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = self.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            if self.accent {
                layer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(dark ? 0.28 : 0.16).cgColor
                layer.borderColor = NSColor.controlAccentColor.withAlphaComponent(dark ? 0.45 : 0.28).cgColor
            } else {
                layer.backgroundColor = (dark ? NSColor.white.withAlphaComponent(0.06)
                                              : NSColor.white.withAlphaComponent(0.64)).cgColor
                layer.borderColor = (dark ? NSColor.white.withAlphaComponent(0.10)
                                          : NSColor.black.withAlphaComponent(0.07)).cgColor
            }
            layer.cornerRadius = self.radius
            layer.borderWidth = 1
        }
    }
}

/// 小圆点：用来表示单击 / 双击 / 三击的次数。
final class Dot: NSView {
    init(size: CGFloat = 6) {
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
        layer?.cornerRadius = size / 2
        layer?.backgroundColor = NSColor.controlAccentColor.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// 翻转坐标系：NSScrollView 的 documentView 默认原点在左下，未翻转时内容会贴着底部。
/// 规则列表必须从顶部往下排，所以用这个当 documentView。
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - 设置窗口

final class SettingsWindowController: NSObject {
    let window: NSWindow
    private var rowsStack: NSStackView!
    private var rowViews: [RuleRowView] = []
    private var emptyHint: GlassCard?
    private var footNote: NSTextField!

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 470),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "EchoKey 设置"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 400)
        window.center()
        super.init()
        installVibrantBacking(window)
        buildUI()
        reload()
    }

    private func buildUI() {
        guard let content = window.contentView else { return }

        // ── 头部：图标块 + 标题 / 副标题
        let tile = GlassCard()
        tile.accent = true
        tile.radius = 11
        tile.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "headphones", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(icon)

        let title = NSTextField(labelWithString: "EchoKey 设置")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        let hint = NSTextField(labelWithString: "插上 EarPods，按下线控键即可触发对应动作；改完点「保存」。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let titleBox = NSStackView(views: [title, hint])
        titleBox.orientation = .vertical
        titleBox.alignment = .leading
        titleBox.spacing = 1
        titleBox.translatesAutoresizingMaskIntoConstraints = false

        // ── 规则列表
        rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 8
        rowsStack.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(rowsStack)
        NSLayoutConstraint.activate([
            rowsStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            rowsStack.topAnchor.constraint(equalTo: doc.topAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = doc
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([doc.widthAnchor.constraint(equalTo: scroll.widthAnchor)])

        // ── 底部：左侧信息 + 右侧按钮
        let note = NSTextField(labelWithString: "")
        note.font = .systemFont(ofSize: 10.5)
        note.textColor = .tertiaryLabelColor
        note.lineBreakMode = .byTruncatingMiddle
        note.translatesAutoresizingMaskIntoConstraints = false
        self.footNote = note

        let addBtn = NSButton(title: "＋ 添加规则", target: self, action: #selector(addRow))
        addBtn.bezelStyle = .rounded
        let resetBtn = NSButton(title: "恢复默认", target: self, action: #selector(resetRows))
        resetBtn.bezelStyle = .rounded
        let saveBtn = NSButton(title: "保存", target: self, action: #selector(save))
        saveBtn.bezelStyle = .rounded
        saveBtn.bezelColor = .controlAccentColor
        saveBtn.keyEquivalent = "\r"

        let buttons = NSStackView(views: [addBtn, resetBtn, saveBtn])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(tile)
        content.addSubview(titleBox)
        content.addSubview(scroll)
        content.addSubview(note)
        content.addSubview(buttons)

        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            tile.topAnchor.constraint(equalTo: content.topAnchor, constant: 44),
            tile.widthAnchor.constraint(equalToConstant: 38),
            tile.heightAnchor.constraint(equalToConstant: 38),

            icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor),

            titleBox.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 12),
            titleBox.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            titleBox.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),

            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: tile.bottomAnchor, constant: 16),
            scroll.bottomAnchor.constraint(equalTo: note.topAnchor, constant: -10),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),

            note.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            note.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            note.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -12),

            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.centerYAnchor.constraint(equalTo: note.centerYAnchor),
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    func reload() {
        for v in rowViews { rowsStack.removeArrangedSubview(v); v.removeFromSuperview() }
        rowViews.removeAll()
        emptyHint?.removeFromSuperview()
        emptyHint = nil
        for r in AppState.config.rules { addRowView(r) }
        if rowViews.isEmpty { showEmptyHint() }
        updateFootnote()
    }

    /// 规则全删光时给一张占位卡，避免窗口只剩大片空白。
    private func showEmptyHint() {
        let box = GlassCard()
        box.radius = 12
        box.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "还没有规则。点右下角「＋ 添加规则」新建一条。")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)

        let row = rowsStack!
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: box.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -16),
            box.heightAnchor.constraint(equalToConstant: 66),
        ])
        row.addArrangedSubview(box)
        box.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        emptyHint = box
    }

    private func updateFootnote() {
        let n = rowViews.count
        footNote.stringValue = "\(n) 条规则 · \((configPath as NSString).abbreviatingWithTildeInPath)"
    }

    private func addRowView(_ rule: Rule) {
        let row = RuleRowView(rule: rule)
        row.onRemove = { [weak self, weak row] in
            guard let self, let row else { return }
            self.rowViews.removeAll { $0 === row }
            self.rowsStack.removeArrangedSubview(row)
            row.removeFromSuperview()
            self.updateFootnote()
        }
        rowViews.append(row)
        rowsStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
    }

    @objc private func addRow() {
        addRowView(Rule(consumerKey: "play_or_pause", description: "新规则",
                        kind: .key, keyCode: nameToCode["spacebar"], flags: []))
        updateFootnote()
    }

    @objc private func resetRows() {
        AppState.config.rules = defaultRules()
        reload()
    }

    @objc private func save() {
        AppState.config.rules = rowViews.map { $0.toRule() }
        saveConfig(AppState.config)
        AppState.reloadRules()
        Toast.show("已保存")
    }
}

final class RuleRowView: GlassCard {
    private let triggerPopup = NSPopUpButton()
    private let kindPopup = NSPopUpButton()
    private let paramContainer = NSView()
    private let dots = NSStackView()
    private var shortcutField: ShortcutField?
    private var textField: NSTextField?
    private var currentKind: ActionKind
    /// 删除时回调控制器，保证 rowViews 与界面同步（否则删掉的规则保存时会被写回）。
    var onRemove: (() -> Void)?

    private let triggers: [(String, String)] = [
        ("单击（中键）", "play_or_pause"),
        ("双击", "scan_next_track"),
        ("三击", "scan_previous_track"),
        ("音量＋", "volume_increment"),
        ("音量－", "volume_decrement"),
    ]

    init(rule: Rule) {
        currentKind = rule.kind
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        radius = 12

        // 圆点：直观表示单击 / 双击 / 三击
        dots.orientation = .horizontal
        dots.spacing = 3
        dots.alignment = .centerY
        dots.translatesAutoresizingMaskIntoConstraints = false
        dots.setContentHuggingPriority(.required, for: .horizontal)
        dots.widthAnchor.constraint(equalToConstant: 28).isActive = true

        for t in triggers { triggerPopup.addItem(withTitle: t.0) }
        if let idx = triggers.firstIndex(where: { $0.1 == rule.consumerKey }) { triggerPopup.selectItem(at: idx) }
        triggerPopup.target = self
        triggerPopup.action = #selector(triggerChanged)

        for k in [ActionKind.key, .open, .shell] { kindPopup.addItem(withTitle: k.label) }
        if let idx = [ActionKind.key, .open, .shell].firstIndex(of: rule.kind) { kindPopup.selectItem(at: idx) }
        kindPopup.target = self
        kindPopup.action = #selector(kindChanged)

        let arrow = NSTextField(labelWithString: "→")
        arrow.font = .systemFont(ofSize: 12, weight: .medium)
        arrow.textColor = .tertiaryLabelColor
        arrow.setContentHuggingPriority(.required, for: .horizontal)

        paramContainer.translatesAutoresizingMaskIntoConstraints = false
        paramContainer.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        // 弹性空隙：把删除按钮顶到最右侧
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let trashBtn = NSButton()
        trashBtn.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "删除规则")
        trashBtn.image?.isTemplate = true
        trashBtn.isBordered = false
        trashBtn.bezelStyle = .inline
        trashBtn.contentTintColor = .secondaryLabelColor
        trashBtn.target = self
        trashBtn.action = #selector(removeSelf)
        trashBtn.toolTip = "删除这条规则"
        trashBtn.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [dots, triggerPopup, arrow, kindPopup, paramContainer, spacer, trashBtn])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            trashBtn.widthAnchor.constraint(equalToConstant: 22),
            trashBtn.heightAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 46),
        ])

        refreshDots()
        setParamView(rule)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func refreshDots() {
        for v in dots.arrangedSubviews { dots.removeArrangedSubview(v); v.removeFromSuperview() }
        // 圆点表示「点击次数」：音量键没有点击次数的概念，不留圆点。
        let key = triggers[triggerPopup.indexOfSelectedItem].1
        let count: Int
        switch key {
        case "play_or_pause": count = 1
        case "scan_next_track": count = 2
        case "scan_previous_track": count = 3
        default: count = 0
        }
        for _ in 0..<count { dots.addArrangedSubview(Dot()) }
    }

    @objc private func triggerChanged() {
        refreshDots()
    }

    private func setParamView(_ rule: Rule) {
        paramContainer.subviews.forEach { $0.removeFromSuperview() }
        shortcutField = nil
        textField = nil

        let view: NSView
        switch currentKind {
        case .key:
            let f = ShortcutField()
            // 必须不可编辑：可编辑的 NSTextField 会把按键交给共享字段编辑器，
            // 绕过 ShortcutField.keyDown → 录制失效（已实测确认）。
            f.isEditable = false
            f.isSelectable = false
            f.isBezeled = false
            f.drawsBackground = false
            f.alignment = .center
            f.font = .monospacedSystemFont(ofSize: 12.5, weight: .medium)
            f.wantsLayer = true
            f.layer?.cornerRadius = 8
            f.layer?.borderWidth = 1
            f.layer?.masksToBounds = true
            f.capturedCode = rule.keyCode
            f.capturedFlags = rule.flags
            f.renderValue()
            f.translatesAutoresizingMaskIntoConstraints = false
            f.heightAnchor.constraint(equalToConstant: 26).isActive = true
            f.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
            f.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            shortcutField = f
            view = f
        case .open:
            let f = NSTextField()
            f.placeholderString = "App 路径 或 https://网址"
            f.stringValue = rule.text
            f.font = .systemFont(ofSize: 12.5)
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
            f.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            textField = f
            view = f
        case .shell:
            let f = NSTextField()
            f.placeholderString = "例如：say hello"
            f.stringValue = rule.text
            f.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
            f.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            textField = f
            view = f
        }
        paramContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: paramContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: paramContainer.trailingAnchor),
            view.topAnchor.constraint(equalTo: paramContainer.topAnchor),
            view.bottomAnchor.constraint(equalTo: paramContainer.bottomAnchor),
        ])
        // 玻璃胶囊的底色是 CGColor，不会随系统深浅色自动更新，需手动刷一次。
        (view as? ShortcutField)?.refreshPill()
    }

    @objc private func kindChanged() {
        let kinds = [ActionKind.key, .open, .shell]
        currentKind = kinds[kindPopup.indexOfSelectedItem]
        setParamView(Rule(consumerKey: "", description: "", kind: currentKind))
    }

    @objc private func removeSelf() {
        onRemove?()
    }

    func toRule() -> Rule {
        let consumerKey = triggers[triggerPopup.indexOfSelectedItem].1
        let kind = [ActionKind.key, .open, .shell][kindPopup.indexOfSelectedItem]
        var r = Rule(consumerKey: consumerKey, description: "", kind: kind)
        r.keyCode = shortcutField?.capturedCode
        r.flags = shortcutField?.capturedFlags ?? []
        r.text = textField?.stringValue ?? ""
        var trig = "中键"
        switch consumerKey {
        case "play_or_pause": trig = "单击"
        case "scan_next_track": trig = "双击"
        case "scan_previous_track": trig = "三击"
        case "volume_increment": trig = "音量＋"
        case "volume_decrement": trig = "音量－"
        default: break
        }
        switch kind {
        case .key:
            let d = r.keyCode != nil ? shortcutDisplay(keyCode: r.keyCode!, flags: r.flags) : "未设置"
            r.description = "\(trig) → \(d)"
        case .open:
            r.description = "\(trig) → 打开 \(r.text)"
        case .shell:
            r.description = "\(trig) → 命令 \(r.text)"
        }
        return r
    }
}

// MARK: - 按键测试窗口

final class LogWindowController: NSObject {
    let window: NSWindow
    private let textView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var lines: [String] = []
    private var eventCount = 0

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
                          styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "EchoKey 按键测试"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 400, height: 240)
        window.center()
        super.init()
        installVibrantBacking(window)

        guard let content = window.contentView else { return }

        let title = NSTextField(labelWithString: "按键测试")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(title)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(statusLabel)
        updateStatus()

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        // NSTextView 当 NSScrollView 的 documentView 时，必须给非零初始 frame，并设好
        // minSize/maxSize + 只垂直伸缩 + 容器宽度跟随，否则文本不换行、整窗空白（改版踩过）。
        textView.frame = NSRect(x: 0, y: 0, width: 448, height: 260)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 448, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        content.addSubview(scroll)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 44),

            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            statusLabel.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 12),

            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])

        append("插上 EarPods，按下线控键，这里会显示收到的事件。")
        append("中键走系统媒体键通道；音量＋/－走 HID Consumer 通道。")
        append(String(repeating: "─", count: 40))
        if !AXIsProcessTrusted() || IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            append("⚠️ 权限未授权：监听无法工作。")
            append("请到「系统设置 → 隐私与安全性 → 辅助功能 / 输入监控」")
            append("勾选 EchoKey，然后退出并重新打开本应用。")
            append(String(repeating: "─", count: 40))
        }
    }

    /// 常驻的「监听状态」指示：绿点 + 已收到的事件数（即用户所说的接听/监听状态）。
    private func updateStatus() {
        let s = NSMutableAttributedString(string: "● ", attributes: [
            .foregroundColor: NSColor.systemGreen,
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
        ])
        s.append(NSAttributedString(string: "监听中 · 已接收 \(eventCount) 个事件", attributes: [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
        ]))
        statusLabel.attributedStringValue = s
    }

    func append(_ s: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        lines.append("[\(ts)] \(s)")
        if lines.count > 500 { lines.removeFirst(100) }
        if s.hasPrefix("↓") { eventCount += 1; updateStatus() }
        textView.string = lines.joined(separator: "\n")
        textView.scrollToEndOfDocument(nil)
    }
}

// MARK: - 轻提示

enum Toast {
    static func show(_ message: String) {
        guard let screen = NSScreen.main else { return }

        let label = NSTextField(labelWithString: message)
        label.alignment = .center
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.sizeToFit()

        let width = min(max(ceil(label.frame.width) + 48, 140), 460)
        let height: CGFloat = 46

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                         styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .floating
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true

        // HUD 毛玻璃；.popover 材质会跟随系统深浅色，labelColor 始终有对比度。
        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        effect.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: effect.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(lessThanOrEqualTo: effect.trailingAnchor, constant: -20),
        ])
        w.contentView = effect

        let f = screen.visibleFrame
        w.setFrameOrigin(NSPoint(x: f.midX - width / 2, y: f.maxY - 140))
        w.alphaValue = 0
        w.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2; w.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3; w.animator().alphaValue = 0
            }, completionHandler: { w.orderOut(nil) })
        }
    }
}

// MARK: - 应用状态

enum AppState {
    static var config = Config()
    static var enabled = true
    static var rules: [Rule] = []
    static var swallow = true

    static func reloadRules() {
        rules = config.rules
        swallow = config.swallowOriginal
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWC: SettingsWindowController?
    private var logWC: LogWindowController?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var healthTimer: Timer?
    private var hidManager: IOHIDManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppState.config = loadConfig()
        AppState.reloadRules()

        hkLog("===== EchoKey 启动 =====")
        let axTrusted = AXIsProcessTrusted()
        let hidAccess = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        hkLog("辅助功能已授权：\(axTrusted)；输入监控权限：\(hidAccess)（0=已授权 1=被拒 2=未知）")
        if !axTrusted || hidAccess != kIOHIDAccessTypeGranted {
            hkLog("⚠️ 权限缺失：请在「系统设置 → 隐私与安全性 → 辅助功能 / 输入监控」中勾选 EchoKey")
        }
        hkLog("已加载规则 \(AppState.rules.count) 条：\(AppState.rules.map { $0.consumerKey }.joined(separator: ", "))")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "headphones", accessibilityDescription: "EchoKey")
            btn.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        installEventTap()
        installHIDManager()
        requestAccessibility()

        // 周期自检：权限在运行中被授予后（无需重启）自动补建事件监听。
        healthTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.ensureEventTapHealthy()
        }
    }

    /// tap 被系统停用（超时/用户输入）时立即重新启用。
    func reenableEventTap(reason: String) {
        guard let tap = eventTap else {
            hkLog("事件监听：收到停用（\(reason)），tap 为空，尝试重建")
            installEventTap()
            return
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        hkLog("事件监听：被系统停用（\(reason)），已重新启用")
    }

    /// 权限就绪但监听缺失时自动补建，避免「授权后必须重启 App 才生效」。
    private func ensureEventTapHealthy() {
        guard AXIsProcessTrusted() else { return }
        if eventTap == nil {
            hkLog("事件监听：检测到权限已就绪且监听缺失，自动创建")
            installEventTap()
        }
    }

    // 菜单每次打开时重建，保证状态最新
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: "EchoKey", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let enabledItem = NSMenuItem(title: "启用映射", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        enabledItem.state = AppState.enabled ? .on : .off
        menu.addItem(enabledItem)

        let swallowItem = NSMenuItem(title: "拦截原始按键", action: #selector(toggleSwallow), keyEquivalent: "")
        swallowItem.target = self
        swallowItem.state = AppState.swallow ? .on : .off
        menu.addItem(swallowItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let testItem = NSMenuItem(title: "按键测试…", action: #selector(openTest), keyEquivalent: "")
        testItem.target = self
        menu.addItem(testItem)

        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "开机自动启动", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = isLoginEnabled() ? .on : .off
        menu.addItem(loginItem)

        let aboutItem = NSMenuItem(title: "关于 EchoKey", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 EchoKey", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: 事件处理

    /// 同一 consumerKey 的重复触发防抖窗口（秒）：tap 与 HID 两条通道
    /// 可能同时收到同一次按键，去重避免动作触发两次。
    private var lastFire: [String: Date] = [:]

    @discardableResult
    func dispatch(consumerKey: String, isDown: Bool, source: String) -> Bool {
        if let log = logWC { log.append("\(isDown ? "↓" : "↑") \(consumerKey) [\(source)]") }
        hkLog("事件 \(isDown ? "↓" : "↑") \(consumerKey) 来源=\(source)")
        guard isDown, AppState.enabled else { return false }

        let now = Date()
        if let last = lastFire[consumerKey], now.timeIntervalSince(last) < 0.25 {
            hkLog("  去重：\(consumerKey) 250ms 内重复，忽略")
            return AppState.swallow
        }
        lastFire[consumerKey] = now

        guard let rule = AppState.rules.first(where: { $0.consumerKey == consumerKey }) else {
            hkLog("  无匹配规则：\(consumerKey)")
            return false
        }
        switch rule.kind {
        case .key:
            if let code = rule.keyCode { postKey(code, flags: rule.flags) }
        case .open:
            openTarget(rule.text)
        case .shell:
            runShell(rule.text)
        }
        if let log = logWC { log.append("  → 触发：\(rule.description)") }
        hkLog("  触发：\(rule.description)")
        return AppState.swallow
    }

    // MARK: HID 监听（Consumer UsagePage 0x0C，覆盖 EarPods 音量键）

    func hidDeviceMatched(_ device: IOHIDDevice) {
        let vid = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int) ?? 0
        let pid = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? 0
        let product = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "?"
        hkLog("HID 设备匹配：\(product) VID=\(String(format: "0x%04x", vid)) PID=\(String(format: "0x%04x", pid))")
    }

    func hidValueReceived(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = Int(IOHIDElementGetUsagePage(element))
        let usage = Int(IOHIDElementGetUsage(element))
        let intValue = Int(IOHIDValueGetIntegerValue(value))
        let dev = IOHIDElementGetDevice(element)
        let dvid = (IOHIDDeviceGetProperty(dev, kIOHIDVendorIDKey as CFString) as? Int) ?? 0
        let dpid = (IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int) ?? 0
        hkLog("HID 值：page=0x\(String(usagePage, radix: 16)) usage=0x\(String(usage, radix: 16)) value=\(intValue) dev=\(String(format: "%04x:%04x", dvid, dpid))")
        guard usagePage == 0x0C, let key = consumerKeyForUsage(usage) else { return }
        // Consumer 用法：value != 0 视为按下。
        _ = dispatch(consumerKey: key, isDown: intValue != 0, source: "hid")
    }

    private func installHIDManager() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDDeviceUsagePageKey: 0x0C, // Consumer
            kIOHIDDeviceUsageKey: 0x01,     // Consumer Control
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, hidDeviceMatchingCallback, ctx)
        IOHIDManagerRegisterInputValueCallback(manager, hidInputValueCallback, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        let ok = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        hidManager = manager
        if ok == kIOReturnSuccess {
            hkLog("HID：管理器已打开（匹配 Consumer Control 设备）")
        } else {
            hkLog("HID：IOHIDManagerOpen 失败 code=0x\(String(UInt32(bitPattern: ok), radix: 16))")
        }
    }

    private func installEventTap() {
        if let tap = eventTap {
            // 已存在则确保启用，避免重复创建（重复创建会叠加监听源）。
            CGEvent.tapEnable(tap: tap, enable: true)
            return
        }
        let mask = CGEventMask(1 << 14) // NSSystemDefined
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: eventTapCallback, userInfo: nil) else {
            hkLog("事件监听：创建失败（缺少辅助功能/输入监控权限）")
            NSLog("EchoKey: 无法创建事件监听，缺少辅助功能/输入监控权限")
            return
        }
        eventTap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTapSource = src
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        hkLog("事件监听：已创建并启用（NSSystemDefined 通道）")
    }

    private func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        // 请求「输入监控」权限（IOHIDManager 读取 HID 需要）。
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    // MARK: 菜单动作
    @objc private func toggleEnabled() {
        AppState.enabled.toggle()
        Toast.show(AppState.enabled ? "映射已启用" : "映射已暂停")
    }

    @objc private func toggleSwallow() {
        AppState.swallow.toggle()
        AppState.config.swallowOriginal = AppState.swallow
        saveConfig(AppState.config)
        Toast.show(AppState.swallow ? "已拦截原始按键" : "放行原始按键")
    }

    @objc private func openSettings() {
        if settingsWC == nil { settingsWC = SettingsWindowController() }
        settingsWC?.reload()
        NSApp.activate(ignoringOtherApps: true)
        settingsWC?.window.makeKeyAndOrderFront(nil)
    }

    @objc private func openTest() {
        if logWC == nil { logWC = LogWindowController() }
        NSApp.activate(ignoringOtherApps: true)
        logWC?.window.makeKeyAndOrderFront(nil)
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "EchoKey"
        alert.informativeText = "把有线 EarPods 线控按键映射成快捷键 / 动作。\n\n配置文件：\(configPath)"
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func toggleLogin() {
        if isLoginEnabled() { setLogin(false) } else { setLogin(true) }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: 开机自启动（LaunchAgent）
    private var launchAgentPath: String {
        NSString(string: "~/Library/LaunchAgents/com.echokey.app.plist").expandingTildeInPath
    }

    private func isLoginEnabled() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentPath)
    }

    private func setLogin(_ on: Bool) {
        let fm = FileManager.default
        if on {
            let exe = Bundle.main.executablePath ?? ""
            let plist: [String: Any] = [
                "Label": "com.echokey.app",
                "ProgramArguments": [exe],
                "RunAtLoad": true,
                "KeepAlive": false,
            ]
            let dir = (launchAgentPath as NSString).deletingLastPathComponent
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                try? data.write(to: URL(fileURLWithPath: launchAgentPath))
            }
            launchctl("load", launchAgentPath)
            Toast.show("已设为开机自启动")
        } else {
            launchctl("unload", launchAgentPath)
            try? fm.removeItem(atPath: launchAgentPath)
            Toast.show("已取消开机自启动")
        }
    }

    private func launchctl(_ verb: String, _ path: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = [verb, path]
        try? proc.run()
        proc.waitUntilExit()
    }
}

// MARK: - 入口

let app = NSApplication.shared
gDelegate = AppDelegate()
app.delegate = gDelegate
app.setActivationPolicy(.accessory)
app.run()