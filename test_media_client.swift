import Foundation
import Cocoa

let bundle = CFBundleCreate(kCFAllocatorDefault, NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework"))!

let ptrClient = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingClient" as CFString)!
let getClientFunc = unsafeBitCast(ptrClient, to: (@convention(c) (DispatchQueue, @escaping (AnyObject) -> Void) -> Void).self)

let ptrBundle = CFBundleGetFunctionPointerForName(bundle, "MRNowPlayingClientGetBundleIdentifier" as CFString)!
let getBundleIdFunc = unsafeBitCast(ptrBundle, to: (@convention(c) (AnyObject) -> CFString).self)

let group = DispatchGroup()
group.enter()

getClientFunc(DispatchQueue.global()) { client in
    print("Client: \(client)")
    let bundleId = getBundleIdFunc(client)
    print("Bundle ID: \(bundleId)")
    group.leave()
}

group.wait()
