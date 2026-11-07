import Foundation
import CoreAudio

struct AudioOutputDevice: Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String

    static func devices() -> [AudioOutputDevice] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard ids.withUnsafeMutableBytes({ AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!) }) == noErr else { return [] }
        return ids.compactMap { id in
            // Input-only devices, disconnected devices, and private audio drivers
            // must not be offered as destinations for system media playback.
            guard number(id, kAudioDevicePropertyDeviceIsAlive) == 1,
                  number(id, kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: kAudioDevicePropertyScopeOutput) == 1,
                  let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return AudioOutputDevice(id: id, uid: uid, name: name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func defaultID() -> AudioDeviceID? {
        number(system, kAudioHardwarePropertyDefaultOutputDevice)
    }

    static func select(uid: String) throws {
        // Resolve the UID again: hardware IDs can change after reconnection.
        guard let device = devices().first(where: { $0.uid == uid }) else {
            throw failure("That audio output is no longer connected. Choose another output.")
        }
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(system, &address, &settable) == noErr, settable.boolValue else {
            throw failure("macOS isn’t allowing the audio output to change right now.")
        }
        var id = device.id
        let status = AudioObjectSetPropertyData(system, &address, 0, nil, UInt32(MemoryLayout.size(ofValue: id)), &id)
        guard status == noErr else {
            throw failure("Couldn’t switch to \(device.name) (audio error \(status)).")
        }
        // Leave the microphone and the separate system-alert output alone.
        // The hardware listener refreshes the checkmark from macOS's real state.
    }

    static let system = AudioObjectID(kAudioObjectSystemObject)
    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private static func number(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = address(selector, scope: scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout.size(ofValue: value))
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: value))
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "AppleJack.AudioOutput", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

final class AudioOutputObserver {
    private var selectors: [AudioObjectPropertySelector] = []
    private let listener: AudioObjectPropertyListenerBlock
    init(onChange: @escaping () -> Void) {
        listener = { _, _ in onChange() }
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioOutputDevice.address(selector)
            if AudioObjectAddPropertyListenerBlock(AudioOutputDevice.system, &address, .main, listener) == noErr {
                selectors.append(selector)
            }
        }
    }
    deinit {
        for selector in selectors {
            var address = AudioOutputDevice.address(selector)
            AudioObjectRemovePropertyListenerBlock(AudioOutputDevice.system, &address, .main, listener)
        }
    }
}
