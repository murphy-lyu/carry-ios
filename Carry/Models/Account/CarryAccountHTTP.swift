import Foundation

/// Account requests carry identity tokens, one-use Apple codes or private
/// receipts. A redirect must never forward their headers/body to another route.
nonisolated final class CarryAccountNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
