package expo.modules.appblocker
import android.content.Context
import java.util.concurrent.CountDownLatch

fun main() {
  val context = Context()
  val now = System.currentTimeMillis()
  fun raw(id: String, app: String = id, end: Long = now + 120000) = mapOf<String, Any?>(
    "id" to id, "scope" to GuardianKeyScope(false, setOf(app)).asMap(), "startedAtMillis" to now, "untilMillis" to end)
  val a = raw("a", end=now + 60000); val b = raw("b")
  AppBlockerPrefs.validateGuardianKey(context, a)
  check(!AppBlockerPrefs.hasGuardianKeys(context)) // preflight has no storage effect
  AppBlockerPrefs.startGuardianKey(context, a)
  AppBlockerPrefs.startGuardianKey(context, b)
  check(AppBlockerPrefs.getKeyScope(context)!!.apps == setOf("a", "b"))
  check(AppBlockerPrefs.nextGuardianKeyExpiry(context) == now + 60000)
  val persisted = AppBlockerPrefs.readGuardianKeys(context)!!
  check(persisted.live(now + 60000).map { it.id } == listOf("b"))
  check(persisted.live(now + 120000).isEmpty())
  AppBlockerPrefs.startGuardianKey(context, a)
  check(AppBlockerPrefs.readGuardianKeys(context)!!.keys.size == 2)
  try { AppBlockerPrefs.startGuardianKey(context, raw("a", "different")); error("conflict accepted") }
  catch (e: GuardianKeyFailure) { check(e.code == "ERR_GUARDIAN_KEY_CONFLICT") }
  AppBlockerPrefs.closeGuardianKey(context, "a")
  check(AppBlockerPrefs.getKeyScope(context)!!.apps == setOf("b"))
  try { AppBlockerPrefs.startGuardianKey(context, a); error("closed key resurrected") }
  catch (e: GuardianKeyFailure) { check(e.code == "ERR_GUARDIAN_KEY_CLOSED") }
  context.preferences.failNextCommit = true
  try { AppBlockerPrefs.startGuardianKey(context, raw("failure")); error("failed persistence accepted") } catch (_: IllegalStateException) {}
  check(AppBlockerPrefs.getKeyScope(context)!!.apps == setOf("b"))
  val latch = CountDownLatch(1)
  val threads = (1..12).map { index -> Thread { latch.await(); AppBlockerPrefs.startGuardianKey(context, raw("parallel-$index")) }.apply { start() } }
  latch.countDown(); threads.forEach { it.join() }
  check(AppBlockerPrefs.readGuardianKeys(context)!!.live(now).size == 13)
  AppBlockerPrefs.clearSuppression(context)
  check(!AppBlockerPrefs.isSuppressed(context))
  check(AppBlockerPrefs.readGuardianKeys(context)!!.keys.all { it.closed })
  val legacy = Context()
  AppBlockerPrefs.setSuppressionUntil(legacy, now + 300000)
  AppBlockerPrefs.setSuppressionTargetPackage(legacy, "old-app")
  val migrated = AppBlockerPrefs.readGuardianKeys(legacy, true)!!
  check(migrated.keys.single().id == "legacy-${now + 300000}" && migrated.keys.single().startedAtMillis == 0L)
  check(migrated.keys.single().scope.apps == setOf("old-app"))
  AppBlockerPrefs.writeGuardianKeys(legacy, migrated)
  AppBlockerPrefs.startGuardianKey(legacy, raw("new-app"))
  check(AppBlockerPrefs.getKeyScope(legacy)!!.apps == setOf("old-app", "new-app"))
  try { AppBlockerPrefs.setSuppressionUntil(legacy, now + 400000); error("Legacy API overwrote concurrent") } catch (_: GuardianKeyFailure) {}
  AppBlockerPrefs.clearSuppression(legacy)
  AppBlockerPrefs.setScopedSuppression(legacy, now + 400000, GuardianKeyScope(false, setOf("legacy-again")))
  check(AppBlockerPrefs.getKeyScope(legacy)!!.apps == setOf("legacy-again"))
  val race = Context()
  AppBlockerPrefs.startGuardianKey(race, a)
  val go = CountDownLatch(1)
  val close = Thread { go.await(); AppBlockerPrefs.closeGuardianKey(race, "a") }
  val add = Thread { go.await(); AppBlockerPrefs.startGuardianKey(race, b) }
  close.start(); add.start(); go.countDown(); close.join(); add.join()
  check(AppBlockerPrefs.getKeyScope(race)!!.apps == setOf("b"))
  try { AppBlockerPrefs.startGuardianKey(race, a); error("Racing retry resurrected A") } catch (e: GuardianKeyFailure) { check(e.code == "ERR_GUARDIAN_KEY_CLOSED") }
  race.preferences.edit().putString("guardian_concurrent_keys_v1", "broken").commit()
  check(!AppBlockerPrefs.isSuppressed(race))
  val full = GuardianScopedKey("full", GuardianKeyScope(true, emptySet()), now, now + 1000)
  val withFull = persisted.adding(full, now)
  check(withFull.scope(now).full && !withFull.scope(now + 1000).full)
  println("Kotlin concurrent keys: real prefs replay, migration, failures, interleaved start/close, expiry and legacy compatibility passed")
}
