package expo.modules.appblocker

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat

class AppBlockerService : Service() {
  private val handler = Handler(Looper.getMainLooper())
  private var lastForegroundPackage: String? = null
  // Last *known* foreground app. UsageStats only reports recent transitions, so a
  // poll can momentarily read null while the user sits in one app — we retain the
  // last non-null reading so earned-time consumption and re-blocking stay reliable.
  private var currentForeground: String? = null
  private lateinit var overlayManager: OverlayManager
  private val unlockController by lazy { TemporaryUnlockController(this) }
  // Timestamp of the last tick spent consuming earned time; 0 when not consuming.
  private var consumingSinceMs = 0L
  // Whether a block is currently being enforced (overlay shown / app redirected).
  private var blocking = false
  // #563 allowlist: packages that must never be shielded (launcher / system UI / dialer / IME /
  // settings / host). Resolved once lazily — these rarely change within a session, and probing the
  // PackageManager every 500 ms tick would be wasteful.
  private val essentialApps: Set<String> by lazy { SystemEssentialApps.resolve(this) }

  private val pollRunnable = object : Runnable {
    override fun run() {
      tick()
      handler.postDelayed(this, POLL_INTERVAL_MS)
    }
  }

  private fun tick() {
    maybeExpireImmediateBlock()
    maybeExpireSuppression()
    getCurrentForegroundPackage()?.let { currentForeground = it }
    val foreground = currentForeground

    // #572 escape ticket: a valid ticket suppresses ALL blocking (immediate + schedule), independent
    // of the lock layers — keep every app open while it is live. On the first tick after it expires
    // (maybeExpireSuppression cleared the pref above) this is false, so the block re-applies then.
    if (AppBlockerPrefs.isSuppressed(this)) {
      consumingSinceMs = 0L
      clearBlock()
      lastForegroundPackage = foreground
      return
    }

    if (foreground == null || !isBlocked(foreground)) {
      // Outside any blocked app: pause consumption and drop any active block.
      consumingSinceMs = 0L
      clearBlock()
      lastForegroundPackage = foreground
      return
    }

    // Earned time applies to immediate-only blocks. Schedule blocking is a pure time
    // commitment — earned time never bypasses it (matches iOS) — so a schedule-blocked
    // app is enforced immediately without consuming the budget.
    if (!isScheduleBlocked(foreground) && unlockController.hasTimeLeft) {
      // Inside an immediate-only blocked app with earned time — spend it, keep it usable.
      val now = System.currentTimeMillis()
      if (consumingSinceMs > 0L) unlockController.consume(now - consumingSinceMs)
      consumingSinceMs = now
      if (unlockController.hasTimeLeft) {
        clearBlock()
      } else {
        // Earned time ran out while still inside the app.
        Log.d(TAG, "Earned time exhausted in foreground app: $foreground")
        enforceBlock(foreground, BlockReason.EXPIRED)
      }
    } else {
      // Schedule-blocked (earned time must not be burned on an app the shield makes
      // unusable), or an immediate block with no earned time — block on entry.
      consumingSinceMs = 0L
      if (!blocking || foreground != lastForegroundPackage) {
        Log.d(TAG, "Blocked app in foreground: $foreground")
        enforceBlock(foreground, BlockReason.OPENED)
      }
    }
    lastForegroundPackage = foreground
  }

  private fun clearBlock() {
    if (blocking) {
      overlayManager.hide()
      blocking = false
    }
  }

  // The immediate block carries an optional auto-release time planted the moment it was
  // locked (0 = no expiry). expiry is the release guarantee — a JS relock/clear signal
  // only brings release *forward*, and a killed process drops that signal, so the native
  // expiry is what guarantees the block ever lifts. Once it has passed, drop the immediate
  // set + expiry together so subsequent ticks return to the pristine (nothing-blocked)
  // state. Runs every tick; the boundary alarm guarantees a tick fires at the expiry
  // instant even if the service had been killed. No-op with no expiry or before it passes.
  // Schedule blocking is independent and untouched here.
  private fun maybeExpireImmediateBlock() {
    val expiry = AppBlockerPrefs.getBlockExpiresAt(this)
    if (expiry != 0L && System.currentTimeMillis() >= expiry) {
      Log.d(TAG, "Immediate block auto-release time reached ($expiry) — clearing")
      // #563: clear whichever mode is armed (allowlist or legacy denylist) so release is complete.
      AppBlockerPrefs.clearImmediateBlock(this)
    }
  }

  // #572: drop an escape ticket once its wall-clock instant has passed so the next tick re-blocks
  // (and a stale timestamp never lingers). Independent of the immediate-block expiry above.
  private fun maybeExpireSuppression() {
    val until = AppBlockerPrefs.getSuppressionUntil(this)
    if (until != 0L && System.currentTimeMillis() >= until) {
      Log.d(TAG, "Escape ticket expired ($until) — clearing suppression")
      AppBlockerPrefs.clearSuppression(this)
    }
  }

  override fun onBind(intent: Intent?): IBinder? = null

  override fun onCreate() {
    super.onCreate()
    Log.d(TAG, "AppBlockerService onCreate")
    overlayManager = OverlayManager(this)
    createChannelsIfNeeded()
    startForeground(NOTIFICATION_ID, buildNotification())
    handler.post(pollRunnable)
  }

  // Union of immediate blocking and schedule-window blocking. Evaluated every poll tick,
  // so an active window takes effect at its boundary (the wall clock is re-read here).
  // When no schedule is configured `getSchedulePackages` is empty, so this reduces to the
  // original immediate-block check — zero behavior change.
  private fun isBlocked(packageName: String): Boolean {
    if (isImmediateBlocked(packageName)) return true
    return isScheduleBlocked(packageName)
  }

  // Immediate blocking gated on the auto-release expiry (0 = no expiry). Enforced only
  // while `now < expiry`; once passed the block is no longer applied even before
  // [maybeExpireImmediateBlock] clears the prefs, so release can't be delayed by a
  // pending write. Schedule blocking is separate and never gated by this.
  //
  // #563 allowlist: in "allow" mode the immediate block shields every app EXCEPT the kept set
  // (+ system-essential apps); "block" mode is the legacy denylist. No armed mode → nothing blocked.
  private fun isImmediateBlocked(packageName: String): Boolean {
    val mode = AppBlockerPrefs.getImmediateMode(this) ?: return false
    val expiry = AppBlockerPrefs.getBlockExpiresAt(this)
    val notExpired = expiry == 0L || System.currentTimeMillis() < expiry
    if (!notExpired) return false
    return when (mode) {
      AppBlockerPrefs.MODE_ALLOW ->
        packageName !in AppBlockerPrefs.getAllowedPackages(this) && !isSystemEssential(packageName)
      else -> packageName in AppBlockerPrefs.getBlockedPackages(this)
    }
  }

  // #570 free-window inversion: a schedule window is now "free time". While the schedule is armed
  // (>= 1 window configured), everything OUTSIDE the free windows is blocked and inside a window is
  // fully open. Schedule blocking is still a pure time commitment — earned time never bypasses the
  // out-of-window block (matches iOS, where the schedule ManagedSettingsStore is independent of
  // temporary unlock).
  //
  // Regression guard (#570 S2/S4): 0 windows = not armed → block nothing (an empty window set can
  // never become a 24h lockdown); turning 시간표 off clears the windows, so an off schedule also
  // blocks nothing.
  //
  // #563 allowlist: in "allow" mode the out-of-window block shields everything except the kept set
  // (+ system-essential apps); "block" mode is the legacy denylist.
  private fun isScheduleBlocked(packageName: String): Boolean {
    if (ScheduleStore.getWindows(this).isEmpty()) return false                          // not armed / off
    if (ScheduleStore.isAnyWindowActive(this, System.currentTimeMillis())) return false // inside a free window → open
    return when (ScheduleStore.getMode(this)) {
      AppBlockerPrefs.MODE_ALLOW ->
        packageName !in ScheduleStore.getSchedulePackages(this) && !isSystemEssential(packageName)
      else -> packageName in ScheduleStore.getSchedulePackages(this)
    }
  }

  // #563: never shield launcher / system UI / dialer / IME / settings / the host app, so allowlist
  // "block everything else" can't brick the phone or seal off the OS-level emergency exit.
  private fun isSystemEssential(packageName: String): Boolean = packageName in essentialApps

  private fun enforceBlock(packageName: String, reason: BlockReason) {
    overlayManager.show(packageName)
    showBlockedNotification(packageName, reason)
    recordIntercept(packageName)
    // #535: the block just redirected the user to the app — stamp the consumable guarded-launch
    // flag so the JS router (#522) lands on the guarded task on resume (the launcher intent that
    // OverlayManager fires can't carry routing data).
    AppBlockerPrefs.recordPendingGuardedLaunch(this, System.currentTimeMillis())
    blocking = true
    consumingSinceMs = 0L
  }

  /** Queue this block event for the app to drain (debounced in prefs). */
  private fun recordIntercept(packageName: String) {
    val appName = try {
      val pm = this.packageManager
      pm.getApplicationLabel(pm.getApplicationInfo(packageName, 0)).toString()
    } catch (e: Exception) {
      packageName
    }
    AppBlockerPrefs.appendIntercept(this, appName, System.currentTimeMillis())
  }

  private fun showBlockedNotification(packageName: String, reason: BlockReason) {
    val appName = try {
      val pm = this.packageManager
      val appInfo = pm.getApplicationInfo(packageName, 0)
      pm.getApplicationLabel(appInfo).toString()
    } catch (e: Exception) {
      packageName
    }

    val title = AppBlockerPrefs.getNotificationTitle(this).replace("{appName}", appName)
    val text = AppBlockerPrefs.getNotificationText(this).replace("{appName}", appName)

    val scheme = getAppScheme()
    val deepLinkIntent = Intent(
      Intent.ACTION_VIEW,
      Uri.parse(
        "${scheme}://blocked?app=${Uri.encode(appName)}" +
          "&package=${Uri.encode(packageName)}&reason=${reason.slug}"
      )
    ).apply {
      addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
    }

    val launchIntent = packageManager.getLaunchIntentForPackage(this.packageName)
      ?.apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP) }

    val resolvedIntent = try {
      deepLinkIntent.resolveActivity(packageManager)?.let { deepLinkIntent } ?: launchIntent
    } catch (e: Exception) {
      launchIntent
    } ?: deepLinkIntent

    val pendingIntent = PendingIntent.getActivity(
      this, packageName.hashCode(), resolvedIntent,
      PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
    )

    val notification = NotificationCompat.Builder(this, BLOCKED_CHANNEL_ID)
      .setContentTitle(title)
      .setContentText(text)
      .setSmallIcon(applicationInfo.icon)
      .setAutoCancel(true)
      .setPriority(NotificationCompat.PRIORITY_HIGH)
      .setContentIntent(pendingIntent)
      .build()

    val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    manager.notify(BLOCKED_NOTIFICATION_ID, notification)
  }

  private fun getAppScheme(): String {
    val resId = resources.getIdentifier("expo_app_blocker_scheme", "string", packageName)
    if (resId != 0) return getString(resId)
    return try {
      packageManager.getLaunchIntentForPackage(packageName)?.data?.scheme
        ?: packageName.replace(".", "-")
    } catch (e: Exception) {
      packageName.replace(".", "-")
    }
  }

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    when (intent?.action) {
      ACTION_TEMPORARY_UNLOCK -> {
        val minutes = intent.getIntExtra(EXTRA_DURATION_MINUTES, 0)
        Log.d(TAG, "Granting $minutes minutes of earned time")
        unlockController.grant(minutes)
        consumingSinceMs = 0L
        clearBlock()
      }
      ACTION_RELOCK -> {
        Log.d(TAG, "Relock: dropping earned time")
        unlockController.clear()
        consumingSinceMs = 0L
        // Forget the last-seen app so a blocked app already in the foreground is
        // re-blocked on the next poll. Clearing currentForeground too avoids a
        // stale reading wrongly blocking a non-blocked app if the next poll reads null.
        lastForegroundPackage = null
        currentForeground = null
        clearBlock()
      }
    }
    return START_STICKY
  }

  override fun onDestroy() {
    Log.d(TAG, "AppBlockerService onDestroy")
    handler.removeCallbacks(pollRunnable)
    overlayManager.hide()
    super.onDestroy()
  }

  private fun getCurrentForegroundPackage(): String? {
    val usageStatsManager =
      getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
    val endTime = System.currentTimeMillis()
    val beginTime = endTime - LOOKBACK_WINDOW_MS
    val events = usageStatsManager.queryEvents(beginTime, endTime)
    val event = UsageEvents.Event()
    var latestForeground: String? = null
    while (events.hasNextEvent()) {
      events.getNextEvent(event)
      if (event.eventType == UsageEvents.Event.MOVE_TO_FOREGROUND) {
        latestForeground = event.packageName
      }
    }
    return latestForeground
  }

  private fun createChannelsIfNeeded() {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

      val serviceChannel = NotificationChannel(
        CHANNEL_ID, "App Blocker", NotificationManager.IMPORTANCE_LOW
      ).apply {
        description = "Keeps the app blocker running"
        setShowBadge(false)
      }
      manager.createNotificationChannel(serviceChannel)

      val blockedChannel = NotificationChannel(
        BLOCKED_CHANNEL_ID, "Blocked App Alerts", NotificationManager.IMPORTANCE_HIGH
      ).apply {
        description = "Notifications when a blocked app is detected"
      }
      manager.createNotificationChannel(blockedChannel)
    }
  }

  // #526: the always-on foreground-service notification is owned here (not injectable via
  // configureAndroid, which only reaches the block/overlay copy). Copy SSOT lives in the app at
  // guardianCopy.awareness.androidForegroundNotification; kept voice-compliant (no 3rd person,
  // no "~하는 중").
  private fun buildNotification(): Notification =
    NotificationCompat.Builder(this, CHANNEL_ID)
      .setContentTitle("앱 잠금 켜짐")
      .setContentText("허용한 앱만 열려.")
      .setSmallIcon(applicationInfo.icon)
      .setOngoing(true)
      .setPriority(NotificationCompat.PRIORITY_LOW)
      .build()

  companion object {
    private const val TAG = "ExpoAppBlocker"
    private const val CHANNEL_ID = "expo_app_blocker_channel"
    private const val BLOCKED_CHANNEL_ID = "expo_app_blocker_blocked"
    private const val NOTIFICATION_ID = 9001
    private const val BLOCKED_NOTIFICATION_ID = 9002
    private const val POLL_INTERVAL_MS = 500L
    private const val LOOKBACK_WINDOW_MS = 10_000L
    private const val ACTION_TEMPORARY_UNLOCK = "expo.modules.appblocker.TEMPORARY_UNLOCK"
    private const val ACTION_RELOCK = "expo.modules.appblocker.RELOCK"
    private const val EXTRA_DURATION_MINUTES = "duration_minutes"

    fun start(context: Context) {
      startCommand(context, Intent(context, AppBlockerService::class.java))
    }

    fun stop(context: Context) {
      val intent = Intent(context, AppBlockerService::class.java)
      context.stopService(intent)
    }

    fun temporaryUnlock(context: Context, durationMinutes: Int) {
      val intent = Intent(context, AppBlockerService::class.java).apply {
        action = ACTION_TEMPORARY_UNLOCK
        putExtra(EXTRA_DURATION_MINUTES, durationMinutes)
      }
      startCommand(context, intent)
    }

    fun relock(context: Context) {
      val intent = Intent(context, AppBlockerService::class.java).apply {
        action = ACTION_RELOCK
      }
      startCommand(context, intent)
    }

    private fun startCommand(context: Context, intent: Intent) {
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        context.startForegroundService(intent)
      } else {
        context.startService(intent)
      }
    }
  }
}
