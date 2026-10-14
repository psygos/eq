import AppKit

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "selftest":
    exit(SelfTest.run(out: args.dropFirst().first))
case "render":
    let curve = (try? Curves.load(for: "MODE")) ?? nil
    var a = Face(); a.curve = curve; a.preamp = curve.map { resolvedPreamp($0, fs: 48000) } ?? 0
    a.slots = [true, true, false, false]; a.activeSlot = 0
    var b = a; b.held = true; b.flat = 1; b.enabled = true
    var c = Face(); c.device = "MacBook Pro Speakers"; c.curve = nil; c.running = false; c.enabled = false
    renderFace([a, b, c], to: args.count > 1 ? args[1] : "face.png")
    exit(0)
default:
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
