import ManagedSettings
import ManagedSettingsUI
import UIKit
import UserNotifications
import os

class ShieldActionExtension: ShieldActionDelegate {
  private let appGroupIdentifier = "APP_GROUP_PLACEHOLDER"
  private let pendingUnlockKey = "appBlocker.pendingUnlock.v1"
  private let pendingInterceptsKey = "appBlocker.pendingIntercepts.v1"
  private let lastInterceptTsKey = "appBlocker.lastInterceptTs.v1"
  // #522: the guarded task id the app wrote into the App Group when it armed the
  // block. Carried into the "하러 가기" notification payload so the JS
  // notification-response router can land on that specific task (home tab +
  // main CTA promotion + first-step 'suggest' bubble). Absent → the router
  // falls back to the current CTA (next/smallest). The *writer* of this key is
  // the enforcement slice, not this extension.
  private let guardedItemIdKey = "appBlocker.guardedItemId.v1"
  private let interceptDebounceMs: Double = 2_000
  private let maxPendingIntercepts = 200
  private let pendingUnlockNotificationIdentifier = "expo.appblocker.pendingUnlock.local"
  // #572 escape ticket ("지금 필요해", secondary button): a distinct local notification whose tap
  // deep-links to the reason-writing screen. Kept separate from the primary landing notification so
  // the two never replace each other. Payload contract (agreed with the mobile slice):
  //   { kind: "guardian_escape", itemId?: <App Group guardedItemId, when armed> }
  private let guardianEscapeNotificationIdentifier = "expo.appblocker.guardianEscape.local"
  // Diagnostics (#583): the shield → app landing is a 2-tap flow on iOS (the OS
  // gives no API to open the container app from a ShieldAction, so the primary
  // button posts a local notification whose tap deep-links home). When that
  // notification never appears, the failure is one of: handler never fired |
  // add() returned an error | add() succeeded but the system suppressed the
  // banner (authorization / focus / shield-foreground). This single JSON key in
  // the App Group records the last attempt (handlerFiredAt, addResult, addAt,
  // authorizationStatus) so the container app — or Console via os_log — can
  // attribute the miss on a real device. Cheap and permanent.
  private let shieldActionProbeKey = "appBlocker.shieldActionProbe.v1"
  private let probeLog = Logger(subsystem: "expo.appblocker", category: "ShieldAction")
  // Notification copy + behavior — configurable via plugin options so apps
  // can localize without forking. Defaults preserve the original English
  // copy and the icon attachment.
  private let notificationTitle = "NOTIFICATION_TITLE_PLACEHOLDER"
  private let notificationBody = "NOTIFICATION_BODY_PLACEHOLDER"
  private let notificationAttachIcon = NOTIFICATION_ATTACH_ICON_PLACEHOLDER

  override func handle(action: ShieldAction, for application: ApplicationToken, completionHandler: @escaping (ShieldActionResponse) -> Void) {
    handleAction(action, completionHandler: completionHandler)
  }

  override func handle(action: ShieldAction, for webDomain: WebDomainToken, completionHandler: @escaping (ShieldActionResponse) -> Void) {
    handleAction(action, completionHandler: completionHandler)
  }

  override func handle(action: ShieldAction, for category: ActivityCategoryToken, completionHandler: @escaping (ShieldActionResponse) -> Void) {
    handleAction(action, completionHandler: completionHandler)
  }

  private func handleAction(_ action: ShieldAction, completionHandler: @escaping (ShieldActionResponse) -> Void) {
    // Any interaction with the shield is a confirmed block event. The
    // ShieldConfiguration data source is cached by the system and not
    // re-invoked per open, so this — the action handler, which fires every
    // time — is the reliable place to record the block.
    recordIntercept()
    switch action {
    case .primaryButtonPressed:
      // #583 diagnostics: prove the handler fired before we even try to post.
      // A later reader seeing addResult still "pending" knows the add()
      // completion never returned.
      recordProbeHandlerFired()
      setPendingUnlockFlag()
      schedulePendingUnlockNotification { didSchedule in
        let response: ShieldActionResponse = didSchedule ? .none : .defer
        self.complete(on: response, completionHandler: completionHandler)
      }

    case .secondaryButtonPressed:
      // #572 escape ticket: post the escape landing notification (same 2-tap flow as primary —
      // the OS gives no API to open the container app from a ShieldAction). Routes to the reason
      // screen via the payload's kind; does NOT set the pendingUnlock flag (that is the earn path).
      recordProbeEscapeHandlerFired()
      scheduleEscapeNotification { didSchedule in
        let response: ShieldActionResponse = didSchedule ? .none : .defer
        self.complete(on: response, completionHandler: completionHandler)
      }

    @unknown default:
      complete(on: .close, completionHandler: completionHandler)
    }
  }

  private func complete(on response: ShieldActionResponse, completionHandler: @escaping (ShieldActionResponse) -> Void) {
    if Thread.isMainThread {
      completionHandler(response)
      return
    }

    DispatchQueue.main.async {
      completionHandler(response)
    }
  }

  // MARK: - #583 landing-notification diagnostics

  /// Merge fields into the single App Group probe JSON (last-attempt snapshot).
  private func writeProbe(_ fields: [String: Any]) {
    guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return }
    var probe: [String: Any] = [:]
    if let json = defaults.string(forKey: shieldActionProbeKey),
       let data = json.data(using: .utf8),
       let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      probe = parsed
    }
    for (key, value) in fields { probe[key] = value }
    if let data = try? JSONSerialization.data(withJSONObject: probe),
       let json = String(data: data, encoding: .utf8) {
      defaults.set(json, forKey: shieldActionProbeKey)
    }
    defaults.synchronize()
  }

  /// Record that primaryButtonPressed actually fired, with a provisional
  /// addResult so an unread completion is distinguishable from a real outcome.
  private func recordProbeHandlerFired() {
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000.0)
    writeProbe(["handlerFiredAt": nowMs, "addResult": "pending"])
    probeLog.log("ShieldAction primaryButtonPressed handler fired @\(nowMs, privacy: .public)")
  }

  private func setPendingUnlockFlag() {
    guard let sharedDefaults = UserDefaults(suiteName: appGroupIdentifier) else { return }
    sharedDefaults.set(true, forKey: pendingUnlockKey)
    sharedDefaults.synchronize()

    let notificationCenter = CFNotificationCenterGetDarwinNotifyCenter()
    CFNotificationCenterPostNotification(
      notificationCenter,
      CFNotificationName("expo.appblocker.pendingUnlock" as CFString),
      nil,
      nil,
      true
    )
  }

  private func schedulePendingUnlockNotification(completion: @escaping (Bool) -> Void) {
    let center = UNUserNotificationCenter.current()

    let content = UNMutableNotificationContent()
    content.title = notificationTitle
    content.body = notificationBody
    content.sound = .default
    // #583 candidate fix: a shield is on-screen (system UI) when this fires, so
    // the container app's banner can be suppressed at the default (.active)
    // level. .timeSensitive asks the system to break through. This only elevates
    // when the extension carries the
    // com.apple.developer.usernotifications.time-sensitive entitlement (added to
    // ShieldAction's expo-target.config.js); without it the system silently
    // downgrades to .active, so this line is safe to ship ahead of the App ID
    // capability.
    content.interruptionLevel = .timeSensitive
    // #522: guardian landing payload. `kind` is the router's discriminator
    // (mirrors notificationScheduler's reminder/timer/nudge convention); `link`
    // is kept for back-compat. `itemId` is included only when the app armed the
    // block for a known task.
    var userInfo: [String: Any] = ["kind": "guardian", "link": "/unlock"]
    if let sharedDefaults = UserDefaults(suiteName: appGroupIdentifier) {
      sharedDefaults.synchronize()
      if let guardedItemId = sharedDefaults.string(forKey: guardedItemIdKey), !guardedItemId.isEmpty {
        userInfo["itemId"] = guardedItemId
      }
    }
    content.userInfo = userInfo

    // Attach the app icon to the notification only when the app opted in.
    // When false the system app icon is the only icon shown — avoids the
    // "duplicate icon" look on iOS notification banners.
    if notificationAttachIcon, let iconURL = iconFileURL() {
      if let attachment = try? UNNotificationAttachment(identifier: "icon", url: iconURL, options: nil) {
        content.attachments = [attachment]
      }
    }

    let request = UNNotificationRequest(
      identifier: pendingUnlockNotificationIdentifier,
      content: content,
      trigger: nil
    )

    // #583 diagnostics: capture the authorization status the extension sees —
    // a .denied / .notDetermined app can add() successfully yet show nothing.
    center.getNotificationSettings { settings in
      let authStatus = settings.authorizationStatus.rawValue
      center.removePendingNotificationRequests(withIdentifiers: [self.pendingUnlockNotificationIdentifier])
      center.add(request) { error in
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000.0)
        let addResult = error.map { "add-error: \($0.localizedDescription)" } ?? "add-ok"
        self.writeProbe([
          "addResult": addResult,
          "addAt": nowMs,
          "authorizationStatus": authStatus,
        ])
        self.probeLog.log("ShieldAction add() \(addResult, privacy: .public) authStatus=\(authStatus, privacy: .public)")
        completion(error == nil)
      }
    }
  }

  // MARK: - #572 escape-notification diagnostics + posting

  /// Record that secondaryButtonPressed actually fired, mirroring `recordProbeHandlerFired` but under
  /// distinct probe keys so the escape diagnostics never overwrite the primary landing's.
  private func recordProbeEscapeHandlerFired() {
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000.0)
    writeProbe(["escapeHandlerFiredAt": nowMs, "escapeAddResult": "pending"])
    probeLog.log("ShieldAction secondaryButtonPressed handler fired @\(nowMs, privacy: .public)")
  }

  /// Post the escape landing notification. Reuses the app-configured landing copy (the banner is just
  /// "open the app" — the actual escape UX is the in-app reason screen the payload routes to). The
  /// payload `kind` is the router's discriminator; `itemId` rides only when the app armed the block
  /// for a known task.
  private func scheduleEscapeNotification(completion: @escaping (Bool) -> Void) {
    let center = UNUserNotificationCenter.current()

    let content = UNMutableNotificationContent()
    content.title = notificationTitle
    content.body = notificationBody
    content.sound = .default
    content.interruptionLevel = .timeSensitive

    var userInfo: [String: Any] = ["kind": "guardian_escape"]
    if let sharedDefaults = UserDefaults(suiteName: appGroupIdentifier) {
      sharedDefaults.synchronize()
      if let guardedItemId = sharedDefaults.string(forKey: guardedItemIdKey), !guardedItemId.isEmpty {
        userInfo["itemId"] = guardedItemId
      }
    }
    content.userInfo = userInfo

    if notificationAttachIcon, let iconURL = iconFileURL() {
      if let attachment = try? UNNotificationAttachment(identifier: "icon", url: iconURL, options: nil) {
        content.attachments = [attachment]
      }
    }

    let request = UNNotificationRequest(
      identifier: guardianEscapeNotificationIdentifier,
      content: content,
      trigger: nil
    )

    center.getNotificationSettings { settings in
      let authStatus = settings.authorizationStatus.rawValue
      center.removePendingNotificationRequests(withIdentifiers: [self.guardianEscapeNotificationIdentifier])
      center.add(request) { error in
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000.0)
        let addResult = error.map { "add-error: \($0.localizedDescription)" } ?? "add-ok"
        self.writeProbe([
          "escapeAddResult": addResult,
          "escapeAddAt": nowMs,
          "authorizationStatus": authStatus,
        ])
        self.probeLog.log("ShieldAction escape add() \(addResult, privacy: .public) authStatus=\(authStatus, privacy: .public)")
        completion(error == nil)
      }
    }
  }

  /// Queue a block event (JSON-string queue in the App Group), debounced,
  /// for the app to drain into `blocker_intercepts`.
  private func recordIntercept() {
    guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return }
    defaults.synchronize()

    let nowMs = Date().timeIntervalSince1970 * 1000.0
    let lastMs = defaults.double(forKey: lastInterceptTsKey)
    if lastMs > 0, (nowMs - lastMs) < interceptDebounceMs { return }

    var queue: [[String: Any]] = []
    if let json = defaults.string(forKey: pendingInterceptsKey),
       let data = json.data(using: .utf8),
       let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
      queue = parsed
    }
    queue.append(["appName": NSNull(), "interceptedAt": nowMs])
    if queue.count > maxPendingIntercepts {
      queue = Array(queue.suffix(maxPendingIntercepts))
    }
    if let data = try? JSONSerialization.data(withJSONObject: queue),
       let json = String(data: data, encoding: .utf8) {
      defaults.set(json, forKey: pendingInterceptsKey)
    }
    defaults.set(nowMs, forKey: lastInterceptTsKey)
    defaults.synchronize()
  }

  private func iconFileURL() -> URL? {
    let bundle = Bundle(for: type(of: self))
    // Try shield-icon first (copied by config plugin)
    if let url = bundle.url(forResource: "shield-icon", withExtension: "png") { return url }
    // Try from app group shared container
    if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
      let sharedIcon = container.appendingPathComponent("notification-icon.png")
      if FileManager.default.fileExists(atPath: sharedIcon.path) { return sharedIcon }
    }
    return nil
  }
}
