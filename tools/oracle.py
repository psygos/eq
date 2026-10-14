"""Independent check of eq's DSP. Not shipped; a second implementation in another language.

Reads the cases written by `eq selftest <file>` and checks, per case:
  1. coefficients: a separate Python port of the RBJ cookbook gives the same numbers
  2. processing: scipy's sosfilt (float64) on an impulse matches eq's live Processor (float32)
  3. response: |FFT(eq's impulse response)| matches scipy's freqz of the coefficients
  4. peak: eq's peak search finds the true maximum of the curve (vs a 400k-point grid)
Run: uv run --no-project --with numpy --with scipy python tools/oracle.py cases.json
"""
import json, sys
import numpy as np
from scipy import signal

def rbj(kind, fc, gain, q, fs):
    A = 10 ** (gain / 40); w0 = 2 * np.pi * fc / fs; cw = np.cos(w0); al = np.sin(w0) / (2 * q)
    if kind == "PK":
        b = [1 + al * A, -2 * cw, 1 - al * A]; a = [1 + al / A, -2 * cw, 1 - al / A]
    elif kind == "LSC":
        s = 2 * np.sqrt(A) * al
        b = [A * ((A + 1) - (A - 1) * cw + s), 2 * A * ((A - 1) - (A + 1) * cw), A * ((A + 1) - (A - 1) * cw - s)]
        a = [(A + 1) + (A - 1) * cw + s, -2 * ((A - 1) + (A + 1) * cw), (A + 1) + (A - 1) * cw - s]
    elif kind == "HSC":
        s = 2 * np.sqrt(A) * al
        b = [A * ((A + 1) + (A - 1) * cw + s), -2 * A * ((A - 1) + (A + 1) * cw), A * ((A + 1) + (A - 1) * cw - s)]
        a = [(A + 1) - (A - 1) * cw + s, 2 * ((A - 1) - (A + 1) * cw), (A + 1) - (A - 1) * cw - s]
    else:
        raise ValueError(kind)
    return np.array(b + a) / a[0]

cases = json.load(open(sys.argv[1]))["cases"]
worst = dict(coef=0.0, ir=0.0, resp=0.0, peak=0.0)
for c in cases:
    fs = c["fs"]
    sos = np.array([rbj(k, f, g, q, fs) for k, f, g, q in c["bands"]])
    mine = np.array([[b0, b1, b2, 1.0, a1, a2] for b0, b1, b2, a1, a2 in c["coef"]])
    worst["coef"] = max(worst["coef"], np.max(np.abs(sos - mine) / np.maximum(1, np.abs(sos))))

    ir = np.array(c["ir"]); N = len(ir)
    x = np.zeros(N); x[0] = 1
    ref = signal.sosfilt(sos, x)
    worst["ir"] = max(worst["ir"], np.max(np.abs(ir - ref)) / np.max(np.abs(ref)))

    # magnitude of the measured IR vs the analytic response, 20 Hz .. 0.45 fs, where the 8192-tap
    # IR has decayed (skip cases whose IR hasn't: very low, very sharp filters)
    if np.max(np.abs(ref[-256:])) < 1e-7 * np.max(np.abs(ref)):
        f = np.fft.rfftfreq(N, 1 / fs); H = np.fft.rfft(ir)
        band = (f >= 20) & (f <= 0.45 * fs)
        _, Ha = signal.sosfreqz(sos, worN=f[band], fs=fs)
        d = 20 * np.log10(np.abs(H[band])) - 20 * np.log10(np.abs(Ha))
        worst["resp"] = max(worst["resp"], np.max(np.abs(d)))

    grid = np.exp(np.linspace(np.log(10), np.log(fs * 0.4999), 400_000))
    _, Hg = signal.sosfreqz(sos, worN=grid, fs=fs)
    true_peak = np.max(20 * np.log10(np.abs(Hg)))
    worst["peak"] = max(worst["peak"], true_peak - c["peak"][1])   # >0 means eq under-estimated

limits = dict(coef=1e-12, ir=1e-6, resp=0.001, peak=1e-6)
fail = 0
for k, v in worst.items():
    ok = v <= limits[k]; fail += not ok
    print(f"{'PASS' if ok else 'FAIL'} oracle {k:5s} worst {v:.3e}  (limit {limits[k]:.0e})  over {len(cases)} cases")
sys.exit(1 if fail else 0)
