import AppKit

/// The face: a light instrument plate with a torn scrap of semi-log graph paper taped to it.
/// The ink line is the curve's true response; the cut-paper dots are its bands (disc = bell,
/// half-disc = shelf, facing the side it lifts) and they can be moved by hand. Keys are keys:
/// they sink when pressed. Drawn on demand only.
struct Face {
    var device = "MODE"
    var enabled = true
    var running = true
    var curve: Curve? = Curve(preamp: nil, bands: [])
    var fs: Double = 48000
    var preamp: Double = 0
    var clipped = 0
    var problem: String?
    var flat: Double = 0            // 0 = curve, 1 = flat line (held)
    var held = false
    var slots = [false, false, false, false]
    var activeSlot: Int?
    var bands: [Band] { curve?.bands ?? [] }
}

enum Palette {
    static func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: a)
    }
    static let plate = rgb(0xE4E3DF), plateHi = rgb(0xF1F0EC), plateLo = rgb(0xC9C8C3)
    static let cap = rgb(0xF6F5F2), capSkirt = rgb(0xB7B6B1), well = rgb(0xCFCEC9)
    static let paper = rgb(0xFBFAF4), grid = rgb(0xB9CCE0), gridMajor = rgb(0x8FAACB)
    static let ink = rgb(0x151515), label = rgb(0x6B6A66), ballpoint = rgb(0x24357F)
    static let orange = rgb(0xFF5A1F)
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
    static let size = NSSize(width: 320, height: 240)
    var face = Face() { didSet { needsDisplay = true } }

    var onHold: (Bool) -> Void = { _ in }
    var onPower: () -> Void = {}
    var onSlot: (Int, Bool) -> Void = { _, _ in }        // slot, save
    var onBeginEdit: () -> Void = {}                       // before a change: for undo
    var onEdit: (Curve, Bool) -> Void = { _, _ in }        // curve, final
    var onUndo: (Bool) -> Void = { _ in }                  // redo?
    var onOpenFile: () -> Void = {}

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: layout (top-left origin)

    let scrap = NSRect(x: 18, y: 52, width: 284, height: 124)
    let powerKey = NSRect(x: 254, y: 12, width: 48, height: 26)
    let holdCenter = NSPoint(x: 38, y: 210)
    func slotKey(_ i: Int) -> NSRect { NSRect(x: 186 + CGFloat(i) * 30, y: 198, width: 24, height: 24) }
    var plot: NSRect { scrap.insetBy(dx: 0, dy: 14) }

    // MARK: interaction state

    enum Key: Equatable { case power, slot(Int), hold }
    private var pressed: Key?
    private var flashSlot: Int?
    private var saveTimer: Timer?
    private var savedDuringPress = false
    private var grab: (index: Int, start: Band, startY: CGFloat, range: Double)?
    private var hoverDot: Int?
    private var readout: (index: Int, until: Date)?
    private var scrollPersist: Timer?
    private var tracking: NSTrackingArea?

    // MARK: paper geometry: the scrap is rotated a little; mouse points are rotated back

    private var angle: CGFloat { var s = Seed(face.device); return s.range(-1.6, 1.6) }
    private var paperTransform: CGAffineTransform {
        let c = CGPoint(x: scrap.midX, y: scrap.midY)
        return CGAffineTransform(translationX: c.x, y: c.y).rotated(by: angle * .pi / 180).translatedBy(x: -c.x, y: -c.y)
    }
    private func toPaper(_ p: NSPoint) -> NSPoint { p.applying(paperTransform.inverted()) }

    private func x(_ f: Double) -> CGFloat { scrap.minX + 10 + (scrap.width - 20) * CGFloat(log10(f / 20) / 3) }
    private func f(_ x: CGFloat) -> Double { 20 * pow(10, 3 * Double((x - scrap.minX - 10) / (scrap.width - 20))) }
    private func y(_ db: Double, _ range: Double) -> CGFloat { plot.midY - CGFloat(db / range) * (plot.height / 2) }
    private func db(_ y: CGFloat, _ range: Double) -> Double { Double((plot.midY - y) / (plot.height / 2)) * range }

    private var range: Double {
        if let d = grab { return d.range }
        let bq = face.bands.map { design($0, fs: face.fs) }
        var m = 0.0
        for i in 0...200 { m = max(m, abs(gainDB(bq, 20 * pow(1000, Double(i) / 200), fs: face.fs))) }
        return max(6, (m * 1.2 / 3).rounded(.up) * 3)
    }

    private func dotPoints(_ range: Double) -> [NSPoint] {
        let bq = face.bands.map { design($0, fs: face.fs) }
        let k = 1 - face.flat
        return face.bands.map { NSPoint(x: x(min(max($0.fc, 20), 20000)), y: y(gainDB(bq, $0.fc, fs: face.fs) * k, range)) }
    }

    private func dot(at viewPoint: NSPoint) -> Int? {
        let p = toPaper(viewPoint)
        let pts = dotPoints(range)
        return pts.indices.min(by: { hypot(pts[$0].x - p.x, pts[$0].y - p.y) < hypot(pts[$1].x - p.x, pts[$1].y - p.y) })
            .flatMap { hypot(pts[$0].x - p.x, pts[$0].y - p.y) <= 10 ? $0 : nil }
    }

    // MARK: drawing

    override func draw(_ dirty: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        drawPlate()
        drawHeader()
        drawScrap(cg)
        drawFooter()
    }

    private func drawPlate() {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let body = NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14)
        Palette.plate.setFill(); body.fill()
        NSGraphicsContext.saveGraphicsState()
        body.addClip()
        Palette.plateHi.setStroke()
        let top = NSBezierPath(); top.move(to: NSPoint(x: 14, y: 1.5)); top.line(to: NSPoint(x: r.maxX - 14, y: 1.5)); top.lineWidth = 1.5; top.stroke()
        NSGraphicsContext.restoreGraphicsState()
        Palette.plateLo.withAlphaComponent(0.9).setStroke(); body.lineWidth = 1; body.stroke()
    }

    /// A key: a cap sitting in a well, with a skirt that shows its height. Pressed, it sinks.
    private func drawKey(_ r: NSRect, pressed: Bool, fill: NSColor = Palette.cap) {
        let well = NSBezierPath(roundedRect: r.insetBy(dx: -2, dy: -2), xRadius: 7, yRadius: 7)
        Palette.well.setFill(); well.fill()
        let travel: CGFloat = pressed ? 2 : 0
        let skirt = NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.minY + travel, width: r.width, height: r.height - travel), xRadius: 5, yRadius: 5)
        Palette.capSkirt.setFill(); skirt.fill()
        let cap = NSRect(x: r.minX + 0.5, y: r.minY + travel, width: r.width - 1, height: r.height - (pressed ? 2.5 : 3))
        let c = NSBezierPath(roundedRect: cap, xRadius: 4.5, yRadius: 4.5)
        if !pressed {
            let s = NSShadow(); s.shadowColor = NSColor(white: 0, alpha: 0.18); s.shadowOffset = NSSize(width: 0, height: -1.5); s.shadowBlurRadius = 2
            NSGraphicsContext.saveGraphicsState(); s.set(); fill.setFill(); c.fill(); NSGraphicsContext.restoreGraphicsState()
        } else {
            fill.blended(withFraction: 0.06, of: .black)!.setFill(); c.fill()
        }
    }

    private func led(_ center: NSPoint, lit: Bool, size: CGFloat = 6) {
        let r = NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        if lit {
            Palette.orange.withAlphaComponent(0.28).setFill(); NSBezierPath(ovalIn: r.insetBy(dx: -2.5, dy: -2.5)).fill()
            Palette.orange.setFill(); NSBezierPath(ovalIn: r).fill()
        } else {
            Palette.rgb(0x9C9B96).setFill(); NSBezierPath(ovalIn: r).fill()
        }
    }

    private func drawHeader() {
        "eq".draw(at: NSPoint(x: 18, y: 10), withAttributes: [.font: Type.display(22), .foregroundColor: Palette.ink])

        // readouts: value over label, right-aligned up to the power key
        let mono = Type.mono(9.5), small = Type.mono(7.5)
        let has = face.curve != nil
        let items: [(String, String)] = [
            (has ? String(format: "%+.1f", face.preamp).replacingOccurrences(of: "-", with: "−") : "—", "db pre"),
            (has ? "\(face.clipped)" : "—", "clip"),
            (face.fs >= 1000 ? "\(Int(face.fs / 1000))k" : "—", "rate")]
        var right = powerKey.minX - 14
        for (v, l) in items.reversed() {
            let va: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: Palette.ink]
            let la: [NSAttributedString.Key: Any] = [.font: small, .foregroundColor: Palette.label]
            let w = max(v.size(withAttributes: va).width, l.size(withAttributes: la).width)
            v.draw(at: NSPoint(x: right - v.size(withAttributes: va).width, y: 12), withAttributes: va)
            l.draw(at: NSPoint(x: right - l.size(withAttributes: la).width, y: 25), withAttributes: la)
            right -= w + 12
        }

        // power key with its lamp
        let down = pressed == .power
        drawKey(powerKey, pressed: down)
        let t: CGFloat = down ? 2 : 0
        led(NSPoint(x: powerKey.minX + 12, y: powerKey.midY - 1.5 + t), lit: face.enabled)
        (face.enabled ? "on" : "off").draw(at: NSPoint(x: powerKey.minX + 20, y: powerKey.minY + 5 + t),
                                          withAttributes: [.font: Type.mono(9.5), .foregroundColor: Palette.ink])
    }

    private func drawScrap(_ cg: CGContext) {
        var seed = Seed(face.device)
        _ = seed.range(-1.6, 1.6)                      // the angle (see `angle`)
        cg.saveGState()
        cg.concatenate(paperTransform)

        // torn paper: straight sides, ripped top and bottom
        let paper = NSBezierPath()
        paper.move(to: NSPoint(x: scrap.minX, y: scrap.minY + seed.range(0, 2)))
        var xx = scrap.minX
        while xx < scrap.maxX { xx = min(scrap.maxX, xx + seed.range(2.5, 5)); paper.line(to: NSPoint(x: xx, y: scrap.minY + seed.range(-1.2, 1.6))) }
        paper.line(to: NSPoint(x: scrap.maxX, y: scrap.maxY))
        xx = scrap.maxX
        while xx > scrap.minX { xx = max(scrap.minX, xx - seed.range(2.5, 5)); paper.line(to: NSPoint(x: xx, y: scrap.maxY + seed.range(-1.6, 1.2))) }
        paper.close()

        let shadow = NSShadow(); shadow.shadowColor = NSColor(white: 0, alpha: 0.22); shadow.shadowOffset = NSSize(width: 0, height: -1.5); shadow.shadowBlurRadius = 3
        NSGraphicsContext.saveGraphicsState(); shadow.set(); Palette.paper.setFill(); paper.fill(); NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        paper.addClip()
        let range = self.range

        // semi-log graph paper: the chart's own grid (decades, their 2…9 steps, 3 dB rows)
        for decade in [10.0, 100, 1000, 10000] {
            for k in 1...9 {
                let fq = decade * Double(k)
                guard fq >= 20, fq <= 20000 else { continue }
                let major = k == 1
                (major ? Palette.gridMajor : Palette.grid).withAlphaComponent(major ? 0.8 : 0.55).setStroke()
                let l = NSBezierPath(); l.move(to: NSPoint(x: x(fq), y: scrap.minY)); l.line(to: NSPoint(x: x(fq), y: scrap.maxY))
                l.lineWidth = major ? 0.8 : 0.5; l.stroke()
            }
        }
        var d = -range
        while d <= range + 1e-9 {
            (d == 0 ? Palette.gridMajor : Palette.grid).withAlphaComponent(d == 0 ? 0.9 : 0.5).setStroke()
            let l = NSBezierPath(); l.move(to: NSPoint(x: scrap.minX, y: y(d, range))); l.line(to: NSPoint(x: scrap.maxX, y: y(d, range)))
            l.lineWidth = d == 0 ? 0.9 : 0.5; l.stroke()
            d += 3
        }
        for (fq, t) in [(100.0, "100"), (1000, "1k"), (10000, "10k")] {
            t.draw(at: NSPoint(x: x(fq) + 2, y: scrap.maxY - 13), withAttributes: [.font: Type.mono(7), .foregroundColor: Palette.gridMajor])
        }

        if face.curve != nil {
            // the ink: true response of the loaded filters, scaled toward flat while held
            let bq = face.bands.map { design($0, fs: face.fs) }
            let k = 1 - face.flat
            let line = NSBezierPath()
            for i in 0...220 {
                let fq = 20 * pow(1000, Double(i) / 220)
                let p = NSPoint(x: x(fq), y: y(gainDB(bq, fq, fs: face.fs) * k, range))
                i == 0 ? line.move(to: p) : line.line(to: p)
            }
            line.lineCapStyle = .round; line.lineJoinStyle = .round
            let alpha: CGFloat = face.enabled ? 1 : 0.35
            Palette.ink.withAlphaComponent(0.10 * alpha).setStroke(); line.lineWidth = 4; line.stroke()   // bleed
            Palette.ink.withAlphaComponent(alpha).setStroke(); line.lineWidth = 1.8; line.stroke()

            // cut-paper dots on the line at each band; the one in hand is lifted
            for (i, p) in dotPoints(range).enumerated() {
                let lifted = grab?.index == i || hoverDot == i
                drawDot(at: p, kind: face.bands[i].kind, color: Palette.dots[i % Palette.dots.count].withAlphaComponent(alpha), lifted: lifted)
            }
            if face.bands.isEmpty {
                "flat. double-click to add a band".draw(at: NSPoint(x: scrap.minX + 16, y: plot.midY - 24),
                    withAttributes: [.font: Type.hand(13), .foregroundColor: Palette.ballpoint.withAlphaComponent(0.8)])
            }
            if let r = readout, r.index < face.bands.count, Date() < r.until || grab != nil {
                drawReadout(face.bands[r.index], at: dotPoints(range)[r.index])
            }
        } else {
            "no curve yet. double-click to start one".draw(at: NSPoint(x: scrap.minX + 16, y: scrap.midY - 10),
                withAttributes: [.font: Type.hand(14), .foregroundColor: Palette.ballpoint.withAlphaComponent(0.85)])
        }
        NSGraphicsContext.restoreGraphicsState()

        // tape over the top-left corner, with the device written on it by hand
        var size: CGFloat = 14
        while size > 9, face.device.size(withAttributes: [.font: Type.hand(size)]).width > 128 { size -= 0.5 }
        let attrs: [NSAttributedString.Key: Any] = [.font: Type.hand(size), .foregroundColor: Palette.ballpoint]
        let w = max(64, min(150, face.device.size(withAttributes: attrs).width + 22))
        let tapeAngle = seed.range(-9, -4) * 64 / w          // long tape lies flatter, clear of the readouts
        let t = NSRect(x: scrap.minX - 8, y: scrap.minY - 11, width: w, height: 22)
        cg.saveGState()
        cg.translateBy(x: t.midX, y: t.midY); cg.rotate(by: tapeAngle * .pi / 180); cg.translateBy(x: -t.midX, y: -t.midY)
        let tape = NSBezierPath()
        tape.move(to: NSPoint(x: t.minX, y: t.minY)); tape.line(to: NSPoint(x: t.maxX, y: t.minY))
        var ty = t.minY
        while ty < t.maxY { ty = min(t.maxY, ty + seed.range(2, 4)); tape.line(to: NSPoint(x: t.maxX + seed.range(-1.5, 1.5), y: ty)) }
        tape.line(to: NSPoint(x: t.minX, y: t.maxY))
        ty = t.maxY
        while ty > t.minY { ty = max(t.minY, ty - seed.range(2, 4)); tape.line(to: NSPoint(x: t.minX + seed.range(-1.5, 1.5), y: ty)) }
        tape.close()
        Palette.tape.setFill(); tape.fill()
        (face.device as NSString).draw(in: NSRect(x: t.minX + 10, y: t.minY + 1.5 + (14 - size) / 2, width: w - 14, height: 20), withAttributes: attrs)
        cg.restoreGState()

        cg.restoreGState()
    }

    private func drawDot(at p: NSPoint, kind: Kind, color: NSColor, lifted: Bool) {
        let r: CGFloat = lifted ? 6.5 : 5.5
        let path = NSBezierPath()
        switch kind {
        case .pk: path.appendOval(in: NSRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        case .lsc: path.move(to: NSPoint(x: p.x, y: p.y - r)); path.appendArc(withCenter: p, radius: r, startAngle: 270, endAngle: 90, clockwise: true); path.close()
        case .hsc: path.move(to: NSPoint(x: p.x, y: p.y - r)); path.appendArc(withCenter: p, radius: r, startAngle: 270, endAngle: 90, clockwise: false); path.close()
        }
        let s = NSShadow(); s.shadowColor = NSColor(white: 0, alpha: lifted ? 0.35 : 0.28)
        s.shadowOffset = lifted ? NSSize(width: 1.5, height: -2.5) : NSSize(width: 0.6, height: -0.8); s.shadowBlurRadius = lifted ? 2.5 : 0.8
        NSGraphicsContext.saveGraphicsState(); s.set(); color.setFill(); path.fill(); NSGraphicsContext.restoreGraphicsState()
    }

    private func drawReadout(_ b: Band, at p: NSPoint) {
        let fq = b.fc >= 1000 ? String(format: "%.3g", b.fc / 1000) + "k" : "\(Int(b.fc))"
        let text = "\(fq) hz  \(String(format: "%+.1f", b.gain).replacingOccurrences(of: "-", with: "−"))  q\(String(format: "%.2f", b.q))"
        let a: [NSAttributedString.Key: Any] = [.font: Type.mono(7.5), .foregroundColor: Palette.ink]
        let sz = text.size(withAttributes: a)
        var o = NSPoint(x: p.x - sz.width / 2, y: p.y - 22)
        o.x = min(max(o.x, scrap.minX + 4), scrap.maxX - sz.width - 4)
        if o.y < scrap.minY + 4 { o.y = p.y + 12 }
        Palette.paper.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: NSRect(x: o.x - 3, y: o.y - 1, width: sz.width + 6, height: sz.height + 2), xRadius: 2, yRadius: 2).fill()
        text.draw(at: o, withAttributes: a)
    }

    private func drawFooter() {
        // the hold button: a black cap that sinks when pressed
        let c = holdCenter, r: CGFloat = 17
        let held = face.held
        let cap = NSRect(x: c.x - r, y: c.y - r + (held ? 1.5 : 0), width: 2 * r, height: 2 * r)
        Palette.well.setFill(); NSBezierPath(ovalIn: NSRect(x: c.x - r - 2, y: c.y - r - 1, width: 2 * r + 4, height: 2 * r + 4)).fill()
        if !held { Palette.rgb(0x000000).setFill(); NSBezierPath(ovalIn: cap.offsetBy(dx: 0, dy: 1.5)).fill() }
        (held ? Palette.rgb(0x2A2A2A) : Palette.ink).setFill(); NSBezierPath(ovalIn: cap).fill()
        if !held {
            Palette.rgb(0xFFFFFF, 0.12).setStroke()
            let hi = NSBezierPath(); hi.appendArc(withCenter: NSPoint(x: cap.midX, y: cap.midY), radius: r - 2.5, startAngle: 200, endAngle: 340, clockwise: false)
            hi.lineWidth = 1.5; hi.stroke()
        }
        (held ? "original" : "hold").draw(at: NSPoint(x: c.x + r + 10, y: c.y - 12), withAttributes: [.font: Type.mono(9.5), .foregroundColor: Palette.ink])
        "to compare".draw(at: NSPoint(x: c.x + r + 10, y: c.y + 1), withAttributes: [.font: Type.mono(7.5), .foregroundColor: Palette.label])

        // four preset keys: number on the cap, lamp above the one that's playing
        for i in 0..<4 {
            let k = slotKey(i), down = pressed == .slot(i)
            drawKey(k, pressed: down, fill: flashSlot == i ? Palette.orange : Palette.cap)
            let n = "\(i + 1)", a: [NSAttributedString.Key: Any] = [.font: Type.mono(9.5, face.slots[i] ? "Bd" : "Rg"),
                                                                   .foregroundColor: face.slots[i] ? Palette.ink : Palette.label]
            let sz = n.size(withAttributes: a)
            n.draw(at: NSPoint(x: k.midX - sz.width / 2, y: k.minY + 4 + (down ? 2 : 0)), withAttributes: a)
            led(NSPoint(x: k.midX, y: k.minY - 7), lit: face.activeSlot == i, size: 4)
        }
        if let p = face.problem {
            (p as NSString).draw(in: NSRect(x: 18, y: bounds.maxY - 13, width: bounds.width - 36, height: 12),
                                 withAttributes: [.font: Type.mono(7), .foregroundColor: Palette.orange])
        }
    }

    // MARK: input

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t); tracking = t
    }

    private func key(at p: NSPoint) -> Key? {
        if hypot(p.x - holdCenter.x, p.y - holdCenter.y) <= 21 { return .hold }
        if powerKey.insetBy(dx: -3, dy: -3).contains(p) { return .power }
        for i in 0..<4 where slotKey(i).insetBy(dx: -3, dy: -3).contains(p) { return .slot(i) }
        return nil
    }

    override func mouseMoved(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let d = face.curve != nil ? dot(at: p) : nil
        if d != hoverDot { hoverDot = d; needsDisplay = true }
        if d != nil { NSCursor.openHand.set() }
        else if key(at: p) != nil { NSCursor.pointingHand.set() }
        else { NSCursor.arrow.set() }
    }

    override func mouseExited(with e: NSEvent) { hoverDot = nil; NSCursor.arrow.set(); needsDisplay = true }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if let k = key(at: p) {
            pressed = k; needsDisplay = true
            switch k {
            case .hold: onHold(true)
            case .slot(let i):
                savedDuringPress = false
                saveTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
                    guard let self else { return }
                    self.savedDuringPress = true
                    self.onSlot(i, true)
                    self.flash(i)
                }
            case .power: break
            }
            return
        }
        if let i = face.curve != nil ? dot(at: p) : nil {
            if e.clickCount == 2 { return }
            onBeginEdit()
            grab = (i, face.bands[i], toPaper(p).y, range)
            readout = (i, .distantFuture)
            NSCursor.closedHand.set()
        } else if e.clickCount == 2, scrap.insetBy(dx: -4, dy: -4).contains(toPaper(p)) {
            addBand(at: toPaper(p))
        }
    }

    override func mouseDragged(with e: NSEvent) {
        guard let d = grab, var curve = face.curve, d.index < curve.bands.count else { return }
        let p = toPaper(convert(e.locationInWindow, from: nil))
        let dbPerPt = d.range / Double(plot.height / 2)
        var b = d.start
        b.fc = min(20000, max(20, f(p.x)))
        b.gain = d.start.gain + Double(d.startY - p.y) * dbPerPt
        curve.bands[d.index] = snapped(b)
        face.curve = curve
        onEdit(curve, false)
    }

    override func mouseUp(with e: NSEvent) {
        if let k = pressed {
            pressed = nil; needsDisplay = true
            let inside = key(at: convert(e.locationInWindow, from: nil)) == k
            switch k {
            case .hold: onHold(false)
            case .power: if inside { onPower() }
            case .slot(let i):
                saveTimer?.invalidate(); saveTimer = nil
                if !savedDuringPress, inside { onSlot(i, false) }
            }
            return
        }
        if let d = grab, let curve = face.curve {
            grab = nil
            readout = (d.index, Date().addingTimeInterval(1.2))
            onEdit(curve, true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.25) { [weak self] in self?.needsDisplay = true }
            NSCursor.openHand.set()
        }
    }

    /// Scroll over a dot: narrower / wider. Saved once the scrolling stops.
    override func scrollWheel(with e: NSEvent) {
        guard var curve = face.curve, let i = dot(at: convert(e.locationInWindow, from: nil)) else { return }
        if scrollPersist == nil { onBeginEdit() }
        var b = curve.bands[i]
        let lo = b.kind == .pk ? 0.3 : 0.4, hi = b.kind == .pk ? 10.0 : 2.0
        b.q = min(hi, max(lo, b.q * exp(Double(-e.scrollingDeltaY) * (e.hasPreciseScrollingDeltas ? 0.01 : 0.08))))
        curve.bands[i] = snapped(b)
        face.curve = curve
        readout = (i, Date().addingTimeInterval(1.2))
        onEdit(curve, false)
        scrollPersist?.invalidate()
        scrollPersist = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            guard let self, let c = self.face.curve else { return }
            self.scrollPersist = nil
            self.onEdit(c, true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in self?.needsDisplay = true }
        }
    }

    override func rightMouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let m = NSMenu()
        if let i = face.curve != nil ? dot(at: p) : nil {
            for (title, kind) in [("bell", Kind.pk), ("low shelf", .lsc), ("high shelf", .hsc)] {
                let it = m.addItem(withTitle: title, action: #selector(menuKind(_:)), keyEquivalent: "")
                it.target = self; it.tag = i; it.representedObject = kind.rawValue
                it.state = face.bands[i].kind == kind ? .on : .off
            }
            m.addItem(.separator())
            let rm = m.addItem(withTitle: "remove", action: #selector(menuRemove(_:)), keyEquivalent: ""); rm.target = self; rm.tag = i
        } else if scrap.contains(toPaper(p)) {
            let add = m.addItem(withTitle: "add a band here", action: #selector(menuAdd(_:)), keyEquivalent: ""); add.target = self
            add.representedObject = NSValue(point: toPaper(p))
            if !face.bands.isEmpty { let fl = m.addItem(withTitle: "flatten", action: #selector(menuFlatten), keyEquivalent: ""); fl.target = self }
            m.addItem(.separator())
            let fi = m.addItem(withTitle: "open the file", action: #selector(menuFile), keyEquivalent: ""); fi.target = self
        } else { return }
        NSMenu.popUpContextMenu(m, with: e, for: self)
    }

    @objc private func menuKind(_ it: NSMenuItem) {
        guard var c = face.curve, it.tag < c.bands.count, let raw = it.representedObject as? String, let k = Kind(rawValue: raw) else { return }
        onBeginEdit()
        c.bands[it.tag].kind = k
        if k != .pk { c.bands[it.tag].q = min(c.bands[it.tag].q, 2) }
        commit(c)
    }
    @objc private func menuRemove(_ it: NSMenuItem) {
        guard var c = face.curve, it.tag < c.bands.count else { return }
        onBeginEdit(); c.bands.remove(at: it.tag); hoverDot = nil; commit(c)
    }
    @objc private func menuAdd(_ it: NSMenuItem) { if let v = it.representedObject as? NSValue { addBand(at: v.pointValue) } }
    @objc private func menuFlatten() { guard var c = face.curve else { return }; onBeginEdit(); c.bands = []; commit(c) }
    @objc private func menuFile() { onOpenFile() }

    private func addBand(at paperPoint: NSPoint) {
        var c = face.curve ?? Curve(preamp: nil, bands: [])
        guard c.bands.count < 12 else { return }
        onBeginEdit()
        let fq = min(20000, max(20, f(paperPoint.x)))
        let bq = c.bands.map { design($0, fs: face.fs) }
        let want = db(paperPoint.y, range) - gainDB(bq, fq, fs: face.fs)    // so the line passes the click
        c.bands.append(snapped(Band(kind: .pk, fc: fq, gain: want, q: 1)))
        readout = (c.bands.count - 1, Date().addingTimeInterval(1.5))
        commit(c)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.55) { [weak self] in self?.needsDisplay = true }
    }

    private func commit(_ c: Curve) { face.curve = c; onEdit(c, true) }

    private func flash(_ i: Int) {
        flashSlot = i; needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.flashSlot = nil; self?.needsDisplay = true }
    }

    override func keyDown(with e: NSEvent) {
        if e.charactersIgnoringModifiers == " " { if !e.isARepeat { pressed = .hold; onHold(true) } }
        else if e.keyCode == 53 { window?.orderOut(nil) }        // esc
        else if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers?.lowercased() == "z" {
            onUndo(e.modifierFlags.contains(.shift))
        } else if let n = Int(e.charactersIgnoringModifiers ?? ""), (1...4).contains(n) {
            onSlot(n - 1, e.modifierFlags.contains(.option)); if e.modifierFlags.contains(.option) { flash(n - 1) }
        } else { super.keyDown(with: e) }
    }
    override func keyUp(with e: NSEvent) {
        if e.charactersIgnoringModifiers == " " { pressed = nil; onHold(false) }
    }
}

extension String {
    func draw(at p: NSPoint, withAttributes a: [NSAttributedString.Key: Any]) { (self as NSString).draw(at: p, withAttributes: a) }
    func size(withAttributes a: [NSAttributedString.Key: Any]) -> NSSize { (self as NSString).size(withAttributes: a) }
}

/// The menu-bar glyph: your curve in miniature inside a small frame; flat when off or held.
func statusGlyph(bands: [Band], fs: Double, live: Bool) -> NSImage {
    let img = NSImage(size: NSSize(width: 22, height: 16), flipped: true) { _ in
        let frame = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 2.5, width: 19, height: 11), xRadius: 3, yRadius: 3)
        frame.lineWidth = 1.2; NSColor.black.setStroke(); frame.stroke()
        let bq = live ? bands.map { design($0, fs: fs) } : []
        var m = 0.0
        for i in 0...40 { m = max(m, abs(gainDB(bq, 20 * pow(1000, Double(i) / 40), fs: fs))) }
        let scale = m > 0 ? 3.6 / m : 0
        let line = NSBezierPath()
        for i in 0...40 {
            let fq = 20 * pow(1000, Double(i) / 40)
            let p = NSPoint(x: 4 + 14 * CGFloat(i) / 40, y: 8 - CGFloat(gainDB(bq, fq, fs: fs) * scale))
            i == 0 ? line.move(to: p) : line.line(to: p)
        }
        line.lineWidth = 1.4; line.lineCapStyle = .round; line.stroke()
        return true
    }
    img.isTemplate = true
    return img
}

/// eq render <file.png>: draws faces offline at 2x for review, on a plain desk.
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
