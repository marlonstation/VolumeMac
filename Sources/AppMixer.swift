import AudioToolbox
import CoreAudio
import Foundation

struct MixRequest: Equatable {
    let source: AudioObjectID?
    let output: AudioObjectID
    let processes: [AudioObjectID]
    let gain: Double

    func sameRoute(as other: MixRequest) -> Bool {
        source == other.source && output == other.output && processes == other.processes
    }
}

enum MixState: Equatable {
    case preparing, active, failed(String)
}

private struct MixerFailure: LocalizedError {
    let explanation: String
    let status: OSStatus?

    init(_ explanation: String, status: OSStatus? = nil) {
        self.explanation = explanation
        self.status = status
    }

    var errorDescription: String? {
        guard let status else { return explanation }
        return "\(explanation) (\(status))"
    }
}

private final class ProcessSession {
    private let buffer: OpaquePointer
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var input: AudioDeviceIOProcID?
    private var output: AudioUnit?
    private var started = false
    private var stopped = false
    private var tapDescription: CATapDescription?
    private var armed = false
    private var startTime = Date()
    private var lastFrameTime = Date()
    private var lastFrames: UInt64 = 0

    init(_ request: MixRequest) throws {
        guard let buffer = vm_buffer_create() else { throw MixerFailure("Could not allocate memory for the mixer.") }
        self.buffer = buffer
        do {
            try start(request)
        } catch {
            stop()
            throw error
        }
    }

    deinit { stop() }

    var state: MixState {
        if vm_buffer_format_failed(buffer) {
            return .failed("Unsupported audio format. Original playback was restored.")
        }
        if !armed {
            if vm_buffer_heard_signal(buffer) {
                do {
                    try activateMix()
                } catch {
                    return .failed(error.localizedDescription)
                }
            } else {
                return Date().timeIntervalSince(startTime) > 8
                    ? .failed("No audio reached the mixer. Check System Audio Recording access and play audio in the app.")
                    : .preparing
            }
        }
        let frames = vm_buffer_frames_played(buffer)
        if frames != lastFrames {
            lastFrames = frames
            lastFrameTime = Date()
        }
        if Date().timeIntervalSince(lastFrameTime) > 4 {
            return .failed("Audio stopped reaching the mixer. Original playback was restored.")
        }
        return frames > 0 ? .active : .preparing
    }

    func setGain(_ gain: Double) { vm_buffer_set_gain(buffer, Float(gain)) }

    private func start(_ request: MixRequest) throws {
        let description: CATapDescription
        if let source = request.source {
            guard let uid = Audio.string(source, selector: kAudioDevicePropertyDeviceUID) else {
                throw MixerFailure("Could not identify the source audio device.")
            }
            description = CATapDescription(processes: request.processes, deviceUID: uid, stream: 0)
        } else {
            description = CATapDescription(stereoMixdownOfProcesses: request.processes)
        }
        description.name = "VolumeMac"
        description.isPrivate = true
        description.isMixdown = true
        description.isMono = false
        // Verify the signal path without replacing the original playback.
        description.muteBehavior = .unmuted
        tapDescription = description
        try check(AudioHardwareCreateProcessTap(description, &tap),
                  "Could not create the app audio tap.")

        var format = AudioStreamBasicDescription()
        guard Audio.read(tap, Audio.address(kAudioTapPropertyFormat), into: &format),
              format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == kAudioFormatFlagsNativeEndian,
              format.mBitsPerChannel == 32, format.mChannelsPerFrame == 2,
              format.mBytesPerFrame == (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0 ? 8 : 4),
              format.mSampleRate.isFinite, format.mSampleRate > 0 else {
            throw MixerFailure("The audio tap did not provide the required stereo format.")
        }
        guard let tapUID = Audio.string(tap, selector: kAudioTapPropertyUID) else {
            throw MixerFailure("Could not identify the audio tap.")
        }
        let descriptor: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VolumeMac Mixer Input",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true
            ]]
        ]
        try check(AudioHardwareCreateAggregateDevice(descriptor as CFDictionary, &aggregate),
                  "Could not prepare the app audio stream.")
        try configureOutput(device: request.output, rate: format.mSampleRate)
        try check(AudioDeviceCreateIOProcID(aggregate, vm_capture, UnsafeMutableRawPointer(buffer), &input),
                  "Could not connect the audio tap.")
        guard let input, let output else { throw MixerFailure("Could not start the mixer.") }
        setGain(request.gain)
        try check(AudioOutputUnitStart(output), "Could not start mixer playback.")
        try check(AudioDeviceStart(aggregate, input),
                  "Could not start app audio. Check System Audio Recording access.")
        started = true
        startTime = Date()
        lastFrameTime = startTime
    }

    private func activateMix() throws {
        guard let description = tapDescription else { throw MixerFailure("The audio tap is unavailable.") }
        // Core Audio restores the original stream as soon as the reader stops.
        description.muteBehavior = .mutedWhenTapped
        var reference = Unmanaged.passUnretained(description)
        var property = Audio.address(kAudioTapPropertyDescription)
        let size = UInt32(MemoryLayout.size(ofValue: reference))
        let status = withUnsafePointer(to: &reference) {
            AudioObjectSetPropertyData(tap, &property, 0, nil, size, $0)
        }
        try check(status, "Could not take control of the app volume.")
        vm_buffer_arm(buffer)
        armed = true
    }

    private func configureOutput(device: AudioObjectID, rate: Double) throws {
        var descriptor = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &descriptor) else {
            throw MixerFailure("The Core Audio output unit is unavailable.")
        }
        try check(AudioComponentInstanceNew(component, &output), "Could not prepare the mixer output.")
        guard let output else { throw MixerFailure("The output unit could not be created.") }
        var off: UInt32 = 0
        try check(set(output, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &off),
                  "Could not disable input on the playback unit.")
        var deviceID = device
        try check(set(output, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID),
                  "The mixer could not use this output device.")
        var stream = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0
        )
        try check(set(output, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &stream),
                  "The output did not accept the app’s stereo format.")
        var callback = AURenderCallbackStruct(inputProc: vm_render, inputProcRefCon: UnsafeMutableRawPointer(buffer))
        try check(set(output, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback),
                  "Could not connect audio playback.")
        try check(AudioUnitInitialize(output), "Could not initialize mixer output.")
    }

    private func stop() {
        guard !stopped else { return }
        stopped = true
        if let input {
            if started { AudioDeviceStop(aggregate, input) }
            AudioDeviceDestroyIOProcID(aggregate, input)
        }
        if let output {
            AudioOutputUnitStop(output)
            AudioUnitUninitialize(output)
            AudioComponentInstanceDispose(output)
        }
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate) }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        vm_buffer_destroy(buffer)
    }

    private func set<T>(_ unit: AudioUnit, _ property: AudioUnitPropertyID,
                        _ scope: AudioUnitScope, _ element: AudioUnitElement, _ value: inout T) -> OSStatus {
        withUnsafePointer(to: &value) {
            AudioUnitSetProperty(unit, property, scope, element, $0, UInt32(MemoryLayout<T>.size))
        }
    }

    private func check(_ status: OSStatus, _ message: String) throws {
        guard status == noErr else { throw MixerFailure(message, status: status) }
    }
}

final class AppMixer {
    private let queue = DispatchQueue(label: "VolumeMac.AppMixer", qos: .userInitiated)
    private var routes: [String: MixRequest] = [:]
    private var sessions: [String: ProcessSession] = [:]
    private var failed: [String: String] = [:]

    func update(_ requests: [String: MixRequest], completion: @escaping ([String: MixState]) -> Void) {
        queue.async {
            for key in Array(self.routes.keys) {
                guard let request = requests[key], let route = self.routes[key],
                      route.sameRoute(as: request), self.failed[key] == nil || route.gain == request.gain else {
                    self.sessions.removeValue(forKey: key)
                    self.routes.removeValue(forKey: key)
                    self.failed.removeValue(forKey: key)
                    continue
                }
            }
            var states: [String: MixState] = [:]
            for (key, request) in requests {
                self.routes[key] = request
                if let problem = self.failed[key] {
                    states[key] = .failed(problem)
                    continue
                }
                do {
                    if self.sessions[key] == nil {
                        self.sessions[key] = try ProcessSession(request)
                    }
                    guard let session = self.sessions[key] else { continue }
                    session.setGain(request.gain)
                    let state = session.state
                    if case .failed(let message) = state {
                        self.sessions.removeValue(forKey: key)
                        self.failed[key] = message
                    }
                    states[key] = state
                } catch {
                    self.failed[key] = error.localizedDescription
                    states[key] = .failed(error.localizedDescription)
                }
            }
            DispatchQueue.main.async { completion(states) }
        }
    }
}
