import ManagedSettingsUI
import ManagedSettings
import UIKit
import os

class ShieldConfigurationExtension: ShieldConfigurationDataSource {

  private let appGroupIdentifier = "APP_GROUP_PLACEHOLDER"
  // #598 diagnosis: idevicesyslog-observable trace of every lastShielded write attempt — whether the
  // data source was called, which overload, whether iOS gave an ApplicationToken (hypothesis A: it
  // withholds it in category context), and whether the App Group file write succeeded (hypothesis B:
  // the ShieldConfiguration sandbox blocks it). Filter: subsystem com.worthyi.chapchu.guardian.
  private let diagLog = Logger(subsystem: "com.worthyi.chapchu.guardian", category: "shieldconfig")
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
  // Subtitle. Keeps the "하러 가기" redirect button (NOT an unlock — the schedule store survives the
  // unlock path, so the button only returns to the app). (#588: the bedtime preset was removed by
  // #570's free-window inversion, so there is only the one weekday shield now.)
  private let scheduleWeekdayTitle = "지금은 나랑 있자."
  private let scheduleWeekdaySubtitle = "문은 이따 열려."

  private var mascotIcon: UIImage? {
    let bundle = Bundle(for: type(of: self))
    return UIImage(named: "shield-icon", in: bundle, compatibleWith: nil)
      ?? UIImage(contentsOfFile: bundle.path(forResource: "shield-icon", ofType: "png") ?? "")
  }

  private func getBlockedAppCount() -> Int {
    guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return 0 }
    // Focus-store split: the immediate config may live in the gate (legacy) slot or the focus slot.
    // Prefer the gate slot; fall back to focus so a focus-only lock still shows a count. (A render
    // can't tell which store shielded it, so this stays a best-effort label.)
    guard let config = defaults.dictionary(forKey: "appBlocker.blockConfiguration.v1")
      ?? defaults.dictionary(forKey: "appBlocker.blockConfiguration.focus.v1") else { return 0 }
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

  // #525: whether a schedule window is currently active — the DeviceActivity monitor writes
  // "schedule" while out of every free window, and removes the key while inside one (or unarmed).
  // nil = not shielded by the schedule, so the default/focus shield path renders instead.
  // (#588: the value is always "schedule" now — #570 removed the bedtime preset.)
  private func scheduleShieldVariant() -> String? {
    guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return nil }
    guard let value = defaults.string(forKey: "appBlocker.scheduleShieldVariant.v1"), !value.isEmpty else { return nil }
    return value
  }

  private func scheduleShieldConfig() -> ShieldConfiguration? {
    guard scheduleShieldVariant() != nil else { return nil }
    // #572: the escape ticket is the ONLY way out of an out-of-window schedule lock, so the schedule
    // shield offers the same "지금 필요해" secondary button as the default/focus shield (when the app
    // configured it; "none"/empty hides it — back-compat).
    let hasSecondary = !shieldSecondaryButtonLabel.isEmpty && shieldSecondaryButtonLabel != "none"
    return ShieldConfiguration(
      backgroundBlurStyle: shieldBlurStyle,
      backgroundColor: shieldBackgroundColor,
      icon: mascotIcon,
      title: ShieldConfiguration.Label(text: scheduleWeekdayTitle, color: shieldTitleColor),
      subtitle: ShieldConfiguration.Label(text: scheduleWeekdaySubtitle, color: shieldSubtitleColor),
      primaryButtonLabel: ShieldConfiguration.Label(text: shieldPrimaryButtonLabel, color: .white),
      primaryButtonBackgroundColor: shieldPrimaryButtonColor,
      secondaryButtonLabel: hasSecondary ? ShieldConfiguration.Label(text: shieldSecondaryButtonLabel, color: shieldSubtitleColor) : nil
    )
  }

  private func isTemporarilyUnlocked() -> Bool {
    guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return false }
    guard let expiration = defaults.object(forKey: "appBlocker.temporaryUnlock.v1") as? Date else { return false }
    return Date() < expiration
  }

  // Block-event queue, drained by the app into `blocker_intercepts` to power
  // the "blocks" counter. The system re-renders the shield often (app
  // switcher previews, re-foreground), so a short debounce collapses those
  // bursts into one logical block event. The debounce timestamp is PER
  // EXTENSION: this data source (exposure) and ShieldAction (tap) used to
  // share one `appBlocker.lastInterceptTs.v1` key, so a render within 2s of
  // a tap — or, the common case, a tap right after the render that produced
  // the shield — was silently swallowed and the two could never both be
  // recorded. Each entry now also carries `kind` ("impression" here,
  // "action" in ShieldAction) so the drain side can tell them apart.
  private let pendingInterceptsKey = "appBlocker.pendingIntercepts.v1"
  private let lastImpressionTsKey = "appBlocker.lastImpressionTs.v1"
  private let interceptDebounceMs: Double = 2_000
  private let maxPendingIntercepts = 200

  // Best-effort block recording. iOS caches the shield configuration and
  // does NOT reliably re-invoke this data source per open, so the action
  // handler (ShieldAction) is the primary recorder; this is a bonus path
  // for the cases the system does re-invoke. Writes share the same App
  // Group JSON queue as ShieldAction but debounce on their own key, so an
  // exposure never swallows the tap that follows it (and vice versa).
  private func recordIntercept(appName: String) {
    guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return }
    defaults.synchronize()

    let nowMs = Date().timeIntervalSince1970 * 1000.0
    let lastMs = defaults.double(forKey: lastImpressionTsKey)
    if lastMs > 0, (nowMs - lastMs) < interceptDebounceMs { return }

    var queue: [[String: Any]] = []
    if let json = defaults.string(forKey: pendingInterceptsKey),
       let data = json.data(using: .utf8),
       let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
      queue = parsed
    }
    queue.append(["appName": appName, "interceptedAt": nowMs, "kind": "impression"])
    if queue.count > maxPendingIntercepts {
      queue = Array(queue.suffix(maxPendingIntercepts))
    }
    if let data = try? JSONSerialization.data(withJSONObject: queue),
       let json = String(data: data, encoding: .utf8) {
      defaults.set(json, forKey: pendingInterceptsKey)
    }
    defaults.set(nowMs, forKey: lastImpressionTsKey)
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

    // #525: out of every free window → render the weekday schedule shield. The monitor's variant key
    // is the SSOT; inside a window (or unarmed) it's absent → fall through to the default/focus shield.
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

  /// #598 diagnosis: record the app being shielded so the escape ShieldAction (which on the category
  /// overload has no ApplicationToken) can target it. ALWAYS writes the file — even when iOS withholds
  /// the token — so the real-device probe separates hypothesis A (token nil in category context) from
  /// B (the sandbox blocks the write). os_log traces every step for idevicesyslog.
  private func recordLastShieldedApplication(_ application: Application, overload: String) {
    let token = application.token
    let displayName = application.localizedDisplayName
    let tsMs = Int64(Date().timeIntervalSince1970 * 1000.0)
    diagLog.log("recordLastShielded called overload=\(overload, privacy: .public) tokenNil=\(token == nil, privacy: .public) hasDisplayName=\(displayName?.isEmpty == false, privacy: .public)")

    var payload: [String: Any] = ["ts": tsMs, "overload": overload]
    var encoded: String? = nil
    if let token = token, let tokenData = try? JSONEncoder().encode(token) {
      let enc = tokenData.base64EncodedString()
      encoded = enc
      payload["token"] = enc
      payload["tokenNil"] = false
    } else {
      payload["tokenNil"] = true
      payload["hasDisplayName"] = (displayName?.isEmpty == false)
    }

    // Primary: atomic file write to the App Group container. Resolve the container inline so a nil
    // (missing entitlement / wrong app group) logs distinctly from a write failure (sandbox = B).
    guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
      diagLog.error("recordLastShielded: App Group container URL nil (entitlement/appGroup id?)")
      mirrorLastShieldedToUserDefaults(encoded: encoded, tsMs: tsMs)
      return
    }
    let fileURL = container.appendingPathComponent(lastShieldedFileName)
    if let json = try? JSONSerialization.data(withJSONObject: payload) {
      do {
        try json.write(to: fileURL, options: .atomic)
        diagLog.log("recordLastShielded: file write OK tokenNil=\(token == nil, privacy: .public)")
      } catch {
        diagLog.error("recordLastShielded: file write FAILED: \(error.localizedDescription, privacy: .public)")
      }
    }

    // Best-effort UserDefaults mirror (kept for the ShieldAction fallback read; usually reaped).
    mirrorLastShieldedToUserDefaults(encoded: encoded, tsMs: tsMs)
  }

  /// UserDefaults mirror of the last-shielded token (only when a token exists), for ShieldAction's
  /// fallback read. Best-effort — this extension's UserDefaults writes are frequently reaped.
  private func mirrorLastShieldedToUserDefaults(encoded: String?, tsMs: Int64) {
    guard let encoded = encoded, let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return }
    defaults.set(encoded, forKey: lastShieldedTokenKey)
    defaults.set(tsMs, forKey: lastShieldedTokenTsKey)
  }

  override func configuration(shielding application: Application) -> ShieldConfiguration {
    recordLastShieldedApplication(application, overload: "application")
    return makeConfig(appName: application.localizedDisplayName ?? "This app")
  }

  override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration {
    recordLastShieldedApplication(application, overload: "application-in-category")
    return makeConfig(appName: category.localizedDisplayName ?? "This category")
  }

  override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
    makeConfig(appName: webDomain.domain ?? "This website")
  }

  override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration {
    makeConfig(appName: webDomain.domain ?? "This website")
  }
}
