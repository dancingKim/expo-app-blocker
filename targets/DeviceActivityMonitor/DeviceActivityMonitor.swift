import DeviceActivity
import ManagedSettings
import FamilyControls
import Foundation

@available(iOS 15.0, *)
// NOTE: the class name MUST be `DeviceActivityMonitorExtension` — it has to match
// the `NSExtensionPrincipalClass` (`$(PRODUCT_MODULE_NAME).DeviceActivityMonitorExtension`)
// that @bacons/apple-targets writes into the extension's Info.plist. If it doesn't
// match, iOS cannot instantiate the extension and NONE of the callbacks fire.
class DeviceActivityMonitorExtension: DeviceActivityMonitor {
  // CONFIGURE: Replace with your App Group identifier
  private let appGroupIdentifier = "APP_GROUP_PLACEHOLDER"
  // Granted earned-time budget in SECONDS (Int); kept in sync with
  // ExpoAppBlockerModule.swift. Presence with value > 0 means an unlock is active.
  private let temporaryUnlockKey = "appBlocker.temporaryUnlock.v1"
  // Consumed seconds, written here as blocked-app usage thresholds fire.
  private let usageConsumedKey = "appBlocker.usageConsumedSeconds.v1"
  // Wall-clock instant the budget was granted (Date) — upper bound for the
  // premature-fire guard (measured usage can't exceed elapsed wall-clock).
  private let unlockGrantedAtKey = "appBlocker.unlockGrantedAt.v1"
  // Usage-step event-name prefix; the suffix is the threshold in seconds.
  private let usageStepEventPrefix = "appBlocker.usageStep."
  private let blockConfigStorageKey = "appBlocker.blockConfiguration.v1"
  // Schedule-window blocking. Config is mirrored here by the module; each window is a
  // DeviceActivity named "<prefix><index>". Shields live in a dedicated store, unioned
  // with `store` and independent of the temporary-unlock logic.
  private let scheduleConfigStorageKey = "appBlocker.scheduleConfiguration.v1"
  private let scheduleActivityPrefix = "appBlocker.scheduleWindow."
  // #525: the shield variant of the currently-active schedule window ("bedtime" | "schedule").
  // The monitor is the SSOT for which window is active, so it records the variant here on shield
  // apply; ShieldConfiguration reads it to render the sleepy (bedtime) vs weekday shield. Removed
  // when no window is active. The per-window "variant" tag rides in the App Group schedule config
  // (the module persists the raw config dict, so JS-supplied fields survive).
  private let scheduleShieldVariantKey = "appBlocker.scheduleShieldVariant.v1"
  // #535: the immediate-block wall-clock expiry DeviceActivity. Its interval STARTS at the expiry
  // instant, so intervalDidStart (below) is the kill-proof point to lift the immediate shield.
  private let immediateExpiryActivityName = "appBlocker.immediateExpiry"
  // #572 escape ticket: while `now < suppressionUntil` both shields stay down (the ticket is
  // layer-agnostic). The suppression-expiry DeviceActivity's interval STARTS at that instant, so
  // intervalDidStart is the kill-proof point to recompute the shields from the persisted config.
  private let suppressionUntilKey = "appBlocker.suppressionUntil.v1"
  private let suppressionExpiryActivityName = "appBlocker.suppressionExpiry"
  // #598 targeted escape ticket: the base64 ApplicationToken the ticket opens. When present the
  // monitor re-applies each shield with that one app exempt (via the allow-except set) instead of
  // keeping every shield fully down — so a schedule boundary or stray usage step mid-ticket does not
  // re-block the escaped app. Absent → full suppression (every shield stays down). Set by the module.
  private let suppressionTargetTokenKey = "appBlocker.suppressionTargetToken.v1"
  // #601 diagnostics: the monitor's kill-proof suppression-expiry re-lock decision, for the next
  // real-device round. JSON { firedAt, decision, scheduleConfigPresent, immediateConfigPresent }.
  // decision ∈ reapplied-schedule-shield | schedule-open-window | schedule-not-armed |
  // no-schedule-config | not-due. "no-schedule-config" at expiry = the app-side orphan the JS heal
  // targets; anything else means the native backstop resolved the schedule shield correctly.
  private let suppressionExpiryProbeKey = "appBlocker.suppressionExpiryProbe.v1"
  // #598 durability: this probe did not persist on device — a monitor UserDefaults write can also be
  // reaped before cfprefsd commits. Write it primarily to the App Group container file (atomic), same
  // as ShieldConfiguration's lastShielded, and keep the UserDefaults key as a best-effort mirror.
  private let suppressionExpiryProbeFileName = "suppressionExpiryProbe.json"
  // #614: same fired-outcome probe for the immediate (gate/focus) wall-clock expiry.
  private let immediateExpiryProbeKey = "appBlocker.immediateExpiryProbe.v1"
  private let immediateExpiryProbeFileName = "immediateExpiryProbe.json"

  private let store = ManagedSettingsStore()
  // Dedicated schedule store; must match the name used in ExpoAppBlockerModule.swift.
  private let scheduleStore = ManagedSettingsStore(named: ManagedSettingsStore.Name("appBlocker.schedule"))
  private var sharedDefaults: UserDefaults?

  override init() {
    super.init()
    sharedDefaults = UserDefaults(suiteName: appGroupIdentifier)
  }

  /// Fires once per usage step (threshold = N seconds of measured blocked-app use).
  /// Records consumed seconds back to the App Group so the host can show a paused,
  /// pause-when-away countdown; once consumption reaches the budget, re-applies the
  /// shield. This is the primary pause-on-leave relock path.
  override func eventDidReachThreshold(
    _ event: DeviceActivityEvent.Name,
    activity: DeviceActivityName
  ) {
    super.eventDidReachThreshold(event, activity: activity)

    let stepSeconds = parseStepSeconds(from: event.rawValue)
    guard stepSeconds > 0 else {
      // Unknown event — treat as a full relock to stay safe.
      clearUnlockState()
      reapplyBlockConfiguration()
      return
    }

    // Premature-fire guard (iOS-26 bug + clock skew): measured usage can never
    // exceed the wall-clock elapsed since the grant. If a step claims more usage
    // than has physically elapsed (+30s tolerance), it's spurious — ignore it.
    if let grantedAt = sharedDefaults?.object(forKey: unlockGrantedAtKey) as? Date {
      let elapsed = Date().timeIntervalSince(grantedAt)
      if Double(stepSeconds) > elapsed + 30 {
        return
      }
    }

    // Record consumed seconds monotonically (steps can arrive out of order).
    let prev = sharedDefaults?.integer(forKey: usageConsumedKey) ?? 0
    if stepSeconds > prev {
      sharedDefaults?.set(stepSeconds, forKey: usageConsumedKey)
    }

    let budgetSeconds = sharedDefaults?.integer(forKey: temporaryUnlockKey) ?? 0
    if budgetSeconds <= 0 || stepSeconds >= budgetSeconds {
      // Budget fully spent — re-block.
      clearUnlockState()
      reapplyBlockConfiguration()
    }
  }

  /// Fires at the schedule's interval end (23:59:59) — the daily reset. Clears any
  /// unspent budget and re-applies the shield so earned time does not carry across
  /// midnight.
  ///
  /// Guards against the spurious callback that `stopMonitoring()` fires during a
  /// re-grant: that fire happens whenever the user earns time, not at the day
  /// boundary, so only honor it in the last couple of minutes before midnight.
  override func intervalDidEnd(for activity: DeviceActivityName) {
    super.intervalDidEnd(for: activity)

    // #570: a free window boundary — re-evaluate the union of all windows (handles overlaps and
    // weekday gating). A free window just ended → now outside it → the shield is re-applied
    // (intervalDidEnd = re-apply). Never runs the unlock daily-reset below.
    if activity.rawValue.hasPrefix(scheduleActivityPrefix) {
      reevaluateScheduleShield()
      return
    }

    let comps = Calendar.current.dateComponents([.hour, .minute], from: Date())
    guard comps.hour == 23, (comps.minute ?? 0) >= 58 else {
      return
    }
    clearUnlockState()
    reapplyBlockConfiguration()
  }

  override func intervalDidStart(for activity: DeviceActivityName) {
    super.intervalDidStart(for: activity)

    // #535: the immediate-block wall-clock expiry fired (interval starts at the expiry instant).
    // Lift the immediate shield if the persisted expiry has actually passed. Kill-proof: runs even
    // when the host app was force-quit.
    if activity.rawValue == immediateExpiryActivityName {
      expireImmediateBlockIfDue()
      return
    }

    // #572: the escape-ticket expiry fired. Drop the ticket and recompute BOTH shields from the
    // persisted config — kill-proof re-application (the SSOT for re-lock, no RN timer involved).
    if activity.rawValue == suppressionExpiryActivityName {
      expireSuppressionIfDue()
      return
    }

    // #570: a free window opened — re-evaluate. Now inside a free window → the shield is lifted
    // (intervalDidStart = release); intervalDidEnd re-applies it. reevaluate handles overlaps and
    // weekday gating (the opened window may be gated out by weekday).
    if activity.rawValue.hasPrefix(scheduleActivityPrefix) {
      reevaluateScheduleShield()
    }
  }

  /// #535: lift the immediate-block shield once its persisted wall-clock expiry passes. Guards
  /// against a spurious/early boundary fire (only releases when now >= expiry) and drops the App
  /// Group config copy so the shield doesn't re-render; the host clears its userDefaults.standard
  /// copy on next foreground (the module's applyBlocks expiry gate).
  private func expireImmediateBlockIfDue() {
    let defaults = sharedDefaults ?? UserDefaults.standard
    guard let dict = defaults.dictionary(forKey: blockConfigStorageKey),
          let expiry = (dict["expiresAtMillis"] as? NSNumber)?.doubleValue, expiry > 0 else {
      writeImmediateExpiryProbe(decision: "no-immediate-expiry")
      return
    }
    guard Date().timeIntervalSince1970 * 1000.0 >= expiry else {
      writeImmediateExpiryProbe(decision: "not-due")
      return
    }
    store.shield.applications = nil
    store.shield.applicationCategories = nil
    store.shield.webDomains = nil
    defaults.removeObject(forKey: blockConfigStorageKey)
    writeImmediateExpiryProbe(decision: "released")
  }

  // MARK: - Escape Ticket Suppression (#572)

  /// True while an escape ticket is live (`now < suppressionUntil`). Shared with the app module's
  /// gate so a ticket keeps every shield the monitor would apply down until it expires.
  private func isSuppressed() -> Bool {
    let defaults = sharedDefaults ?? UserDefaults.standard
    guard let until = (defaults.object(forKey: suppressionUntilKey) as? NSNumber)?.doubleValue, until > 0 else {
      return false
    }
    return Date().timeIntervalSince1970 * 1000.0 < until
  }

  /// #598: the one app a live TARGETED escape ticket keeps open — exempt from every shield the
  /// monitor re-applies. nil for a full-suppression ticket or when no ticket is live. Mirrors the
  /// app module's identical gate (App Group is the shared source of truth).
  private func escapeExemptToken() -> ApplicationToken? {
    guard isSuppressed() else { return nil }
    let defaults = sharedDefaults ?? UserDefaults.standard
    guard let encoded = defaults.string(forKey: suppressionTargetTokenKey), !encoded.isEmpty else { return nil }
    return decodeApplicationToken(from: encoded)
  }

  /// #572: the escape-ticket window has passed. Drop the persisted ticket and recompute both shields
  /// from the stored config (kill-proof re-application). Guards a spurious/early boundary fire.
  private func expireSuppressionIfDue() {
    let defaults = sharedDefaults ?? UserDefaults.standard
    guard let until = (defaults.object(forKey: suppressionUntilKey) as? NSNumber)?.doubleValue, until > 0 else {
      return
    }
    guard Date().timeIntervalSince1970 * 1000.0 >= until else {
      // Spurious/early boundary fire — ticket not actually over yet; nothing re-locked.
      writeSuppressionExpiryProbe(decision: "not-due")
      return
    }
    defaults.removeObject(forKey: suppressionUntilKey)
    // #598: drop the ticket's target too so the recompute re-shields the previously-exempt app.
    defaults.removeObject(forKey: suppressionTargetTokenKey)
    recomputeShieldsAfterSuppression()
  }

  /// #601: record how the suppression-expiry backstop resolved the SCHEDULE shield, so the next
  /// real-device round can tell "native restored it" from "app-side config orphan" at a glance.
  /// Derives the decision from the same persisted config `reevaluateScheduleShield` reads.
  /// #607/#614: record a FIRED expiry outcome. "fired" distinguishes the monitor's callback from the
  /// module's "registered" write to the same record — an inspection still showing phase "registered"
  /// means iOS never fired the callback.
  private func writeExpiryProbe(fileName: String, udKey: String, decision: String) {
    let defaults = sharedDefaults ?? UserDefaults.standard
    let probe: [String: Any] = [
      "phase": "fired",
      "firedAt": Int64(Date().timeIntervalSince1970 * 1000.0),
      "decision": decision,
      "scheduleConfigPresent": defaults.dictionary(forKey: scheduleConfigStorageKey) != nil,
      "immediateConfigPresent": defaults.dictionary(forKey: blockConfigStorageKey) != nil
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: probe) else { return }
    // Primary: atomic file write (durable even if the monitor is torn down before cfprefsd commits).
    if let fileURL = appGroupFileURL(fileName) {
      try? data.write(to: fileURL, options: .atomic)
    }
    // Best-effort UserDefaults mirror.
    if let json = String(data: data, encoding: .utf8) {
      defaults.set(json, forKey: udKey)
    }
  }

  private func writeSuppressionExpiryProbe(decision: String) {
    writeExpiryProbe(fileName: suppressionExpiryProbeFileName, udKey: suppressionExpiryProbeKey, decision: decision)
  }

  private func writeImmediateExpiryProbe(decision: String) {
    writeExpiryProbe(fileName: immediateExpiryProbeFileName, udKey: immediateExpiryProbeKey, decision: decision)
  }

  private func appGroupFileURL(_ name: String) -> URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
      .appendingPathComponent(name)
  }

  /// The schedule-shield outcome `reevaluateScheduleShield` will produce for the current wall clock —
  /// computed with the same persisted config + window logic, purely for the expiry probe label.
  private func scheduleReapplyDecision() -> String {
    let defaults = sharedDefaults ?? UserDefaults.standard
    guard let dict = defaults.dictionary(forKey: scheduleConfigStorageKey) else { return "no-schedule-config" }
    let windows = parseScheduleWindows(dict)
    if windows.isEmpty { return "schedule-not-armed" }
    if activeScheduleVariant(windows: windows, at: Date()) != nil { return "schedule-open-window" }
    return "reapplied-schedule-shield"
  }

  /// Re-apply the immediate shield from the persisted config (unless its OWN wall-clock expiry has
  /// passed → drop it) and re-evaluate the schedule window state. Runs only after the ticket flag is
  /// cleared, so the gates in `reapplyBlockConfiguration` / `reevaluateScheduleShield` don't skip.
  private func recomputeShieldsAfterSuppression() {
    let defaults = sharedDefaults ?? UserDefaults.standard
    if let dict = defaults.dictionary(forKey: blockConfigStorageKey) {
      let expiry = (dict["expiresAtMillis"] as? NSNumber)?.doubleValue ?? 0
      if expiry > 0, Date().timeIntervalSince1970 * 1000.0 >= expiry {
        store.shield.applications = nil
        store.shield.applicationCategories = nil
        store.shield.webDomains = nil
        defaults.removeObject(forKey: blockConfigStorageKey)
      } else {
        reapplyBlockConfiguration()
      }
    } else {
      store.shield.applications = nil
      store.shield.applicationCategories = nil
      store.shield.webDomains = nil
    }
    reevaluateScheduleShield()
    // #601: record whether the persisted schedule config was present and re-shielded, or absent
    // (the app-side orphan the JS heal covers). Suppression is already cleared here, so
    // reevaluateScheduleShield restored the schedule shield iff we're outside every free window.
    writeSuppressionExpiryProbe(decision: scheduleReapplyDecision())
  }

  /// Extract the threshold seconds from an event name like `appBlocker.usageStep.90`;
  /// 0 if the name is not a usage step.
  private func parseStepSeconds(from rawName: String) -> Int {
    guard rawName.hasPrefix(usageStepEventPrefix) else { return 0 }
    let suffix = rawName.dropFirst(usageStepEventPrefix.count)
    return Int(suffix) ?? 0
  }

  /// Clear all persisted unlock state (budget + consumed counter + grant time).
  private func clearUnlockState() {
    sharedDefaults?.removeObject(forKey: temporaryUnlockKey)
    sharedDefaults?.removeObject(forKey: usageConsumedKey)
    sharedDefaults?.removeObject(forKey: unlockGrantedAtKey)
  }

  private func reapplyBlockConfiguration() {
    // #572/#598: a live FULL escape ticket keeps the shield down — never re-block while it is valid
    // (e.g. a stray usage-step boundary). A TARGETED ticket (#598) instead re-applies the shield with
    // just the escaped app exempt. Either way the monitor re-applies from this same path once the
    // ticket expires.
    let exempt = escapeExemptToken()
    if isSuppressed() && exempt == nil { return }

    let userDefaults = sharedDefaults ?? UserDefaults.standard

    guard let configDict = userDefaults.dictionary(forKey: blockConfigStorageKey) else {
      store.shield.applications = nil
      store.shield.applicationCategories = nil
      store.shield.webDomains = nil
      return
    }

    guard let blockConfig = parseBlockConfig(configDict) else {
      return
    }

    applyBlocks(blockConfig, exempt: exempt)
  }

  // MARK: - Schedule-Window Blocking

  /// Read the schedule config from the App Group and set the dedicated schedule store to
  /// shield the items iff any window is currently active. Independent of the default
  /// `store` (immediate blocks) and the temporary-unlock state.
  private func reevaluateScheduleShield() {
    let defaults = sharedDefaults ?? UserDefaults.standard
    // #572/#598: a live FULL escape ticket also suppresses the schedule shield — keep it down while
    // valid. A TARGETED ticket instead exempts just the escaped app and keeps the gap shield up.
    let exempt = escapeExemptToken()
    if isSuppressed() && exempt == nil {
      clearScheduleShield()
      defaults.removeObject(forKey: scheduleShieldVariantKey)
      return
    }
    guard let dict = defaults.dictionary(forKey: scheduleConfigStorageKey) else {
      clearScheduleShield()
      defaults.removeObject(forKey: scheduleShieldVariantKey)
      return
    }
    let windows = parseScheduleWindows(dict)
    // #563 allowlist: the kept apps ride under `allowedItems` (mode "allow") or `blockedItems`
    // (legacy). The mode picks the shield policy in applyScheduleShield.
    let mode: BlockMode = (dict["mode"] as? String) == "allow" ? .allow : .block
    // #570 free-window inversion: a window = "free time". Shield everything OUTSIDE the free
    // windows while armed; open (clear) while inside one. 0 windows = not armed → clear (never a
    // 24h lockdown; JS clears the config in that case, this is the defensive backstop).
    if windows.isEmpty {
      clearScheduleShield()
      defaults.removeObject(forKey: scheduleShieldVariantKey)
      return
    }
    if activeScheduleVariant(windows: windows, at: Date()) != nil {
      // Inside a free window → fully open.
      clearScheduleShield()
      defaults.removeObject(forKey: scheduleShieldVariantKey)
    } else {
      // Outside all free windows → shield everything but the allowed apps (minus the escaped app for
      // a targeted ticket). The gap shield always records the "schedule" (weekday, redirect-button)
      // variant; the per-window bedtime/schedule tag no longer selects the shield.
      applyScheduleShield(parseScheduleItems(dict, mode: mode), mode: mode, exempt: exempt)
      defaults.set("schedule", forKey: scheduleShieldVariantKey)
    }
  }

  private func parseScheduleWindows(_ dict: [String: Any]) -> [MonitorScheduleWindow] {
    guard let raw = dict["windows"] as? [[String: Any]] else { return [] }
    return raw.compactMap { window in
      guard let start = window["startMinute"] as? Int,
            let end = window["endMinute"] as? Int else {
        return nil
      }
      let weekdays = (window["weekdays"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
      // #525: variant tag rides in the JS-supplied window ("bedtime" for the sleep preset,
      // "schedule" for weekday windows). Missing → treat as a plain weekday window.
      let variant = (window["variant"] as? String) ?? "schedule"
      return MonitorScheduleWindow(startMinute: start, endMinute: end, weekdays: Set(weekdays), variant: variant)
    }
  }

  /// True if `window` covers `date`'s minute-of-day + weekday. A window with
  /// `endMinute < startMinute` crosses midnight; its after-midnight portion is gated on the
  /// window's START day (yesterday).
  private func isWindowActive(_ window: MonitorScheduleWindow, nowMinute: Int, todayIso: Int, yesterdayIso: Int) -> Bool {
    if window.startMinute <= window.endMinute {
      return nowMinute >= window.startMinute && nowMinute < window.endMinute && window.weekdays.contains(todayIso)
    }
    if nowMinute >= window.startMinute, window.weekdays.contains(todayIso) { return true }
    if nowMinute < window.endMinute, window.weekdays.contains(yesterdayIso) { return true }
    return false
  }

  /// #525: the shield variant of the currently-active window, or nil if none is active. A
  /// weekday ("schedule") window takes precedence over "bedtime" when both overlap — the
  /// weekday shield keeps its redirect button, so an overlap never traps the user behind the
  /// button-less sleepy shield.
  private func activeScheduleVariant(windows: [MonitorScheduleWindow], at date: Date) -> String? {
    let comps = Calendar.current.dateComponents([.hour, .minute, .weekday], from: date)
    let nowMinute = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    let todayIso = isoWeekday(fromGregorian: comps.weekday ?? 1)
    let yesterdayIso = todayIso == 1 ? 7 : todayIso - 1

    var bedtimeActive = false
    for window in windows where isWindowActive(window, nowMinute: nowMinute, todayIso: todayIso, yesterdayIso: yesterdayIso) {
      if window.variant == "bedtime" { bedtimeActive = true } else { return "schedule" }
    }
    return bedtimeActive ? "bedtime" : nil
  }

  /// Convert a Gregorian weekday (1 = Sunday … 7 = Saturday) to ISO (1 = Monday … 7 = Sunday).
  private func isoWeekday(fromGregorian gregorian: Int) -> Int {
    return ((gregorian + 5) % 7) + 1
  }

  private func parseScheduleItems(_ dict: [String: Any], mode: BlockMode) -> [MonitorBlockedItemInfo] {
    let key = mode == .allow ? "allowedItems" : "blockedItems"
    guard let rawItems = dict[key] as? [[String: Any]] else { return [] }
    return rawItems.compactMap { selection -> MonitorBlockedItemInfo? in
      guard let tokenString = selection["token"] as? String else { return nil }
      let itemTypeRaw = (selection["type"] as? String ?? "app").lowercased()
      let itemType: MonitorBlockedItemType
      switch itemTypeRaw {
      case "category":
        itemType = .category
      case "webdomain":
        itemType = .webDomain
      default:
        itemType = .app
      }
      return MonitorBlockedItemInfo(
        type: itemType,
        tokenId: tokenString,
        appToken: itemType == .app ? decodeApplicationToken(from: tokenString) : nil,
        categoryToken: itemType == .category ? decodeCategoryToken(from: tokenString) : nil,
        webDomainToken: itemType == .webDomain ? decodeWebDomainToken(from: tokenString) : nil
      )
    }
  }

  private func applyScheduleShield(_ items: [MonitorBlockedItemInfo], mode: BlockMode, exempt: ApplicationToken? = nil) {
    // #563 allowlist: an active window shields everything except the kept apps.
    if mode == .allow {
      applyAllowlistShield(scheduleStore, allowed: items, exempt: exempt)
      return
    }
    let exemptSet: Set<ApplicationToken> = exempt.map { [$0] } ?? []
    let apps = items.compactMap { $0.appToken }.filter { !exemptSet.contains($0) }
    let categories = items.compactMap { $0.categoryToken }
    let webDomains = items.compactMap { $0.webDomainToken }
    if apps.isEmpty {
      scheduleStore.shield.applications = nil
    } else {
      scheduleStore.shield.applications = Set(apps)
    }
    if categories.isEmpty {
      scheduleStore.shield.applicationCategories = nil
    } else {
      scheduleStore.shield.applicationCategories = .specific(Set(categories))
    }
    if webDomains.isEmpty {
      scheduleStore.shield.webDomains = nil
    } else {
      scheduleStore.shield.webDomains = Set(webDomains)
    }
  }

  /// #563 allowlist shield: shield every app EXCEPT the kept (allowed) app tokens via
  /// `ShieldSettings.ActivityCategoryPolicy.all(except:)`. Only ApplicationTokens can go in the
  /// except-set (the app layer refuses non-app selections). Empty allowed set → no shield (the app
  /// gates 0 allowed apps as "lock not possible", so empty is never a real block-all here).
  private func applyAllowlistShield(_ managedStore: ManagedSettingsStore, allowed items: [MonitorBlockedItemInfo], exempt: ApplicationToken? = nil) {
    var allowedAppTokens = Set(items.compactMap { $0.appToken })
    if allowedAppTokens.isEmpty {
      // Empty allow set = no shield on this store; a targeted-ticket exempt must not turn that into
      // a block-everything-except-one shield.
      managedStore.shield.applications = nil
      managedStore.shield.applicationCategories = nil
      managedStore.shield.webDomains = nil
      return
    }
    // #598: the escaped app joins the allow (except) set for the ticket.
    if let exempt = exempt { allowedAppTokens.insert(exempt) }
    managedStore.shield.applications = nil
    managedStore.shield.applicationCategories = ShieldSettings.ActivityCategoryPolicy.all(except: allowedAppTokens)
    managedStore.shield.webDomains = nil
  }

  private func clearScheduleShield() {
    scheduleStore.shield.applications = nil
    scheduleStore.shield.applicationCategories = nil
    scheduleStore.shield.webDomains = nil
  }

  private func parseBlockConfig(_ dict: [String: Any]) -> MonitorBlockConfig? {
    // #563 allowlist: `mode == "allow"` reads the kept apps from `allowedItems`; legacy reads the
    // blocked apps from `blockedItems`.
    let mode: BlockMode = (dict["mode"] as? String) == "allow" ? .allow : .block
    let rawItems: [[String: Any]]
    if mode == .allow, let allowedItems = dict["allowedItems"] as? [[String: Any]] {
      rawItems = allowedItems
    } else if let blockedItems = dict["blockedItems"] as? [[String: Any]] {
      rawItems = blockedItems
    } else if let appSelections = dict["appSelections"] as? [[String: Any]] {
      rawItems = appSelections.map { item in
        var normalized = item
        normalized["type"] = "app"
        return normalized
      }
    } else if mode == .allow {
      rawItems = []
    } else {
      return nil
    }

    let items: [MonitorBlockedItemInfo] = rawItems.compactMap { selection -> MonitorBlockedItemInfo? in
      guard let tokenString = selection["token"] as? String else {
        return nil
      }

      let itemTypeRaw = (selection["type"] as? String ?? "app").lowercased()
      let itemType: MonitorBlockedItemType
      switch itemTypeRaw {
      case "category":
        itemType = .category
      case "webdomain":
        itemType = .webDomain
      default:
        itemType = .app
      }

      return MonitorBlockedItemInfo(
        type: itemType,
        tokenId: tokenString,
        appToken: itemType == .app ? decodeApplicationToken(from: tokenString) : nil,
        categoryToken: itemType == .category ? decodeCategoryToken(from: tokenString) : nil,
        webDomainToken: itemType == .webDomain ? decodeWebDomainToken(from: tokenString) : nil
      )
    }

    let isActive = dict["isActive"] as? Bool ?? true
    return MonitorBlockConfig(items: items, isActive: isActive, mode: mode)
  }

  private func applyBlocks(_ config: MonitorBlockConfig, exempt: ApplicationToken? = nil) {
    guard config.isActive else {
      store.shield.applications = nil
      store.shield.applicationCategories = nil
      store.shield.webDomains = nil
      return
    }

    // #563 allowlist: shield every app except the kept ones (whether iOS also exempts
    // system-essential/controlling apps is pending real-device verification).
    if config.mode == .allow {
      applyAllowlistShield(store, allowed: config.items, exempt: exempt)
      return
    }

    let exemptSet: Set<ApplicationToken> = exempt.map { [$0] } ?? []
    let validAppTokens = config.items.compactMap { $0.appToken }.filter { !exemptSet.contains($0) }
    let validCategoryTokens = config.items.compactMap { $0.categoryToken }
    let validWebDomainTokens = config.items.compactMap { $0.webDomainToken }

    guard !validAppTokens.isEmpty || !validCategoryTokens.isEmpty || !validWebDomainTokens.isEmpty else {
      store.shield.applications = nil
      store.shield.applicationCategories = nil
      store.shield.webDomains = nil
      return
    }

    if !validAppTokens.isEmpty {
      store.shield.applications = Set(validAppTokens)
    } else {
      store.shield.applications = nil
    }

    if !validCategoryTokens.isEmpty {
      store.shield.applicationCategories = .specific(Set(validCategoryTokens))
    } else {
      store.shield.applicationCategories = nil
    }

    if !validWebDomainTokens.isEmpty {
      store.shield.webDomains = Set(validWebDomainTokens)
    } else {
      store.shield.webDomains = nil
    }
  }

  private func decodeApplicationToken(from encoded: String) -> ApplicationToken? {
    guard let data = Data(base64Encoded: encoded) else {
      return nil
    }

    do {
      return try JSONDecoder().decode(ApplicationToken.self, from: data)
    } catch {
      return nil
    }
  }

  private func decodeCategoryToken(from encoded: String) -> ActivityCategoryToken? {
    guard let data = Data(base64Encoded: encoded) else {
      return nil
    }

    do {
      return try JSONDecoder().decode(ActivityCategoryToken.self, from: data)
    } catch {
      return nil
    }
  }

  private func decodeWebDomainToken(from encoded: String) -> WebDomainToken? {
    guard let data = Data(base64Encoded: encoded) else {
      return nil
    }

    do {
      return try JSONDecoder().decode(WebDomainToken.self, from: data)
    } catch {
      return nil
    }
  }
}

enum MonitorBlockedItemType: String {
  case app
  case category
  case webDomain
}

/// #563: block semantics (see the app module's BlockMode). `.allow` = keep the listed apps open,
/// shield everything else via `.all(except:)`.
enum BlockMode: String {
  case block
  case allow
}

struct MonitorBlockedItemInfo {
  let type: MonitorBlockedItemType
  let tokenId: String
  let appToken: ApplicationToken?
  let categoryToken: ActivityCategoryToken?
  let webDomainToken: WebDomainToken?
}

struct MonitorBlockConfig {
  let items: [MonitorBlockedItemInfo]
  let isActive: Bool
  // #563: block vs allow semantics for `items`.
  let mode: BlockMode
}

/// One schedule window: local minute-of-day bounds (0..1439) plus the ISO weekdays
/// (1 = Monday … 7 = Sunday) it applies to. `endMinute < startMinute` crosses midnight.
struct MonitorScheduleWindow {
  let startMinute: Int
  let endMinute: Int
  let weekdays: Set<Int>
  // #525: "bedtime" (sleepy shield, no button) | "schedule" (weekday shield, redirect button).
  let variant: String
}
