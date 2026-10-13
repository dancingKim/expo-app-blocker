package expo.modules.appblocker

import android.content.Context
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject

/**
 * chapchu #988: the ACTUAL schedule-lock boundaries (the moment the schedule commitment came into
 * force and the moment it lifted), recorded on-device so the host app can upload them later — the
 * schedule layer is enforced by [AppBlockerService]/[AlarmReceiver] while the app is not running.
 * Mirrors iOS `GuardianLockRecords.swift`. A live escape ticket does NOT end a record (tickets are
 * door passes, subtracted by the host).
 */
object ScheduleLockRecords {
  private const val KEY_STATE = "schedule_lock_state_v1"
  private const val KEY_RECORDS = "schedule_lock_records_v1"
  const val MAX_RECORDS = 200

  /** Armed and outside every free window (same arming rule as the service's schedule check). */
  fun commitmentInForce(context: Context, nowMillis: Long): Boolean {
    if (ScheduleStore.getWindows(context).isEmpty()) {
      val targets = ScheduleStore.getTargetPolicy(context)
      if (!ScheduleStore.isContinuous(context) ||
        (targets?.enforceable ?: ScheduleStore.getSchedulePackages(context).isNotEmpty()) == false) return false
    }
    return !ScheduleStore.isAnyWindowActive(context, nowMillis)
  }

  fun observeNow(context: Context, nowMillis: Long = System.currentTimeMillis()) =
    observe(context, commitmentInForce(context, nowMillis), nowMillis)

  /** Only a transition writes: unlocked→locked opens a record, locked→unlocked closes the newest. */
  fun observe(context: Context, locked: Boolean, nowMillis: Long): Unit = synchronized(AppBlockerPrefs) {
    val prefs = AppBlockerPrefs.get(context)
    if (prefs.getBoolean(KEY_STATE, false) == locked) return
    val records = read(context).toMutableList()
    if (locked) {
      records.add(mapOf("id" to UUID.randomUUID().toString(), "startedAt" to nowMillis.toDouble()))
    } else {
      val index = records.indexOfLast { it["endedAt"] == null }
      if (index >= 0) {
        val startedAt = records[index]["startedAt"] as Double
        records[index] = records[index] + ("endedAt" to maxOf(nowMillis.toDouble(), startedAt))
      }
    }
    val kept = if (records.size > MAX_RECORDS) records.takeLast(MAX_RECORDS) else records
    prefs.edit().putString(KEY_RECORDS, encode(kept)).putBoolean(KEY_STATE, locked).commit()
  }

  /** Every unacknowledged record, oldest first. An open record has no `endedAt`. */
  fun read(context: Context): List<Map<String, Any?>> {
    val raw = AppBlockerPrefs.get(context).getString(KEY_RECORDS, null) ?: return emptyList()
    return try {
      val array = JSONArray(raw)
      (0 until array.length()).mapNotNull { i ->
        val o = array.optJSONObject(i) ?: return@mapNotNull null
        val id = o.optString("id", "").takeIf { it.isNotEmpty() } ?: return@mapNotNull null
        if (!o.has("startedAt")) return@mapNotNull null
        val out = mutableMapOf<String, Any?>("id" to id, "startedAt" to o.getDouble("startedAt"))
        if (o.has("endedAt")) out["endedAt"] = o.getDouble("endedAt")
        out
      }
    } catch (e: Exception) { emptyList() }
  }

  /** Drop CLOSED records the host durably handed off; open records stay even when named. */
  fun acknowledge(context: Context, ids: List<String>): Unit = synchronized(AppBlockerPrefs) {
    val drop = ids.toSet()
    val kept = read(context).filterNot { it["id"] in drop && it["endedAt"] != null }
    AppBlockerPrefs.get(context).edit().putString(KEY_RECORDS, encode(kept)).commit()
  }

  private fun encode(records: List<Map<String, Any?>>): String {
    val array = JSONArray()
    records.forEach { r ->
      val o = JSONObject().put("id", r["id"]).put("startedAt", r["startedAt"])
      r["endedAt"]?.let { o.put("endedAt", it) }
      array.put(o)
    }
    return array.toString()
  }
}
