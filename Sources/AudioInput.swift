import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

struct AudioInputDevice {
    let id: AudioDeviceID
    let uid: String
    let name: String
    static let preferenceKey = "microphoneUID"
    static func devices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { return [] }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
    static func systemDefault() -> AudioInputDevice? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else { return nil }
        return devices().first { $0.id == id }
    }
    static func preferred() -> AudioInputDevice? {
        guard let uid = UserDefaults.standard.string(forKey: preferenceKey), !uid.isEmpty else { return systemDefault() }
        return devices().first { $0.uid == uid }
    }
    func select(on input: AVAudioInputNode) throws {
        guard let unit = input.audioUnit else {
            throw NSError(domain: "AppleJack.Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "The microphone audio unit is unavailable."])
        }
        var deviceID = id
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            throw NSError(domain: "AppleJack.Audio", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Could not select \(name) (audio error \(status)). Choose another input under Menu → Speech & Input → Microphone."])
        }
    }
}

// Read each channel independently: a silent first channel or opposite-polarity
// stereo channels must not hide a real microphone signal. No audio is saved.
final class MicrophoneSignal {
    private let lock = NSLock()
    private var frames = 0
    private var highest: Float = 0
    private var recent: Float = 0
    func prepare(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let count = Int(buffer.frameLength)
        guard count > 0, let channels = buffer.floatChannelData else { return buffer }
        let channelCount = Int(buffer.format.channelCount)
        let stride = buffer.format.isInterleaved ? channelCount : 1
        var strongest = 0
        var peak: Float = 0
        for channel in 0..<channelCount {
            let samples = buffer.format.isInterleaved ? channels[0].advanced(by: channel) : channels[channel]
            var channelPeak: Float = 0
            for index in 0..<count { channelPeak = max(channelPeak, abs(samples[index * stride])) }
            if channelPeak > peak { peak = channelPeak; strongest = channel }
        }
        lock.lock()
        frames += count; highest = max(highest, peak); recent = max(recent, peak)
        lock.unlock()
        guard channelCount > 1,
              let monoFormat = AVAudioFormat(standardFormatWithSampleRate: buffer.format.sampleRate, channels: 1),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
              let destination = mono.floatChannelData?[0] else { return buffer }
        mono.frameLength = buffer.frameLength
        let source = buffer.format.isInterleaved ? channels[0].advanced(by: strongest) : channels[strongest]
        for index in 0..<count { destination[index] = source[index * stride] }
        return mono
    }
    func read() -> (frames: Int, highest: Float, level: Double) {
        lock.lock(); defer { lock.unlock() }
        let db = 20 * log10(max(Double(recent), 0.000001))
        let value = max(0, min(1, (db + 60) / 60))
        recent = 0
        return (frames, highest, value)
    }
}
