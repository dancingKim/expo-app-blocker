import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct GuardianKeyApplyFailure: Error {}

enum GuardianKeyFailure: String, Error {
  case invalid = "ERR_GUARDIAN_KEY_INVALID"
  case conflict = "ERR_GUARDIAN_KEY_CONFLICT"
  case closed = "ERR_GUARDIAN_KEY_CLOSED"
}

struct GuardianScopedKey: Equatable {
  let id: String
  let scope: GuardianOpeningScope
  let startedAtMillis: Double
  let untilMillis: Double
  var closed: Bool
  init(_ raw: [String: Any]) throws {
    guard let id = raw["id"] as? String, !id.isEmpty, id.count <= 200,
          let scope = raw["scope"] as? [String: Any],
          let start = (raw["startedAtMillis"] as? NSNumber)?.doubleValue,
          let end = (raw["untilMillis"] as? NSNumber)?.doubleValue,
          start.isFinite, end.isFinite, start.rounded() == start, end.rounded() == end, start >= 0, end > start, end < Double(Int64.max) else { throw GuardianKeyFailure.invalid }
    guard raw["closed"] == nil || raw["closed"] is Bool else { throw GuardianKeyFailure.invalid }
    self.id = id; self.scope = try GuardianOpeningScope(scope)
    startedAtMillis = start; untilMillis = end; closed = raw["closed"] as? Bool ?? false
  }
  var dictionary: [String: Any] {
    ["id": id, "scope": scope.dictionary, "startedAtMillis": startedAtMillis,
     "untilMillis": untilMillis]
  }
  var persisted: [String: Any] { dictionary.merging(["closed": closed]) { _, new in new } }
  func live(_ now: Double) -> Bool { !closed && startedAtMillis <= now && untilMillis > now }
  func sameContent(_ other: Self) -> Bool {
    id == other.id && scope == other.scope && startedAtMillis == other.startedAtMillis && untilMillis == other.untilMillis
  }
}

struct GuardianKeyRegistry {
  var keys: [GuardianScopedKey]
  init(_ raw: [[String: Any]] = []) throws {
    keys = try raw.map(GuardianScopedKey.init)
    guard Set(keys.map(\.id)).count == keys.count else { throw GuardianKeyFailure.invalid }
  }
  func live(_ now: Double) -> [GuardianScopedKey] {
    keys.filter { $0.live(now) }.sorted { ($0.untilMillis, $0.id) < ($1.untilMillis, $1.id) }
  }
  func snapshot(_ now: Double) -> [String: Any] {
    let active = live(now)
    return ["keys": active.map(\.dictionary), "nextExpiryMillis": active.first?.untilMillis ?? 0]
  }
  func adding(_ key: GuardianScopedKey, now: Double) throws -> Self {
    if let previous = keys.first(where: { $0.id == key.id }) {
      guard previous.sameContent(key) else { throw GuardianKeyFailure.conflict }
      guard !previous.closed else { throw GuardianKeyFailure.closed }
      guard previous.live(now) else { throw GuardianKeyFailure.invalid }
      return self
    }
    guard !key.closed, key.live(now) else { throw GuardianKeyFailure.invalid }
    var next = self
    next.keys.removeAll { $0.untilMillis <= now }
    next.keys.append(key)
    return next
  }
  func closing(_ id: String) -> Self {
    var next = self
    if let index = next.keys.firstIndex(where: { $0.id == id }) { next.keys[index].closed = true }
    return next
  }
  /// Check every expiry and the independent early close of all masking keys.
  func validateCapacity<T: Hashable>(allowed: Set<T>, decode: (String) throws -> T, now: Double) throws {
    let active = live(now)
    for boundary in Set([now] + active.map(\.untilMillis)) {
      let remaining = active.filter { $0.untilMillis > boundary }
      // Full/allow-layer can close early: they must not hide an unrepresentable exception set.
      let opened = try Set(remaining.flatMap { $0.scope.apps }.map(decode))
      if !allowed.isEmpty && allowed.union(opened).count > 50 { throw GuardianKeyFailure.invalid }
    }
  }
}

/// The same file lock protects host and Monitor read/render/rearm. Recursive on one thread.
final class GuardianKeyFileLock {
  private static let processLock = NSRecursiveLock()
  private let path: String
  private let fd: Int32?
  private var released = false
  init(directory: URL) throws {
    Self.processLock.lock()
    path = directory.appendingPathComponent("guardian-keys.lock").path
    let nestingKey = "guardian-key-lock:" + path
    let depth = Thread.current.threadDictionary[nestingKey] as? Int ?? 0
    if depth > 0 {
      fd = nil
    } else {
      let descriptor = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
      guard descriptor >= 0 else { Self.processLock.unlock(); throw GuardianKeyFailure.invalid }
      guard flock(descriptor, LOCK_EX) == 0 else {
        close(descriptor); Self.processLock.unlock(); throw GuardianKeyFailure.invalid
      }
      fd = descriptor
    }
    Thread.current.threadDictionary[nestingKey] = depth + 1
  }
  func unlock() {
    guard !released else { return }; released = true
    let key = "guardian-key-lock:" + path
    let depth = (Thread.current.threadDictionary[key] as? Int ?? 1) - 1
    if depth == 0 { Thread.current.threadDictionary.removeObject(forKey: key) }
    else { Thread.current.threadDictionary[key] = depth }
    if let fd { _ = flock(fd, LOCK_UN); close(fd) }
    Self.processLock.unlock()
  }
  deinit { unlock() }
}

#if os(iOS)
import DeviceActivity

enum GuardianConcurrentStorage {
  static let key = "appBlocker.concurrentKeys.v1"
  static let activity = "appBlocker.suppressionExpiry"
  static func directory(_ group: String) throws -> URL {
    guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { throw GuardianKeyFailure.invalid }
    return url
  }
  static func lock(_ group: String) throws -> GuardianKeyFileLock { try GuardianKeyFileLock(directory: directory(group)) }
  static func read(_ defaults: UserDefaults, group: String) throws -> GuardianKeyRegistry? {
    let url = try directory(group).appendingPathComponent("guardian-keys.v1.json")
    guard FileManager.default.fileExists(atPath: url.path) else {
      defaults.removeObject(forKey: key); return nil
    }
    guard let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]] else { throw GuardianKeyFailure.invalid }
    let registry = try GuardianKeyRegistry(raw)
    let legacyEnd = (defaults.object(forKey: GuardianTargetRuntime.untilKey) as? NSNumber)?.doubleValue ?? 0
    if legacyEnd > Date().timeIntervalSince1970 * 1000 && registry.live(Date().timeIntervalSince1970 * 1000).isEmpty {
      defaults.removeObject(forKey: key)
    } else { defaults.set(raw, forKey: key) }
    return registry
  }
  static func write(_ registry: GuardianKeyRegistry, defaults: UserDefaults, group: String) throws {
    let raw = registry.keys.map(\.persisted)
    try JSONSerialization.data(withJSONObject: raw).write(to: directory(group).appendingPathComponent("guardian-keys.v1.json"), options: .atomic)
    defaults.set(raw, forKey: key)
  }
  static func load(_ defaults: UserDefaults, group: String, now: Double, persistMigration: Bool = true) throws -> GuardianKeyRegistry {
    var registry = try read(defaults, group: group) ?? GuardianKeyRegistry()
    // Import the old single opening once, preserving its exact scope and deadline.
    let legacyEnd: Double
    if defaults.object(forKey: GuardianTargetRuntime.scopeKey) != nil {
      guard let raw = defaults.dictionary(forKey: GuardianTargetRuntime.scopeKey),
            let end = (raw["untilMillis"] as? NSNumber)?.doubleValue else { throw GuardianKeyFailure.invalid }
      legacyEnd = end
    } else { legacyEnd = (defaults.object(forKey: GuardianTargetRuntime.untilKey) as? NSNumber)?.doubleValue ?? 0 }
    if legacyEnd > now {
      guard legacyEnd.isFinite, legacyEnd < Double(Int64.max), legacyEnd.rounded() == legacyEnd else { throw GuardianKeyFailure.invalid }
      let scope: [String: Any]
      if let raw = defaults.dictionary(forKey: GuardianTargetRuntime.scopeKey) { scope = try GuardianOpeningScope(raw).dictionary }
      else if let target = defaults.string(forKey: GuardianTargetRuntime.legacyTargetKey) {
        scope = ["policy": "targets-v1", "kind": "targets", "apps": [target], "webDomains": [String]()]
      } else { scope = ["policy": "targets-v1", "kind": "full"] }
      let imported = try GuardianScopedKey(["id": "legacy-\(Int64(legacyEnd))", "scope": scope,
        "startedAtMillis": 0.0, "untilMillis": legacyEnd])
      if !registry.keys.contains(where: { $0.id == imported.id }) { registry.keys.append(imported) }
      if persistMigration {
      try write(registry, defaults: defaults, group: group)
      defaults.removeObject(forKey: GuardianTargetRuntime.untilKey)
      defaults.removeObject(forKey: GuardianTargetRuntime.scopeKey)
      defaults.removeObject(forKey: GuardianTargetRuntime.legacyTargetKey)
      }
    }
    return registry
  }
  static func mirrored(_ defaults: UserDefaults) -> GuardianKeyRegistry? {
    guard defaults.object(forKey: key) != nil else { return nil }
    // A malformed explicit registry means no openings, never the legacy full fallback.
    return (try? GuardianKeyRegistry(defaults.array(forKey: key) as? [[String: Any]] ?? [])) ?? (try! GuardianKeyRegistry())
  }
  static func rearm(_ registry: GuardianKeyRegistry, now: Double) throws {
    let center = DeviceActivityCenter()
    let name = DeviceActivityName(activity)
    guard let next = registry.live(now).first?.untilMillis else { center.stopMonitoring([name]); return }
    let start = Date(timeIntervalSince1970: ceil(next / 60000) * 60)
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    func components(_ date: Date) -> DateComponents {
      var value = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
      value.calendar = calendar; value.timeZone = calendar.timeZone; return value
    }
    // Replaces the same name; do not cancel a good alarm before registration succeeds.
    try center.startMonitoring(name, during: DeviceActivitySchedule(intervalStart: components(start),
      intervalEnd: components(start.addingTimeInterval(86400)), repeats: false), events: [:])
  }
}
#endif
