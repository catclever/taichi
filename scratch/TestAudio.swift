import Foundation
import CoreAudio

func getOutputDevices() -> [AudioDeviceID] {
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    
    var dataSize: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize)
    guard status == noErr else { return [] }
    
    let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: kAudioObjectUnknown, count: deviceCount)
    
    status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs)
    guard status == noErr else { return [] }
    
    return deviceIDs.filter { isOutputDevice($0) }
}

func isOutputDevice(_ deviceID: AudioDeviceID) -> Bool {
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    
    var dataSize: UInt32 = 0
    let status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize)
    guard status == noErr else { return false }
    
    let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(dataSize))
    defer { bufferList.deallocate() }
    
    let status2 = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, bufferList)
    guard status2 == noErr else { return false }
    
    let numChannels = (0..<Int(bufferList.pointee.mNumberBuffers)).reduce(0) { sum, i in
        let buffer = withUnsafePointer(to: &bufferList.pointee.mBuffers) {
            $0.withMemoryRebound(to: AudioBuffer.self, capacity: Int(bufferList.pointee.mNumberBuffers)) { ptr in
                ptr[i]
            }
        }
        return sum + Int(buffer.mNumberChannels)
    }
    
    return numChannels > 0
}

func getDeviceTransportType(_ deviceID: AudioDeviceID) -> UInt32 {
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyTransportType,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var transportType: UInt32 = 0
    var propertySize = UInt32(MemoryLayout<UInt32>.size)
    
    let status = AudioObjectGetPropertyData(
        deviceID,
        &propertyAddress,
        0,
        nil,
        &propertySize,
        &transportType
    )
    return status == noErr ? transportType : 0
}

func getDeviceName(_ deviceID: AudioDeviceID) -> String {
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceNameCFString,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var name: Unmanaged<CFString>?
    var propertySize = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
    
    let status = AudioObjectGetPropertyData(
        deviceID,
        &propertyAddress,
        0,
        nil,
        &propertySize,
        &name
    )
    
    if status == noErr, let name = name {
        return name.takeRetainedValue() as String
    }
    return "Unknown"
}

let devices = getOutputDevices()
for device in devices {
    let name = getDeviceName(device)
    let transport = getDeviceTransportType(device)
    let isBuiltIn = (transport == kAudioDeviceTransportTypeBuiltIn)
    print("Device: \(name) (ID: \(device)), BuiltIn: \(isBuiltIn), Transport: \(String(format:"%08X", transport))")
}
