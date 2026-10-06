import Foundation

/// Origin evidence comes from the typed shield callback and the currently applied native stores.
enum GuardianEscapeScope {
  /// A newer token-less record invalidates the older mirror, rather than reviving another app.
  static func lastShielded(file: [String: Any]?, mirror: [String: Any]?) -> (encoded: String, ts: Double)? {
    let latest = [file, mirror].compactMap { $0 }.enumerated().max {
      let left = ($0.element["ts"] as? NSNumber)?.doubleValue ?? 0
      let right = ($1.element["ts"] as? NSNumber)?.doubleValue ?? 0
      return left == right ? $0.offset > $1.offset : left < right
    }?.element
    guard let latest, latest["tokenNil"] as? Bool != true,
          let token = latest["token"] as? String, !token.isEmpty,
          let ts = (latest["ts"] as? NSNumber)?.doubleValue else { return nil }
    return (token, ts)
  }
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
