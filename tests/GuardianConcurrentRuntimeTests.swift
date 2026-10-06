import Foundation

// Only OS I/O and framework types are substituted. Production storage, commit and expiry
// bodies are compiled by the runner; no second implementation of the state transition.
typealias ApplicationToken = String
typealias WebDomainToken = String
enum TestFailure: Error { case render, alarm }
enum GuardianTargetRuntime {
  static let untilKey = "oldUntil", scopeKey = "oldScope", legacyTargetKey = "oldTarget"
  static func app(_ token: String, group: String) throws -> String { token }
  static func web(_ token: String) throws -> String { token }
  // PRODUCTION_AGGREGATE
}
struct DeviceActivityName: Equatable { let value: String; init(_ value: String) { self.value = value } }
struct DeviceActivitySchedule { let intervalStart: DateComponents; let intervalEnd: DateComponents; let repeats: Bool }
final class DeviceActivityCenter {
  static var next: Date?, failOnce = false
  func stopMonitoring(_ names: [DeviceActivityName]) { Self.next = nil }
  func startMonitoring(_ name: DeviceActivityName, during schedule: DeviceActivitySchedule, events: [String: String]) throws {
    if Self.failOnce { Self.failOnce = false; throw TestFailure.alarm }
    Self.next = schedule.intervalStart.date
  }
}
// PRODUCTION_STORAGE
final class Host {
  let sharedDefaults: UserDefaults?
  let userDefaults: UserDefaults
  let appGroupIdentifier: String
  var rendered: [String] = [], failOnce = false
  init(_ defaults: UserDefaults, _ directory: URL) { sharedDefaults = defaults; userDefaults = defaults; appGroupIdentifier = directory.path }
  func reapplyPersistedLayers() throws {
    if failOnce { failOnce = false; throw TestFailure.render }
    let registry = try GuardianConcurrentStorage.read(userDefaults, group: appGroupIdentifier)!
    rendered = registry.live(Date().timeIntervalSince1970 * 1000).map(\.id)
  }
  // PRODUCTION_COMMIT
}
final class Monitor {
  let sharedDefaults: UserDefaults?
  let appGroupIdentifier: String
  let suppressionUntilKey = GuardianTargetRuntime.untilKey
  let suppressionTargetTokenKey = GuardianTargetRuntime.legacyTargetKey
  var rendered: [String] = []
  init(_ defaults: UserDefaults, _ directory: URL) { sharedDefaults = defaults; appGroupIdentifier = directory.path }
  func recomputeShieldsAfterSuppression() {
    rendered = GuardianConcurrentStorage.mirrored(sharedDefaults!)!.live(Date().timeIntervalSince1970 * 1000).map(\.id)
  }
  func writeSuppressionExpiryProbe(decision: String) {}
  // PRODUCTION_EXPIRY
}
@main struct GuardianConcurrentRuntimeTests {
  static func main() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:directory, withIntermediateDirectories:true)
    let suite = "guardian-concurrent-runtime-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { try? FileManager.default.removeItem(at:directory); defaults.removePersistentDomain(forName:suite) }
    let now = Date().timeIntervalSince1970 * 1000
    let start = floor(now - 2000), end = floor(now + 120000)
    func key(_ id: String, _ until: Double) throws -> GuardianScopedKey {
      try GuardianScopedKey(["id":id, "scope":["policy":"targets-v1", "kind":"targets", "apps":[id], "webDomains":[String]()], "startedAtMillis":start, "untilMillis":until])
    }
    let empty = try GuardianKeyRegistry(), a = try key("a", end), b = try key("b", end + 60000)
    let first = try empty.adding(a, now:now), both = try first.adding(b, now:now)
    let host = Host(defaults,directory), monitor = Monitor(defaults,directory)
    try host.commitGuardianKeys(first, previous:empty)
    precondition(host.rendered == ["a"] && DeviceActivityCenter.next != nil)
    host.failOnce = true
    do { try host.commitGuardianKeys(both, previous:first); fatalError("Render failure accepted") } catch is GuardianKeyApplyFailure {}
    precondition(host.rendered == ["a"] && (try! GuardianConcurrentStorage.read(defaults,group:directory.path))!.keys == first.keys)
    DeviceActivityCenter.failOnce = true
    do { try host.commitGuardianKeys(both, previous:first); fatalError("Alarm failure accepted") } catch is GuardianKeyApplyFailure {}
    precondition(host.rendered == ["a"] && (try! GuardianConcurrentStorage.read(defaults,group:directory.path))!.keys == first.keys)
    try host.commitGuardianKeys(both, previous:first)
    try host.commitGuardianKeys(both.closing("a"), previous:both)
    precondition(host.rendered == ["b"])
    precondition(GuardianTargetRuntime.opened(defaults,group:directory.path).0 == ["b"])
    precondition(!GuardianTargetRuntime.full(defaults) && !GuardianTargetRuntime.allowLayer(defaults))
    let saved = try GuardianConcurrentStorage.read(defaults,group:directory.path)!
    do { _ = try saved.adding(a,now:now); fatalError("Restart replay resurrected closed key") } catch GuardianKeyFailure.closed {}
    // Simulate killed host and a delayed first expiry, retaining the second opening.
    let expired = try key("a", floor(now - 1))
    try GuardianConcurrentStorage.write(GuardianKeyRegistry([expired.persisted,b.persisted]),defaults:defaults,group:directory.path)
    monitor.expireSuppressionIfDue()
    precondition(monitor.rendered == ["b"])
    precondition(DeviceActivityCenter.next!.timeIntervalSince1970 * 1000 >= b.untilMillis)
    // Delayed/duplicate old callback reads current registry and does not mutate it.
    monitor.expireSuppressionIfDue()
    precondition((try! GuardianConcurrentStorage.read(defaults,group:directory.path))!.keys.count == 2)
    // A legacy scope is imported verbatim with deterministic identity; dry run has no write.
    try FileManager.default.removeItem(at:directory.appendingPathComponent("guardian-keys.v1.json"))
    defaults.set(end,forKey:GuardianTargetRuntime.untilKey)
    defaults.set(["policy":"targets-v2", "kind":"allow-layer", "untilMillis":end] as [String:Any],forKey:GuardianTargetRuntime.scopeKey)
    let preview = try GuardianConcurrentStorage.load(defaults,group:directory.path,now:now,persistMigration:false)
    precondition(preview.keys.single.scope.allowLayer && preview.keys.single.id == "legacy-\(Int64(end))")
    precondition(!FileManager.default.fileExists(atPath:directory.appendingPathComponent("guardian-keys.v1.json").path))
    _ = try GuardianConcurrentStorage.load(defaults,group:directory.path,now:now)
    precondition(defaults.object(forKey:GuardianTargetRuntime.scopeKey) == nil)
    precondition(GuardianTargetRuntime.allowLayer(defaults) && !GuardianTargetRuntime.full(defaults))
    let combined = try GuardianConcurrentStorage.read(defaults,group:directory.path)!.adding(b,now:now)
    try GuardianConcurrentStorage.write(combined,defaults:defaults,group:directory.path)
    precondition(GuardianTargetRuntime.allowLayer(defaults) && GuardianTargetRuntime.opened(defaults,group:directory.path).0 == ["b"])
    let allowedItems = (0..<49).map { ["type":"app", "token":"safe\($0)"] }
    let config: [String:Any] = ["targetPolicy":"dual-v1", "allowEnabled":true, "blockEnabled":true, "allowedItems":allowedItems, "blockedItems":[[String:String]]()]
    try GuardianTargetRuntime.validateRegistry(combined,configs:[config],group:directory.path,now:now)
    let overflow = try combined.adding(a,now:now)
    do { try GuardianTargetRuntime.validateRegistry(overflow,configs:[config],group:directory.path,now:now); fatalError("Early close capacity invalid") } catch GuardianKeyFailure.invalid {}
    // Malformed explicit state never falls back to an unrestricted legacy opening.
    try Data("broken".utf8).write(to:directory.appendingPathComponent("guardian-keys.v1.json"))
    do { _ = try GuardianConcurrentStorage.read(defaults,group:directory.path); fatalError("Corrupt storage accepted") } catch {}
    print("Swift production commit/storage/Monitor: rollback, independent close, killed-host expiry, rearm, migration and malformed state passed")
  }
}
extension Array { var single: Element { precondition(count == 1); return self[0] } }
