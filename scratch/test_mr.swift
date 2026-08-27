import Foundation

// Private MediaRemote declarations
@_silgen_name("MRMediaRemoteSendCommandToApp")
func MRMediaRemoteSendCommandToApp(_ command: UInt32, _ bundleIdentifier: CFString, _ options: CFDictionary?, _ completion: ((CFDictionary?) -> Void)?)

print("Sending play/pause to MusicFree...")
MRMediaRemoteSendCommandToApp(2, "up.2074.musicfree" as CFString, nil, nil)
RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
print("Done")
