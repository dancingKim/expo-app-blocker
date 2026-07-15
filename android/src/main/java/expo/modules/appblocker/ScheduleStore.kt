package expo.modules.appblocker

import android.content.Context
import java.util.Calendar
import org.json.JSONArray
import org.json.JSONObject

/**
 * Persistence + evaluation for schedule-window blocking.
 *
 * A window is a recurring local-time range (minutes since midnight, 0..1439) restricted to
 * a set of ISO weekdays (1 = Monday … 7 = Sunday). `endMinute < startMinute` crosses
 * midnight; the after-midnight portion is gated on the window's START day.
 *
 * Schedule state is stored alongside the immediate-block prefs but under its own keys, so
 * an unset schedule leaves [AppBlockerService] behaving exactly as before. The service's
 * poll re-reads these on every tick, so window boundaries take effect while the service is
 * alive; [AlarmReceiver] wakes the service at boundaries in case it was killed.
 */
object ScheduleStore {
  private const val KEY_SCHEDULE_WINDOWS = "schedule_windows"
  private const val KEY_SCHEDULE_PACKAGES = "schedule_packages"
  private const val MINUTE_MS = 60_000L

  data class Window(val startMinute: Int, val endMinute: Int, val weekdays: Set<Int>)

  /**
   * Persist the schedule config sent from JS: `{ windows: [...], blockedItems: [pkg,...] }`.
   * `blockedItems` on Android is a list of package-name strings (mirrors `setBlockedApps`).
   */
  fun setConfiguration(context: Context, config: Map<String, Any?>) {
    val windowsJson = JSONArray()
    (config["windows"] as? List<*>)?.forEach { raw ->
      val w = raw as? Map<*, *> ?: return@forEach
      val start = (w["startMinute"] as? Number)?.toInt() ?: return@forEach
      val end = (w["endMinute"] as? Number)?.toInt() ?: return@forEach
      val days = JSONArray()
      (w["weekdays"] as? List<*>)?.forEach { d -> (d as? Number)?.toInt()?.let { days.put(it) } }
      windowsJson.put(
        JSONObject()
          .put("startMinute", start)
          .put("endMinute", end)
          .put("weekdays", days)
      )
    }

    val packages = (config["blockedItems"] as? List<*>)
      ?.mapNotNull { it as? String }
      ?.toSet()
      ?: emptySet()

    AppBlockerPrefs.get(context).edit()
      .putString(KEY_SCHEDULE_WINDOWS, windowsJson.toString())
      .putStringSet(KEY_SCHEDULE_PACKAGES, packages)
      .apply()
  }

  fun clear(context: Context) {
    AppBlockerPrefs.get(context).edit()
      .remove(KEY_SCHEDULE_WINDOWS)
      .remove(KEY_SCHEDULE_PACKAGES)
      .apply()
  }

  fun getSchedulePackages(context: Context): Set<String> =
    AppBlockerPrefs.get(context).getStringSet(KEY_SCHEDULE_PACKAGES, emptySet()) ?: emptySet()

  fun getWindows(context: Context): List<Window> {
    val json = AppBlockerPrefs.get(context).getString(KEY_SCHEDULE_WINDOWS, null) ?: return emptyList()
    val arr = try {
      JSONArray(json)
    } catch (e: Exception) {
      return emptyList()
    }
    val out = ArrayList<Window>(arr.length())
    for (i in 0 until arr.length()) {
      val o = arr.optJSONObject(i) ?: continue
      val start = o.optInt("startMinute", -1)
      val end = o.optInt("endMinute", -1)
      if (start < 0 || end < 0) continue
      val daysArr = o.optJSONArray("weekdays") ?: JSONArray()
      val days = HashSet<Int>(daysArr.length())
      for (j in 0 until daysArr.length()) days.add(daysArr.optInt(j))
      out.add(Window(start, end, days))
    }
    return out
  }

  /** Reconstruct the config map for `getScheduleConfiguration`, or null if none is set. */
  fun getConfigurationMap(context: Context): Map<String, Any?>? {
    val windows = getWindows(context)
    val packages = getSchedulePackages(context)
    if (windows.isEmpty() && packages.isEmpty()) return null
    return mapOf(
      "windows" to windows.map {
        mapOf(
          "startMinute" to it.startMinute,
          "endMinute" to it.endMinute,
          "weekdays" to it.weekdays.sorted(),
        )
      },
      "blockedItems" to packages.toList(),
    )
  }

  /**
   * True if any window covers [nowMillis]. A window with `endMinute < startMinute` crosses
   * midnight; its after-midnight portion is gated on the window's START day (yesterday).
   */
  fun isAnyWindowActive(context: Context, nowMillis: Long): Boolean {
    val windows = getWindows(context)
    if (windows.isEmpty()) return false

    val cal = Calendar.getInstance().apply { timeInMillis = nowMillis }
    val nowMinute = cal.get(Calendar.HOUR_OF_DAY) * 60 + cal.get(Calendar.MINUTE)
    val todayIso = isoWeekday(cal.get(Calendar.DAY_OF_WEEK))
    val yesterdayIso = if (todayIso == 1) 7 else todayIso - 1

    for (w in windows) {
      if (w.startMinute <= w.endMinute) {
        if (nowMinute >= w.startMinute && nowMinute < w.endMinute && w.weekdays.contains(todayIso)) {
          return true
        }
      } else {
        if (nowMinute >= w.startMinute && w.weekdays.contains(todayIso)) return true
        if (nowMinute < w.endMinute && w.weekdays.contains(yesterdayIso)) return true
      }
    }
    return false
  }

  /**
   * The next window boundary (start or end) strictly after [nowMillis], or null if no
   * windows are configured. Used by [AlarmReceiver] to wake the service at boundaries.
   * DST shifts are not compensated (acceptable for a wake-and-re-evaluate alarm).
   */
  fun nextBoundaryAfter(context: Context, nowMillis: Long): Long? {
    val windows = getWindows(context)
    if (windows.isEmpty()) return null

    var best = Long.MAX_VALUE
    // Scan 9 calendar days so any non-empty weekday set yields at least one boundary.
    for (dayOffset in 0..8) {
      val dayStart = Calendar.getInstance().apply {
        timeInMillis = nowMillis
        set(Calendar.HOUR_OF_DAY, 0)
        set(Calendar.MINUTE, 0)
        set(Calendar.SECOND, 0)
        set(Calendar.MILLISECOND, 0)
        add(Calendar.DAY_OF_YEAR, dayOffset)
      }
      val isoD = isoWeekday(dayStart.get(Calendar.DAY_OF_WEEK))
      val isoPrev = if (isoD == 1) 7 else isoD - 1

      for (w in windows) {
        // Start boundary fires on day D when D's weekday is in the set.
        if (w.weekdays.contains(isoD)) {
          val startMs = dayStart.timeInMillis + w.startMinute * MINUTE_MS
          if (startMs > nowMillis && startMs < best) best = startMs
        }
        // End boundary: same-day windows end on their start day; cross-midnight windows
        // end on the day after their start day (so gate on the previous day's weekday).
        val endGateIso = if (w.startMinute <= w.endMinute) isoD else isoPrev
        if (w.weekdays.contains(endGateIso)) {
          val endMs = dayStart.timeInMillis + w.endMinute * MINUTE_MS
          if (endMs > nowMillis && endMs < best) best = endMs
        }
      }
    }
    return if (best == Long.MAX_VALUE) null else best
  }

  /** Calendar weekday (Sunday = 1 … Saturday = 7) → ISO (Monday = 1 … Sunday = 7). */
  private fun isoWeekday(calendarDayOfWeek: Int): Int = ((calendarDayOfWeek + 5) % 7) + 1
}
