import Foundation
// Shared host/monitor helper; only the host publishes aliases.
enum GuardianTokenRecovery {
  enum Failure: Error { case cycle, cardinality, invalidToken, unavailableContainer }
  private static let publicationLock = NSLock()
  static func resolve(_ token: String, aliases: [String: String]) throws -> String {
    var current = token
    var seen = Set<String>()
    while let next = aliases[current], next != current {
      guard seen.insert(current).inserted else { throw Failure.cycle }
      current = next
    }
    return current
  }
  // Stage singleton results: no array-order assumption or partial publication on failure.
  static func stage(_ tokens: [String], aliases: [String: String],
                    refresh: (String) throws -> [String]) throws -> [String: String] {
    var staged = aliases
    var refreshed = Set<String>()
    for original in tokens {
      let current = try resolve(original, aliases: staged)
      guard refreshed.insert(current).inserted else { continue }
      let result = try refresh(current)
      guard result.count == 1, let replacement = result.first, !replacement.isEmpty else {
        throw Failure.cardinality
      }
      if replacement != current { staged[current] = replacement }
      refreshed.insert(replacement)
    }
    for key in Array(staged.keys) {
      let canonical = try resolve(key, aliases: staged)
      if canonical == key { staged.removeValue(forKey: key) }
      else { staged[key] = canonical }
    }
    return staged
  }
  static func read(_ url: URL) throws -> [String: String] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
    return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
  }
  static func publish(_ aliases: [String: String], to url: URL) throws {
    try JSONEncoder().encode(aliases).write(to: url, options: .atomic)
  }
}
#if os(iOS)
import ManagedSettings
extension GuardianTokenRecovery {
  static var supported: Bool {
    if #available(iOS 26.5, *) { return true }
    return false
  }
  static func location(group: String) throws -> URL {
    guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
      throw Failure.unavailableContainer
    }
    return container.appendingPathComponent("guardianTokenAliases.v1.json")
  }
  static func decode(_ encoded: String, group: String) -> ApplicationToken? {
    // Decode fallback preserves targeted/full distinction; enforcement rejects unreadable aliases.
    let canonical = (try? resolve(encoded, aliases: read(location(group: group)))) ?? encoded
    guard let data = Data(base64Encoded: canonical) else { return nil }
    return try? JSONDecoder().decode(ApplicationToken.self, from: data)
  }
  static func refresh(_ tokens: [String], group: String, persist: Bool) throws -> [String: String] {
    // No refresh calls another refresh; the complete read/modify/publish owns this lock once.
    publicationLock.lock()
    defer { publicationLock.unlock() }
    guard supported else { return [:] }
    let url = try location(group: group)
    let previous = try read(url)
    let staged = try stage(tokens, aliases: previous) { encoded in
      guard let data = Data(base64Encoded: encoded),
            let token = try? JSONDecoder().decode(ApplicationToken.self, from: data) else {
        throw Failure.invalidToken
      }
      var values = [token]
      if #available(iOS 26.5, *) { try ManagedSettingsStore.refresh(&values) }
      return try values.map { try JSONEncoder().encode($0).base64EncodedString() }
    }
    if persist && previous != staged { try publish(staged, to: url) }
    return staged
  }
  static func exceptions(_ encoded: [String], exempt: ApplicationToken?, group: String,
                         persist: Bool, refreshRequired: Bool = true) throws -> Set<ApplicationToken> {
    // Never let a ticket turn an intentionally empty allowed set into block-all-except-one.
    guard !encoded.isEmpty else { return [] }
    var inputs = encoded
    if let exempt { inputs.append(try JSONEncoder().encode(exempt).base64EncodedString()) }
    let aliases = try refreshRequired ? refresh(inputs, group: group, persist: persist) : read(location(group: group))
    let decoded = try inputs.map { original -> ApplicationToken in
      let canonical = try resolve(original, aliases: aliases)
      guard let data = Data(base64Encoded: canonical),
            let token = try? JSONDecoder().decode(ApplicationToken.self, from: data) else {
        throw Failure.invalidToken
      }
      return token
    }
    return Set(decoded)
  }
}
#endif
