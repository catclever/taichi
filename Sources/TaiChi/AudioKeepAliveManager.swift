import Foundation
import AVFoundation
import CoreAudio

private func getSilenceRenderBlock() -> AVAudioSourceNodeRenderBlock {
    return { _, _, frameCount, audioBufferList -> OSStatus in
        let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
        for buffer in ablPointer {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
        return noErr
    }
}

@MainActor
class AudioKeepAliveManager: ObservableObject {
    static let shared = AudioKeepAliveManager()
    
    private var engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode!
    
    @Published var isPlaying = false
    @Published var isBluetoothConnected = false
    
    private var isEnabled = false
    
    private init() {
        sourceNode = AVAudioSourceNode(renderBlock: getSilenceRenderBlock())
        engine.attach(sourceNode)
        setupDeviceListener()
        checkCurrentDevice()
    }
    
    func setEnabled(_ enabled: Bool) {
        self.isEnabled = enabled
        updatePlaybackState()
    }
    
    private func updatePlaybackState() {
        if isEnabled && isBluetoothConnected {
            startEngine()
        } else {
            stopEngine()
        }
    }
    
    private func startEngine() {
        guard !isPlaying else { return }
        
        let format = engine.outputNode.outputFormat(forBus: 0)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
        
        do {
            try engine.start()
            isPlaying = true
            print("🎧 [AudioKeepAlive] Started continuous silent playback (Bluetooth active).")
        } catch {
            print("❌ [AudioKeepAlive] Failed to start engine: \(error)")
        }
    }
    
    private func stopEngine() {
        guard isPlaying else { return }
        engine.stop()
        engine.disconnectNodeOutput(sourceNode)
        isPlaying = false
        print("🎧 [AudioKeepAlive] Stopped silent playback.")
    }
    
    // MARK: - CoreAudio Device Monitoring
    
    private func checkCurrentDevice() {
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
            setBluetoothConnected(false)
            return
        }
        
        propertyAddress.mSelector = kAudioDevicePropertyTransportType
        propertyAddress.mScope = kAudioObjectPropertyScopeGlobal
        propertyAddress.mElement = kAudioObjectPropertyElementMain
        
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
            setBluetoothConnected(false)
            return
        }
        
        let isBT = (transportType == kAudioDeviceTransportTypeBluetooth || transportType == kAudioDeviceTransportTypeBluetoothLE)
        setBluetoothConnected(isBT)
    }
    
    private func setBluetoothConnected(_ isBT: Bool) {
        if self.isBluetoothConnected != isBT {
            print("🎧 [AudioKeepAlive] Bluetooth device state changed: \(isBT)")
            self.isBluetoothConnected = isBT
            updatePlaybackState()
        }
    }
    
    private func setupDeviceListener() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let listener: AudioObjectPropertyListenerProc = { objectID, numberAddresses, addresses, clientData in
            guard let clientData = clientData else { return noErr }
            let manager = Unmanaged<AudioKeepAliveManager>.fromOpaque(clientData).takeUnretainedValue()
            Task { @MainActor in
                manager.checkCurrentDevice()
            }
            return noErr
        }
        
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        
        AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            listener,
            selfPointer
        )
    }
}
