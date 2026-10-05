import Foundation

// Kept identical in host and monitor: these pure rules are also compiled by native policy tests.
struct GuardianOpeningScope: Equatable {
  enum Failure: Error { case invalidScope, capacity, invalidConfiguration }
  let full: Bool
  let allowLayer: Bool
  let apps: Set<String>
  let webDomains: Set<String>
  init(_ raw: [String: Any]) throws {
    if raw["policy"] as? String == "targets-v2" {
      guard raw["kind"] as? String == "allow-layer", raw["apps"] == nil,
            raw["webDomains"] == nil else { throw Failure.invalidScope }
      full = false; allowLayer = true; apps = []; webDomains = []; return
    }
    guard raw["policy"] as? String == "targets-v1" else { throw Failure.invalidScope }
    allowLayer = false
    if raw["kind"] as? String == "full" {
      guard raw["apps"] == nil, raw["webDomains"] == nil else { throw Failure.invalidScope }
      full = true; apps = []; webDomains = []
    } else {
      guard raw["kind"] as? String == "targets",
            let appValues = raw["apps"] as? [String], let webValues = raw["webDomains"] as? [String],
            appValues.allSatisfy({ !$0.isEmpty }), webValues.allSatisfy({ !$0.isEmpty }),
            !appValues.isEmpty || !webValues.isEmpty else { throw Failure.invalidScope }
      full = false; apps = Set(appValues); webDomains = Set(webValues)
    }
  }
  var dictionary: [String: Any] {
    if allowLayer { return ["policy": "targets-v2", "kind": "allow-layer"] }
    if full { return ["policy": "targets-v1", "kind": "full"] }
    return ["policy": "targets-v1", "kind": "targets", "apps": apps.sorted(), "webDomains": webDomains.sorted()]
  }
  static func live(_ raw: [String: Any]?, nowMillis: Double) -> GuardianOpeningScope? {
    guard let raw, let until = raw["untilMillis"] as? Double, until.isFinite,
          until > nowMillis else { return nil }
    return try? GuardianOpeningScope(raw)
  }
  static func supportedExtensions(_ policies: [String: String]) -> Bool {
    ["ShieldAction", "DeviceActivityMonitor"].allSatisfy { policies[$0] == "allow-layer-v1" }
  }
}

struct GuardianTargetPlan<T: Hashable, W: Hashable> {
  let allowed: Set<T>
  let blockedApps: Set<T>
  let blockedWeb: Set<W>
  init(allowEnabled: Bool, blockEnabled: Bool, allowed: Set<T>, blockedApps: Set<T>,
       blockedWeb: Set<W>, openedApps: Set<T>, openedWeb: Set<W>, full: Bool, allowLayer: Bool = false) throws {
    let effectiveAllow = allowEnabled && !allowed.isEmpty && !full && !allowLayer
    let exceptions = effectiveAllow ? allowed.union(openedApps) : []
    guard exceptions.count <= 50, blockedApps.count <= 50, blockedWeb.count <= 50 else {
      throw GuardianOpeningScope.Failure.capacity
    }
    self.allowed = exceptions
    self.blockedApps = blockEnabled && !full ? blockedApps.subtracting(openedApps) : []
    self.blockedWeb = blockEnabled && !full ? blockedWeb.subtracting(openedWeb) : []
  }
}

#if os(iOS)
import ManagedSettings
import FamilyControls

enum GuardianTargetRuntime {
  static let scopeKey = "appBlocker.suppressionScope.v1"
  static let candidateKey = "appBlocker.escapeScope.v1"
  static let untilKey = "appBlocker.suppressionUntil.v1"
  static let legacyTargetKey = "appBlocker.suppressionTargetToken.v1"
  static func until(_ defaults: UserDefaults) -> Double {
    if defaults.object(forKey: scopeKey) != nil {
      return (defaults.dictionary(forKey: scopeKey)?["untilMillis"] as? NSNumber)?.doubleValue ?? 0
    }
    return (defaults.object(forKey: untilKey) as? NSNumber)?.doubleValue ?? 0
  }
  static func active(_ defaults: UserDefaults) -> Bool { until(defaults) > Date().timeIntervalSince1970 * 1000 }
  static func full(_ defaults: UserDefaults) -> Bool {
    guard active(defaults) else { return false }
    if let raw = defaults.dictionary(forKey: scopeKey) { return (try? GuardianOpeningScope(raw).full) == true }
    if defaults.object(forKey: scopeKey) != nil { return false }
    return defaults.string(forKey: legacyTargetKey) == nil
  }
  static func allowLayer(_ defaults: UserDefaults) -> Bool {
    GuardianOpeningScope.live(defaults.dictionary(forKey: scopeKey),
      nowMillis: Date().timeIntervalSince1970 * 1000)?.allowLayer == true
  }
  static func app(_ token: String, group: String) throws -> ApplicationToken {
    let canonical = GuardianTokenRecovery.supported
      ? try GuardianTokenRecovery.resolve(token, aliases: GuardianTokenRecovery.read(GuardianTokenRecovery.location(group: group))) : token
    guard let data = Data(base64Encoded: canonical), let value = try? JSONDecoder().decode(ApplicationToken.self, from: data) else { throw GuardianOpeningScope.Failure.invalidScope }
    return value
  }
  static func web(_ token: String) throws -> WebDomainToken {
    guard let data = Data(base64Encoded: token), let value = try? JSONDecoder().decode(WebDomainToken.self, from: data) else {
      throw GuardianOpeningScope.Failure.invalidScope
    }
    return value
  }
  static func opened(_ defaults: UserDefaults, group: String) -> (Set<ApplicationToken>, Set<WebDomainToken>) {
    guard active(defaults) else { return ([], []) }
    if let raw = defaults.dictionary(forKey: scopeKey) {
      guard let scope = try? GuardianOpeningScope(raw), !scope.full,
            let apps = try? Set(scope.apps.map { try app($0, group: group) }),
            let domains = try? Set(scope.webDomains.map { try web($0) }) else { return ([], []) }
      return (apps, domains)
    }
    guard defaults.object(forKey: scopeKey) == nil,
          let token = defaults.string(forKey: legacyTargetKey), let value = try? app(token, group: group) else { return ([], []) }
    return ([value], [])
  }
  static func directStore(_ layer: String) -> ManagedSettingsStore {
    ManagedSettingsStore(named: ManagedSettingsStore.Name("appBlocker.direct.\(layer)"))
  }
  static func clear(_ store: ManagedSettingsStore) {
    store.shield.applications = nil; store.shield.applicationCategories = nil; store.shield.webDomains = nil
  }
  static func tokens(_ raw: Any?, type: String) throws -> [String] {
    guard let items = raw as? [[String: Any]], items.allSatisfy({ $0["type"] as? String == "app" || $0["type"] as? String == "webDomain" }) else {
      throw GuardianOpeningScope.Failure.invalidConfiguration
    }
    return try items.filter { $0["type"] as? String == type }.map {
      guard let token = $0["token"] as? String, !token.isEmpty else { throw GuardianOpeningScope.Failure.invalidConfiguration }
      return token
    }
  }
  static func validate(_ config: [String: Any], group: String) throws {
    guard config["targetPolicy"] as? String == "dual-v1",
          config["allowEnabled"] is Bool, config["blockEnabled"] is Bool else { throw GuardianOpeningScope.Failure.invalidConfiguration }
    let allowed = try tokens(config["allowedItems"], type: "app")
    guard try tokens(config["allowedItems"], type: "webDomain").isEmpty else { throw GuardianOpeningScope.Failure.invalidConfiguration }
    let apps = try tokens(config["blockedItems"], type: "app")
    let webs = try tokens(config["blockedItems"], type: "webDomain")
    guard try Set(allowed.map { try app($0, group: group) }).count <= 49,
          try Set(apps.map { try app($0, group: group) }).count <= 50,
          try Set(webs.map { try web($0) }).count <= 50 else { throw GuardianOpeningScope.Failure.capacity }
  }
  static func validateOpening(_ scope: GuardianOpeningScope, configs: [[String: Any]], group: String) throws {
    let opened = try Set(scope.apps.map { try app($0, group: group) })
    _ = try scope.webDomains.map { try web($0) }
    guard !scope.full && !scope.allowLayer else { return }
    var allowed = Set<ApplicationToken>()
    for config in configs {
      let dual = config["targetPolicy"] as? String == "dual-v1"
      if dual { try validate(config, group: group) }
      guard (dual ? config["allowEnabled"] as? Bool == true : config["mode"] as? String == "allow"),
            config["isActive"] as? Bool != false else { continue }
      for token in try tokens(config["allowedItems"] ?? [], type: "app") { allowed.insert(try app(token, group: group)) }
    }
    if !allowed.isEmpty && allowed.union(opened).count > 50 { throw GuardianOpeningScope.Failure.capacity }
  }
  static func render(_ config: [String: Any], store: ManagedSettingsStore, layer: String,
                     defaults: UserDefaults, group: String) throws {
    try validate(config, group: group)
    let allowed = try Set(tokens(config["allowedItems"], type: "app").map { try app($0, group: group) })
    let blocked = try Set(tokens(config["blockedItems"], type: "app").map { try app($0, group: group) })
    let domains = try Set(tokens(config["blockedItems"], type: "webDomain").map { try web($0) })
    let (openedApps, openedWeb) = opened(defaults, group: group)
    let plan = try GuardianTargetPlan(allowEnabled: config["allowEnabled"] as? Bool == true,
      blockEnabled: config["blockEnabled"] as? Bool == true, allowed: allowed, blockedApps: blocked,
      blockedWeb: domains, openedApps: openedApps, openedWeb: openedWeb,
      full: config["isActive"] as? Bool == false || full(defaults), allowLayer: allowLayer(defaults))
    let direct = directStore(layer)
    store.shield.applications = nil
    store.shield.applicationCategories = plan.allowed.isEmpty ? nil : .all(except: plan.allowed)
    store.shield.webDomains = nil
    direct.shield.applications = plan.blockedApps.isEmpty ? nil : plan.blockedApps
    direct.shield.applicationCategories = nil
    direct.shield.webDomains = plan.blockedWeb.isEmpty ? nil : plan.blockedWeb
  }
}
#endif
