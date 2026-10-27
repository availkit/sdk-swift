import AvailKit
import Foundation

// Complete opt-in public test lifecycle. No workspace credential/native login.
struct Config: Decodable {
  let pageID: String
  let offeringID: String
  let from: String
  let to: String
  let displayName: String
  let email: String?
  let phone: String?
  let intentDirectory: String
  let baseURL: String?
}
@main struct FirstBooking {
  static func main() async {
    do { try await run() } catch let error as AvailKitError {
      FileHandle.standardError.write(Data((error.description + "\n").utf8))
      exit(1)
    } catch {
      FileHandle.standardError.write(
        Data(
          "Example configuration or private persistence failed. Inspect the retained intent before any further action.\n"
            .utf8))
      exit(1)
    }
  }
  static func run() async throws {
    guard let path = ProcessInfo.processInfo.environment["AVAILKIT_CONFIG_FILE"] else {
      throw CocoaError(.fileReadNoSuchFile)
    }
    try await run(configFile: path)
  }
  static func run(configFile path: String) async throws {
    // docs:configuration:start
    let config = try JSONDecoder().decode(
      Config.self, from: PrivateFiles.read(from: URL(fileURLWithPath: path), limit: 16_384))
    let client = try PublicBookingClient(
      pageID: config.pageID, baseURL: config.baseURL ?? "https://api.availkit.com")
    let directory = URL(fileURLWithPath: config.intentDirectory, isDirectory: true)
    // Every run is a deliberate one-time fixture. Keep the latch after ANY result.
    // On rerun this exclusive durable write fails before any network request.
    try PrivateFiles.create(
      Data("{\"version\":1,\"state\":\"started\"}".utf8),
      at: directory.appendingPathComponent("lifecycle-started.json"))
    // docs:configuration:end
    // docs:lifecycle:start
    let page = try await client.getPage()
    guard page.environment == .test else { throw CocoaError(.featureUnsupported) }
    var cursor: String?
    var found = false
    for _ in 0..<100 {
      let catalog = try await client.listOfferings(after: cursor)
      if catalog.items.contains(where: { $0.id == config.offeringID }) {
        found = true
        break
      }
      guard let next = catalog.nextAfter else { break }
      cursor = next
    }
    guard found else { throw CocoaError(.fileNoSuchFile) }
    let times = try await client.availability(
      offeringID: config.offeringID, from: config.from, to: config.to)
    guard times.slots.count >= 2 else { throw CocoaError(.fileNoSuchFile) }
    let first = times.slots[0]
    let second = times.slots[1]
    let bookingToken = AvailKitSecrets.newBookingToken()
    let contactToken = AvailKitSecrets.newBookingToken()
    let body = PublicBookingInput(
      offeringId: config.offeringID, start: first.start,
      contact: .init(displayName: config.displayName, email: config.email, phone: config.phone))
    let intent = try client.prepareBook(
      body, idempotencyKey: AvailKitSecrets.newIdempotencyKey(), bookingToken: bookingToken,
      contactToken: contactToken)
    try retain(
      intent, at: directory.appendingPathComponent("create.json"))
    let booking = try await client.execute(intent)
    _ = try await client.getBooking(bookingID: booking.id, bookingToken: bookingToken)
    let move = try client.prepareReschedule(
      bookingID: booking.id,
      body: .init(expectedStart: booking.start, start: second.start),
      idempotencyKey: AvailKitSecrets.newIdempotencyKey(), bookingToken: bookingToken)
    try retain(move, at: directory.appendingPathComponent("move.json"))
    let moved = try await client.execute(move)
    let cancel = try client.prepareCancel(
      bookingID: moved.id, idempotencyKey: AvailKitSecrets.newIdempotencyKey(),
      bookingToken: bookingToken)
    try retain(
      cancel, at: directory.appendingPathComponent("cancel.json"))
    _ = try await client.execute(cancel)
    try PrivateFiles.create(
      Data("{\"version\":1,\"state\":\"completed\"}".utf8),
      at: directory.appendingPathComponent("completed.json"))
    // docs:lifecycle:end
    print("Test booking created, read, moved and cancelled. Private intents retained.")
  }
  static func retain(_ intent: BookingIntent, at url: URL) throws {
    try intent.savePrivate(to: url)
  }
}
