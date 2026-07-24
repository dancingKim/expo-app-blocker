package expo.modules.appblocker

import android.app.AppOpsManager
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.net.Uri
import android.os.Process
import android.provider.Settings
import android.util.Base64
import android.util.Log
import androidx.core.app.NotificationManagerCompat
import expo.modules.kotlin.exception.Exceptions
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import java.io.ByteArrayOutputStream

private const val TAG = "ExpoAppBlocker"

class ExpoAppBlockerModule : Module() {
  private val context: Context
    get() = appContext.reactContext ?: throw Exceptions.ReactContextLost()

  override fun definition() = ModuleDefinition {
    Name("ExpoAppBlocker")

    // #535: Android compiles the blocker in (no separate extension), so guardian is attached
    // whenever this native module is present. Mirrors iOS's guardianExtensionAttached for the JS
    // exposure gate (#541).
    Constants("guardianExtensionAttached" to true)

    OnCreate {
      AppBlockerService.start(context)
      Log.d(TAG, "Module OnCreate: started AppBlockerService")
    }

    AsyncFunction("checkOverlayPermission") {
      Settings.canDrawOverlays(context)
    }

    AsyncFunction("checkUsageStatsPermission") {
      val appOps = context.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
      val mode = appOps.unsafeCheckOpNoThrow(
        AppOpsManager.OPSTR_GET_USAGE_STATS,
        Process.myUid(),
        context.packageName
      )
      mode == AppOpsManager.MODE_ALLOWED
    }

    AsyncFunction("checkNotificationPermission") {
      NotificationManagerCompat.from(context).areNotificationsEnabled()
    }

    Function("openOverlaySettings") {
      val intent = Intent(
        Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
        Uri.parse("package:${context.packageName}")
      ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
      context.startActivity(intent)
    }

    Function("openUsageStatsSettings") {
      val intent = Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
      context.startActivity(intent)
    }

    Function("setAndroidConfig") { config: Map<String, Any?> ->
      // JS sends numbers as Double over the bridge — coerce to Float so prefs
      // keep a consistent type. Booleans are forwarded as-is.
      fun numberOrNull(key: String): Float? = (config[key] as? Number)?.toFloat()

      AppBlockerPrefs.setAndroidConfig(
        context,
        overlayTitle = config["overlayTitle"] as? String,
        overlayText = config["overlayText"] as? String,
        overlayBackgroundColor = config["overlayBackgroundColor"] as? String,
        overlayTitleColor = config["overlayTitleColor"] as? String,
        overlayTextColor = config["overlayTextColor"] as? String,
        overlayTitleFontSize = numberOrNull("overlayTitleFontSize"),
        overlayTextFontSize = numberOrNull("overlayTextFontSize"),
        overlayTitleBold = config["overlayTitleBold"] as? Boolean,
        overlayPadding = numberOrNull("overlayPadding"),
        overlayIconSize = numberOrNull("overlayIconSize"),
        overlayIconBottomMargin = numberOrNull("overlayIconBottomMargin"),
        overlayTitleBottomMargin = numberOrNull("overlayTitleBottomMargin"),
        overlayShowSpinner = config["overlayShowSpinner"] as? Boolean,
        overlaySpinnerSize = numberOrNull("overlaySpinnerSize"),
        overlaySpinnerTopMargin = numberOrNull("overlaySpinnerTopMargin"),
        overlaySpinnerColor = config["overlaySpinnerColor"] as? String,
        overlayPrimaryButtonText = config["overlayPrimaryButtonText"] as? String,
        overlaySecondaryButtonText = config["overlaySecondaryButtonText"] as? String,
        overlayPrimaryButtonColor = config["overlayPrimaryButtonColor"] as? String,
        overlayPrimaryButtonTextColor = config["overlayPrimaryButtonTextColor"] as? String,
        overlaySecondaryButtonTextColor = config["overlaySecondaryButtonTextColor"] as? String,
        foregroundNotificationTitle = config["foregroundNotificationTitle"] as? String,
        foregroundNotificationText = config["foregroundNotificationText"] as? String,
        notificationTitle = config["notificationTitle"] as? String,
        notificationText = config["notificationText"] as? String,
      )
      Log.d(TAG, "setAndroidConfig: $config")
    }

    Function("setBlockedApps") { packageNames: List<String> ->
      AppBlockerPrefs.setBlockedPackages(context, packageNames)
      Log.d(TAG, "setBlockedApps: $packageNames")
    }

    // #563 allowlist immediate blocking: shield every app EXCEPT `packageNames` (+ system-essential
    // apps) while armed. An empty list clears the immediate block (release). Expiry is planted
    // separately via setBlockExpiryAndroid, exactly like setBlockedApps.
    Function("setAllowedAppsAndroid") { packageNames: List<String> ->
      AppBlockerPrefs.setAllowedPackages(context, packageNames)
      AppBlockerService.start(context)
      Log.d(TAG, "setAllowedAppsAndroid: $packageNames")
    }

    // Plant (or clear) the immediate block's auto-release time. Epoch millis; <= 0 clears
    // it. The service gates the immediate block on this and lazily clears it once passed,
    // and re-arming the boundary alarm makes it wake the service at the expiry instant so
    // release happens even if this app process was later killed. JS sends the millis as a
    // Double (epoch ms overflows Int).
    Function("setBlockExpiryAndroid") { expiresAtMillis: Double ->
      AppBlockerPrefs.setBlockExpiresAt(context, expiresAtMillis.toLong())
      AlarmReceiver.scheduleNext(context)
      Log.d(TAG, "setBlockExpiryAndroid: $expiresAtMillis")
    }

    Function("getBlockedApps") {
      AppBlockerPrefs.getBlockedPackages(context).toList()
    }

    // #535: guarded task id the app arms alongside an immediate block (mirrors the iOS
    // appBlocker.guardedItemId.v1 App Group key). Recorded into the consumable pending-launch flag
    // when a block redirects the user, so the JS router (#522) can land on that task. null/empty clears.
    Function("setGuardedItemIdAndroid") { itemId: String? ->
      AppBlockerPrefs.setGuardedItemId(context, itemId)
      Log.d(TAG, "setGuardedItemIdAndroid: $itemId")
    }

    // #535: drain the one-shot "a block just redirected you here" flag. Returns the guarded task id
    // (possibly empty string) when a fresh guarded launch is pending, else null. The verified
    // launcher intent can't carry routing data, so the JS router (#522) consumes this on resume to
    // land on the guarded task — analogous to the home widget's consumePendingLaunchAction.
    Function("consumePendingGuardedLaunch") {
      AppBlockerPrefs.consumePendingGuardedLaunch(context)
    }

    // #596: drain the one-shot "지금 필요해 tapped" escape flag. Returns { itemId, guardType } when a
    // fresh escape landing is pending, else null. The JS router lands on the reason screen
    // (guardian_escape), mirroring the iOS ShieldAction escape notification payload.
    Function("consumePendingGuardedEscape") {
      AppBlockerPrefs.consumePendingGuardedEscape(context)
    }

    Function("setScheduleConfiguration") { config: Map<String, Any?> ->
      ScheduleStore.setConfiguration(context, config)
      // Arm the boundary alarm and make sure the service is alive so an already-open
      // window is enforced on the next poll tick.
      AlarmReceiver.scheduleNext(context)
      AppBlockerService.start(context)
      Log.d(TAG, "setScheduleConfiguration: $config")
    }

    Function("clearScheduleConfiguration") {
      ScheduleStore.clear(context)
      // #572: tearing down the schedule drops any escape ticket so it can't outlive the blocks.
      AppBlockerPrefs.clearSuppression(context)
      AlarmReceiver.cancel(context)
      Log.d(TAG, "clearScheduleConfiguration")
    }

    Function("getScheduleConfiguration") {
      ScheduleStore.getConfigurationMap(context)
    }

    Function("drainPendingIntercepts") {
      AppBlockerPrefs.drainIntercepts(context)
    }

    Function("startMonitoring") {
      AppBlockerService.start(context)
      Log.d(TAG, "startMonitoring called")
    }

    Function("stopMonitoring") {
      AppBlockerService.stop(context)
      Log.d(TAG, "stopMonitoring called")
    }

    Function("temporaryUnlockAndroid") { durationMinutes: Int ->
      AppBlockerService.temporaryUnlock(context, durationMinutes)
      Log.d(TAG, "temporaryUnlockAndroid: $durationMinutes minutes")
    }

    Function("relockAndroid") {
      AppBlockerService.relock(context)
      Log.d(TAG, "relockAndroid")
    }

    Function("getRemainingUnlockTimeAndroid") {
      TemporaryUnlockController.remainingSeconds(context)
    }

    // #572 escape ticket: suppress ALL blocking (immediate + schedule) until untilMillis (epoch ms),
    // independent of the lock layers. The service tick honors it; the boundary alarm re-blocks at T
    // even if the service was killed. Epoch ms arrives as a Double (overflows Int), like
    // setBlockExpiryAndroid.
    Function("suppressBlocksAndroid") { untilMillis: Double ->
      AppBlockerPrefs.setSuppressionUntil(context, untilMillis.toLong())
      // #598: promote the overlay-captured escaped package (if fresh) to this ticket's target — only
      // that app stays open, every other blocked app keeps its shield. Absent/stale → full open.
      AppBlockerPrefs.setSuppressionTargetPackage(context, AppBlockerPrefs.consumeEscapeTargetPackage(context))
      AlarmReceiver.scheduleNext(context)
      AppBlockerService.start(context)
      Log.d(TAG, "suppressBlocksAndroid: $untilMillis")
    }

    // #572: current escape-ticket state (remaining ms) for the door card '열림 · 타이머 N분' display.
    Function("getSuppressionStateAndroid") {
      val until = AppBlockerPrefs.getSuppressionUntil(context)
      val remaining = (until - System.currentTimeMillis()).coerceAtLeast(0L)
      mapOf(
        "active" to (remaining > 0L),
        "untilMillis" to until.toDouble(),
        "remainingMs" to remaining.toDouble(),
      )
    }

    // Last-resort recovery for an unrecoverable native state (observed:
    // expo-sqlite's Android connection degrading after enough reuse in a
    // long-lived process — a fresh `openDatabaseAsync` + first pragma NPEs
    // even after a full DB rebuild). Apps that keep this module's
    // AppBlockerService running as a foreground service can end up with an
    // unusually long-lived process (the OS won't kill it just because the
    // Activity was "closed"), which surfaces exactly this kind of
    // native-module degradation far more than a normal app would. Only a
    // genuine process kill clears it: queue the relaunch intent (optionally
    // straight back into `deepLink`, e.g. the blocker intercept URL the
    // caller was trying to reach) — `startActivity` only needs to queue the
    // intent with ActivityManagerService, which survives our process dying
    // right after — then kill this process outright. No AlarmManager/
    // PendingIntent needed (and SCHEDULE_EXACT_ALARM would require a
    // permission apps otherwise don't need just for this).
    Function("restartApp") { deepLink: String? ->
      val intent = if (!deepLink.isNullOrEmpty()) {
        Intent(Intent.ACTION_VIEW, Uri.parse(deepLink))
      } else {
        context.packageManager.getLaunchIntentForPackage(context.packageName)
      }
      if (intent == null) {
        Log.e(TAG, "restartApp: no launch intent resolvable, cannot self-heal")
        return@Function
      }
      intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)

      context.startActivity(intent)

      Log.w(
        TAG,
        "restartApp: relaunch queued, killing process ${Process.myPid()} to recover " +
          "from an unrecoverable native state"
      )
      Process.killProcess(Process.myPid())
    }

    AsyncFunction("getInstalledApps") {
      val pm = context.packageManager
      val intent = Intent(Intent.ACTION_MAIN).apply {
        addCategory(Intent.CATEGORY_LAUNCHER)
      }
      val resolved = pm.queryIntentActivities(intent, 0)
      val seen = HashSet<String>()
      resolved.mapNotNull { resolveInfo ->
        val appInfo = resolveInfo.activityInfo.applicationInfo
        if (appInfo.packageName == context.packageName) return@mapNotNull null
        if (!seen.add(appInfo.packageName)) return@mapNotNull null

        val iconBase64 = try {
          val drawable = pm.getApplicationIcon(appInfo)
          drawableToBase64Png(drawable)
        } catch (e: Exception) {
          Log.w(TAG, "Failed to load icon for ${appInfo.packageName}: ${e.message}")
          null
        }

        mapOf(
          "packageName" to appInfo.packageName,
          "name" to (pm.getApplicationLabel(appInfo)?.toString() ?: appInfo.packageName),
          "iconBase64" to iconBase64
        )
      }.sortedBy { it["name"]?.toString()?.lowercase() }
    }
  }

  private fun drawableToBase64Png(drawable: Drawable): String {
    val size = 96
    val bitmap = if (drawable is BitmapDrawable && drawable.bitmap != null) {
      Bitmap.createScaledBitmap(drawable.bitmap, size, size, true)
    } else {
      val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
      val canvas = Canvas(bmp)
      drawable.setBounds(0, 0, canvas.width, canvas.height)
      drawable.draw(canvas)
      bmp
    }
    val stream = ByteArrayOutputStream()
    bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
    return Base64.encodeToString(stream.toByteArray(), Base64.NO_WRAP)
  }
}
