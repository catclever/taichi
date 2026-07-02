import Foundation
import Cocoa

let bundle = CFBundleCreate(kCFAllocatorDefault, NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework"))!

let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying" as CFString)!
let isPlayingFunc = unsafeBitCast(ptr, to: (@convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void).self)

let group = DispatchGroup()
group.enter()

isPlayingFunc(DispatchQueue.global()) { playing in
    print("Is playing: \(playing)")
    group.leave()
}

group.wait()
