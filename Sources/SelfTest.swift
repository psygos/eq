import Foundation

/// Offline proof of the DSP: runs the exact Processor used live. Prints PASS/FAIL per check and
/// writes cases for the independent Python/scipy oracle (tools/oracle.py).
enum SelfTest {
    struct RNG { var s: UInt64; mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) } }

    static func run(out: String?) -> Int32 {
        var failed = 0
        func expect(_ ok: Bool, _ name: String, _ detail: String = "") {
            print((ok ? "PASS " : "FAIL ") + name + (detail.isEmpty ? "" : "  " + detail))
            if !ok { failed += 1 }
        }
        var rng = RNG(s: 0x5EED)

        // Parser
        let apo = """
        Preamp: -6.1 dB
        Filter 1: ON LSC Fc 105 Hz Gain 4.5 dB Q 0.70
        Filter 2: ON PK Fc 400 Hz Gain -1.0 dB Q 0.8   # comment
        Filter 3: OFF PK Fc 3000 Hz Gain 9 dB Q 2
        Filter 4: ON HSC Fc 9000 Hz Gain 3.0 dB Q 0.70
        """
        let c = try? parseCurve(apo)
        expect(c == Curve(preamp: -6.1, bands: [Band(kind: .lsc, fc: 105, gain: 4.5, q: 0.7),
                                                Band(kind: .pk, fc: 400, gain: -1, q: 0.8),
                                                Band(kind: .hsc, fc: 9000, gain: 3, q: 0.7)]), "parse AutoEQ file")
        expect((try? parseCurve("Preamp: auto\nFilter: ON PK Fc 1000 Hz Gain 1 dB Q 1"))?.preamp == nil, "parse auto preamp")
        for bad in ["Filtr 1: ON PK Fc 100 Hz Gain 1 dB Q 1", "Filter 1: ON PK Fc 100 Hz Gain dB Q 1",
                    "Filter 1: ON XX Fc 100 Hz Gain 1 dB Q 1", "Filter 1: ON PK Fc 100 Hz Gain 1 dB Q 0",
                    "Preamp: loud"] {
            expect((try? parseCurve(bad)) == nil, "reject \"\(bad)\"")
        }

        // Spec points of the cookbook filters, from their definitions (not from the code's formulas)
        for fs in [44100.0, 48000, 96000] {
            for g in [-12.0, -3, 3, 12] {
                let pk = design(Band(kind: .pk, fc: 1000, gain: g, q: 2), fs: fs)
                let ls = design(Band(kind: .lsc, fc: 200, gain: g, q: 0.707), fs: fs)
                let hs = design(Band(kind: .hsc, fc: 5000, gain: g, q: 0.707), fs: fs)
                let errs = [gainDB(pk, 1000, fs: fs) - g, gainDB(pk, 1e-3, fs: fs), gainDB(pk, fs / 2 * 0.999999, fs: fs),
                            gainDB(ls, 1e-3, fs: fs) - g, gainDB(ls, 200, fs: fs) - g / 2, gainDB(ls, fs / 2 * 0.999999, fs: fs),
                            gainDB(hs, 1e-3, fs: fs), gainDB(hs, 5000, fs: fs) - g / 2, gainDB(hs, fs / 2 * 0.999999, fs: fs) - g]
                let worst = errs.map(abs).max()!
                expect(worst < 1e-6, "cookbook spec points fs=\(Int(fs)) g=\(g)", String(format: "worst %.2e dB", worst))
            }
        }

        // Random curves: auto preamp never lets the curve exceed 0 dB (checked on a 200k grid)
        var cases: [[String: Any]] = []
        var worstHeadroom = -Double.infinity
        for i in 0..<120 {
            let fs = [44100.0, 48000, 96000][i % 3]
            let n = 1 + Int(rng.next() * 10)
            let bands = (0..<n).map { _ in
                Band(kind: [.pk, .lsc, .hsc][Int(rng.next() * 3)], fc: 20 * pow(1000, rng.next()),
                     gain: rng.next() * 24 - 12, q: 0.3 * pow(30, rng.next()))
            }
            let curve = Curve(preamp: nil, bands: bands)
            let bq = bands.map { design($0, fs: fs) }
            let pre = resolvedPreamp(curve, fs: fs)
            var m = -Double.infinity
            for j in 0...200_000 { m = max(m, gainDB(bq, exp(log(10) + (log(fs * 0.4999) - log(10)) * Double(j) / 200_000), fs: fs)) }
            worstHeadroom = max(worstHeadroom, m + pre)
            if i < 60 {
                // impulse response of the live Processor, unity preamp
                let p = Processor(); p.load(bq, preampDB: 0, audioRunning: false)
                let N = 8192
                var x = [Float](repeating: 0, count: N); x[0] = 1
                var y = [Float](repeating: 0, count: N)
                p.process(x, inCh: 1, &y, outCh: 1, frames: N, fs: fs)
                let pk = peakDB(bq, fs: fs)
                cases.append(["fs": fs, "bands": bands.map { [$0.kind.rawValue, $0.fc, $0.gain, $0.q] as [Any] },
                              "coef": bq.map { [$0.b0, $0.b1, $0.b2, $0.a1, $0.a2] }, "ir": y.map { Double($0) },
                              "peak": [pk.f, pk.db]])
            }
        }
        expect(worstHeadroom <= 1e-9, "auto preamp: curve + preamp ≤ 0 dB, 120 random curves",
               String(format: "worst %+.2e dB", worstHeadroom))

        // Bit-exact paths
        let N = 48000
        var noise = [Float](repeating: 0, count: N * 2)
        for i in 0..<noise.count { noise[i] = Float(rng.next() * 2 - 1) }
        do {
            let p = Processor(); p.load([], preampDB: 0, audioRunning: false)
            var y = [Float](repeating: 0, count: N * 2)
            p.process(noise, inCh: 2, &y, outCh: 2, frames: N, fs: 48000)
            expect(y == noise, "flat curve is bit-identical")
        }
        do {
            let p = Processor()
            p.load([design(Band(kind: .pk, fc: 1000, gain: 6, q: 1), fs: 48000)], preampDB: -6, audioRunning: false)
            p.bypass.store(true, ordering: .relaxed); p.reset()
            var y = [Float](repeating: 0, count: N * 2)
            p.process(noise, inCh: 2, &y, outCh: 2, frames: N, fs: 48000)
            expect(y == noise, "bypass is bit-identical")

            // A/B crossfade: from bypass to curve over 10 ms, no NaN, settles exactly on the curve
            p.bypass.store(false, ordering: .relaxed)
            var z = [Float](repeating: 0, count: N * 2)
            p.process(noise, inCh: 2, &z, outCh: 2, frames: N, fs: 48000)
            let q = Processor()
            q.load([design(Band(kind: .pk, fc: 1000, gain: 6, q: 1), fs: 48000)], preampDB: -6, audioRunning: false)
            var w = [Float](repeating: 0, count: N * 2), w0 = w
            q.process(noise, inCh: 2, &w0, outCh: 2, frames: N, fs: 48000)   // same filter history
            q.process(noise, inCh: 2, &w, outCh: 2, frames: N, fs: 48000)
            let tail = 500 * 2
            expect(z.allSatisfy { $0.isFinite } && Array(z[tail...]) == Array(w[tail...]),
                   "A/B crossfade settles bit-exactly after 10 ms")
        }
        // Mono and multichannel mapping
        do {
            let p = Processor(); p.load([], preampDB: 0, audioRunning: false)
            let mono: [Float] = [0.1, 0.2, 0.3]
            var y = [Float](repeating: 9, count: 6)
            p.process(mono, inCh: 1, &y, outCh: 2, frames: 3, fs: 48000)
            expect(y == [0.1, 0.1, 0.2, 0.2, 0.3, 0.3], "mono input feeds both channels")
            var s = [Float](repeating: 9, count: 4)
            p.process(nil, inCh: 0, &s, outCh: 2, frames: 2, fs: 48000)
            expect(s == [0, 0, 0, 0], "no input writes silence")
        }
        // Clip counter
        do {
            let p = Processor(); p.load([], preampDB: 6, audioRunning: false)
            var y = [Float](repeating: 0, count: 4)
            p.process([0.4, 0.6, -0.6, 0.1], inCh: 1, &y, outCh: 1, frames: 4, fs: 48000)
            expect(p.clipped.load(ordering: .relaxed) == 2, "clip counter counts samples beyond full scale")
        }

        if let out {
            let data = try! JSONSerialization.data(withJSONObject: ["cases": cases])
            try! data.write(to: URL(fileURLWithPath: out))
            print("wrote \(cases.count) cases for the oracle → \(out)")
        }
        print(failed == 0 ? "ALL PASS" : "\(failed) FAILED")
        return failed == 0 ? 0 : 1
    }
}
