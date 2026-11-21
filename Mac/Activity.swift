import AudioToolbox
import AVFoundation
import CoreAudio
import CoreMediaIO

struct CaptureActivity: Codable, Equatable, Sendable {
    let microphone: Bool
    let camera: Bool
    private static let cameraDiscovery = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
        mediaType: .video, position: .unspecified
    )

    static func read() -> Self {
        Self(microphone: microphoneActive(), camera: cameraActive())
    }

    private static func microphoneActive() -> Bool {
        var list = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &list, 0, nil, &size) == noErr,
              size > 0 else { return false }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / 4)
        let result = processes.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(system, &list, 0, nil, &size, $0.baseAddress!)
        }
        guard result == noErr else { return false }

        // This selects input streams. Output-only playback leaves the sign idle.
        for process in processes.prefix(Int(size) / 4) {
            var runningInput = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningInput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var running: UInt32 = 0
            var valueSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(process, &runningInput, 0, nil, &valueSize, &running) == noErr,
               running != 0 { return true }
        }
        return false
    }

    private static func cameraActive() -> Bool {
        if cameraDiscovery.devices.contains(where: \.isInUseByAnotherApplication) { return true }

        // Also check the CoreMediaIO device state, including extensions.
        var list = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &list, 0, nil, &size) == noErr,
              size > 0 else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / 4)
        var used: UInt32 = 0
        let result = devices.withUnsafeMutableBytes {
            CMIOObjectGetPropertyData(system, &list, 0, nil, size, &used, $0.baseAddress!)
        }
        guard result == noErr else { return false }
        for device in devices.prefix(Int(used) / 4) {
            var inputStreams = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams),
                mScope: CMIOObjectPropertyScope(kCMIODevicePropertyScopeInput),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            var streamBytes: UInt32 = 0
            guard CMIOObjectGetPropertyDataSize(device, &inputStreams, 0, nil, &streamBytes) == noErr,
                  streamBytes > 0 else { continue }
            var runningSomewhere = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            var running: UInt32 = 0
            if CMIOObjectGetPropertyData(device, &runningSomewhere, 0, nil, 4, &used, &running) == noErr,
               running != 0 { return true }
        }
        return false
    }
}
