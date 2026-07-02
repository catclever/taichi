import Foundation
struct MyState { var a = 0; var b = 0; var c = 0 }
var state = MyState()
let group = DispatchGroup()
group.enter()
DispatchQueue.main.async {
    state.a = 1
    group.leave()
}
group.enter()
DispatchQueue.main.async {
    state.b = 2
    group.leave()
}
group.notify(queue: .main) {
    print("State: \(state)")
    exit(0)
}
RunLoop.main.run()
