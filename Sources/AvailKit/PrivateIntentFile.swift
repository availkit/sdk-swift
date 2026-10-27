import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

public enum PrivateFiles {
  /// Exclusively create/fsync a0600 file in an existing owned0700 directory.
  /// Use an app-private, protected directory. Existing/partial files are retained.
  /// No persistence failure admits a network request.
  public static func create(_ data: Data, at url: URL) throws {
    guard !data.isEmpty, data.count <= 131_072 else {
      throw AvailKitError(.input, "private_persistence_failed")
    }
    guard url.isFileURL else { throw AvailKitError(.input, "intent_persistence_failed") }
    let directory = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard directory >= 0 else { throw AvailKitError(.input, "intent_persistence_failed") }
    defer { _ = close(directory) }
    var info = stat()
    guard fstat(directory, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
      info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    else { throw AvailKitError(.input, "intent_persistence_failed") }
    let name = url.lastPathComponent
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
      !name.utf8.contains(0)
    else { throw AvailKitError(.input, "intent_persistence_failed") }
    let file = openat(
      directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
    guard file >= 0 else { throw AvailKitError(.input, "intent_persistence_failed") }
    defer { _ = close(file) }
    #if os(iOS)
      do {
        try FileManager.default.setAttributes(
          [.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
      } catch { throw AvailKitError(.input, "intent_persistence_failed") }
    #endif
    let success = data.withUnsafeBytes { buffer -> Bool in
      var position = 0
      while position < buffer.count {
        let count = write(file, buffer.baseAddress!.advanced(by: position), buffer.count - position)
        if count < 0 && errno == EINTR { continue }
        if count <= 0 { return false }
        position += count
      }
      return fsync(file) == 0 && fsync(directory) == 0
    }
    guard success else { throw AvailKitError(.input, "intent_persistence_failed") }
  }

  /// Bounded, owner-only, no-symlink file read. Import/load never sends.
  public static func read(from url: URL, limit: Int = 131_072) throws -> Data {
    guard (1...131_072).contains(limit) else { throw AvailKitError(.input, "invalid_private_file") }
    guard url.isFileURL else { throw AvailKitError(.input, "invalid_intent_file") }
    let file = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard file >= 0 else { throw AvailKitError(.input, "invalid_intent_file") }
    defer { _ = close(file) }
    var info = stat()
    guard fstat(file, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
      info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size > 0,
      info.st_size <= limit
    else { throw AvailKitError(.input, "invalid_intent_file") }
    var bytes = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = buffer.withUnsafeMutableBytes { pointer in
        #if canImport(Darwin)
          Darwin.read(file, pointer.baseAddress, pointer.count)
        #else
          Glibc.read(file, pointer.baseAddress, pointer.count)
        #endif
      }
      if count < 0 && errno == EINTR { continue }
      guard count >= 0 else { throw AvailKitError(.input, "invalid_intent_file") }
      if count == 0 { break }
      guard bytes.count + count <= limit else {
        throw AvailKitError(.input, "invalid_intent_file")
      }
      bytes.append(contentsOf: buffer.prefix(count))
    }
    return bytes
  }
}

extension BookingIntent {
  public func savePrivate(to url: URL) throws { try PrivateFiles.create(exportPrivate(), at: url) }
  public static func loadPrivate(from url: URL) throws -> BookingIntent {
    try importPrivate(PrivateFiles.read(from: url))
  }
}
