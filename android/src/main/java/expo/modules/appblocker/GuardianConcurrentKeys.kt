package expo.modules.appblocker

internal class GuardianKeyFailure(val code: String) : IllegalArgumentException(code)
internal data class GuardianScopedKey(
  val id: String, val scope: GuardianKeyScope, val startedAtMillis: Long,
  val untilMillis: Long, val closed: Boolean = false
) {
  fun live(now: Long) = !closed && startedAtMillis <= now && untilMillis > now
  fun asMap(): Map<String, Any> = mapOf("id" to id, "scope" to scope.asMap(),
    "startedAtMillis" to startedAtMillis, "untilMillis" to untilMillis)
  fun persisted(): Map<String, Any> = asMap() + ("closed" to closed)
  companion object {
    fun parse(raw: Map<String, Any?>): GuardianScopedKey {
      val id = raw["id"] as? String ?: throw GuardianKeyFailure("ERR_GUARDIAN_KEY_INVALID")
      val start = (raw["startedAtMillis"] as? Number)?.toDouble() ?: Double.NaN
      val end = (raw["untilMillis"] as? Number)?.toDouble() ?: Double.NaN
      if (id.isEmpty() || id.length > 200 || !start.isFinite() || !end.isFinite() || start % 1.0 != 0.0 || end % 1.0 != 0.0 || start < 0 || end <= start || end >= Long.MAX_VALUE.toDouble())
        throw GuardianKeyFailure("ERR_GUARDIAN_KEY_INVALID")
      if (raw.containsKey("closed") && raw["closed"] !is Boolean) throw GuardianKeyFailure("ERR_GUARDIAN_KEY_INVALID")
      @Suppress("UNCHECKED_CAST")
      val scope = try { GuardianKeyScope.parse(raw["scope"] as? Map<String, Any?> ?: throw GuardianKeyFailure("ERR_GUARDIAN_KEY_INVALID")) }
        catch (_: IllegalArgumentException) { throw GuardianKeyFailure("ERR_GUARDIAN_KEY_INVALID") }
      return GuardianScopedKey(id, scope, start.toLong(), end.toLong(), raw["closed"] == true)
    }
  }
}
internal data class GuardianKeyRegistry(val keys: List<GuardianScopedKey> = emptyList()) {
  init { if (keys.map { it.id }.toSet().size != keys.size) throw GuardianKeyFailure("ERR_GUARDIAN_KEY_INVALID") }
  fun live(now: Long) = keys.filter { it.live(now) }.sortedWith(compareBy({ it.untilMillis }, { it.id }))
  fun snapshot(now: Long): Map<String, Any> = live(now).let {
    mapOf("keys" to it.map(GuardianScopedKey::asMap), "nextExpiryMillis" to (it.firstOrNull()?.untilMillis ?: 0L))
  }
  fun adding(key: GuardianScopedKey, now: Long): GuardianKeyRegistry {
    keys.firstOrNull { it.id == key.id }?.let {
      if (it.copy(closed = false) != key.copy(closed = false)) throw GuardianKeyFailure("ERR_GUARDIAN_KEY_CONFLICT")
      if (it.closed) throw GuardianKeyFailure("ERR_GUARDIAN_KEY_CLOSED")
      if (!it.live(now)) throw GuardianKeyFailure("ERR_GUARDIAN_KEY_INVALID")
      return this
    }
    if (!key.live(now)) throw GuardianKeyFailure("ERR_GUARDIAN_KEY_INVALID")
    return GuardianKeyRegistry(keys.filter { it.untilMillis > now } + key)
  }
  fun closing(id: String) = GuardianKeyRegistry(keys.map { if (it.id == id) it.copy(closed = true) else it })
  fun scope(now: Long): GuardianKeyScope = live(now).let {
    GuardianKeyScope(it.any { key -> key.scope.full }, it.flatMap { key -> key.scope.apps }.toSet())
  }
}
