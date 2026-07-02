import Foundation
import Cocoa

let bundle = CFBundleCreate(kCFAllocatorDefault, NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework"))!

let ptrInfo = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingInfo" as CFString)!
let getInfoFunc = unsafeBitCast(ptrInfo, to: (@convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void).self)

let group = DispatchGroup()
group.enter()

getInfoFunc(DispatchQueue.global()) { info in
    print("Info: \(info.keys)")
    if let title = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String {
        print("Title: \(title)")
    }
    group.leave()
}

group.wait()
