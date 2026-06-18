import Foundation

let semaphore = DispatchSemaphore(value: 0)
let wsUrl = URL(string: "ws://echo.websocket.events")!
let task = URLSession.shared.webSocketTask(with: wsUrl)
task.resume()

task.send(.string("Hello")) { error in
    if let error = error {
        print("Send error: \(error)")
    } else {
        task.receive { result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    print("Received: \(text)")
                case .data(let data):
                    print("Received data: \(data)")
                @unknown default:
                    break
                }
            case .failure(let error):
                print("Receive error: \(error)")
            }
            semaphore.signal()
        }
    }
}

semaphore.wait()
