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
//   • menu bar 👻 → "共享/录屏时隐藏": ghosted windows stay visible to you but
//     vanish from screen sharing and recordings (see "Hide-in-shares mode")
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

// MARK: - Hide-in-shares mode
//
// Goal: you see a ghosted window at its chosen opacity, while anything that
// captures the screen (Zoom, Meet, Teams, Cap, QuickTime, screenshots) sees no
// window at all. Same constraint as above: we can't touch the other app's window,
// only put our own windows on top of it.
//
// Per display, while anything is hidden (DisplayShield):
//   • cover — sharingType .readOnly, full display: the screen without the hidden
//     apps, except their windows checked to be unrelated. Captures get this, so
//     the window is gone however it moves, jumps or slides (Space switches).
//   • view  — sharingType .none, full display: the real screen, so you see what
//     you'd see anyway, with a hole at each hidden window where the real screen
//     is drawn at the chosen opacity over the cover.
// Leak guards:
//   • Unknown windows of a hidden app (a menu, sheet or popover that just opened,
//     a new window) are left out of the cover until classified; at worst a new
//     window shows up in a share a moment late.
//   • An app counts as hidden only once a cover frame newer than the filter that
//     excludes it has arrived (ShieldStream.confirmed).
//   • The cursor is hidden from captures while it's over a hidden window (CursorCloak).
//   • A watchdog process keeps blocks under hidden windows in case Ghost dies (CrashGuard).
// Cost: while something is hidden, your whole screen is shown through a capture
// (about one display frame later), and the window server does noticeably more work.

let shieldLevel = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)

/// Bounds, on-screen flag and owner pid for one window id; nil once it's closed.
/// Unlike CGWindowListCopyWindowInfo(.optionIncludingWindow), this also finds
/// windows that are off screen (minimized, app hidden, other Space).
func windowInfo(_ id: CGWindowID) -> (bounds: CGRect, onScreen: Bool, pid: pid_t)? {
    var ids: [UnsafeRawPointer?] = [UnsafeRawPointer(bitPattern: UInt(id))]
    guard let arr = CFArrayCreate(nil, &ids, 1, nil),
          let list = CGWindowListCreateDescriptionFromArray(arr) as? [[String: Any]],
          let d = list.first,
          let bd = d[kCGWindowBounds as String] as? NSDictionary,
          let bounds = CGRect(dictionaryRepresentation: bd as CFDictionary),
          let pid = (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
    else { return nil }
    return (bounds, (d[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false, pid)
}

/// Bounds and on-screen flag of several windows at once, off-screen ones included.
func describeWindows(_ ids: [CGWindowID]) -> [CGWindowID: (bounds: CGRect, onScreen: Bool)] {
    guard !ids.isEmpty else { return [:] }
    var ptrs: [UnsafeRawPointer?] = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
    guard let arr = CFArrayCreate(nil, &ptrs, ptrs.count, nil),
          let list = CGWindowListCreateDescriptionFromArray(arr) as? [[String: Any]] else { return [:] }
    var out: [CGWindowID: (CGRect, Bool)] = [:]
    for d in list {
        guard let id = (d[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let bd = d[kCGWindowBounds as String] as? NSDictionary,
              let b = CGRect(dictionaryRepresentation: bd as CFDictionary) else { continue }
        out[id] = (b, (d[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false)
    }
    return out
}

private func makeOverlay(frame: NSRect, level: NSWindow.Level, sharing: NSWindow.SharingType) -> (NSWindow, CALayer) {
    let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    w.isOpaque = false
    w.backgroundColor = .clear
    w.hasShadow = false
    w.ignoresMouseEvents = true
    w.level = level
    w.sharingType = sharing
    w.animationBehavior = .none
    w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
    let v = NSView(frame: NSRect(origin: .zero, size: frame.size))
    v.wantsLayer = true
    v.layer!.masksToBounds = true
    w.contentView = v
    w.setFrame(frame, display: false)
    return (w, v.layer!)
}

/// One capture stream of a display shield, plus which exclusions it is known to
/// honour. A key (window id or pid) joins `confirmed` only after a frame newer
/// than the filter that excludes it arrives, or after the screen stayed idle
/// long enough that nothing excluded can have been on it.
final class ShieldStream {
    let name: String
    var stream: SCStream?
    var surface: IOSurface?
    private(set) var confirmed: Set<UInt64> = []
    private var wanted: Set<UInt64> = []
    private var applying = false
    private var pending: (keys: Set<UInt64>, after: UInt64, at: Date)?
    let makeFilter: (SCShareableContent, Set<UInt64>) -> SCContentFilter

    init(name: String, makeFilter: @escaping (SCShareableContent, Set<UInt64>) -> SCContentFilter) {
        self.name = name
        self.makeFilter = makeFilter
    }

    var startKeys: Set<UInt64> { wanted }

    func started(_ s: SCStream, keys: Set<UInt64>, at t: UInt64) {
        stream = s
        pending = (keys, t, Date())
        apply()
    }

    func want(_ keys: Set<UInt64>) {
        wanted = keys
        confirmed.formIntersection(keys)        // dropped keys need no confirmation
        apply()
    }

    private func apply() {
        guard let s = stream, !applying, wanted != (pending?.keys ?? confirmed) else { return }
        applying = true
        let keys = wanted
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                try await s.updateContentFilter(makeFilter(content, keys))
                let t = mach_absolute_time()
                await MainActor.run {
                    applying = false
                    pending = (keys, t, Date())
                    apply()
                }
            } catch {
                NSLog("Ghost: \(name) updateContentFilter failed: \(error)")
                await MainActor.run { applying = false }
            }
        }
    }

    func frame(shownAt t: UInt64) {
        if let p = pending, t > p.after { confirm(p.keys) }
    }

    func checkIdle() {
        if let p = pending, Date().timeIntervalSince(p.at) > 0.25 { confirm(p.keys) }
    }

    private func confirm(_ keys: Set<UInt64>) {
        confirmed = keys.intersection(wanted)
        pending = nil
    }
}

/// Key for a pid in a ShieldStream's key set (window ids stay below 2^32).
func pidKey(_ pid: pid_t) -> UInt64 { 1 << 40 | UInt64(UInt32(bitPattern: pid)) }

/// One display's overlays and capture streams.
///
///   cover (sharingType .readOnly, what captures see): full display, the screen
///     without the hidden apps — except that app's other windows we have checked
///     are unrelated to the hidden window. Anything new (a menu, popover, sheet,
///     child panel, a fresh window) starts out excluded, so the share can show a
///     new window a moment late but never shows a hidden one. Being full-screen,
///     it needs no tracking: moves, jumps and Space switches can't uncover it.
///   view (sharingType .none, what only you see): full display, the real screen,
///     with a hole at each hidden window; inside the hole the real screen at the
///     chosen opacity over the cover: α·window + (1−α)·what's behind it.
final class DisplayShield: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Patch { let id: CGWindowID; let pid: pid_t; let rect: CGRect; let alpha: CGFloat }

    let display: SCDisplay
    var frame: CGRect { display.frame }
    var onStopped: (() -> Void)?

    let coverWin: NSWindow
    let viewWin: NSWindow
    let coverID: CGWindowID                    // read off the main thread, so cached
    private let coverRoot: CALayer
    private let viewRoot: CALayer
    private let coverBase = CALayer()
    private let viewBase = CALayer()
    private let viewMask = CAShapeLayer()
    private var patches: [CGWindowID: CALayer] = [:]
    private let queue = DispatchQueue(label: "ghost.shield", qos: .userInteractive)
    private var stopped = false

    private(set) var base: ShieldStream!      // keys: pidKey(hidden apps) + their windows to keep
    private(set) var view: ShieldStream!      // keys: none

    init(display: SCDisplay) {
        self.display = display
        let f = cocoaRect(display.frame)
        (coverWin, coverRoot) = makeOverlay(frame: f, level: shieldLevel, sharing: .readOnly)
        (viewWin, viewRoot) = makeOverlay(frame: f, level: NSWindow.Level(rawValue: shieldLevel.rawValue + 1), sharing: .none)
        coverID = CGWindowID(coverWin.windowNumber)
        super.init()
        let me = ProcessInfo.processInfo.processIdentifier
        let d = display
        base = ShieldStream(name: "base") { content, keys in
            let apps = content.applications.filter {
                $0.processID == me || $0.processID == watchdogPID || keys.contains(pidKey($0.processID)) }
            let keep = content.windows.filter { keys.contains(UInt64($0.windowID)) }
            return SCContentFilter(display: d, excludingApplications: apps, exceptingWindows: keep)
        }
        // Ghost's own menus and alerts sit below the overlays; let them into the
        // view (keys: their window ids) or you couldn't see them while hiding.
        view = ShieldStream(name: "view") { content, keys in
            let apps = content.applications.filter { $0.processID == me || $0.processID == watchdogPID }
            let mine = content.windows.filter { keys.contains(UInt64($0.windowID)) }
            return SCContentFilter(display: d, excludingApplications: apps, exceptingWindows: mine)
        }
        let full = CGRect(origin: .zero, size: f.size)
        for (l, root) in [(coverBase, coverRoot), (viewBase, viewRoot)] {
            l.frame = full
            l.contentsGravity = .resize
            l.isHidden = true
            l.actions = quietActions
            root.addSublayer(l)
        }
        viewMask.frame = full
        viewMask.fillRule = .evenOdd
        viewMask.actions = ["path": NSNull()]
        viewBase.mask = viewMask
        // On screen before any filter is built: ScreenCaptureKit only lists apps
        // that have windows, and Ghost must be listed to exclude itself.
        coverWin.orderFrontRegardless()
        viewWin.orderFrontRegardless()
    }

    private let quietActions: [String: CAAction] = [
        "contents": NSNull(), "contentsRect": NSNull(), "bounds": NSNull(),
        "position": NSNull(), "hidden": NSNull(), "opacity": NSNull()]

    func start(keys: Set<UInt64>) {
        base.want(keys)
        Task { await self.startStreams(attempt: 0) }
    }

    func stop() {
        stopped = true
        for s in streams.compactMap(\.stream) { Task { try? await s.stopCapture() } }
        coverWin.orderOut(nil)
        viewWin.orderOut(nil)
    }

    func want(_ keys: Set<UInt64>) { base.want(keys) }
    func wantInView(_ keys: Set<UInt64>) { view.want(keys) }

    /// The cover is up and known to leave this app's hidden windows out.
    func isReady(pid: pid_t) -> Bool {
        base.surface != nil && base.confirmed.contains(pidKey(pid))
    }

    private func config(fps: Int) -> SCStreamConfiguration {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
        }
        let c = SCStreamConfiguration()
        c.pixelFormat = kCVPixelFormatType_32BGRA
        if let name = screen?.colorSpace?.cgColorSpace?.name { c.colorSpaceName = name }   // no colour shift
        c.showsCursor = false
        c.queueDepth = 5
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        let scale = screen?.backingScaleFactor ?? 2
        c.width = Int(CGFloat(display.width) * scale)
        c.height = Int(CGFloat(display.height) * scale)
        return c
    }

    private func startStreams(attempt: Int) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let me = ProcessInfo.processInfo.processIdentifier
            guard content.applications.contains(where: { $0.processID == me }),
                  content.windows.contains(where: { $0.windowID == coverID }) else {
                // Our overlays aren't listed yet; without self-exclusion the cover
                // would capture itself. Wait for the window server to catch up.
                if attempt < 40, !stopped {
                    try await Task.sleep(nanoseconds: 50_000_000)
                    await startStreams(attempt: attempt + 1)
                } else { NSLog("Ghost: shield could not find its own windows in shareable content") }
                return
            }
            let maxFPS = NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60
            var made: [(ShieldStream, SCStream, Set<UInt64>)] = []
            // Cover: what shares and recordings get, so full rate and resolution.
            // View: what you see, so the display's own refresh rate.
            for (ss, fps) in [(base!, 60), (view!, maxFPS)] {
                let keys = await MainActor.run { ss.startKeys }
                let s = SCStream(filter: ss.makeFilter(content, keys), configuration: config(fps: fps), delegate: self)
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                made.append((ss, s, keys))
            }
            let all = made
            for (_, s, _) in all { try await s.startCapture() }
            let t = mach_absolute_time()
            await MainActor.run {
                if stopped { all.forEach { m in Task { try? await m.1.stopCapture() } }; return }
                all.forEach { $0.0.started($0.1, keys: $0.2, at: t) }
            }
        } catch {
            NSLog("Ghost: shield start failed: \(error)")
            await MainActor.run { onStopped?() }
        }
    }

    private var streams: [ShieldStream] { [base, view] }

    func checkIdle() { streams.forEach { $0.checkIdle() } }

    private var lastHoles: [CGRect] = []

    /// Called every tick; commits only what changed, so a still screen costs
    /// the window server nothing.
    func layout(_ list: [Patch]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if coverBase.isHidden != (base.surface == nil) { coverBase.isHidden = base.surface == nil }
        if viewBase.isHidden != (view.surface == nil) { viewBase.isHidden = view.surface == nil }
        let live = Set(list.map(\.id))
        for (id, l) in patches where !live.contains(id) {
            l.removeFromSuperlayer()
            patches[id] = nil
        }
        let d = display.frame
        var holes: [CGRect] = []
        for p in list.sorted(by: { $0.id < $1.id }) {
            let l = patches[p.id] ?? addPatch(p.id)
            let x = p.rect.minX - d.minX, y = d.maxY - p.rect.maxY
            let r = CGRect(x: x, y: y, width: p.rect.width, height: p.rect.height)
            let cr = CGRect(x: x / d.width, y: y / d.height, width: p.rect.width / d.width, height: p.rect.height / d.height)
            let show = isReady(pid: p.pid) && view.surface != nil && p.rect.intersects(d)
            if l.frame != r { l.frame = r }
            if l.contentsRect != cr { l.contentsRect = cr }
            if l.isHidden == show { l.isHidden = !show }
            if l.opacity != Float(p.alpha) { l.opacity = Float(p.alpha) }
            if show { holes.append(r) }
        }
        if holes != lastHoles {
            lastHoles = holes
            let path = CGMutablePath()
            path.addRect(CGRect(origin: .zero, size: d.size))
            holes.forEach { path.addRect($0) }
            viewMask.path = path
        }
    }

    private func addPatch(_ id: CGWindowID) -> CALayer {
        let l = CALayer()
        l.contentsGravity = .resize
        l.isHidden = true
        l.contents = view.surface
        l.actions = quietActions
        viewRoot.addSublayer(l)
        patches[id] = l
        return l
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = atts.first,
              let raw = info[.status] as? Int, let status = SCFrameStatus(rawValue: raw),
              status == .complete || status == .idle
        else { return }
        let shown = (info[.displayTime] as? NSNumber)?.uint64Value ?? 0
        var surface: IOSurface?
        if status == .complete, let pb = CMSampleBufferGetImageBuffer(sb) {
            surface = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue()
        }
        DispatchQueue.main.async { [weak self] in self?.frameArrived(stream, surface: surface, shown: shown) }
    }

    private func frameArrived(_ s: SCStream, surface: IOSurface?, shown: UInt64) {
        guard let ss = streams.first(where: { $0.stream === s }) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let surface {
            ss.surface = surface
            if ss === base { coverBase.contents = surface }
            if ss === view {
                viewBase.contents = surface
                for l in patches.values { l.contents = surface }
            }
        }
        ss.frame(shownAt: shown)
        CATransaction.commit()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Ghost: shield stream stopped: \(error)")
        // Keep the overlays and their last frames up: a stale cover still hides.
        DispatchQueue.main.async { [weak self] in self?.onStopped?() }
    }
}

/// Over a hidden window, a share would show the cursor moving and clicking over
/// nothing (and its I-beam would give text fields away). While the mouse is over
/// one, hide the system cursor — a private SkyLight switch lets a background app
/// do that — and draw a local-only copy. The window server brings the real cursor
/// back by itself if Ghost exits.
final class CursorCloak {
    private let win: NSWindow
    private let image = NSImageView()
    private var hidden = false
    private var shown: NSCursor?
    private var monitor: Any?

    static let available: Bool = {
        typealias MainConn = @convention(c) () -> UInt32
        typealias SetProp = @convention(c) (UInt32, UInt32, CFString, CFTypeRef) -> Int32
        guard let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let a = dlsym(sky, "SLSMainConnectionID") ?? dlsym(sky, "CGSMainConnectionID"),
              let b = dlsym(sky, "SLSSetConnectionProperty") ?? dlsym(sky, "CGSSetConnectionProperty")
        else { return false }
        let cid = unsafeBitCast(a, to: MainConn.self)()
        return unsafeBitCast(b, to: SetProp.self)(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue) == 0
    }()

    init() {
        win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 32, height: 32), styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.sharingType = .none
        win.level = NSWindow.Level(rawValue: shieldLevel.rawValue + 4)
        win.animationBehavior = .none
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        image.imageScaling = .scaleAxesIndependently
        win.contentView = image
    }

    var window: NSWindow { win }

    /// `areas` in CG coordinates: where the cursor must not be seen by captures.
    func update(hiddenOver areas: [CGRect]) {
        guard CursorCloak.available else { return }
        let m = NSEvent.mouseLocation
        let inside = areas.contains { $0.contains(cgPoint(m)) }
        if inside != hidden { inside ? cloak() : uncloak() }
        if hidden { place(m) }
    }

    func stop() { if hidden { uncloak() } }

    private func place(_ m: NSPoint) {
        guard let c = NSCursor.currentSystem else { return }
        let size = c.image.size
        if c !== shown {
            shown = c
            image.image = c.image
            win.setContentSize(size)
            image.frame = NSRect(origin: .zero, size: size)
        }
        win.setFrameOrigin(NSPoint(x: m.x - c.hotSpot.x, y: m.y - (size.height - c.hotSpot.y)))
    }

    private func cloak() {
        hidden = true
        CGDisplayHideCursor(kCGNullDirectDisplay)
        place(NSEvent.mouseLocation)
        win.orderFrontRegardless()
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        ) { [weak self] _ in self?.place(NSEvent.mouseLocation) }
    }

    private func uncloak() {
        hidden = false
        CGDisplayShowCursor(kCGNullDirectDisplay)
        win.orderOut(nil)
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        shown = nil
    }
}

/// Hidden windows across all displays: positions patches every display frame.
final class ShareShield {
    struct Target {
        let pid: pid_t
        var alpha: CGFloat
        var bounds: CGRect
        var group: CGRect          // the window plus its menus/popovers/sheets
        var rect: CGRect           // group, padded: the hole in the local view
        var pad: CGFloat
        var onScreen = true
    }

    private(set) var targets: [CGWindowID: Target] = [:]
    private var shields: [CGDirectDisplayID: DisplayShield] = [:]
    let cursor = CursorCloak()
    private var timer: Timer?
    private var syncing = false
    private var resyncNeeded = false
    private var reportedActive: Set<CGWindowID> = []
    private var screenObserver: NSObjectProtocol?

    var onTargetsChanged: (() -> Void)?
    var onActive: ((CGWindowID, pid_t) -> Void)?

    /// Covers the window shadow; grows with speed while a window is dragged.
    private let basePad: CGFloat = 48
    /// How many layout ticks of motion a patch must lead the window by.
    private let leadTicks: CGFloat = 4
    /// A teleporting window can't be out-run anyway; don't blanket the screen.
    private let maxPad: CGFloat = 240

    var isEmpty: Bool { targets.isEmpty }
    var pids: Set<pid_t> { Set(targets.values.map(\.pid)) }
    /// Windows of hidden apps that are unrelated to any hidden window: shown in shares.
    private var keep: Set<CGWindowID> = []
    private var keys: Set<UInt64> { Set(targets.values.map { pidKey($0.pid) }).union(keep.map { UInt64($0) }) }
    var allShields: [DisplayShield] { Array(shields.values) }

    func alpha(of id: CGWindowID) -> CGFloat? { targets[id]?.alpha }

    func isActive(_ id: CGWindowID) -> Bool {
        guard let t = targets[id], !shields.isEmpty else { return false }
        return shields.values.allSatisfy { $0.isReady(pid: t.pid) }
    }

    @discardableResult
    func set(_ id: CGWindowID, alpha: CGFloat) -> Bool {
        if targets[id] != nil {
            targets[id]!.alpha = alpha
            onTargetsChanged?()
            return true
        }
        guard let info = windowInfo(id) else { return false }
        let pad = basePad
        targets[id] = Target(pid: info.pid, alpha: alpha, bounds: info.bounds, group: info.bounds,
                             rect: info.bounds.insetBy(dx: -pad, dy: -pad), pad: pad)
        start()
        shields.values.forEach { $0.want(keys) }
        onTargetsChanged?()
        return true
    }

    func remove(_ id: CGWindowID) {
        guard targets.removeValue(forKey: id) != nil else { return }
        reportedActive.remove(id)
        related[id] = nil
        layoutAll()                                   // patch gone before the app is re-included
        shields.values.forEach { $0.want(keys) }
        onTargetsChanged?()
        if targets.isEmpty { stop() }
    }

    func removeAll() {
        targets.removeAll()
        reportedActive.removeAll()
        stop()
        onTargetsChanged?()
    }

    private func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)         // keep running during menu tracking / drags
        timer = t
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.syncDisplays() }
        syncDisplays()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        cursor.stop()
        if let o = screenObserver { NotificationCenter.default.removeObserver(o) }
        screenObserver = nil
        shields.values.forEach { $0.stop() }
        shields.removeAll()
    }

    /// Match shields to the current displays. Shields of unchanged displays are
    /// kept, so plugging in a monitor never uncovers windows on the others.
    private func syncDisplays() {
        guard !syncing else { resyncNeeded = true; return }
        syncing = true
        Task {
            let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            await MainActor.run {
                syncing = false
                defer { if resyncNeeded { resyncNeeded = false; syncDisplays() } }
                guard timer != nil, let content else { return }
                let live = Dictionary(uniqueKeysWithValues: content.displays.map { ($0.displayID, $0) })
                for (id, s) in shields where live[id]?.frame != s.frame {
                    s.stop()
                    shields[id] = nil
                }
                for (id, d) in live where shields[id] == nil {
                    let s = DisplayShield(display: d)
                    s.onStopped = { [weak self, weak s] in
                        guard let self, let s, self.shields[id] === s else { return }
                        self.restartShield(id)
                    }
                    shields[id] = s
                    s.wantInView(ownWindows)
                    s.start(keys: keys)
                }
                layoutAll()
            }
        }
    }

    /// A stream died: start a new shield first, drop the old one once it's ready.
    private func restartShield(_ id: CGDirectDisplayID) {
        guard let old = shields[id] else { return }
        let fresh = DisplayShield(display: old.display)
        fresh.onStopped = { [weak self, weak fresh] in
            guard let self, let fresh, self.shields[id] === fresh else { return }
            self.restartShield(id)
        }
        fresh.wantInView(ownWindows)
        fresh.start(keys: keys)
        var check: Timer?
        check = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { check?.invalidate(); return }
            fresh.checkIdle()
            if self.targets.values.allSatisfy({ fresh.isReady(pid: $0.pid) }) {
                check?.invalidate()
                self.shields[id] = fresh
                old.stop()
            }
        }
    }

    private var tickCount = 0
    /// Per hidden window, the same-app windows that belong to it (last full scan).
    private var related: [CGWindowID: Set<CGWindowID>] = [:]
    /// Every on-screen window of a hidden app → the hidden window it belongs to (nil: unrelated).
    private var known: [CGWindowID: CGWindowID?] = [:]
    /// Ghost's own menus and alerts, shown in the local view.
    private var ownWindows: Set<UInt64> = []

    /// Look again right away, e.g. when Ghost's menu is about to open.
    func rescanSoon() {
        guard timer != nil else { return }
        for delay in [0.02, 0.06] {
            let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in self?.scan() }
            RunLoop.main.add(t, forMode: .common)
        }
    }

    /// 120 Hz: follow the hidden windows and their children, looked up by id.
    private func tick() {
        tickCount += 1
        if tickCount % 8 == 1 { scan() }
        let ids = Array(targets.keys) + related.values.flatMap { $0 }
        let info = describeWindows(ids)
        var gone: [CGWindowID] = []
        for (id, var t) in targets {
            guard let w = info[id] else { gone.append(id); continue }   // closed
            t.onScreen = w.onScreen
            guard w.onScreen else { targets[id] = t; continue }      // off screen: keep the hole where it was
            let b = w.bounds
            let step = max(abs(b.minX - t.bounds.minX), abs(b.minY - t.bounds.minY),
                           abs(b.maxX - t.bounds.maxX), abs(b.maxY - t.bounds.maxY))
            t.pad = min(max(basePad + step * leadTicks, t.pad * 0.97, basePad), maxPad)  // jump up, ease down
            t.bounds = b
            var group = b
            for oid in related[id] ?? [] {
                if let o = info[oid], o.onScreen, o.bounds.intersects(b) { group = group.union(o.bounds) }
            }
            t.group = group
            t.rect = group.insetBy(dx: -t.pad, dy: -t.pad)
            targets[id] = t
        }
        gone.forEach(remove)
        layoutAll()
    }

    /// 15 Hz: sort the hidden apps' other windows into "belongs to a hidden window"
    /// (left out of shares with it) and "unrelated" (shown in shares). A window
    /// that appears in between is unknown, and unknown windows stay left out.
    private func scan() {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return }
        var wins: [CGWindowID: (pid: pid_t, layer: Int, bounds: CGRect, z: Int, titled: Bool)] = [:]
        let watched = pids
        let me = ProcessInfo.processInfo.processIdentifier
        var mine: Set<UInt64> = []
        for d in list where (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == me {
            if let id = (d[kCGWindowNumber as String] as? NSNumber)?.uint32Value { mine.insert(UInt64(id)) }
        }
        // Everything of ours but the covers (the rest is .none, never captured anyway).
        mine.subtract(shields.values.map { UInt64($0.coverID) })
        if mine != ownWindows {
            ownWindows = mine
            shields.values.forEach { $0.wantInView(mine) }
        }
        for (z, d) in list.enumerated() {                // front to back
            guard let pid = (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, watched.contains(pid),
                  let id = (d[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bd = d[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: bd as CFDictionary)
            else { continue }
            let titled = !((d[kCGWindowName as String] as? String) ?? "").isEmpty
            wins[id] = (pid, (d[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0, b, z, titled)
        }
        // Sticky: once a window is known to belong to a hidden window it stays so,
        // and a window first seen on top of a hidden one belongs to it (a sheet or
        // popover mid-animation may not look like a child yet). A window that was
        // already there, like one you're presenting, is never swallowed for merely
        // being dragged over a hidden one.
        var owner: [CGWindowID: CGWindowID?] = [:]
        for (oid, o) in wins where targets[oid] == nil {
            if let prev = known[oid], let t = prev, targets[t] != nil { owner[oid] = t; continue }
            var match: CGWindowID?
            for (id, t) in targets {
                guard let w = wins[id], o.pid == t.pid, o.z < w.z, o.bounds.intersects(w.bounds) else { continue }
                let childLike = o.layer != 0 || w.bounds.contains(o.bounds)
                    || (!o.titled && o.bounds.width * o.bounds.height < w.bounds.width * w.bounds.height)
                if known[oid] == nil || childLike { match = id; break }
            }
            owner[oid] = match
        }
        known = owner
        var rel: [CGWindowID: Set<CGWindowID>] = [:]
        for id in targets.keys { rel[id] = wins[id] == nil ? related[id] : [] }   // off screen: keep last
        for (oid, t) in owner { if let t, wins[t] != nil { rel[t, default: []].insert(oid) } }
        related = rel
        let newKeep = Set(wins.keys).subtracting(targets.keys).subtracting(rel.values.flatMap { $0 })
        if newKeep != keep {
            keep = newKeep
            shields.values.forEach { $0.want(keys) }
        }
    }

    private func layoutAll() {
        let patches = targets.map { DisplayShield.Patch(id: $0.key, pid: $0.value.pid, rect: $0.value.rect, alpha: $0.value.alpha) }
        for s in shields.values {
            s.checkIdle()
            s.layout(patches)
        }
        cursor.update(hiddenOver: targets.filter { $0.value.onScreen && isActive($0.key) }
                                         .map { $0.value.group.insetBy(dx: -6, dy: -6) })
        for id in targets.keys where !reportedActive.contains(id) && isActive(id) {
            reportedActive.insert(id)
            onActive?(id, targets[id]!.pid)
        }
    }
}

// MARK: - Crash guard for hide mode
//
// If Ghost dies, its overlays vanish with it. A watchdog child process keeps an
// opaque block under every hidden window at all times — below Ghost's overlays
// and left out of Ghost's captures, so nobody sees it while Ghost runs. The
// moment Ghost dies the blocks are what's on top, with no reaction time. The
// watchdog then hides the apps that owned hidden windows, and after a crash
// relaunches Ghost, which covers those windows again and un-hides the apps.

struct HiddenState: Codable {
    struct Entry: Codable { let window: UInt32; let pid: Int32; let alpha: Double; var active: Bool }
    var ghost: Int32
    var entries: [Entry]

    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.yangli.ghost")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static var file: URL { dir.appendingPathComponent("hidden.json") }
    static var crashMarker: URL { dir.appendingPathComponent("crashed") }

    static func load() -> HiddenState? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(HiddenState.self, from: data)
    }

    func save() {
        if entries.isEmpty {
            try? FileManager.default.removeItem(at: HiddenState.file)
        } else if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: HiddenState.file, options: .atomic)
        }
    }
}

private var crashMarkerFD: Int32 = -1
/// The watchdog's pid; its blocks must be left out of Ghost's own captures.
var watchdogPID: pid_t = 0

enum CrashGuard {
    /// Called in the Ghost process at launch.
    static func install() {
        try? FileManager.default.removeItem(at: HiddenState.crashMarker)
        crashMarkerFD = open(HiddenState.crashMarker.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        // Empty file = running; a byte written by the handler = crashed.
        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE] {
            signal(sig) { s in
                if crashMarkerFD >= 0 { var b: UInt8 = 1; _ = write(crashMarkerFD, &b, 1) }
                signal(s, SIG_DFL)
                raise(s)
            }
        }
        guard var exe = Bundle.main.executablePath else { return }
        // Through a link named "Ghost Watchdog" (made by build.sh), so Activity
        // Monitor doesn't list two processes both called Ghost.
        let link = (exe as NSString).deletingLastPathComponent + "/Ghost Watchdog"
        if FileManager.default.isExecutableFile(atPath: link) { exe = link }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["--watchdog", String(getpid())]
        if (try? p.run()) != nil { watchdogPID = p.processIdentifier }
    }

    /// Clean exit: take the watchdog (and its blocks) down first, then forget state.
    static func disarm() {
        if watchdogPID > 0 { kill(watchdogPID, SIGKILL) }
        try? FileManager.default.removeItem(at: HiddenState.file)
        if crashMarkerFD >= 0 { close(crashMarkerFD); crashMarkerFD = -1 }
        try? FileManager.default.removeItem(at: HiddenState.crashMarker)
    }

    /// Entry point of the watchdog process.
    static func runWatchdog(parent: pid_t) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let dog = Watchdog(parent: parent)
        dog.start()
        app.run()
        exit(0)
    }
}

/// Runs in the watchdog process (see above).
final class Watchdog {
    private let parent: pid_t
    private var blocks: [UInt32: NSWindow] = [:]
    private var source: DispatchSourceProcess?
    private var timer: Timer?
    private var state: HiddenState?
    private var stateStamp: Date?
    private var parentGoneAt: Date?
    private var relaunched = false
    /// What was covered when Ghost died: blocked until a new Ghost covers it.
    private var orphans: [HiddenState.Entry] = []

    init(parent: pid_t) { self.parent = parent }


    func start() {
        let src = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
        src.setEventHandler { [weak self] in self?.parentExited() }
        src.resume()
        source = src
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        if kill(parent, 0) != 0 { parentExited() }
    }

    private func reloadState() {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: HiddenState.file.path))?[.modificationDate] as? Date
        guard stamp != stateStamp else { return }
        stateStamp = stamp
        state = stamp == nil ? nil : HiddenState.load()
    }

    private func tick() {
        reloadState()
        // While Ghost runs: a block under each window it covers. After it died:
        // the windows it covered then, whatever a relaunched Ghost writes now.
        let entries = parentGoneAt != nil ? orphans
            : (state?.ghost == parent ? (state?.entries.filter(\.active) ?? []) : [])
        if entries.isEmpty, blocks.isEmpty, parentGoneAt == nil { return }   // nothing hidden: idle
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        var bounds: [UInt32: (pid: Int32, rect: CGRect)] = [:]
        for d in list {
            guard let id = (d[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let bd = d[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bd as CFDictionary) else { continue }
            bounds[id] = (pid, r)
        }
        var live: Set<UInt32> = []
        for e in entries {
            guard let w = bounds[e.window] else { continue }           // off screen: nothing to cover
            var rect = w.rect
            for (_, o) in bounds where o.pid == e.pid && o.rect.intersects(w.rect) { rect = rect.union(o.rect) }
            rect = rect.insetBy(dx: -48, dy: -48)
            let win = blocks[e.window] ?? makeBlock(e.window)
            let f = cocoaRect(rect)
            if win.frame != f { win.setFrame(f, display: false) }
            if !win.isVisible { win.orderFrontRegardless() }
            live.insert(e.window)
        }
        for (id, w) in blocks where !live.contains(id) { w.orderOut(nil); blocks[id] = nil }

        guard let gone = parentGoneAt else { return }
        let age = Date().timeIntervalSince(gone)
        if relaunched {
            // Done once a new Ghost covers every orphan (or the window closed).
            let covered = Set((state?.ghost != parent ? state?.entries ?? [] : []).filter(\.active).map(\.window))
            if orphans.allSatisfy({ covered.contains($0.window) || windowInfo($0.window) == nil }) {
                exit(0)
            }
            if age > 60 { exit(0) }
        } else if live.isEmpty || age > 10 {
            exit(0)                                                 // the apps are hidden now
        }
    }

    private func makeBlock(_ id: UInt32) -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = true
        w.backgroundColor = NSColor(calibratedWhite: 0.5, alpha: 1)
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = NSWindow.Level(rawValue: shieldLevel.rawValue - 1)   // just under Ghost's cover
        w.animationBehavior = .none
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        blocks[id] = w
        return w
    }

    private func parentExited() {
        guard parentGoneAt == nil else { return }
        parentGoneAt = Date()
        reloadState()
        guard let st = state, st.ghost == parent, !st.entries.isEmpty else { exit(0) }   // clean exit
        orphans = st.entries.filter(\.active)
        var allHidden = true
        for pid in Set(orphans.map(\.pid)) {
            allHidden = (NSRunningApplication(processIdentifier: pid)?.hide() ?? false) && allHidden
        }
        let crashed = ((try? Data(contentsOf: HiddenState.crashMarker))?.count ?? 0) > 0
        // After a crash, or if an app refused to hide, bring Ghost back to cover.
        guard crashed || !allHidden else { return }
        relaunched = true
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        cfg.createsNewApplicationInstance = true      // LaunchServices may still list the dead one
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, err in
            if let err { NSLog("Ghost watchdog: relaunch failed: \(err)") }
        }
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
        level = NSWindow.Level(rawValue: shieldLevel.rawValue + 2)   // above all overlays
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
    private let shield = ShareShield()
    /// Hide ghosted windows from screen sharing / recording (only you see them).
    private var hideInShares = UserDefaults.standard.bool(forKey: "HideInShares") {
        didSet { UserDefaults.standard.set(hideInShares, forKey: "HideInShares") }
    }
    private var unhideWhenCovered: Set<pid_t> = []
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

        CrashGuard.install()
        shield.onTargetsChanged = { [weak self] in self?.saveHiddenState() }
        shield.onActive = { [weak self] _, pid in
            self?.saveHiddenState()                   // the watchdog puts its block under it now
            self?.unhideIfCovered(pid)
        }
        if ensurePermission() { recoverHiddenWindows() }
    }

    // MARK: hide-in-shares bookkeeping

    private func saveHiddenState() {
        HiddenState(ghost: getpid(), entries: shield.targets.map {
            .init(window: $0.key, pid: $0.value.pid, alpha: Double($0.value.alpha), active: shield.isActive($0.key))
        }).save()
    }

    /// After a crash (or a force quit) the watchdog hid the apps that owned hidden
    /// windows. Cover those windows again, then bring the apps back.
    private func recoverHiddenWindows() {
        guard let st = HiddenState.load() else { return }
        hideInShares = true
        for e in st.entries where windowInfo(e.window)?.pid == e.pid {
            if shield.set(e.window, alpha: CGFloat(e.alpha)) { unhideWhenCovered.insert(e.pid) }
        }
        saveHiddenState()
    }

    private func unhideIfCovered(_ pid: pid_t) {
        guard unhideWhenCovered.contains(pid),
              shield.targets.filter({ $0.value.pid == pid }).keys.allSatisfy(shield.isActive) else { return }
        unhideWhenCovered.remove(pid)
        NSRunningApplication(processIdentifier: pid)?.unhide()
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
        shield.rescanSoon()                    // show the alert in the local view while hiding
        a.runModal()
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard !shield.isEmpty else { return .terminateNow }
        // macOS no longer lets one app hide another, so all we can do is warn.
        let a = NSAlert()
        a.messageText = "还有 \(shield.targets.count) 个窗口在共享中被隐藏"
        a.informativeText = "退出 Ghost 后，它们会立刻出现在共享和录屏画面里。"
        a.addButton(withTitle: "取消")
        a.addButton(withTitle: "仍然退出")
        NSApp.activate(ignoringOtherApps: true)
        shield.rescanSoon()
        return a.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_: Notification) {
        ghosts.values.forEach { $0.stop() }
        CrashGuard.disarm()
    }

    // MARK: opacity control

    private func percent(of id: CGWindowID) -> Double {
        if let a = shield.alpha(of: id) { return Double(a * 100) }
        return ghosts[id].map { Double($0.opacity * 100) } ?? 100
    }

    private func isGhosted(_ id: CGWindowID) -> Bool { ghosts[id] != nil || shield.alpha(of: id) != nil }

    private func setOpacity(for id: CGWindowID, percent: Double) {
        if percent >= 99 {                       // 100% = restore
            ghosts[id]?.stop()
            ghosts[id] = nil
            shield.remove(id)
            return
        }
        let op = CGFloat(percent) / 100
        if hideInShares {
            guard ensurePermission() else { hideHUD(); return }
            shield.set(id, alpha: op)
            return
        }
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
        shield.removeAll()
    }

    /// Switch modes, carrying every ghosted window and its opacity over.
    private func setHideInShares(_ on: Bool) {
        guard on != hideInShares else { return }
        let carried: [(CGWindowID, Double)] =
            ghosts.map { ($0.key, Double($0.value.opacity * 100)) } +
            shield.targets.map { ($0.key, Double($0.value.alpha * 100)) }
        if on {
            hideInShares = true
            carried.forEach { setOpacity(for: $0.0, percent: $0.1) }   // cover first…
            ghosts.values.forEach { $0.stop() }                        // …then drop the old overlays
            ghosts.removeAll()
        } else {
            hideInShares = false
            shield.removeAll()
            carried.forEach { setOpacity(for: $0.0, percent: $0.1) }
        }
    }

    /// Hotkey: toggle the frontmost app's top window between 100% and the default.
    func toggleFrontmost() {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let w = onScreenWindows().first(where: { $0.pid == pid }) else { return }
        setOpacity(for: w.id, percent: isGhosted(w.id) ? 100 : Double(defaultOpacity * 100))
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

    func menuWillOpen(_ menu: NSMenu) { shield.rescanSoon() }

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

        let hide = NSMenuItem(title: "共享/录屏时隐藏（只有你能看到）", action: #selector(toggleHideInShares), keyEquivalent: "")
        hide.state = hideInShares ? .on : .off
        menu.addItem(hide)

        let count = ghosts.count + shield.targets.count
        if count > 0 {
            menu.addItem(withTitle: "全部恢复 (\(count))", action: #selector(restoreAllAction), keyEquivalent: "")
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
            if isGhosted(w.id) { name += "   \(Int(percent(of: w.id)))%" }
            let it = NSMenuItem(title: name, action: #selector(toggleWindow(_:)), keyEquivalent: "")
            it.representedObject = w.id
            it.state = isGhosted(w.id) ? .on : .off
            menu.addItem(it)
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func toggleWindow(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? CGWindowID else { return }
        setOpacity(for: id, percent: isGhosted(id) ? 100 : Double(defaultOpacity * 100))
    }

    @objc private func toggleHideInShares() { setHideInShares(!hideInShares) }

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

func ghostMain() {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--watchdog"), i + 1 < args.count, let parent = Int32(args[i + 1]) {
        CrashGuard.runWatchdog(parent: parent)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
    app.run()
}

ghostMain()
