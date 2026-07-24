import ExpoModulesCore
import FamilyControls
import ManagedSettings
import DeviceActivity
import SwiftUI
import Foundation
import os

public class ExpoAppBlockerModule: Module {
  private let appGroupIdentifier = ExpoAppBlockerConfig.appGroupIdentifier
  // #609: one-line boot log of the RESOLVED app group, so idevicesyslog confirms the module now
  // shares the extensions' real container (not the historical group.<bundleId> ghost).
  private let diagLog = Logger(subsystem: "com.worthyi.chapchu.guardian", category: "module")

  private let authCenter = AuthorizationCenter.shared
  private let store = ManagedSettingsStore()
  // Dedicated store for schedule-window blocking. Kept separate from `store` so the two
  // shield sources union at the system level and clearing one never clears the other
  // (`ManagedSettingsStore.Name` is ExpressibleByStringLiteral). The monitor extension
  // uses the identical name so both processes write the same store.
  private let scheduleStore = ManagedSettingsStore(named: ManagedSettingsStore.Name("appBlocker.schedule"))
  private let activityCenter = DeviceActivityCenter()
  private var sharedDefaults: UserDefaults?
  private let userDefaults = UserDefaults.standard
  private let blockConfigStorageKey = "appBlocker.blockConfiguration.v1"
  // Stores the granted earned-time budget in **seconds** (Int). Presence with a
  // value > 0 means a temporary unlock is active. Enforcement is usage-based: the
  // shield is re-applied by the DeviceActivityMonitor once cumulative foreground
  // usage of the blocked apps reaches the budget (see `startUsageBasedRelock`). The
  // budget pauses when no blocked app is in use and resumes on return.
  private let temporaryUnlockKey = "appBlocker.temporaryUnlock.v1"
  // Consumed seconds of the active unlock, written by the monitor extension as
  // blocked-app usage accrues. Remaining = budget − consumed.
  private let usageConsumedKey = "appBlocker.usageConsumedSeconds.v1"
  // Wall-clock instant the active budget was granted (Date). Used for the daily
  // reset (budget is cleared when the calendar day changes) and as the upper bound
  // for the monitor's premature-fire guard (usage can't exceed elapsed wall-clock).
  private let unlockGrantedAtKey = "appBlocker.unlockGrantedAt.v1"
  private let unlockActivityName = "appBlocker.temporaryUnlock"
  // Schedule-window blocking. The config (windows + blocked items) is persisted here and
  // mirrored into the App Group so the monitor extension can read it. Each window is
  // registered as its own DeviceActivity named "<prefix><index>", never colliding with
  // `unlockActivityName`.
  private let scheduleConfigStorageKey = "appBlocker.scheduleConfiguration.v1"
  private let scheduleActivityPrefix = "appBlocker.scheduleWindow."
  // #525: whether the schedule shield is currently up — set to "schedule" while out of every free
  // window, absent otherwise. Read by ShieldConfiguration to pick the rendered shield. The monitor is
  // the usual writer; the module also writes it when it re-applies the schedule (gap) shield itself —
  // see `reevaluateScheduleShieldFromPersisted` (#601). (#588: the value is always "schedule" now —
  // #570 removed the bedtime preset.) Absent = no schedule shield → default shield.
  private let scheduleShieldVariantKey = "appBlocker.scheduleShieldVariant.v1"
  // Immediate-block wall-clock expiry (#535). When `setBlockConfiguration` carries
  // `expiresAtMillis`, one DeviceActivity fires at that instant and the monitor extension lifts
  // the immediate shield — a kill-proof release guarantee mirroring Android's `expiresAtMillis`.
  // The interval's START is the expiry instant (intervalDidStart), so short blocks work despite
  // DeviceActivity's ~15-minute minimum interval length (only the start boundary matters).
  private let immediateExpiryActivityName = "appBlocker.immediateExpiry"
  // G5 escape ticket (#572). A wall-clock suppression window independent of EVERY lock layer
  // (immediate / schedule / focus / earn): while `now < suppressionUntil`, both shields stay down —
  // "차단됨 = 잠금 AND NOT 유효티켓" in the door-state formula. At the instant a one-shot
  // DeviceActivity fires and the monitor recomputes the shields from the persisted config
  // (kill-proof, mirroring the immediate-expiry backstop). Persisted in the App Group too so the
  // monitor extension can read it. Absent key = never suppressed = original behavior (back-compat).
  private let suppressionUntilKey = "appBlocker.suppressionUntil.v1"
  private let suppressionExpiryActivityName = "appBlocker.suppressionExpiry"
  // #607 diagnostics: the module records here whether it REGISTERED the suppression-expiry
  // DeviceActivity (and its schedule params); the monitor overwrites it with the FIRED outcome. So at
  // inspection: still "registered" = iOS never fired the callback; a "fired" phase = it fired. Written
  // to the App Group container file (durable) — see writeSuppressionExpiryProbe.
  private let suppressionExpiryProbeFileName = "suppressionExpiryProbe.json"
  // #614: same registered/fired probe for the immediate (gate/focus) wall-clock expiry.
  private let immediateExpiryProbeFileName = "immediateExpiryProbe.json"
  // #598 targeted escape ticket. The ShieldAction records the ApplicationToken the user pressed
  // "지금 필요해" on into `escapeTargetTokenKey` (+ a timestamp for freshness). `suppressBlocks`
  // consumes it and, when fresh, promotes it to `suppressionTargetTokenKey` — the ONE app that stays
  // open for the ticket while every other blocked app remains shielded (added to each store's
  // allow-except set). Absent/stale capture (web/category shield) → the ticket lowers everything
  // (the original full-suppression behavior), so back-compat is preserved.
  private let escapeTargetTokenKey = "appBlocker.escapeTargetToken.v1"
  private let escapeTargetTokenTsKey = "appBlocker.escapeTargetTokenTs.v1"
  private let suppressionTargetTokenKey = "appBlocker.suppressionTargetToken.v1"
  private let escapeTargetTokenMaxAgeMs: Double = 5 * 60 * 1000
  // DeviceActivity requires a monitored interval to be at least ~15 minutes. A
  // cross-midnight split fragment shorter than this is skipped (the evaluator still
  // corrects the shield at the next boundary that fires).
  private let minScheduleIntervalMinutes = 15
  // Sub-minute usage steps. We register one DeviceActivityEvent per `usageStepSeconds`
  // of the budget (threshold = k×step seconds of measured usage). Each step's
  // eventDidReachThreshold lets the monitor write consumed SECONDS back to the App
  // Group. The event name carries its threshold (`appBlocker.usageStep.<seconds>`).
  private let usageStepEventPrefix = "appBlocker.usageStep."
  // Apple's usage thresholds are coarse/unreliable below ~a minute; 30s is a best-
  // effort finer grain backstopped by later steps and the final (== budget) event.
  private let usageStepSeconds = 30
  // Cap on registered step events; the step auto-coarsens for large budgets so the
  // event count stays under this (Apple degrades with too many events).
  private let maxUsageSteps = 60
  private let pendingUnlockKey = "appBlocker.pendingUnlock.v1"
  private let pendingInterceptsKey = "appBlocker.pendingIntercepts.v1"
  private let minimumTemporaryUnlockMinutes = 1
  private var didLoadPersistedConfig = false

  private var currentBlockConfig: BlockConfig?
  private let stateQueue = DispatchQueue(label: "expo.appblocker.state", qos: .userInitiated)
  private let scheduleLock = NSLock()
  private var isProcessingUnlockState = false

  public func definition() -> ModuleDefinition {
    Name("ExpoAppBlocker")

    Events("onPendingUnlockRequest")

    // #535: whether THIS binary bundles the guardian Family Controls extensions. Lets the JS
    // exposure gate (#541) tell a guardian-capable build from one where the .appex were not
    // attached (the extensions ship only on the internal variant), independent of the OTA JS
    // bundle. Android has no separate extension — the blocker is compiled in — so it is `true`.
    Constants([
      "guardianExtensionAttached": self.hasGuardianExtension()
    ])

    // Native view that renders blocked app tokens with real names and icons
    View(BlockedAppsView.self) {
      // #602: a row's minus button emits { index, token, type } for RN to remove from its SSOT — the
      // view never mutates registration itself (JS owns the allowed-apps list). The `tokens` path
      // preserves the exact base64 tokenId RN passed, so RN can match the removed item precisely.
      Events("onRemoveItem")

      // `tokens` is the primary data source; `selectionData` is a legacy alternative. Expo applies
      // the two prop setters in a non-deterministic order, so an EMPTY selectionData must be a no-op —
      // clearing here would clobber the tokens the other setter just wrote (the observed intermittent
      // empty list, since the registry always passes selectionData="" alongside tokens).
      Prop("selectionData") { (view: BlockedAppsView, selectionBase64: String) in
        guard !selectionBase64.isEmpty,
              let data = Data(base64Encoded: selectionBase64),
              let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
        else { return }
        view.setItemsFromSelection(selection)
      }

      Prop("tokens") { (view: BlockedAppsView, tokens: [[String: String]]) in
        view.setItemsFromTokens(tokens)
      }

      // #602: render a per-row remove (minus) button. Default false keeps the render-only look for
      // any caller that just wants the labelled list.
      Prop("removable") { (view: BlockedAppsView, removable: Bool) in
        view.viewModel.removable = removable
      }
    }

    OnCreate {
      self.sharedDefaults = UserDefaults(suiteName: self.appGroupIdentifier)
      // #609: confirm module ↔ extension container alignment on the next device round. containerNil=true
      // means the resolved group is not entitled (still the ghost) — file handoffs would be no-ops.
      let containerNil = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: self.appGroupIdentifier) == nil
      self.diagLog.log("boot appGroup=\(self.appGroupIdentifier, privacy: .public) containerNil=\(containerNil, privacy: .public)")
      self.setupUnlockNotificationObserver()

      self.stateQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
        self?.checkAndApplyUnlockState()
      }
    }

    AsyncFunction("requestAuthorization") { (promise: Promise) in
      Task {
        do {
          try await self.authCenter.requestAuthorization(for: .individual)
          let status = self.getAuthStatus()
          promise.resolve([
            "authorized": status.authorized,
            "status": status.statusString
          ])
        } catch {
          promise.resolve([
            "authorized": false,
            "status": "denied"
          ])
        }
      }
    }

    Function("getAuthorizationStatus") {
      let status = self.getAuthStatus()
      return [
        "authorized": status.authorized,
        "status": status.statusString
      ]
    }

    AsyncFunction("presentFamilyActivityPicker") { (promise: Promise) in
      DispatchQueue.main.async {
        self.ensureLoadedPersistedConfig()

        guard self.authCenter.authorizationStatus == .approved else {
          promise.reject("NOT_AUTHORIZED", "Family Controls authorization not granted")
          return
        }

        let initialAppTokens = Set(self.currentBlockConfig?.items.compactMap { $0.appToken } ?? [])
        let initialCategoryTokens = Set(self.currentBlockConfig?.items.compactMap { $0.categoryToken } ?? [])
        // Scoped, weak handle to the picker's own controller. The exit paths
        // must dismiss ONLY this controller — never rootVC.dismiss(), which
        // collapses an RN modal (e.g. SettingsModal) presented beneath the
        // picker and desyncs React Native's modal bookkeeping (touches freeze
        // until app restart). weakHost is assigned after the controller exists.
        var weakHost: () -> UIViewController? = { nil }
        let dismissPicker: (@escaping () -> Void) -> Void = { completion in
          DispatchQueue.main.async {
            if let host = weakHost() {
              host.dismiss(animated: true, completion: completion)
            } else {
              completion()
            }
          }
        }

        let pickerView = FamilyActivityPickerView(
          initialApplicationTokens: initialAppTokens,
          initialCategoryTokens: initialCategoryTokens,
          promise: promise,
          dismissPicker: dismissPicker
        )
        let hostingController = UIHostingController(rootView: pickerView)
        weakHost = { [weak hostingController] in hostingController }

        if let rootVC = self.getRootViewController() {
          // Present on the topmost presented controller so the picker stacks
          // above any RN modal rather than under it.
          var topVC = rootVC
          while let presented = topVC.presentedViewController {
            topVC = presented
          }
          hostingController.modalPresentationStyle = .formSheet
          topVC.present(hostingController, animated: true)
        } else {
          promise.reject("NO_ROOT_VC", "Could not find root view controller")
        }
      }
    }

    AsyncFunction("setBlockConfiguration") { (config: [String: Any], promise: Promise) in
      self.stateQueue.async {
        do {
          self.ensureLoadedPersistedConfig()
          let blockConfig = try self.parseBlockConfig(config)
          self.currentBlockConfig = blockConfig
          try self.applyBlocks(blockConfig)
          self.persistBlockConfiguration(config)
          // #535: (re)arm or cancel the wall-clock expiry DeviceActivity for this config.
          self.updateImmediateExpiryMonitoring(blockConfig)

          DispatchQueue.main.async {
            promise.resolve(nil)
          }
        } catch {
          DispatchQueue.main.async {
            promise.reject("CONFIG_ERROR", "Failed to set block configuration: \(error.localizedDescription)")
          }
        }
      }
    }

    Function("getBlockConfiguration") { () -> [String: Any]? in
      self.ensureLoadedPersistedConfig()

      guard let config = self.currentBlockConfig else {
        return nil
      }
      return self.serializeBlockConfig(config)
    }

    // Tear down the IMMEDIATE (gate/focus) block — the immediate `store` shield and its persisted
    // config only. This is the JS `releaseLock('gate'|'focus')` native path; the schedule store and
    // its config are a separate layer with their own teardown (`clearScheduleConfiguration`).
    //
    // #601 ticket-restore leak: the escape ticket (suppression) is layer-agnostic — it also lowered
    // the SCHEDULE shield. Blindly `clearSuppressionState()` here cancels the suppression-expiry
    // DeviceActivity (the kill-proof backstop that re-applies the schedule shield at ticket expiry)
    // and orphans the schedule shield DOWN even though we are outside every free window. So branch:
    //   · ticket still live → preserve the ticket, its expiry activity, and the schedule config; the
    //     backstop restores the schedule shield when the ticket ends (respect the ticket's lifetime).
    //   · no live ticket → drop any stale ticket and recompute the schedule shield from the persisted
    //     config by wall-clock now (restore it if we are outside every free window).
    // In BOTH branches the immediate config is removed, so a suppression-expiry recompute never
    // re-arms a gate whose session already ended (satisfied) — it only restores the schedule.
    Function("clearAllBlocks") {
      self.stateQueue.async {
        self.ensureLoadedPersistedConfig()
        self.cancelRelockActivity()
        self.cancelImmediateExpiryActivity()  // #535: drop any pending wall-clock expiry
        self.store.shield.applications = nil
        self.store.shield.applicationCategories = nil
        self.store.shield.webDomains = nil
        self.currentBlockConfig = nil
        self.userDefaults.removeObject(forKey: self.blockConfigStorageKey)
        self.sharedDefaults?.removeObject(forKey: self.blockConfigStorageKey)
        self.clearUnlockState()

        if self.isSuppressedInternal() {
          // Ticket still live — leave suppression state + its expiry DeviceActivity + the persisted
          // schedule config untouched. The monitor's suppression-expiry backstop re-applies the
          // schedule shield from config when the ticket ends. (Do NOT clearSuppressionState here.)
        } else {
          self.clearSuppressionState()
          self.reevaluateScheduleShieldFromPersisted()
        }
      }
    }

    Function("checkAndClearPendingUnlock") { () -> Bool in
      guard let defaults = self.sharedDefaults else { return false }
      let hasPending = defaults.bool(forKey: self.pendingUnlockKey)
      if hasPending {
        defaults.removeObject(forKey: self.pendingUnlockKey)
        defaults.synchronize()
      }
      return hasPending
    }

    Function("drainPendingIntercepts") { () -> [[String: Any]] in
      guard let defaults = self.sharedDefaults else { return [] }
      // Refresh the cached suite so writes made by the (separate) shield
      // extension process are visible to this long-lived app process.
      defaults.synchronize()
      var queue: [[String: Any]] = []
      if let json = defaults.string(forKey: self.pendingInterceptsKey),
         let data = json.data(using: .utf8),
         let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
        queue = parsed
      }
      if defaults.string(forKey: self.pendingInterceptsKey) != nil {
        defaults.removeObject(forKey: self.pendingInterceptsKey)
        defaults.synchronize()
      }
      return queue
    }

    Function("isAppBlocked") { (bundleIdentifier: String) -> Bool in
      self.ensureLoadedPersistedConfig()
      guard let config = self.currentBlockConfig else {
        return false
      }
      return config.items.contains { $0.bundleIdentifier == bundleIdentifier }
    }

    AsyncFunction("temporaryUnlock") { (durationMinutes: Int, promise: Promise) in
      self.stateQueue.async {
        self.ensureLoadedPersistedConfig()
        let sanitizedDurationMinutes = max(self.minimumTemporaryUnlockMinutes, durationMinutes)

        guard let config = self.currentBlockConfig, config.isActive else {
          DispatchQueue.main.async {
            promise.reject("NO_ACTIVE_BLOCKS", "No active blocks to unlock")
          }
          return
        }

        // Usage-based budget is the source of truth: the grant is spent only while a
        // blocked app is in the foreground, so it pauses on leave and resumes on
        // return. (See `startUsageBasedRelock`.) The budget is cleared at midnight.
        let budgetSeconds = sanitizedDurationMinutes * 60
        let grantedAt = Date()
        self.sharedDefaults?.set(budgetSeconds, forKey: self.temporaryUnlockKey)
        self.sharedDefaults?.set(0, forKey: self.usageConsumedKey)
        self.sharedDefaults?.set(grantedAt, forKey: self.unlockGrantedAtKey)

        DispatchQueue.main.async {
          self.store.shield.applications = nil
          self.store.shield.applicationCategories = nil
          self.store.shield.webDomains = nil
        }

        // Arm usage-threshold monitoring so the monitor re-blocks once measured
        // blocked-app usage reaches the budget. Non-fatal if it can't start — the
        // host-side relock (getRemainingUnlockTime poll / foreground check) is a
        // backstop once the monitor reports consumption.
        do {
          try self.startUsageBasedRelock(budgetSeconds: budgetSeconds)
        } catch {
          print("[AppBlocker] startUsageBasedRelock failed: \(error.localizedDescription)")
        }

        DispatchQueue.main.async {
          promise.resolve([
            "unlocked": true,
            "expiresAt": grantedAt.addingTimeInterval(TimeInterval(budgetSeconds)).timeIntervalSince1970
          ])
        }
      }
    }

    Function("isTemporarilyUnlocked") { () -> Bool in
      return self.remainingUnlockSeconds() > 0
    }

    // Remaining earned-time seconds = granted budget − measured blocked-app usage.
    // Stays flat while no blocked app is in use (the budget pauses on leave) and
    // drops as the monitor reports consumption. When the host polls this (e.g. the
    // blocking-status banner) and it has reached 0 — budget spent or the day rolled
    // over — the shield is re-applied as a backstop to the monitor.
    Function("getRemainingUnlockTime") { () -> Int in
      let hadBudget = ((self.sharedDefaults?.object(forKey: self.temporaryUnlockKey) as? Int) ?? 0) > 0
      let remaining = self.remainingUnlockSeconds()
      if remaining > 0 {
        return remaining
      }
      if hadBudget {
        self.relockApps()
      }
      return 0
    }

    AsyncFunction("relockApps") { (promise: Promise) in
      self.stateQueue.async {
        self.relockApps()

        DispatchQueue.main.async {
          promise.resolve(["locked": true])
        }
      }
    }

    // MARK: Escape ticket suppression (#572)

    // Suppress ALL blocking (immediate + schedule) until `untilMillis` (epoch ms), independent of
    // every lock layer, then auto-re-apply from the stored config. Distinct from `temporaryUnlock`
    // (earn): that is usage-based and never touches the schedule store; this is a wall-clock window
    // that lowers BOTH stores and is re-applied by the monitor at the expiry instant (kill-proof).
    AsyncFunction("suppressBlocks") { (untilMillis: Double, promise: Promise) in
      self.stateQueue.async {
        self.ensureLoadedPersistedConfig()
        let nowMillis = Date().timeIntervalSince1970 * 1000.0
        // Already-expired / absent target = no-op: never lower a shield without a live window.
        guard untilMillis > nowMillis else {
          DispatchQueue.main.async {
            promise.resolve(["active": false, "untilMillis": 0, "remainingMs": 0])
          }
          return
        }

        self.sharedDefaults?.set(untilMillis, forKey: self.suppressionUntilKey)
        self.userDefaults.set(untilMillis, forKey: self.suppressionUntilKey)

        // #598: promote the ShieldAction-captured app (if fresh) to this ticket's target. Present →
        // targeted ticket (open only that app); absent/stale → full-suppression ticket (open all).
        if let encoded = self.consumeFreshEscapeTargetTokenEncoded() {
          self.sharedDefaults?.set(encoded, forKey: self.suppressionTargetTokenKey)
          self.userDefaults.set(encoded, forKey: self.suppressionTargetTokenKey)
        } else {
          self.sharedDefaults?.removeObject(forKey: self.suppressionTargetTokenKey)
          self.userDefaults.removeObject(forKey: self.suppressionTargetTokenKey)
        }

        // Re-apply both shields for the new ticket state. `escapeExemptToken()` now reflects the
        // target (targeted → keep every store's shield up minus that one app) or nil (full → the
        // gates in applyBlocks / reevaluateScheduleShieldFromPersisted lower both stores).
        if let config = self.currentBlockConfig {
          try? self.applyBlocks(config)
        } else {
          self.store.shield.applications = nil
          self.store.shield.applicationCategories = nil
          self.store.shield.webDomains = nil
        }
        self.reevaluateScheduleShieldFromPersisted()

        // Kill-proof re-application: a one-shot DeviceActivity fires at the expiry instant and the
        // monitor recomputes the shields from the persisted config (RN timers must not re-lock).
        self.updateSuppressionExpiryMonitoring(untilMillis: untilMillis)

        DispatchQueue.main.async {
          promise.resolve([
            "active": true,
            "untilMillis": untilMillis,
            "remainingMs": Int(untilMillis - nowMillis)
          ])
        }
      }
    }

    // Current escape-ticket state (remaining ms) for the door card '열림 · 타이머 N분' display. An
    // already-expired ticket reads back inactive.
    Function("getSuppressionState") { () -> [String: Any] in
      return self.suppressionState()
    }

    // MARK: Schedule-window blocking

    AsyncFunction("setScheduleConfiguration") { (config: [String: Any], promise: Promise) in
      self.stateQueue.async {
        self.applyScheduleConfiguration(config)
        self.persistScheduleConfiguration(config)
        DispatchQueue.main.async {
          promise.resolve(nil)
        }
      }
    }

    Function("clearScheduleConfiguration") {
      self.stateQueue.async {
        self.clearScheduleConfigurationInternal()
      }
    }

    Function("getScheduleConfiguration") { () -> [String: Any]? in
      return self.userDefaults.dictionary(forKey: self.scheduleConfigStorageKey)
    }
  }

  // MARK: - Guardian binary capability (#535)

  /// Does THIS binary actually bundle the guardian Family Controls extensions? The shield/monitor
  /// `.appex` live under the app bundle's PlugIns dir only when the (internal) variant built them
  /// in — a fact of the native binary, independent of the JS/OTA bundle. Presence of the
  /// ShieldConfiguration extension is the marker; the exposure gate (#541) reads it via the
  /// `guardianExtensionAttached` constant.
  private func hasGuardianExtension() -> Bool {
    guard let pluginsURL = Bundle.main.builtInPlugInsURL,
          let contents = try? FileManager.default.contentsOfDirectory(
            at: pluginsURL, includingPropertiesForKeys: nil) else {
      return false
    }
    return contents.contains {
      $0.pathExtension == "appex" && $0.lastPathComponent.contains("ShieldConfiguration")
    }
  }

  // MARK: - Authorization

  private func getAuthStatus() -> (authorized: Bool, statusString: String) {
    let status = authCenter.authorizationStatus
    switch status {
    case .notDetermined:
      return (false, "notDetermined")
    case .denied:
      return (false, "denied")
    case .approved:
      return (true, "approved")
    @unknown default:
      return (false, "denied")
    }
  }

  private func getRootViewController() -> UIViewController? {
    if let currentVC = appContext?.utilities?.currentViewController() {
      return currentVC
    }

    let scenes = UIApplication.shared.connectedScenes
    let windowScene = scenes.first as? UIWindowScene
    let window = windowScene?.windows.first
    return window?.rootViewController
  }

  // MARK: - Darwin Notification Observer

  private func setupUnlockNotificationObserver() {
    let notificationCenter = CFNotificationCenterGetDarwinNotifyCenter()
    let observer = Unmanaged.passUnretained(self).toOpaque()

    let legacyName = "expo.appblocker.temporaryUnlock" as CFString
    CFNotificationCenterAddObserver(
      notificationCenter,
      observer,
      { (_, observer, _, _, _) in
        guard let observer else { return }
        let module = Unmanaged<ExpoAppBlockerModule>.fromOpaque(observer).takeUnretainedValue()
        module.stateQueue.async {
          module.checkAndApplyUnlockState()
        }
      },
      legacyName,
      nil,
      .deliverImmediately
    )

    let pendingName = "expo.appblocker.pendingUnlock" as CFString
    CFNotificationCenterAddObserver(
      notificationCenter,
      observer,
      { (_, observer, _, _, _) in
        guard let observer else { return }
        let module = Unmanaged<ExpoAppBlockerModule>.fromOpaque(observer).takeUnretainedValue()
        module.handlePendingUnlockRequest()
      },
      pendingName,
      nil,
      .deliverImmediately
    )
  }

  private func handlePendingUnlockRequest() {
    DispatchQueue.main.async {
      self.sendEvent("onPendingUnlockRequest", [:])
    }
  }

  // MARK: - Unlock State

  private func checkAndApplyUnlockState() {
    guard !isProcessingUnlockState else {
      return
    }

    isProcessingUnlockState = true
    defer { isProcessingUnlockState = false }

    ensureLoadedPersistedConfig()

    let budgetSeconds = (sharedDefaults?.object(forKey: temporaryUnlockKey) as? Int) ?? 0
    if budgetSeconds > 0 {
      if remainingUnlockSeconds() > 0 {
        // Budget still available (and the day hasn't rolled over) — keep the shield
        // off. Do NOT re-arm monitoring here: DeviceActivity monitoring is system-
        // level and survives app termination, so the schedule registered at grant
        // time is still running. Re-registering would restart the usage interval at
        // "now" and discard accrued usage — letting a user reset their budget by
        // bouncing back to this app. The monitor re-blocks on its own once usage
        // reaches the budget; this branch only ensures the shield stays off.
        DispatchQueue.main.async {
          self.store.shield.applications = nil
          self.store.shield.applicationCategories = nil
          self.store.shield.webDomains = nil
        }
      } else {
        // Budget spent or cleared by the daily reset.
        relockApps()
      }
    } else if let config = currentBlockConfig {
      do {
        try applyBlocks(config)
      } catch {
      }
    }
  }

  // MARK: - Block Configuration

  private func parseBlockConfig(_ dict: [String: Any]) throws -> BlockConfig {
    // #563 allowlist mode: `mode == "allow"` reinterprets the item set as the apps to KEEP OPEN;
    // every other app is shielded. Absent/"block" → the original denylist (shield the listed apps).
    let mode: BlockMode = (dict["mode"] as? String) == "allow" ? .allow : .block

    let rawItems: [[String: Any]]
    // In allow mode the kept apps ride under `allowedItems`; in block mode under `blockedItems`.
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
      // Allow mode with no kept apps: valid shape (the app gates 0 → no lock), no items.
      rawItems = []
    } else {
      throw NSError(domain: "AppBlocker", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing blockedItems"])
    }

    let items = makeBlockedItems(from: rawItems)

    let isActive = dict["isActive"] as? Bool ?? true

    var schedule: ScheduleInfo?
    if let scheduleDict = dict["schedule"] as? [String: Any] {
      schedule = ScheduleInfo(
        intervalStart: scheduleDict["intervalStart"] as? Int ?? 0,
        intervalEnd: scheduleDict["intervalEnd"] as? Int ?? 24,
        repeats: scheduleDict["repeats"] as? Bool ?? true,
        warningTime: scheduleDict["warningTime"] as? Int ?? 5
      )
    }

    // #535: wall-clock expiry (epoch millis). JS may send it as any JSON number, so read via
    // NSNumber. Absent → nil (no expiry, back-compat with callers that don't pass it).
    let expiresAtMillis = (dict["expiresAtMillis"] as? NSNumber)?.doubleValue

    return BlockConfig(items: items, isActive: isActive, schedule: schedule, expiresAtMillis: expiresAtMillis, mode: mode)
  }

  /// Decode an array of raw item dicts (the `blockedItems` shape shared by immediate and
  /// schedule configs) into typed `BlockedItemInfo`s.
  private func makeBlockedItems(from rawItems: [[String: Any]]) -> [BlockedItemInfo] {
    return rawItems.compactMap { selection -> BlockedItemInfo? in
      guard let tokenString = selection["token"] as? String else {
        return nil
      }

      let itemTypeRaw = (selection["type"] as? String ?? "app").lowercased()
      let itemType: BlockedItemType
      switch itemTypeRaw {
      case "category":
        itemType = .category
      case "webdomain":
        itemType = .webDomain
      default:
        itemType = .app
      }

      return BlockedItemInfo(
        type: itemType,
        tokenId: tokenString,
        appToken: itemType == .app ? self.decodeApplicationToken(from: tokenString) : nil,
        categoryToken: itemType == .category ? self.decodeCategoryToken(from: tokenString) : nil,
        webDomainToken: itemType == .webDomain ? self.decodeWebDomainToken(from: tokenString) : nil,
        bundleIdentifier: selection["bundleIdentifier"] as? String,
        displayName: selection["displayName"] as? String,
        categoryName: selection["categoryName"] as? String,
        domain: selection["domain"] as? String,
        iconBase64: selection["iconBase64"] as? String
      )
    }
  }

  private func applyBlocks(_ config: BlockConfig) throws {
    guard config.isActive else {
      store.shield.applications = nil
      store.shield.applicationCategories = nil
      store.shield.webDomains = nil
      return
    }

    // #535: immediate-block wall-clock expiry backstop (mirrors Android's `isImmediateBlocked`
    // wall-clock gate). If the configured expiry has passed, treat the block as released — clear
    // the shield AND drop the persisted config so a killed-app relaunch (ensureLoadedPersistedConfig)
    // never re-applies an expired block. The monitor extension is the kill-proof path; this covers
    // the case where the app comes back to the foreground after expiry.
    if let expiry = config.expiresAtMillis, expiry > 0,
       Date().timeIntervalSince1970 * 1000.0 >= expiry {
      store.shield.applications = nil
      store.shield.applicationCategories = nil
      store.shield.webDomains = nil
      cancelImmediateExpiryActivity()
      currentBlockConfig = nil
      userDefaults.removeObject(forKey: blockConfigStorageKey)
      sharedDefaults?.removeObject(forKey: blockConfigStorageKey)
      return
    }

    if isTemporarilyUnlockedInternal() {
      store.shield.applications = nil
      store.shield.applicationCategories = nil
      store.shield.webDomains = nil
      return
    }

    // #572/#598: a live escape ticket suppresses the immediate shield (layer-agnostic). A plain
    // (full) ticket keeps it fully down; a TARGETED ticket (#598) instead exempts just the one
    // escaped app below and leaves the rest shielded, so it does NOT take the full-lower path.
    let exempt = escapeExemptToken()
    if isSuppressedInternal() && exempt == nil {
      store.shield.applications = nil
      store.shield.applicationCategories = nil
      store.shield.webDomains = nil
      return
    }

    // #563 allowlist: shield every app EXCEPT the kept (allowed) ones. The except-set is the user's
    // allowed apps; whether Family Controls also implicitly exempts system-essential apps
    // (Phone/Settings/…) and the controlling app is **pending real-device verification** (see the
    // PR's manual-check list), so no explicit exception list is added here.
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

  private func relockApps() {
    clearUnlockState()
    cancelRelockActivity()
    ensureLoadedPersistedConfig()

    guard let config = currentBlockConfig else {
      return
    }

    do {
      try applyBlocks(config)
    } catch {
    }
  }

  // MARK: - Activity Scheduling

  /// Start usage-based monitoring: re-apply the shield once cumulative foreground
  /// usage of the blocked apps reaches `budgetSeconds`. iOS counts only active usage,
  /// so the budget naturally pauses when the apps aren't in use and resumes on return.
  ///
  /// We register a series of threshold events stepping by `usageStepSeconds` (auto-
  /// coarsened so the count stays under `maxUsageSteps`). The event name carries its
  /// threshold in seconds (`usageStepEventPrefix + <seconds>`). Each step's
  /// `eventDidReachThreshold` (in the DeviceActivityMonitor extension) writes the
  /// consumed-second count to the App Group — giving the host app a sub-minute,
  /// pause-when-away consumed counter (`getRemainingUnlockTime`). The final step
  /// (== budget) is where the monitor re-applies the shield.
  ///
  /// The interval ends at 23:59:59 so the monitor's `intervalDidEnd` clears any
  /// unspent budget at the day boundary (earned time does not carry across midnight).
  /// `repeats: false` because we re-register on every unlock.
  ///
  /// Note: Apple's usage thresholds are coarse/unreliable below ~a minute, so the
  /// finest steps may fire late or be skipped — later steps and the final threshold
  /// still re-block, bounding overshoot to roughly one step.
  private func startUsageBasedRelock(budgetSeconds: Int) throws {
    scheduleLock.lock()
    defer { scheduleLock.unlock() }

    cancelRelockActivityLocked()

    guard let config = currentBlockConfig else {
      print("[AppBlocker] startUsageBasedRelock: no active config, monitoring not started")
      return
    }
    let appTokens = Set(config.items.compactMap { $0.appToken })
    let categoryTokens = Set(config.items.compactMap { $0.categoryToken })
    let webDomainTokens = Set(config.items.compactMap { $0.webDomainToken })

    guard !appTokens.isEmpty || !categoryTokens.isEmpty || !webDomainTokens.isEmpty else {
      print("[AppBlocker] startUsageBasedRelock: no blockable tokens, monitoring not started")
      return
    }

    let budget = max(1, budgetSeconds)
    // Step by usageStepSeconds, but coarsen so we never exceed maxUsageSteps events.
    let step = max(usageStepSeconds, Int(ceil(Double(budget) / Double(maxUsageSteps))))
    var thresholds: [Int] = []
    var t = step
    while t < budget {
      thresholds.append(t)
      t += step
    }
    thresholds.append(budget) // always include the exact budget as the final re-block

    var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
    for seconds in thresholds {
      events[DeviceActivityEvent.Name("\(usageStepEventPrefix)\(seconds)")] = DeviceActivityEvent(
        applications: appTokens,
        categories: categoryTokens,
        webDomains: webDomainTokens,
        threshold: dateComponents(fromSeconds: seconds)
      )
    }

    // CRITICAL: the interval must start ~now, not at midnight. DeviceActivityEvent
    // thresholds measure usage accumulated *within the interval, from its start*. An
    // all-day [00:00, 23:59] interval would count usage since midnight — so any prior
    // blocked-app use today would have already crossed the thresholds before monitoring
    // began, and the system never fires a (new) crossing → the shield never re-applies.
    // Starting the interval at the current time makes thresholds count from the unlock
    // moment. repeats:false because we re-register on every unlock.
    let now = Date()
    let startComps = Calendar.current.dateComponents([.hour, .minute, .second], from: now)
    let schedule = DeviceActivitySchedule(
      intervalStart: startComps,
      intervalEnd: DateComponents(hour: 23, minute: 59, second: 59),
      repeats: false
    )

    try activityCenter.startMonitoring(
      DeviceActivityName(unlockActivityName),
      during: schedule,
      events: events
    )
  }

  private func cancelRelockActivity() {
    scheduleLock.lock()
    defer { scheduleLock.unlock() }
    cancelRelockActivityLocked()
  }

  private func cancelRelockActivityLocked() {
    let activityName = DeviceActivityName(unlockActivityName)
    activityCenter.stopMonitoring([activityName])
  }

  // MARK: - Immediate-Block Wall-Clock Expiry (#535)

  /// (Re)arm or cancel the wall-clock expiry DeviceActivity for the current immediate block. A
  /// DeviceActivity fires at the expiry instant so the monitor extension lifts the shield even if
  /// the host app is force-quit — the iOS analogue of Android's `expiresAtMillis` backstop.
  private func updateImmediateExpiryMonitoring(_ config: BlockConfig) {
    cancelImmediateExpiryActivity()
    guard config.isActive, let expiry = config.expiresAtMillis, expiry > 0 else { return }
    let expiryDate = Date(timeIntervalSince1970: expiry / 1000.0)
    let now = Date()
    guard expiryDate > now else { return }  // already past — applyBlocks handled the release
    // Same-day only: a DeviceActivitySchedule interval is a time-of-day window, so a next-day
    // expiry can't be expressed as a reliable one-shot. Cross-midnight focus sessions are rare;
    // the app-foreground expiry gate (applyBlocks) clears the block on next launch as the fallback.
    guard Calendar.current.isDate(expiryDate, inSameDayAs: now) else {
      print("[AppBlocker] immediate-expiry crosses midnight — relying on foreground clear")
      return
    }
    startImmediateExpiryMonitoring(expiresAt: expiryDate)
  }

  /// Register a one-shot DeviceActivity whose interval STARTS at the expiry instant. Only the
  /// start boundary matters (the monitor's `intervalDidStart` lifts the block there), so a short
  /// block still works despite DeviceActivity's ~15-minute minimum interval length — we pad the
  /// interval past that minimum. An expiry within ~16 min of midnight can't fit a non-wrapping
  /// ≥15-min window, so it falls back to the app-foreground clear.
  private func startImmediateExpiryMonitoring(expiresAt: Date) {
    scheduleLock.lock()
    defer { scheduleLock.unlock() }

    // #614: DeviceActivity is minute-granular, so an intervalStart carrying seconds makes iOS fire
    // intervalDidStart at the minute FLOOR — before the true expiry — and expireImmediateBlockIfDue
    // then rejects it (now < expiry) with the one-shot never firing again (same not-due silence #607
    // fixed for suppression-expiry). Round the start UP to the minute at/after expiry.
    let comps = Calendar.current.dateComponents([.hour, .minute, .second], from: expiresAt)
    let expiryMinute = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    let startMinute = (comps.second ?? 0) > 0 ? expiryMinute + 1 : expiryMinute
    let endMinute = startMinute + minScheduleIntervalMinutes + 1
    guard startMinute <= 23 * 60 + 59, endMinute <= 23 * 60 + 59 else {
      print("[AppBlocker] immediate-expiry within ~16m of midnight — relying on foreground clear")
      writeImmediateExpiryProbe(["phase": "register-skipped-midnight", "startMinute": startMinute])
      return
    }
    let schedule = DeviceActivitySchedule(
      intervalStart: scheduleTimeComponents(minuteOfDay: startMinute),
      intervalEnd: scheduleTimeComponents(minuteOfDay: endMinute),
      repeats: false
    )
    do {
      try activityCenter.startMonitoring(
        DeviceActivityName(immediateExpiryActivityName),
        during: schedule,
        events: [:]
      )
      writeImmediateExpiryProbe([
        "phase": "registered",
        "startMinute": startMinute,
        "endMinute": endMinute,
        "untilMs": Int64(expiresAt.timeIntervalSince1970 * 1000.0)
      ])
    } catch {
      print("[AppBlocker] immediate-expiry startMonitoring failed: \(error.localizedDescription)")
      writeImmediateExpiryProbe(["phase": "register-failed", "error": "\(error)"])
    }
  }

  private func cancelImmediateExpiryActivity() {
    scheduleLock.lock()
    defer { scheduleLock.unlock() }
    activityCenter.stopMonitoring([DeviceActivityName(immediateExpiryActivityName)])
  }

  // MARK: - Escape Ticket Suppression (#572)

  /// The current escape-ticket state: `active` (a live window), `untilMillis` (the wall-clock end),
  /// and `remainingMs`. Reads back inactive once the window has passed (self-cleaning for the host).
  private func suppressionState() -> [String: Any] {
    let until = (sharedDefaults?.object(forKey: suppressionUntilKey) as? NSNumber)?.doubleValue
      ?? (userDefaults.object(forKey: suppressionUntilKey) as? NSNumber)?.doubleValue ?? 0
    let nowMillis = Date().timeIntervalSince1970 * 1000.0
    let remaining = until - nowMillis
    if until <= 0 || remaining <= 0 {
      return ["active": false, "untilMillis": 0, "remainingMs": 0]
    }
    return ["active": true, "untilMillis": until, "remainingMs": Int(remaining)]
  }

  /// True while an escape ticket is live (`now < suppressionUntil`). The shield-apply paths gate on
  /// this so a ticket keeps every shield down regardless of the lock layers.
  private func isSuppressedInternal() -> Bool {
    let until = (sharedDefaults?.object(forKey: suppressionUntilKey) as? NSNumber)?.doubleValue
      ?? (userDefaults.object(forKey: suppressionUntilKey) as? NSNumber)?.doubleValue ?? 0
    guard until > 0 else { return false }
    return Date().timeIntervalSince1970 * 1000.0 < until
  }

  /// #598: the app the current TARGETED escape ticket opens — the ONE app exempt from every shield
  /// while the ticket is live. nil for a full-suppression ticket (no target) or when no ticket is
  /// live. Shared via the App Group with the monitor's identical gate so both processes exempt the
  /// same app when they re-apply a shield.
  private func escapeExemptToken() -> ApplicationToken? {
    guard isSuppressedInternal() else { return nil }
    guard let encoded = sharedDefaults?.string(forKey: suppressionTargetTokenKey)
      ?? userDefaults.string(forKey: suppressionTargetTokenKey), !encoded.isEmpty else { return nil }
    return decodeApplicationToken(from: encoded)
  }

  /// #598: consume the ShieldAction-captured escape target (base64 ApplicationToken) iff it is fresh,
  /// returning the encoded string for `suppressBlocks` to promote to this ticket's target. Clears the
  /// one-shot candidate either way. A stale/absent/corrupt candidate → nil → the ticket opens all.
  private func consumeFreshEscapeTargetTokenEncoded() -> String? {
    defer {
      sharedDefaults?.removeObject(forKey: escapeTargetTokenKey)
      sharedDefaults?.removeObject(forKey: escapeTargetTokenTsKey)
    }
    // Refresh the suite so the (separate) ShieldAction process's write is visible here.
    sharedDefaults?.synchronize()
    guard let encoded = sharedDefaults?.string(forKey: escapeTargetTokenKey), !encoded.isEmpty else { return nil }
    let ts = (sharedDefaults?.object(forKey: escapeTargetTokenTsKey) as? NSNumber)?.doubleValue ?? 0
    let nowMs = Date().timeIntervalSince1970 * 1000.0
    guard ts > 0, nowMs - ts <= escapeTargetTokenMaxAgeMs else { return nil }
    guard decodeApplicationToken(from: encoded) != nil else { return nil }
    return encoded
  }

  /// Drop the persisted ticket and cancel its expiry DeviceActivity. Called on block teardown so a
  /// dangling ticket / orphan activity can't outlive the blocks it suppressed.
  private func clearSuppressionState() {
    sharedDefaults?.removeObject(forKey: suppressionUntilKey)
    userDefaults.removeObject(forKey: suppressionUntilKey)
    // #598: drop the ticket's target app too so a later full ticket never inherits a stale exemption.
    sharedDefaults?.removeObject(forKey: suppressionTargetTokenKey)
    userDefaults.removeObject(forKey: suppressionTargetTokenKey)
    cancelSuppressionExpiryActivity()
  }

  /// (Re)arm the one-shot DeviceActivity that fires at the ticket's expiry instant so the monitor
  /// re-applies the shields even if the host app is force-quit — same pattern as the immediate
  /// wall-clock expiry. Same-day only (a DeviceActivitySchedule interval is a time-of-day window);
  /// a cross-midnight ticket falls back to the app-foreground re-apply (applyBlocks' gate clears
  /// once `isSuppressedInternal` goes false).
  private func updateSuppressionExpiryMonitoring(untilMillis: Double) {
    cancelSuppressionExpiryActivity()
    let expiryDate = Date(timeIntervalSince1970: untilMillis / 1000.0)
    let now = Date()
    guard expiryDate > now else { return }
    guard Calendar.current.isDate(expiryDate, inSameDayAs: now) else {
      print("[AppBlocker] suppression expiry crosses midnight — relying on foreground re-apply")
      return
    }
    startSuppressionExpiryMonitoring(expiresAt: expiryDate)
  }

  /// Register the one-shot expiry DeviceActivity (interval STARTS at the expiry instant, so only its
  /// start boundary matters — padded past DeviceActivity's ~15-minute minimum length).
  private func startSuppressionExpiryMonitoring(expiresAt: Date) {
    scheduleLock.lock()
    defer { scheduleLock.unlock() }

    // #607: DeviceActivity is MINUTE-granular, so an intervalStart carrying seconds makes iOS fire
    // intervalDidStart at the minute FLOOR — before the true expiry — and expireSuppressionIfDue then
    // rejects it as "not-due". Since the activity is one-shot (repeats:false), it never fires again →
    // the observed native silence. Round the start UP to the minute AT OR AFTER the expiry so the fire
    // lands at/after the real instant (`now >= until` holds). Costs at most ~1 min of extra ticket.
    let comps = Calendar.current.dateComponents([.hour, .minute, .second], from: expiresAt)
    let expiryMinute = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    let startMinute = (comps.second ?? 0) > 0 ? expiryMinute + 1 : expiryMinute
    let endMinute = startMinute + minScheduleIntervalMinutes + 1
    guard startMinute <= 23 * 60 + 59, endMinute <= 23 * 60 + 59 else {
      print("[AppBlocker] suppression expiry within ~16m of midnight — relying on foreground re-apply")
      writeSuppressionExpiryProbe(["phase": "register-skipped-midnight", "startMinute": startMinute])
      return
    }
    let schedule = DeviceActivitySchedule(
      intervalStart: scheduleTimeComponents(minuteOfDay: startMinute),
      intervalEnd: scheduleTimeComponents(minuteOfDay: endMinute),
      repeats: false
    )
    do {
      try activityCenter.startMonitoring(
        DeviceActivityName(suppressionExpiryActivityName),
        during: schedule,
        events: [:]
      )
      writeSuppressionExpiryProbe([
        "phase": "registered",
        "startMinute": startMinute,
        "endMinute": endMinute,
        "untilMs": Int64(expiresAt.timeIntervalSince1970 * 1000.0)
      ])
    } catch {
      print("[AppBlocker] suppression-expiry startMonitoring failed: \(error.localizedDescription)")
      writeSuppressionExpiryProbe(["phase": "register-failed", "error": "\(error)"])
    }
  }

  /// #607/#614: record an expiry REGISTRATION outcome (phase + schedule params) to the App Group
  /// container file (+ a best-effort UserDefaults mirror). The monitor overwrites the file with the
  /// FIRED outcome, so an inspection still showing "registered" proves iOS never fired the callback.
  private func writeExpiryProbe(fileName: String, udKey: String, _ fields: [String: Any]) {
    var probe = fields
    probe["at"] = Int64(Date().timeIntervalSince1970 * 1000.0)
    guard let data = try? JSONSerialization.data(withJSONObject: probe) else { return }
    if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
      try? data.write(to: container.appendingPathComponent(fileName), options: .atomic)
    }
    if let json = String(data: data, encoding: .utf8) {
      sharedDefaults?.set(json, forKey: udKey)
    }
  }

  private func writeSuppressionExpiryProbe(_ fields: [String: Any]) {
    writeExpiryProbe(fileName: suppressionExpiryProbeFileName, udKey: "appBlocker.suppressionExpiryProbe.v1", fields)
  }

  private func writeImmediateExpiryProbe(_ fields: [String: Any]) {
    writeExpiryProbe(fileName: immediateExpiryProbeFileName, udKey: "appBlocker.immediateExpiryProbe.v1", fields)
  }

  private func cancelSuppressionExpiryActivity() {
    scheduleLock.lock()
    defer { scheduleLock.unlock() }
    activityCenter.stopMonitoring([DeviceActivityName(suppressionExpiryActivityName)])
  }

  // MARK: - Schedule-Window Blocking

  /// #570 free-window inversion: each window is now a "free time" span the user may use freely;
  /// while the schedule is armed, everything OUTSIDE the free windows is shielded and INSIDE a
  /// window is fully open. Register one repeating DeviceActivity per window (boundary wake-ups),
  /// then apply the shield now iff we are currently outside all free windows. Only the schedule
  /// activities and the dedicated `scheduleStore` are touched — the immediate-block `store` and
  /// the temporary-unlock activity are untouched.
  private func applyScheduleConfiguration(_ config: [String: Any]) {
    let windows = parseScheduleWindows(config)
    // #563 allowlist: read the kept apps from `allowedItems` (mode "allow") or the blocked apps
    // from `blockedItems` (legacy). The shield policy is chosen by `mode` in `applyScheduleShield`.
    let mode = scheduleMode(config)
    let items = makeBlockedItems(from: scheduleItemsRaw(config, mode: mode))

    // Stop only previously-registered schedule activities (never the unlock activity), so
    // re-configuring with a different window count leaves no orphans.
    stopScheduleActivities()

    // DeviceActivity intervals are only wake-up triggers; `reevaluateScheduleShield` /
    // `isAnyScheduleWindowActive` (the evaluator) is the SSOT for shield state. A
    // cross-midnight window (startMinute > endMinute) is split into two non-wrapping
    // activities so we never rely on a wrapping interval firing:
    //   evening [startMinute, 23:59]  +  morning [00:00, endMinute]
    // Both names keep the schedule prefix so `stopScheduleActivities` still filters them.
    for (index, window) in windows.enumerated() {
      if window.startMinute <= window.endMinute {
        registerScheduleActivity(
          name: "\(scheduleActivityPrefix)\(index)",
          startMinute: window.startMinute,
          endMinute: window.endMinute
        )
      } else {
        let eveningEnd = 23 * 60 + 59
        if eveningEnd - window.startMinute >= minScheduleIntervalMinutes {
          registerScheduleActivity(
            name: "\(scheduleActivityPrefix)\(index).evening",
            startMinute: window.startMinute,
            endMinute: eveningEnd
          )
        } else {
          // Sub-15-minute evening fragment (start after 23:44): skip the wake-up; the
          // evaluator corrects the shield at the next boundary that does fire.
          print("[AppBlocker] schedule window \(index) evening fragment < \(minScheduleIntervalMinutes)m — skipping activity")
        }
        if window.endMinute > 0 {
          if window.endMinute >= minScheduleIntervalMinutes {
            registerScheduleActivity(
              name: "\(scheduleActivityPrefix)\(index).morning",
              startMinute: 0,
              endMinute: window.endMinute
            )
          } else {
            // Sub-15-minute morning fragment (endMinute < 15): skip the wake-up; the
            // evaluator corrects the shield at the next boundary that does fire.
            print("[AppBlocker] schedule window \(index) morning fragment < \(minScheduleIntervalMinutes)m — skipping activity")
          }
        }
      }
    }

    // #570 inversion: shield while OUTSIDE all free windows; open while inside one.
    // DeviceActivity only fires at interval boundaries, so seed the initial state here.
    // 0 windows = not armed (JS clears the config in that case) — clear defensively so an
    // empty window set can never become a 24h lockdown (#570 S2 regression guard).
    // #572/#598: a live escape ticket also suppresses the schedule shield (the ticket is the only
    // escape for an out-of-window schedule lock). A full ticket keeps it down; a targeted ticket
    // (#598) instead exempts just the escaped app and leaves the gap shield up for the rest.
    let exempt = escapeExemptToken()
    if windows.isEmpty {
      clearScheduleShield()
    } else if isSuppressedInternal() && exempt == nil {
      clearScheduleShield()
    } else if isAnyScheduleWindowActive(windows: windows, at: Date()) {
      clearScheduleShield()
    } else {
      applyScheduleShield(items, mode: mode, exempt: exempt)
    }
  }

  /// #563: the schedule block mode ("allow" | "block"), read from the JS config dict. Absent → block
  /// (legacy denylist), so an old config keeps its meaning.
  private func scheduleMode(_ config: [String: Any]) -> BlockMode {
    return (config["mode"] as? String) == "allow" ? .allow : .block
  }

  /// #563: the raw item dicts for the schedule shield — the kept apps (`allowedItems`) in allow
  /// mode, the blocked apps (`blockedItems`) in legacy mode.
  private func scheduleItemsRaw(_ config: [String: Any], mode: BlockMode) -> [[String: Any]] {
    if mode == .allow {
      return (config["allowedItems"] as? [[String: Any]]) ?? []
    }
    return (config["blockedItems"] as? [[String: Any]]) ?? []
  }

  /// Register one non-wrapping repeating DeviceActivity (no events — boundaries only).
  /// Each window may register one or two of these; failures are logged and isolated so a
  /// rejected schedule can't break the others.
  private func registerScheduleActivity(name: String, startMinute: Int, endMinute: Int) {
    let schedule = DeviceActivitySchedule(
      intervalStart: scheduleTimeComponents(minuteOfDay: startMinute),
      intervalEnd: scheduleTimeComponents(minuteOfDay: endMinute),
      repeats: true
    )
    do {
      try activityCenter.startMonitoring(DeviceActivityName(name), during: schedule, events: [:])
    } catch {
      print("[AppBlocker] schedule activity \(name) startMonitoring failed: \(error.localizedDescription)")
    }
  }

  private func clearScheduleConfigurationInternal() {
    stopScheduleActivities()
    clearScheduleShield()
    clearSuppressionState()  // #572: tearing down the schedule drops any escape ticket
    userDefaults.removeObject(forKey: scheduleConfigStorageKey)
    sharedDefaults?.removeObject(forKey: scheduleConfigStorageKey)
  }

  private func stopScheduleActivities() {
    let scheduleActivities = activityCenter.activities.filter {
      $0.rawValue.hasPrefix(scheduleActivityPrefix)
    }
    if !scheduleActivities.isEmpty {
      activityCenter.stopMonitoring(scheduleActivities)
    }
  }

  private func persistScheduleConfiguration(_ config: [String: Any]) {
    userDefaults.set(config, forKey: scheduleConfigStorageKey)
    sharedDefaults?.set(config, forKey: scheduleConfigStorageKey)
  }

  private func applyScheduleShield(_ items: [BlockedItemInfo], mode: BlockMode, exempt: ApplicationToken? = nil) {
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

  /// #563 allowlist shield: shield every app in every category EXCEPT the kept (allowed) app
  /// tokens. `ShieldSettings.ActivityCategoryPolicy.all(except:)` is the Family Controls primitive
  /// for "block all but these". Only ApplicationTokens can go in the except-set — category/web
  /// tokens can't, so the app layer refuses a selection that contains non-app items (they'd silently
  /// drop out of `compactMap` here and shield everything). An empty allow set would mean "shield
  /// everything" — the app never arms a lock with 0 allowed apps (0 = lock not possible), so we
  /// treat empty defensively as "no shield" rather than a block-all footgun. Whether iOS implicitly
  /// exempts the controlling app / system-essential apps is pending real-device verification.
  private func applyAllowlistShield(_ managedStore: ManagedSettingsStore, allowed items: [BlockedItemInfo], exempt: ApplicationToken? = nil) {
    var allowedAppTokens = Set(items.compactMap { $0.appToken })
    if allowedAppTokens.isEmpty {
      // Empty allow set = no shield on this store (0 allowed is "lock not possible", never block-all).
      // Do NOT let a targeted-ticket exempt token turn that into a block-everything-except-one shield.
      managedStore.shield.applications = nil
      managedStore.shield.applicationCategories = nil
      managedStore.shield.webDomains = nil
      return
    }
    // #598: the escaped app joins the allow (except) set for the ticket, so it is the only extra app
    // that opens while everything else stays shielded.
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

  /// #601: recompute the SCHEDULE shield from the persisted config by wall-clock — the module-side
  /// equivalent of the monitor's `reevaluateScheduleShield`. Used when tearing down the immediate
  /// block (`clearAllBlocks`) so a schedule shield an escape ticket had lowered is restored NOW if we
  /// are outside every free window, instead of waiting orphaned for the next window boundary. Only
  /// ever touches the dedicated `scheduleStore` (never the immediate `store`, so a satisfied gate is
  /// not re-armed) and the App-Group variant key ShieldConfiguration reads. Callers must run this only
  /// when no live ticket exists; a live ticket keeps the schedule shield down (defensive re-check).
  private func reevaluateScheduleShieldFromPersisted() {
    // #598: a targeted ticket exempts one app but keeps the gap shield up for the rest; a full ticket
    // keeps the whole schedule shield down.
    let exempt = escapeExemptToken()
    if isSuppressedInternal() && exempt == nil {
      clearScheduleShield()
      sharedDefaults?.removeObject(forKey: scheduleShieldVariantKey)
      return
    }
    guard let dict = userDefaults.dictionary(forKey: scheduleConfigStorageKey)
      ?? sharedDefaults?.dictionary(forKey: scheduleConfigStorageKey) else {
      clearScheduleShield()
      sharedDefaults?.removeObject(forKey: scheduleShieldVariantKey)
      return
    }
    let windows = parseScheduleWindows(dict)
    let mode = scheduleMode(dict)
    let items = makeBlockedItems(from: scheduleItemsRaw(dict, mode: mode))
    if windows.isEmpty || isAnyScheduleWindowActive(windows: windows, at: Date()) {
      // Not armed, or inside a free window → fully open.
      clearScheduleShield()
      sharedDefaults?.removeObject(forKey: scheduleShieldVariantKey)
    } else {
      // Outside every free window → restore the gap shield (minus the escaped app for a targeted
      // ticket). Mirrors the monitor: the gap shield always records the "schedule" variant (weekday
      // shield, keeps its redirect + escape buttons).
      applyScheduleShield(items, mode: mode, exempt: exempt)
      sharedDefaults?.set("schedule", forKey: scheduleShieldVariantKey)
    }
  }

  private func parseScheduleWindows(_ config: [String: Any]) -> [ScheduleWindowInfo] {
    guard let raw = config["windows"] as? [[String: Any]] else { return [] }
    return raw.compactMap { window in
      guard let start = window["startMinute"] as? Int,
            let end = window["endMinute"] as? Int else {
        return nil
      }
      let weekdays = (window["weekdays"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
      return ScheduleWindowInfo(startMinute: start, endMinute: end, weekdays: Set(weekdays))
    }
  }

  /// True if any window covers `date`. A window with `endMinute < startMinute` crosses
  /// midnight; its after-midnight portion is gated on the window's START day (yesterday).
  private func isAnyScheduleWindowActive(windows: [ScheduleWindowInfo], at date: Date) -> Bool {
    let comps = Calendar.current.dateComponents([.hour, .minute, .weekday], from: date)
    let nowMinute = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    let todayIso = isoWeekday(fromGregorian: comps.weekday ?? 1)
    let yesterdayIso = todayIso == 1 ? 7 : todayIso - 1

    for window in windows {
      if window.startMinute <= window.endMinute {
        if nowMinute >= window.startMinute, nowMinute < window.endMinute,
           window.weekdays.contains(todayIso) {
          return true
        }
      } else {
        if nowMinute >= window.startMinute, window.weekdays.contains(todayIso) {
          return true
        }
        if nowMinute < window.endMinute, window.weekdays.contains(yesterdayIso) {
          return true
        }
      }
    }
    return false
  }

  /// Convert a Gregorian weekday (1 = Sunday … 7 = Saturday) to ISO (1 = Monday … 7 = Sunday).
  private func isoWeekday(fromGregorian gregorian: Int) -> Int {
    return ((gregorian + 5) % 7) + 1
  }

  private func scheduleTimeComponents(minuteOfDay: Int) -> DateComponents {
    return DateComponents(hour: minuteOfDay / 60, minute: minuteOfDay % 60)
  }

  private func isTemporarilyUnlockedInternal() -> Bool {
    return remainingUnlockSeconds() > 0
  }

  /// Clear all persisted unlock state (budget + consumed counter + grant time).
  private func clearUnlockState() {
    sharedDefaults?.removeObject(forKey: temporaryUnlockKey)
    sharedDefaults?.removeObject(forKey: usageConsumedKey)
    sharedDefaults?.removeObject(forKey: unlockGrantedAtKey)
  }

  /// Seconds of earned time still available: the granted budget minus the seconds of
  /// blocked-app usage the monitor extension has recorded. Returns 0 if there is no
  /// active unlock, the budget is fully consumed, or the grant is from a previous day
  /// (earned time does not carry across midnight). Clamped at 0.
  private func remainingUnlockSeconds() -> Int {
    let budgetSeconds = (sharedDefaults?.object(forKey: temporaryUnlockKey) as? Int) ?? 0
    if budgetSeconds <= 0 { return 0 }

    // Daily reset: a grant made on an earlier calendar day is stale.
    if let grantedAt = sharedDefaults?.object(forKey: unlockGrantedAtKey) as? Date,
       !Calendar.current.isDate(grantedAt, inSameDayAs: Date()) {
      return 0
    }

    let consumedSeconds = (sharedDefaults?.object(forKey: usageConsumedKey) as? Int) ?? 0
    return max(0, budgetSeconds - consumedSeconds)
  }

  /// Build a DateComponents threshold from a total number of seconds (normalized
  /// into hour/minute/second so the system reads it cleanly).
  private func dateComponents(fromSeconds total: Int) -> DateComponents {
    return DateComponents(
      hour: total / 3600,
      minute: (total % 3600) / 60,
      second: total % 60
    )
  }


  // MARK: - Serialization

  private func serializeBlockConfig(_ config: BlockConfig) -> [String: Any] {
    let blockedItems: [[String: Any]] = config.items.compactMap { tokenInfo in
      var tokenId = tokenInfo.tokenId
      if tokenId.isEmpty {
        switch tokenInfo.type {
        case .app:
          if let token = tokenInfo.appToken, let encoded = self.encodeApplicationToken(token) {
            tokenId = encoded
          }
        case .category:
          if let token = tokenInfo.categoryToken, let encoded = self.encodeCategoryToken(token) {
            tokenId = encoded
          }
        case .webDomain:
          if let token = tokenInfo.webDomainToken, let encoded = self.encodeWebDomainToken(token) {
            tokenId = encoded
          }
        }
      }

      guard !tokenId.isEmpty else {
        return nil
      }

      var dict: [String: Any] = [
        "type": tokenInfo.type.rawValue,
        "token": tokenId
      ]

      if let bundleId = tokenInfo.bundleIdentifier {
        dict["bundleIdentifier"] = bundleId
      }
      if let displayName = tokenInfo.displayName {
        dict["displayName"] = displayName
      }
      if let categoryName = tokenInfo.categoryName {
        dict["categoryName"] = categoryName
      }
      if let domain = tokenInfo.domain {
        dict["domain"] = domain
      }
      if let iconBase64 = tokenInfo.iconBase64 {
        dict["iconBase64"] = iconBase64
      }

      return dict
    }

    let appSelections = blockedItems.filter { ($0["type"] as? String) == BlockedItemType.app.rawValue }

    var result: [String: Any] = [
      "blockedItems": blockedItems,
      "appSelections": appSelections,
      "isActive": config.isActive,
      // #563: surface the block mode; in allow mode the item list is the kept (allowed) apps.
      "mode": config.mode.rawValue
    ]
    if config.mode == .allow {
      result["allowedItems"] = blockedItems
    }

    if let schedule = config.schedule {
      result["schedule"] = [
        "intervalStart": schedule.intervalStart,
        "intervalEnd": schedule.intervalEnd,
        "repeats": schedule.repeats,
        "warningTime": schedule.warningTime
      ]
    }

    // #535: persist the wall-clock expiry so it survives relaunch and the monitor extension can
    // read it from the App Group copy to gate its release.
    if let expiresAtMillis = config.expiresAtMillis {
      result["expiresAtMillis"] = expiresAtMillis
    }

    return result
  }

  // MARK: - Persistence

  private func ensureLoadedPersistedConfig() {
    if didLoadPersistedConfig {
      return
    }
    didLoadPersistedConfig = true

    guard let savedConfig = userDefaults.dictionary(forKey: blockConfigStorageKey) else {
      return
    }

    do {
      let config = try parseBlockConfig(savedConfig)
      currentBlockConfig = config
      try applyBlocks(config)
    } catch {
      currentBlockConfig = nil
      userDefaults.removeObject(forKey: blockConfigStorageKey)
    }
  }

  private func persistBlockConfiguration(_ config: [String: Any]) {
    userDefaults.set(config, forKey: blockConfigStorageKey)
    sharedDefaults?.set(config, forKey: blockConfigStorageKey)
  }

  // MARK: - Token Encoding/Decoding

  private func encodeApplicationToken(_ token: ApplicationToken) -> String? {
    do {
      let data = try JSONEncoder().encode(token)
      return data.base64EncodedString()
    } catch {
      return nil
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

  private func encodeCategoryToken(_ token: ActivityCategoryToken) -> String? {
    do {
      let data = try JSONEncoder().encode(token)
      return data.base64EncodedString()
    } catch {
      return nil
    }
  }

  private func decodeCategoryToken(from encoded: String) -> ActivityCategoryToken? {
    return Self.decodeCategoryTokenStatic(from: encoded)
  }

  private func encodeWebDomainToken(_ token: WebDomainToken) -> String? {
    do {
      let data = try JSONEncoder().encode(token)
      return data.base64EncodedString()
    } catch {
      return nil
    }
  }

  private func decodeWebDomainToken(from encoded: String) -> WebDomainToken? {
    guard let data = Data(base64Encoded: encoded) else {
      return nil
    }
    return try? JSONDecoder().decode(WebDomainToken.self, from: data)
  }

  // Static versions for use in View prop closures
  static func decodeApplicationTokenStatic(from encoded: String) -> ApplicationToken? {
    guard let data = Data(base64Encoded: encoded) else { return nil }
    return try? JSONDecoder().decode(ApplicationToken.self, from: data)
  }

  static func decodeCategoryTokenStatic(from encoded: String) -> ActivityCategoryToken? {
    guard let data = Data(base64Encoded: encoded) else { return nil }
    return try? JSONDecoder().decode(ActivityCategoryToken.self, from: data)
  }
}

// MARK: - Native View for rendering blocked app tokens with real names/icons

/// #602: one rendered registered-app row. `id` is the exact base64 tokenId RN passed (stable ForEach
/// identity + the identifier echoed back in `onRemoveItem`), so RN can match the removed row precisely.
struct BlockedAppRenderItem: Identifiable {
  let id: String
  let type: String   // "app" | "category"
  let appToken: ApplicationToken?
  let categoryToken: ActivityCategoryToken?
}

class BlockedAppsViewModel: ObservableObject {
  // Ordered so ForEach keeps the caller's order and the remove index is meaningful.
  @Published var items: [BlockedAppRenderItem] = []
  @Published var removable: Bool = false
}

class BlockedAppsView: ExpoView {
  let viewModel = BlockedAppsViewModel()
  // #602: fired when the user taps a row's remove button. Payload { index, token, type }.
  let onRemoveItem = EventDispatcher()
  private var hostingController: UIHostingController<BlockedAppsContentView>?

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    clipsToBounds = true
    let contentView = BlockedAppsContentView(viewModel: viewModel) { [weak self] item, index in
      self?.handleRemove(item: item, index: index)
    }
    let hc = UIHostingController(rootView: contentView)
    hc.view.backgroundColor = .clear
    addSubview(hc.view)
    hostingController = hc
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    hostingController?.view.frame = bounds
  }

  /// Build the ordered render list from the RN `tokens` prop, preserving each item's exact base64
  /// tokenId (the identifier RN can match on) and the caller's order.
  func setItemsFromTokens(_ tokens: [[String: String]]) {
    var items: [BlockedAppRenderItem] = []
    for tokenInfo in tokens {
      guard let tokenString = tokenInfo["token"], let type = tokenInfo["type"] else { continue }
      if type == "app" {
        if let token = ExpoAppBlockerModule.decodeApplicationTokenStatic(from: tokenString) {
          items.append(BlockedAppRenderItem(id: tokenString, type: "app", appToken: token, categoryToken: nil))
        }
      } else if type == "category" {
        if let token = ExpoAppBlockerModule.decodeCategoryTokenStatic(from: tokenString) {
          items.append(BlockedAppRenderItem(id: tokenString, type: "category", appToken: nil, categoryToken: token))
        }
      }
    }
    viewModel.items = items
  }

  /// Fallback path (a full FamilyActivitySelection). Token order isn't preserved by the Set, and the
  /// tokenId is re-encoded (deterministic, matching serializeBlockConfig), so RN callers that need
  /// exact identity should prefer the `tokens` prop.
  func setItemsFromSelection(_ selection: FamilyActivitySelection) {
    var items: [BlockedAppRenderItem] = []
    for token in selection.applicationTokens {
      if let data = try? JSONEncoder().encode(token) {
        items.append(BlockedAppRenderItem(id: data.base64EncodedString(), type: "app", appToken: token, categoryToken: nil))
      }
    }
    for token in selection.categoryTokens {
      if let data = try? JSONEncoder().encode(token) {
        items.append(BlockedAppRenderItem(id: data.base64EncodedString(), type: "category", appToken: nil, categoryToken: token))
      }
    }
    viewModel.items = items
  }

  private func handleRemove(item: BlockedAppRenderItem, index: Int) {
    onRemoveItem([
      "index": index,
      "token": item.id,
      "type": item.type
    ])
  }
}

// #602: fixed per-row height for the registered-apps list. Native views don't propagate an intrinsic
// content size to the RN frame, so instead of an internal ScrollView the list is a NON-scrolling,
// fixed-height VStack and RN sizes the frame deterministically as `rowHeight × items.length` (outer
// scrolling is RN's job). Kept in sync with the TS export `BLOCKED_APPS_ROW_HEIGHT`.
let BlockedAppsRowHeight: CGFloat = 56

struct BlockedAppsContentView: View {
  @ObservedObject var viewModel: BlockedAppsViewModel
  // #602: invoked with the tapped row + its index; the view emits, RN removes.
  var onRemove: (BlockedAppRenderItem, Int) -> Void

  // Grandmizer design system colors
  private let borderColor = Color(red: 0.91, green: 0.91, blue: 0.91)   // #e8e8e8
  private let labelColor = Color(red: 0.067, green: 0.067, blue: 0.067) // #111111
  private let greenBadgeBg = Color(red: 0.94, green: 0.96, blue: 0.91)  // #f0f6e8
  private let greenText = Color(red: 0.24, green: 0.31, blue: 0.0)      // #3d5000
  private let removeColor = Color(red: 0.73, green: 0.73, blue: 0.73)   // #bbbbbb

  var body: some View {
    // spacing 0 + a fixed height per row = total height is exactly rowHeight × count, matching the RN
    // frame. Pin to the top so rows never center-clip if the frame is a touch taller than the content.
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(viewModel.items.enumerated()), id: \.element.id) { index, item in
        HStack(spacing: 12) {
          if let appToken = item.appToken {
            Label(appToken)
              .labelStyle(.titleAndIcon)
              .font(.system(size: 16, weight: .semibold))
              .tint(labelColor)
              .foregroundStyle(labelColor)
              .lineLimit(1)
          } else if let categoryToken = item.categoryToken {
            Label(categoryToken)
              .labelStyle(.titleAndIcon)
              .font(.system(size: 16, weight: .semibold))
              .tint(labelColor)
              .foregroundStyle(labelColor)
              .lineLimit(1)
          }
          Spacer()
          if viewModel.removable {
            Button {
              onRemove(item, index)
            } label: {
              Image(systemName: "minus.circle.fill")
                .font(.system(size: 22))
                .foregroundColor(removeColor)
            }
            .buttonStyle(.plain)
          } else {
            Text(item.type == "category" ? "Category" : "App")
              .font(.system(size: 11, weight: .semibold))
              .foregroundColor(greenText)
              .padding(.horizontal, 10)
              .padding(.vertical, 4)
              .background(greenBadgeBg)
              .cornerRadius(100)
          }
        }
        .padding(.horizontal, 14)
        .frame(height: BlockedAppsRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
          Rectangle().fill(borderColor).frame(height: 1)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .environment(\.colorScheme, .light)
  }
}

// MARK: - Data Types

enum BlockedItemType: String {
  case app
  case category
  case webDomain
}

/// #563: block semantics. `.block` = shield the listed apps (legacy denylist). `.allow` = keep the
/// listed apps open and shield everything else (allowlist, via `.all(except:)`).
enum BlockMode: String {
  case block
  case allow
}

struct BlockedItemInfo {
  let type: BlockedItemType
  let tokenId: String
  let appToken: ApplicationToken?
  let categoryToken: ActivityCategoryToken?
  let webDomainToken: WebDomainToken?
  let bundleIdentifier: String?
  let displayName: String?
  let categoryName: String?
  let domain: String?
  let iconBase64: String?
}

struct BlockConfig {
  let items: [BlockedItemInfo]
  let isActive: Bool
  let schedule: ScheduleInfo?
  // #535: optional wall-clock auto-release (epoch millis). nil / <= 0 = no expiry.
  let expiresAtMillis: Double?
  // #563: block vs allow semantics for `items` (see BlockMode).
  let mode: BlockMode
}

struct ScheduleInfo {
  let intervalStart: Int
  let intervalEnd: Int
  let repeats: Bool
  let warningTime: Int
}

/// One schedule window: local minute-of-day bounds (0..1439) plus the ISO weekdays
/// (1 = Monday … 7 = Sunday) it applies to. `endMinute < startMinute` crosses midnight.
struct ScheduleWindowInfo {
  let startMinute: Int
  let endMinute: Int
  let weekdays: Set<Int>
}

// MARK: - FamilyActivityPicker SwiftUI View

struct FamilyActivityPickerView: View {
  @State private var selection: FamilyActivitySelection
  @State private var didAppear = false
  @State private var didFinish = false
  let promise: Promise
  // Dismisses only the picker's own controller, then runs the completion.
  let dismissPicker: (@escaping () -> Void) -> Void

  init(
    initialApplicationTokens: Set<ApplicationToken>,
    initialCategoryTokens: Set<ActivityCategoryToken>,
    promise: Promise,
    dismissPicker: @escaping (@escaping () -> Void) -> Void
  ) {
    self.promise = promise
    self.dismissPicker = dismissPicker

    var initialSelection = FamilyActivitySelection()
    initialSelection.applicationTokens = initialApplicationTokens
    initialSelection.categoryTokens = initialCategoryTokens
    self._selection = State(initialValue: initialSelection)
  }

  var body: some View {
    NavigationView {
      VStack {
        familyActivityPicker
          .onChange(of: selection) { newSelection in
            _ = newSelection
          }
      }
      .onAppear {
        didAppear = true
      }
      .onDisappear {
        handleInteractiveDismissIfNeeded()
      }
      .navigationBarItems(
        leading: Button("Cancel") {
          dismissWithCancel()
        },
        trailing: Button("Done") {
          dismissWithSelection()
        }
      )
    }
  }

  @ViewBuilder
  private var familyActivityPicker: some View {
    FamilyActivityPicker(selection: $selection)
  }

  private func dismissWithSelection() {
    let appItems: [[String: Any]] = selection.applications.compactMap { selectedApp in
      guard let token = selectedApp.token,
            let tokenId = encodeSelectionToken(token) else {
        return nil
      }

      let bundleIdentifier = selectedApp.bundleIdentifier ?? ""
      let displayName = selectedApp.localizedDisplayName ?? ""
      // String(describing:) on Application sometimes contains the app name
      let descriptionString = String(describing: selectedApp)

      // Log everything for debugging
      print("[AppBlocker] Application: displayName='\(displayName)' bundleId='\(bundleIdentifier)' description='\(descriptionString)'")

      // Try multiple strategies to get a meaningful name
      let resolvedName: String
      if !displayName.isEmpty {
        resolvedName = displayName
      } else if !bundleIdentifier.isEmpty {
        // Try to make a readable name from bundle ID
        // e.g. "com.instagram.android" -> "Instagram"
        let parts = bundleIdentifier.split(separator: ".")
        if let lastPart = parts.last {
          let name = String(lastPart)
          // Capitalize and clean up
          resolvedName = name.prefix(1).uppercased() + name.dropFirst()
        } else {
          resolvedName = bundleIdentifier
        }
      } else if !descriptionString.isEmpty && descriptionString != "Application()" {
        // Try to parse something useful from description
        let cleaned = descriptionString
          .replacingOccurrences(of: "Application(", with: "")
          .replacingOccurrences(of: ")", with: "")
          .trimmingCharacters(in: .whitespaces)
        resolvedName = cleaned.isEmpty ? "Blocked App" : cleaned
      } else {
        resolvedName = "Blocked App"
      }

      return [
        "type": "app",
        "token": tokenId,
        "bundleIdentifier": bundleIdentifier,
        "displayName": resolvedName,
        "description": descriptionString
      ]
    }

    let categoryItems: [[String: Any]] = selection.categoryTokens.compactMap { categoryToken in
      guard let tokenId = encodeSelectionCategoryToken(categoryToken) else {
        return nil
      }

      let descriptionString = String(describing: categoryToken)
      let name = resolveCategoryName(categoryToken)
      print("[AppBlocker] Category: name='\(name)' description='\(descriptionString)'")

      return [
        "type": "category",
        "token": tokenId,
        "categoryName": name.isEmpty ? "Category" : name
      ]
    }

    let webDomainItems: [[String: Any]] = selection.webDomainTokens.compactMap { webDomainToken in
      guard let tokenId = encodeSelectionWebDomainToken(webDomainToken) else {
        return nil
      }
      let domain = String(describing: webDomainToken)
      return [
        "type": "webDomain",
        "token": tokenId,
        "domain": domain
      ]
    }

    // Serialize the full FamilyActivitySelection for the native view
    var selectionBase64 = ""
    if let selectionData = try? JSONEncoder().encode(selection) {
      selectionBase64 = selectionData.base64EncodedString()
    }

    var result: [[String: Any]] = appItems + categoryItems + webDomainItems
    result.append([
      "type": "summary",
      "totalApps": selection.applications.count,
      "totalCategories": selection.categoryTokens.count,
      "totalWebDomains": selection.webDomainTokens.count,
      "selectionData": selectionBase64
    ])

    dismissWithResult(result)
  }

  private func dismissWithCancel() {
    didFinish = true
    dismissPicker {
      self.promise.reject("PICKER_CANCELLED", "User cancelled Family Activity Picker")
    }
  }

  private func encodeSelectionCategoryToken(_ token: ActivityCategoryToken) -> String? {
    do {
      let data = try JSONEncoder().encode(token)
      return data.base64EncodedString()
    } catch {
      return nil
    }
  }

  private func encodeSelectionWebDomainToken(_ token: WebDomainToken) -> String? {
    do {
      let data = try JSONEncoder().encode(token)
      return data.base64EncodedString()
    } catch {
      return nil
    }
  }

  private func resolveCategoryName(_ token: ActivityCategoryToken) -> String {
    let raw = String(describing: token)
    return raw.isEmpty ? "Category" : raw
  }

  private func encodeSelectionToken(_ token: ApplicationToken) -> String? {
    do {
      let data = try JSONEncoder().encode(token)
      return data.base64EncodedString()
    } catch {
      return nil
    }
  }

  private func dismissWithResult(_ result: [[String: Any]]) {
    didFinish = true
    dismissPicker {
      self.promise.resolve(result)
    }
  }

  private func handleInteractiveDismissIfNeeded() {
    guard didAppear, !didFinish else {
      return
    }

    didFinish = true
    promise.reject("PICKER_CANCELLED", "User dismissed Family Activity Picker")
  }
}
