import Foundation
import Synchronization

// MARK: - Curve: what the text file says

enum Kind: String { case pk = "PK", lsc = "LSC", hsc = "HSC" }

struct Band: Equatable {
    var kind: Kind
    var fc: Double    // Hz
    var gain: Double  // dB
    var q: Double
}

struct Curve: Equatable {
    var preamp: Double?   // dB; nil = auto (minus the curve's peak, so it never boosts)
    var bands: [Band]
    static let flat = Curve(preamp: 0, bands: [])
}

/// Reads the Equalizer APO / AutoEQ "ParametricEQ.txt" format:
///   Preamp: -6.2 dB          (or "Preamp: auto")
///   Filter 1: ON PK Fc 250 Hz Gain -1.0 dB Q 1.41
/// '#' starts a comment. Any other line is an error, so a typo never silently plays.
func parseCurve(_ text: String) throws -> Curve {
    var curve = Curve(preamp: nil, bands: [])
    for (n, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { continue }
        let t = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        func num(after key: String) -> Double? {
            guard let i = t.firstIndex(where: { $0.caseInsensitiveCompare(key) == .orderedSame }), i + 1 < t.count
            else { return nil }
            return Double(t[i + 1])
        }
        let head = t[0].lowercased()
        if head == "preamp:" {
            if t.count > 1, t[1].lowercased() == "auto" { curve.preamp = nil; continue }
            guard t.count > 1, let v = Double(t[1]), v.isFinite else { throw ParseError(line: n + 1, text: line) }
            curve.preamp = v
        } else if head == "filter" || head.hasPrefix("filter") {
            guard let on = t.firstIndex(where: { $0 == "ON" || $0 == "OFF" }), on + 1 < t.count
            else { throw ParseError(line: n + 1, text: line) }
            if t[on] == "OFF" { continue }
            guard let kind = Kind(rawValue: t[on + 1].uppercased()),
                  let fc = num(after: "Fc"), let g = num(after: "Gain"), let q = num(after: "Q"),
                  fc > 0, fc < 24_000, q > 0, q < 100, g.isFinite, abs(g) <= 30
            else { throw ParseError(line: n + 1, text: line) }
            curve.bands.append(Band(kind: kind, fc: fc, gain: g, q: q))
        } else {
            throw ParseError(line: n + 1, text: line)
        }
    }
    if curve.bands.count > Processor.maxBands { throw ParseError(line: 0, text: "more than \(Processor.maxBands) filters") }
    return curve
}

/// Writes a curve in the same format parseCurve reads; parseCurve(formatCurve(c)) == c for curves
/// whose numbers are already at this precision (the face rounds edits to it).
func formatCurve(_ c: Curve, title: String) -> String {
    var out = "# \(title). Written by eq; Equalizer APO / AutoEQ format. Save to apply.\n"
    out += "Preamp: " + (c.preamp.map { String(format: "%.1f dB", $0) } ?? "auto") + "\n"
    for (i, b) in c.bands.enumerated() {
        out += String(format: "Filter %d: ON %@ Fc %@ Hz Gain %.1f dB Q %.2f\n", i + 1, b.kind.rawValue,
                      b.fc.rounded() == b.fc ? String(Int(b.fc)) : String(format: "%.1f", b.fc), b.gain, b.q)
    }
    return out
}

/// Rounds an edit to what the file stores: Fc to a musical grid, gain 0.1 dB, Q 0.01.
func snapped(_ b: Band) -> Band {
    let step: Double = b.fc < 100 ? 1 : b.fc < 1000 ? 5 : b.fc < 10000 ? 50 : 100
    return Band(kind: b.kind, fc: min(20000, max(20, (b.fc / step).rounded() * step)),
                gain: (min(15, max(-15, b.gain)) * 10).rounded() / 10,
                q: (min(10, max(0.3, b.q)) * 100).rounded() / 100)
}

struct ParseError: Error, CustomStringConvertible {
    let line: Int, text: String
    var description: String { "line \(line): can't read \"\(text)\"" }
}

// MARK: - Filter design (RBJ Audio EQ Cookbook; the same formulas Equalizer APO and AutoEQ use)

struct Biquad: Equatable { var b0, b1, b2, a1, a2: Double }   // a0 normalised to 1

func design(_ b: Band, fs: Double) -> Biquad {
    let A = pow(10, b.gain / 40)
    let w0 = 2 * Double.pi * b.fc / fs
    let cw = cos(w0), alpha = sin(w0) / (2 * b.q)
    let b0, b1, b2, a0, a1, a2: Double
    switch b.kind {
    case .pk:
        b0 = 1 + alpha * A; b1 = -2 * cw; b2 = 1 - alpha * A
        a0 = 1 + alpha / A; a1 = -2 * cw; a2 = 1 - alpha / A
    case .lsc:
        let s = 2 * sqrt(A) * alpha
        b0 = A * ((A + 1) - (A - 1) * cw + s)
        b1 = 2 * A * ((A - 1) - (A + 1) * cw)
        b2 = A * ((A + 1) - (A - 1) * cw - s)
        a0 = (A + 1) + (A - 1) * cw + s
        a1 = -2 * ((A - 1) + (A + 1) * cw)
        a2 = (A + 1) + (A - 1) * cw - s
    case .hsc:
        let s = 2 * sqrt(A) * alpha
        b0 = A * ((A + 1) + (A - 1) * cw + s)
        b1 = -2 * A * ((A - 1) + (A + 1) * cw)
        b2 = A * ((A + 1) + (A - 1) * cw - s)
        a0 = (A + 1) - (A - 1) * cw + s
        a1 = 2 * ((A - 1) - (A + 1) * cw)
        a2 = (A + 1) - (A - 1) * cw - s
    }
    return Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
}

/// |H(f)| in dB of one biquad, evaluated exactly on the unit circle.
func gainDB(_ q: Biquad, _ f: Double, fs: Double) -> Double {
    let w = 2 * Double.pi * f / fs
    let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
    let nr = q.b0 + q.b1 * c1 + q.b2 * c2, ni = -(q.b1 * s1 + q.b2 * s2)
    let dr = 1 + q.a1 * c1 + q.a2 * c2, di = -(q.a1 * s1 + q.a2 * s2)
    return 10 * log10((nr * nr + ni * ni) / (dr * dr + di * di))
}

func gainDB(_ qs: [Biquad], _ f: Double, fs: Double) -> Double {
    qs.reduce(0) { $0 + gainDB($1, f, fs: fs) }
}

/// The highest point of the summed curve between 10 Hz and Nyquist: dense log grid, then
/// golden-section refinement between the best point's neighbours.
func peakDB(_ qs: [Biquad], fs: Double) -> (f: Double, db: Double) {
    if qs.isEmpty { return (1000, 0) }
    let lo = log(10.0), hi = log(fs * 0.4999), n = 4000
    var best = (f: 10.0, db: -Double.infinity), bi = 0
    for i in 0...n {
        let f = exp(lo + (hi - lo) * Double(i) / Double(n))
        let g = gainDB(qs, f, fs: fs)
        if g > best.db { best = (f, g); bi = i }
    }
    var a = lo + (hi - lo) * Double(max(bi - 1, 0)) / Double(n)
    var b = lo + (hi - lo) * Double(min(bi + 1, n)) / Double(n)
    let r = (sqrt(5.0) - 1) / 2
    for _ in 0..<80 {
        let c = b - r * (b - a), d = a + r * (b - a)
        if gainDB(qs, exp(c), fs: fs) > gainDB(qs, exp(d), fs: fs) { b = d } else { a = c }
    }
    let f = exp((a + b) / 2), g = gainDB(qs, f, fs: fs)
    return g > best.db ? (f, g) : best
}

/// The preamp actually applied: the file's value, or minus the curve's peak (never positive).
func resolvedPreamp(_ c: Curve, fs: Double) -> Double {
    if let p = c.preamp { return p }
    return -max(0, peakDB(c.bands.map { design($0, fs: fs) }, fs: fs).db)
}

// MARK: - Realtime processor

/// Runs the curve on the audio thread: no allocation, no locks, no reference counting, no Swift
/// collections; every buffer is allocated once in init. Coefficients live in two banks: the main
/// thread writes the idle one and publishes it, the audio thread switches at the start of a
/// block. Filters run in Double. With no bands and a 0 dB preamp the output is bit-identical to
/// the input; while comparing it is the input times the preamp, exactly.
final class Processor: @unchecked Sendable {
    static let maxBands = 32, maxChannels = 8

    private let coef: UnsafeMutablePointer<Double>    // [2][maxBands][5]
    private let gains: UnsafeMutablePointer<Double>   // [2]
    private let counts: UnsafeMutablePointer<Int>     // [2]
    private let state: UnsafeMutablePointer<Double>   // [maxChannels][maxBands][2]
    private let mix: UnsafeMutablePointer<Double>     // 1 = curve, 0 = straight through

    private let published = Atomic<Int>(0)  // bank the audio thread should use
    private let seen = Atomic<Int>(0)       // bank the audio thread last picked up
    let bypass = Atomic<Bool>(false)
    let clipped = Atomic<Int>(0)            // output samples beyond full scale, ever
    let blocks = Atomic<Int>(0)             // audio callbacks so far
    private let peakIn = Atomic<UInt32>(0)  // Float bits, max |x| since last read
    private let peakOut = Atomic<UInt32>(0)

    init() {
        coef = .allocate(capacity: 2 * Self.maxBands * 5); coef.initialize(repeating: 0, count: 2 * Self.maxBands * 5)
        state = .allocate(capacity: Self.maxChannels * Self.maxBands * 2)
        state.initialize(repeating: 0, count: Self.maxChannels * Self.maxBands * 2)
        gains = .allocate(capacity: 2); gains.initialize(repeating: 1, count: 2)
        counts = .allocate(capacity: 2); counts.initialize(repeating: 0, count: 2)
        mix = .allocate(capacity: 1); mix.initialize(to: 1)
    }

    /// Main thread. Waits until the audio thread has picked up the previous change, so a bank is
    /// never rewritten while it may be in use. If audio is stopped nobody reads either bank.
    /// With wait false it gives up (returns false) instead of waiting; the caller retries later.
    @discardableResult
    func load(_ bqs: [Biquad], preampDB: Double, audioRunning: Bool, wait: Bool = true) -> Bool {
        precondition(bqs.count <= Self.maxBands)
        if audioRunning {
            var spins = 0
            while seen.load(ordering: .acquiring) != published.load(ordering: .relaxed), spins < 500 {
                if !wait { return false }
                usleep(1000); spins += 1
            }
        }
        let next = 1 - published.load(ordering: .relaxed)
        let base = coef + next * Self.maxBands * 5
        for (i, q) in bqs.enumerated() {
            base[i * 5] = q.b0; base[i * 5 + 1] = q.b1; base[i * 5 + 2] = q.b2
            base[i * 5 + 3] = q.a1; base[i * 5 + 4] = q.a2
        }
        counts[next] = bqs.count
        gains[next] = pow(10, preampDB / 20)
        published.store(next, ordering: .releasing)
        if !audioRunning { seen.store(next, ordering: .releasing) }
        return true
    }

    /// Audio thread. Interleaved Float32 in and out; output channel c reads input channel
    /// min(c, inCh - 1). A nil input (no tap data) writes silence.
    func process(_ input: UnsafePointer<Float>?, inCh: Int,
                 _ output: UnsafeMutablePointer<Float>, outCh: Int, frames: Int, fs: Double) {
        let bank = published.load(ordering: .acquiring)
        seen.store(bank, ordering: .releasing)
        blocks.add(1, ordering: .relaxed)
        guard let input, inCh > 0 else {
            output.update(repeating: 0, count: frames * outCh); return
        }
        let n = counts[bank], g = gains[bank], c = coef + bank * Self.maxBands * 5
        let target: Double = bypass.load(ordering: .relaxed) ? 0 : 1
        let step = 1 / (0.010 * fs)                         // 10 ms crossfade on A/B
        var m = mix.pointee
        var clips = 0, pin: Float = 0, pout: Float = 0
        let chs = min(outCh, Self.maxChannels)
        for f in 0..<frames {
            if m != target { m = target > m ? min(target, m + step) : max(target, m - step) }
            for ch in 0..<outCh {
                let x = input[f * inCh + min(ch, inCh - 1)]
                var y = Double(x) * g
                if ch < chs {
                    let s = state + ch * Self.maxBands * 2
                    for b in 0..<n {                       // transposed direct form II
                        let k = c + b * 5, z = s + b * 2
                        let o = k[0] * y + z[0]
                        z[0] = k[1] * y - k[3] * o + z[1]
                        z[1] = k[2] * y - k[4] * o
                        y = o
                    }
                }
                // compare plays the original at the curve's level (the preamp), so only the
                // shape differs: louder always sounds better, and that isn't a fair comparison
                let out: Float = m == 1 ? Float(y) : m == 0 ? Float(Double(x) * g) : Float(y * m + Double(x) * g * (1 - m))
                output[f * outCh + ch] = out
                pin = max(pin, abs(x)); pout = max(pout, abs(out))
                if abs(out) > 1 { clips += 1 }
            }
        }
        mix.pointee = m
        if clips > 0 { clipped.add(clips, ordering: .relaxed) }
        Self.raise(peakIn, pin); Self.raise(peakOut, pout)
    }

    private static func raise(_ a: borrowing Atomic<UInt32>, _ v: Float) {
        var cur = a.load(ordering: .relaxed)
        while Float(bitPattern: cur) < v {
            let (ok, now) = a.compareExchange(expected: cur, desired: v.bitPattern, ordering: .relaxed)
            if ok { break }
            cur = now
        }
    }

    /// Main thread: read and reset the meters.
    func takePeaks() -> (in: Float, out: Float) {
        (Float(bitPattern: peakIn.exchange(0, ordering: .relaxed)),
         Float(bitPattern: peakOut.exchange(0, ordering: .relaxed)))
    }

    /// Only while audio is stopped.
    func reset() {
        state.update(repeating: 0, count: Self.maxChannels * Self.maxBands * 2)
        mix.pointee = bypass.load(ordering: .relaxed) ? 0 : 1
    }
}
