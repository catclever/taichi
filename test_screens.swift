import Foundation

let sema = DispatchSemaphore(value: 0)
let url = URL(string: "http://127.0.0.1:9999/")!
var req = URLRequest(url: url)
req.httpMethod = "POST"
req.setValue("application/json", forHTTPHeaderField: "Content-Type")

let actionPayload = ["action": "system.screens", "params": [:]] as [String : Any]
req.httpBody = try! JSONSerialization.data(withJSONObject: actionPayload)

URLSession.shared.dataTask(with: req) { data, resp, err in
    if let data = data {
        let str = String(data: data, encoding: .utf8)!
        print(str)
    } else if let err = err {
        print("Error: \(err)")
    }
    sema.signal()
}.resume()
sema.wait()
