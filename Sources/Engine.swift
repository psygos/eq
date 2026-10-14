import CoreAudio
import Foundation

/// What the audio thread needs, in plain memory.
struct IOContext {
    var proc: Unmanaged<Processor>
    var tapBuffer: Int     // index of the tap's buffer in the aggregate's input list
    var outBuffer: Int     // index of the output device's buffer in the output list
    var fs: Double
}

/// AudioBufferList is { UInt32 mNumberBuffers; AudioBuffer mBuffers[] } with the array at byte 8.
/// Read with plain pointer arithmetic so the audio thread never touches Swift runtime helpers
/// (tools/rtcheck.py verifies this on the built binary).
@inline(__always) private func buffers(_ list: UnsafeRawPointer) -> (Int, UnsafeMutablePointer<AudioBuffer>) {
    (Int(list.load(as: UInt32.self)), UnsafeMutableRawPointer(mutating: list + 8).assumingMemoryBound(to: AudioBuffer.self))
}

/// The audio callback. A plain C function: it reads the tap (everything the system was about to
/// play on the device), runs the curve, and writes the device's output. No allocation, locks,
/// reference counting or Swift runtime calls.
@_cdecl("eq_io")
func eqIO(_ dev: AudioObjectID, _ now: UnsafePointer<AudioTimeStamp>,
          _ inData: UnsafePointer<AudioBufferList>, _ inTime: UnsafePointer<AudioTimeStamp>,
          _ outData: UnsafeMutablePointer<AudioBufferList>, _ outTime: UnsafePointer<AudioTimeStamp>,
          _ client: UnsafeMutableRawPointer?) -> OSStatus {
    guard let client else { return 0 }
    let ctx = client.assumingMemoryBound(to: IOContext.self)
    let (nOut, outs) = buffers(outData), (nIn, ins) = buffers(inData)
    let ob = ctx.pointee.outBuffer, tb = ctx.pointee.tapBuffer
    for i in 0..<nOut where i != ob {                                // anything else stays silent
        if let d = outs[i].mData { memset(d, 0, Int(outs[i].mDataByteSize)) }
    }
    guard ob < nOut, let od = outs[ob].mData, outs[ob].mNumberChannels > 0 else { return 0 }
    let outCh = Int(outs[ob].mNumberChannels)
    var frames = Int(outs[ob].mDataByteSize) / (4 * outCh)
    var ip: UnsafePointer<Float>? = nil, inCh = 0
    if tb < nIn, let id = ins[tb].mData, ins[tb].mNumberChannels > 0 {
        inCh = Int(ins[tb].mNumberChannels)
        ip = UnsafePointer(id.assumingMemoryBound(to: Float.self))
        frames = min(frames, Int(ins[tb].mDataByteSize) / (4 * inCh))
    }
    let fs = ctx.pointee.fs
    ctx.pointee.proc._withUnsafeGuaranteedRef {
        $0.process(ip, inCh: inCh, od.assumingMemoryBound(to: Float.self), outCh: outCh, frames: frames, fs: fs)
    }
    return 0
}

/// One running chain: tap on a device → private aggregate (tap in, device out) → IOProc.
/// Exists only while a curve is active for the current output device.
final class Chain {
    let device: AudioObjectID, uid: String, fs: Double
    private(set) var tap = AudioObjectID(0), agg = AudioObjectID(0)
    private var procID: AudioDeviceIOProcID?
    private let ctx: UnsafeMutablePointer<IOContext>
    private(set) var layoutIn: [Int] = [], layoutOut: [Int] = []

    init(device: AudioObjectID, proc: Processor, bufferFrames: UInt32 = 512, drift: Bool = false) throws {
        self.device = device
        guard let uid = HAL.uid(device) else { throw HALError(what: "device UID", status: -1) }
        self.uid = uid
        fs = HAL.rate(device)
        ctx = .allocate(capacity: 1)
        ctx.initialize(to: IOContext(proc: Unmanaged.passUnretained(proc), tapBuffer: 0, outBuffer: 0, fs: fs))

        // 1. Tap: every process except this one, on this device's first output stream. Their
        //    audio stops going to the hardware only while we're reading it; if this process
        //    dies the tap dies with it and sound goes straight to the device again.
        let me = HAL.process(pid: getpid())
        let desc = CATapDescription(__excludingProcesses: me != 0 ? [NSNumber(value: me)] : [],
                                    andDeviceUID: uid, withStream: 0)
        desc.name = "eq"
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped
        do {
            try check(AudioHardwareCreateProcessTap(desc, &tap), "create tap")

            // 2. Private aggregate clocked by the device itself, with the tap as its input.
            let spec: [String: Any] = [
                kAudioAggregateDeviceNameKey: "eq",
                kAudioAggregateDeviceUIDKey: "eq-" + UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: uid,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString,
                                                   kAudioSubTapDriftCompensationKey: drift]],
            ]
            try check(AudioHardwareCreateAggregateDevice(spec as CFDictionary, &agg), "create aggregate")
            _ = HAL.set(agg, kAudioDevicePropertyBufferFrameSize, bufferFrames)

            // 3. Which buffers are which: the device's own inputs (e.g. a headset mic) come
            //    first, the tap last. Only the tap's input is switched on, so no microphone.
            layoutIn = HAL.streamLayout(agg, kAudioObjectPropertyScopeInput)
            layoutOut = HAL.streamLayout(agg, kAudioObjectPropertyScopeOutput)
            guard !layoutIn.isEmpty, !layoutOut.isEmpty else { throw HALError(what: "aggregate streams", status: -1) }
            ctx.pointee.tapBuffer = layoutIn.count - 1
            ctx.pointee.outBuffer = 0
            for f in HAL.formats(agg, kAudioObjectPropertyScopeInput) + HAL.formats(agg, kAudioObjectPropertyScopeOutput)
            where f.mFormatID != kAudioFormatLinearPCM || f.mFormatFlags & kAudioFormatFlagIsFloat == 0
                || f.mBitsPerChannel != 32 || f.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
                throw HALError(what: "stream format \(f.mFormatID) flags \(f.mFormatFlags)", status: -1)
            }

            try check(AudioDeviceCreateIOProcID(agg, eqIO, ctx, &procID), "create IOProc")
            try setInputUsage(only: ctx.pointee.tapBuffer, of: layoutIn.count)
            try check(AudioDeviceStart(agg, procID), "start")
        } catch {
            teardown(); throw error
        }
    }

    private func setInputUsage(only keep: Int, of n: Int) throws {
        guard n > 1, let procID else { return }
        let size = 12 + 4 * n   // { void *mIOProc; UInt32 mNumberStreams; UInt32 mStreamIsOn[n] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { raw.deallocate() }
        raw.storeBytes(of: unsafeBitCast(procID, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        raw.storeBytes(of: UInt32(n), toByteOffset: 8, as: UInt32.self)
        for i in 0..<n { raw.storeBytes(of: UInt32(i == keep ? 1 : 0), toByteOffset: 12 + 4 * i, as: UInt32.self) }
        var a = HAL.addr(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        try check(AudioObjectSetPropertyData(agg, &a, 0, nil, UInt32(size), raw), "stream usage")
    }

    private func teardown() {
        if let procID { AudioDeviceStop(agg, procID); AudioDeviceDestroyIOProcID(agg, procID) }
        procID = nil
        if agg != 0 { AudioHardwareDestroyAggregateDevice(agg); agg = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
    }

    func stop() { teardown() }
    deinit { teardown(); ctx.deinitialize(count: 1); ctx.deallocate() }
}

/// Follows the default output device. When a curve file exists for it, a Chain runs; otherwise
/// nothing does: no tap, no thread, no cost.
final class Engine {
    let proc = Processor()
    private(set) var chain: Chain?
    private(set) var device = AudioObjectID(0)
    private(set) var deviceName = ""
    private(set) var curve: Curve?
    private(set) var preamp: Double = 0
    private(set) var problem: String?
    var enabled = true { didSet { if enabled != oldValue { refresh(force: true) } } }
    var onChange: () -> Void = {}
    private var watched = AudioObjectID(0)
    private var rateListener: AudioObjectPropertyListenerBlock?
    private var aliveListener: AudioObjectPropertyListenerBlock?

    var running: Bool { chain != nil }

    func start() {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        HAL.listen(sys, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in self?.refresh() }
        HAL.listen(sys, kAudioHardwarePropertyDevices) { [weak self] in self?.refresh() }
        Curves.watch { [weak self] in self?.refresh(force: false, curvesChanged: true) }
        refresh(force: true)
    }

    /// Re-reads the world and converges: same device and rate → only swap coefficients;
    /// anything else → rebuild the chain (or tear it down).
    func refresh(force: Bool = false, curvesChanged: Bool = false) {
        let dev = HAL.defaultOutput
        let name = HAL.name(dev)
        var newCurve: Curve? = nil
        problem = nil
        do { newCurve = try Curves.load(for: name) } catch { problem = "\(Curves.file(for: name).lastPathComponent): \(error)" }
        if newCurve == nil, problem != nil, dev == device { newCurve = curve }   // keep playing the last good curve
        let want = enabled && newCurve != nil && dev != 0
        let sameDevice = dev == device && chain.map { $0.fs == HAL.rate(dev) && HAL.alive(dev) } ?? false

        if want, sameDevice, !force {
            if newCurve != curve { curve = newCurve; loadCoefficients(running: true) }
        } else if want {
            chain?.stop(); chain = nil
            device = dev; deviceName = name; curve = newCurve
            watch(dev)
            proc.reset()
            loadCoefficients(running: false, fs: HAL.rate(dev))
            do {
                chain = try Chain(device: dev, proc: proc)
                NSLog("eq: on \(name) at \(Int(chain!.fs)) Hz, in \(chain!.layoutIn) out \(chain!.layoutOut), preamp \(preamp)")
            } catch { problem = "\(error)"; NSLog("eq: \(error)") }
        } else {
            if chain != nil { NSLog("eq: off (\(name))") }
            chain?.stop(); chain = nil
            device = dev; deviceName = name; curve = newCurve
            watch(dev)
        }
        onChange()
    }

    private func loadCoefficients(running: Bool, fs: Double? = nil) {
        guard let curve else { return }
        let rate = fs ?? chain?.fs ?? 48000
        preamp = resolvedPreamp(curve, fs: rate)
        proc.load(curve.bands.map { design($0, fs: rate) }, preampDB: preamp, audioRunning: running)
    }

    private func watch(_ dev: AudioObjectID) {
        guard dev != watched else { return }
        if watched != 0 {
            if let r = rateListener { HAL.unlisten(watched, kAudioDevicePropertyNominalSampleRate, r) }
            if let a = aliveListener { HAL.unlisten(watched, kAudioDevicePropertyDeviceIsAlive, a) }
        }
        watched = dev
        guard dev != 0 else { return }
        rateListener = HAL.listen(dev, kAudioDevicePropertyNominalSampleRate) { [weak self] in self?.refresh(force: true) }
        aliveListener = HAL.listen(dev, kAudioDevicePropertyDeviceIsAlive) { [weak self] in self?.refresh(force: true) }
    }

    func shutdown() { chain?.stop(); chain = nil }
}

/// Curve files: ~/.config/eq/<device name>.txt, one per output device.
enum Curves {
    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/eq")
    private static var source: DispatchSourceFileSystemObject?

    static func file(for device: String) -> URL {
        dir.appendingPathComponent(device.replacingOccurrences(of: "/", with: "-") + ".txt")
    }

    static func load(for device: String) throws -> Curve? {
        let url = file(for: device)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return try parseCurve(text)
    }

    /// Calls back on the main queue whenever anything in the folder changes (editors save by
    /// replacing the file, which changes the folder).
    static func watch(_ changed: @escaping () -> Void) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        s.setEventHandler { changed() }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }
}
