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
  const val MODE_ALLOW = "allow"
  const val MODE_BLOCK = "block"
  private const val KEY_BLOCK_EXPIRES_AT = "block_expires_at_millis"
  // #572 escape ticket: a wall-clock instant until which ALL blocking (immediate + schedule) is
  // suppressed, independent of the lock layers. 0 = no ticket. The service tick honors it; the
  // boundary alarm wakes the service at this instant to re-block even if the service had been killed.
  private const val KEY_SUPPRESSION_UNTIL = "suppression_until_millis"
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
    val editor = get(context).edit().putStringSet(KEY_BLOCKED_PACKAGES, set)
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
    val editor = get(context).edit()
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
      .remove(KEY_BLOCKED_PACKAGES)
      .remove(KEY_ALLOWED_PACKAGES)
      .remove(KEY_IMMEDIATE_MODE)
      .putLong(KEY_BLOCK_EXPIRES_AT, 0L)
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
    get(context).getLong(KEY_SUPPRESSION_UNTIL, 0L)

  /** #572: plant/clear the escape-ticket end instant. Any value <= 0 clears it (no ticket). */
  fun setSuppressionUntil(context: Context, untilMillis: Long) {
    get(context).edit()
      .putLong(KEY_SUPPRESSION_UNTIL, if (untilMillis > 0L) untilMillis else 0L)
      .apply()
  }

  /** #572: drop the escape ticket. */
  fun clearSuppression(context: Context) {
    get(context).edit().remove(KEY_SUPPRESSION_UNTIL).apply()
  }

  /** #572: true while an escape ticket is live (`now < suppressionUntil`). */
  fun isSuppressed(context: Context): Boolean {
    val until = getSuppressionUntil(context)
    return until > 0L && System.currentTimeMillis() < until
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
    notificationTitle: String?,
    notificationText: String?,
  ) {
    val editor = get(context).edit()
      .putString(KEY_OVERLAY_TITLE, overlayTitle)
      .putString(KEY_OVERLAY_TEXT, overlayText)
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
