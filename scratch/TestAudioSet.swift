import Foundation
import CoreAudio

func getCurrentOutputDevice() -> AudioDeviceID {
    var defaultOutputDeviceID = kAudioObjectUnknown
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &propertySize, &defaultOutputDeviceID)
    return defaultOutputDeviceID
}

func setDefaultOutputDevice(_ deviceID: AudioDeviceID) {
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var id = deviceID
    let size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, size, &id)
}

let original = getCurrentOutputDevice()
print("Original device ID: \(original)")
// Switch to 189 (MacBook Pro Speakers)
setDefaultOutputDevice(189)
print("Switched to 189")
Thread.sleep(forTimeInterval: 0.1)
setDefaultOutputDevice(original)
print("Restored original device")
