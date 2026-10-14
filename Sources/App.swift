import AppKit
import ServiceManagement

/// A panel that can take keys (space = hold) without activating the app.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let engine = Engine()
    var item: NSStatusItem!
    var panel: KeyPanel!
    var face: FaceView!
    var usr1: DispatchSourceSignal?
    var outside: Any?
    var anim: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        signal(SIGUSR1, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        s.setEventHandler { [weak self] in self?.dumpStatus() }
        s.resume(); usr1 = s

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        panel = KeyPanel(contentRect: NSRect(origin: .zero, size: FaceView.size),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .popUpMenu; panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        face = FaceView(frame: NSRect(origin: .zero, size: FaceView.size))
        face.onHold = { [weak self] in self?.hold($0) }
        face.onPower = { [weak self] in self?.engine.enabled.toggle() }
        face.onEdit = { [weak self] in self?.edit() }
        panel.contentView = face

        engine.onChange = { [weak self] in self?.update() }
        engine.start()
    }

    func applicationWillTerminate(_ n: Notification) { engine.shutdown() }

    /// Opening eq again (Spotlight, Finder, `open -a eq`) shows the face.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        show(); return false
    }

    // MARK: state → face and glyph

    func update() {
        var f = face.face
        f.device = engine.deviceName
        f.enabled = engine.enabled
        f.running = engine.running
        f.hasCurve = engine.curve != nil
        f.bands = engine.curve?.bands ?? []
        f.fs = engine.chain?.fs ?? HAL.rate(engine.device)
        f.preamp = engine.preamp
        f.clipped = engine.proc.clipped.load(ordering: .relaxed)
        f.problem = engine.problem
        face.face = f
        item.button?.image = statusGlyph(bands: f.bands, fs: f.fs, live: f.running && !f.held)
    }

    // MARK: menu-bar item

    @objc func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu() }
        else if panel.isVisible { hide() } else { show() }
    }

    func show() {
        update()
        guard let b = item.button, let w = b.window else { return }
        let r = w.convertToScreen(b.convert(b.bounds, to: nil))
        let screen = (w.screen ?? NSScreen.main)!.visibleFrame
        let x = min(max(r.midX - FaceView.size.width / 2, screen.minX + 8), screen.maxX - FaceView.size.width - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: r.minY - FaceView.size.height - 6))
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(face)
        outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.hide() }
    }

    func hide() {
        if face.face.held { hold(false) }
        panel.orderOut(nil)
        if let o = outside { NSEvent.removeMonitor(o); outside = nil }
    }

    func windowDidResignKey(_ n: Notification) { hide() }

    func showMenu() {
        hide()
        let m = NSMenu()
        let login = m.addItem(withTitle: "Open at login", action: #selector(toggleLogin), keyEquivalent: ""); login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let dir = m.addItem(withTitle: "Curves folder", action: #selector(openFolder), keyEquivalent: ""); dir.target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Quit eq", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = m
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc func toggleLogin() {
        let s = SMAppService.mainApp
        do { if s.status == .enabled { try s.unregister() } else { try s.register() } }
        catch { NSLog("eq: login item: \(error)") }
    }

    @objc func openFolder() { NSWorkspace.shared.open(Curves.dir) }

    // MARK: hold to compare

    func hold(_ down: Bool) {
        guard face.face.held != down else { return }
        engine.proc.bypass.store(down, ordering: .relaxed)
        face.face.held = down
        item.button?.image = statusGlyph(bands: face.face.bands, fs: face.face.fs, live: face.face.running && !down)
        // the ink falls flat / springs back over 140 ms; the timer exists only during the move
        let from = face.face.flat, to: Double = down ? 1 : 0, start = CACurrentMediaTime()
        anim?.invalidate()
        anim = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let u = min(1, (CACurrentMediaTime() - start) / 0.14)
            let e = down ? u * u : 1 - pow(1 - u, 3) * cos(u * 5)        // drop; spring back with a little bounce
            self.face.face.flat = from + (to - from) * min(max(e, 0), 1.08)
            if u >= 1 { self.face.face.flat = to; t.invalidate(); self.anim = nil }
        }
    }

    func edit() {
        let url = Curves.file(for: engine.deviceName)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? """
            # \(engine.deviceName). Equalizer APO / AutoEQ format; save to apply.
            Preamp: auto
            Filter 1: ON PK Fc 1000 Hz Gain 0.0 dB Q 1.00

            """.write(to: url, atomically: true, encoding: .utf8)
        }
        hide()
        NSWorkspace.shared.open(url)
    }

    /// kill -USR1 <pid> writes the live state for the test bench.
    func dumpStatus() {
        let (pin, pout) = engine.proc.takePeaks()
        let s: [String: Any] = [
            "pid": getpid(), "device": engine.deviceName, "running": engine.running, "enabled": engine.enabled,
            "bypass": engine.proc.bypass.load(ordering: .relaxed), "preamp": engine.preamp,
            "bands": engine.curve?.bands.count ?? -1, "problem": engine.problem ?? "",
            "blocks": engine.proc.blocks.load(ordering: .relaxed), "clipped": engine.proc.clipped.load(ordering: .relaxed),
            "peakIn": pin, "peakOut": pout,
            "fs": engine.chain?.fs ?? 0, "layoutIn": engine.chain?.layoutIn ?? [], "layoutOut": engine.chain?.layoutOut ?? [],
        ]
        let data = try! JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted, .sortedKeys])
        try? data.write(to: URL(fileURLWithPath: NSTemporaryDirectory() + "eq-status.json"))
    }
}
