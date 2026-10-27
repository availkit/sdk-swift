import CoreFoundation
import Foundation

enum Schema {
  // Resource bytes are immutable and parsed within a call: no mutable global Any.
  static func schemas() throws -> [String: Any] {
    guard let url = Bundle.module.url(forResource: "schemas", withExtension: "json"),
      let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    else { throw AvailKitError(.protocol, "schema_unavailable") }
    return value
  }
  static func response(_ data: Data, _ name: String) throws {
    let all = try schemas()
    let value = try JSONSerialization.jsonObject(with: data)
    guard let spec = all[name] as? [String: Any], validate(value, spec, all) else {
      throw AvailKitError(.protocol, "invalid_response")
    }
  }
  static func input(_ data: Data, _ name: String) throws {
    guard data.count <= 16_384 else { throw AvailKitError(.input, "body_too_large") }
    do {
      try StrictJSON.check(data)
      let all = try schemas()
      let value = try JSONSerialization.jsonObject(with: data)
      guard let spec = all[name] as? [String: Any], validate(value, spec, all),
        let object = value as? [String: Any]
      else { throw AvailKitError(.input, "invalid_input") }
      if name == "PublicBookingInput" {
        guard
          (object["offeringId"] as? String)?.range(
            of: "^[0-9a-f]{32}$", options: .regularExpression) != nil
        else { throw AvailKitError(.input, "invalid_id") }
        let contact = try JSONSerialization.data(withJSONObject: object["contact"]!)
        try input(contact, "CustomerInput")
      }
      if name == "CustomerInput" {
        func text(_ s: String, _ max: Int) -> Bool {
          !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && s.count <= max
            && !s.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        guard let display = object["displayName"] as? String, text(display, 160) else {
          throw AvailKitError(.input, "invalid_customer")
        }
        if let email = object["email"] as? String {
          guard text(email, 254),
            email.range(of: #"^[^@\s]+@[^@\s]+$"#, options: .regularExpression) != nil
          else { throw AvailKitError(.input, "invalid_customer") }
        }
        if let phone = object["phone"] as? String {
          guard text(phone, 32) else { throw AvailKitError(.input, "invalid_customer") }
        }
      }
    } catch let error as AvailKitError { throw error } catch {
      throw AvailKitError(.input, "invalid_input")
    }
  }
  private static func validate(
    _ value: Any, _ s: [String: Any], _ all: [String: Any], _ depth: Int = 0
  ) -> Bool {
    guard depth <= 20 else { return false }
    if let ref = s["$ref"] as? String {
      guard let spec = all[String(ref.split(separator: "/").last!)] as? [String: Any] else {
        return false
      }
      return validate(value, spec, all, depth + 1)
    }
    for key in ["anyOf", "allOf", "oneOf"] {
      if let specs = s[key] as? [[String: Any]] {
        let n = specs.filter { validate(value, $0, all, depth + 1) }.count
        if key == "allOf" && n != specs.count || key != "allOf" && n == 0
          || key == "oneOf" && n != 1
        {
          return false
        }
      }
    }
    func same(_ a: Any, _ b: Any) -> Bool { (a as? NSObject)?.isEqual(b) == true }
    if let values = s["enum"] as? [Any], !values.contains(where: { same(value, $0) }) {
      return false
    }
    if let constant = s["const"], !same(value, constant) { return false }
    let types = (s["type"] as? [String]) ?? (s["type"] as? String).map { [$0] } ?? []
    if !types.isEmpty {
      let ok = types.contains { type in
        switch type {
        case "null": return value is NSNull
        case "string": return value is String
        case "object": return value is [String: Any]
        case "array": return value is [Any]
        case "boolean":
          return (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
        case "integer":
          return (value as? NSNumber).map {
            CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.rounded() == $0.doubleValue
          } ?? false
        default: return false
        }
      }
      if !ok { return false }
    }
    if let object = value as? [String: Any] {
      let properties = s["properties"] as? [String: [String: Any]] ?? [:]
      if let required = s["required"] as? [String], required.contains(where: { object[$0] == nil })
      {
        return false
      }
      for (key, item) in object {
        if let property = properties[key] {
          if !validate(item, property, all, depth + 1) { return false }
        } else if s["additionalProperties"] as? Bool == false {
          return false
        }
      }
    }
    if let array = value as? [Any] {
      if array.count < (s["minItems"] as? Int ?? 0)
        || array.count > (s["maxItems"] as? Int ?? 10_000)
      {
        return false
      }
      if let item = s["items"] as? [String: Any],
        array.contains(where: { !validate($0, item, all, depth + 1) })
      {
        return false
      }
    }
    if let string = value as? String {
      if string.count < (s["minLength"] as? Int ?? 0)
        || string.count > (s["maxLength"] as? Int ?? 8192)
      {
        return false
      }
      if let pattern = s["pattern"] as? String,
        string.range(of: pattern, options: .regularExpression) == nil
      {
        return false
      }
      if s["format"] as? String == "date-time", (try? utc(string)) == nil { return false }
    }
    if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
      if number.doubleValue < (s["minimum"] as? Double ?? -9_007_199_254_740_991)
        || number.doubleValue > (s["maximum"] as? Double ?? 9_007_199_254_740_991)
      {
        return false
      }
    }
    return true
  }
  static func safeCode(_ code: String) -> String {
    let codes =
      "booking_page_paused booking_access_in_use contact_changed validation_failed synthetic_email_required unauthorized forbidden scope_denied not_found invalid_input invalid_query invalid_cursor invalid_limit quota_exceeded unavailable credential_invalid capability_denied customer_archived idempotency_conflict capacity_conflict capacity_exceeded version_conflict catalog_in_use catalog_archived event_cursor_expired invalid_id invalid_range identity_unavailable recovery_unavailable csrf_invalid recent_auth_required secret_already_revealed idempotency_mismatch membership_changed membership_denied last_credential identity_limit identity_rate_limited membership_conflict request_key_invalid"
      .split(separator: " ")
    return codes.contains(Substring(code)) ? code : "api_error"
  }
}

/// A bounded syntax walk rejects duplicate keys before Foundation decodes JSON.
enum StrictJSON {
  static func check(_ data: Data) throws {
    var parser = Parser(bytes: Array(data))
    try parser.value(0)
    parser.space()
    guard parser.index == parser.bytes.count else { throw AvailKitError(.protocol, "invalid_json") }
    _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
  }
  private struct Parser {
    let bytes: [UInt8]
    var index = 0
    mutating func space() {
      while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }
    mutating func take(_ byte: UInt8) throws {
      space()
      guard index < bytes.count, bytes[index] == byte else {
        throw AvailKitError(.protocol, "invalid_json")
      }
      index += 1
    }
    mutating func string() throws -> String {
      space()
      let start = index
      try take(34)
      while index < bytes.count {
        let byte = bytes[index]
        index += 1
        if byte == 34 {
          let raw = Data(bytes[start..<index])
          let wrapped = Data([91]) + raw + Data([93])
          guard let result = try JSONSerialization.jsonObject(with: wrapped) as? [String] else {
            throw AvailKitError(.protocol, "invalid_json")
          }
          return result[0]
        }
        if byte == 92 {
          guard index < bytes.count else { throw AvailKitError(.protocol, "invalid_json") }
          index += 1
        }
      }
      throw AvailKitError(.protocol, "invalid_json")
    }
    mutating func value(_ depth: Int) throws {
      space()
      guard depth <= 20, index < bytes.count else { throw AvailKitError(.protocol, "invalid_json") }
      if bytes[index] == 123 {
        try take(123)
        space()
        if index < bytes.count && bytes[index] == 125 {
          index += 1
          return
        }
        var keys = Set<String>()
        while true {
          let key = try string()
          guard keys.insert(key).inserted else { throw AvailKitError(.protocol, "invalid_json") }
          try take(58)
          try value(depth + 1)
          space()
          guard index < bytes.count else { throw AvailKitError(.protocol, "invalid_json") }
          if bytes[index] == 125 {
            index += 1
            return
          }
          try take(44)
        }
      }
      if bytes[index] == 91 {
        try take(91)
        space()
        if index < bytes.count && bytes[index] == 93 {
          index += 1
          return
        }
        while true {
          try value(depth + 1)
          space()
          guard index < bytes.count else { throw AvailKitError(.protocol, "invalid_json") }
          if bytes[index] == 93 {
            index += 1
            return
          }
          try take(44)
        }
      }
      if bytes[index] == 34 {
        _ = try string()
        return
      }
      let start = index
      while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) {
        index += 1
      }
      guard index > start else { throw AvailKitError(.protocol, "invalid_json") }
    }
  }
}
