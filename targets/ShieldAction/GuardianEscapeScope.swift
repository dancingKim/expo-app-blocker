import Foundation

/// Origin evidence comes from the typed shield callback and the currently applied native stores.
enum GuardianEscapeScope {
  static func candidate(app: String?, webDomain: String?, directlyBlocked: Bool,
                        allowBlocked: Bool) -> [String: Any]? {
    if let webDomain {
      return ["policy": "targets-v1", "kind": "targets", "apps": [String](), "webDomains": [webDomain]]
    }
    if let app, directlyBlocked {
      return ["policy": "targets-v1", "kind": "targets", "apps": [app], "webDomains": [String]()]
    }
    if allowBlocked { return ["policy": "targets-v2", "kind": "allow-layer"] }
    // Unknown origin is not authority to lower either layer.
    return nil
  }
}
