import Foundation

// In-memory adapters for OS-owned stores; real reapply/schedule method bodies are injected by runner.
final class TestLock { func unlock() {} }
final class TestStore {
  var allowed: Set<String> = ["stale-allowed"]
  var apps: Set<String> = ["stale-direct"]
  var web: Set<String> = ["stale-site"]
}
struct TestConfig {
  let isActive: Bool
  let expiresAtMillis: Double?
  let guardType: String
  let raw: [String: Any]
}
enum GuardianTargetRuntime {
  static func full(_ defaults: UserDefaults) -> Bool { false }
  static func render(_ config: [String: Any], store: TestStore, layer: String, defaults: UserDefaults, group: String) throws {
    if config["failRender"] as? Bool == true { throw GuardianOpeningScope.Failure.invalidConfiguration }
    let scope = GuardianOpeningScope.live(defaults.dictionary(forKey: "scope"), nowMillis: Date().timeIntervalSince1970 * 1000)
    let plan = try GuardianTargetPlan(allowEnabled: true, blockEnabled: true,
      allowed: Set(["safe"]), blockedApps: Set(["direct"]), blockedWeb: Set(["site"]),
      openedApps: scope?.apps ?? [], openedWeb: scope?.webDomains ?? [], full: false, allowLayer: scope?.allowLayer == true)
    store.allowed = plan.allowed; store.apps = plan.blockedApps; store.web = plan.blockedWeb
  }
}
final class HostFixture {
  var sharedDefaults: UserDefaults?
  let userDefaults: UserDefaults
  var didLoadPersistedConfig = false
  var currentBlockConfig: TestConfig?
  var focusBlockConfig: TestConfig?
  let store = TestStore(), focusStore = TestStore(), scheduleStore = TestStore()
  let blockConfigStorageKey = "gate", focusBlockConfigStorageKey = "focus", scheduleConfigStorageKey = "schedule"
  let blockSatisfiedKey = "gateSatisfied", focusBlockSatisfiedKey = "focusSatisfied", scheduleShieldVariantKey = "variant"
  let appGroupIdentifier = "fixture"
  init(_ defaults: UserDefaults) { sharedDefaults = defaults; userDefaults = defaults }
  func lockGuardianKeys() throws -> TestLock { TestLock() }
  func clearImmediateStore(_ target: TestStore) { target.allowed = []; target.apps = []; target.web = [] }
  func clearScheduleShield() { clearImmediateStore(scheduleStore) }
  func parseBlockConfig(_ raw: [String: Any]) throws -> TestConfig {
    if raw["failParse"] as? Bool == true { throw GuardianOpeningScope.Failure.invalidConfiguration }
    return TestConfig(isActive: raw["isActive"] as? Bool ?? true, expiresAtMillis: raw["expiresAtMillis"] as? Double,
      guardType: raw["guardType"] as? String ?? "gate", raw: raw)
  }
  func isFocus(_ config: TestConfig) -> Bool { config.guardType == "focus" }
  func applyBlocks(_ config: TestConfig) throws {
    try GuardianTargetRuntime.render(config.raw, store: isFocus(config) ? focusStore : store,
      layer: config.guardType, defaults: userDefaults, group: appGroupIdentifier)
  }
  func escapeExemptToken() -> String? { nil }
  func parseScheduleWindows(_ config: [String: Any]) -> [Int] { config["windows"] as? [Int] ?? [] }
  func scheduleMode(_ config: [String: Any]) -> String { "allow" }
  func scheduleItemsRaw(_ config: [String: Any], mode: String) -> [String] { [] }
  func makeBlockedItems(from raw: [String]) -> [String] { raw }
  func isContinuousSchedule(_ config: [String: Any]) -> Bool { config["continuous"] as? Bool == true }
  func isAnyScheduleWindowActive(windows: [Int], at: Date) -> Bool { windows.contains(1) }
  func updateScheduleShieldVariant() {}
  func applyScheduleShield(_ items: [String], mode: String, exempt: String?) { preconditionFailure("Unexpected legacy fixture") }
  func clearSuppressionState() { userDefaults.removeObject(forKey: "scope") }
  // PRODUCTION_REAPPLY
  // PRODUCTION_SCHEDULE
  // PRODUCTION_ROLLBACK
}
@main struct GuardianEscapeRuntimeTests {
  static func main() throws {
    let suite = "guardian-escape-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let host = HostFixture(defaults)
    let now = Date().timeIntervalSince1970 * 1000
    func configure() {
      defaults.removePersistentDomain(forName: suite)
      defaults.set(["guardType":"gate", "isActive":true], forKey: "gate")
      defaults.set(["guardType":"focus", "isActive":true], forKey: "focus")
      defaults.set(["targetPolicy":"dual-v1", "continuous":true, "windows":[Int]()], forKey: "schedule")
      defaults.set(["policy":"targets-v2", "kind":"allow-layer", "untilMillis":now + 60_000] as [String:Any], forKey: "scope")
    }
    configure()
    try host.reapplyPersistedLayers()
    for store in [host.store, host.focusStore, host.scheduleStore] {
      precondition(store.allowed.isEmpty && store.apps == ["direct"] && store.web == ["site"])
      // Both KakaoTalk and another outside-allow app open, while direct targets remain.
      for app in ["kakao", "another"] { precondition(!store.apps.contains(app) && store.allowed.isEmpty) }
    }
    // Missing, satisfied and expired configs cannot leave a previous OS store behind.
    for kind in ["missing", "satisfied", "expired", "inactive"] {
      configure()
      for layer in ["gate", "focus"] {
        if kind == "missing" { defaults.removeObject(forKey: layer) }
        if kind == "satisfied" { defaults.set(true, forKey: layer + "Satisfied") }
        if kind == "expired" { defaults.set(["guardType":layer, "expiresAtMillis":now - 1000], forKey: layer) }
        if kind == "inactive" { defaults.set(["guardType":layer, "isActive":false], forKey: layer) }
      }
      try host.reapplyPersistedLayers()
      for store in [host.store, host.focusStore] { precondition(store.allowed.isEmpty && store.apps.isEmpty && store.web.isEmpty) }
    }
    configure()
    defaults.set(["targetPolicy":"dual-v1", "continuous":true, "failRender":true], forKey: "schedule")
    do { try host.reapplyPersistedLayers(); preconditionFailure("Schedule failure must reach Start") }
    catch GuardianOpeningScope.Failure.invalidConfiguration {}
    for failed in ["gate", "focus", "schedule"] {
      for failure in ["failParse", "failRender"] where failed != "schedule" || failure == "failRender" {
        configure()
        // The failing layer retains its preexisting shield. Other layers must all recover.
        for store in [host.store, host.focusStore, host.scheduleStore] {
          store.allowed = ["safe"]; store.apps = ["direct"]; store.web = ["site"]
        }
        var config = defaults.dictionary(forKey: failed)!; config[failure] = true
        defaults.set(config, forKey: failed)
        do { try host.reapplyPersistedLayers(); preconditionFailure("Expected failed Start") }
        catch { host.rollback() }
        precondition(defaults.dictionary(forKey: "scope") == nil)
        for store in [host.store, host.focusStore, host.scheduleStore] {
          precondition(store.allowed == ["safe"] && store.apps == ["direct"] && store.web == ["site"])
        }
      }
    }
    configure()
    defaults.removeObject(forKey: "scope")
    try host.reapplyPersistedLayers()
    for store in [host.store, host.focusStore, host.scheduleStore] { precondition(store.allowed == ["safe"] && store.apps == ["direct"]) }
    print("Guardian escape origin and production Start layer boundary: passed")
  }
}
