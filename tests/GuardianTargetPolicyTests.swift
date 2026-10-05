import Foundation

@main struct GuardianTargetPolicyTests {
  static func main() throws {
    func plan(_ allow: [String], _ blocked: [String], _ web: [String], _ apps: [String] = [], _ sites: [String] = [], full: Bool = false, allowLayer: Bool = false) throws -> GuardianTargetPlan<String, String> {
      try GuardianTargetPlan(allowEnabled: true, blockEnabled: true, allowed: Set(allow), blockedApps: Set(blocked), blockedWeb: Set(web), openedApps: Set(apps), openedWeb: Set(sites), full: full, allowLayer: allowLayer)
    }
    let overlap = try plan(["a"], ["a", "b"], ["site"])
    precondition(overlap.allowed == ["a"] && overlap.blockedApps == ["a", "b"])
    let multiple = try plan([], ["a", "b", "c"], ["x", "y"], ["a", "b"], ["x"])
    precondition(multiple.allowed.isEmpty && multiple.blockedApps == ["c"] && multiple.blockedWeb == ["y"])
    let website = try plan(["safe"], ["browser"], ["x", "y"], [], ["x"])
    precondition(website.blockedApps == ["browser"] && website.blockedWeb == ["y"] && website.allowed == ["safe"])
    let emptied = try plan([], ["blocked"], ["x"], ["temporary"])
    precondition(emptied.allowed.isEmpty && emptied.blockedApps == ["blocked"])
    let full = try plan(["safe"], ["blocked"], ["x"], full: true)
    precondition(full.allowed.isEmpty && full.blockedApps.isEmpty && full.blockedWeb.isEmpty)
    let a49 = (0..<49).map(String.init)
    let atCapacity = try plan(a49, ["outside"], [], ["outside"])
    precondition(atCapacity.allowed.count == 50)
    do { _ = try plan(a49, [], [], ["outside", "another"]); preconditionFailure("51 exceptions must reject") }
    catch GuardianOpeningScope.Failure.capacity { }
    let returned = try plan(["new-allowed"], ["a", "new-block"], ["new-site"])
    precondition(returned.blockedApps == ["a", "new-block"] && returned.blockedWeb == ["new-site"])
    let scope = try GuardianOpeningScope(["policy":"targets-v1", "kind":"targets", "apps":["a","a","b"], "webDomains":["site"]])
    let restoredScope = try GuardianOpeningScope(scope.dictionary)
    precondition(restoredScope == scope)
    let site = try GuardianOpeningScope(["policy":"targets-v1", "kind":"targets", "apps":[String](), "webDomains":["site"]])
    precondition(!site.full && site.apps.isEmpty && site.webDomains == ["site"])
    for bad: [String: Any] in [[:], ["policy":"targets-v1","kind":"targets","apps":[String](),"webDomains":[String]()], ["policy":"targets-v1","kind":"full","apps":["a"]]] {
      do { _ = try GuardianOpeningScope(bad); preconditionFailure("Invalid scope must reject") }
      catch GuardianOpeningScope.Failure.invalidScope { }
    }
    let allowScope = try GuardianOpeningScope(["policy":"targets-v2", "kind":"allow-layer"])
    precondition(allowScope.allowLayer && !allowScope.full && allowScope.apps.isEmpty)
    let allowRoundTrip = try GuardianOpeningScope(allowScope.dictionary)
    precondition(allowRoundTrip == allowScope)
    let layerOnly = try plan(["safe"], ["safe", "direct"], ["site"], allowLayer: true)
    precondition(layerOnly.allowed.isEmpty && layerOnly.blockedApps == ["safe", "direct"] && layerOnly.blockedWeb == ["site"])
    for bad: [String: Any] in [
      ["policy":"targets-v2", "kind":"full"],
      ["policy":"targets-v2", "kind":"targets", "apps":["app"], "webDomains":[String]()],
      ["policy":"targets-v2", "kind":"allow-layer", "apps":[String]()],
      ["policy":"targets-v1", "kind":"allow-layer"]
    ] {
      do { _ = try GuardianOpeningScope(bad); preconditionFailure("Invalid version/kind must reject") }
      catch GuardianOpeningScope.Failure.invalidScope { }
    }
    // Exercise production origin selection, including a direct/allow overlap.
    let direct = try GuardianOpeningScope(GuardianEscapeScope.candidate(app: "overlap", webDomain: nil, directlyBlocked: true, allowBlocked: true)!)
    precondition(!direct.allowLayer && direct.apps == ["overlap"])
    let allow = try GuardianOpeningScope(GuardianEscapeScope.candidate(app: "other", webDomain: nil, directlyBlocked: false, allowBlocked: true)!)
    precondition(allow.allowLayer)
    let web = try GuardianOpeningScope(GuardianEscapeScope.candidate(app: "stale-app", webDomain: "site", directlyBlocked: true, allowBlocked: true)!)
    precondition(web.apps.isEmpty && web.webDomains == ["site"] && !web.allowLayer)
    precondition(GuardianEscapeScope.candidate(app: nil, webDomain: nil, directlyBlocked: false, allowBlocked: false) == nil)
    let category = try GuardianOpeningScope(GuardianEscapeScope.candidate(app: nil, webDomain: nil, directlyBlocked: false, allowBlocked: true)!)
    precondition(category.allowLayer)
    // A persisted shared deadline drives the policy; closing or expiry renders
    // the latest config rather than a snapshot from when the key started.
    var persisted = allowScope.dictionary; persisted["untilMillis"] = 2000.0
    let live = GuardianOpeningScope.live(persisted, nowMillis: 1999)
    let during = try plan(["latest-safe"], ["latest-direct"], ["latest-site"], allowLayer: live?.allowLayer == true)
    precondition(during.allowed.isEmpty && during.blockedApps == ["latest-direct"])
    precondition(GuardianOpeningScope.live(persisted, nowMillis: 2000) == nil)
    precondition(GuardianOpeningScope.live(nil, nowMillis: 1999) == nil)
    let expired = try plan(["latest-safe"], ["latest-direct"], ["latest-site"], allowLayer: GuardianOpeningScope.live(persisted, nowMillis: 2000)?.allowLayer == true)
    precondition(expired.allowed == ["latest-safe"] && expired.blockedWeb == ["latest-site"])
    precondition(!GuardianOpeningScope.supportedExtensions([:]))
    precondition(!GuardianOpeningScope.supportedExtensions(["ShieldAction":"allow-layer-v1"]))
    precondition(!GuardianOpeningScope.supportedExtensions(["ShieldAction":"allow-layer-v1", "DeviceActivityMonitor":"old"]))
    precondition(GuardianOpeningScope.supportedExtensions(["ShieldAction":"allow-layer-v1", "DeviceActivityMonitor":"allow-layer-v1"]))
    print("Swift target policy: 20 scenarios passed")
  }
}
