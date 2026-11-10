// Ghost — make any macOS window look transparent, without disabling SIP.
//
// Trick: macOS won't let one process change another process's window alpha.
// So instead of making the target window transparent, we put a click-through
// overlay on top of it that shows "the screen with the target removed"
// (captured live with ScreenCaptureKit) at partial alpha. Visually the target
// looks see-through; clicks fall through the overlay to the real window.
//
// UI:
//   • hover the title bar of any window for ~0.3s → a small slider HUD appears
//     at the window's top-right; drag it to set that window's opacity
//     (100% = restore)
//   • ⌃⌥T toggles the frontmost window between 100% and the default opacity
//   • menu bar 👻 lists windows and current percentages
//
// Requires macOS 13+, Screen Recording permission.

import AppKit
import Carbon
import ScreenCaptureKit
import ServiceManagement

// MARK: - Window enumeration

struct WinInfo {
    let id: CGWindowID
    let pid: pid_t
    let app: String
    let title: String
    let bounds: CGRect          // CoreGraphics coords (origin top-left)
    var label: String { title.isEmpty ? app : "\(app) — \(title)" }
}

/// Front-to-back list of normal, on-screen windows (excluding ours).
func onScreenWindows() -> [WinInfo] {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
    let me = ProcessInfo.processInfo.processIdentifier
    return list.compactMap { d in
        guard (d[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              let id = (d[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let pid = (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != me,
              let bd = d[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: bd as CFDictionary),
              bounds.width > 60, bounds.height > 60
        else { return nil }
        let app = d[kCGWindowOwnerName as String] as? String ?? "?"
        let title = d[kCGWindowName as String] as? String ?? ""
        return WinInfo(id: id, pid: pid, app: app, title: title, bounds: bounds)
    }
}

/// Bounds + on-screen flag for one window id; nil if the window no longer exists.
func windowState(_ id: CGWindowID) -> (CGRect, Bool)? {
    guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
          let d = list.first,
          let bd = d[kCGWindowBounds as String] as? NSDictionary,
          let bounds = CGRect(dictionaryRepresentation: bd as CFDictionary)
    else { return nil }
    let onScreen = (d[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
    return (bounds, onScreen)
}

var primaryScreenHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

/// CoreGraphics (top-left origin) → Cocoa (bottom-left origin).
func cocoaRect(_ r: CGRect) -> NSRect {
    NSRect(x: r.minX, y: primaryScreenHeight - r.maxY, width: r.width, height: r.height)
}
func cgPoint(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x, y: primaryScreenHeight - p.y) }

// MARK: - One ghosted window

final class Ghost: NSObject, SCStreamOutput, SCStreamDelegate {
    let targetID: CGWindowID
    var onEnded: (() -> Void)?
    var onError: ((String) -> Void)?
    /// Fires once this ghost's overlay is on screen and its stream is running.
    var onStarted: (() -> Void)?

    /// 0…1, how opaque the target should *look*.
    var opacity: CGFloat { didSet { overlay.alphaValue = 1 - opacity } }

    // Design: the stream captures the WHOLE display (minus the target) and the
    // overlay window is display-sized and never moves. Only `patch`, a sublayer,
    // follows the target window: its frame and its contentsRect (the crop of
    // the display capture) are updated together in one CATransaction, so the
    // background can never be offset from where it should be — no jitter while
    // dragging/resizing, and no round-trips to the capture engine.
    private let overlay: NSWindow
    private let overlayID: CGWindowID          // read off the main thread, so cache it
    private let patch = CALayer()
    private let config = SCStreamConfiguration()
    private let frameQueue = DispatchQueue(label: "ghost.frames")
    private var stream: SCStream?
    private var timer: Timer?
    private var lastBounds = CGRect.null
    private var displayFrame = CGRect.zero     // CG coords
    private var display: SCDisplay?
    private var restarting = false

    init(targetID: CGWindowID, opacity: CGFloat) {
        self.targetID = targetID
        self.opacity = opacity

        overlay = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true          // clicks go to the real window underneath
        overlay.level = .floating
        // Visible to other recorders (Cap, QuickTime…) so demos show the effect.
        // Our own streams exclude every Ghost window explicitly instead.
        overlay.sharingType = .readOnly
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        overlay.alphaValue = 1 - opacity
        let v = NSView(frame: .zero)
        v.wantsLayer = true
        patch.contentsGravity = .resize
        patch.actions = ["contents": NSNull(), "contentsRect": NSNull(), "bounds": NSNull(), "position": NSNull()]
        v.layer?.addSublayer(patch)
        overlay.contentView = v
        overlayID = CGWindowID(overlay.windowNumber)
        super.init()
    }

    func start() {
        guard let (b, _) = windowState(targetID) else { onEnded?(); return }
        Task { await self.startStream(bounds: b) }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let s = stream {
            stream = nil
            Task { try? await s.stopCapture() }
        }
        overlay.orderOut(nil)
    }

    private func fail(_ msg: String) {
        NSLog("Ghost: \(msg)")
        DispatchQueue.main.async { [weak self] in
            self?.stop()
            self?.onError?(msg)
            self?.onEnded?()
        }
    }

    // MARK: stream

    private func startStream(bounds: CGRect) async {
        do {
            let first = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard first.windows.contains(where: { $0.windowID == targetID }) else {
                fail("ScreenCaptureKit 找不到目标窗口 \(targetID)"); return
            }
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            guard let display = first.displays.first(where: { $0.frame.contains(center) }) ?? first.displays.first
            else { fail("没有可用的显示器"); return }

            // Show the overlay (still empty, so invisible) BEFORE building the filter:
            // only an on-screen overlay is guaranteed to be listed and excludable.
            await MainActor.run {
                self.display = display
                displayFrame = display.frame
                overlay.setFrame(cocoaRect(display.frame), display: false)
                lastBounds = .null
                placePatch(bounds)
                overlay.orderFrontRegardless()
            }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let filter = SCContentFilter(display: display, excludingWindows: excludedWindows(in: content))

            let screen = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
            }
            let scale = screen?.backingScaleFactor ?? 2

            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false
            config.queueDepth = 5
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.width = Int(CGFloat(display.width) * scale)
            config.height = Int(CGFloat(display.height) * scale)

            let s = SCStream(filter: filter, configuration: config, delegate: self)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue)
            try await s.startCapture()
            stream = s
            await MainActor.run { onStarted?() }
        } catch {
            fail("启动捕获失败：\(error.localizedDescription)")
        }
    }

    /// The target plus every window Ghost owns (all overlays), so no stream ever
    /// captures an overlay — otherwise the image would feed back into itself.
    private func excludedWindows(in content: SCShareableContent) -> [SCWindow] {
        let me = ProcessInfo.processInfo.processIdentifier
        if !content.windows.contains(where: { $0.windowID == overlayID }) {
            NSLog("Ghost: overlay \(overlayID) not in shareable content; stream may capture it")
        }
        return content.windows.filter { $0.windowID == targetID || $0.owningApplication?.processID == me }
    }

    /// Re-exclude Ghost's windows; call when another ghost's overlay appears.
    func refreshFilter() {
        guard let s = stream, let display else { return }
        Task {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            else { return }
            let filter = SCContentFilter(display: display, excludingWindows: excludedWindows(in: content))
            do { try await s.updateContentFilter(filter) } catch { NSLog("Ghost: updateContentFilter failed: \(error)") }
        }
    }

    /// Put the crop layer where the target window is (overlay-local, y-up coords).
    private func placePatch(_ b: CGRect) {
        lastBounds = b
        let d = displayFrame
        guard d.width > 0, d.height > 0 else { return }
        // Window rect in Cocoa coords relative to the overlay's (= display's) bottom-left.
        let x = b.minX - d.minX
        let y = d.maxY - b.maxY
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        patch.frame = CGRect(x: x, y: y, width: b.width, height: b.height)
        patch.contentsRect = CGRect(x: x / d.width, y: y / d.height,
                                    width: b.width / d.width, height: b.height / d.height)
        CATransaction.commit()
    }

    private func tick() {
        guard let (b, onScreen) = windowState(targetID) else {
            stop(); onEnded?(); return
        }
        if !onScreen || b.width < 2 {
            if overlay.isVisible { overlay.orderOut(nil) }
            return
        }
        if !overlay.isVisible, stream != nil { overlay.orderFrontRegardless() }
        guard b != lastBounds else { return }

        // moved to another display → rebuild the stream against that display
        if displayFrame.width > 0, !displayFrame.contains(CGPoint(x: b.midX, y: b.midY)), !restarting, stream != nil {
            restarting = true
            let old = stream; stream = nil
            Task {
                try? await old?.stopCapture()
                await self.startStream(bounds: b)
                self.restarting = false
            }
            return
        }
        placePatch(b)
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = atts.first?[.status] as? Int, raw == SCFrameStatus.complete.rawValue,
              let pb = CMSampleBufferGetImageBuffer(sb),
              let surface = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue()
        else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.patch.contents = surface
            CATransaction.commit()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Ghost: stream stopped: \(error)")
        DispatchQueue.main.async { [weak self] in self?.stop(); self?.onEnded?() }
    }
}

// MARK: - Hover slider HUD

final class HUDPanel: NSPanel {
    static let size = NSSize(width: 230, height: 36)
    private let slider = NSSlider(value: 100, minValue: 20, maxValue: 100, target: nil, action: nil)
    private let label = NSTextField(labelWithString: "100%")
    var onChange: ((Double) -> Void)?

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: HUDPanel.size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu                      // above the ghost overlays
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        sharingType = .none                     // never captured by a ghost stream
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: HUDPanel.size))
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 9
        effect.layer?.masksToBounds = true

        slider.frame = NSRect(x: 12, y: 8, width: 156, height: 20)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged)

        label.frame = NSRect(x: 172, y: 9, width: 48, height: 18)
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.alignment = .right

        effect.addSubview(slider)
        effect.addSubview(label)
        contentView = effect
    }

    override var canBecomeKey: Bool { true }    // lets the slider take the drag without activating us

    @objc private func sliderChanged() {
        label.stringValue = "\(Int(slider.doubleValue))%"
        onChange?(slider.doubleValue)
    }

    func set(percent: Double) {
        slider.doubleValue = percent
        label.stringValue = "\(Int(percent))%"
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var ghosts: [CGWindowID: Ghost] = [:]
    private var defaultOpacity: CGFloat = 0.6
    private var hotKeyRef: EventHotKeyRef?

    private let hud = HUDPanel()
    private var hudTarget: WinInfo?
    private var hoverTimer: Timer?
    private var hoverCandidate: CGWindowID?
    private var hoverSince = Date()
    private var leftHUDAt: Date?

    private let hoverDelay: TimeInterval = 0.3   // how long to hover on a title bar
    private let hideDelay: TimeInterval = 0.7    // how long after leaving before HUD hides
    private let titleBarHeight: CGFloat = 32

    func applicationDidFinishLaunching(_: Notification) {
        // New status items are placed at the far left of the menu bar, which on a
        // notched MacBook with a full bar means hidden behind the notch. Ask for a
        // spot near the right edge (points from the right) on first launch; a later
        // ⌘-drag by the user overwrites this key and is kept.
        let posKey = "NSStatusItem Preferred Position GhostStatusItem"
        if UserDefaults.standard.object(forKey: posKey) == nil {
            UserDefaults.standard.set(400, forKey: posKey)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "GhostStatusItem"
        statusItem.button?.title = "👻"
        menu.delegate = self
        statusItem.menu = menu

        hud.onChange = { [weak self] v in
            guard let self, let t = self.hudTarget else { return }
            self.setOpacity(for: t.id, percent: v)
        }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            self?.pollHover()
        }
        registerHotKey()
        _ = ensurePermission()
    }

    // MARK: Screen Recording permission

    private var permissionAlertShown = false

    /// true if we may capture. Otherwise asks the system once and explains what to do.
    private func ensurePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if !permissionAlertShown {
            permissionAlertShown = true
            CGRequestScreenCaptureAccess()          // adds Ghost to the Screen Recording list
            let a = NSAlert()
            a.messageText = "Ghost 需要「屏幕录制」权限"
            a.informativeText = """
            系统设置 → 隐私与安全性 → 屏幕录制，打开 Ghost 的开关，然后重新启动 Ghost。
            （每次重新 build 之后签名会变，需要重新授权一次。）
            """
            a.addButton(withTitle: "打开系统设置")
            a.addButton(withTitle: "稍后")
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
        return false
    }

    private func showError(_ msg: String) {
        let a = NSAlert()
        a.messageText = "Ghost 出错了"
        a.informativeText = msg
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    func applicationWillTerminate(_: Notification) { ghosts.values.forEach { $0.stop() } }

    // MARK: opacity control

    private func percent(of id: CGWindowID) -> Double {
        ghosts[id].map { Double($0.opacity * 100) } ?? 100
    }

    private func setOpacity(for id: CGWindowID, percent: Double) {
        if percent >= 99 {                       // 100% = restore
            ghosts[id]?.stop()
            ghosts[id] = nil
            return
        }
        let op = CGFloat(percent) / 100
        if let g = ghosts[id] {
            g.opacity = op
        } else {
            guard ensurePermission() else { hideHUD(); return }
            let g = Ghost(targetID: id, opacity: op)
            g.onEnded = { [weak self, weak g] in
                guard let self, let g, self.ghosts[id] === g else { return }
                self.ghosts[id] = nil
            }
            g.onError = { [weak self] msg in self?.hideHUD(); self?.showError(msg) }
            g.onStarted = { [weak self, weak g] in   // new overlay → hide it from the other streams
                self?.ghosts.values.forEach { if $0 !== g { $0.refreshFilter() } }
            }
            ghosts[id] = g
            g.start()
        }
    }

    private func restoreAll() {
        ghosts.values.forEach { $0.stop() }
        ghosts.removeAll()
    }

    /// Hotkey: toggle the frontmost app's top window between 100% and the default.
    func toggleFrontmost() {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let w = onScreenWindows().first(where: { $0.pid == pid }) else { return }
        setOpacity(for: w.id, percent: ghosts[w.id] == nil ? Double(defaultOpacity * 100) : 100)
        if hud.isVisible, hudTarget?.id == w.id { hud.set(percent: percent(of: w.id)) }
    }

    // MARK: hover HUD

    private func pollHover() {
        let mouse = NSEvent.mouseLocation                      // Cocoa coords

        // Mouse on (or near) the HUD itself → keep it.
        if hud.isVisible, hud.frame.insetBy(dx: -24, dy: -24).contains(mouse) {
            leftHUDAt = nil
            return
        }

        let p = cgPoint(mouse)
        let under = onScreenWindows().first { $0.bounds.contains(p) }
        if let w = under, p.y - w.bounds.minY <= titleBarHeight {
            leftHUDAt = nil
            if hud.isVisible, hudTarget?.id == w.id { return }
            if hoverCandidate != w.id {
                hoverCandidate = w.id
                hoverSince = Date()
                return
            }
            if Date().timeIntervalSince(hoverSince) >= hoverDelay { showHUD(for: w) }
            return
        }

        hoverCandidate = nil
        guard hud.isVisible else { return }
        if let t = leftHUDAt {
            if Date().timeIntervalSince(t) >= hideDelay { hideHUD() }
        } else {
            leftHUDAt = Date()
        }
    }

    private func showHUD(for w: WinInfo) {
        hudTarget = w
        hud.set(percent: percent(of: w.id))

        // Top-right corner of the window, just below its title bar.
        let f = cocoaRect(w.bounds)
        var origin = NSPoint(x: f.maxX - HUDPanel.size.width - 10,
                             y: f.maxY - titleBarHeight - HUDPanel.size.height - 4)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: f.midX, y: f.midY)) }) {
            let vis = screen.visibleFrame
            origin.x = min(max(origin.x, vis.minX + 4), vis.maxX - HUDPanel.size.width - 4)
            origin.y = min(max(origin.y, vis.minY + 4), vis.maxY - HUDPanel.size.height - 4)
        }
        hud.setFrameOrigin(origin)
        hud.orderFrontRegardless()
    }

    private func hideHUD() {
        hud.orderOut(nil)
        hudTarget = nil
        leftHUDAt = nil
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let hint = NSMenuItem(title: "悬停窗口标题栏 → 滑块 ｜ ⌃⌥T 切换前台窗口", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        let opItem = NSMenuItem(title: "⌃⌥T 默认透明度", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for p in [30, 40, 50, 60, 70, 80, 90] {
            let it = NSMenuItem(title: "\(p)%", action: #selector(setDefaultOpacity(_:)), keyEquivalent: "")
            it.tag = p
            it.state = Int(defaultOpacity * 100) == p ? .on : .off
            sub.addItem(it)
        }
        opItem.submenu = sub
        menu.addItem(opItem)

        if !ghosts.isEmpty {
            menu.addItem(withTitle: "全部恢复 (\(ghosts.count))", action: #selector(restoreAllAction), keyEquivalent: "")
        }

        let login = NSMenuItem(title: "登录时自动启动", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let head = NSMenuItem(title: "窗口（点击 = 切换）", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        for w in onScreenWindows().prefix(30) {
            var name = String(w.label.prefix(60))
            if let g = ghosts[w.id] { name += "   \(Int(g.opacity * 100))%" }
            let it = NSMenuItem(title: name, action: #selector(toggleWindow(_:)), keyEquivalent: "")
            it.representedObject = w.id
            it.state = ghosts[w.id] != nil ? .on : .off
            menu.addItem(it)
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func toggleWindow(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? CGWindowID else { return }
        setOpacity(for: id, percent: ghosts[id] == nil ? Double(defaultOpacity * 100) : 100)
    }

    @objc private func setDefaultOpacity(_ sender: NSMenuItem) {
        defaultOpacity = CGFloat(sender.tag) / 100
    }

    @objc private func restoreAllAction() { restoreAll() }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showError("设置登录启动失败：\(error.localizedDescription)")
        }
    }

    // MARK: global hotkey (⌃⌥T) via Carbon

    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData -> OSStatus in
            guard let userData else { return noErr }
            let me = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { me.toggleFrontmost() }
            return noErr
        }, 1, &spec, selfPtr, nil)

        let hotKeyID = EventHotKeyID(signature: OSType(0x4748_5354), id: 1) // "GHST"
        RegisterEventHotKey(UInt32(kVK_ANSI_T), UInt32(controlKey | optionKey),
                            hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
app.run()
