import ExpoModulesCore
import FamilyControls
import ManagedSettings
import DeviceActivity
import SwiftUI
import Foundation

public class ExpoAppBlockerModule: Module {
  private let appGroupIdentifier = ExpoAppBlockerConfig.appGroupIdentifier

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
  // Immediate-block wall-clock expiry (#535). When `setBlockConfiguration` carries
  // `expiresAtMillis`, one DeviceActivity fires at that instant and the monitor extension lifts
  // the immediate shield — a kill-proof release guarantee mirroring Android's `expiresAtMillis`.
  // The interval's START is the expiry instant (intervalDidStart), so short blocks work despite
  // DeviceActivity's ~15-minute minimum interval length (only the start boundary matters).
  private let immediateExpiryActivityName = "appBlocker.immediateExpiry"
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
      Prop("selectionData") { (view: BlockedAppsView, selectionBase64: String) in
        guard !selectionBase64.isEmpty,
              let data = Data(base64Encoded: selectionBase64),
              let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
        else { return }
        view.viewModel.selection = selection
      }

      Prop("tokens") { (view: BlockedAppsView, tokens: [[String: String]]) in
        var appTokens: Set<ApplicationToken> = []
        var categoryTokens: Set<ActivityCategoryToken> = []

        for tokenInfo in tokens {
          guard let tokenString = tokenInfo["token"], let type = tokenInfo["type"] else { continue }
          if type == "app" {
            if let token = Self.decodeApplicationTokenStatic(from: tokenString) {
              appTokens.insert(token)
            }
          } else if type == "category" {
            if let token = Self.decodeCategoryTokenStatic(from: tokenString) {
              categoryTokens.insert(token)
            }
          }
        }

        var selection = FamilyActivitySelection()
        selection.applicationTokens = appTokens
        selection.categoryTokens = categoryTokens
        view.viewModel.selection = selection
      }
    }

    OnCreate {
      self.sharedDefaults = UserDefaults(suiteName: self.appGroupIdentifier)
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
        let pickerView = FamilyActivityPickerView(
          initialApplicationTokens: initialAppTokens,
          initialCategoryTokens: initialCategoryTokens,
          promise: promise
        )
        let hostingController = UIHostingController(rootView: pickerView)

        if let rootVC = self.getRootViewController() {
          hostingController.modalPresentationStyle = .formSheet
          rootVC.present(hostingController, animated: true)
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
    let rawItems: [[String: Any]]
    if let blockedItems = dict["blockedItems"] as? [[String: Any]] {
      rawItems = blockedItems
    } else if let appSelections = dict["appSelections"] as? [[String: Any]] {
      rawItems = appSelections.map { item in
        var normalized = item
        normalized["type"] = "app"
        return normalized
      }
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

    return BlockConfig(items: items, isActive: isActive, schedule: schedule, expiresAtMillis: expiresAtMillis)
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

    let validAppTokens = config.items.compactMap { $0.appToken }
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

    let startComps = Calendar.current.dateComponents([.hour, .minute, .second], from: expiresAt)
    let startMinute = (startComps.hour ?? 0) * 60 + (startComps.minute ?? 0)
    let endMinute = startMinute + minScheduleIntervalMinutes + 1
    guard endMinute <= 23 * 60 + 59 else {
      print("[AppBlocker] immediate-expiry within ~16m of midnight — relying on foreground clear")
      return
    }
    let schedule = DeviceActivitySchedule(
      intervalStart: startComps,
      intervalEnd: scheduleTimeComponents(minuteOfDay: endMinute),
      repeats: false
    )
    do {
      try activityCenter.startMonitoring(
        DeviceActivityName(immediateExpiryActivityName),
        during: schedule,
        events: [:]
      )
    } catch {
      print("[AppBlocker] immediate-expiry startMonitoring failed: \(error.localizedDescription)")
    }
  }

  private func cancelImmediateExpiryActivity() {
    scheduleLock.lock()
    defer { scheduleLock.unlock() }
    activityCenter.stopMonitoring([DeviceActivityName(immediateExpiryActivityName)])
  }

  // MARK: - Schedule-Window Blocking

  /// Register one repeating DeviceActivity per window and immediately shield if a window
  /// is already active. Only the schedule activities and the dedicated `scheduleStore` are
  /// touched — the immediate-block `store` and the temporary-unlock activity are untouched.
  private func applyScheduleConfiguration(_ config: [String: Any]) {
    let windows = parseScheduleWindows(config)
    let items = makeBlockedItems(from: (config["blockedItems"] as? [[String: Any]]) ?? [])

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

    // DeviceActivity only fires at interval boundaries, so if we're already inside a
    // window at configuration time, apply the shield now.
    if isAnyScheduleWindowActive(windows: windows, at: Date()) {
      applyScheduleShield(items)
    } else {
      clearScheduleShield()
    }
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

  private func applyScheduleShield(_ items: [BlockedItemInfo]) {
    let apps = items.compactMap { $0.appToken }
    let categories = items.compactMap { $0.categoryToken }
    let webDomains = items.compactMap { $0.webDomainToken }
    scheduleStore.shield.applications = apps.isEmpty ? nil : Set(apps)
    if categories.isEmpty {
      scheduleStore.shield.applicationCategories = nil
    } else {
      scheduleStore.shield.applicationCategories = .specific(Set(categories))
    }
    scheduleStore.shield.webDomains = webDomains.isEmpty ? nil : Set(webDomains)
  }

  private func clearScheduleShield() {
    scheduleStore.shield.applications = nil
    scheduleStore.shield.applicationCategories = nil
    scheduleStore.shield.webDomains = nil
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
      "isActive": config.isActive
    ]

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

class BlockedAppsViewModel: ObservableObject {
  @Published var selection = FamilyActivitySelection()
}

class BlockedAppsView: ExpoView {
  let viewModel = BlockedAppsViewModel()
  private var hostingController: UIHostingController<BlockedAppsContentView>?

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    clipsToBounds = true
    let contentView = BlockedAppsContentView(viewModel: viewModel)
    let hc = UIHostingController(rootView: contentView)
    hc.view.backgroundColor = .clear
    addSubview(hc.view)
    hostingController = hc
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    hostingController?.view.frame = bounds
  }
}

struct BlockedAppsContentView: View {
  @ObservedObject var viewModel: BlockedAppsViewModel

  // Grandmizer design system colors
  private let cardBg = Color(red: 1.0, green: 1.0, blue: 1.0)           // #ffffff
  private let borderColor = Color(red: 0.91, green: 0.91, blue: 0.91)   // #e8e8e8
  private let labelColor = Color(red: 0.067, green: 0.067, blue: 0.067) // #111111
  private let subtitleColor = Color(red: 0.73, green: 0.73, blue: 0.73) // #bbbbbb
  private let greenBadgeBg = Color(red: 0.94, green: 0.96, blue: 0.91)  // #f0f6e8
  private let greenText = Color(red: 0.24, green: 0.31, blue: 0.0)      // #3d5000

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(viewModel.selection.applicationTokens), id: \.self) { token in
        HStack(spacing: 12) {
          Label(token)
            .labelStyle(.titleAndIcon)
            .font(.system(size: 16, weight: .semibold))
            .tint(labelColor)
            .foregroundStyle(labelColor)
          Spacer()
          Text("App")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(greenText)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(greenBadgeBg)
            .cornerRadius(100)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(cardBg)
        .cornerRadius(16)
        .overlay(
          RoundedRectangle(cornerRadius: 16)
            .stroke(borderColor, lineWidth: 1)
        )
      }

      ForEach(Array(viewModel.selection.categoryTokens), id: \.self) { token in
        HStack(spacing: 12) {
          Label(token)
            .labelStyle(.titleAndIcon)
            .font(.system(size: 16, weight: .semibold))
            .tint(labelColor)
            .foregroundStyle(labelColor)
          Spacer()
          Text("Category")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(greenText)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(greenBadgeBg)
            .cornerRadius(100)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(cardBg)
        .cornerRadius(16)
        .overlay(
          RoundedRectangle(cornerRadius: 16)
            .stroke(borderColor, lineWidth: 1)
        )
      }

      if viewModel.selection.applicationTokens.isEmpty && viewModel.selection.categoryTokens.isEmpty {
        Text("No apps blocked")
          .foregroundColor(subtitleColor)
          .font(.system(size: 14))
          .frame(maxWidth: .infinity, alignment: .center)
          .padding(.vertical, 16)
      }
    }
    .environment(\.colorScheme, .light)
  }
}

// MARK: - Data Types

enum BlockedItemType: String {
  case app
  case category
  case webDomain
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

  init(
    initialApplicationTokens: Set<ApplicationToken>,
    initialCategoryTokens: Set<ActivityCategoryToken>,
    promise: Promise
  ) {
    self.promise = promise

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

    DispatchQueue.main.async {
      if let rootVC = getRootViewController() {
        rootVC.dismiss(animated: true) {
          self.promise.reject("PICKER_CANCELLED", "User cancelled Family Activity Picker")
        }
      }
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

    DispatchQueue.main.async {
      if let rootVC = getRootViewController() {
        rootVC.dismiss(animated: true) {
          self.promise.resolve(result)
        }
      }
    }
  }

  private func getRootViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes
    let windowScene = scenes.first as? UIWindowScene
    let window = windowScene?.windows.first
    return window?.rootViewController
  }

  private func handleInteractiveDismissIfNeeded() {
    guard didAppear, !didFinish else {
      return
    }

    didFinish = true
    promise.reject("PICKER_CANCELLED", "User dismissed Family Activity Picker")
  }
}
