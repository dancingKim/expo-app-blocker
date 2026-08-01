import ManagedSettings
import ManagedSettingsUI
import UIKit
import UserNotifications
import os

class ShieldActionExtension: ShieldActionDelegate {
  private let appGroupIdentifier = "APP_GROUP_PLACEHOLDER"
  private let pendingUnlockKey = "appBlocker.pendingUnlock.v1"
  private let pendingInterceptsKey = "appBlocker.pendingIntercepts.v1"
  // Debounce timestamp for TAP (action) events only. This used to be the
  // `appBlocker.lastInterceptTs.v1` key shared with ShieldConfiguration, so the
  // shield render that had just preceded a tap swallowed the tap inside the 2s
  // window — exposure and tap were indistinguishable. Each extension now
  // debounces on its own key and stamps its entries with `kind` ("action" here,
  // "impression" in ShieldConfiguration).
  private let lastActionTsKey = "appBlocker.lastActionTs.v1"
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
  // #598 targeted escape ticket: on "지금 필요해" (secondary) this records the ApplicationToken the
  // user pressed on (+ a timestamp for freshness) into the App Group. The container app's
  // suppressBlocks consumes it and opens ONLY that app for the ticket, keeping every other blocked
  // app shielded. Web/category shields (no app token) clear it so the ticket falls back to full open.
  private let escapeTargetTokenKey = "appBlocker.escapeTargetToken.v1"
  private let escapeTargetTokenTsKey = "appBlocker.escapeTargetTokenTs.v1"
  // #598: the guardian locks by category (`.all(except:)`), so escape almost always arrives on the
  // category overload with NO ApplicationToken. ShieldConfiguration records the app it last rendered a
  // shield for here; we read the freshest one as the target. See the ShieldConfiguration comment for
  // the caching / background-render caveat that the freshness gate + full-open fallback guard against.
  private let lastShieldedTokenKey = "appBlocker.lastShieldedToken.v1"
  private let lastShieldedTokenTsKey = "appBlocker.lastShieldedTokenTs.v1"
  private let lastShieldedTokenMaxAgeMs: Double = 5 * 60 * 1000
  // #598 durability: ShieldConfiguration writes the last-shielded app to this App Group container file
  // (its UserDefaults write is reaped before commit). Read it file-first here, UserDefaults fallback.
  private let lastShieldedFileName = "lastShielded.json"
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
  // Serializes the probe's read-modify-write. The authorization-status probe now
  // runs in parallel with add()'s completion (see schedulePendingUnlockNotification),
  // and UNUserNotificationCenter delivers completion handlers on arbitrary
  // queues, so two writeProbe calls can otherwise race and drop a field.
  private let probeLock = NSLock()
  // Notification copy + behavior — configurable via plugin options so apps
  // can localize without forking. Defaults preserve the original English
  // copy and the icon attachment.
  private let notificationTitle = "NOTIFICATION_TITLE_PLACEHOLDER"
  private let notificationBody = "NOTIFICATION_BODY_PLACEHOLDER"
  private let notificationAttachIcon = NOTIFICATION_ATTACH_ICON_PLACEHOLDER

  override func handle(action: ShieldAction, for application: ApplicationToken, completionHandler: @escaping (ShieldActionResponse) -> Void) {
    // #598: only the app-token overload carries the pressed app, so only it can target the ticket.
    handleAction(action, application: application, completionHandler: completionHandler)
  }

  override func handle(action: ShieldAction, for webDomain: WebDomainToken, completionHandler: @escaping (ShieldActionResponse) -> Void) {
    handleAction(action, application: nil, completionHandler: completionHandler)
  }

  override func handle(action: ShieldAction, for category: ActivityCategoryToken, completionHandler: @escaping (ShieldActionResponse) -> Void) {
    handleAction(action, application: nil, completionHandler: completionHandler)
  }

  private func handleAction(_ action: ShieldAction, application: ApplicationToken?, completionHandler: @escaping (ShieldActionResponse) -> Void) {
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
      recordEscapeTargetToken(application)  // #598: capture the pressed app for a targeted ticket
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
    probeLock.lock()
    defer { probeLock.unlock() }
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
  }

  /// Best-effort authorization-status probe (#583). `getNotificationSettings` is
  /// a system XPC that is documented to stall for seconds, so it is fired in
  /// parallel with the notification post and its result is merged into the probe
  /// only if it returns before this short-lived extension is torn down. It never
  /// gates the shield response — that is what kept the shield UI frozen.
  private func recordAuthorizationStatusProbe(via center: UNUserNotificationCenter) {
    center.getNotificationSettings { settings in
      self.writeProbe(["authorizationStatus": settings.authorizationStatus.rawValue])
    }
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
    if let sharedDefaults = UserDefaults(suiteName: appGroupIdentifier),
       let guardedItemId = sharedDefaults.string(forKey: guardedItemIdKey), !guardedItemId.isEmpty {
      userInfo["itemId"] = guardedItemId
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

    // Latency fix: the shield UI stays locked until `completion` → the
    // completionHandler fires, and this extension is torn down right after
    // (async work started after the response is not guaranteed to run), so the
    // notification post must finish *before* we signal. add() is therefore the
    // single gating XPC. The authorization-status probe used to wrap add() and
    // serialized a second, slow XPC ahead of it; it now runs in parallel and
    // never gates the response.
    recordAuthorizationStatusProbe(via: center)
    center.removePendingNotificationRequests(withIdentifiers: [pendingUnlockNotificationIdentifier])
    center.add(request) { error in
      let nowMs = Int64(Date().timeIntervalSince1970 * 1000.0)
      let addResult = error.map { "add-error: \($0.localizedDescription)" } ?? "add-ok"
      self.writeProbe([
        "addResult": addResult,
        "addAt": nowMs,
      ])
      self.probeLog.log("ShieldAction add() \(addResult, privacy: .public)")
      completion(error == nil)
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

  /// #598: record the app the user pressed "지금 필요해" on, so the container app's suppressBlocks can
  /// open ONLY that app for the ticket. Three sources, in order:
  ///   1. `handler` — the app-token overload carried it directly (rare: the guardian locks by
  ///      category, so escape usually arrives on the category overload with no token).
  ///   2. `lastShielded` — no token here → the app ShieldConfiguration last rendered a shield for
  ///      (App Group), if fresh. This is the guardian's normal path.
  ///   3. `fallback-full` — no usable token → clear the candidate so the ticket opens everything
  ///      (the original safe behavior). Reason recorded for the real-device probe.
  /// The chosen source + reason are written into the shieldAction probe so the next device round can
  /// attribute the outcome immediately. ApplicationToken is Codable; the container decodes the same
  /// base64 back into its allow-except set.
  private func recordEscapeTargetToken(_ application: ApplicationToken?) {
    guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return }
    let nowMs = Date().timeIntervalSince1970 * 1000.0

    if let application = application, let data = try? JSONEncoder().encode(application) {
      defaults.set(data.base64EncodedString(), forKey: escapeTargetTokenKey)
      defaults.set(Int64(nowMs), forKey: escapeTargetTokenTsKey)
      writeProbe(["escapeTargetSource": "handler"])
      return
    }

    // No token here → fall back to the app ShieldConfiguration last rendered a shield for (#598),
    // read file-first (durable) then the legacy UserDefaults mirror.
    if let last = readLastShieldedToken() {
      if last.ts > 0, nowMs - last.ts <= lastShieldedTokenMaxAgeMs {
        defaults.set(last.encoded, forKey: escapeTargetTokenKey)
        defaults.set(Int64(nowMs), forKey: escapeTargetTokenTsKey)
        writeProbe(["escapeTargetSource": "lastShielded"])
        return
      }
      defaults.removeObject(forKey: escapeTargetTokenKey)
      defaults.removeObject(forKey: escapeTargetTokenTsKey)
      writeProbe(["escapeTargetSource": "fallback-full", "escapeTargetReason": "stale-last-shielded"])
      return
    }

    defaults.removeObject(forKey: escapeTargetTokenKey)
    defaults.removeObject(forKey: escapeTargetTokenTsKey)
    writeProbe(["escapeTargetSource": "fallback-full", "escapeTargetReason": "no-last-shielded"])
  }

  /// #598: read the last-shielded app record, file first (durable across ShieldConfiguration's instant
  /// teardown) then the legacy UserDefaults mirror. Returns (base64 token, epoch-ms timestamp) or nil.
  private func readLastShieldedToken() -> (encoded: String, ts: Double)? {
    if let fileURL = appGroupFileURL(lastShieldedFileName),
       let data = try? Data(contentsOf: fileURL),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let encoded = obj["token"] as? String, !encoded.isEmpty {
      let ts = (obj["ts"] as? NSNumber)?.doubleValue ?? 0
      return (encoded, ts)
    }
    if let defaults = UserDefaults(suiteName: appGroupIdentifier) {
      defaults.synchronize()
      if let encoded = defaults.string(forKey: lastShieldedTokenKey), !encoded.isEmpty {
        let ts = (defaults.object(forKey: lastShieldedTokenTsKey) as? NSNumber)?.doubleValue ?? 0
        return (encoded, ts)
      }
    }
    return nil
  }

  private func appGroupFileURL(_ name: String) -> URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
      .appendingPathComponent(name)
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
    if let sharedDefaults = UserDefaults(suiteName: appGroupIdentifier),
       let guardedItemId = sharedDefaults.string(forKey: guardedItemIdKey), !guardedItemId.isEmpty {
      userInfo["itemId"] = guardedItemId
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

    // Same latency fix as the primary landing: add() is the single gating XPC,
    // the authorization-status probe runs in parallel and does not gate.
    recordAuthorizationStatusProbe(via: center)
    center.removePendingNotificationRequests(withIdentifiers: [guardianEscapeNotificationIdentifier])
    center.add(request) { error in
      let nowMs = Int64(Date().timeIntervalSince1970 * 1000.0)
      let addResult = error.map { "add-error: \($0.localizedDescription)" } ?? "add-ok"
      self.writeProbe([
        "escapeAddResult": addResult,
        "escapeAddAt": nowMs,
      ])
      self.probeLog.log("ShieldAction escape add() \(addResult, privacy: .public)")
      completion(error == nil)
    }
  }

  /// Queue a block event (JSON-string queue in the App Group), debounced on the
  /// action-only key, for the app to drain into `blocker_intercepts`. `kind:
  /// "action"` marks this as a confirmed shield-button tap (vs the data source's
  /// "impression" = the shield merely rendered).
  private func recordIntercept() {
    guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return }

    let nowMs = Date().timeIntervalSince1970 * 1000.0
    let lastMs = defaults.double(forKey: lastActionTsKey)
    if lastMs > 0, (nowMs - lastMs) < interceptDebounceMs { return }

    var queue: [[String: Any]] = []
    if let json = defaults.string(forKey: pendingInterceptsKey),
       let data = json.data(using: .utf8),
       let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
      queue = parsed
    }
    queue.append(["appName": NSNull(), "interceptedAt": nowMs, "kind": "action"])
    if queue.count > maxPendingIntercepts {
      queue = Array(queue.suffix(maxPendingIntercepts))
    }
    if let data = try? JSONSerialization.data(withJSONObject: queue),
       let json = String(data: data, encoding: .utf8) {
      defaults.set(json, forKey: pendingInterceptsKey)
    }
    defaults.set(nowMs, forKey: lastActionTsKey)
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
