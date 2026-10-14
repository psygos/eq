import CoreAudio
import Foundation

/// Thin helpers over the Core Audio HAL property API.
enum HAL {
    static func addr(_ sel: AudioObjectPropertySelector,
                     _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func read<T: BitwiseCopyable>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ zero: T,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var a = addr(sel, scope), v = zero, size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    static func set<T: BitwiseCopyable>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ value: T,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> OSStatus {
        var a = addr(sel, scope), v = value
        return AudioObjectSetPropertyData(obj, &a, 0, nil, UInt32(MemoryLayout<T>.size), &v)
    }

    static func string(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var a = addr(sel), s: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &s) == noErr, let s else { return nil }
        return s.takeRetainedValue() as String
    }

    static func ids(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var a = addr(sel, scope), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var out = [AudioObjectID](repeating: 0, count: Int(size) / 4)
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &out) == noErr else { return [] }
        return Array(out.prefix(Int(size) / 4))
    }

    static var defaultOutput: AudioObjectID {
        read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0)) ?? 0
    }

    static func name(_ dev: AudioObjectID) -> String { string(dev, kAudioObjectPropertyName) ?? "?" }
    static func uid(_ dev: AudioObjectID) -> String? { string(dev, kAudioDevicePropertyDeviceUID) }
    static func rate(_ dev: AudioObjectID) -> Double { read(dev, kAudioDevicePropertyNominalSampleRate, Float64(0)) ?? 0 }
    static func alive(_ dev: AudioObjectID) -> Bool { (read(dev, kAudioDevicePropertyDeviceIsAlive, UInt32(0)) ?? 0) != 0 }

    /// The HAL's object for a process, or 0 if it has never touched audio.
    static func process(pid: pid_t) -> AudioObjectID {
        var a = addr(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var p = pid, obj = AudioObjectID(0), size = UInt32(4)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 4, &p, &size, &obj)
        return err == noErr ? obj : 0
    }

    /// Channels per buffer, in the order an IOProc sees them.
    static func streamLayout(_ dev: AudioObjectID, _ scope: AudioObjectPropertyScope) -> [Int] {
        var a = addr(kAudioDevicePropertyStreamConfiguration, scope), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, raw) == noErr else { return [] }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }

    /// Virtual formats of a device's streams in one direction.
    static func formats(_ dev: AudioObjectID, _ scope: AudioObjectPropertyScope) -> [AudioStreamBasicDescription] {
        ids(dev, kAudioDevicePropertyStreams, scope: scope).compactMap {
            read($0, kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription())
        }
    }

    @discardableResult
    static func listen(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                       _ block: @escaping () -> Void) -> AudioObjectPropertyListenerBlock {
        var a = addr(sel)
        let b: AudioObjectPropertyListenerBlock = { _, _ in block() }
        AudioObjectAddPropertyListenerBlock(obj, &a, .main, b)
        return b
    }

    static func unlisten(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ b: @escaping AudioObjectPropertyListenerBlock) {
        var a = addr(sel)
        AudioObjectRemovePropertyListenerBlock(obj, &a, .main, b)
    }
}

struct HALError: Error, CustomStringConvertible {
    let what: String, status: OSStatus
    var description: String {
        let c = UInt32(bitPattern: status)
        let fourcc = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((c >> UInt32($0)) & 0xff))) }
        let printable = fourcc.allSatisfy { $0.isASCII && !$0.isWhitespace || $0 == " " }
        return "\(what) failed (\(printable ? "'" + String(fourcc) + "'" : String(status)))"
    }
}

func check(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw HALError(what: what, status: status) }
}
