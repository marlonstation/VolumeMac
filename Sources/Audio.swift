import AppKit
import AudioToolbox
import CoreAudio
import Darwin

struct AudioEndpoint: Identifiable {
    let id: AudioObjectID
    let name: String
}

struct AudioApp: Identifiable {
    let id: String
    let name: String
    let icon: NSImage?
    var processes: [AudioObjectID] = []
    var playing = false
}

enum AudioDirection {
    case output, input

    var scope: AudioObjectPropertyScope {
        self == .output ? kAudioDevicePropertyScopeOutput : kAudioDevicePropertyScopeInput
    }

    var defaultSelector: AudioObjectPropertySelector {
        self == .output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice
    }

    var title: String { self == .output ? "Output" : "Input" }
    var levelTitle: String { self == .output ? "Output Volume" : "Microphone Gain" }
}

enum Audio {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let outputScope = kAudioDevicePropertyScopeOutput

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func read<T>(_ id: AudioObjectID, _ property: AudioObjectPropertyAddress, into value: inout T) -> Bool {
        var property = property
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &property, 0, nil, &size, $0) == noErr
        }
    }

    static func objects(_ id: AudioObjectID, _ property: AudioObjectPropertyAddress) -> [AudioObjectID] {
        var property = property
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size) == noErr, size > 0 else { return [] }
        let stride = MemoryLayout<AudioObjectID>.stride
        var result = [AudioObjectID](repeating: 0, count: Int(size) / stride)
        let status = result.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return kAudioHardwareBadPropertySizeError }
            return AudioObjectGetPropertyData(id, &property, 0, nil, &size, base)
        }
        return status == noErr ? Array(result.prefix(Int(size) / stride)) : []
    }

    static func endpoints(_ direction: AudioDirection) -> [AudioEndpoint] {
        objects(system, address(kAudioHardwarePropertyDevices)).compactMap { id in
            var available: UInt32 = 0
            guard !objects(id, address(kAudioDevicePropertyStreams, scope: direction.scope)).isEmpty,
                  read(id, address(kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: direction.scope), into: &available),
                  available != 0, let name = string(id, selector: kAudioObjectPropertyName) else { return nil }
            return AudioEndpoint(id: id, name: name)
        }
    }

    static func selection(_ direction: AudioDirection) -> AudioObjectID? {
        var id = AudioObjectID(kAudioObjectUnknown)
        guard read(system, address(direction.defaultSelector), into: &id),
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    static func select(_ device: AudioObjectID, direction: AudioDirection) -> Bool {
        var device = device
        var property = address(direction.defaultSelector)
        return AudioObjectSetPropertyData(system, &property, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &device) == noErr
    }

    static func volume(_ device: AudioObjectID, direction: AudioDirection) -> Double? {
        guard let property = volumeProperty(device, direction: direction) else { return nil }
        var value: Float32 = 0
        guard read(device, property, into: &value), value.isFinite else { return nil }
        return Double(value)
    }

    static func setVolume(_ volume: Double, on device: AudioObjectID, direction: AudioDirection) -> Bool {
        guard var property = volumeProperty(device, direction: direction) else { return false }
        var value = Float32(min(1, max(0, volume)))
        return AudioObjectSetPropertyData(device, &property, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    private static func volumeProperty(_ device: AudioObjectID, direction: AudioDirection) -> AudioObjectPropertyAddress? {
        let scope = direction.scope
        var properties = [
            address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope),
            address(kAudioDevicePropertyVolumeScalar, scope: scope)
        ]
        let streams = objects(device, address(kAudioDevicePropertyStreams, scope: scope))
        if streams.count == 1 {
            var format = AudioStreamBasicDescription()
            if read(streams[0], address(kAudioStreamPropertyVirtualFormat), into: &format),
               format.mChannelsPerFrame == 1 {
                properties.append(AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyVolumeScalar, mScope: scope, mElement: 1
                ))
            }
        }
        return properties.first { candidate in
            var property = candidate
            var writable = DarwinBoolean(false)
            return AudioObjectIsPropertySettable(device, &property, &writable) == noErr && writable.boolValue
        }
    }

    static func string(_ id: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var value: Unmanaged<CFString>?
        guard read(id, address(selector), into: &value), let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func applications(on output: AudioObjectID?) -> [AudioApp] {
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != getpid()
        }
        var byPID: [pid_t: String] = [:]
        var apps: [String: AudioApp] = [:]
        for app in running {
            guard let name = app.localizedName else { continue }
            let key = app.bundleIdentifier ?? String(app.processIdentifier)
            byPID[app.processIdentifier] = key
            apps[key] = AudioApp(id: key, name: name, icon: app.icon)
        }
        for process in objects(system, address(kAudioHardwarePropertyProcessObjectList)) {
            var active: UInt32 = 0
            var pid: pid_t = 0
            guard read(process, address(kAudioProcessPropertyIsRunningOutput), into: &active),
                  active != 0, read(process, address(kAudioProcessPropertyPID), into: &pid),
                  pid > 0, pid != getpid() else { continue }
            let key = owner(of: pid, visible: byPID) ?? string(process, selector: kAudioProcessPropertyBundleID)
                .flatMap { bundle in
                    apps.keys.filter { bundle == $0 || bundle.hasPrefix($0 + ".") }.max { $0.count < $1.count }
                }
            guard let key, var app = apps[key] else { continue }
            app.playing = true
            let devices = objects(process, address(kAudioProcessPropertyDevices, scope: outputScope))
            if let output, devices.isEmpty || devices.contains(output) {
                app.processes.append(process)
            }
            apps[key] = app
        }
        return apps.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func owner(of pid: pid_t, visible: [pid_t: String]) -> String? {
        var candidate = pid
        for _ in 0..<12 {
            if let owner = visible[candidate] { return owner }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard candidate > 1,
                  proc_pidinfo(candidate, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.pbi_ppid > 1, info.pbi_ppid != candidate else { break }
            candidate = pid_t(info.pbi_ppid)
        }
        return nil
    }
}
