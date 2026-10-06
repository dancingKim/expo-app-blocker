import Foundation

typealias ApplicationToken = String
typealias WebDomainToken = String
enum CategoryPolicy { case all(Set<String>) }
final class TestShield {
  var applications: Set<String>?
  var applicationCategories: CategoryPolicy?
}
final class ManagedSettingsStore {
  struct Name { let value: String; init(_ value: String) { self.value = value } }
  static var shields: [String: TestShield] = [:]
  let shield: TestShield
  init(named: Name = Name("gate")) {
    let value = Self.shields[named.value] ?? TestShield()
    Self.shields[named.value] = value; shield = value
  }
}
final class ActionFixture {
  let appGroupIdentifier: String
  let escapeTargetTokenKey = "appBlocker.escapeTargetToken.v1"
  let escapeTargetTokenTsKey = "appBlocker.escapeTargetTokenTs.v1"
  init(_ group: String) { appGroupIdentifier = group }
  func appGroupFileURL(_ name: String) -> URL? { nil }
  func writeProbe(_ values: [String: String]) {}
  // PRODUCTION_ORIGIN
}
@main struct OriginTests {
  static func main() throws {
    let suite = "guardian-origin-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let action = ActionFixture(suite)
    let encoded = try JSONEncoder().encode("direct").base64EncodedString()
    // Cached configuration still names A; current category callback for B supplies no identity.
    defaults.set(encoded, forKey: "appBlocker.lastShieldedToken.v1")
    defaults.set(Date().timeIntervalSince1970 * 1000, forKey: "appBlocker.lastShieldedTokenTs.v1")
    ManagedSettingsStore().shield.applicationCategories = .all(["safe"])
    ManagedSettingsStore(named: .init("appBlocker.direct.gate")).shield.applications = ["direct"]
    action.recordEscapeTargetToken(nil, webDomain: nil)
    let unknown = defaults.dictionary(forKey: "appBlocker.escapeScope.v1")!
    do { _ = try GuardianOpeningScope(unknown); preconditionFailure("Cached A cannot become B's scope") }
    catch GuardianOpeningScope.Failure.invalidScope {}
    action.recordEscapeTargetToken("kakao", webDomain: nil)
    let outside = try GuardianOpeningScope(defaults.dictionary(forKey: "appBlocker.escapeScope.v1")!)
    precondition(outside.allowLayer && outside.apps.isEmpty)
    action.recordEscapeTargetToken("direct", webDomain: nil)
    let direct = try GuardianOpeningScope(defaults.dictionary(forKey: "appBlocker.escapeScope.v1")!)
    precondition(!direct.allowLayer && direct.apps == [encoded])
    ManagedSettingsStore(named: .init("appBlocker.direct.gate")).shield.applications = nil
    action.recordEscapeTargetToken(nil, webDomain: nil)
    let onlyAllow = try GuardianOpeningScope(defaults.dictionary(forKey: "appBlocker.escapeScope.v1")!)
    precondition(onlyAllow.allowLayer)
    action.recordEscapeTargetToken(nil, webDomain: "site")
    let site = try GuardianOpeningScope(defaults.dictionary(forKey: "appBlocker.escapeScope.v1")!)
    precondition(site.apps.isEmpty && site.webDomains.count == 1)
    print("Production ShieldAction origin: stale cached app ignored, typed and pure-allow scopes passed")
  }
}
