import Foundation
import AVFoundation

private func getSilenceRenderBlock() -> AVAudioSourceNodeRenderBlock {
    return { _, _, frameCount, audioBufferList -> OSStatus in
        let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
        for buffer in ablPointer {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        return noErr
    }
}
let engine = AVAudioEngine()
let sourceNode = AVAudioSourceNode(renderBlock: getSilenceRenderBlock())
engine.attach(sourceNode)
engine.connect(sourceNode, to: engine.mainMixerNode, format: engine.outputNode.outputFormat(forBus: 0))
try? engine.start()
Thread.sleep(forTimeInterval: 3.0)
