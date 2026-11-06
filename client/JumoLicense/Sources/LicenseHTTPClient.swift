import Foundation

/// One bounded, cookie-free HTTPS request. Redirects never forward card credentials.
final class JumoHTTPClient: NSObject, URLSessionDataDelegate {
    private var session: URLSession?
    private var completion: ((Result<Data, Error>) -> Void)?
    private var bytes = Data()

    func authorize(key: String, machine: String,
                   completion: @escaping (Result<Data, Error>) -> Void) throws {
        precondition(self.completion == nil)
        var request = URLRequest(url: JumoProtocol.endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JumoProtocol.formBody(key: key, machine: machine)
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 5
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.completion = completion
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        session?.dataTask(with: request).resume()
    }

    private func finish(_ result: Result<Data, Error>) {
        guard let callback = completion else { return }
        completion = nil
        session?.invalidateAndCancel()
        session = nil
        bytes.removeAll()
        DispatchQueue.main.async { callback(result) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(.failure(JumoLicenseError.http(response.statusCode)))
    }

    static func retryDelay(_ raw: String?, now: Date = Date()) -> TimeInterval {
        guard let raw = raw else { return 60 }
        if let seconds = Double(raw), seconds.isFinite, seconds >= 0 { return max(1, seconds) }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = format.date(from: raw) { return max(1, date.timeIntervalSince(now)) }
        return 60
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(JumoLicenseError.transport))
            return
        }
        guard http.statusCode == 200 else {
            completionHandler(.cancel)
            if http.statusCode == 429 {
                finish(.failure(JumoLicenseError.throttled(Self.retryDelay(http.value(forHTTPHeaderField: "Retry-After")))))
            } else {
                finish(.failure(JumoLicenseError.http(http.statusCode)))
            }
            return
        }
        guard response.expectedContentLength <= 65_536 else {
            completionHandler(.cancel)
            finish(.failure(JumoLicenseError.format))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard bytes.count + data.count <= 65_536 else {
            finish(.failure(JumoLicenseError.format))
            return
        }
        bytes.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil { finish(.failure(JumoLicenseError.transport)) }
        else { finish(.success(bytes)) }
    }
}
