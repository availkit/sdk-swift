import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// One fresh ephemeral session/task, no application retries or shared connection pool.
/// The lock covers all mutable delegate state; completion is consumed exactly once.
final class OneRequest: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate,
  @unchecked Sendable
{
  private let lock = NSLock()
  private let maxBytes: Int
  private var continuation: CheckedContinuation<(Data, HTTPURLResponse), any Error>?
  private var result: Result<(Data, HTTPURLResponse), any Error>?
  private var session: URLSession?
  private var task: URLSessionDataTask?
  private var timer: Task<Void, Never>?
  private var bytes = Data()
  private var response: HTTPURLResponse?
  private init(maxBytes: Int) { self.maxBytes = maxBytes }
  static func run(_ request: URLRequest, timeout: TimeInterval, maxBytes: Int) async throws -> (
    Data, HTTPURLResponse
  ) {
    let job = OneRequest(maxBytes: maxBytes)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        job.start(request, timeout: timeout, continuation: continuation)
      }
    } onCancel: {
      job.finish(.failure(AvailKitError(.transport, "cancelled")))
    }
  }
  private func start(
    _ request: URLRequest, timeout: TimeInterval,
    continuation: CheckedContinuation<(Data, HTTPURLResponse), any Error>
  ) {
    lock.lock()
    if let result {
      lock.unlock()
      continuation.resume(with: result)
      return
    }
    self.continuation = continuation
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.urlCache = nil
    config.urlCredentialStorage = nil
    config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    config.connectionProxyDictionary = [:]
    config.timeoutIntervalForRequest = timeout
    config.timeoutIntervalForResource = timeout
    config.httpMaximumConnectionsPerHost = 1
    let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    self.session = session
    let task = session.dataTask(with: request)
    self.task = task
    timer = Task { [weak self] in
      do {
        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        self?.finish(.failure(AvailKitError(.transport, "timeout")))
      } catch {}
    }
    task.resume()
    lock.unlock()
  }
  private func finish(_ value: Result<(Data, HTTPURLResponse), any Error>) {
    lock.lock()
    guard result == nil else {
      lock.unlock()
      return
    }
    result = value
    let continuation = self.continuation
    self.continuation = nil
    let session = self.session
    self.session = nil
    let task = self.task
    self.task = nil
    let timer = self.timer
    self.timer = nil
    lock.unlock()
    timer?.cancel()
    task?.cancel()
    session?.invalidateAndCancel()
    continuation?.resume(with: value)
  }
  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    guard let http = response as? HTTPURLResponse else {
      completionHandler(.cancel)
      finish(.failure(AvailKitError(.protocol, "invalid_response")))
      return
    }
    let status = http.statusCode
    let media = http.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first?
      .trimmingCharacters(in: .whitespaces).lowercased()
    let encoding = http.value(forHTTPHeaderField: "Content-Encoding")?.lowercased() ?? "identity"
    guard !(300..<400).contains(status),
      ["application/json", "application/problem+json"].contains(media),
      !(200..<300).contains(status) || media == "application/json", encoding == "identity",
      response.expectedContentLength <= maxBytes
    else {
      completionHandler(.cancel)
      finish(
        .failure(
          AvailKitError(
            .protocol,
            response.expectedContentLength > maxBytes ? "response_too_large" : "invalid_response",
            status: status)))
      return
    }
    lock.lock()
    self.response = http
    lock.unlock()
    completionHandler(.allow)
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    lock.lock()
    let tooLarge = data.count > maxBytes - bytes.count
    if !tooLarge && result == nil { bytes.append(data) }
    lock.unlock()
    if tooLarge { finish(.failure(AvailKitError(.protocol, "response_too_large"))) }
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
  ) {
    lock.lock()
    let data = bytes
    let response = self.response
    lock.unlock()
    if let error {
      let code = (error as NSError).code
      finish(
        .failure(
          AvailKitError(
            .transport,
            code == NSURLErrorTimedOut
              ? "timeout" : code == NSURLErrorCancelled ? "cancelled" : "request_failed")))
      return
    }
    guard let response else {
      finish(.failure(AvailKitError(.protocol, "invalid_response")))
      return
    }
    guard response.expectedContentLength < 0 || response.expectedContentLength == data.count else {
      finish(.failure(AvailKitError(.protocol, "incomplete_response", status: response.statusCode)))
      return
    }
    do {
      try StrictJSON.check(data)
      finish(.success((data, response)))
    } catch {
      finish(.failure(AvailKitError(.protocol, "invalid_json", status: response.statusCode)))
    }
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
    finish(.failure(AvailKitError(.protocol, "redirect_denied", status: response.statusCode)))
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
    completionHandler:
      @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    // Platform TLS trust validation remains mandatory; no HTTP auth replay.
    completionHandler(
      challenge.protectionSpace.authenticationMethod == "NSURLAuthenticationMethodServerTrust"
        ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    needNewBodyStream completionHandler: @escaping @Sendable (InputStream?) -> Void
  ) { completionHandler(nil) }
}
