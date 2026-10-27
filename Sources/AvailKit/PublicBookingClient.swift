import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Safe finite diagnostics. Raw request/response/URLSession errors are never retained.
public struct AvailKitError: Error, Sendable, CustomStringConvertible {
  public enum Kind: String, Sendable { case input, transport, api, `protocol` }
  public let kind: Kind
  public let code: String
  public let status: Int?
  public let mutationOutcomeUnknown: Bool
  public var description: String { "AvailKit \(kind.rawValue): \(code)" }
  init(_ kind: Kind, _ code: String, status: Int? = nil, unknown: Bool = false) {
    self.kind = kind
    self.code = code
    self.status = status
    mutationOutcomeUnknown = unknown
  }
}
private func fail(_ code: String) -> AvailKitError { AvailKitError(.input, code) }
private func id(_ value: String) throws {
  guard value.utf8.count == 32,
    value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
  else { throw fail("invalid_id") }
}
private func access(_ value: String) throws {
  guard value.utf8.count == 43,
    value.utf8.allSatisfy({
      (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95
        || $0 == 45
    }), "AEIMQUYcgkosw048".contains(value.last!)
  else { throw fail("invalid_capability") }
}
private func key(_ value: String) throws {
  guard (16...128).contains(value.utf8.count), value.utf8.allSatisfy({ (32...126).contains($0) }),
    value.trimmingCharacters(in: .whitespaces) == value
  else { throw fail("invalid_idempotency_key") }
}
private func origin(_ value: String) throws -> String {
  guard let u = URLComponents(string: value), let host = u.host,
    ["https", "http"].contains(u.scheme),
    u.scheme != "http" || ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host), u.user == nil,
    u.password == nil, u.query == nil, u.fragment == nil, ["", "/"].contains(u.path),
    value.utf8.allSatisfy({ $0 > 32 && $0 < 127 }), let url = u.url
  else { throw fail("invalid_base_url") }
  return url.absoluteString.hasSuffix("/")
    ? String(url.absoluteString.dropLast()) : url.absoluteString
}
func utc(_ value: String) throws -> Date {
  guard
    value.range(
      of: #"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,9})?Z$"#, options: .regularExpression) != nil
  else { throw fail("invalid_timestamp") }
  let format = ISO8601DateFormatter()
  format.formatOptions =
    value.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
  guard let date = format.date(from: value) else { throw fail("invalid_timestamp") }
  return date
}
public enum AvailKitSecrets {
  /// Cryptographic system RNG. Generate once and persist with the original intent.
  public static func newBookingToken() -> String { token(32) }
  public static func newIdempotencyKey() -> String { token(24) }
  private static func token(_ count: Int) -> String {
    var random = SystemRandomNumberGenerator()
    return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &random) })
      .base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(
        of: "/", with: "_"
      ).replacingOccurrences(of: "=", with: "")
  }
}

/// Immutable original bytes/key/origin/page/capabilities. Loading never sends.
/// Contains private contact data and capabilities. Store in an app-private encrypted
/// store (Keychain/file protection); never UserDefaults, logs, analytics or URLs.
public struct BookingIntent: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  fileprivate struct Record: Codable, Sendable {
    let version: Int
    let operation: String
    let path: String
    let body: Data
    let idempotencyKey: String
    let origin: String
    let pageID: String
    let bookingToken: String
    let contactToken: String?
    let createdAt: Date
  }
  fileprivate let record: Record
  public var description: String { "AvailKit BookingIntent (private)" }
  public var debugDescription: String { description }
  public func exportPrivate() throws -> Data { try JSONEncoder().encode(record) }
  public static func importPrivate(_ data: Data) throws -> BookingIntent {
    guard data.count <= 131_072 else { throw fail("invalid_intent") }
    do {
      try StrictJSON.check(data)
      let record = try JSONDecoder().decode(Record.self, from: data)
      return BookingIntent(record: record)
    } catch { throw fail("invalid_intent") }
  }
}

/// Supported mobile path: a published page plus private per-booking capabilities.
/// No workspace keys, account/passkey login or cookie sessions are accepted.
public struct PublicBookingClient: Sendable, CustomStringConvertible {
  public let pageID: String
  public let baseURL: String
  public let timeout: TimeInterval
  public let maxResponseBytes: Int
  public var description: String { "AvailKit PublicBookingClient" }
  public init(
    pageID: String, baseURL: String = "https://api.availkit.com", timeout: TimeInterval = 10,
    maxResponseBytes: Int = 262_144
  ) throws {
    try id(pageID)
    guard timeout.isFinite, timeout > 0, timeout <= 120, (1...8_388_608).contains(maxResponseBytes)
    else { throw fail("invalid_limits") }
    self.pageID = pageID
    self.baseURL = try origin(baseURL)
    self.timeout = timeout
    self.maxResponseBytes = maxResponseBytes
  }
  public func getPage() async throws -> PublicPage {
    try await send("getPublicPage", path: "", schema: "PublicPage")
  }
  public func listOfferings(after: String? = nil, limit: Int = 25) async throws
    -> PublicOfferingPage
  {
    guard (1...100).contains(limit) else { throw fail("invalid_limit") }
    var query = [URLQueryItem(name: "limit", value: String(limit))]
    if let after {
      try id(after)
      query.append(URLQueryItem(name: "after", value: after))
    }
    let page: PublicOfferingPage = try await send(
      "listPublicOfferings", path: "/offerings", query: query, schema: "PublicOfferingPage")
    guard page.items.count <= limit else { throw AvailKitError(.protocol, "invalid_response") }
    var cursor = after ?? ""
    for item in page.items {
      try id(item.id)
      guard item.id > cursor else { throw AvailKitError(.protocol, "invalid_response") }
      cursor = item.id
    }
    guard page.nextAfter == nil || page.items.count == limit && page.nextAfter == cursor else {
      throw AvailKitError(.protocol, "invalid_response")
    }
    return page
  }
  public func availability(offeringID: String, from: String, to: String) async throws
    -> Availability
  {
    try id(offeringID)
    let lo = try utc(from)
    let hi = try utc(to)
    guard hi > lo, hi.timeIntervalSince(lo) <= 604_800 else { throw fail("invalid_range") }
    let value: Availability = try await send(
      "publicAvailability", path: "/availability",
      query: [
        URLQueryItem(name: "offeringId", value: offeringID),
        URLQueryItem(name: "from", value: from), URLQueryItem(name: "to", value: to),
      ], schema: "Availability")
    var previous: Date?
    for slot in value.slots {
      let start = try utc(slot.start)
      let end = try utc(slot.end)
      guard start >= lo, end <= hi, end > start, previous == nil || start > previous!,
        slot.remainingCapacity > 0
      else { throw AvailKitError(.protocol, "invalid_response") }
      previous = start
    }
    return value
  }
  public func prepareBook(
    _ body: PublicBookingInput, idempotencyKey: String, bookingToken: String, contactToken: String
  ) throws -> BookingIntent {
    try prepare(
      "bookPublic", path: "/bookings", body: body, schema: "PublicBookingInput",
      idempotencyKey: idempotencyKey, bookingToken: bookingToken, contactToken: contactToken)
  }
  public func prepareCancel(bookingID: String, idempotencyKey: String, bookingToken: String) throws
    -> BookingIntent
  {
    try id(bookingID)
    return try prepare(
      "cancelPublicBooking", path: "/bookings/\(bookingID)/cancel", body: Empty(), schema: "Empty",
      idempotencyKey: idempotencyKey, bookingToken: bookingToken)
  }
  public func prepareReschedule(
    bookingID: String, body: RescheduleInput, idempotencyKey: String, bookingToken: String
  ) throws -> BookingIntent {
    try id(bookingID)
    return try prepare(
      "reschedulePublicBooking", path: "/bookings/\(bookingID)/reschedule", body: body,
      schema: "RescheduleInput", idempotencyKey: idempotencyKey, bookingToken: bookingToken)
  }
  public func book(
    _ body: PublicBookingInput, idempotencyKey: String, bookingToken: String, contactToken: String
  ) async throws -> PublicBooking {
    try await execute(
      prepareBook(
        body, idempotencyKey: idempotencyKey, bookingToken: bookingToken, contactToken: contactToken
      ))
  }
  public func cancel(bookingID: String, idempotencyKey: String, bookingToken: String) async throws
    -> PublicBooking
  {
    try await execute(
      prepareCancel(
        bookingID: bookingID, idempotencyKey: idempotencyKey, bookingToken: bookingToken))
  }
  public func reschedule(
    bookingID: String, body: RescheduleInput, idempotencyKey: String, bookingToken: String
  ) async throws -> PublicBooking {
    try await execute(
      prepareReschedule(
        bookingID: bookingID, body: body, idempotencyKey: idempotencyKey, bookingToken: bookingToken
      ))
  }
  public func getBooking(bookingID: String, bookingToken: String) async throws -> PublicBooking {
    try id(bookingID)
    try access(bookingToken)
    let value: PublicBooking = try await send(
      "getPublicBooking", path: "/bookings/\(bookingID)", bookingToken: bookingToken,
      schema: "PublicBooking")
    guard value.id == bookingID else { throw AvailKitError(.protocol, "invalid_response") }
    return value
  }
  private func prepare<T: Encodable>(
    _ operation: String, path: String, body: T, schema: String, idempotencyKey: String,
    bookingToken: String, contactToken: String? = nil
  ) throws -> BookingIntent {
    try key(idempotencyKey)
    try access(bookingToken)
    if let contactToken { try access(contactToken) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let bytes = try encoder.encode(body)
    try Schema.input(bytes, schema)
    return BookingIntent(
      record: .init(
        version: 1, operation: operation, path: path, body: bytes, idempotencyKey: idempotencyKey,
        origin: baseURL, pageID: pageID, bookingToken: bookingToken, contactToken: contactToken,
        createdAt: Date()))
  }
  /// Each invocation sends the retained original once; never a fresh replacement.
  /// A24h local guard cannot prove server receipt retention after privacy pruning.
  public func execute(_ intent: BookingIntent) async throws -> PublicBooking {
    let r = intent.record
    guard r.version == 1, r.origin == baseURL, r.pageID == pageID,
      ["bookPublic", "cancelPublicBooking", "reschedulePublicBooking"].contains(r.operation)
    else { throw fail("intent_scope_mismatch") }
    let age = Date().timeIntervalSince(r.createdAt)
    guard age < 86_400 else { throw fail("intent_expired") }
    guard age >= 0 else { throw fail("invalid_intent_timestamp") }
    try key(r.idempotencyKey)
    try access(r.bookingToken)
    var bookingID: String?
    if r.operation == "bookPublic" {
      guard r.path == "/bookings", let contactToken = r.contactToken else {
        throw fail("invalid_intent")
      }
      try access(contactToken)
    } else {
      let parts = r.path.split(separator: "/")
      guard parts.count == 3, parts[0] == "bookings",
        parts[2] == (r.operation == "cancelPublicBooking" ? "cancel" : "reschedule"),
        r.contactToken == nil
      else { throw fail("invalid_intent") }
      bookingID = String(parts[1])
      try id(bookingID!)
      let suffix = r.operation == "cancelPublicBooking" ? "cancel" : "reschedule"
      guard r.path == "/bookings/\(bookingID!)/\(suffix)" else { throw fail("invalid_intent") }
    }
    let schema =
      r.operation == "bookPublic"
      ? "PublicBookingInput" : r.operation == "cancelPublicBooking" ? "Empty" : "RescheduleInput"
    try Schema.input(r.body, schema)
    let value: PublicBooking = try await send(
      r.operation, path: r.path, body: r.body, bookingToken: r.bookingToken,
      contactToken: r.contactToken, idempotencyKey: r.idempotencyKey, schema: "PublicBooking")
    let request = try JSONSerialization.jsonObject(with: r.body) as! [String: Any]
    guard bookingID == nil || value.id == bookingID else {
      throw AvailKitError(.protocol, "invalid_response", unknown: true)
    }
    if r.operation == "cancelPublicBooking" {
      guard value.status.rawValue == "cancelled" else {
        throw AvailKitError(.protocol, "invalid_response", unknown: true)
      }
    } else {
      guard value.status.rawValue == "confirmed",
        try utc(value.start) == utc(request["start"] as! String),
        r.operation != "bookPublic" || value.offering.id == request["offeringId"] as! String
      else { throw AvailKitError(.protocol, "invalid_response", unknown: true) }
    }
    return value
  }
  private func send<T: Decodable>(
    _ operation: String, path: String, query: [URLQueryItem] = [], body: Data? = nil,
    bookingToken: String? = nil, contactToken: String? = nil, idempotencyKey: String? = nil,
    schema: String
  ) async throws -> T {
    guard !Task.isCancelled else { throw AvailKitError(.transport, "cancelled") }
    var components = URLComponents(string: baseURL + "/v1/public/pages/" + pageID + path)!
    if !query.isEmpty { components.queryItems = query }
    var request = URLRequest(
      url: components.url!, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
      timeoutInterval: timeout)
    request.httpMethod = body == nil ? "GET" : "POST"
    // A one-use stream cannot be regenerated for an HTTP protocol/auth replay.
    // The delegate refuses needNewBodyStream. Never retain Data in httpBody.
    if let body {
      request.httpBodyStream = InputStream(data: body)
    }
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
    request.setValue("availkit-swift/0.1.1", forHTTPHeaderField: "User-Agent")
    if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    if let bookingToken {
      request.setValue("Booking " + bookingToken, forHTTPHeaderField: "Authorization")
    }
    if let contactToken {
      request.setValue(contactToken, forHTTPHeaderField: "X-AvailKit-Contact-Token")
    }
    if let idempotencyKey {
      request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
    }
    let mutation = body != nil
    do {
      let (data, response) = try await OneRequest.run(
        request, timeout: timeout, maxBytes: maxResponseBytes)
      let status = response.statusCode
      guard (200..<300).contains(status) else {
        let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let error = value?["error"] as? [String: Any]
        let code =
          (error?["message"] is String ? error?["code"] as? String : nil)
          ?? (value?["type"] as? String == "urn:availkit:problem"
            && value?["status"] as? Int == status ? value?["code"] as? String : nil)
        guard let code else {
          throw AvailKitError(.protocol, "invalid_error", status: status, unknown: mutation)
        }
        throw AvailKitError(
          .api, Schema.safeCode(code), status: status,
          unknown: mutation && (status >= 500 || Schema.safeCode(code) == "api_error"))
      }
      guard status == (operation == "bookPublic" ? 201 : 200),
        response.value(forHTTPHeaderField: "Cache-Control") == "no-store"
      else { throw AvailKitError(.protocol, "invalid_response", status: status, unknown: mutation) }
      try Schema.response(data, schema)
      let value = try JSONDecoder().decode(T.self, from: data)
      if let page = value as? PublicPage {
        guard page.id == pageID else {
          throw AvailKitError(.protocol, "invalid_response", status: status)
        }
      }
      if let booking = value as? PublicBooking {
        guard booking.page.id == pageID, try utc(booking.end) > utc(booking.start) else {
          throw AvailKitError(.protocol, "invalid_response", status: status, unknown: mutation)
        }
      }
      return value
    } catch let error as AvailKitError {
      throw AvailKitError(
        error.kind, error.code, status: error.status,
        unknown: error.mutationOutcomeUnknown || mutation && error.kind != .api)
    } catch {
      throw AvailKitError(
        .transport, Task.isCancelled ? "cancelled" : "request_failed", unknown: mutation)
    }
  }
}
