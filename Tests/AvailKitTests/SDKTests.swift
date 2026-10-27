import Foundation
import XCTest

@testable import AvailKit
@testable import FirstBooking

private let fixtureID = String(repeating: "1", count: 32)
private let fixtureToken = String(repeating: "A", count: 43)
private let fixtureStart = "2026-10-26T10:00:00Z"
private final class Fixture {
  let process = Process()
  private let errors = Pipe()
  let directory: URL
  let requests: URL
  let origin: String
  init(_ mode: String = "normal") throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "availkit-swift-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    requests = directory.appendingPathComponent("requests.jsonl")
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
      "python3", Bundle.module.url(forResource: "fixture", withExtension: "py")!.path, mode,
      requests.path,
    ]
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    var port = Data()
    while port.count < 16 {
      let byte = try output.fileHandleForReading.read(upToCount: 1) ?? Data()
      if byte == Data([10]) { break }
      guard !byte.isEmpty else { throw AvailKitError(.input, "fixture_failed") }
      port.append(byte)
    }
    origin = "http://127.0.0.1:" + String(data: port, encoding: .utf8)!
  }
  func records() throws -> [[String: Any]] {
    let data = (try? Data(contentsOf: requests)) ?? Data()
    return try String(data: data, encoding: .utf8)!.split(separator: "\n").map {
      try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
    }
  }
  func close() {
    if process.isRunning {
      process.terminate()
      process.waitUntilExit()
    }
    let diagnostics = errors.fileHandleForReading.readDataToEndOfFile()
    if !diagnostics.isEmpty { FileHandle.standardError.write(diagnostics) }
    try? FileManager.default.removeItem(at: directory)
  }
  deinit { close() }
}
@MainActor
final class SDKTests: XCTestCase {
  private func body() -> PublicBookingInput {
    .init(
      offeringId: fixtureID, start: fixtureStart, contact: .init(displayName: "Synthetic fixture"))
  }
  func testActualPublicLifecycleAllSevenOperations() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    let client = try PublicBookingClient(pageID: fixtureID, baseURL: fixture.origin)
    let page = try await client.getPage()
    XCTAssertEqual(page.id, fixtureID)
    let catalog = try await client.listOfferings()
    XCTAssertEqual(catalog.items.count, 1)
    let slots = try await client.availability(
      offeringID: fixtureID, from: fixtureStart, to: "2026-10-26T11:00:00Z")
    XCTAssertEqual(slots.slots.count, 1)
    let intent = try client.prepareBook(
      body(), idempotencyKey: fixtureToken, bookingToken: fixtureToken, contactToken: fixtureToken)
    XCTAssertFalse(String(describing: intent).contains(fixtureToken))
    let restored = try BookingIntent.importPrivate(intent.exportPrivate())
    let booking = try await client.execute(restored)
    XCTAssertEqual(booking.status, .confirmed)
    let read = try await client.getBooking(bookingID: booking.id, bookingToken: fixtureToken)
    XCTAssertEqual(read.id, booking.id)
    let moved = try await client.reschedule(
      bookingID: booking.id, body: .init(expectedStart: fixtureStart, start: fixtureStart),
      idempotencyKey: fixtureToken, bookingToken: fixtureToken)
    XCTAssertEqual(moved.status, .confirmed)
    let cancelled = try await client.cancel(
      bookingID: booking.id, idempotencyKey: fixtureToken, bookingToken: fixtureToken)
    XCTAssertEqual(cancelled.status, .cancelled)
    let records = try fixture.records()
    XCTAssertEqual(records.count, 7)
    XCTAssertFalse(
      records.contains {
        ($0["headers"] as! [String: String]).keys.contains { $0.lowercased() == "cookie" }
      })
    let headers = records[3]["headers"] as! [String: String]
    XCTAssertTrue(
      headers.contains {
        $0.key.lowercased() == "authorization" && $0.value == "Booking " + fixtureToken
      })
    XCTAssertTrue(
      headers.contains {
        $0.key.lowercased() == "x-availkit-contact-token" && $0.value == fixtureToken
      })
  }
  func testDroppedAcknowledgmentNeverRetriesAndExplicitReplayKeepsBytes() async throws {
    let fixture = try Fixture("lost")
    defer { fixture.close() }
    let client = try PublicBookingClient(pageID: fixtureID, baseURL: fixture.origin)
    let intent = try client.prepareBook(
      body(), idempotencyKey: fixtureToken, bookingToken: fixtureToken, contactToken: fixtureToken)
    do {
      _ = try await client.execute(intent)
      XCTFail("Expected unknown response")
    } catch let error as AvailKitError { XCTAssertTrue(error.mutationOutcomeUnknown) }
    XCTAssertEqual(try fixture.records().count, 1)
    _ = try await client.execute(intent)
    let records = try fixture.records()
    XCTAssertEqual(records.count, 2)
    XCTAssertEqual(records[0]["body"] as? String, records[1]["body"] as? String)
    XCTAssertEqual(records[0]["path"] as? String, records[1]["path"] as? String)
    XCTAssertEqual(
      records[0]["headers"] as? [String: String], records[1]["headers"] as? [String: String])
  }
  func testDeadlineAndCancellationDoNotRetry() async throws {
    let fixture = try Fixture("slow")
    defer { fixture.close() }
    let client = try PublicBookingClient(pageID: fixtureID, baseURL: fixture.origin, timeout: 0.04)
    do {
      _ = try await client.getPage()
      XCTFail("Expected deadline")
    } catch let error as AvailKitError { XCTAssertEqual(error.code, "timeout") }
    XCTAssertEqual(try fixture.records().count, 1)
    let cancellable = try PublicBookingClient(pageID: fixtureID, baseURL: fixture.origin)
    let job = Task { try await cancellable.getPage() }
    try await Task.sleep(nanoseconds: 30_000_000)
    job.cancel()
    do {
      _ = try await job.value
      XCTFail("Expected cancellation")
    } catch let error as AvailKitError { XCTAssertEqual(error.code, "cancelled") }
    XCTAssertEqual(try fixture.records().count, 2)
  }
  func testScopeAgeAndValidationFailBeforeSend() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    let client = try PublicBookingClient(pageID: fixtureID, baseURL: fixture.origin)
    let intent = try client.prepareBook(
      body(), idempotencyKey: fixtureToken, bookingToken: fixtureToken, contactToken: fixtureToken)
    let other = try PublicBookingClient(
      pageID: String(repeating: "2", count: 32), baseURL: fixture.origin)
    do {
      _ = try await other.execute(intent)
      XCTFail("Expected scope check")
    } catch let e as AvailKitError { XCTAssertEqual(e.code, "intent_scope_mismatch") }
    var record = try JSONSerialization.jsonObject(with: intent.exportPrivate()) as! [String: Any]
    record["createdAt"] = -1_000_000_000
    let expired = try BookingIntent.importPrivate(JSONSerialization.data(withJSONObject: record))
    do {
      _ = try await client.execute(expired)
      XCTFail("Expected expiry")
    } catch let e as AvailKitError { XCTAssertEqual(e.code, "intent_expired") }
    XCTAssertThrowsError(
      try client.prepareBook(
        body(), idempotencyKey: "short", bookingToken: fixtureToken, contactToken: fixtureToken))
    XCTAssertThrowsError(try PublicBookingClient(pageID: fixtureID, baseURL: "http://example.com"))
    XCTAssertEqual(try fixture.records().count, 0)
  }
  func testErrorsRedirectDuplicateJSONAndBoundsAreSafe() async throws {
    for mode in ["forbidden", "redirect", "invalid", "oversize"] {
      let fixture = try Fixture(mode)
      defer { fixture.close() }
      let client = try PublicBookingClient(
        pageID: fixtureID, baseURL: fixture.origin, maxResponseBytes: 1024)
      do {
        _ = try await client.book(
          body(), idempotencyKey: fixtureToken, bookingToken: fixtureToken,
          contactToken: fixtureToken)
        XCTFail("Expected fixture rejection")
      } catch let error as AvailKitError {
        XCTAssertFalse(error.description.contains("PRIVATE"))
        if mode == "forbidden" {
          XCTAssertEqual(error.code, "scope_denied")
          XCTAssertFalse(error.mutationOutcomeUnknown)
        } else {
          XCTAssertTrue(error.mutationOutcomeUnknown)
        }
      }
      XCTAssertEqual(try fixture.records().count, 1)
    }
  }
  func testPrivateImportRejectsDuplicateKeys() throws {
    XCTAssertThrowsError(
      try BookingIntent.importPrivate(Data("{\"version\":1,\"version\":1}".utf8)))
    for _ in 0..<20 {
      let token = AvailKitSecrets.newBookingToken()
      XCTAssertEqual(token.count, 43)
      XCTAssertTrue("AEIMQUYcgkosw048".contains(token.last!))
    }
  }
  private func exampleConfig(_ fixture: Fixture) throws -> URL {
    let config: [String: Any] = [
      "pageID": fixtureID, "offeringID": fixtureID,
      "from": fixtureStart, "to": "2026-10-26T12:00:00Z", "displayName": "Fixture",
      "intentDirectory": fixture.directory.path, "baseURL": fixture.origin,
    ]
    let url = fixture.directory.appendingPathComponent("config.json")
    try PrivateFiles.create(JSONSerialization.data(withJSONObject: config), at: url)
    return url
  }
  func testActualExampleLossStopsAndPermanentLatchRefusesRerun() async throws {
    let fixture = try Fixture("example-lost")
    defer { fixture.close() }
    let config = try exampleConfig(fixture)
    do {
      try await FirstBooking.run(configFile: config.path)
      XCTFail("Expected unknown")
    } catch let error as AvailKitError { XCTAssertTrue(error.mutationOutcomeUnknown) }
    let before = try fixture.records().count
    XCTAssertEqual(before, 4)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: fixture.directory.appendingPathComponent("create.json").path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: fixture.directory.appendingPathComponent("move.json").path))
    do {
      try await FirstBooking.run(configFile: config.path)
      XCTFail("Expected permanent latch")
    } catch {}
    XCTAssertEqual(try fixture.records().count, before)
  }
  func testActualExampleSuccessMovesCancelsPersistsAndRefusesRerun() async throws {
    let fixture = try Fixture("example")
    defer { fixture.close() }
    let config = try exampleConfig(fixture)
    try await FirstBooking.run(configFile: config.path)
    XCTAssertEqual(try fixture.records().count, 7)
    for name in [
      "create.json", "move.json", "cancel.json", "completed.json", "lifecycle-started.json",
    ] {
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent(name).path))
    }
    do {
      try await FirstBooking.run(configFile: config.path)
      XCTFail("Expected permanent latch")
    } catch {}
    XCTAssertEqual(try fixture.records().count, 7)
  }
  func testPrivateFilesAreExclusiveBoundedOwnerOnlyAndNoSymlink() throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    let path = fixture.directory.appendingPathComponent("private.json")
    try PrivateFiles.create(Data("{}".utf8), at: path)
    XCTAssertThrowsError(try PrivateFiles.create(Data("{}".utf8), at: path))
    XCTAssertThrowsError(try PrivateFiles.read(from: path, limit: 1))
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
    XCTAssertThrowsError(try PrivateFiles.read(from: path))
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    let link = fixture.directory.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path)
    XCTAssertThrowsError(try PrivateFiles.read(from: link))
  }

  func testUnknownErrorCodeAndMalformedErrorEnvelopeKeepMutationUnknown() async throws {
    for mode in ["unknowncode", "baderror"] {
      let fixture = try Fixture(mode)
      defer { fixture.close() }
      let client = try PublicBookingClient(pageID: fixtureID, baseURL: fixture.origin)
      do {
        _ = try await client.book(
          body(), idempotencyKey: fixtureToken, bookingToken: fixtureToken,
          contactToken: fixtureToken)
        XCTFail("Expected rejected acknowledgment")
      } catch let error as AvailKitError {
        XCTAssertTrue(error.mutationOutcomeUnknown)
        XCTAssertEqual(error.code, mode == "unknowncode" ? "api_error" : "invalid_error")
        XCTAssertFalse(error.description.contains("PRIVATE"))
      }
      XCTAssertEqual(try fixture.records().count, 1)
    }
  }
  func testForgedImportedBodiesPathsAndFutureTimestampsCannotSend() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    let client = try PublicBookingClient(pageID: fixtureID, baseURL: fixture.origin)
    let original = try client.prepareCancel(
      bookingID: fixtureID, idempotencyKey: fixtureToken, bookingToken: fixtureToken)
    let record = try JSONSerialization.jsonObject(with: original.exportPrivate()) as! [String: Any]
    for alteration in ["duplicate", "oversize", "path", "future"] {
      var value = record
      switch alteration {
      case "duplicate": value["body"] = Data("{\"x\":1,\"x\":2}".utf8).base64EncodedString()
      case "oversize":
        value["body"] = Data((String(repeating: " ", count: 16_385) + "{}").utf8)
          .base64EncodedString()
      case "path": value["path"] = "//bookings//" + fixtureID + "//cancel//"
      default: value["createdAt"] = Date().timeIntervalSinceReferenceDate + 4
      }
      let imported = try BookingIntent.importPrivate(JSONSerialization.data(withJSONObject: value))
      do {
        _ = try await client.execute(imported)
        XCTFail("Expected imported intent guard")
      } catch {}
    }
    XCTAssertEqual(try fixture.records().count, 0)
  }

}
