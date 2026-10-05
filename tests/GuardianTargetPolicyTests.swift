import Foundation

@main struct GuardianTargetPolicyTests {
  static func main() throws {
    func plan(_ allow: [String], _ blocked: [String], _ web: [String], _ apps: [String] = [], _ sites: [String] = [], full: Bool = false) throws -> GuardianTargetPlan<String, String> {
      try GuardianTargetPlan(allowEnabled: true, blockEnabled: true, allowed: Set(allow), blockedApps: Set(blocked), blockedWeb: Set(web), openedApps: Set(apps), openedWeb: Set(sites), full: full)
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
    print("Swift target policy: 11 scenarios passed")
  }
}
