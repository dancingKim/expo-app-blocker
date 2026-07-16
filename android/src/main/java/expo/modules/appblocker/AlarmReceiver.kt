package expo.modules.appblocker

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

/**
 * Wakes [AppBlockerService] at each schedule-window boundary — and at the immediate
 * block's auto-release time — so those transitions are enforced even if the service was
 * killed while idle. The service's 500 ms poll handles enforcement while it is alive; this
 * alarm only guarantees it is running at the next boundary/expiry, whichever is sooner.
 *
 * WARNING (Android 12+): starting a foreground service from this background broadcast is
 * only permitted because [AlarmManager.setExactAndAllowWhileIdle] grants the app a short
 * temporary allowlist when the exact alarm fires. If exact alarms are unavailable (denied
 * SCHEDULE_EXACT_ALARM) we fall back to an inexact alarm, which does NOT carry that
 * allowlist — the FGS start may then be blocked until the app is next foregrounded.
 */
class AlarmReceiver : BroadcastReceiver() {
  override fun onReceive(context: Context, intent: Intent) {
    if (intent.action != ACTION_BOUNDARY) return
    Log.d(TAG, "AlarmReceiver: boundary/expiry, waking service + re-arming")
    // Wake the service; its poll re-reads the wall clock and applies/clears the block
    // (schedule transition or immediate-block auto-release, whichever this wake was for).
    AppBlockerService.start(context.applicationContext)
    // Chain the next boundary (exact alarms are one-shot).
    scheduleNext(context.applicationContext)
  }

  companion object {
    private const val TAG = "ExpoAppBlocker"
    private const val ACTION_BOUNDARY = "expo.modules.appblocker.SCHEDULE_BOUNDARY"
    private const val REQUEST_CODE = 9101

    private fun pendingIntent(context: Context): PendingIntent {
      val intent = Intent(context, AlarmReceiver::class.java).apply { action = ACTION_BOUNDARY }
      // FLAG_IMMUTABLE is required on Android 12+ for PendingIntents we don't mutate.
      return PendingIntent.getBroadcast(
        context, REQUEST_CODE, intent,
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
      )
    }

    /**
     * (Re)arm the alarm for the next window boundary. Cancels any pending alarm when no
     * windows are configured, so clearing the schedule leaves no wakeups behind. Safe to
     * call repeatedly (the PendingIntent is stable, so it replaces rather than stacks).
     */
    fun scheduleNext(context: Context) {
      val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
      val pi = pendingIntent(context)
      val now = System.currentTimeMillis()

      // Wake at whichever comes first: the next schedule-window boundary, or the immediate
      // block's auto-release instant (when one is planted and still in the future). The
      // service does the actual transition/release on the tick that follows the wake — this
      // alarm only guarantees a tick fires at that instant even if the service was killed.
      val scheduleBoundary = ScheduleStore.nextBoundaryAfter(context, now)
      val blockExpiry = AppBlockerPrefs.getBlockExpiresAt(context).takeIf { it > now }
      val next = listOfNotNull(scheduleBoundary, blockExpiry).minOrNull()
      if (next == null) {
        am.cancel(pi)
        return
      }

      val canExact = Build.VERSION.SDK_INT < Build.VERSION_CODES.S || am.canScheduleExactAlarms()
      try {
        if (canExact) {
          am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, next, pi)
        } else {
          // No exact-alarm permission — best-effort inexact wake (no idle allowlist).
          am.set(AlarmManager.RTC_WAKEUP, next, pi)
        }
      } catch (e: SecurityException) {
        Log.w(TAG, "AlarmReceiver: exact alarm denied, falling back to inexact", e)
        am.set(AlarmManager.RTC_WAKEUP, next, pi)
      }
    }

    /** Cancel any pending boundary alarm. */
    fun cancel(context: Context) {
      val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
      am.cancel(pendingIntent(context))
    }
  }
}
