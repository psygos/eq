import AppKit

/// The face: a light instrument plate with a torn scrap of semi-log graph paper taped to it.
/// The ink line is the curve's true response; the cut-paper dots are its bands (disc = bell,
/// half-disc = shelf, facing the side it lifts). Holding the round button flattens the line
/// while you hear the original. Drawn on demand only; nothing animates unless you're holding.
struct Face {
    var device = "MODE"
    var enabled = true
    var running = true
    var bands: [Band] = []
    var fs: Double = 48000
    var preamp: Double = 0
    var clipped = 0
    var hasCurve = true
    var problem: String?
    var flat: Double = 0            // 0 = curve, 1 = flat line (held)
    var held = false
}

enum Palette {
    static func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: a)
    }
    static let plate = rgb(0xE4E3DF), plateHi = rgb(0xF1F0EC), plateLo = rgb(0xC9C8C3)
    static let paper = rgb(0xFBFAF4), grid = rgb(0xB9CCE0), gridMajor = rgb(0x8FAACB)
    static let ink = rgb(0x151515), label = rgb(0x6B6A66), ballpoint = rgb(0x24357F)
    static let dots = [rgb(0xFF5A1F), rgb(0x2E5BFF), rgb(0xFFC21A), rgb(0x151515)]
    static let tape = rgb(0xF4EFD8, 0.78)
}

enum Type {
    static func mono(_ size: CGFloat, _ weight: String = "Rg") -> NSFont {
        NSFont(name: "MartianMono-Cn" + weight, size: size) ?? NSFont(name: "MartianMono-Std" + weight, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: weight == "Bd" ? .bold : .regular)
    }
    static func display(_ size: CGFloat) -> NSFont {
        NSFont(name: "PPNeueMachina-Ultrabold", size: size) ?? .systemFont(ofSize: size, weight: .heavy)
    }
    static func hand(_ size: CGFloat) -> NSFont {
        NSFont(name: "BradleyHandITCTT-Bold", size: size) ?? .systemFont(ofSize: size)
    }
}

/// Deterministic jitter so each device keeps the same scrap, tape and tear forever.
struct Seed {
    var s: UInt64
    init(_ text: String) { s = text.utf8.reduce(1469598103934665603) { ($0 ^ UInt64($1)) &* 1099511628211 } }
    mutating func next() -> CGFloat { s = s &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(s >> 11) / CGFloat(1 << 53) }
    mutating func range(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * next() }
}

final class FaceView: NSView {
    static let size = NSSize(width: 320, height: 236)
    var face = Face() { didSet { needsDisplay = true } }
    var onHold: (Bool) -> Void = { _ in }
    var onPower: () -> Void = {}
    var onEdit: () -> Void = {}

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Layout (top-left origin)
    let scrap = NSRect(x: 18, y: 46, width: 284, height: 128)
    var holdCenter: NSPoint { NSPoint(x: 38, y: 204) }
    let powerHit = NSRect(x: 240, y: 8, width: 72, height: 30)

    // MARK: drawing

    override func draw(_ dirty: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        drawPlate(cg)
        drawHeader()
        drawScrap(cg)
        drawFooter(cg)
    }

    private func drawPlate(_ cg: CGContext) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let body = NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14)
        Palette.plate.setFill(); body.fill()
        // machined edge: light on top, shade below
        NSGraphicsContext.saveGraphicsState()
        body.addClip()
        Palette.plateHi.setStroke()
        let top = NSBezierPath(); top.move(to: NSPoint(x: 14, y: 1.5)); top.line(to: NSPoint(x: r.maxX - 14, y: 1.5)); top.lineWidth = 1.5; top.stroke()
        NSGraphicsContext.restoreGraphicsState()
        Palette.plateLo.withAlphaComponent(0.9).setStroke(); body.lineWidth = 1; body.stroke()
    }

    private func drawHeader() {
        ("eq" as NSString).draw(at: NSPoint(x: 18, y: 10), withAttributes: [.font: Type.display(22), .foregroundColor: Palette.ink])
        // power: a lamp and its word, TE style
        let lit = face.enabled && face.running
        let lamp = NSRect(x: 252, y: 18, width: 9, height: 9)
        let p = NSBezierPath(ovalIn: lamp)
        if lit {
            Palette.dots[0].withAlphaComponent(0.25).setFill(); NSBezierPath(ovalIn: lamp.insetBy(dx: -3, dy: -3)).fill()
            Palette.dots[0].setFill(); p.fill()
        } else {
            Palette.label.setStroke(); p.lineWidth = 1.2; p.stroke()
        }
        let word = face.enabled ? (face.hasCurve ? "on" : "idle") : "off"
        (word as NSString).draw(at: NSPoint(x: 267, y: 15), withAttributes: [.font: Type.mono(9.5), .foregroundColor: Palette.ink])
    }

    /// x position on the paper for a frequency (20 Hz – 20 kHz, log)
    private func x(_ f: Double, in r: NSRect) -> CGFloat {
        r.minX + 10 + (r.width - 20) * CGFloat(log10(f / 20) / 3)
    }

    private func drawScrap(_ cg: CGContext) {
        var seed = Seed(face.device)
        let angle = seed.range(-1.6, 1.6)
        let c = NSPoint(x: scrap.midX, y: scrap.midY)
        cg.saveGState()
        cg.translateBy(x: c.x, y: c.y); cg.rotate(by: angle * .pi / 180); cg.translateBy(x: -c.x, y: -c.y)

        // torn paper: straight sides, ripped top and bottom
        let paper = NSBezierPath()
        var tearSeed = seed
        paper.move(to: NSPoint(x: scrap.minX, y: scrap.minY + tearSeed.range(0, 2)))
        var xx = scrap.minX
        while xx < scrap.maxX { xx = min(scrap.maxX, xx + tearSeed.range(2.5, 5)); paper.line(to: NSPoint(x: xx, y: scrap.minY + tearSeed.range(-1.2, 1.6))) }
        paper.line(to: NSPoint(x: scrap.maxX, y: scrap.maxY))
        xx = scrap.maxX
        while xx > scrap.minX { xx = max(scrap.minX, xx - tearSeed.range(2.5, 5)); paper.line(to: NSPoint(x: xx, y: scrap.maxY + tearSeed.range(-1.6, 1.2))) }
        paper.close()
        seed = tearSeed

        let shadow = NSShadow(); shadow.shadowColor = NSColor(white: 0, alpha: 0.22); shadow.shadowOffset = NSSize(width: 0, height: -1.5); shadow.shadowBlurRadius = 3
        NSGraphicsContext.saveGraphicsState(); shadow.set(); Palette.paper.setFill(); paper.fill(); NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        paper.addClip()
        let plot = scrap.insetBy(dx: 0, dy: 14)
        let range = dbRange()
        func y(_ db: Double) -> CGFloat { plot.midY - CGFloat(db / range) * (plot.height / 2) }

        // semi-log graph paper: the chart's own grid (decades, their 2…9 steps, 3 dB rows)
        for decade in [20.0, 100, 1000, 10000] {
            for k in 1...9 {
                let f = (decade == 20 ? 10 : decade) * Double(k)
                guard f >= 20, f <= 20000 else { continue }
                let major = k == 1
                (major ? Palette.gridMajor : Palette.grid).withAlphaComponent(major ? 0.8 : 0.55).setStroke()
                let l = NSBezierPath(); l.move(to: NSPoint(x: x(f, in: scrap), y: scrap.minY)); l.line(to: NSPoint(x: x(f, in: scrap), y: scrap.maxY))
                l.lineWidth = major ? 0.8 : 0.5; l.stroke()
            }
        }
        var db = -range
        while db <= range + 1e-9 {
            (db == 0 ? Palette.gridMajor : Palette.grid).withAlphaComponent(db == 0 ? 0.9 : 0.5).setStroke()
            let l = NSBezierPath(); l.move(to: NSPoint(x: scrap.minX, y: y(db))); l.line(to: NSPoint(x: scrap.maxX, y: y(db)))
            l.lineWidth = db == 0 ? 0.9 : 0.5; l.stroke()
            db += 3
        }
        for (f, t) in [(100.0, "100"), (1000, "1k"), (10000, "10k")] {
            (t as NSString).draw(at: NSPoint(x: x(f, in: scrap) + 2, y: scrap.maxY - 13),
                                 withAttributes: [.font: Type.mono(7), .foregroundColor: Palette.gridMajor])
        }

        if face.hasCurve {
            // the ink: true response of the loaded filters, scaled toward flat while held
            let bq = face.bands.map { design($0, fs: face.fs) }
            let k = 1 - face.flat
            let line = NSBezierPath()
            let steps = 220
            for i in 0...steps {
                let f = 20 * pow(1000, Double(i) / Double(steps))
                let p = NSPoint(x: x(f, in: scrap), y: y(gainDB(bq, f, fs: face.fs) * k))
                i == 0 ? line.move(to: p) : line.line(to: p)
            }
            line.lineCapStyle = .round; line.lineJoinStyle = .round
            let alpha: CGFloat = face.enabled ? 1 : 0.35
            Palette.ink.withAlphaComponent(0.10 * alpha).setStroke(); line.lineWidth = 4; line.stroke()   // bleed
            Palette.ink.withAlphaComponent(alpha).setStroke(); line.lineWidth = 1.8; line.stroke()

            // cut-paper dots on the line at each band
            for (i, b) in face.bands.enumerated() {
                let p = NSPoint(x: x(min(max(b.fc, 20), 20000), in: scrap), y: y(gainDB(bq, b.fc, fs: face.fs) * k))
                drawDot(cg, at: p, kind: b.kind, color: Palette.dots[i % Palette.dots.count].withAlphaComponent(alpha), tilt: seed.range(-20, 20))
            }
        } else {
            ("no curve yet — click to write one" as NSString).draw(at: NSPoint(x: scrap.minX + 16, y: scrap.midY - 10),
                withAttributes: [.font: Type.hand(15), .foregroundColor: Palette.ballpoint.withAlphaComponent(0.85)])
        }
        NSGraphicsContext.restoreGraphicsState()

        // tape over the top-left corner, with the device written on it by hand
        let tapeAngle = seed.range(-9, -4)
        let name = face.device as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: Type.hand(14), .foregroundColor: Palette.ballpoint]
        let w = max(64, name.size(withAttributes: attrs).width + 22)
        let t = NSRect(x: scrap.minX - 8, y: scrap.minY - 11, width: w, height: 22)
        cg.saveGState()
        cg.translateBy(x: t.midX, y: t.midY); cg.rotate(by: tapeAngle * .pi / 180); cg.translateBy(x: -t.midX, y: -t.midY)
        let tape = NSBezierPath()
        tape.move(to: NSPoint(x: t.minX, y: t.minY))
        tape.line(to: NSPoint(x: t.maxX, y: t.minY))
        var ty = t.minY
        while ty < t.maxY { ty = min(t.maxY, ty + seed.range(2, 4)); tape.line(to: NSPoint(x: t.maxX + seed.range(-1.5, 1.5), y: ty)) }
        tape.line(to: NSPoint(x: t.minX, y: t.maxY))
        ty = t.maxY
        while ty > t.minY { ty = max(t.minY, ty - seed.range(2, 4)); tape.line(to: NSPoint(x: t.minX + seed.range(-1.5, 1.5), y: ty)) }
        tape.close()
        Palette.tape.setFill(); tape.fill()
        name.draw(at: NSPoint(x: t.minX + 10, y: t.minY + 1.5), withAttributes: attrs)
        cg.restoreGState()

        cg.restoreGState()
    }

    private func dbRange() -> Double {
        let bq = face.bands.map { design($0, fs: face.fs) }
        var m = 0.0
        for i in 0...200 { m = max(m, abs(gainDB(bq, 20 * pow(1000, Double(i) / 200), fs: face.fs))) }
        return max(6, (m * 1.2 / 3).rounded(.up) * 3)
    }

    private func drawDot(_ cg: CGContext, at p: NSPoint, kind: Kind, color: NSColor, tilt: CGFloat) {
        let r: CGFloat = 5.5
        let path = NSBezierPath()
        switch kind {
        case .pk: path.appendOval(in: NSRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        case .lsc: path.move(to: NSPoint(x: p.x, y: p.y - r)); path.appendArc(withCenter: p, radius: r, startAngle: 270, endAngle: 90, clockwise: true); path.close()
        case .hsc: path.move(to: NSPoint(x: p.x, y: p.y - r)); path.appendArc(withCenter: p, radius: r, startAngle: 270, endAngle: 90, clockwise: false); path.close()
        }
        let s = NSShadow(); s.shadowColor = NSColor(white: 0, alpha: 0.28); s.shadowOffset = NSSize(width: 0.6, height: -0.8); s.shadowBlurRadius = 0.8
        NSGraphicsContext.saveGraphicsState(); s.set(); color.setFill(); path.fill(); NSGraphicsContext.restoreGraphicsState()
    }

    private func drawFooter(_ cg: CGContext) {
        // the hold button: a black cap that sinks when pressed
        let c = holdCenter, r: CGFloat = 17
        let held = face.held
        let cap = NSRect(x: c.x - r, y: c.y - r + (held ? 1 : 0), width: 2 * r, height: 2 * r)
        Palette.plateLo.setFill(); NSBezierPath(ovalIn: NSRect(x: c.x - r - 1.5, y: c.y - r - 0.5, width: 2 * r + 3, height: 2 * r + 3)).fill()
        (held ? Palette.rgb(0x2A2A2A) : Palette.ink).setFill(); NSBezierPath(ovalIn: cap).fill()
        if !held {
            Palette.rgb(0xFFFFFF, 0.12).setStroke()
            let hi = NSBezierPath(); hi.appendArc(withCenter: NSPoint(x: cap.midX, y: cap.midY), radius: r - 2.5, startAngle: 200, endAngle: 340, clockwise: false)
            hi.lineWidth = 1.5; hi.stroke()
        }
        let mono = Type.mono(9.5), small = Type.mono(7.5)
        (held ? "original" : "hold") .draw(at: NSPoint(x: c.x + r + 10, y: c.y - 12), withAttributes: [.font: mono, .foregroundColor: Palette.ink])
        "to compare".draw(at: NSPoint(x: c.x + r + 10, y: c.y + 1), withAttributes: [.font: small, .foregroundColor: Palette.label])

        // readouts, right-aligned: value over label
        var items: [(String, String)] = [(String(format: "%+.1f", face.preamp).replacingOccurrences(of: "-", with: "−"), "db pre"),
                                         ("\(face.clipped)", "clip"),
                                         (face.fs >= 1000 ? "\(Int(face.fs / 1000))k" : "—", "rate")]
        if !face.hasCurve { items = [("—", "db pre"), ("—", "clip"), (face.fs >= 1000 ? "\(Int(face.fs / 1000))k" : "—", "rate")] }
        var right = bounds.maxX - 18
        for (v, l) in items.reversed() {
            let va: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: Palette.ink]
            let la: [NSAttributedString.Key: Any] = [.font: small, .foregroundColor: Palette.label]
            let w = max(v.size(withAttributes: va).width, l.size(withAttributes: la).width)
            v.draw(at: NSPoint(x: right - v.size(withAttributes: va).width, y: c.y - 12), withAttributes: va)
            l.draw(at: NSPoint(x: right - l.size(withAttributes: la).width, y: c.y + 1), withAttributes: la)
            right -= w + 16
        }
        if let p = face.problem {
            (p as NSString).draw(in: NSRect(x: 18, y: bounds.maxY - 14, width: bounds.width - 36, height: 12),
                                 withAttributes: [.font: Type.mono(7), .foregroundColor: Palette.dots[0]])
        }
    }

    // MARK: input

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if hypot(p.x - holdCenter.x, p.y - holdCenter.y) <= 22 { onHold(true) }
        else if powerHit.contains(p) { onPower() }
        else if scrap.insetBy(dx: -6, dy: -10).contains(p) { onEdit() }
    }
    override func mouseUp(with e: NSEvent) { if face.held { onHold(false) } }
    override func keyDown(with e: NSEvent) {
        if e.charactersIgnoringModifiers == " " { if !e.isARepeat { onHold(true) } }
        else if e.keyCode == 53 { window?.orderOut(nil) }        // esc
        else { super.keyDown(with: e) }
    }
    override func keyUp(with e: NSEvent) { if e.charactersIgnoringModifiers == " " { onHold(false) } }
}

extension String {
    func draw(at p: NSPoint, withAttributes a: [NSAttributedString.Key: Any]) { (self as NSString).draw(at: p, withAttributes: a) }
    func size(withAttributes a: [NSAttributedString.Key: Any]) -> NSSize { (self as NSString).size(withAttributes: a) }
}

/// The menu-bar glyph: your curve in miniature inside a small frame; flat when off or held.
func statusGlyph(bands: [Band], fs: Double, live: Bool) -> NSImage {
    let img = NSImage(size: NSSize(width: 22, height: 16), flipped: true) { r in
        let frame = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 2.5, width: 19, height: 11), xRadius: 3, yRadius: 3)
        frame.lineWidth = 1.2; NSColor.black.setStroke(); frame.stroke()
        let bq = live ? bands.map { design($0, fs: fs) } : []
        var m = 0.0
        for i in 0...40 { m = max(m, abs(gainDB(bq, 20 * pow(1000, Double(i) / 40), fs: fs))) }
        let scale = m > 0 ? 3.6 / m : 0
        let line = NSBezierPath()
        for i in 0...40 {
            let f = 20 * pow(1000, Double(i) / 40)
            let p = NSPoint(x: 4 + 14 * CGFloat(i) / 40, y: 8 - CGFloat(gainDB(bq, f, fs: fs) * scale))
            i == 0 ? line.move(to: p) : line.line(to: p)
        }
        line.lineWidth = 1.4; line.lineCapStyle = .round; line.stroke()
        return true
    }
    img.isTemplate = true
    return img
}

/// eq render <file.png>: draws the face offline at 2x for review, on a plain desk.
func renderFace(_ faces: [Face], to path: String) {
    let pad: CGFloat = 28, gap: CGFloat = 24
    let W = pad * 2 + CGFloat(faces.count) * FaceView.size.width + CGFloat(faces.count - 1) * gap
    let H = pad * 2 + FaceView.size.height
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * 2), pixelsHigh: Int(H * 2), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    Palette.rgb(0xB8BCC2).setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
    for (i, f) in faces.enumerated() {
        let v = FaceView(frame: NSRect(origin: .zero, size: FaceView.size)); v.face = f
        let ox = pad + CGFloat(i) * (FaceView.size.width + gap)
        let s = NSShadow(); s.shadowColor = NSColor(white: 0, alpha: 0.3); s.shadowOffset = NSSize(width: 0, height: -6); s.shadowBlurRadius = 14
        NSGraphicsContext.saveGraphicsState(); s.set()
        NSColor.black.setFill(); NSBezierPath(roundedRect: NSRect(x: ox, y: pad, width: FaceView.size.width, height: FaceView.size.height), xRadius: 14, yRadius: 14).fill()
        NSGraphicsContext.restoreGraphicsState()
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.saveGState()
        ctx.translateBy(x: ox, y: pad + FaceView.size.height); ctx.scaleBy(x: 1, y: -1)
        let outer = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        v.draw(v.bounds)
        NSGraphicsContext.current = outer
        ctx.restoreGState()
    }
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
