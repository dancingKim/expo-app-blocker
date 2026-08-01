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
  // Focus-slot twin (focus-store split): a config armed with guardType "focus" persists here and
  // shields via the dedicated focus store; the legacy key remains the gate slot. Kept in sync with
  // ExpoAppBlockerModule.swift.
  private let focusBlockConfigStorageKey = "appBlocker.blockConfiguration.focus.v1"
  // Schedule-window blocking. Config is mirrored here by the module; each window is a
  // DeviceActivity named "<prefix><index>". Shields live in a dedicated store, unioned
  // with `store` and independent of the temporary-unlock logic.
  private let scheduleConfigStorageKey = "appBlocker.scheduleConfiguration.v1"
  private let scheduleActivityPrefix = "appBlocker.scheduleWindow."
  // #525: whether the schedule (gap) shield is up. The monitor is the SSOT for window state, so it
  // records "schedule" here while out of every free window and removes the key while inside one (or
  // unarmed); ShieldConfiguration reads it to render the weekday schedule shield. (#588: always
  // "schedule" now — #570 removed the bedtime preset, so there is only one schedule shield.)
  private let scheduleShieldVariantKey = "appBlocker.scheduleShieldVariant.v1"
  // #535: the immediate-block wall-clock expiry DeviceActivity. Its interval STARTS at the expiry
  // instant, so intervalDidStart (below) is the kill-proof point to lift the immediate shield.
  private let immediateExpiryActivityName = "appBlocker.immediateExpiry"
  // Focus twin of the immediate-expiry one-shot (focus-store split) — separate name so each layer's
  // expiry lifts only its own store.
  private let focusImmediateExpiryActivityName = "appBlocker.immediateExpiry.focus"
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
  // #661 stage 1 (RECORD ONLY): allowlist-shield decode outcome — requested vs decoded app tokens.
  // Same record the module writes (it carries `process` to tell the two writers apart).
  private let allowlistShieldProbeKey = "appBlocker.allowlistShieldProbe.v1"
  private let allowlistShieldProbeFileName = "allowlistShieldProbe.json"
  // #657 satisfied marker (epoch ms), written by the host via `setGuardSatisfied`: this layer's
  // reason to be locked is already done, even though its persisted config is still here (the host
  // defers the teardown while an escape ticket is open). Present → the config is a leftover and this
  // extension must NOT re-arm it. Cleared by the host on every arm/teardown, so it cannot go stale.
  private let blockSatisfiedKey = "appBlocker.blockSatisfied.v1"
  private let focusBlockSatisfiedKey = "appBlocker.blockSatisfied.focus.v1"

  private let store = ManagedSettingsStore()
  // Dedicated schedule store; must match the name used in ExpoAppBlockerModule.swift.
  private let scheduleStore = ManagedSettingsStore(named: ManagedSettingsStore.Name("appBlocker.schedule"))
  // Dedicated focus store (focus-store split); must match ExpoAppBlockerModule.swift. The default
  // `store` is the gate layer; the three stores union at the OS level.
  private let focusStore = ManagedSettingsStore(named: ManagedSettingsStore.Name("appBlocker.focus"))
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
    // when the host app was force-quit. Focus-store split: each layer's one-shot lifts only its own
    // store/config slot.
    if activity.rawValue == immediateExpiryActivityName {
      expireImmediateBlockIfDue(configKey: blockConfigStorageKey, target: store, layer: "gate")
      return
    }
    if activity.rawValue == focusImmediateExpiryActivityName {
      expireImmediateBlockIfDue(configKey: focusBlockConfigStorageKey, target: focusStore, layer: "focus")
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

  /// #535: lift an immediate-block shield once its persisted wall-clock expiry passes. Guards
  /// against a spurious/early boundary fire (only releases when now >= expiry) and drops the App
  /// Group config copy so the shield doesn't re-render; the host clears its userDefaults.standard
  /// copy on next foreground (the module's applyBlocks expiry gate). Focus-store split: the caller
  /// passes the layer's config key + store, so gate and focus expire independently.
  private func expireImmediateBlockIfDue(configKey: String, target: ManagedSettingsStore, layer: String) {
    let defaults = sharedDefaults ?? UserDefaults.standard
    guard let dict = defaults.dictionary(forKey: configKey),
          let expiry = (dict["expiresAtMillis"] as? NSNumber)?.doubleValue, expiry > 0 else {
      writeImmediateExpiryProbe(decision: "no-immediate-expiry", extra: ["guardType": layer])
      return
    }
    guard Date().timeIntervalSince1970 * 1000.0 >= expiry else {
      writeImmediateExpiryProbe(decision: "not-due", extra: ["guardType": layer])
      return
    }
    target.shield.applications = nil
    target.shield.applicationCategories = nil
    target.shield.webDomains = nil
    defaults.removeObject(forKey: configKey)
    writeImmediateExpiryProbe(decision: "released", extra: ["guardType": layer])
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
      // #661: the one-shot fired but no ticket is recorded — the App Group read came back empty
      // (ticket already cleared by a teardown, or the container was unreadable from this process).
      // Nothing is re-locked on this path, and it used to be silent; record it.
      writeSuppressionExpiryProbe(decision: "no-ticket-recorded")
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
  private func writeExpiryProbe(fileName: String, udKey: String, decision: String, extra: [String: Any] = [:]) {
    let defaults = sharedDefaults ?? UserDefaults.standard
    var probe: [String: Any] = [
      "phase": "fired",
      "firedAt": Int64(Date().timeIntervalSince1970 * 1000.0),
      "decision": decision,
      "scheduleConfigPresent": defaults.dictionary(forKey: scheduleConfigStorageKey) != nil,
      "immediateConfigPresent": defaults.dictionary(forKey: blockConfigStorageKey) != nil
    ]
    for (key, value) in extra { probe[key] = value }
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

  private func writeImmediateExpiryProbe(decision: String, extra: [String: Any] = [:]) {
    writeExpiryProbe(fileName: immediateExpiryProbeFileName, udKey: immediateExpiryProbeKey, decision: decision, extra: extra)
  }

  /// #661 stage 1: record the allowlist-shield decode outcome from THIS process. Same record shape
  /// and destination as the module's writer (App Group file + a best-effort UserDefaults mirror);
  /// `process` tells the two apart. RECORD ONLY — nothing here changes the shield.
  private func writeAllowlistShieldProbe(_ fields: [String: Any]) {
    let defaults = sharedDefaults ?? UserDefaults.standard
    var probe = fields
    probe["process"] = "monitor"
    probe["at"] = Int64(Date().timeIntervalSince1970 * 1000.0)
    guard let data = try? JSONSerialization.data(withJSONObject: probe) else { return }
    if let fileURL = appGroupFileURL(allowlistShieldProbeFileName) {
      try? data.write(to: fileURL, options: .atomic)
    }
    if let json = String(data: data, encoding: .utf8) {
      defaults.set(json, forKey: allowlistShieldProbeKey)
    }
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
    if isInsideAnyScheduleWindow(windows: windows, at: Date()) { return "schedule-open-window" }
    return "reapplied-schedule-shield"
  }

  /// #657: a layer marked SATISFIED by the host is a leftover, not a lock — its reason to exist is
  /// already done and only the physical teardown is outstanding (deferred while an escape ticket was
  /// open, then lost to an app kill). Drop it here instead of re-arming it: clear that layer's
  /// shield, its persisted config, and the marker itself (one-shot, so the marker can never linger
  /// and suppress a genuinely armed lock — and the host clears it on every arm anyway).
  /// Returns true when the layer was consumed and the caller must not re-apply anything.
  private func consumeSatisfiedLayerIfMarked(satisfiedKey: String, configKey: String,
                                             target: ManagedSettingsStore, layer: String) -> Bool {
    let defaults = sharedDefaults ?? UserDefaults.standard
    let satisfiedAt = (defaults.object(forKey: satisfiedKey) as? NSNumber)?.doubleValue ?? 0
    guard satisfiedAt > 0 else { return false }
    target.shield.applications = nil
    target.shield.applicationCategories = nil
    target.shield.webDomains = nil
    defaults.removeObject(forKey: configKey)
    defaults.removeObject(forKey: satisfiedKey)
    writeImmediateExpiryProbe(decision: "satisfied-not-rearmed", extra: ["guardType": layer])
    return true
  }

  /// Re-apply the immediate shields from the persisted configs (unless a layer's OWN wall-clock
  /// expiry has passed → drop it) and re-evaluate the schedule window state. Runs only after the
  /// ticket flag is cleared, so the gates in `reapplyBlockConfiguration` / `reevaluateScheduleShield`
  /// don't skip. Focus-store split: the gate and focus layers recompute independently.
  ///
  /// #657: a gate the user already SATISFIED is not re-armed here. That used to be an assumption
  /// about the host ("JS clears the config when the task completes") rather than a rule this process
  /// enforced — and when the host could not clear it (release deferred for a live ticket, then the
  /// app killed), the ticket's expiry resurrected the lock for a finished task. The real guard now
  /// lives in `reapplyBlockConfiguration` / `reapplyFocusConfiguration` (see
  /// `consumeSatisfiedLayerIfMarked`), so this comment and the code agree.
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
    reapplyFocusConfiguration()
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

    // #657: the user already finished what this lock was guarding — do not resurrect it.
    if consumeSatisfiedLayerIfMarked(satisfiedKey: blockSatisfiedKey,
                                     configKey: blockConfigStorageKey,
                                     target: store,
                                     layer: "gate") { return }

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

    applyBlocks(blockConfig, exempt: exempt, target: store, layer: "gate")
  }

  /// Focus-layer twin of `recomputeShieldsAfterSuppression`'s gate path (focus-store split):
  /// re-apply the persisted focus config to the dedicated focus store, drop it if its own wall-clock
  /// expiry has passed, or clear the store when no focus config is armed. A live FULL ticket keeps
  /// it down (same gate as `reapplyBlockConfiguration`); a targeted ticket exempts just the one app.
  private func reapplyFocusConfiguration() {
    let exempt = escapeExemptToken()
    if isSuppressed() && exempt == nil { return }

    // #657: same satisfied guard as the gate layer, on the focus slot/store.
    if consumeSatisfiedLayerIfMarked(satisfiedKey: focusBlockSatisfiedKey,
                                     configKey: focusBlockConfigStorageKey,
                                     target: focusStore,
                                     layer: "focus") { return }

    let defaults = sharedDefaults ?? UserDefaults.standard
    guard let dict = defaults.dictionary(forKey: focusBlockConfigStorageKey) else {
      focusStore.shield.applications = nil
      focusStore.shield.applicationCategories = nil
      focusStore.shield.webDomains = nil
      return
    }
    let expiry = (dict["expiresAtMillis"] as? NSNumber)?.doubleValue ?? 0
    if expiry > 0, Date().timeIntervalSince1970 * 1000.0 >= expiry {
      focusStore.shield.applications = nil
      focusStore.shield.applicationCategories = nil
      focusStore.shield.webDomains = nil
      defaults.removeObject(forKey: focusBlockConfigStorageKey)
      return
    }
    guard let blockConfig = parseBlockConfig(dict) else { return }
    applyBlocks(blockConfig, exempt: exempt, target: focusStore, layer: "focus")
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
    if isInsideAnyScheduleWindow(windows: windows, at: Date()) {
      // Inside a free window → fully open.
      clearScheduleShield()
      defaults.removeObject(forKey: scheduleShieldVariantKey)
    } else {
      // Outside all free windows → shield everything but the allowed apps (minus the escaped app for
      // a targeted ticket). The gap shield always records the "schedule" variant (weekday shield,
      // redirect + escape buttons) — the only schedule shield since #570.
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
      // #588: the JS-supplied per-window `variant` is ignored now (the bedtime preset was removed).
      return MonitorScheduleWindow(startMinute: start, endMinute: end, weekdays: Set(weekdays))
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

  /// #588: true if any free window currently covers `date` (minute-of-day + weekday). #570's
  /// free-window inversion means "inside a window" = fully open, so this is the only distinction the
  /// shield state needs (the old per-window bedtime/weekday variant was removed — it never rendered).
  private func isInsideAnyScheduleWindow(windows: [MonitorScheduleWindow], at date: Date) -> Bool {
    let comps = Calendar.current.dateComponents([.hour, .minute, .weekday], from: date)
    let nowMinute = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    let todayIso = isoWeekday(fromGregorian: comps.weekday ?? 1)
    let yesterdayIso = todayIso == 1 ? 7 : todayIso - 1

    for window in windows where isWindowActive(window, nowMinute: nowMinute, todayIso: todayIso, yesterdayIso: yesterdayIso) {
      return true
    }
    return false
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
      applyAllowlistShield(scheduleStore, allowed: items, layer: "schedule", exempt: exempt)
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
  ///
  /// #661 stage 1: records requested vs decoded app tokens for `layer` (RECORD ONLY — no fail-open
  /// judgement, no threshold; the shield applied is unchanged).
  private func applyAllowlistShield(_ managedStore: ManagedSettingsStore, allowed items: [MonitorBlockedItemInfo], layer: String, exempt: ApplicationToken? = nil) {
    var allowedAppTokens = Set(items.compactMap { $0.appToken })
    let requestedApps = items.filter { $0.type == .app }.count
    writeAllowlistShieldProbe([
      "layer": layer,
      "requestedItems": items.count,
      "requestedApps": requestedApps,
      "decodedApps": allowedAppTokens.count,
      "nonAppItems": items.count - requestedApps,
      "shortfall": max(0, requestedApps - allowedAppTokens.count),
      "hasTicketExempt": exempt != nil,
      "shielded": !allowedAppTokens.isEmpty
    ])
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

  /// Focus-store split: `target` is the layer's own store (gate = default `store`, focus =
  /// `focusStore`), so a recompute for one layer never rewrites the other's shield.
  private func applyBlocks(_ config: MonitorBlockConfig, exempt: ApplicationToken? = nil, target: ManagedSettingsStore, layer: String) {
    guard config.isActive else {
      target.shield.applications = nil
      target.shield.applicationCategories = nil
      target.shield.webDomains = nil
      return
    }

    // #563 allowlist: shield every app except the kept ones (whether iOS also exempts
    // system-essential/controlling apps is pending real-device verification).
    if config.mode == .allow {
      applyAllowlistShield(target, allowed: config.items, layer: layer, exempt: exempt)
      return
    }

    let exemptSet: Set<ApplicationToken> = exempt.map { [$0] } ?? []
    let validAppTokens = config.items.compactMap { $0.appToken }.filter { !exemptSet.contains($0) }
    let validCategoryTokens = config.items.compactMap { $0.categoryToken }
    let validWebDomainTokens = config.items.compactMap { $0.webDomainToken }

    guard !validAppTokens.isEmpty || !validCategoryTokens.isEmpty || !validWebDomainTokens.isEmpty else {
      target.shield.applications = nil
      target.shield.applicationCategories = nil
      target.shield.webDomains = nil
      return
    }

    if !validAppTokens.isEmpty {
      target.shield.applications = Set(validAppTokens)
    } else {
      target.shield.applications = nil
    }

    if !validCategoryTokens.isEmpty {
      target.shield.applicationCategories = .specific(Set(validCategoryTokens))
    } else {
      target.shield.applicationCategories = nil
    }

    if !validWebDomainTokens.isEmpty {
      target.shield.webDomains = Set(validWebDomainTokens)
    } else {
      target.shield.webDomains = nil
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
}
