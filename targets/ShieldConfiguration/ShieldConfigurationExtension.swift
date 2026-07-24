import ManagedSettingsUI
import ManagedSettings
import UIKit

class ShieldConfigurationExtension: ShieldConfigurationDataSource {

  private let appGroupIdentifier = "APP_GROUP_PLACEHOLDER"
  // #598: the app this data source LAST rendered a shield for. The guardian locks via
  // `.all(except:)` (a category shield), so the escape ShieldAction almost always arrives on the
  // CATEGORY overload — which carries no ApplicationToken, leaving it unable to tell which app the
  // user pressed "지금 필요해" on (the observed bug: the ticket opened everything). This data source's
  // app-carrying overloads DO receive the specific `Application` even in category mode, so we record
  // its token here on every render (always overwrite = the latest render is the shield on screen),
  // and the ShieldAction reads the freshest one as the escape target.
  // ⚠️ Known limitation: iOS caches shield configs and can render shields for BACKGROUND apps
  // (app-switcher previews), so a stale or different-app token can occasionally win. The
  // ShieldAction's freshness gate + full-open fallback are the safety net.
  private let lastShieldedTokenKey = "appBlocker.lastShieldedToken.v1"
  private let lastShieldedTokenTsKey = "appBlocker.lastShieldedTokenTs.v1"
  // #598 durability: this extension is torn down the instant it returns a shield config, so a
  // UserDefaults write is frequently reaped by cfprefsd before it commits and silently vanishes (the
  // observed no-last-shielded bug). The App Group CONTAINER FILE, written with Data.write(.atomic)
  // (temp + rename, flushed to disk synchronously), survives the instant death. This is the primary
  // store; the UserDefaults mirror is kept best-effort for the ShieldAction's legacy fallback read.
  private let lastShieldedFileName = "lastShielded.json"

  // All values below are replaced by the config plugin at prebuild time
  private let shieldTitle = "SHIELD_TITLE_PLACEHOLDER"
  private let shieldSubtitle = "SHIELD_SUBTITLE_PLACEHOLDER"
  private let shieldPrimaryButtonLabel = "SHIELD_PRIMARY_BUTTON_PLACEHOLDER"
  private let shieldSecondaryButtonLabel = "SHIELD_SECONDARY_BUTTON_PLACEHOLDER"
  // Temporary-unlock state copy — shown briefly while ManagedSettings clears
  // after a successful unlock. Configurable via plugin options.
  private let shieldTempUnlockTitle = "SHIELD_TEMP_UNLOCK_TITLE_PLACEHOLDER"
  private let shieldTempUnlockSubtitle = "SHIELD_TEMP_UNLOCK_SUBTITLE_PLACEHOLDER"
  private let shieldTempUnlockButtonLabel = "SHIELD_TEMP_UNLOCK_BUTTON_PLACEHOLDER"
  private let shieldPrimaryButtonColor = UIColor(red: SHIELD_PRIMARY_R_PLACEHOLDER, green: SHIELD_PRIMARY_G_PLACEHOLDER, blue: SHIELD_PRIMARY_B_PLACEHOLDER, alpha: 1.0)
  private let shieldBackgroundColor: UIColor? = SHIELD_BG_COLOR_PLACEHOLDER
  private let shieldBlurStyle: UIBlurEffect.Style? = SHIELD_BLUR_STYLE_PLACEHOLDER
  private let shieldTitleColor = UIColor(red: SHIELD_TITLE_R_PLACEHOLDER, green: SHIELD_TITLE_G_PLACEHOLDER, blue: SHIELD_TITLE_B_PLACEHOLDER, alpha: 1.0)
  private let shieldSubtitleColor = UIColor(red: SHIELD_SUBTITLE_R_PLACEHOLDER, green: SHIELD_SUBTITLE_G_PLACEHOLDER, blue: SHIELD_SUBTITLE_B_PLACEHOLDER, alpha: 1.0)
  // #525 schedule-window shield copy — hand-synced with guardianCopy.ts schedule.*ShieldTitle/
  // Subtitle. Weekday: keeps the "하러 가기" redirect button (NOT an unlock — the schedule store
  // survives the unlock path, so the button only returns to the app). Bedtime: sleepy, no
  // buttons, auto-releases at the window's end (pure time promise).
  private let scheduleWeekdayTitle = "지금은 나랑 있자."
  private let scheduleWeekdaySubtitle = "문은 이따 열려."
  private let scheduleBedtimeTitle = "지금은 잘 시간이야."
  private let scheduleBedtimeSubtitle = "내일 또 하자."

  private var mascotIcon: UIImage? {
    let bundle = Bundle(for: type(of: self))
    return UIImage(named: "shield-icon", in: bundle, compatibleWith: nil)
      ?? UIImage(contentsOfFile: bundle.path(forResource: "shield-icon", ofType: "png") ?? "")
  }

  private func getBlockedAppCount() -> Int {
    guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return 0 }
    guard let config = defaults.dictionary(forKey: "appBlocker.blockConfiguration.v1") else { return 0 }
    if let items = config["blockedItems"] as? [[String: Any]] {
      return items.count
    }
    return 0
  }

  // #523: variant subtitle the enforcement slice writes into the App Group on arm
  // (e.g. focus "지금은 그거 하나만."). Absent/empty → fall back to the fixed line.
  private func focusShieldSubtitle() -> String? {
    guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return nil }
    guard let value = defaults.string(forKey: "appBlocker.shieldFocusSubtitle.v1"), !value.isEmpty else { return nil }
    return value
  }

  // #525: the active schedule window's variant ("bedtime" | "schedule"), written by the
  // DeviceActivity monitor (the SSOT for which window is active). nil = not inside a window,
  // so the default/focus shield path renders instead.
  private func scheduleShieldVariant() -> String? {
    guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return nil }
    guard let value = defaults.string(forKey: "appBlocker.scheduleShieldVariant.v1"), !value.isEmpty else { return nil }
    return value
  }

  private func scheduleShieldConfig() -> ShieldConfiguration? {
    guard let variant = scheduleShieldVariant() else { return nil }
    let bedtime = variant == "bedtime"
    // #572: the escape ticket is the ONLY way out of an out-of-window schedule lock, so the weekday
    // shield offers the same "지금 필요해" secondary button as the default/focus shield (when the app
    // configured it; "none"/empty hides it — back-compat). Bedtime stays button-less (pure time
    // promise, auto-release at the window's end).
    let hasSecondary = !shieldSecondaryButtonLabel.isEmpty && shieldSecondaryButtonLabel != "none"
    return ShieldConfiguration(
      backgroundBlurStyle: shieldBlurStyle,
      backgroundColor: shieldBackgroundColor,
      icon: mascotIcon,
      title: ShieldConfiguration.Label(text: bedtime ? scheduleBedtimeTitle : scheduleWeekdayTitle, color: shieldTitleColor),
      subtitle: ShieldConfiguration.Label(text: bedtime ? scheduleBedtimeSubtitle : scheduleWeekdaySubtitle, color: shieldSubtitleColor),
      // Bedtime: no buttons (time promise, auto-release at window end). Weekday: redirect button.
      primaryButtonLabel: bedtime ? nil : ShieldConfiguration.Label(text: shieldPrimaryButtonLabel, color: .white),
      primaryButtonBackgroundColor: bedtime ? nil : shieldPrimaryButtonColor,
      secondaryButtonLabel: (!bedtime && hasSecondary) ? ShieldConfiguration.Label(text: shieldSecondaryButtonLabel, color: shieldSubtitleColor) : nil
    )
  }

  private func isTemporarilyUnlocked() -> Bool {
    guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return false }
    guard let expiration = defaults.object(forKey: "appBlocker.temporaryUnlock.v1") as? Date else { return false }
    return Date() < expiration
  }

  // Block-event queue, drained by the app into `blocker_intercepts` to power
  // the "blocks" counter. The system re-renders the shield often (app
  // switcher previews, re-foreground), so a short global debounce collapses
  // those bursts into one logical block event.
  private let pendingInterceptsKey = "appBlocker.pendingIntercepts.v1"
  private let lastInterceptTsKey = "appBlocker.lastInterceptTs.v1"
  private let interceptDebounceMs: Double = 2_000
  private let maxPendingIntercepts = 200

  // Best-effort block recording. iOS caches the shield configuration and
  // does NOT reliably re-invoke this data source per open, so the action
  // handler (ShieldAction) is the primary recorder; this is a bonus path
  // for the cases the system does re-invoke. Writes share the same App
  // Group JSON queue + debounce as ShieldAction.
  private func recordIntercept(appName: String) {
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
    queue.append(["appName": appName, "interceptedAt": nowMs])
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

  private func makeConfig(appName: String) -> ShieldConfiguration {
    if isTemporarilyUnlocked() {
      return ShieldConfiguration(
        backgroundBlurStyle: shieldBlurStyle,
        backgroundColor: shieldBackgroundColor,
        icon: mascotIcon,
        title: ShieldConfiguration.Label(text: shieldTempUnlockTitle, color: shieldTitleColor),
        subtitle: ShieldConfiguration.Label(text: shieldTempUnlockSubtitle, color: shieldSubtitleColor),
        primaryButtonLabel: ShieldConfiguration.Label(text: shieldTempUnlockButtonLabel, color: .white),
        primaryButtonBackgroundColor: shieldPrimaryButtonColor,
        secondaryButtonLabel: nil
      )
    }

    // A blocked app is being shielded — this is a block event. Record it
    // (debounced) for the app to drain.
    recordIntercept(appName: appName)

    // #525: inside a schedule window → render the sleepy (bedtime) / weekday variant. The
    // monitor's variant key is the SSOT; outside every window it's absent → fall through to
    // the default/focus shield below.
    if let scheduleConfig = scheduleShieldConfig() {
      return scheduleConfig
    }

    let count = getBlockedAppCount()
    // The plugin replaces this placeholder with a Swift string literal
    // containing `\(count)` interpolation, or `""` when the user opted out.
    let context = count > 1 ? SHIELD_COUNT_SUFFIX_SWIFT_PLACEHOLDER : ""
    // #523: prefer the armed variant subtitle (focus etc.); fall back to the fixed line.
    let baseSubtitle = focusShieldSubtitle() ?? shieldSubtitle
    let subtitle = baseSubtitle.replacingOccurrences(of: "{appName}", with: appName) + context

    let hasSecondary = !shieldSecondaryButtonLabel.isEmpty && shieldSecondaryButtonLabel != "none"

    return ShieldConfiguration(
      backgroundBlurStyle: shieldBlurStyle,
      backgroundColor: shieldBackgroundColor,
      icon: mascotIcon,
      title: ShieldConfiguration.Label(text: shieldTitle, color: shieldTitleColor),
      subtitle: ShieldConfiguration.Label(text: subtitle, color: shieldSubtitleColor),
      primaryButtonLabel: ShieldConfiguration.Label(text: shieldPrimaryButtonLabel, color: .white),
      primaryButtonBackgroundColor: shieldPrimaryButtonColor,
      secondaryButtonLabel: hasSecondary ? ShieldConfiguration.Label(text: shieldSecondaryButtonLabel, color: shieldSubtitleColor) : nil
    )
  }

  /// #598: record the app currently being shielded (App Group) so the escape ShieldAction — which on
  /// the category overload has no ApplicationToken — can target it. Both app-carrying overloads pass
  /// through here; `application.token` is the specific app even inside a category shield.
  private func recordLastShieldedApplication(_ application: Application) {
    guard let token = application.token,
          let tokenData = try? JSONEncoder().encode(token) else { return }
    let encoded = tokenData.base64EncodedString()
    let tsMs = Int64(Date().timeIntervalSince1970 * 1000.0)

    // Primary: atomic file write to the App Group container (durable across this extension's instant
    // teardown — see lastShieldedFileName).
    if let fileURL = appGroupFileURL(lastShieldedFileName),
       let json = try? JSONSerialization.data(withJSONObject: ["token": encoded, "ts": tsMs]) {
      try? json.write(to: fileURL, options: .atomic)
    }
    // Best-effort UserDefaults mirror (usually reaped with this process; kept for the legacy fallback).
    if let defaults = UserDefaults(suiteName: appGroupIdentifier) {
      defaults.set(encoded, forKey: lastShieldedTokenKey)
      defaults.set(tsMs, forKey: lastShieldedTokenTsKey)
    }
  }

  private func appGroupFileURL(_ name: String) -> URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
      .appendingPathComponent(name)
  }

  override func configuration(shielding application: Application) -> ShieldConfiguration {
    recordLastShieldedApplication(application)
    return makeConfig(appName: application.localizedDisplayName ?? "This app")
  }

  override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration {
    recordLastShieldedApplication(application)
    return makeConfig(appName: category.localizedDisplayName ?? "This category")
  }

  override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
    makeConfig(appName: webDomain.domain ?? "This website")
  }

  override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration {
    makeConfig(appName: webDomain.domain ?? "This website")
  }
}
