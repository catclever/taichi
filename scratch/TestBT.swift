import Foundation
import CoreAudio
import AVFoundation

func checkCurrentDevice() {
    var defaultOutputDeviceID = kAudioObjectUnknown
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
    
    var status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &propertyAddress,
        0,
        nil,
        &propertySize,
        &defaultOutputDeviceID
    )
    
    guard status == noErr, defaultOutputDeviceID != kAudioObjectUnknown else {
        print("No device found")
        return
    }
    
    propertyAddress.mSelector = kAudioDevicePropertyTransportType
    
    var transportType: UInt32 = 0
    propertySize = UInt32(MemoryLayout<UInt32>.size)
    
    status = AudioObjectGetPropertyData(
        defaultOutputDeviceID,
        &propertyAddress,
        0,
        nil,
        &propertySize,
        &transportType
    )
    
    guard status == noErr else {
        print("Could not get transport type")
        return
    }
    
    let isBT = (transportType == kAudioDeviceTransportTypeBluetooth || transportType == kAudioDeviceTransportTypeBluetoothLE)
    print("Device ID: \(defaultOutputDeviceID)")
    print("Transport Type: \(String(format:"%08X", transportType))")
    print("Is Bluetooth: \(isBT)")
}

checkCurrentDevice()
