import AppKit

/// Milestone-1 shell: a text menu. The real face comes after the engine is proven.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine = Engine()
    var item: NSStatusItem!
    var usr1: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ n: Notification) {
        signal(SIGUSR1, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        s.setEventHandler { [weak self] in self?.dumpStatus() }
        s.resume(); usr1 = s
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        engine.onChange = { [weak self] in self?.rebuildMenu() }
        engine.start()
    }

    func applicationWillTerminate(_ n: Notification) { engine.shutdown() }

    func rebuildMenu() {
        item.button?.title = engine.running ? (engine.proc.bypass.load(ordering: .relaxed) ? "eq ○" : "eq ●") : "eq"
        let m = NSMenu()
        m.addItem(withTitle: "\(engine.deviceName) — " + (engine.running ? "curve on, preamp \(String(format: "%.1f", engine.preamp)) dB" : engine.curve == nil ? "no curve" : "off"), action: nil, keyEquivalent: "")
        if let p = engine.problem { m.addItem(withTitle: "⚠︎ " + p, action: nil, keyEquivalent: "") }
        m.addItem(.separator())
        let on = m.addItem(withTitle: "On", action: #selector(toggle), keyEquivalent: ""); on.target = self
        on.state = engine.enabled ? .on : .off
        let ab = m.addItem(withTitle: "Bypass (compare)", action: #selector(bypass), keyEquivalent: "b"); ab.target = self
        ab.state = engine.proc.bypass.load(ordering: .relaxed) ? .on : .off
        let ed = m.addItem(withTitle: "Edit curve…", action: #selector(edit), keyEquivalent: "e"); ed.target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = m
    }

    @objc func toggle() { engine.enabled.toggle() }
    @objc func bypass() { engine.proc.bypass.store(!engine.proc.bypass.load(ordering: .relaxed), ordering: .relaxed); rebuildMenu() }
    @objc func edit() {
        let url = Curves.file(for: engine.deviceName)
        if !FileManager.default.fileExists(atPath: url.path) { try? "Preamp: auto\n".write(to: url, atomically: true, encoding: .utf8) }
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
