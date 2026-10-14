import AppKit

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "selftest":
    exit(SelfTest.run(out: args.dropFirst().first))
default:
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
