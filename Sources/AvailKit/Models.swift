import Foundation

// Typed stable public-booking wire models. No workspace credential or account API.
public struct AvailabilitySlotsItem: Codable, Sendable, Equatable {
  public let start: String
  public let end: String
  public let remainingCapacity: Int
  public init(start: String, end: String, remainingCapacity: Int) {
    self.start = start
    self.end = end
    self.remainingCapacity = remainingCapacity
  }
}
public struct Availability: Codable, Sendable, Equatable {
  public let slots: [AvailabilitySlotsItem]
  public init(slots: [AvailabilitySlotsItem]) { self.slots = slots }
}
public struct RescheduleInput: Codable, Sendable, Equatable {
  public let expectedStart: String
  public let start: String
  public init(expectedStart: String, start: String) {
    self.expectedStart = expectedStart
    self.start = start
  }
}
public struct CustomerInput: Codable, Sendable, Equatable {
  public let displayName: String
  public let email: String?
  public let phone: String?
  public init(displayName: String, email: String? = nil, phone: String? = nil) {
    self.displayName = displayName
    self.email = email
    self.phone = phone
  }
}
public struct Empty: Codable, Sendable, Equatable {
  public init() {}
}
public enum PublicPageEnvironment: String, Codable, Sendable {
  case test = "test"
  case live = "live"
}
public struct PublicPage: Codable, Sendable, Equatable {
  public let id: String
  public let title: String
  public let environment: PublicPageEnvironment
  public let emailNotifications: Bool?
  public init(
    id: String, title: String, environment: PublicPageEnvironment, emailNotifications: Bool? = nil
  ) {
    self.id = id
    self.title = title
    self.environment = environment
    self.emailNotifications = emailNotifications
  }
}
public struct PublicOfferingPage: Codable, Sendable, Equatable {
  public let items: [PublicOffering]
  public let nextAfter: String?
  public init(items: [PublicOffering], nextAfter: String?) {
    self.items = items
    self.nextAfter = nextAfter
  }
}
public struct PublicOffering: Codable, Sendable, Equatable {
  public let id: String
  public let name: String
  public let durationMinutes: Int
  public let timeZone: String
  public init(id: String, name: String, durationMinutes: Int, timeZone: String) {
    self.id = id
    self.name = name
    self.durationMinutes = durationMinutes
    self.timeZone = timeZone
  }
}
public struct PublicBookingInput: Codable, Sendable, Equatable {
  public let offeringId: String
  public let start: String
  public let contact: CustomerInput
  public init(offeringId: String, start: String, contact: CustomerInput) {
    self.offeringId = offeringId
    self.start = start
    self.contact = contact
  }
}
public enum PublicBookingStatus: String, Codable, Sendable {
  case confirmed = "confirmed"
  case cancelled = "cancelled"
}
public struct PublicBooking: Codable, Sendable, Equatable {
  public let id: String
  public let start: String
  public let end: String
  public let status: PublicBookingStatus
  public let offering: PublicOffering
  public let page: PublicPage
  public let pageEnabled: Bool
  public init(
    id: String, start: String, end: String, status: PublicBookingStatus, offering: PublicOffering,
    page: PublicPage, pageEnabled: Bool
  ) {
    self.id = id
    self.start = start
    self.end = end
    self.status = status
    self.offering = offering
    self.page = page
    self.pageEnabled = pageEnabled
  }
}

extension CustomerInput: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String { "AvailKit CustomerInput (private)" }
  public var debugDescription: String { description }
}
