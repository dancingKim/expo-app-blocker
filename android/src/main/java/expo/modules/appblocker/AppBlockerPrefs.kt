package expo.modules.appblocker

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject

object AppBlockerPrefs {
  const val PREFS_NAME = "expo_app_blocker_prefs"
  private const val KEY_PENDING_INTERCEPTS = "pending_intercepts"
  private const val KEY_LAST_INTERCEPT_TS = "last_intercept_ts"
  private const val INTERCEPT_DEBOUNCE_MS = 2_000L
  private const val MAX_PENDING_INTERCEPTS = 200
  const val KEY_BLOCKED_PACKAGES = "blocked_packages"
  // #563 allowlist: the kept apps for the immediate block, plus the immediate-block mode
  // ("allow" | "block" | absent = none). In allow mode the service shields everything except
  // KEY_ALLOWED_PACKAGES (+ system-essential apps); in block mode it shields KEY_BLOCKED_PACKAGES.
  const val KEY_ALLOWED_PACKAGES = "allowed_packages"
  const val KEY_IMMEDIATE_MODE = "immediate_mode"
  const val MODE_DUAL = "dual-v1"
  private const val KEY_TARGET_CONFIG = "guardian_target_configuration"
  private const val KEY_CONCURRENT_KEYS = "guardian_concurrent_keys_v1"
  private const val KEY_KEY_SCOPE = "guardian_key_scope"
  const val MODE_ALLOW = "allow"
  const val MODE_BLOCK = "block"
  private const val KEY_BLOCK_EXPIRES_AT = "block_expires_at_millis"
  // #572 escape ticket: a wall-clock instant until which ALL blocking (immediate + schedule) is
  // suppressed, independent of the lock layers. 0 = no ticket. The service tick honors it; the
  // boundary alarm wakes the service at this instant to re-block even if the service had been killed.
  private const val KEY_SUPPRESSION_UNTIL = "suppression_until_millis"
  // #598 targeted escape ticket: while a ticket is live and this is set, only this ONE package is
  // exempt (opens) — every other blocked package stays blocked. Absent → full suppression (all open).
  // Promoted from the escape-target candidate the overlay records when "지금 필요해" is tapped.
  private const val KEY_SUPPRESSION_TARGET_PACKAGE = "suppression_target_package"
  // #598: the package the user pressed "지금 필요해" on, recorded by the overlay (+ freshness ts).
  // suppressBlocksAndroid consumes it and promotes it to KEY_SUPPRESSION_TARGET_PACKAGE.
  private const val KEY_ESCAPE_TARGET_PACKAGE = "escape_target_package"
  private const val KEY_ESCAPE_TARGET_PACKAGE_TS = "escape_target_package_ts"
  // #596 escape landing: the one-shot "지금 필요해 was tapped" flag — the escape variant of
  // KEY_PENDING_GUARDED_LAUNCH. Carries the guarded task id + guardType so the JS router lands on the
  // reason screen (guardian_escape) instead of the task. Same freshness window as the normal launch.
  private const val KEY_PENDING_GUARDED_ESCAPE = "pending_guarded_escape"
  private const val KEY_PENDING_GUARDED_ESCAPE_GUARD_TYPE = "pending_guarded_escape_guard_type"
  private const val KEY_PENDING_GUARDED_ESCAPE_TS = "pending_guarded_escape_ts"
  // #596: overlay button labels (injected by the app via configureAndroid, English fallbacks here —
  // no Korean hardcoded in the fork). Primary = "하러 가기" landing, secondary = "지금 필요해" escape.
  private const val KEY_OVERLAY_PRIMARY_BUTTON = "overlay_primary_button"
  private const val KEY_OVERLAY_SECONDARY_BUTTON = "overlay_secondary_button"
  // Overlay button colors (hex). Absent → fall back to the existing title/text colors, so the
  // current look is unchanged unless the app injects them.
  private const val KEY_OVERLAY_PRIMARY_BUTTON_COLOR = "overlay_primary_button_color"
  private const val KEY_OVERLAY_PRIMARY_BUTTON_TEXT_COLOR = "overlay_primary_button_text_color"
  private const val KEY_OVERLAY_SECONDARY_BUTTON_TEXT_COLOR = "overlay_secondary_button_text_color"
  // Always-on foreground-service notification copy. Absent → the baked-in Korean default (back-compat).
  private const val KEY_FG_NOTIFICATION_TITLE = "fg_notification_title"
  private const val KEY_FG_NOTIFICATION_TEXT = "fg_notification_text"
  private const val KEY_OVERLAY_TITLE = "overlay_title"
  private const val KEY_OVERLAY_TEXT = "overlay_text"
  private const val KEY_OVERLAY_BG_COLOR = "overlay_bg_color"
  private const val KEY_OVERLAY_TITLE_COLOR = "overlay_title_color"
  private const val KEY_OVERLAY_TEXT_COLOR = "overlay_text_color"
  private const val KEY_OVERLAY_TITLE_FONT_SIZE = "overlay_title_font_size"
  private const val KEY_OVERLAY_TEXT_FONT_SIZE = "overlay_text_font_size"
  private const val KEY_OVERLAY_TITLE_BOLD = "overlay_title_bold"
  private const val KEY_OVERLAY_PADDING = "overlay_padding"
  private const val KEY_OVERLAY_ICON_SIZE = "overlay_icon_size"
  private const val KEY_OVERLAY_ICON_GAP = "overlay_icon_gap"
  private const val KEY_OVERLAY_TITLE_GAP = "overlay_title_gap"
  private const val KEY_OVERLAY_SHOW_SPINNER = "overlay_show_spinner"
  private const val KEY_OVERLAY_SPINNER_SIZE = "overlay_spinner_size"
  private const val KEY_OVERLAY_SPINNER_GAP = "overlay_spinner_gap"
  private const val KEY_OVERLAY_SPINNER_COLOR = "overlay_spinner_color"
  private const val KEY_NOTIFICATION_TITLE = "notification_title"
  private const val KEY_NOTIFICATION_TEXT = "notification_text"
  // #535: guarded-launch routing (Android overlay landing). guardedItemId is armed by the app;
  // pending* is the one-shot flag stamped when a block redirects the user, drained by the JS router.
  private const val KEY_GUARDED_ITEM_ID = "guarded_item_id"
  private const val KEY_PENDING_GUARDED_LAUNCH = "pending_guarded_launch"
  private const val KEY_PENDING_GUARDED_LAUNCH_TS = "pending_guarded_launch_ts"
  // Mirror the iOS home-widget freshness window: a guarded launch older than this is stale.
  private const val MAX_PENDING_GUARDED_LAUNCH_AGE_MS = 5 * 60 * 1000L

  fun get(context: Context): SharedPreferences =
    context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

  fun getBlockedPackages(context: Context): Set<String> =
    get(context).getStringSet(KEY_BLOCKED_PACKAGES, emptySet()) ?: emptySet()

  fun setBlockedPackages(context: Context, packages: Collection<String>) {
    val set = packages.toSet()
    val editor = get(context).edit().remove(KEY_TARGET_CONFIG).putStringSet(KEY_BLOCKED_PACKAGES, set)
    // An empty immediate-block set means nothing is blocked now, so drop any pending
    // auto-release expiry with it — expiry is only meaningful alongside a non-empty set,
    // and a stale timestamp must never gate a later block.
    if (set.isEmpty()) {
      editor.putLong(KEY_BLOCK_EXPIRES_AT, 0L)
      editor.remove(KEY_IMMEDIATE_MODE)
    } else {
      // #563: mark legacy denylist mode so the service picks the right enforcement branch.
      editor.putString(KEY_IMMEDIATE_MODE, MODE_BLOCK)
    }
    editor.apply()
  }

  /** #563: the kept apps for allowlist immediate blocking. */
  fun getAllowedPackages(context: Context): Set<String> =
    get(context).getStringSet(KEY_ALLOWED_PACKAGES, emptySet()) ?: emptySet()

  /** #563: the immediate-block mode ("allow" | "block"), or null when no immediate block is armed. */
  fun getImmediateMode(context: Context): String? =
    get(context).getString(KEY_IMMEDIATE_MODE, null)

  /**
   * #563: arm allowlist immediate blocking — shield everything except `packages` (+ system apps).
   * An EMPTY list is the release signal: it clears the immediate block entirely (mode → none, no
   * allowed set, expiry dropped) so "allow nothing / block everything" can never be armed by
   * accident. Non-empty sets mode = "allow".
   */
  fun setAllowedPackages(context: Context, packages: Collection<String>) {
    val set = packages.toSet()
    val editor = get(context).edit().remove(KEY_TARGET_CONFIG)
    if (set.isEmpty()) {
      clearImmediate(editor)
    } else {
      editor
        .putStringSet(KEY_ALLOWED_PACKAGES, set)
        .putString(KEY_IMMEDIATE_MODE, MODE_ALLOW)
    }
    editor.apply()
  }

  /**
   * #563: clear the immediate block regardless of mode — both the denylist and allowlist sets,
   * the mode, and the auto-release expiry. Used on release and on auto-expiry so the next tick
   * returns to the pristine (nothing-blocked) state.
   */
  fun clearImmediateBlock(context: Context) {
    val editor = get(context).edit()
    clearImmediate(editor)
    editor.apply()
  }

  private fun clearImmediate(editor: SharedPreferences.Editor) {
    editor
      .remove(KEY_TARGET_CONFIG)
      .remove(KEY_BLOCKED_PACKAGES)
      .remove(KEY_ALLOWED_PACKAGES)
      .remove(KEY_IMMEDIATE_MODE)
      .putLong(KEY_BLOCK_EXPIRES_AT, 0L)
  }

  internal fun setTargetConfiguration(context: Context, config: Map<String, Any?>) {
    GuardianTargetPolicy.parse(config)
    val active = config["isActive"] != false
    val expiry = (config["expiresAtMillis"] as? Number)?.toLong() ?: 0L
    val prefs = get(context)
    val previous = prefs.getString(KEY_TARGET_CONFIG, null)
    val previousMode = prefs.getString(KEY_IMMEDIATE_MODE, null)
    val previousExpiry = prefs.getLong(KEY_BLOCK_EXPIRES_AT, 0L)
    val previousAllowed = prefs.getStringSet(KEY_ALLOWED_PACKAGES, emptySet())
    val previousBlocked = prefs.getStringSet(KEY_BLOCKED_PACKAGES, emptySet())
    val editor = prefs.edit()
    if (active) {
      editor.putString(KEY_TARGET_CONFIG, JSONObject(config).toString())
        .putString(KEY_IMMEDIATE_MODE, MODE_DUAL).putLong(KEY_BLOCK_EXPIRES_AT, expiry)
    } else { clearImmediate(editor) }
    if (!editor.commit()) {
      // Android commit may update memory even when disk persistence fails: restore both views.
      prefs.edit().putString(KEY_TARGET_CONFIG, previous).putString(KEY_IMMEDIATE_MODE, previousMode)
        .putLong(KEY_BLOCK_EXPIRES_AT, previousExpiry).putStringSet(KEY_ALLOWED_PACKAGES, previousAllowed)
        .putStringSet(KEY_BLOCKED_PACKAGES, previousBlocked).commit()
      error("Target policy persistence failed")
    }
  }

  internal fun jsonMap(raw: String): Map<String, Any?> {
    val json = JSONObject(raw)
    return json.keys().asSequence().associateWith { key -> jsonValue(json.get(key)) }
  }
  private fun jsonValue(value: Any?): Any? = when (value) {
    is JSONArray -> (0 until value.length()).map { jsonValue(value.get(it)) }
    is JSONObject -> value.keys().asSequence().associateWith { jsonValue(value.get(it)) }
    JSONObject.NULL -> null
    else -> value
  }

  internal fun getTargetPolicy(context: Context): GuardianTargetPolicy? =
    get(context).getString(KEY_TARGET_CONFIG, null)?.let {
      runCatching { GuardianTargetPolicy.parse(jsonMap(it)) }.getOrNull()
    }

  // Service, alarm receiver and Expo module share this application process and monitor.
  // commit (not apply) makes successful Start durable before its native acknowledgement.
  @Synchronized internal fun readGuardianKeys(context: Context, migrate: Boolean = false): GuardianKeyRegistry? {
    val prefs = get(context)
    var registry = prefs.getString(KEY_CONCURRENT_KEYS, null)?.let { raw ->
      val values = JSONArray(raw)
      GuardianKeyRegistry((0 until values.length()).map { GuardianScopedKey.parse(jsonMap(values.getJSONObject(it).toString())) })
    }
    if (migrate) {
      registry = registry ?: GuardianKeyRegistry()
      val end = prefs.getLong(KEY_SUPPRESSION_UNTIL, 0L)
      if (end > System.currentTimeMillis()) {
        val scope = if (prefs.contains(KEY_KEY_SCOPE)) GuardianKeyScope.parse(jsonMap(prefs.getString(KEY_KEY_SCOPE, "")!!))
          else prefs.getString(KEY_SUPPRESSION_TARGET_PACKAGE, null).let { GuardianKeyScope(it == null, it?.let(::setOf) ?: emptySet()) }
        val legacy = GuardianScopedKey("legacy-$end", scope, 0L, end)
        if (registry.keys.none { it.id == legacy.id }) registry = GuardianKeyRegistry(registry.keys + legacy)
      }
    }
    return registry
  }
  @Synchronized internal fun writeGuardianKeys(context: Context, registry: GuardianKeyRegistry) {
    val prefs = get(context)
    val old = prefs.getString(KEY_CONCURRENT_KEYS, null)
    val oldScope = prefs.getString(KEY_KEY_SCOPE, null)
    val oldEnd = prefs.getLong(KEY_SUPPRESSION_UNTIL, 0L)
    val oldTarget = prefs.getString(KEY_SUPPRESSION_TARGET_PACKAGE, null)
    if (!prefs.edit().putString(KEY_CONCURRENT_KEYS, JSONArray(registry.keys.map { JSONObject(it.persisted()) }).toString())
        .remove(KEY_KEY_SCOPE).remove(KEY_SUPPRESSION_UNTIL).remove(KEY_SUPPRESSION_TARGET_PACKAGE).commit()) {
      prefs.edit().putString(KEY_CONCURRENT_KEYS, old).putString(KEY_KEY_SCOPE, oldScope)
        .putLong(KEY_SUPPRESSION_UNTIL, oldEnd).putString(KEY_SUPPRESSION_TARGET_PACKAGE, oldTarget).commit()
      error("Guardian keys persistence failed")
    }
  }
  @Synchronized internal fun validateGuardianKey(context: Context, raw: Map<String, Any?>): GuardianKeyRegistry {
    val previous = readGuardianKeys(context, true)!!
    return previous.adding(GuardianScopedKey.parse(raw), System.currentTimeMillis())
  }
  @Synchronized internal fun startGuardianKey(context: Context, raw: Map<String, Any?>): GuardianKeyRegistry {
    val next = validateGuardianKey(context, raw)
    writeGuardianKeys(context, next)
    return next
  }
  @Synchronized internal fun closeGuardianKey(context: Context, id: String): GuardianKeyRegistry {
    val next = readGuardianKeys(context, true)!!.closing(id)
    writeGuardianKeys(context, next)
    return next
  }
  internal fun hasGuardianKeys(context: Context) = get(context).contains(KEY_CONCURRENT_KEYS)
  private fun activeRegistry(context: Context): GuardianKeyRegistry? {
    val current = try { readGuardianKeys(context) } catch (_: Exception) { return GuardianKeyRegistry() }
    // An old API remains a single opening until a new API explicitly migrates it.
    if (get(context).getLong(KEY_SUPPRESSION_UNTIL, 0L) > System.currentTimeMillis() && current?.live(System.currentTimeMillis()).isNullOrEmpty()) return null
    return current
  }
  internal fun nextGuardianKeyExpiry(context: Context): Long =
    activeRegistry(context)?.live(System.currentTimeMillis())?.firstOrNull()?.untilMillis ?: getSuppressionUntil(context)
  @Synchronized internal fun prepareLegacyGuardianKey(context: Context) {
    if (readGuardianKeys(context)?.live(System.currentTimeMillis())?.isNotEmpty() == true) throw GuardianKeyFailure("ERR_GUARDIAN_KEY_CONFLICT")
  }

  @Synchronized internal fun setScopedSuppression(context: Context, until: Long, scope: GuardianKeyScope) {
    prepareLegacyGuardianKey(context)
    val raw = scope.asMap() + ("untilMillis" to until)
    val prefs = get(context)
    val previous = prefs.getString(KEY_KEY_SCOPE, null)
    val previousUntil = prefs.getLong(KEY_SUPPRESSION_UNTIL, 0L)
    val previousTarget = prefs.getString(KEY_SUPPRESSION_TARGET_PACKAGE, null)
    if (!prefs.edit().putString(KEY_KEY_SCOPE, JSONObject(raw).toString())
        .putLong(KEY_SUPPRESSION_UNTIL, until).remove(KEY_SUPPRESSION_TARGET_PACKAGE).commit()) {
      prefs.edit().putString(KEY_KEY_SCOPE, previous).putLong(KEY_SUPPRESSION_UNTIL, previousUntil)
        .putString(KEY_SUPPRESSION_TARGET_PACKAGE, previousTarget).commit()
      error("Opening persistence failed")
    }
  }

  internal fun hasExplicitKeyScope(context: Context): Boolean = get(context).contains(KEY_KEY_SCOPE)

  internal fun getKeyScope(context: Context): GuardianKeyScope? {
    activeRegistry(context)?.let { return it.scope(System.currentTimeMillis()) }
    val prefs = get(context)
    if (prefs.contains(KEY_KEY_SCOPE)) {
      // An explicit but malformed value must never mean full opening.
      return runCatching { GuardianKeyScope.parse(jsonMap(prefs.getString(KEY_KEY_SCOPE, "")!!)) }
        .getOrElse { GuardianKeyScope(false, emptySet()) }
    }
    val legacy = getSuppressionTargetPackage(context)
    return GuardianKeyScope(legacy == null, legacy?.let { setOf(it) } ?: emptySet())
  }

  /** Immediate-block auto-release time (epoch millis); 0 means no expiry. */
  fun getBlockExpiresAt(context: Context): Long =
    get(context).getLong(KEY_BLOCK_EXPIRES_AT, 0L)

  /**
   * Plant/clear the immediate-block auto-release time. This is the *release guarantee*
   * stored the moment we lock: an app/server relock signal can only bring release
   * *forward*, and a killed process drops that signal, so the block is guaranteed to lift
   * only because this timestamp lives in prefs and the service enforces it. Any value
   * <= 0 clears it (no expiry).
   */
  fun setBlockExpiresAt(context: Context, expiresAtMillis: Long) {
    get(context).edit()
      .putLong(KEY_BLOCK_EXPIRES_AT, if (expiresAtMillis > 0L) expiresAtMillis else 0L)
      .apply()
  }

  /** #572: the escape-ticket end instant (epoch millis); 0 means no ticket. */
  fun getSuppressionUntil(context: Context): Long =
    activeRegistry(context)?.live(System.currentTimeMillis())?.maxOfOrNull { it.untilMillis }
      ?: if (activeRegistry(context) != null) 0L else get(context).getLong(KEY_SUPPRESSION_UNTIL, 0L)

  /** #572: plant/clear the escape-ticket end instant. Any value <= 0 clears it (no ticket). */
  @Synchronized fun setSuppressionUntil(context: Context, untilMillis: Long) {
    prepareLegacyGuardianKey(context)
    get(context).edit()
      .remove(KEY_KEY_SCOPE)
      .putLong(KEY_SUPPRESSION_UNTIL, if (untilMillis > 0L) untilMillis else 0L)
      .apply()
  }

  /** #572: drop the escape ticket. #598: and its targeted package, so a later ticket starts clean. */
  @Synchronized fun clearSuppression(context: Context) {
    readGuardianKeys(context)?.let { registry -> writeGuardianKeys(context, GuardianKeyRegistry(registry.keys.map { it.copy(closed = true) })) }
    get(context).edit()
      .remove(KEY_KEY_SCOPE)
      .remove(KEY_SUPPRESSION_UNTIL)
      .remove(KEY_SUPPRESSION_TARGET_PACKAGE)
      .apply()
  }

  /** #572: true while an escape ticket is live (`now < suppressionUntil`). */
  fun isSuppressed(context: Context): Boolean {
    val until = getSuppressionUntil(context)
    return until > 0L && System.currentTimeMillis() < until
  }

  /**
   * #598: the ONE package a live targeted escape ticket keeps open (every other blocked package stays
   * blocked), or null for a full-suppression ticket (all open). Set by [setSuppressionTargetPackage].
   */
  fun getSuppressionTargetPackage(context: Context): String? =
    get(context).getString(KEY_SUPPRESSION_TARGET_PACKAGE, null)

  /** #598: plant/clear the targeted-ticket package. null/empty clears it (→ full suppression). */
  fun setSuppressionTargetPackage(context: Context, packageName: String?) {
    val editor = get(context).edit()
    if (packageName.isNullOrEmpty()) editor.remove(KEY_SUPPRESSION_TARGET_PACKAGE)
    else editor.putString(KEY_SUPPRESSION_TARGET_PACKAGE, packageName)
    editor.apply()
  }

  /**
   * #732: read (do NOT clear) the fresh escape-target candidate so the JS reason screen can show the
   * app's real name. [consumeEscapeTargetPackage] still promotes/clears it when the ticket is issued.
   * Stale/absent → null (same freshness window as the guarded launch).
   */
  fun peekEscapeTargetPackage(context: Context): String? {
    val prefs = get(context)
    val ts = prefs.getLong(KEY_ESCAPE_TARGET_PACKAGE_TS, 0L)
    val pkg = prefs.getString(KEY_ESCAPE_TARGET_PACKAGE, null)
    if (ts <= 0L || pkg.isNullOrEmpty()) return null
    return if (System.currentTimeMillis() - ts <= MAX_PENDING_GUARDED_LAUNCH_AGE_MS) pkg else null
  }

  /** #598: the overlay records the package the user pressed "지금 필요해" on (candidate + freshness). */
  fun recordEscapeTargetPackage(context: Context, packageName: String, atMillis: Long) {
    get(context).edit()
      .putString(KEY_ESCAPE_TARGET_PACKAGE, packageName)
      .putLong(KEY_ESCAPE_TARGET_PACKAGE_TS, atMillis)
      .apply()
  }

  /**
   * #598: return and clear the escape-target candidate iff fresh (same window as the guarded launch),
   * for suppressBlocksAndroid to promote to the ticket's target. Stale/absent → null → full open.
   */
  fun consumeEscapeTargetPackage(context: Context): String? {
    val prefs = get(context)
    val ts = prefs.getLong(KEY_ESCAPE_TARGET_PACKAGE_TS, 0L)
    val pkg = prefs.getString(KEY_ESCAPE_TARGET_PACKAGE, null)
    if (ts > 0L || pkg != null) {
      prefs.edit().remove(KEY_ESCAPE_TARGET_PACKAGE).remove(KEY_ESCAPE_TARGET_PACKAGE_TS).apply()
    }
    if (ts <= 0L || pkg.isNullOrEmpty()) return null
    return if (System.currentTimeMillis() - ts <= MAX_PENDING_GUARDED_LAUNCH_AGE_MS) pkg else null
  }

  /**
   * #596: record the one-shot escape flag ("지금 필요해" tapped) — the escape variant of
   * [recordPendingGuardedLaunch]. Stamps the currently-armed guarded task id + the guardType, and
   * clears any normal pending-launch flag so a single overlay tap routes to exactly one place.
   */
  fun recordPendingGuardedEscape(context: Context, guardType: String, atMillis: Long) {
    val prefs = get(context)
    val itemId = prefs.getString(KEY_GUARDED_ITEM_ID, "") ?: ""
    prefs.edit()
      .putString(KEY_PENDING_GUARDED_ESCAPE, itemId)
      .putString(KEY_PENDING_GUARDED_ESCAPE_GUARD_TYPE, guardType)
      .putLong(KEY_PENDING_GUARDED_ESCAPE_TS, atMillis)
      .remove(KEY_PENDING_GUARDED_LAUNCH)
      .remove(KEY_PENDING_GUARDED_LAUNCH_TS)
      .apply()
  }

  /**
   * #596: return and clear the pending escape flag as { itemId, guardType } when a fresh escape tap is
   * pending, else null. The JS router drains it on resume and lands on the reason screen
   * (guardian_escape), mirroring the iOS ShieldAction escape notification payload.
   */
  fun consumePendingGuardedEscape(context: Context): Map<String, String>? {
    val prefs = get(context)
    val ts = prefs.getLong(KEY_PENDING_GUARDED_ESCAPE_TS, 0L)
    if (ts <= 0L) return null
    val itemId = prefs.getString(KEY_PENDING_GUARDED_ESCAPE, "") ?: ""
    val guardType = prefs.getString(KEY_PENDING_GUARDED_ESCAPE_GUARD_TYPE, "") ?: ""
    prefs.edit()
      .remove(KEY_PENDING_GUARDED_ESCAPE)
      .remove(KEY_PENDING_GUARDED_ESCAPE_GUARD_TYPE)
      .remove(KEY_PENDING_GUARDED_ESCAPE_TS)
      .apply()
    if (System.currentTimeMillis() - ts > MAX_PENDING_GUARDED_LAUNCH_AGE_MS) return null
    return mapOf("itemId" to itemId, "guardType" to guardType)
  }

  /**
   * #535: the guarded task id armed alongside an immediate block (mirrors iOS's App Group
   * `appBlocker.guardedItemId.v1`). null/empty clears it. Stamped into the pending-launch flag when
   * a block redirects the user.
   */
  fun setGuardedItemId(context: Context, itemId: String?) {
    val editor = get(context).edit()
    if (itemId.isNullOrEmpty()) editor.remove(KEY_GUARDED_ITEM_ID) else editor.putString(KEY_GUARDED_ITEM_ID, itemId)
    editor.apply()
  }

  /**
   * #535: record a one-shot "a block just redirected the user here" flag, stamping the currently
   * armed guarded task id (possibly empty) and the time. The JS router drains it on resume via
   * [consumePendingGuardedLaunch] and lands on that task.
   */
  fun recordPendingGuardedLaunch(context: Context, atMillis: Long) {
    val prefs = get(context)
    val itemId = prefs.getString(KEY_GUARDED_ITEM_ID, "") ?: ""
    prefs.edit()
      .putString(KEY_PENDING_GUARDED_LAUNCH, itemId)
      .putLong(KEY_PENDING_GUARDED_LAUNCH_TS, atMillis)
      .apply()
  }

  /**
   * #535: return and clear the pending guarded-launch flag. Returns the guarded task id (possibly
   * empty string) when a fresh guarded launch is pending, or null when none is pending or it is stale.
   */
  fun consumePendingGuardedLaunch(context: Context): String? {
    val prefs = get(context)
    val ts = prefs.getLong(KEY_PENDING_GUARDED_LAUNCH_TS, 0L)
    if (ts <= 0L) return null
    val itemId = prefs.getString(KEY_PENDING_GUARDED_LAUNCH, "") ?: ""
    prefs.edit()
      .remove(KEY_PENDING_GUARDED_LAUNCH)
      .remove(KEY_PENDING_GUARDED_LAUNCH_TS)
      .apply()
    return if (System.currentTimeMillis() - ts <= MAX_PENDING_GUARDED_LAUNCH_AGE_MS) itemId else null
  }

  /**
   * Push the overlay + notification config from JS into native prefs.
   *
   * Numeric `Float?` knobs (font sizes, paddings, icon size) are stored as
   * floats and read back through [getOverlayFloat]. Pass `null` to keep the
   * baked-in default; pass an explicit value (e.g. `28f`) to override.
   */
  fun setAndroidConfig(
    context: Context,
    overlayTitle: String?,
    overlayText: String?,
    overlayBackgroundColor: String?,
    overlayTitleColor: String?,
    overlayTextColor: String?,
    overlayTitleFontSize: Float?,
    overlayTextFontSize: Float?,
    overlayTitleBold: Boolean?,
    overlayPadding: Float?,
    overlayIconSize: Float?,
    overlayIconBottomMargin: Float?,
    overlayTitleBottomMargin: Float?,
    overlayShowSpinner: Boolean?,
    overlaySpinnerSize: Float?,
    overlaySpinnerTopMargin: Float?,
    overlaySpinnerColor: String?,
    overlayPrimaryButtonText: String?,
    overlaySecondaryButtonText: String?,
    overlayPrimaryButtonColor: String?,
    overlayPrimaryButtonTextColor: String?,
    overlaySecondaryButtonTextColor: String?,
    foregroundNotificationTitle: String?,
    foregroundNotificationText: String?,
    notificationTitle: String?,
    notificationText: String?,
  ) {
    val editor = get(context).edit()
      .putString(KEY_OVERLAY_TITLE, overlayTitle)
      .putString(KEY_OVERLAY_TEXT, overlayText)
      .putString(KEY_OVERLAY_PRIMARY_BUTTON, overlayPrimaryButtonText)
      .putString(KEY_OVERLAY_SECONDARY_BUTTON, overlaySecondaryButtonText)
      .putString(KEY_OVERLAY_PRIMARY_BUTTON_COLOR, overlayPrimaryButtonColor)
      .putString(KEY_OVERLAY_PRIMARY_BUTTON_TEXT_COLOR, overlayPrimaryButtonTextColor)
      .putString(KEY_OVERLAY_SECONDARY_BUTTON_TEXT_COLOR, overlaySecondaryButtonTextColor)
      .putString(KEY_FG_NOTIFICATION_TITLE, foregroundNotificationTitle)
      .putString(KEY_FG_NOTIFICATION_TEXT, foregroundNotificationText)
      .putString(KEY_OVERLAY_BG_COLOR, overlayBackgroundColor)
      .putString(KEY_OVERLAY_TITLE_COLOR, overlayTitleColor)
      .putString(KEY_OVERLAY_TEXT_COLOR, overlayTextColor)
      .putString(KEY_OVERLAY_SPINNER_COLOR, overlaySpinnerColor)
      .putString(KEY_NOTIFICATION_TITLE, notificationTitle)
      .putString(KEY_NOTIFICATION_TEXT, notificationText)
    putNullableFloat(editor, KEY_OVERLAY_TITLE_FONT_SIZE, overlayTitleFontSize)
    putNullableFloat(editor, KEY_OVERLAY_TEXT_FONT_SIZE, overlayTextFontSize)
    putNullableFloat(editor, KEY_OVERLAY_PADDING, overlayPadding)
    putNullableFloat(editor, KEY_OVERLAY_ICON_SIZE, overlayIconSize)
    putNullableFloat(editor, KEY_OVERLAY_ICON_GAP, overlayIconBottomMargin)
    putNullableFloat(editor, KEY_OVERLAY_TITLE_GAP, overlayTitleBottomMargin)
    putNullableFloat(editor, KEY_OVERLAY_SPINNER_SIZE, overlaySpinnerSize)
    putNullableFloat(editor, KEY_OVERLAY_SPINNER_GAP, overlaySpinnerTopMargin)
    if (overlayTitleBold != null) {
      editor.putBoolean(KEY_OVERLAY_TITLE_BOLD, overlayTitleBold)
    } else {
      editor.remove(KEY_OVERLAY_TITLE_BOLD)
    }
    if (overlayShowSpinner != null) {
      editor.putBoolean(KEY_OVERLAY_SHOW_SPINNER, overlayShowSpinner)
    } else {
      editor.remove(KEY_OVERLAY_SHOW_SPINNER)
    }
    editor.apply()
  }

  fun getOverlayTitle(context: Context): String =
    get(context).getString(KEY_OVERLAY_TITLE, null) ?: "App Blocked"

  fun getOverlayText(context: Context): String =
    get(context).getString(KEY_OVERLAY_TEXT, null) ?: "{appName} is blocked."

  // #596 overlay buttons. Primary = "하러 가기" landing (always shown). Secondary = "지금 필요해"
  // escape (shown unless the app disables it by passing "none"/empty). English fallbacks only —
  // the app injects the Korean copy via configureAndroid.
  fun getOverlayPrimaryButtonText(context: Context): String =
    get(context).getString(KEY_OVERLAY_PRIMARY_BUTTON, null) ?: "Go do it"

  fun getOverlaySecondaryButtonText(context: Context): String? {
    val value = get(context).getString(KEY_OVERLAY_SECONDARY_BUTTON, null) ?: "I need it now"
    return if (value.isEmpty() || value == "none") null else value
  }

  // Overlay button colors (hex) — null lets OverlayManager fall back to the title/text colors, so the
  // current look is unchanged unless the app injects them.
  fun getOverlayPrimaryButtonColor(context: Context): String? =
    get(context).getString(KEY_OVERLAY_PRIMARY_BUTTON_COLOR, null)

  fun getOverlayPrimaryButtonTextColor(context: Context): String? =
    get(context).getString(KEY_OVERLAY_PRIMARY_BUTTON_TEXT_COLOR, null)

  fun getOverlaySecondaryButtonTextColor(context: Context): String? =
    get(context).getString(KEY_OVERLAY_SECONDARY_BUTTON_TEXT_COLOR, null)

  // Always-on foreground-service notification copy — SSOT in the app (guardianCopy.awareness.*);
  // baked-in Korean defaults keep back-compat when the app doesn't inject.
  fun getForegroundNotificationTitle(context: Context): String =
    get(context).getString(KEY_FG_NOTIFICATION_TITLE, null) ?: "앱 잠금 켜짐"

  fun getForegroundNotificationText(context: Context): String =
    get(context).getString(KEY_FG_NOTIFICATION_TEXT, null) ?: "허용한 앱만 열려."

  fun getOverlayBackgroundColor(context: Context): String =
    get(context).getString(KEY_OVERLAY_BG_COLOR, null) ?: "#FFFFFF"

  fun getOverlayTitleColor(context: Context): String =
    get(context).getString(KEY_OVERLAY_TITLE_COLOR, null) ?: "#111111"

  fun getOverlayTextColor(context: Context): String =
    get(context).getString(KEY_OVERLAY_TEXT_COLOR, null) ?: "#737373"

  fun getOverlayTitleFontSize(context: Context): Float =
    getOverlayFloat(context, KEY_OVERLAY_TITLE_FONT_SIZE, 24f)

  fun getOverlayTextFontSize(context: Context): Float =
    getOverlayFloat(context, KEY_OVERLAY_TEXT_FONT_SIZE, 16f)

  fun getOverlayTitleBold(context: Context): Boolean =
    get(context).getBoolean(KEY_OVERLAY_TITLE_BOLD, true)

  fun getOverlayPadding(context: Context): Float =
    getOverlayFloat(context, KEY_OVERLAY_PADDING, 32f)

  fun getOverlayIconSize(context: Context): Float =
    getOverlayFloat(context, KEY_OVERLAY_ICON_SIZE, 96f)

  fun getOverlayIconBottomMargin(context: Context): Float =
    getOverlayFloat(context, KEY_OVERLAY_ICON_GAP, 20f)

  fun getOverlayTitleBottomMargin(context: Context): Float =
    getOverlayFloat(context, KEY_OVERLAY_TITLE_GAP, 12f)

  fun getOverlayShowSpinner(context: Context): Boolean =
    get(context).getBoolean(KEY_OVERLAY_SHOW_SPINNER, false)

  fun getOverlaySpinnerSize(context: Context): Float =
    getOverlayFloat(context, KEY_OVERLAY_SPINNER_SIZE, 32f)

  fun getOverlaySpinnerTopMargin(context: Context): Float =
    getOverlayFloat(context, KEY_OVERLAY_SPINNER_GAP, 24f)

  fun getOverlaySpinnerColor(context: Context): String? =
    get(context).getString(KEY_OVERLAY_SPINNER_COLOR, null)

  fun getNotificationTitle(context: Context): String =
    get(context).getString(KEY_NOTIFICATION_TITLE, null) ?: "App Blocked"

  fun getNotificationText(context: Context): String =
    get(context).getString(KEY_NOTIFICATION_TEXT, null) ?: "{appName} is blocked. Tap to manage."

  /**
   * Queue one OS-level block event for the app to drain into
   * `blocker_intercepts`. Debounced globally so the poll loop can't emit
   * duplicates for a single block, and capped to bound storage.
   */
  fun appendIntercept(context: Context, appName: String, interceptedAtMs: Long) {
    val prefs = get(context)
    val lastTs = prefs.getLong(KEY_LAST_INTERCEPT_TS, 0L)
    if (lastTs > 0L && interceptedAtMs - lastTs < INTERCEPT_DEBOUNCE_MS) return

    val arr = try {
      JSONArray(prefs.getString(KEY_PENDING_INTERCEPTS, "[]"))
    } catch (e: Exception) {
      JSONArray()
    }
    arr.put(JSONObject().put("appName", appName).put("interceptedAt", interceptedAtMs))

    val trimmed = if (arr.length() > MAX_PENDING_INTERCEPTS) {
      JSONArray().also { t ->
        for (i in (arr.length() - MAX_PENDING_INTERCEPTS) until arr.length()) t.put(arr.get(i))
      }
    } else {
      arr
    }

    prefs.edit()
      .putString(KEY_PENDING_INTERCEPTS, trimmed.toString())
      .putLong(KEY_LAST_INTERCEPT_TS, interceptedAtMs)
      .apply()
  }

  /** Return and clear the queued block events. */
  fun drainIntercepts(context: Context): List<Map<String, Any>> {
    val prefs = get(context)
    val arr = try {
      JSONArray(prefs.getString(KEY_PENDING_INTERCEPTS, "[]"))
    } catch (e: Exception) {
      JSONArray()
    }
    val out = ArrayList<Map<String, Any>>(arr.length())
    for (i in 0 until arr.length()) {
      val o = arr.getJSONObject(i)
      out.add(
        mapOf(
          "appName" to o.optString("appName", ""),
          "interceptedAt" to o.optDouble("interceptedAt"),
        )
      )
    }
    if (arr.length() > 0) prefs.edit().remove(KEY_PENDING_INTERCEPTS).apply()
    return out
  }

  private fun putNullableFloat(editor: SharedPreferences.Editor, key: String, value: Float?) {
    if (value != null) editor.putFloat(key, value) else editor.remove(key)
  }

  private fun getOverlayFloat(context: Context, key: String, fallback: Float): Float =
    if (get(context).contains(key)) get(context).getFloat(key, fallback) else fallback
}
